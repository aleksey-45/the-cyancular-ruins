globalThis.Editor = (function () {
  'use strict';

  var Core = globalThis.Core, Render = globalThis.Render, Io = globalThis.Io;
  if (!Core) throw new Error('ui.js: 必须先加载 core.js');
  if (!Render) throw new Error('ui.js: 必须先加载 render.js');
  if (!Io) throw new Error('ui.js: 必须先加载 io.js');

  var DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;
  var DEFAULT_COMPRESS = true;
  var VIEW_CONTROLS = {
    grid: 'tg-grid', subGrid: 'tg-subgrid', torus: 'tg-torus', dimOthers: 'dim-others', guides: 'tg-guides',
  };
  var homeFiles = globalThis.CYRM_OFFLINE ? MapFiles.downloads() : MapFiles.server();

  var app = {
    r: null, canvas: null, map: null, name: null,
    raw: null, tileDefs: null, files: homeFiles, inLibrary: false, fileBusy: false,
    sourceFormat: 'v4', documentKey: '', drawing: false, gesture: null, compress: DEFAULT_COMPRESS,
  };

  function $(id) { return document.getElementById(id); }
  function msgOf(e) {
    if (!e) return '未知错误';
    var m = (e.message !== undefined) ? String(e.message) : String(e);
    if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
    return String(m);
  }

  function status(msg) { var el = $('status-msg'); if (el) el.textContent = String(msg); }

  function reportError(text, err) {
    status(text);
    if (typeof console !== 'undefined') console.error(text, err);
  }

  // 面板与渲染里抛出的异常必须可见:症状"按了没反应"最难查,而静默捕获更糟。
  function guard(label, fn) {
    var out;
    try { out = fn(); }
    catch (e) { reportError('出错了(' + label + '):' + msgOf(e), e); return null; }
    // thenable ⇒ 挂收口并交回已收口的 promise:调用方 await 也好、完全不接也好,
    //   都不会再冒"未处理的 promise 拒绝"(那条全局通道只会说"有个 promise 被拒了",
    //   不说是谁 —— 而这条说的是"哪个入口").
    if (out && typeof out.then === 'function') {
      return out.then(null, function (e) {
        reportError('出错了(' + label + '):' + msgOf(e), e);
      });
    }
    return out;
  }

  function nameFromFile(fileName) {
    return String(fileName == null ? '' : fileName).replace(/\.(?:cyrm|txt)$/i, '');
  }
  var TOOL_LABELS = { brush: '画笔', rect: '矩形', bucket: '油漆桶', eraser: '橡皮',
                      line: '直线', select: '选框', picker: '吸管', gradient: '渐变',
                      'respawn-1': '放侧 1 复活点', 'respawn-2': '放侧 2 复活点' };
  var TOOLS = Object.keys(TOOL_LABELS);
  var RESPAWN_SIDES = { 'respawn-1': 1, 'respawn-2': 2 };
  var DERIVED_TEXTURES = [22];

  // ── 尺寸与纹理的硬上限(闸 1:一律钳制,不报错回滚)──
  // 唯一的造图入口。Core.createMap 不判 400×300 上限(它只要求正整数),
  //    所以输入 99999 的那条路必须在这里被 Core.clampMapSize 截住(A8 的原样复发形态:
  //    旧编辑器的 clampMin 第三参是"非数字时的默认值",根本没有上限)。
  function createEmptyMap(name, w, h) {
    var c = Core.clampMapSize(w, h);
    return Core.createMap(Core.sanitizeName(name), c.w, c.h);
  }
  // 纹理号必须同时避开两个坑:0(空气,没有贴图)与超出图集容量(越界会抛)。
  // 上界派生自图集(列 × 行,换图集就变):调用方不传就自己问 Render。
  //    容量 < 1(= 图集还没加载 / 一块都放不下 / 畸形图集算出的负数)一律当"没有信息"
  //    ⇒ 只给 1,不是放宽到描述符位宽那个上界 —— tint 的越界判据是"图集里有没有
  //    这一块",放宽等于把越界号直接放进 tileFor(它抛,而且每帧同一处抛一屏)。
  function clampTexture(tex, atlasCap) {
    var t = parseInt(tex, 10);
    if (!isFinite(t) || t < 1) t = 1;
    var cap = (atlasCap === undefined || atlasCap === null) ? Render.atlasCapacity()
                                                            : parseInt(atlasCap, 10);
    if (!isFinite(cap) || cap < 1) cap = 1;
    return Math.max(1, Math.min(cap, t));
  }
  function texturePalette(defs) {
    if (!defs || !defs.tiles) return [];
    var out = [];
    Object.keys(defs.tiles).forEach(function (k) {
      var tex = parseInt(k, 10);
      if (!isFinite(tex) || tex <= 0) return;
      if (DERIVED_TEXTURES.indexOf(tex) >= 0) return;
      var t = defs.tiles[k] || {};
      out.push({ tex: tex, name: t.name ? String(t.name) : ('纹理 ' + tex),
                 type: t.type ? String(t.type) : '' });
    });
    out.sort(function (a, b) { return a.tex - b.tex; });
    return out;
  }
  function validateLines(report) {
    var out = [];
    var r = report || { errors: [], warnings: [] };
    (r.errors || []).forEach(function (e) { out.push('✖ ' + e); });
    (r.warnings || []).forEach(function (w) { out.push('⚠ ' + w); });
    return out;
  }

  function inRect(r, x, y, W, H) { return !r || Render.inSel(r, x, y, W, H); }
  function idxOf(map, X, Y) {
    return Render.wrapIdx(Y, map.subRows) * map.subCols + Render.wrapIdx(X, map.subCols);
  }
  // 两种单位(格 / 子格)的换算只此一处:region.unit === 'cell' ⇒ 每格 16 个子格。
  function regionCells(map, region, clip, outline = false) {
    var out = [], seen = new Set();
    function add(X, Y) {
      var wx = Render.wrapIdx(X, map.subCols), wy = Render.wrapIdx(Y, map.subRows);
      if (!inRect(clip, wx, wy, map.subCols, map.subRows)) return;   // C12:选区约束绘制(环面)
      var i = wy * map.subCols + wx;
      if (seen.has(i)) return;
      seen.add(i); out.push(i);
    }
    var k = Core.SUB_PER_CELL;
    if (region.unit === 'cell') {
      for (var cy = region.y0; cy <= region.y1; cy++) {
        for (var cx = region.x0; cx <= region.x1; cx++) {
          if (outline && cx !== region.x0 && cx !== region.x1 && cy !== region.y0 && cy !== region.y1) continue;
          for (var qy = 0; qy < k; qy++) {
            for (var qx = 0; qx < k; qx++) add(cx * k + qx, cy * k + qy);
          }
        }
      }
    } else {
      for (var y = region.y0; y <= region.y1; y++) {
        for (var x = region.x0; x <= region.x1; x++) {
          if (!outline || x === region.x0 || x === region.x1 || y === region.y0 || y === region.y1) add(x, y);
        }
      }
    }
    return out;
  }
  function strokePoints(from, to) {
    var pts = [];
    if (!to || (from.x === to.x && from.y === to.y)) { pts.push(from); return pts; }
    var cells = Core.lineCells(Math.floor(from.x), Math.floor(from.y),
                               Math.floor(to.x), Math.floor(to.y));
    for (var i = 0; i < cells.length; i++) pts.push({ kind: from.kind, x: cells[i][0], y: cells[i][1] });
    return pts;
  }
  function lineTargets(map, a, b, clip, width) {
    var {lo, hi} = Core.brushOffsets(width);
    var out = new Set();
    for (var [x, y] of Core.lineCells(a.x, a.y, b.x, b.y)) {
      var region = {unit: 'sub', x0: x - lo, y0: y - lo, x1: x + hi, y1: y + hi};
      for (var cell of regionCells(map, region, clip)) out.add(cell);
    }
    return Array.from(out);
  }
  function toSub(hit) {
    var k = Core.SUB_PER_CELL;
    return hit.kind === 'cell' ? { x: hit.x * k, y: hit.y * k } : { x: hit.x, y: hit.y };
  }

  function constrainLine(a, b, shift) {
    var bx = Math.floor(b.x), by = Math.floor(b.y);
    if (!shift) return { x: bx, y: by };
    var dx = b.x - a.x, dy = b.y - a.y;
    var adx = Math.abs(dx), ady = Math.abs(dy);
    if (adx >= 2 * ady) return { x: bx, y: Math.floor(a.y) };          // 近水平 → 锁水平
    if (ady >= 2 * adx) return { x: Math.floor(a.x), y: by };          // 近垂直 → 锁垂直
    var m = Math.max(adx, ady);                                        // 其余 → 45°
    return { x: Math.floor(a.x + (dx < 0 ? -m : m)), y: Math.floor(a.y + (dy < 0 ? -m : m)) };
  }
  function constrainSquare(a, b, shift) {
    var bx = Math.floor(b.x), by = Math.floor(b.y);
    if (!shift) return { x: bx, y: by };
    var dx = b.x - a.x, dy = b.y - a.y;
    var m = Math.max(Math.abs(dx), Math.abs(dy));
    return { x: Math.floor(a.x + (dx < 0 ? -m : m)), y: Math.floor(a.y + (dy < 0 ? -m : m)) };
  }

  function paintCells(map, L, indices, valueOf) {
    return Edits.cells(map, L, function (arr, write) {
      for (var index of indices) write(index, valueOf(arr[index]));
    });
  }
  function valueFor(st, L) {
    if (L === Core.LAYER_BG) return function () { return st.rgba >>> 0; };
    if (st.descOnly) {
      // "只改辅码":空气仍是空气(不能凭空长出纹理),有纹理的保留原纹理、只换辅码。
      //   少了这一支,整片墙"变暗"的操作会把墙换成画笔当前选的那个纹理。
      return function (oldV) {
        if (oldV === 0 || Core.texOf(oldV) === 0) return oldV;
        return Core.packDesc(Core.texOf(oldV), Core.hueOf(st.desc), Core.brightOf(st.desc),
                             Core.satOf(st.desc), Core.alphaOf(st.desc));
      };
    }
    return function () { return st.desc >>> 0; };
  }
  function pickAt(map, L, X, Y) { return Render.descAt(map, L, X, Y); }

  // 一次工具操作 → 一条差量(没有改动就返回 null)。bucket / gradient / select 不走这里。
  function applyTool(st, tool, from, to) {
    var map = st.map, L = st.layer, clip = st.selection || null;
    var idx = null;
    if (tool === 'brush' || tool === 'eraser') {
      var pts = strokePoints(from, to), seen = new Set();
      idx = [];
      for (var i = 0; i < pts.length; i++) {
        var reg = Render.brushRegion(pts[i], st.brushSize);
        var list = regionCells(map, reg, clip);
        for (var k2 = 0; k2 < list.length; k2++) {
          if (seen.has(list[k2])) continue;
          seen.add(list[k2]); idx.push(list[k2]);
        }
      }
    } else if (tool === 'rect') {
      idx = regionCells(map, {
        unit: from.kind,
        x0: Math.min(from.x, to.x), y0: Math.min(from.y, to.y),
        x1: Math.max(from.x, to.x), y1: Math.max(from.y, to.y),
      }, clip, st.outline);
    } else if (tool === 'line') {
      idx = lineTargets(map, toSub(from), toSub(to), clip, st.lineWidth);
    }
    if (!idx) return null;
    return paintCells(map, L, idx, tool === 'eraser' ? () => 0 : valueFor(st, L));
  }

  // 环面四邻域填充，遍历结束时队列正好包含所有要涂的子格。
  function createBucketJob(map, L, X, Y, opts) {
    opts = opts || {};
    var arr = Core.layerArray(map, L);
    var cols = map.subCols, rows = map.subRows;
    var sx = Render.wrapIdx(Math.floor(X), cols), sy = Render.wrapIdx(Math.floor(Y), rows);
    var seedVal = arr ? arr[sy * cols + sx] : 0;
    var queue = [sy * cols + sx];
    var seen = new Set(queue);
    var head = 0;
    function runChunk(maxSteps) {
      var end = head + maxSteps;
      while (head < queue.length && head < end) {
        var i = queue[head++];
        var x = i % cols, y = Math.floor(i / cols);
        for (var k = 0; k < 4; k++) {
          var nx = Render.wrapIdx(x + (k === 0 ? 1 : k === 1 ? -1 : 0), cols);
          var ny = Render.wrapIdx(y + (k === 2 ? 1 : k === 3 ? -1 : 0), rows);
          var ni = ny * cols + nx;
          if (seen.has(ni)) continue;
          if (!inRect(opts.clip, nx, ny, cols, rows)) continue;   // 选区内外是两块互不连通的地
          if (arr && arr[ni] !== seedVal) continue;
          seen.add(ni); queue.push(ni);
        }
      }
      return { done: head === queue.length, total: head };
    }
    return { runChunk, result: queue };
  }

  function lerpRGBA(v0, v1, t) {
    var a = v0 >>> 0, b = v1 >>> 0;
    var ch = function (shift) {
      var x = (a >>> shift) & 255, y = (b >>> shift) & 255;
      return Math.round(x + (y - x) * t) & 255;
    };
    return (((ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0)) >>> 0);
  }
  function createGradientJob(map, a, b, rgba0, rgba1, opts) {
    opts = opts || {};
    var L = (opts.layer === undefined) ? Core.LAYER_BG : opts.layer;
    if (L !== Core.LAYER_BG) {
      throw new Error('渐变只能用在背景层(规格 §4.4):实得图层 ' + L);
    }
    if (!Core.layerArray(map, L)) {
      throw new Error('这张图的背景层不存在(layer_flags 缺位),渐变无处可写');
    }
    var dx = Math.floor(b.x) - Math.floor(a.x), dy = Math.floor(b.y) - Math.floor(a.y);
    var ax = Math.floor(a.x), ay = Math.floor(a.y);
    var len2 = dx * dx + dy * dy;
    var cols = map.subCols, rows = map.subRows;
    var totalCells = cols * rows;
    var out = [];
    var head = 0;
    function runChunk(maxSteps) {
      var end = Math.min(head + maxSteps, totalCells);
      while (head < end) {
        var i = head++;
        var X = i % cols, Y = (i - X) / cols;
        if (!inRect(opts.clip, X, Y, cols, rows)) continue;   // 选区约束(与 regionCells 同一条判据)
        var t = len2 === 0 ? 0 : ((X - ax) * dx + (Y - ay) * dy) / len2;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        out.push({ i, rgba: lerpRGBA(rgba0, rgba1, t) });
      }
      return { done: head === totalCells, total: out.length };
    }
    return { runChunk, result: out };
  }

  // 出生点、敌人与团队复活点使用新的数组，历史持有上一个数组。
  function toggleRespawn(map, side, hit) {
    var p = toSub(hit), k = Core.SUB_PER_CELL;
    var x = Math.floor(p.x / k), y = Math.floor(p.y / k);
    var atCell = r => r.x === x && r.y === y;
    var remove = map.respawns.some(r => r.side === side && atCell(r));
    var respawns = map.respawns.filter(r => !atCell(r));
    if (!remove) respawns.push({side, x, y});
    return Edits.replace(map, {respawns});
  }
  function clearRespawns(map, side) {
    var keep = map.respawns.filter(r => r.side !== side);
    return keep.length === map.respawns.length ? null : Edits.replace(map, {respawns: keep});
  }

  // ── 改尺寸(与 A8/A10 同源)──
  function resizeMap(map, w, h) {
    var out = createEmptyMap(map.name, w, h);          // ← 尺寸闸只在这一条路上
    var copyW = Math.min(map.subCols, out.subCols), copyH = Math.min(map.subRows, out.subRows);
    for (var L = 0; L < Core.LAYER_COUNT; L++) {
      var src = Core.layerArray(map, L), dst = Core.layerArray(out, L);
      if (!src) { out.layers[L] = null; continue; }
      for (var y = 0; y < copyH; y++) {
        var start = y * map.subCols;
        dst.set(src.subarray(start, start + copyW), y * out.subCols);
      }
    }
    out.comments = map.comments.slice();
    var dropped = [];
    var cellsW = Core.cellsWOf(out), cellsH = Core.cellsHOf(out);
    var inRange = function (p) { return p.x >= 0 && p.y >= 0 && p.x < cellsW && p.y < cellsH; };
    for (const [field, kind] of [['players', 'player'], ['enemies', 'enemy'], ['respawns', 'respawn']]) {
      out[field] = map[field].filter(point => {
        if (inRange(point)) return true;
        const {slot, ...position} = point;
        dropped.push({kind, ...position});
        return false;
      });
    }
    return { map: out, dropped: dropped, size: { w: cellsW, h: cellsH } };
  }
  // A10 要求的是"提示并清理"而不是"静默清理" —— 这一行就是那个提示的文案。
  function resizeReportLines(dropped) {
    return (dropped || []).map(function (d) {
      var label = '出生点';
      if (d.kind === 'enemy') label = '敌人 ' + d.type;
      if (d.kind === 'respawn') label = '侧 ' + d.side + ' 复活点';
      return label + '落在图外 (' + d.x + ',' + d.y + ')，已移除';
    });
  }
  // 尺寸统一经 resizeMap 钳制，输入框回显实际地图尺寸。
  function sizeInputsSync() {
    if (!app.map) return;
    var w = $('size-w'), h = $('size-h');
    if (w) w.value = String(Core.cellsWOf(app.map));
    if (h) h.value = String(Core.cellsHOf(app.map));
  }
  function sizeInputNum(el) {
    if (!el) return null;
    var n = parseInt(String(el.value == null ? '' : el.value), 10);
    return isFinite(n) ? n : null;
  }
  function dropStaleSelection() {
    if (!app.r || !app.map) return false;
    var sel = app.r.selection();
    if (!sel) return false;
    if (sel.x + sel.w <= app.map.subCols && sel.y + sel.h <= app.map.subRows) return false;
    app.r.setSelection(null);
    return true;
  }
  function applySize() {
    if (app.fileBusy || app.drawing) return;
    if (!app.map) { status('先打开一张地图'); return null; }
    var wEl = $('size-w'), hEl = $('size-h');
    var curW = Core.cellsWOf(app.map), curH = Core.cellsHOf(app.map);
    // 未输入有效数字的维度保留当前尺寸，其余值钳制到合法范围。
    var wNum = sizeInputNum(wEl), hNum = sizeInputNum(hEl);
    var c = Core.clampMapSize(wNum === null ? curW : wNum, hNum === null ? curH : hNum);
    var ig = [];
    if (wNum === null) ig.push('宽保留 ' + curW);
    if (hNum === null) ig.push('高保留 ' + curH);
    var igTxt = ig.length ? (';' + ig.join(',') + '(那一格是空的或不是数字 ⇒ 这一项不改)') : '';
    if (c.w === curW && c.h === curH) {
      sizeInputsSync();                     // 钳制结果照样回显(输 99999 → 框里变 400)
      status('尺寸没变(' + c.w + '×' + c.h + '),没有改动地图' + igTxt);
      return null;
    }
    var out = resizeMap(app.map, c.w, c.h);
    var edit = Edits.resize(app.map, out.map);
    var selDropped = dropStaleSelection();
    var paint = pushAndShow(edit);
    var lines = resizeReportLines(out.dropped);
    status('尺寸改为 ' + out.size.w + '×' + out.size.h + ' 格' +
           (lines.length ? '，已清理越界项 ' + lines.join('，') : '') +
           igTxt +
           (selDropped ? '，已清除越界选区' : ''));
    return paint;
  }

  var KEY_TOOLS = { b: 'brush', e: 'eraser', g: 'bucket', l: 'line', m: 'select', i: 'picker' };
  // 事件目标是不是一个"正在打字"的控件(评审发现 4)。判据取 tagName 与 isContentEditable,
  // 不取 ev.target === document.activeElement 之类:合成事件 / 焦点在 body 时 target 就是
  // body,那样的判据会把"按在画布上"也判成输入(热键整个失灵,而症状是"什么键都没反应")。
  function isTypingTarget(el) {
    if (!el || typeof el !== 'object') return false;
    var t = String(el.tagName == null ? '' : el.tagName).toLowerCase();
    if (t === 'input' || t === 'textarea' || t === 'select') return true;
    return el.isContentEditable === true;
  }
  function commandFor(ev) {
    var e = ev || {};
    var k = String(e.key == null ? '' : e.key).toLowerCase();
    var mod = e.ctrlKey || e.metaKey;
    if (mod) {
      if (k === 'z') return e.shiftKey ? 'redo' : 'undo';
      if (k === 'y') return 'redo';
      if (k === 'c') return 'copy';
      if (k === 'x') return 'cut';
      if (k === 'v') return 'paste';
      if (k === 's') return e.shiftKey ? 'save-as' : 'save';
      return null;
    }
    if (KEY_TOOLS[k]) return 'tool:' + KEY_TOOLS[k];
    if (k === 'r') return 'guides';
    if (k === 'h') return 'mirror:h';
    if (k === 'v') return 'mirror:v';
    if (k === '[') return 'brush-smaller';
    if (k === ']') return 'brush-bigger';
    if (k >= '0' && k <= '9') return 'layer:' + k;
    if (k === 'delete' || k === 'backspace') return 'clear-selection';
    if (k === 'escape') return 'cancel-selection';
    if (k === 'arrowleft' || k === 'arrowright' || k === 'arrowup' || k === 'arrowdown') {
      return 'pan:' + k.slice(5);
    }
    return null;
  }

  // ── 剪贴板(跨图层粘贴只允许"纹理 ↔ 纹理")──
  function copyRegion(map, L, sel) {
    if (!sel) return null;
    var arr = Core.layerArray(map, L);
    var values = new Uint32Array(sel.w * sel.h);
    if (arr) {
      for (var y = 0; y < sel.h; y++) {
        for (var x = 0; x < sel.w; x++) values[y * sel.w + x] = arr[idxOf(map, sel.x + x, sel.y + y)];
      }
    }
    return { kind: Core.LAYER_KINDS[L], w: sel.w, h: sel.h, values: values };
  }

  // 环绕后的每个目标只写一次，扫描范围最多是一张图。
  function visitRegion(map, x0, y0, region, visit) {
    var w = Math.min(region.w, map.subCols), h = Math.min(region.h, map.subRows);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) visit(idxOf(map, x0 + x, y0 + y), x, y);
    }
  }

  function pasteRegion(map, L, clip, X, Y) {
    if (!clip) return { ok: false, why: '剪贴板是空的' };
    if (L === Core.LAYER_BG && clip.kind !== 'color') {
      return { ok: false, why: '剪贴板是纹理层内容,不能粘到背景层(两种数据类型不互转)' };
    }
    if (L !== Core.LAYER_BG && clip.kind !== 'tex') {
      return { ok: false, why: '剪贴板是背景层的颜色,不能粘到纹理层' };
    }
    var diff = Edits.cells(map, L, function (_, write) {
      visitRegion(map, Math.floor(X), Math.floor(Y), clip, function (index, x, y) {
        write(index, clip.values[y * clip.w + x]);
      });
    });
    return { ok: true, diff: diff };
  }

  function moveRegion(map, L, sel, dx, dy) {
    if (!sel) return null;
    return Edits.cells(map, L, function (arr, write) {
      var targets = new Set();
      visitRegion(map, sel.x + dx, sel.y + dy, sel, function (index, x, y) {
        targets.add(index);
        write(index, arr[idxOf(map, sel.x + x, sel.y + y)]);
      });
      visitRegion(map, sel.x, sel.y, sel, function (index) {
        if (!targets.has(index)) write(index, 0);
      });
    });
  }

  function mirrorRegion(map, L, sel, axis) {
    if (!sel) return null;
    if (axis !== 'h' && axis !== 'v') {
      throw new Error('镜像轴非法(只能是 h 水平 / v 垂直):实得 ' + String(axis));
    }
    return Edits.cells(map, L, function (arr, write) {
      visitRegion(map, sel.x, sel.y, sel, function (index, x, y) {
        var sx = axis === 'h' ? sel.w - 1 - x : x;
        var sy = axis === 'v' ? sel.h - 1 - y : y;
        write(index, arr[idxOf(map, sel.x + sx, sel.y + sy)]);
      });
    });
  }

  function mirrorSelection(axis) {
    var sel = app.r.selection();
    if (!sel) { status('先框选一块,再按 H(水平)/ V(垂直)镜像'); return null; }
    var diff = mirrorRegion(app.map, app.r.layer(), sel, axis);
    if (!diff) { status('镜像:选区内容没变(这条轴上是回文),没有改动地图'); return null; }
    pushAndShow(diff);
    status('已' + (axis === 'h' ? '水平' : '垂直') + '镜像选区(' +
           (sel.w / Core.SUB_PER_CELL) + '×' + (sel.h / Core.SUB_PER_CELL) + ' 格)');
    return diff;
  }

  // ── 交互(指针 / 滚轮 / 热键)──
  // 写格产生的差量用于撤销和局部重画。
  var undoHistory = null;
  var clipboard = null;

  var dirty = false;
  function renderSaveState() {
    var el = $('st-save');
    if (!el) return;
    if (app.db && lastAutoSaveAt) {
      el.textContent = '已自动保存 ' + new Date(lastAutoSaveAt).toLocaleTimeString();
      return;
    }
    el.textContent = dirty ? '未保存' : '已保存';
  }

  function setCompression(on) {
    app.compress = on;
    var el = $('opt-compress');
    if (el) el.checked = on;
  }
  function encodeForWrite(map) {
    return Io.encodeMap(map, { compress: app.compress });
  }

  function pushAndShow(diff) {
    if (!diff) return;
    undoHistory.push(diff);
    return afterStateChange(diff);
  }
  function travelHistory(dir) {
    const edit = undoHistory.step(app.map, dir);
    if (edit) return afterStateChange(edit);
    status(dir < 0 ? '没有可撤销的操作' : '没有可重做的操作');
    return null;
  }
  function afterStateChange(e) {
    var paint;
    markDirty();
    if (e.kind === 'whole') {
      if (dropStaleSelection()) status('已清除越界选区');
      paint = app.r.invalidateAll();
      refreshStatus();
    } else if (e.kind === 'cells') {
      paint = app.r.editCells(e.layer, e.idx);
    } else {
      app.r.render();
      refreshStatus();
    }
    statusLine();
    return paint;
  }
  function runJob(label, job, apply) {
    return guard(label, async () => {
      app.drawing = true;
      try {
        await Render.createSlicer().runWhile(() => {
          const {done, total} = job.runChunk(2048);
          if (!done) status(label + ' … ' + total);
          return !done;
        });
        await apply(job.result);
      } finally {
        app.drawing = false;
      }
    });
  }
  function statusLine() {
    if (!app.map) return;
    var set = function (id, txt) { var el = $(id); if (el) el.textContent = txt; };
    var tool = app.st.tool, detail = '';
    if (tool === 'line') detail = ' · ' + $('line-width').value + ' 子格';
    if (tool === 'rect') detail = ' · ' + $('rect-mode').selectedOptions[0].textContent;
    if (tool === 'brush' || tool === 'eraser') detail = ' × ' + app.st.brushSize;
    set('st-tool', '工具 ' + TOOL_LABELS[tool] + detail);
    set('st-tex', '纹理 ' + Core.texOf(app.st.desc));
    set('st-desc', '辅码 ' + Core.hueOf(app.st.desc) + '/' + Core.brightOf(app.st.desc) + '/' +
                   Core.satOf(app.st.desc) + '/' + Core.alphaOf(app.st.desc));
    var sel = app.r.selection();
    set('st-sel', sel ? ('选区 ' + (sel.w / Core.SUB_PER_CELL) + '×' + (sel.h / Core.SUB_PER_CELL) + ' 格') : '无选区');
    set('st-undo', '撤销 ' + undoHistory.depth() + ' / 重做 ' + undoHistory.redoDepth());
    renderSaveState();                // 每落一笔都要跟着翻(状态栏是"现在"的样子)
  }

  function hitOf(ev, inside = false) {
    var cv = app.canvas;
    var rect = cv.getBoundingClientRect();
    var x = ev.clientX - rect.left, y = ev.clientY - rect.top;
    if (inside && !app.r.containsPoint(x, y)) return null;
    var p = app.r.screenToSub(x, y);
    // 两种单位的吸附只在 hitOf 里决定一次:整数画笔吸附到格、小数画笔吸附到子格
    var unit = Render.brushSpan(app.st.brushSize).unit;
    var k = Core.SUB_PER_CELL;
    return unit === 'sub' ? { kind: 'sub', x: p.X, y: p.Y }
                          : { kind: 'cell', x: Math.floor(p.X / k), y: Math.floor(p.Y / k) };
  }
  function stNow() {
    return { map: app.map, layer: app.r.layer(), desc: app.st.desc, rgba: app.st.rgba,
             rgba2: app.st.rgba2, brushSize: app.st.brushSize, selection: app.r.selection(),
             descOnly: app.st.descOnly, outline: $('rect-mode').value === 'outline',
             lineWidth: Number($('line-width').value) };
  }
  function subRectOf(from, to) {
    var k = Core.SUB_PER_CELL;
    var a = toSub(from), b = toSub(to);
    return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y),
             w: Math.abs(b.x - a.x) + k, h: Math.abs(b.y - a.y) + k };
  }

  function gestureEnd(gesture, hit, shift) {
    if (gesture.kind === 'select') {
      return { kind: 'sub', ...constrainSquare(toSub(gesture.from), toSub(hit), shift) };
    }
    if (gesture.kind === 'stroke' && app.st.tool === 'line') {
      return { kind: 'sub', ...constrainLine(toSub(gesture.from), toSub(hit), shift) };
    }
    return hit;
  }

  function runCommand(cmd) {
    if (app.fileBusy || app.drawing) return;
    if (cmd === 'guides') return $('tg-guides').click();
    if (cmd.startsWith('tool:')) {
      app.st.tool = cmd.slice(5);
      return selectToolButton();
    }
    if (cmd === 'brush-smaller' || cmd === 'brush-bigger') {
      return setBrush(bumpBrush(app.st.brushSize, cmd === 'brush-smaller' ? -1 : 1));
    }
    if (cmd.startsWith('layer:')) return setLayer(Number(cmd.slice(6)));
    if (!app.map) return;
    if (cmd === 'save' || cmd === 'save-as') return fileAction('保存', () => saveCurrent(cmd === 'save-as'));
    if (cmd === 'undo') return travelHistory(-1);
    if (cmd === 'redo') return travelHistory(1);
    if (cmd.startsWith('pan:')) return arrowPan(cmd.slice(4));
    if (cmd === 'cancel-selection') {
      if (app.gesture?.kind === 'move') app.gesture = null;
      app.r.setSelDrag(null, 0, 0);
      app.r.setSelection(null);
      return statusLine();
    }
    var L = app.r.layer(), sel = app.r.selection();
    if (cmd !== 'copy' && !canEditLayer(L)) return;
    if (cmd.startsWith('mirror:')) return mirrorSelection(cmd.slice(7));
    if (cmd === 'paste') {
      var at = sel || { x: 0, y: 0 };
      var out = pasteRegion(app.map, L, clipboard, at.x, at.y);
      if (!out.ok) return status('粘贴失败：' + out.why);
      pushAndShow(out.diff);
      if (sel) app.r.setSelection({x: at.x, y: at.y, w: clipboard.w, h: clipboard.h});
      return statusLine();
    }
    if (!sel) return status('先框选一块');
    if (cmd === 'copy' || cmd === 'cut') {
      clipboard = copyRegion(app.map, L, sel);
      if (!clipboard) return status('当前图层没有可复制的内容');
      if (cmd === 'copy') return status('已复制 ' + clipboard.w + '×' + clipboard.h);
    }
    return pushAndShow(applyTool({map: app.map, layer: L, desc: 0, rgba: 0, brushSize: 0.25, selection: sel},
      'rect', {kind: 'sub', x: sel.x, y: sel.y}, {kind: 'sub', x: sel.x + sel.w - 1, y: sel.y + sel.h - 1}));
  }
  function beginGesture(ev, spaceDown) {
    if (ev.button === 1 || ev.altKey || (spaceDown && ev.button === 0)) {
      app.gesture = { kind: 'pan', x: ev.clientX, y: ev.clientY };
      return;
    }
    if (ev.button !== 0) return;
    var hit = hitOf(ev, true);
    if (!hit) return;
    var tool = app.st.tool, layer = app.r.layer();
    if (RESPAWN_SIDES[tool]) return pushAndShow(toggleRespawn(app.map, RESPAWN_SIDES[tool], hit));
    if (tool === 'select') {
      var sub = toSub(hit), sel = app.r.selection();
      var moving = sel && inRect(sel, sub.x, sub.y, app.map.subCols, app.map.subRows);
      app.gesture = moving ? { kind: 'move', from: hit, dx: 0, dy: 0 } : { kind: 'select', from: hit };
      return;
    }
    if (tool === 'picker') {
      var rect = app.canvas.getBoundingClientRect();
      var p = app.r.screenToSub(ev.clientX - rect.left, ev.clientY - rect.top);
      var value = pickAt(app.map, layer, p.X, p.Y) >>> 0;
      if (layer === Core.LAYER_BG) app.st.rgba = value;
      else if (Core.texOf(value) !== 0) app.st.desc = value;
      status('吸管:0x' + value.toString(16) + (Core.texOf(value) === 0 ? '(空气,未采用)' : ''));
      return statusLine();
    }
    if (!canEditLayer(layer)) return;
    if (tool === 'bucket') {
      var st = stNow(), at = toSub(hit);
      var job = createBucketJob(st.map, layer, at.x, at.y, { clip: st.selection });
      return runJob('油漆桶填充', job, indices =>
        pushAndShow(paintCells(st.map, layer, indices, valueFor(st, layer))));
    }
    if (tool === 'gradient' && layer !== Core.LAYER_BG) {
      return status('渐变只能用在背景层(它改的是颜色,不是纹理)');
    }
    app.gesture = { kind: tool === 'gradient' ? 'gradient' : 'stroke', from: hit, last: null };
  }

  function updateGesture(ev) {
    var gesture = app.gesture;
    if (!gesture) return;
    if (gesture.kind === 'pan') {
      var dx = ev.clientX - gesture.x, dy = ev.clientY - gesture.y;
      gesture.x = ev.clientX;
      gesture.y = ev.clientY;
      return app.r.panBy(dx, dy);
    }
    var hit = hitOf(ev);
    if (gesture.kind === 'move') {
      var from = toSub(gesture.from), to = toSub(hit);
      gesture.dx = to.x - from.x;
      gesture.dy = to.y - from.y;
      return app.r.setSelDrag(app.r.selection(), gesture.dx, gesture.dy);
    }
    if (gesture.kind === 'stroke') {
      if (!canEditLayer(app.r.layer())) return;
      var tool = app.st.tool;
      if (tool === 'brush' || tool === 'eraser') {
        pushAndShow(applyTool(stNow(), tool, gesture.last || gesture.from, hit));
        gesture.last = hit;   // 单击在松手时落笔，拖动已在这里落笔。
        return;
      }
    }
    app.r.setPreview(subRectOf(gesture.from, gestureEnd(gesture, hit, ev.shiftKey)));
  }

  function finishGesture(ev) {
    var gesture = app.gesture;
    app.gesture = null;
    if (!gesture || gesture.kind === 'pan') return;
    var layer = app.r.layer();
    if (gesture.kind === 'move') {
      app.r.setSelDrag(null, 0, 0);
      var sel = app.r.selection();
      if (sel && (gesture.dx || gesture.dy) && canEditLayer(layer)) {
        pushAndShow(moveRegion(app.map, layer, sel, gesture.dx, gesture.dy));
        app.r.setSelection({ x: Render.wrapIdx(sel.x + gesture.dx, app.map.subCols),
                             y: Render.wrapIdx(sel.y + gesture.dy, app.map.subRows),
                             w: sel.w, h: sel.h });
      }
      return statusLine();
    }
    app.r.setPreview(null);
    var from = gesture.from, to = gestureEnd(gesture, hitOf(ev), ev.shiftKey);
    if (gesture.kind === 'select') {
      app.r.setSelection(subRectOf(from, to));
      return statusLine();
    }
    if (gesture.kind === 'gradient') {
      var st = stNow();
      var job = createGradientJob(st.map, toSub(from), toSub(to), st.rgba, st.rgba2, { clip: st.selection });
      return runJob('渐变', job, cells => pushAndShow(Edits.cells(st.map, Core.LAYER_BG, (_, write) => {
        for (const cell of cells) write(cell.i, cell.rgba);
      })));
    }
    if (!canEditLayer(layer)) return;
    var tool = app.st.tool;
    var shape = tool === 'rect' || tool === 'line';
    if (shape || !gesture.last) {
      return pushAndShow(applyTool(stNow(), tool, from, shape ? to : from));
    }
  }

  function installInteraction() {
    var cv = app.canvas;
    undoHistory = Edits.history();
    var spaceDown = false;
    app.st = { tool: 'brush', brushSize: 1, desc: Core.neutralDesc(1),
               rgba: 0xFF00FFFF, rgba2: 0x101820FF, descOnly: false };

    cv.addEventListener('contextmenu', function (e) { e.preventDefault(); });
    cv.addEventListener('pointerdown', function (ev) {
      if (app.fileBusy || app.drawing || !app.map) return;
      if (cv.setPointerCapture) cv.setPointerCapture(ev.pointerId);
      guard('pointerdown', () => beginGesture(ev, spaceDown));
    });
    cv.addEventListener('pointermove', (ev) => guard('pointermove', () => updateGesture(ev)));
    cv.addEventListener('pointerup', (ev) => guard('pointerup', () => finishGesture(ev)));

    cv.addEventListener('wheel', function (ev) {
      guard('wheel', function () {
        ev.preventDefault();
        var rect = cv.getBoundingClientRect();
        // 视图入口的 promise 同样收口(见上面 pointermove 的说明)
        var zp = app.r.setZoomAt(ev.clientX - rect.left, ev.clientY - rect.top,
                                ev.deltaY < 0 ? 1.25 : 0.8);
        statusLine();
        return zp;
      });
    }, { passive: false });

    window.addEventListener('keydown', function (ev) {
      if (isTypingTarget(ev.target)) return;
      if (ev.key === ' ') { spaceDown = true; ev.preventDefault(); return; }
      var cmd = commandFor(ev);
      if (!cmd) return;
      ev.preventDefault();
      guard('编辑操作', () => runCommand(cmd));
    });
    window.addEventListener('keyup', function (ev) {
      if (ev.key !== ' ') return;
      spaceDown = false;                  // 清位与"认不认领"无关:键已经抬起来了
      if (isTypingTarget(ev.target)) return;
      ev.preventDefault();
    });
    window.addEventListener('blur', function () { spaceDown = false; });

    statusLine();
  }

  var BRUSH_STEPS = [0.25, 0.5, 0.75, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
  function bumpBrush(cur, dir) {
    var i = BRUSH_STEPS.indexOf(cur);
    if (i < 0) i = 3;
    return BRUSH_STEPS[Math.max(0, Math.min(BRUSH_STEPS.length - 1, i + dir))];
  }
  function clampBrushSize(v) {
    return Math.max(0.25, Math.min(Render.MAX_BRUSH_CELLS, v));
  }
  function setBrush(v) {
    app.st.brushSize = clampBrushSize(v);
    var el = $('brush-size');
    if (el) el.value = String(app.st.brushSize);
    statusLine();
  }
  function arrowPan(dir) {
    var step = 64;
    var d = { left: [-step, 0], right: [step, 0], up: [0, -step], down: [0, step] }[dir];
    if (!d) return null;
    return app.r.panBy(d[0], d[1]);
  }
  function selectToolButton() {
    document.querySelectorAll('.tool[data-tool]').forEach(function (b) {
      var selected = b.dataset.tool === app.st.tool;
      b.classList.toggle('on', selected);
      b.setAttribute('aria-pressed', String(selected));
    });
    for (var options of document.querySelectorAll('[data-tool-options]')) {
      options.hidden = options.dataset.toolOptions !== app.st.tool;
    }
    statusLine();
  }
  function setLayer(L) {
    if (!(L >= 0 && L < Core.LAYER_COUNT)) return;
    app.r.setLayer(L);
    document.querySelectorAll('#layers .layer-row').forEach(function (row) {
      row.classList.toggle('cur', parseInt(row.dataset.layer, 10) === L);
    });
    if (typeof syncPanelForLayer === 'function') syncPanelForLayer();
    statusLine();
  }

  function fileAction(label, action) {
    if (app.fileBusy || app.drawing || ['stroke', 'select', 'move'].includes(app.gesture?.kind)) return;
    return guard(label, async () => {
      app.fileBusy = true;
      syncFileControls();
      try { return await action(); }
      finally {
        app.fileBusy = false;
        syncFileControls();
      }
    });
  }

  function fileStem(name) {
    return nameFromFile(name).replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 64) || 'map';
  }

  function askName(title, stem, newMap = false) {
    var dialog = $('file-dialog'), size = $('new-size'), input = $('file-stem');
    $('file-dialog-title').textContent = title;
    size.hidden = size.disabled = !newMap;
    $('new-width').value = $('size-w').value || DEFAULT_CELLS_W;
    $('new-height').value = $('size-h').value || DEFAULT_CELLS_H;
    input.value = stem;
    dialog.returnValue = '';
    return new Promise(resolve => {
      dialog.addEventListener('close', () => {
        resolve(dialog.returnValue === 'ok' ? {
          name: input.value + '.cyrm', w: Number($('new-width').value), h: Number($('new-height').value),
        } : null);
      }, {once: true});
      dialog.showModal();
      input.select();
    });
  }

  function showReport(title, lines) {
    $('report-title').textContent = title;
    $('report-text').textContent = lines.join('\n');
    $('report-dialog').showModal();
  }

  function identifyDocument(name, bytes, format, inLibrary) {
    app.name = name;
    app.raw = bytes;
    app.sourceFormat = format;
    app.inLibrary = inLibrary;
    app.map.name = nameFromFile(name);
    app.documentKey = app.files.scope +
      (inLibrary ? '' : 'import:' + Core.crc32(bytes) + ':') + app.map.name;
  }

  async function showDocument(map, name, bytes, format, inLibrary, draft = null) {
    var report = Core.validateMap(map);
    if (report.errors.length) throw new Error(report.errors.join('，'));
    app.map = map;
    identifyDocument(name, bytes, format, inLibrary);
    if (draft) app.documentKey = draft.key;
    undoHistory.clear();
    draftSavedRev = draftRev;
    lastAutoSaveAt = draft ? draft.savedAt : 0;
    dirty = !!draft;
    await app.r.setMap(map);
    if (!inLibrary && !draft) markDirty();
    refreshStatus(report);
    statusLine();
  }

  function closeDocument() {
    app.map = app.name = app.raw = null;
    app.inLibrary = dirty = false;
    app.documentKey = '';
    undoHistory.clear();
    draftSavedRev = draftRev;
    lastAutoSaveAt = 0;
    app.r.setMap(null);
    refreshStatus();
    statusLine();
  }

  async function newMap() {
    var input = await askName('新建地图', 'new_map', true);
    if (!input) return;
    var map = createEmptyMap(nameFromFile(input.name), input.w, input.h);
    var bytes = await encodeForWrite(map);
    await flushDraft();
    var out = await app.files.write(input.name, bytes, {create: true});
    await showDocument(map, input.name, bytes, 'v4', true);
    await refreshLibrary();
    status((out.download ? '已下载 ' : '已新建 ') + input.name);
  }

  async function saveCurrent(asNew) {
    var name = app.name, create = asNew || !app.inLibrary;
    if (asNew || !MapFiles.NAME_PATTERN.test(name)) {
      var input = await askName('另存为', fileStem(name));
      if (!input) return;
      name = input.name;
      create = true;
    }
    var backup = !create && app.sourceFormat !== 'v4';
    if (backup && !window.confirm('将 ' + name + ' 转成 CYRM v4 并备份原文。继续保存？')) return;
    var key = app.documentKey;
    var bytes = await encodeForWrite(app.map);
    var out = await app.files.write(name, bytes, {create, backup});
    identifyDocument(name, bytes, 'v4', true);
    dirty = false;
    await markDraftSaved(key);
    refreshStatus();
    await refreshLibrary();
    status((out.download ? '已下载 ' : '已保存 ') + name + (out.backup ? ' · 原文备份 ' + out.backup : ''));
  }

  async function duplicateMap() {
    var names = new Set((await app.files.list()).map(file => file.name.toLowerCase()));
    var stem = fileStem(app.name), name, i = 1;
    do {
      var suffix = i === 1 ? '_copy' : '_copy_' + i;
      name = stem.slice(0, 64 - suffix.length) + suffix + '.cyrm';
      i++;
    } while (names.has(name.toLowerCase()));
    var map = structuredClone(app.map);
    var bytes = await encodeForWrite(map);
    await flushDraft();
    var out = await app.files.write(name, bytes, {create: true});
    await showDocument(map, name, bytes, 'v4', true);
    await refreshLibrary();
    status((out.download ? '已下载 ' : '已复制为 ') + name);
  }

  async function renameCurrent() {
    var input = await askName('重命名', fileStem(app.name));
    if (!input || input.name === app.name) return;
    var key = app.documentKey;
    await app.files.rename(app.name, input.name);
    identifyDocument(input.name, app.raw, app.sourceFormat, true);
    await markDraftSaved(key);
    if (dirty) markDirty();
    refreshStatus();
    await refreshLibrary();
    status('已重命名为 ' + app.name);
  }

  async function deleteCurrent() {
    var name = app.name;
    if (!window.confirm('从' + app.files.label + '删除 ' + name + '？')) return;
    await app.files.remove(name);
    await markDraftSaved(app.documentKey);
    closeDocument();
    await refreshLibrary();
    status('已删除 ' + name);
  }

  async function exportCurrent() {
    var name = fileStem(app.name) + '.cyrm';
    MapFiles.download(name, await encodeForWrite(app.map));
    status('已导出 ' + name);
  }

  async function checkCurrent() {
    var report = Core.validateMap(app.map), lines = validateLines(report);
    if (!MapFiles.NAME_PATTERN.test(app.name)) lines.push('当前文件名需要通过「另存为」调整');
    if (!report.errors.length) {
      try {
        var bytes = await encodeForWrite(app.map);
        lines.push('CYRM v4 编码成功，' + bytes.length + ' 字节');
      } catch (e) { lines.push('编码失败：' + msgOf(e)); }
    }
    showReport('地图校验', lines);
  }

  async function selfTest() {
    var map = Core.createMap('selftest', 1, 1);
    map.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(1);
    await Io.ping();
    var reopened = await Io.decodeMap(await encodeForWrite(map));
    if (reopened.layers[Core.LAYER_SCENE].desc[0] !== map.layers[Core.LAYER_SCENE].desc[0]) {
      throw new Error('Worker 编解码结果不一致');
    }
    showReport('编辑器自检', ['Worker 编解码通过', '草稿盘：' + (app.db ? '已连接' : '不可用'),
                             '当前地图库：' + app.files.label]);
  }
  var DRAFT_DB = 'cyrm-editor';
  var DRAFT_STORE = 'draft';
  var CRASH_STORE = 'crash';
  var DRAFT_DB_VERSION = 2;
  var DRAFT_TIME_INDEX = 'savedAt';
  var UI_STATE_KEY = 'cyrm.ui.v1';       // 带版本号:将来换字段可以让老的那份自然失效
  var MAX_LIB = 60;
  var DRAFT_DEBOUNCE_MS = 1500;          // 最后一笔之后多久落盘(不是每笔都写)
  var UI_SAVE_THROTTLE_MS = 500;
  function draftKey(name) { return Core.sanitizeName(nameFromFile(name)); }
  // ── 第 3 层:localStorage 小状态(读损坏值一律回落默认:编辑器要能开)──
  function uiStateDefaults() {
    return { ...Render.VIEW_DEFAULTS, layer: Core.LAYER_SCENE, zoom: 0, tool: 'brush', brushSize: 1,
             visible: [true, true, true, true], locked: [false, false, false, false],
             compress: DEFAULT_COMPRESS, panelOpen: { lib: true, right: true },
             playerRef: { cx: 0, cy: 0, visible: false }, selectedTexture: 1 };
  }

  function readUiState(store) {
    var state = uiStateDefaults(), saved;
    try { saved = JSON.parse(store?.[UI_STATE_KEY] || 'null'); }
    catch (_) { return state; }
    if (!saved || typeof saved !== 'object') return state;
    if (saved.layer >= 0 && saved.layer < Core.LAYER_COUNT) state.layer = saved.layer | 0;
    if (isFinite(saved.zoom)) state.zoom = Render.clampZoom(saved.zoom);
    if (TOOLS.includes(saved.tool)) state.tool = saved.tool;
    if (isFinite(saved.brushSize) && saved.brushSize > 0) state.brushSize = clampBrushSize(saved.brushSize);
    for (var key of [...Object.keys(VIEW_CONTROLS), 'compress']) {
      if (typeof saved[key] === 'boolean') state[key] = saved[key];
    }
    for (var key of ['visible', 'locked']) {
      if (Array.isArray(saved[key]) && saved[key].length === Core.LAYER_COUNT) {
        state[key] = saved[key].map((value, i) => typeof value === 'boolean' ? value : state[key][i]);
      }
    }
    for (var key of ['lib', 'right']) {
      if (typeof saved.panelOpen?.[key] === 'boolean') state.panelOpen[key] = saved.panelOpen[key];
    }
    if (saved.playerRef && typeof saved.playerRef === 'object') {
      var pr = saved.playerRef;
      if (isFinite(pr.cx)) state.playerRef.cx = Math.floor(pr.cx);
      if (isFinite(pr.cy)) state.playerRef.cy = Math.floor(pr.cy);
      state.playerRef.visible = pr.visible === true;
    }
    // 纹理上界在图集载入后校验。
    if (isFinite(saved.selectedTexture) && saved.selectedTexture > 0) {
      state.selectedTexture = Math.floor(saved.selectedTexture);
    }
    return state;
  }

  function writeUiState(store, uist) {
    try { store.setItem(UI_STATE_KEY, JSON.stringify(uist)); }
    catch (e) { /* 私密模式/配额满:UI 小状态丢了不影响作品,静默 */ }
  }
  // 取 localStorage 这件事本身在私密模式下就可能抛(不是只有 setItem 会)——
  //   收在一处,读与写的调用方都不必各自 try。
  function localStore() {
    try {
      return (typeof window !== 'undefined' && window.localStorage) ? window.localStorage : null;
    } catch (e) { return null; }
  }

  function openDraftStore() {
    return new Promise(function (resolve) {
      if (typeof indexedDB === 'undefined') { resolve(null); return; }
      var req;
      try { req = indexedDB.open(DRAFT_DB, DRAFT_DB_VERSION); } catch (e) { resolve(null); return; }
      req.onupgradeneeded = function () {
        var db = req.result;
        // 按保存时间清理最旧的草稿。
        var st = db.objectStoreNames.contains(DRAFT_STORE)
          ? req.transaction.objectStore(DRAFT_STORE)
          : db.createObjectStore(DRAFT_STORE, { keyPath: 'key' });
        if (!st.indexNames.contains(DRAFT_TIME_INDEX)) {
          st.createIndex(DRAFT_TIME_INDEX, 'savedAt');
        }
        if (!db.objectStoreNames.contains(CRASH_STORE)) db.createObjectStore(CRASH_STORE, { keyPath: 'key' });
      };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { resolve(null); };
      req.onblocked = function () { resolve(null); };
    });
  }
  function idbPut(db, store, rec) {
    return new Promise(function (resolve, reject) {
      var tx = db.transaction(store, 'readwrite');
      tx.objectStore(store).put(rec);
      tx.oncomplete = function () { resolve(true); };
      tx.onerror = function () { reject(tx.error || new Error('IndexedDB 写失败')); };
      tx.onabort = function () { reject(tx.error || new Error('IndexedDB 写被中止')); };
    });
  }
  function idbGetOne(db, store, key) {
    return new Promise((resolve, reject) => {
      var tx = db.transaction(store, 'readonly');
      var request = tx.objectStore(store).get(key);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      tx.onabort = () => reject(tx.error);
    });
  }
  var draftTimer = null;
  var draftRev = 0;              // 地图每次变动 +1(判"这一版写过没有")
  var draftSavedRev = -1;        // 上一次草稿落盘时的 rev
  var lastAutoSaveAt = 0;        // 状态栏那一格要显示的自动保存时刻(0 = 本局还没自动存过)

  function markDirty() {
    dirty = true;
    draftRev++;
    scheduleDraftSave();
  }
  var draftWrite = Promise.resolve();

  function scheduleDraftSave() {
    if (!app.db) return;
    clearTimeout(draftTimer);
    draftTimer = setTimeout(() => {
      draftTimer = null;
      saveDraft().catch(error => reportError('草稿保存失败：' + msgOf(error), error));
    }, DRAFT_DEBOUNCE_MS);
  }

  async function flushDraft(recover = false) {
    clearTimeout(draftTimer);
    draftTimer = null;
    if (!app.db || !dirty) return;
    var key = app.documentKey;
    await saveDraft();
    if (recover && dirty && key === app.documentKey) {
      await idbPut(app.db, CRASH_STORE, {key: 'crash', draftKey: key});
    }
  }

  function saveDraft() {
    var job = draftWrite.then(async () => {
      if (!dirty || draftRev <= draftSavedRev) return;
      var rev = draftRev, map = app.map, key = app.documentKey, name = app.name;
      var bytes = await encodeForWrite(map);
      if (!dirty || app.map !== map || app.documentKey !== key) return;
      var savedAt = Date.now();
      await idbPut(app.db, DRAFT_STORE, {key, name, bytes, savedAt, dirty: true});
      draftSavedRev = rev;
      lastAutoSaveAt = savedAt;
      renderSaveState();
      await pruneDrafts().catch(error => reportError('草稿已保存，清理失败：' + msgOf(error), error));
    });
    // 后续草稿仍可保存，当前调用者收到本次写入的错误。
    draftWrite = job.catch(() => {});
    return job;
  }

  async function markDraftSaved(key) {
    await draftWrite;
    draftSavedRev = draftRev;
    lastAutoSaveAt = 0;
    if (!app.db) return;
    try {
      var rec = await idbGetOne(app.db, DRAFT_STORE, key);
      if (rec) await idbPut(app.db, DRAFT_STORE, {...rec, dirty: false});
    } catch (error) {
      reportError('文件操作已完成，更新草稿状态失败：' + msgOf(error), error);
    }
  }
  function pruneDrafts() {
    return new Promise((resolve, reject) => {
      var tx = app.db.transaction(DRAFT_STORE, 'readwrite');
      var store = tx.objectStore(DRAFT_STORE);
      var count = store.count();
      var removed = 0;
      count.onsuccess = () => {
        var excess = count.result - MAX_LIB;
        if (excess <= 0) return;
        removed = excess;
        var oldestUnsaved = [];
        var request = store.index(DRAFT_TIME_INDEX).openCursor();
        request.onsuccess = () => {
          var cursor = request.result;
          if (!cursor) {
            for (var key of oldestUnsaved.slice(0, excess)) store.delete(key);
            return;
          }
          if (!cursor.value.dirty) {
            cursor.delete();
            if (--excess === 0) return;
          } else if (oldestUnsaved.length < excess) {
            oldestUnsaved.push(cursor.primaryKey);
          }
          cursor.continue();
        };
      };
      tx.oncomplete = () => {
        if (removed) status('已清理 ' + removed + ' 条最旧草稿');
        resolve();
      };
      tx.onabort = () => reject(tx.error);
    });
  }
  async function offerDraft() {
    if (!app.db || !app.map) return;
    var key = app.documentKey;
    var rec = await idbGetOne(app.db, DRAFT_STORE, key);
    var oldKey = draftKey(app.name);
    if (!rec && app.inLibrary && app.files === homeFiles && oldKey !== key) {
      var old = await idbGetOne(app.db, DRAFT_STORE, oldKey);
      if (old && old.name === app.name) {
        rec = {...old, key};
        await idbPut(app.db, DRAFT_STORE, rec);
        await idbPut(app.db, DRAFT_STORE, {...old, dirty: false});
      }
    }
    if (!rec || !rec.dirty || sameBytes(rec.bytes, app.raw)) return;
    if (window.confirm('发现未保存的草稿（' + new Date(rec.savedAt).toLocaleString() + '），要恢复吗？')) {
      await restoreDraft(rec);
    }
  }

  async function restoreDraft(rec) {
    var sameDocument = app.documentKey === rec.key;
    var map = await Io.decodeMap(rec.bytes);
    await showDocument(map, rec.name, sameDocument ? app.raw : rec.bytes,
      sameDocument ? app.sourceFormat : 'v4', sameDocument && app.inLibrary, rec);
    status('已恢复草稿 ' + rec.name);
  }
  // 逐字节相同(长度先过;两边都可能是 Uint8Array,也可能有一个是 null —— 那就不相同)
  function sameBytes(a, b) {
    if (!a || !b || a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  // ── UI 小状态(第 3 层):恢复与落盘 ──
  function setViewToggle(key, on) {
    var control = $(VIEW_CONTROLS[key]);
    if (control?.type === 'checkbox') control.checked = on;
    else if (control) control.classList.toggle('on', on);
    return app.r.setViewOption(key, on);
  }

  async function applyUiState() {
    var u = app.uist;
    // 打开地图后恢复缩放，0 表示沿用自动适配。
    var cur = app.r.view().zoom;
    if (app.map && u.zoom > 0 && cur > 0 && Math.abs(u.zoom - cur) > 1e-6) {
      await app.r.setZoomAt(app.canvas.width / 2, app.canvas.height / 2, u.zoom / cur);
    }
    setLayer(u.layer);
    for (var key of Object.keys(VIEW_CONTROLS)) await setViewToggle(key, u[key]);
    for (var L = 0; L < Core.LAYER_COUNT; L++) {
      app.r.setLayerVisible(L, u.visible[L]);
      app.r.setLayerLocked(L, u.locked[L]);
    }
    syncLayerButtons();
    app.st.tool = u.tool;
    setBrush(u.brushSize);
    if (u.selectedTexture > 0) {
      app.st.desc = Core.migrateDescriptor(Core.packDesc(clampTexture(u.selectedTexture, Render.atlasCapacity()),
                                  Core.hueOf(app.st.desc), Core.brightOf(app.st.desc),
                                  Core.satOf(app.st.desc), Core.alphaOf(app.st.desc)));
      if (!app.tileDefs.tiles[Core.texOf(app.st.desc)]) app.st.desc = Core.neutralDesc(1);
      $('desc-hue').value = String(Core.hueOf(app.st.desc));
      document.querySelectorAll('#palette .sw').forEach(function (b) {
        b.classList.toggle('on', Number(b.textContent) === Core.texOf(app.st.desc));
      });
    }
    setCompression(u.compress);
    selectToolButton();
  }

  var uiSaveTimer = null;
  function persistUi() {
    if (uiSaveTimer || !app.st) return;
    uiSaveTimer = setTimeout(function () {
      uiSaveTimer = null;
      var prev = app.uist || uiStateDefaults();
      app.uist = {
        ...prev, ...app.r.viewOptions(),
        layer: app.r.layer(), zoom: app.map ? app.r.view().zoom : prev.zoom, tool: app.st.tool,
        brushSize: app.st.brushSize, compress: app.compress,
        visible: Array.from({length: Core.LAYER_COUNT}, (_, L) => app.r.layerVisible(L)),
        locked: Array.from({length: Core.LAYER_COUNT}, (_, L) => app.r.layerLocked(L)),
        selectedTexture: Core.texOf(app.st.desc),
      };
      writeUiState(localStore(), app.uist);
    }, UI_SAVE_THROTTLE_MS);
  }

  // 绑定一律经 onWin:node 冒烟里 window 是 globalThis 而 globalThis 没有
  //   addEventListener(Node 24 实测),裸 window.addEventListener(...) 会在
  //   bootLoad() 的第一行就抛 —— 那会让"打开失败也要有面板"(⑭e)那条路一起红,
  //   而根因与面板毫无关系。
  function onWin(evt, fn, opts) {
    if (typeof window === 'undefined' || typeof window.addEventListener !== 'function') return;
    window.addEventListener(evt, fn, opts);
  }
  function installUiStateSave() {
    ['click', 'change', 'wheel', 'keyup', 'pointerup'].forEach(function (evt) {
      onWin(evt, persistUi, { passive: true });
    });
    onWin('pagehide', () => {
      persistUi();
      flushDraft().catch(error => reportError('草稿保存失败：' + msgOf(error), error));
    });
  }

  function installCrashRecovery() {
    function saveAfterError(error) {
      reportError('页面异常：' + msgOf(error), error);
      flushDraft(true).catch(failure => reportError('草稿保存失败：' + msgOf(failure), failure));
    }
    onWin('error', event => saveAfterError(event.error || event.message));
    onWin('unhandledrejection', event => saveAfterError(event.reason));
  }

  async function offerCrashDraft() {
    if (!app.db) return false;
    var marker = await idbGetOne(app.db, CRASH_STORE, 'crash');
    if (!marker || marker.declined) return false;
    var rec;
    if (marker.draftKey) {
      rec = await idbGetOne(app.db, DRAFT_STORE, marker.draftKey);
    } else {
      // 旧版快照自带字节。恢复时迁入草稿库，避免覆盖同名文件的草稿。
      rec = {key: 'recovery:' + marker.scope + marker.name, name: marker.name,
        bytes: marker.bytes, savedAt: marker.savedAt, dirty: true};
    }
    if (!rec || !rec.dirty) return false;
    var sameDocument = app.documentKey === rec.key;
    if (sameDocument && sameBytes(rec.bytes, app.raw)) return false;
    var confirmed = window.confirm('上次异常退出时保存了 ' + rec.name + ' 的草稿，要恢复吗？');
    if (confirmed) {
      if (!marker.draftKey) await idbPut(app.db, DRAFT_STORE, rec);
      await restoreDraft(rec);
    }
    await idbPut(app.db, CRASH_STORE, {key: 'crash', declined: true});
    return confirmed || sameDocument;
  }

  function canEditLayer(L) {
    if (app.r.layerLocked(L)) { status('当前图层已锁定'); return false; }
    if (!app.map.layers[L]) { status('当前地图缺少这一层'); return false; }
    return true;
  }

  function syncLayerButtons() {
    for (var row of document.querySelectorAll('#layers .layer-row')) {
      var L = Number(row.dataset.layer);
      var visible = app.r.layerVisible(L), locked = app.r.layerLocked(L);
      var vis = row.querySelector('.vis'), lock = row.querySelector('.lock');
      row.classList.toggle('absent', !!app.map && !app.map.layers[L]);
      vis.style.opacity = visible ? '1' : '0.35';
      vis.setAttribute('aria-pressed', String(visible));
      lock.textContent = locked ? '🔒' : '🔓';
      lock.setAttribute('aria-pressed', String(locked));
    }
  }

  function bindFileActions() {
    var actions = {
      'btn-new': newMap, 'btn-open-folder': openFolder, 'btn-server': () => switchLibrary(homeFiles),
      'btn-save': () => saveCurrent(false), 'btn-save-as': () => saveCurrent(true),
      'btn-dup': duplicateMap, 'btn-rename': renameCurrent, 'btn-del': deleteCurrent,
      'btn-export': exportCurrent, 'btn-check': checkCurrent, 'btn-selftest': selfTest,
    };
    for (const [id, action] of Object.entries(actions)) {
      var button = $(id);
      button.addEventListener('click', () => fileAction($(id).textContent, action));
    }
    for (const button of document.querySelectorAll('[data-command]')) {
      button.addEventListener('click', () => guard('编辑操作', () => runCommand(button.dataset.command)));
    }
    $('lib-list').addEventListener('click', ev => {
      var row = ev.target.closest('.lib-row');
      if (row) fileAction('打开地图', () => openMap(row.dataset.name));
    });
    var input = $('map-file');
    $('btn-open-file').addEventListener('click', () => input.click());
    input.addEventListener('change', () => {
      var file = input.files[0];
      input.value = '';
      if (file) fileAction('导入地图', () => openLocalFile(file));
    });
    $('cancel-file-dialog').addEventListener('click', () => $('file-dialog').close());
    syncFileControls();
  }

  function buildPanels() {
    document.querySelectorAll('#layers .layer-row').forEach(function (row) {
      var L = parseInt(row.dataset.layer, 10);
      row.addEventListener('click', function () { setLayer(L); });
      row.querySelector('.vis').addEventListener('click', function (ev) {
        ev.stopPropagation();
        var on = !app.r.layerVisible(L);
        app.r.setLayerVisible(L, on);
        syncLayerButtons();
      });
      row.querySelector('.lock').addEventListener('click', function (ev) {
        ev.stopPropagation();
        var on = !app.r.layerLocked(L);
        app.r.setLayerLocked(L, on);
        syncLayerButtons();
      });
    });
    var pal = texturePalette(app.tileDefs);
    var box = $('palette');
    var cols = Render.atlasInfo().width / Tint.BLOCK_PX;
    pal.forEach(function (e) {
      var b = document.createElement('button');
      b.className = 'sw';
      b.title = e.tex + ' ' + e.name + (e.type ? '(' + e.type + ')' : '');
      b.textContent = String(e.tex);
      var tile = e.tex - 1, size = Tint.BLOCK_PX;
      b.style.backgroundImage = 'url(' + JSON.stringify(atlasUrl()) + ')';
      b.style.backgroundPosition = -(tile % cols) * size + 'px ' + -Math.floor(tile / cols) * size + 'px';
      b.addEventListener('click', function () {
        app.st.desc = Core.packDesc(e.tex, Core.hueOf(app.st.desc), Core.brightOf(app.st.desc),
                                    Core.satOf(app.st.desc), Core.alphaOf(app.st.desc));
        document.querySelectorAll('#palette .sw').forEach(function (x) { x.classList.remove('on'); });
        b.classList.add('on');
        statusLine();
      });
      box.appendChild(b);
    });
    if (DERIVED_TEXTURES.length) {
      var hint = document.createElement('div');
      hint.className = 'desc-row';
      // 给它一个 id:它是 #palette 的派生行,背景层上必须跟着一起藏 —— 否则
      //    「纹理 22 不进调色板…」会孤零零浮在一个空面板底下(见 syncPanelForLayer)。
      hint.id = 'palette-hint';
      hint.textContent = '纹理 ' + DERIVED_TEXTURES.join('/') + ' 不进调色板:游戏侧由地形自动派生';
      box.parentNode.insertBefore(hint, box.nextSibling);
    }
    // 辅码四组档位
    [['desc-hue', 'hueOf'], ['desc-bri', 'brightOf'],
     ['desc-sat', 'satOf'], ['desc-alp', 'alphaOf']].forEach(function (spec) {
      var sel = $(spec[0]);
      if (!sel) return;
      for (var k = 0; k < Core.SUB_PER_CELL * 2; k++) {
        var o = document.createElement('option');
        o.value = String(k); o.textContent = String(k);
        sel.appendChild(o);
      }
      sel.value = String(Core[spec[1]](app.st.desc));
      sel.addEventListener('change', function () {
        app.st.desc = Core.packDesc(Core.texOf(app.st.desc), +$('desc-hue').value, +$('desc-bri').value,
                                    +$('desc-sat').value, +$('desc-alp').value);
        statusLine();
      });
    });
    var only = $('desc-only');
    if (only) only.addEventListener('change', function () { app.st.descOnly = only.checked; });
    var bs = $('brush-size');
    if (bs) {
      bs.addEventListener('change', function () { setBrush(parseFloat(bs.value) || 1); });
    }
    document.querySelectorAll('.tool[data-tool]').forEach(function (b) {
      b.addEventListener('click', function () { app.st.tool = b.dataset.tool; selectToolButton(); });
    });
    for (let key of Object.keys(VIEW_CONTROLS)) {
      let control = $(VIEW_CONTROLS[key]);
      if (!control) continue;
      let checkbox = control.type === 'checkbox';
      control.addEventListener(checkbox ? 'change' : 'click', () => guard(control.title || key,
        () => setViewToggle(key, checkbox ? control.checked : !app.r.viewOptions()[key])));
    }
    for (var id of ['rect-mode', 'line-width']) $(id).addEventListener('change', statusLine);
    for (var type of globalThis.ENEMY_REGISTRY) $('spawn-enemy-type').add(new Option(type.name, type.id));
    var p1 = $('spawn-p1'), p2 = $('spawn-p2'), en = $('spawn-enemy'), cl = $('spawn-clear');
    if (p1) p1.addEventListener('click', () => spawnAt(1));
    if (p2) p2.addEventListener('click', () => spawnAt(2));
    if (en) en.addEventListener('click', () => spawnAt());
    if (cl) cl.addEventListener('click', function () {
      guard('清空出生点', function () {
        if (!app.map) { status('先打开一张地图'); return null; }
        return pushAndShow(Edits.replace(app.map, {players: [], enemies: []}));
      });
    });
    document.querySelectorAll('[data-clear-respawn]').forEach(function (button) {
      button.addEventListener('click', function () {
        if (!app.map) { status('先打开一张地图'); return; }
        pushAndShow(clearRespawns(app.map, Number(button.dataset.clearRespawn)));
      });
    });
    // ── 画布尺寸面板(规格 A10)──
    // 与上面四个出生点按钮同款:没打开地图时说一句话,而不是把 resizeMap(null, …) 的
    //   TypeError 抛进 click 处理器(同一个面板里两种说法)。
    // 输入框里的回车也当"应用尺寸":两个数字框 + 一颗按钮的版式里,按回车什么都不发生
    //   是最容易被当成"坏了"的一种手感。
    var rsBtn = $('btn-resize');
    if (rsBtn) rsBtn.addEventListener('click', function () { guard('改尺寸', applySize); });
    ['size-w', 'size-h'].forEach(function (id) {
      var el = $(id);
      if (el) el.addEventListener('keydown', function (ev) {
        if (ev.key !== 'Enter') return;
        ev.preventDefault();
        guard('改尺寸', applySize);
      });
    });
    var cpBox = $('opt-compress');
    if (cpBox) cpBox.addEventListener('change', function () {
      setCompression(cpBox.checked);
      status(cpBox.checked ? '导出/保存:压缩(deflate)'
                           : '导出/保存:裸 body(compression=0;浏览器与 Godot 的 deflate 万一对不上,这条是退路)');
    });
    bindFileActions();
    [['bg-color', 'rgba'], ['bg-color2', 'rgba2']].forEach(function (spec) {
      var inp = $(spec[0]), lab = $(spec[0] + '-val');
      if (!inp) return;
      var m0 = /^#([0-9a-f]{6})$/i.exec(inp.value);
      if (m0) app.st[spec[1]] = (parseInt(m0[1], 16) * 256 + 255) >>> 0;
      inp.addEventListener('input', function () {
        var m = /^#([0-9a-f]{6})$/i.exec(inp.value);
        if (!m) return;
        app.st[spec[1]] = (parseInt(m[1], 16) * 256 + 255) >>> 0;
        if (lab) lab.textContent = inp.value;
        statusLine();
      });
    });
    selectToolButton();
    syncPanelForLayer();
    statusLine();
  }

  function syncPanelForLayer() {
    var isBg = (app.r.layer() === Core.LAYER_BG);
    var show = function (id, on) { var el = $(id); if (el) el.style.display = on ? '' : 'none'; };
    // 藏的是整行,不是控件的直接父节点:面板里各控件的父节点并不统一 —— 四个档位
    //    select 的父节点就是 .desc-row,而「只改辅码」那个 input 外面还包着一层 <label>
    //    ⇒ 直接写 parentNode 的话后者只藏掉 label,那一行仍占着位置(而且只读得出"少了个
    //    勾选框",看不出是故意的)。故一律向上找到 .desc-row。
    var hideRow = function (id, on) {
      var el = $(id);
      if (!el) return;
      var row = el;
      while (row && !(row.classList && row.classList.contains('desc-row'))) row = row.parentNode;
      if (row) row.style.display = on ? '' : 'none';
    };
    show('palette', !isBg);
    show('palette-hint', !isBg);       // 派生行跟着调色板走(见 buildPanels 里插它的那一段)
    show('bg-color-row', isBg);
    show('bg-color-row2', isBg);
    show('bg-color-title', isBg);
    ['desc-hue', 'desc-bri', 'desc-sat', 'desc-alp'].forEach(function (id) { hideRow(id, !isBg); });
    // 「只改辅码」与四个档位是同一组(它管的就是那四档),故同显同藏 —— 否则背景层上
    //   它会挂在一个已经没有别的控件的「辅码」区块里。
    hideRow('desc-only', !isBg);
    var titles = document.querySelectorAll('#right h2');
    for (var i = 0; i < titles.length; i++) {
      if (titles[i].textContent === '辅码') titles[i].style.display = isBg ? 'none' : '';
    }
    // 工具条上"渐变只在背景层可用":其余工具照旧(纹理层没有颜色可插值,故渐变只在背景层)
    var g = document.querySelector('.tool[data-tool="gradient"]');
    if (g) g.style.opacity = isBg ? '1' : '0.45';
  }

  function spawnAt(slot) {
    if (!app.map) { status('先打开一张地图'); return; }
    const v = app.r.view();
    const x = Render.wrapIdx(Math.round((v.x + app.canvas.width / v.zoom / 2) / Core.SUB_PER_CELL), Core.cellsWOf(app.map));
    const y = Render.wrapIdx(Math.round((v.y + app.canvas.height / v.zoom / 2) / Core.SUB_PER_CELL), Core.cellsHOf(app.map));
    if (slot) {
      const players = app.map.players.slice();
      const at = players.findIndex(p => p.slot === slot);
      players[at < 0 ? players.length : at] = {slot, x, y};
      pushAndShow(Edits.replace(app.map, {players}));
    } else {
      const enemy = {type: $('spawn-enemy-type').value, x, y};
      pushAndShow(Edits.replace(app.map, {enemies: [...app.map.enemies, enemy]}));
    }
    status((slot ? 'P' + slot : '敌人') + ' 放到 (' + x + ',' + y + ')');
  }

  function atlasUrl() {
    return globalThis.CYRM_OFFLINE ? globalThis.CYRM_OFFLINE.atlasUrl : 'structure.png';
  }

  function loadAtlas() {
    return new Promise(function (resolve, reject) {
      var img = new Image();
      img.onload = function () {
        var c = document.createElement('canvas');
        c.width = img.width; c.height = img.height;
        var g = c.getContext('2d', { willReadFrequently: true });
        g.drawImage(img, 0, 0);
        var d = g.getImageData(0, 0, img.width, img.height);
        Render.setAtlas(d.data, img.width, img.height);   // 同时作废 ③ 与 ④
        resolve({ width: img.width, height: img.height });
      };
      img.onerror = function () { reject(new Error('structure.png 加载失败')); };
      img.src = atlasUrl();
    });
  }

  async function openBytes(name, bytes, inLibrary, restore) {
    var out = await Io.importMap(bytes);
    await flushDraft();
    await showDocument(out.map, name, bytes, out.format, inLibrary);
    status((inLibrary ? '已打开 ' : '已导入 ') + name + (out.format === 'v4' ? '' : ' · 旧文本'));
    if (restore) await offerDraft();
  }

  async function openMap(name, restore = true) {
    await openBytes(name, await app.files.read(name), true, restore);
  }

  async function openLocalFile(file) {
    await openBytes(file.name, new Uint8Array(await file.arrayBuffer()), false, true);
  }

  async function directoryScope(handle) {
    var id = 'dir:' + crypto.randomUUID() + ':';
    if (!app.db) return id;
    // 浏览器只暴露目录名，通过句柄识别同名目录。
    var key = 'directories:' + handle.name;
    var record = await idbGetOne(app.db, CRASH_STORE, key);
    var entries = record ? record.entries : [];
    for (var entry of entries) {
      if (await handle.isSameEntry(entry.handle)) return entry.id;
    }
    entries.push({id, handle});
    await idbPut(app.db, CRASH_STORE, {key, entries});
    return id;
  }

  async function switchLibrary(files) {
    var rows = await files.list();
    await flushDraft();
    app.files = files;
    if (app.map) {
      identifyDocument(app.name, app.raw, app.sourceFormat, false);
      markDirty();
    }
    renderLibrary(rows);
    refreshStatus();
    status('地图库 · ' + files.label);
  }

  async function openFolder() {
    var handle;
    try { handle = await window.showDirectoryPicker({mode: 'readwrite'}); }
    catch (e) { if (e.name === 'AbortError') return; throw e; }
    await switchLibrary(MapFiles.directory(handle, await directoryScope(handle)));
  }

  function syncLibrarySelection() {
    document.querySelectorAll('#lib-list .lib-row').forEach(row => {
      row.classList.toggle('cur', app.inLibrary && row.dataset.name === app.name);
    });
  }

  function syncFileControls() {
    for (var button of document.querySelectorAll('[data-document]')) {
      button.disabled = app.fileBusy || !app.map;
    }
    $('btn-new').disabled = $('btn-open-file').disabled = app.fileBusy;
    $('btn-open-folder').disabled = app.fileBusy || typeof window.showDirectoryPicker !== 'function';
    $('btn-rename').disabled = app.fileBusy || !app.inLibrary || !app.files.rename;
    $('btn-del').disabled = app.fileBusy || !app.inLibrary || !app.files.remove;
    $('btn-server').hidden = !!globalThis.CYRM_OFFLINE || app.files === homeFiles;
    $('btn-server').disabled = app.fileBusy;
    $('right').inert = app.fileBusy;
    $('lib-list').inert = app.fileBusy;
  }

  function refreshStatus(report) {
    var m = app.map;
    $('empty-hint').hidden = !!m;
    syncLayerButtons();
    syncFileControls();
    syncLibrarySelection();
    if (!m) {
      $('st-name').textContent = '未打开地图';
      for (var id of ['st-size', 'st-tool', 'st-tex', 'st-desc', 'st-sel', 'st-undo', 'st-valid', 'st-save']) {
        $(id).textContent = '';
      }
      $('respawn-count').textContent = '侧 1 0 · 侧 2 0';
      return;
    }
    $('st-name').textContent = app.name;
    $('st-size').textContent = Core.cellsWOf(m) + '×' + Core.cellsHOf(m) + ' 格';
    var counts = [0, 0];
    for (var r of m.respawns) counts[r.side - 1]++;
    $('respawn-count').textContent = '侧 1 ' + counts[0] + ' · 侧 2 ' + counts[1];
    sizeInputsSync();
    var rep = report || Core.validateMap(m);
    $('st-valid').textContent = rep.errors.length ? '错误 ' + rep.errors.length
      : rep.warnings.length ? '⚠ ' + rep.warnings.length : '校验 OK';
    renderSaveState();
  }

  function renderLibrary(rows) {
    $('lib-backend').textContent = app.files.label;
    var list = $('lib-list');
    list.replaceChildren();
    if (!rows.length) { list.textContent = '库里没有地图'; return; }
    for (var file of rows) {
      var item = document.createElement('li');
      var button = document.createElement('button');
      button.className = 'lib-row';
      button.dataset.name = file.name;
      button.textContent = file.name;
      button.title = file.name + ' · ' + Math.ceil(file.size / 1024) + ' KiB';
      item.appendChild(button);
      list.appendChild(item);
    }
    syncLibrarySelection();
  }

  async function refreshLibrary() { renderLibrary(await app.files.list()); }

  async function openFromUrl() {
    await refreshLibrary();
    var name = new URLSearchParams(location.search).get('p');
    if (name) await openMap(name, false);
    else refreshStatus();
  }
  function boot() {
    app.canvas = $('map-canvas');
    if (!app.canvas) return;
    app.tileDefs = globalThis.TILE_DEFS || null;
    // 闸 3 没有降级路径 ⇒ 缺 Worker 时的唯一正确行为是把话说清楚(而不是静默退回主线程)
    if (!Io.workerAvailable()) {
      var b = $('boot-error');
      if (b) { b.hidden = false; b.textContent = '浏览器不支持 Web Worker，请换用支持 Worker 的浏览器。源码版请通过 serve.bat 打开；离线版请打开 cyrm-editor.html。'; }
      return;
    }
    app.r = Render.mount(app.canvas);
    installInteraction();
    var ro = new ResizeObserver(function () { guard('resize', function () { return app.r.resize(); }); });
    ro.observe(app.canvas.parentElement);
    var fitBtn = $('btn-fit');
    if (fitBtn) fitBtn.addEventListener('click', function () { guard('fit', function () { return app.r.fit(); }); });

    // 图集必须先就位(渲染第一帧就要它);失败要说出来,而不是画一片黑。
    bootLoad().catch(error => reportError('启动失败：' + msgOf(error), error));
  }

  async function bootLoad() {
    installCrashRecovery();
    app.uist = readUiState(localStore());
    app.db = await openDraftStore();
    if (!app.db) status('草稿盘不可用，请手动保存地图');
    await loadAtlas();
    buildPanels();
    await openFromUrl();
    try {
      if (!await offerCrashDraft()) await offerDraft();
    } catch (error) {
      reportError('恢复草稿失败：' + msgOf(error), error);
    }
    await applyUiState();
    installUiStateSave();
  }

  return {
    boot: boot, status: status, app: app,
    openMap: openMap, refreshLibrary: refreshLibrary,
  };
})();
