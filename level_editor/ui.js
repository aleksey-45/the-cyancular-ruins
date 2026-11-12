globalThis.Editor = (function () {
  'use strict';

  var Core = globalThis.Core, Render = globalThis.Render, Io = globalThis.Io;
  if (!Core) throw new Error('ui.js: 必须先加载 core.js');
  if (!Render) throw new Error('ui.js: 必须先加载 render.js');
  if (!Io) throw new Error('ui.js: 必须先加载 io.js');

  var DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;
  var homeFiles = globalThis.CYRM_OFFLINE ? MapFiles.downloads() : MapFiles.server();

  var app = {
    r: null, canvas: null, map: null, name: null,
    raw: null, tileDefs: null, files: homeFiles, inLibrary: false, fileBusy: false,
    sourceFormat: 'v4', documentKey: '', drawing: false,
  };

  function $(id) { return document.getElementById(id); }
  function nowMs() {
    return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
  }
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

  // ── 落笔:先读旧值、再写、产出一条差量 ──
  function paintCells(map, L, idx, valueOf) {
    var arr = Render.layerArray(map, L);
    if (!arr || !arr.length) return null;
    var changed = [], before = [], after = [], seen = new Set();
    for (var i = 0; i < idx.length; i++) {
      var k = idx[i];
      if (seen.has(k)) continue;
      seen.add(k);
      var oldV = arr[k], newV = valueOf(oldV) >>> 0;
      if (newV === oldV) continue;                        // 值没变就不进差量(撤销栈里不留空操作)
      changed.push(k); before.push(oldV); after.push(newV);
      arr[k] = newV;
    }
    if (!changed.length) return null;
    return { kind: 'cells', layer: L, idx: Int32Array.from(changed),
             before: Uint32Array.from(before), after: Uint32Array.from(after) };
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
    if (tool === 'picker' || tool === 'select' || tool === 'bucket' || tool === 'gradient') return null;
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
      if (tool === 'eraser') {
        return paintCells(map, L, idx, function () { return 0; });   // 两层都置空气(色层 = 黑)
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
    return paintCells(map, L, idx, valueFor(st, L));
  }

  // ── 油漆桶:跨环面连通填充(A14)+ 可分帧驱动(闸 2)──
  // 返回一个作业对象而不是一次性跑完:500×300 的地图跨环面时是 19.2 万格,
  // 同步跑完就是一次长阻塞。runChunk(maxSteps) 每次至多推进 maxSteps 个格子。
  function createBucketJob(map, L, X, Y, opts) {
    opts = opts || {};
    var arr = Render.layerArray(map, L);
    var cols = map.subCols, rows = map.subRows;
    var sx = Render.wrapIdx(Math.floor(X), cols), sy = Render.wrapIdx(Math.floor(Y), rows);
    var seedVal = arr ? arr[sy * cols + sx] : 0;
    var queue = [sy * cols + sx];
    var seen = new Set(queue);
    var out = [];
    var head = 0, done = false;
    function runChunk(maxSteps) {
      var n = 0;
      var lim = (maxSteps === undefined || maxSteps < 1) ? 1 : maxSteps;
      while (head < queue.length && n < lim) {
        var i = queue[head++];
        n++;
        out.push(i);
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
      if (head >= queue.length) done = true;
      return { done: done, scanned: n, total: out.length };
    }
    return { runChunk: runChunk, result: function () { return out.slice(); } };
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
    if (!Render.layerArray(map, L)) {
      throw new Error('这张图的背景层不存在(layer_flags 缺位),渐变无处可写');
    }
    var dx = Math.floor(b.x) - Math.floor(a.x), dy = Math.floor(b.y) - Math.floor(a.y);
    var ax = Math.floor(a.x), ay = Math.floor(a.y);
    var len2 = dx * dx + dy * dy;
    var cols = map.subCols, rows = map.subRows;
    var totalCells = cols * rows;
    var out = [];
    var head = 0, done = false;
    function runChunk(maxSteps) {
      var n = 0;
      var lim = (maxSteps === undefined || maxSteps < 1) ? 1 : maxSteps;
      while (head < totalCells && n < lim) {
        var X = head % cols, Y = (head - X) / cols;
        head++; n++;
        if (!inRect(opts.clip, X, Y, cols, rows)) continue;   // 选区约束(与 regionCells 同一条判据)
        var t = len2 === 0 ? 0 : ((X - ax) * dx + (Y - ay) * dy) / len2;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        out.push({ i: Y * cols + X, rgba: lerpRGBA(rgba0, rgba1, t) });
      }
      if (head >= totalCells) done = true;
      return { done: done, scanned: n, total: out.length };
    }
    return { runChunk: runChunk, result: function () { return out.slice(); } };
  }

  // ── 出生点、敌人与团队复活点──
  function snapshotSpawns(map) {
    return {
      players: map.players.map(p => ({...p})),
      enemies: map.enemies.map(function (e) { return { type: e.type, x: e.x, y: e.y }; }),
      respawns: map.respawns.map(function (r) { return { side: r.side, x: r.x, y: r.y }; }),
    };
  }
  function spawnDiff(before, after) {
    return { kind: 'spawn', before: before, after: after };
  }
  function spawnIndexAt(map, cellX, cellY, kind) {
    var x = Render.wrapIdx(Math.floor(cellX), Core.cellsWOf(map));
    var y = Render.wrapIdx(Math.floor(cellY), Core.cellsHOf(map));
    var i;
    if (kind !== 'enemy') {
      for (i = 0; i < map.players.length; i++) {
        if (map.players[i].x === x && map.players[i].y === y) return { kind: 'player', index: i };
      }
    }
    if (kind !== 'player') {
      for (i = 0; i < map.enemies.length; i++) {
        if (map.enemies[i].x === x && map.enemies[i].y === y) return { kind: 'enemy', index: i };
      }
    }
    return null;
  }
  function removeSpawn(map, kind, index) {
    var before = snapshotSpawns(map);
    if (kind === 'enemy') { if (index < 0 || index >= map.enemies.length) return null; map.enemies.splice(index, 1); }
    else { if (index < 0 || index >= map.players.length) return null; map.players.splice(index, 1); }
    return spawnDiff(before, snapshotSpawns(map));
  }
  function clearSpawns(map) {
    var before = snapshotSpawns(map);
    map.players = []; map.enemies = [];
    return spawnDiff(before, snapshotSpawns(map));
  }
  function toggleRespawn(map, side, hit) {
    var p = toSub(hit), k = Core.SUB_PER_CELL;
    var x = Math.floor(p.x / k), y = Math.floor(p.y / k);
    var before = snapshotSpawns(map);
    var atCell = r => r.x === x && r.y === y;
    var remove = map.respawns.some(r => r.side === side && atCell(r));
    map.respawns = map.respawns.filter(r => !atCell(r));
    if (!remove) map.respawns.push({ side: side, x: x, y: y });
    return spawnDiff(before, snapshotSpawns(map));
  }
  function clearRespawns(map, side) {
    var keep = map.respawns.filter(r => r.side !== side);
    if (keep.length === map.respawns.length) return null;
    var before = snapshotSpawns(map);
    map.respawns = keep;
    return spawnDiff(before, snapshotSpawns(map));
  }

  // ── 改尺寸(与 A8/A10 同源)──
  function resizeMap(map, w, h) {
    var out = createEmptyMap(map.name, w, h);          // ← 尺寸闸只在这一条路上
    var copyW = Math.min(map.subCols, out.subCols), copyH = Math.min(map.subRows, out.subRows);
    for (var L = 0; L < Core.LAYER_COUNT; L++) {
      var src = Render.layerArray(map, L), dst = Render.layerArray(out, L);
      if (!src) { out.layers[L] = null; continue; }    // 缺席层保持缺席(不是"补一层空的")
      for (var y = 0; y < copyH; y++) {
        for (var x = 0; x < copyW; x++) dst[y * out.subCols + x] = src[y * map.subCols + x];
      }
    }
    out.comments = map.comments.slice();
    var dropped = [];
    var cellsW = Core.cellsWOf(out), cellsH = Core.cellsHOf(out);
    var inRange = function (p) { return p.x >= 0 && p.y >= 0 && p.x < cellsW && p.y < cellsH; };
    var i;
    for (i = 0; i < map.players.length; i++) {
      if (inRange(map.players[i])) out.players.push({...map.players[i]});
      else dropped.push({ kind: 'player', x: map.players[i].x, y: map.players[i].y });
    }
    for (i = 0; i < map.enemies.length; i++) {
      var e = map.enemies[i];
      if (inRange(e)) out.enemies.push({ type: e.type, x: e.x, y: e.y });
      else dropped.push({ kind: 'enemy', type: e.type, x: e.x, y: e.y });
    }
    for (var r of map.respawns) {
      if (inRange(r)) out.respawns.push({ side: r.side, x: r.x, y: r.y });
      else dropped.push({ kind: 'respawn', side: r.side, x: r.x, y: r.y });
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
    var before = snapshotMap(app.map);
    var out = resizeMap(app.map, c.w, c.h);
    adoptMapInto(app.map, out.map);
    var after = snapshotMap(app.map);
    var selDropped = dropStaleSelection();
    var paint = pushAndShow({kind: 'whole', before, after,
      bytes: bytesOfSnapshot(before) + bytesOfSnapshot(after)});
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
  function hasSelection(st) { return !!(st && st.selection); }

  // ── 历史(差量撤销;闸 1:200 步 + 字节预算)──
  // 差量而不是整图快照:一张 125×75 的图是 2.4MB,200 份就是 480MB。
  // 但"改尺寸/换图"这类操作没法差量(table 级),故留一条整图快照的通道
  //   (kind:'whole'),并按字节记账 —— 字节预算才是真闸,步数只是廉价上界。
  var MAX_UNDO = 200;
  var MAX_UNDO_BYTES = 64 * 1024 * 1024;

  function spawnCount(s) { return s.players.length + s.enemies.length + s.respawns.length; }

  function bytesOfEntry(e) {
    if (!e) return 0;
    if (e.kind === 'cells') return 12 + e.idx.length * 4 + e.before.length * 4 + e.after.length * 4;
    if (e.kind === 'spawn') {
      return 64 + 32 * (spawnCount(e.before) + spawnCount(e.after));
    }
    if (e.kind === 'whole') return 64 + (e.bytes || 0);
    return 64;
  }

  function createHistory(opts) {
    opts = opts || {};
    var maxSteps = opts.maxSteps === undefined ? MAX_UNDO : opts.maxSteps;
    var maxBytes = opts.maxBytes === undefined ? MAX_UNDO_BYTES : opts.maxBytes;
    var undos = [], redos = [], total = 0;
    function trim() {
      while (undos.length > maxSteps) { total -= bytesOfEntry(undos.shift()); }
      // 至少留一条:一条都留不住时"撤销"这个功能就整体失效了(比多占几 MB 更糟)
      while (total > maxBytes && undos.length > 1) { total -= bytesOfEntry(undos.shift()); }
    }
    return {
      push: function (e) {
        if (!e) return false;                       // 空操作不进历史
        undos.push(e); total += bytesOfEntry(e);
        redos.length = 0;                           // 新编辑之后重做链断掉(标准语义)
        trim();
        return true;
      },
      undo: function () {
        if (!undos.length) return null;
        var e = undos.pop(); total -= bytesOfEntry(e);
        redos.push(e);
        return e;
      },
      redo: function () {
        if (!redos.length) return null;
        var e = redos.pop(); total += bytesOfEntry(e);
        undos.push(e);
        return e;
      },
      depth: function () { return undos.length; },
      redoDepth: function () { return redos.length; },
      bytes: function () { return total; },
      clear: function () { undos.length = 0; redos.length = 0; total = 0; },
    };
  }

  // 整图快照(只给"改尺寸/换图"这类整图级操作用)
  function snapshotMap(map) {
    var layers = [];
    for (var L = 0; L < Core.LAYER_COUNT; L++) {
      var lay = map.layers[L];
      if (!lay) { layers.push(null); continue; }
      layers.push(lay.kind === 'tex' ? { kind: 'tex', desc: new Uint32Array(lay.desc) }
                                     : { kind: 'color', rgba: new Uint32Array(lay.rgba) });
    }
    return { subCols: map.subCols, subRows: map.subRows, layers: layers,
             spawns: snapshotSpawns(map), comments: map.comments.slice() };
  }
  function bytesOfSnapshot(s) {
    var n = 32 * spawnCount(s.spawns);
    for (var L = 0; L < s.layers.length; L++) {
      var lay = s.layers[L];
      if (!lay) continue;
      n += (lay.kind === 'tex' ? lay.desc.length : lay.rgba.length) * 4;
    }
    return n;
  }
  // 改尺寸原地替换内容，整图历史持有同一个地图引用。
  function adoptMapInto(dst, src) {
    dst.subCols = src.subCols; dst.subRows = src.subRows;
    dst.layers = src.layers;
    dst.players = src.players; dst.enemies = src.enemies;
    dst.respawns = src.respawns;
    dst.comments = src.comments;
    return dst;
  }
  function applyEntry(map, e, dir) {
    var i;
    if (e.kind === 'cells') {
      var arr = Render.layerArray(map, e.layer);
      var src = dir < 0 ? e.before : e.after;
      for (i = 0; i < e.idx.length; i++) arr[e.idx[i]] = src[i];
      return;
    }
    if (e.kind === 'spawn') {
      Object.assign(map, snapshotSpawns(dir < 0 ? e.before : e.after));
      return;
    }
    if (e.kind === 'whole') {
      var s = dir < 0 ? e.before : e.after;
      map.subCols = s.subCols; map.subRows = s.subRows;
      // 恢复成可编辑的数组，保留撤销和重做所需的快照。
      map.layers = s.layers.map(function (lay) {
        if (!lay) return null;
        return lay.kind === 'tex' ? { kind: 'tex', desc: new Uint32Array(lay.desc) }
                                  : { kind: 'color', rgba: new Uint32Array(lay.rgba) };
      });
      Object.assign(map, snapshotSpawns(s.spawns));
      map.comments = s.comments.slice();
    }
  }
  // 差量 → 去重后的格坐标列表(交给 renderer.editCells 作废 ③ 与重画缩略图)
  function diffCells(map, e) {
    if (!e || e.kind !== 'cells') return [];
    var seen = new Set(), out = [];
    for (var i = 0; i < e.idx.length; i++) {
      var X = e.idx[i] % map.subCols, Y = Math.floor(e.idx[i] / map.subCols);
      var cx = Math.floor(X / Core.SUB_PER_CELL), cy = Math.floor(Y / Core.SUB_PER_CELL);
      var k = cx + '/' + cy;
      if (seen.has(k)) continue;
      seen.add(k); out.push({ cx: cx, cy: cy });
    }
    return out;
  }
  function cellCountOf(map, L) {
    var a = Render.layerArray(map, L);
    if (!a) return 0;
    var n = 0;
    for (var i = 0; i < a.length; i++) if (a[i] !== 0) n++;
    return n;
  }

  // ── 剪贴板(跨图层粘贴只允许"纹理 ↔ 纹理")──
  function copyRegion(map, L, sel) {
    if (!sel) return null;
    var arr = Render.layerArray(map, L);
    var n = sel.w * sel.h, x, y;
    if (L === Core.LAYER_BG) {
      var rgba = new Uint32Array(n);
      for (y = 0; y < sel.h; y++) {
        for (x = 0; x < sel.w; x++) rgba[y * sel.w + x] = arr ? arr[idxOf(map, sel.x + x, sel.y + y)] : 0;
      }
      return { kind: 'color', w: sel.w, h: sel.h, rgba: rgba };
    }
    var desc = new Uint32Array(n);
    for (y = 0; y < sel.h; y++) {
      for (x = 0; x < sel.w; x++) desc[y * sel.w + x] = arr ? arr[idxOf(map, sel.x + x, sel.y + y)] : 0;
    }
    return { kind: 'tex', w: sel.w, h: sel.h, desc: desc };
  }
  function clipSize(clip) { return clip ? { w: clip.w, h: clip.h } : { w: 0, h: 0 }; }
  // 决定 ④:两种数据类型不互相猜。拒绝时给出原因(状态栏要显示),不静默。
  function pasteRegion(map, L, clip, X, Y) {
    if (!clip) return { ok: false, why: '剪贴板是空的' };
    var isColorLayer = (L === Core.LAYER_BG);
    if (isColorLayer && clip.kind !== 'color') {
      return { ok: false, why: '剪贴板是纹理层内容,不能粘到背景层(两种数据类型不互转)' };
    }
    if (!isColorLayer && clip.kind !== 'tex') {
      return { ok: false, why: '剪贴板是背景层的颜色,不能粘到纹理层' };
    }
    var targets = [], values = [], x, y;
    for (y = 0; y < clip.h; y++) {
      for (x = 0; x < clip.w; x++) {
        targets.push(idxOf(map, Math.floor(X) + x, Math.floor(Y) + y));
        values.push(clip.kind === 'tex' ? clip.desc[y * clip.w + x] : clip.rgba[y * clip.w + x]);
      }
    }
    var order = 0;
    var diff = paintCells(map, L, targets, function () { return values[order++]; });
    return { ok: true, diff: diff };
  }

  function moveRegion(map, L, sel, dx, dy) {
    if (!sel) return null;
    var arr = Render.layerArray(map, L);
    if (!arr) return null;
    var from = new Map(), to = new Map();
    var x, y;
    for (y = 0; y < sel.h; y++) {
      for (x = 0; x < sel.w; x++) {
        var si = idxOf(map, sel.x + x, sel.y + y);
        var di = idxOf(map, sel.x + x + dx, sel.y + y + dy);
        from.set(si, true);
        to.set(di, arr[si]);                       // 一次性算出目标值(基于旧数组读)
      }
    }
    var keys = new Set();
    to.forEach(function (_, k) { keys.add(k); });
    from.forEach(function (_, k) { keys.add(k); });   // 源区里没被覆盖的格 → 写空气
    var idx = [], before = [], after = [];
    keys.forEach(function (k) {
      var nv = to.has(k) ? to.get(k) : 0;
      if (arr[k] === nv) return;
      idx.push(k); before.push(arr[k]); after.push(nv);
    });
    for (var i = 0; i < idx.length; i++) arr[idx[i]] = after[i];
    if (!idx.length) return null;
    return { kind: 'cells', layer: L, idx: Int32Array.from(idx),
             before: Uint32Array.from(before), after: Uint32Array.from(after), tag: 'move' };
  }

  function mirrorRegion(map, L, sel, axis) {
    if (!sel) return null;
    if (axis !== 'h' && axis !== 'v') {
      throw new Error('镜像轴非法(只能是 h 水平 / v 垂直):实得 ' + String(axis));
    }
    var arr = Render.layerArray(map, L);
    if (!arr) return null;
    var idx = [], before = [], after = [], x, y;
    for (y = 0; y < sel.h; y++) {
      for (x = 0; x < sel.w; x++) {
        var sx = (axis === 'h') ? (sel.w - 1 - x) : x;
        var sy = (axis === 'v') ? (sel.h - 1 - y) : y;
        var di = idxOf(map, sel.x + x, sel.y + y);
        var si = idxOf(map, sel.x + sx, sel.y + sy);
        if (arr[di] === arr[si]) continue;
        idx.push(di); before.push(arr[di]); after.push(arr[si]);
      }
    }
    for (var i = 0; i < idx.length; i++) arr[idx[i]] = after[i];
    if (!idx.length) return null;
    return { kind: 'cells', layer: L, idx: Int32Array.from(idx),
             before: Uint32Array.from(before), after: Uint32Array.from(after), tag: 'mirror' };
  }
  // 镜像当前选区(mirrorRegion 的生产入口:热键 H / V,以及以后可能加的按钮)。
  // 三条纪律各挡一种"看不见的坏":
  //    ① 非法轴 ⇒ mirrorRegion 抛中文错。它必须经 guard(页面上现有的那条报错
  //       通道)落到状态栏;而下面那句 if (out.threw) return; 是承重的 —— 少了它,
  //       紧接着的"没改动"文案会把刚写上去的错覆盖掉,用户看到的是一句
  //       「镜像:选区内容没变」,而真相是"这个轴名根本不存在"。
  //    ② 抛出的错绝不许进历史:历史只收 diff|null。一条 why 对象被 push 进去,
  //       撤销时 applyEntry 会拿它当差量读(字段全 undefined)⇒ 撤销静默失灵。
  //    ③ 什么都没变(mirrorRegion 回 null:单格选区、或者这条轴上是回文)不落历史 ——
  //       空差量进历史会让"撤销"按下去像没反应(撤销掉一条什么都没干的条目)。
  function mirrorSelection(axis) {
    var sel = app.r.selection();
    if (!sel) { status('先框选一块,再按 H(水平)/ V(垂直)镜像'); return null; }
    var out = { diff: null, threw: false };
    guard('镜像', function () {
      try { out.diff = mirrorRegion(app.map, app.r.layer(), sel, axis); }
      catch (e) { out.threw = true; throw e; }        // 上报给 sink(见 ①),但要先记下来
      return null;
    });
    if (out.threw) return null;                       // 状态栏上那句话是错的说明,别覆盖它
    if (!out.diff) { status('镜像:选区内容没变(这条轴上是回文),没有改动地图'); return null; }
    pushAndShow(out.diff);
    status('已' + (axis === 'h' ? '水平' : '垂直') + '镜像选区(' +
           (sel.w / Core.SUB_PER_CELL) + '×' + (sel.h / Core.SUB_PER_CELL) + ' 格)');
    return out.diff;
  }

  // ── 交互(指针 / 滚轮 / 热键)──
  // 一切落笔都走同一条路:applyTool(只碰地图)→ 差量进历史 → renderer.editCells
  //   (只碰缓存与像素)。把"改数据"与"作废缓存"分成两步是刻意的:漏了哪一半
  //   都能在断言里指名道姓。
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

  var DEFAULT_COMPRESS = true;
  function optCompress() {
    var el = $('opt-compress');
    return el ? !!el.checked : DEFAULT_COMPRESS;   // 控件不在(启动早期/替身)⇒ 按默认
  }
  function encodeForWrite(map) {
    return Io.encodeMap(map, { compress: optCompress() });
  }

  function pushAndShow(diff) {
    if (!diff) return;
    undoHistory.push(diff);
    return afterStateChange(diff);
  }
  function doUndo() {
    var e = undoHistory.undo();
    if (!e) { status('没有可撤销的操作'); return null; }
    applyEntry(app.map, e, -1);
    return afterStateChange(e);
  }
  function doRedo() {
    var e = undoHistory.redo();
    if (!e) { status('没有可重做的操作'); return null; }
    applyEntry(app.map, e, +1);
    return afterStateChange(e);
  }
  function afterStateChange(e) {
    var paint;
    markDirty();
    if (e.kind === 'whole') {
      if (dropStaleSelection()) status('已清除越界选区');
      paint = app.r.invalidateAll();
      refreshStatus();
    } else if (e.kind === 'cells') {
      var cells = diffCells(app.map, e);
      if (cells.length) app.r.editCells(e.layer, cells); else app.r.render();
    } else {
      app.r.render();
      refreshStatus();
    }
    statusLine();
    return paint;
  }
  // 长作业(油漆桶 / 渐变):分帧驱动(闸 2)。让出帧的判据是时间预算
  //   (Render.createSlicer,默认 8ms/帧),不是固定条数 —— 固定条数在慢机器上照样能把
  //   一帧撑爆,而那正是闸 2 要防的。作业对象只提供"跑一个量子",一帧跑几个量子由预算定。
  var JOB_QUANTUM = 2048;        // 一个量子的格数:小到慢机器上一帧也撑不爆(它是超调的上界)
  var JOB_QUANTA = 4096;         // 一轮的量子额度。取得故意大:一轮结束必须是因为
                                 //   预算到点,而不是因为"条数跑完了"—— 后者又变成固定条数节拍器;
                                 //   作业提前做完时剩下的条目是空转(立即返回),不花时间。
  function runJob(job, onApply, label) {
    var slicer = Render.createSlicer({});
    var done = false, total = 0;
    function quantum() {
      if (done) return;
      var r = job.runChunk(JOB_QUANTUM);
      total = r.total;
      if (r.done) { done = true; return; }
      status((label || '处理中') + ' … ' + total);
    }
    function pass() {
      if (done) return Promise.resolve();
      return slicer.run(new Array(JOB_QUANTA), quantum).then(pass);
    }
    app.drawing = true;
    return pass().then(function () { onApply(total); }).finally(() => { app.drawing = false; });
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
  function k2of(hit) { return hit.kind === 'cell' ? Core.SUB_PER_CELL : 1; }
  function stNow() {
    return { map: app.map, layer: app.r.layer(), desc: app.st.desc, rgba: app.st.rgba,
             rgba2: app.st.rgba2, brushSize: app.st.brushSize, selection: app.r.selection(),
             descOnly: app.st.descOnly, outline: $('rect-mode').value === 'outline',
             lineWidth: Number($('line-width').value) };
  }
  function subRectOf(from, to) {
    var k = Core.SUB_PER_CELL;
    var x0 = from.x * k2of(from), y0 = from.y * k2of(from);
    var x1 = to.x * k2of(to), y1 = to.y * k2of(to);
    return { x: Math.min(x0, x1), y: Math.min(y0, y1),
             w: Math.abs(x1 - x0) + k, h: Math.abs(y1 - y0) + k };
  }
  function shiftHit(from, to, shift) {
    var c = constrainLine(toSub(from), toSub(to), shift);
    return { kind: 'sub', x: c.x, y: c.y };
  }
  function squareHit(from, to, shift) {
    var c = constrainSquare(toSub(from), toSub(to), shift);
    return { kind: 'sub', x: c.x, y: c.y };
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
    if (cmd === 'undo') return doUndo();
    if (cmd === 'redo') return doRedo();
    if (cmd.startsWith('pan:')) return arrowPan(cmd.slice(4));
    if (cmd === 'cancel-selection') {
      app.st.selDrag = null;
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
      if (sel) app.r.setSelection({x: at.x, y: at.y, w: clipSize(clipboard).w, h: clipSize(clipboard).h});
      return statusLine();
    }
    if (!sel) return status('先框选一块');
    if (cmd === 'copy' || cmd === 'cut') {
      clipboard = copyRegion(app.map, L, sel);
      if (!clipboard) return status('当前图层没有可复制的内容');
      if (cmd === 'copy') return status('已复制 ' + clipSize(clipboard).w + '×' + clipSize(clipboard).h);
    }
    return pushAndShow(applyTool({map: app.map, layer: L, desc: 0, rgba: 0, brushSize: 0.25, selection: sel},
      'rect', {kind: 'sub', x: sel.x, y: sel.y}, {kind: 'sub', x: sel.x + sel.w - 1, y: sel.y + sel.h - 1}));
  }
  function installInteraction() {
    var cv = app.canvas;
    undoHistory = createHistory({});
    var spaceDown = false;
    app.st = { tool: 'brush', brushSize: 1, desc: Core.neutralDesc(1),
               rgba: 0xFF00FFFF, rgba2: 0x101820FF,
               descOnly: false, selStart: null, stroke: null, panning: null, selDrag: null,
               gradStart: null };

    cv.addEventListener('contextmenu', function (e) { e.preventDefault(); });

    cv.addEventListener('pointerdown', function (ev) {
      if (app.fileBusy || app.drawing || !app.map) return;
      if (cv.setPointerCapture) cv.setPointerCapture(ev.pointerId);
      guard('pointerdown', function () {
        if (ev.button === 1 || ev.altKey || (spaceDown && ev.button === 0)) {   // 中键 / Alt / 空格+左键 = 平移
          app.st.panning = { x: ev.clientX, y: ev.clientY };
          return;
        }
        if (ev.button !== 0) return;
        var hit = hitOf(ev, true);
        if (!hit) return;
        var respawnSide = RESPAWN_SIDES[app.st.tool];
        if (respawnSide) {
          pushAndShow(toggleRespawn(app.map, respawnSide, hit));
          return;
        }
        var sel = app.r.selection();
        // 没打开地图时退回线性口径(与 Render.inSel 的 W/H 缺省同款)——指针事件比 setMap
        //   早到是可能的(闸 1:钳制,不报错)
        var W = app.map ? app.map.subCols : 0, H = app.map ? app.map.subRows : 0;
        if (app.st.tool === 'select') {
          var hs = toSub(hit);
          if (sel && inRect(sel, hs.x, hs.y, W, H)) {
            app.st.selDrag = { from: hit, dx: 0, dy: 0 };   // 选区内按下 = 拖动它
          } else {
            app.st.selStart = hit;
          }
          return;
        }
        if (app.st.tool === 'picker') {
          var rect0 = cv.getBoundingClientRect();
          var p = app.r.screenToSub(ev.clientX - rect0.left, ev.clientY - rect0.top);
          var v = pickAt(app.map, app.r.layer(), p.X, p.Y);
          if (app.r.layer() === Core.LAYER_BG) app.st.rgba = v >>> 0;
          else if (Core.texOf(v) !== 0) app.st.desc = v >>> 0;   // 空气不吸(会吸出一个空纹理)
          status('吸管:0x' + (v >>> 0).toString(16) + (Core.texOf(v) === 0 ? '(空气,未采用)' : ''));
          statusLine();
          return;
        }
        if (!canEditLayer(app.r.layer())) return;
        if (app.st.tool === 'bucket') {
          var s0 = stNow();
          var job = createBucketJob(app.map, s0.layer, hit.x * k2of(hit), hit.y * k2of(hit),
                                    { clip: s0.selection });
          // runJob 交回的是一整条分帧链的 promise(slicer.run → onApply → 落笔),
          //    丢掉它 = 拒绝逃到全局围栏,而围栏会 snapshot() ⇒ 一次普通的落笔失败
          //    (编辑/渲染入口抛)会把当前图写进崩溃槽位,下次开机弹假的「上次异常退出」。
          //    交给 guard 收口:guard 是终点(它自己吞掉结果、只往状态栏写一行),
          //    故这里不是"第二处接住",而是唯一该接住的地方(与 pointermove/pointerup 同款)。
          guard('油漆桶填充', function () {
            return runJob(job, function () {
              pushAndShow(paintCells(app.map, s0.layer, job.result(), valueFor(s0, s0.layer)));
            }, '油漆桶填充');
          });
          return;
        }
        if (app.st.tool === 'gradient') {
          if (app.r.layer() !== Core.LAYER_BG) { status('渐变只能用在背景层(它改的是颜色,不是纹理)'); return; }
          app.st.gradStart = hit;
          return;
        }
        app.st.stroke = { from: hit, last: hit, painted: false };   // 画笔/橡皮/矩形/直线
      });
    });

    cv.addEventListener('pointermove', function (ev) {
      guard('pointermove', function () {
        if (app.st.panning) {
          var dxp = ev.clientX - app.st.panning.x, dyp = ev.clientY - app.st.panning.y;
          app.st.panning.x = ev.clientX; app.st.panning.y = ev.clientY;
          // 将异步重建交给 guard 处理拒绝。
          return app.r.panBy(dxp, dyp);
        }
        var hit = hitOf(ev);
        if (app.st.selDrag) {                          // 拖动只记偏移(不碰数据)
          var f = app.st.selDrag.from;
          var ddx = hit.x * k2of(hit) - f.x * k2of(f);
          var ddy = hit.y * k2of(hit) - f.y * k2of(f);
          app.st.selDrag.dx = ddx; app.st.selDrag.dy = ddy;
          app.r.setSelDrag(app.r.selection(), ddx, ddy);
          return;
        }
        if (app.st.selStart) { app.r.setPreview(subRectOf(app.st.selStart, squareHit(app.st.selStart, hit, ev.shiftKey))); return; }
        if (app.st.gradStart) { app.r.setPreview(subRectOf(app.st.gradStart, hit)); return; }
        if (app.st.stroke) {
          if (!canEditLayer(app.r.layer())) return;
          if (app.st.tool === 'brush' || app.st.tool === 'eraser') {
            pushAndShow(applyTool(stNow(), app.st.tool, app.st.stroke.last, hit));
            app.st.stroke.last = hit;
            app.st.stroke.painted = true;              // 见 pointerup:单击也要落一次笔
          } else if (app.st.tool === 'line') {
            app.r.setPreview(subRectOf(app.st.stroke.from, shiftHit(app.st.stroke.from, hit, ev.shiftKey)));
          } else {
            app.r.setPreview(subRectOf(app.st.stroke.from, hit));
          }
        }
      });
    });

    cv.addEventListener('pointerup', function (ev) {
      guard('pointerup', function () {
        if (app.st.panning) { app.st.panning = null; return; }
        var hit = hitOf(ev);
        var sd = app.st.selDrag;
        if (sd) {
          app.st.selDrag = null;
          app.r.setSelDrag(null, 0, 0);
          // 选区可能已经没有了(Esc 走 cancel-selection,而左键还按着)⇒ 没有可搬的
          //   东西。少了这层判,下面那句 cur.x 会抛 TypeError(同款后果)。
          var cur = app.r.selection();
          if (cur && (sd.dx !== 0 || sd.dy !== 0) && canEditLayer(app.r.layer())) {
            pushAndShow(moveRegion(app.map, app.r.layer(), cur, sd.dx, sd.dy));
            // 存回去的选区必须折算(评审发现 3):拖动跨过接缝时 cur.x + sd.dx 会
            //    落到 [0, subCols) 之外,而 regionCells 是"先折算每一格、再 inRect(clip, wx, wy)"
            //    ⇒ clip.x < 0 时一格都进不来:框内所有画笔/矩形/直线/油漆桶都产出空集合,
            //    paintCells 回 null、pushAndShow 回 false —— 而且一条状态栏消息都没有
            //    (用户在框里画,什么都没发生,也不告诉他为什么)。
            app.r.setSelection({ x: Render.wrapIdx(cur.x + sd.dx, app.map.subCols),
                                 y: Render.wrapIdx(cur.y + sd.dy, app.map.subRows),
                                 w: cur.w, h: cur.h });
          }
          statusLine();
          return;
        }
        if (app.st.selStart) {
          var rect = subRectOf(app.st.selStart, squareHit(app.st.selStart, hit, ev.shiftKey));
          app.st.selStart = null;
          app.r.setPreview(null);
          app.r.setSelection(rect);
          statusLine();
          return;
        }
        if (app.st.gradStart) {
          var a = app.st.gradStart;
          app.st.gradStart = null;
          app.r.setPreview(null);
          var s1 = stNow();
          var gj = createGradientJob(app.map,
            { x: a.x * k2of(a), y: a.y * k2of(a) },
            { x: hit.x * k2of(hit), y: hit.y * k2of(hit) },
            s1.rgba, s1.rgba2, { clip: s1.selection });   // 两端各一色(不是同一个色)
          // 与「油漆桶填充」同一条理由(同一个 runJob 出口、同一个"丢掉 promise = 一次
          //    普通的失败换来一个假的崩溃提示")。
          guard('渐变', function () {
            return runJob(gj, function () {
              var res = gj.result(), targets = [], values = [], n = 0;
              for (var i = 0; i < res.length; i++) { targets.push(res[i].i); values.push(res[i].rgba); }
              pushAndShow(paintCells(app.map, Core.LAYER_BG, targets, function () { return values[n++]; }));
            }, '渐变');
          });
          return;
        }
        if (app.st.stroke) {
          var st0 = app.st.stroke;
          app.st.stroke = null;
          app.r.setPreview(null);
          if (!canEditLayer(app.r.layer())) { app.st.gradStart = null; return; }
          if (app.st.tool === 'rect') {
            pushAndShow(applyTool(stNow(), 'rect', st0.from, hit));
          } else if (app.st.tool === 'line') {
            pushAndShow(applyTool(stNow(), 'line', st0.from, shiftHit(st0.from, hit, ev.shiftKey)));
          } else if (!st0.painted) {
            // 按下与松开之间没有 pointermove(单击)时,画笔/橡皮的落笔只在 pointermove
            //   那条路上发生 ⇒ 一次单击什么都不画。矩形/直线是松手才落笔、故单击有效;
            //   而"拿画笔点一格"是最常见的编辑动作,必须同样有效。
            // 判据取 painted 而不是"last 是否等于 from":pointermove 在同一格内也会落笔
            //   (last 仍等于 from),那时再落一次就会往历史里塞一条毫无作用的空差量。
            pushAndShow(applyTool(stNow(), app.st.tool, st0.from, st0.from));
          }
        }
      });
    });

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
  function setBrush(v) {
    app.st.brushSize = Math.max(0.25, Math.min(Render.MAX_BRUSH_CELLS, v));
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
    if (app.fileBusy || app.drawing || app.st.stroke || app.st.selStart || app.st.selDrag) return;
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
    return { layer: Core.LAYER_SCENE, zoom: 0, tool: 'brush', brushSize: 1,
             grid: true, subGrid: false, torus: true, dimOthers: true, guides: false,
             visible: [true, true, true, true], locked: [false, false, false, false],
             compress: DEFAULT_COMPRESS,
             panelOpen: { lib: true, right: true },
             playerRef: { cx: 0, cy: 0, visible: false }, selectedTexture: 1 };
  }
  // 逐字段校验:一个坏字段不该把整份状态丢掉,也不该把坏值原样喂给渲染器。
  //   缩放那一处是钳不是"回落默认":默认的 0 是"没存过缩放"的哨兵(见 applyUiState),
  //     而 zoom:-1 这种存过但坏了的值必须钳到合法区间 —— 回落成 0 的话,那个坏值
  //     只是被静默换成另一个"没信息"的值,用户看到的还是"缩放没恢复",查不出是坏数据。
  function readUiState(store) {
    var def = uiStateDefaults();
    var raw = null;
    try { raw = store ? store[UI_STATE_KEY] : null; } catch (e) { raw = null; }
    if (!raw) return def;
    var obj = null;
    try { obj = JSON.parse(raw); } catch (e) { return def; }
    if (!obj || typeof obj !== 'object') return def;
    var out = uiStateDefaults();
    if (obj.layer >= 0 && obj.layer < Core.LAYER_COUNT) out.layer = obj.layer | 0;
    if (isFinite(obj.zoom)) out.zoom = Render.clampZoom(obj.zoom);
    if (TOOLS.indexOf(obj.tool) >= 0) out.tool = obj.tool;
    if (isFinite(obj.brushSize) && obj.brushSize > 0) {
      out.brushSize = Math.max(0.25, Math.min(Render.MAX_BRUSH_CELLS, obj.brushSize));
    }
    ['grid', 'subGrid', 'torus', 'dimOthers', 'guides', 'compress'].forEach(function (k) {
      if (typeof obj[k] === 'boolean') out[k] = obj[k];
    });
    for (var key of ['visible', 'locked']) {
      if (Array.isArray(obj[key]) && obj[key].length === Core.LAYER_COUNT) {
        out[key] = obj[key].map((value, i) => typeof value === 'boolean' ? value : def[key][i]);
      }
    }
    if (obj.panelOpen && typeof obj.panelOpen === 'object') {
      if (typeof obj.panelOpen.lib === 'boolean') out.panelOpen.lib = obj.panelOpen.lib;
      if (typeof obj.panelOpen.right === 'boolean') out.panelOpen.right = obj.panelOpen.right;
    }
    if (obj.playerRef && typeof obj.playerRef === 'object') {
      var pr = obj.playerRef;
      out.playerRef = {
        cx: isFinite(pr.cx) ? Math.floor(pr.cx) : def.playerRef.cx,
        cy: isFinite(pr.cy) ? Math.floor(pr.cy) : def.playerRef.cy,
        visible: pr.visible === true,
      };
    }
    if (isFinite(obj.selectedTexture) && obj.selectedTexture > 0) {
      // 这里不许用图集派生的上界钳(clampTexture(…, Render.atlasCapacity()))。
      //    理由是一条真实的启动时序:bootLoad 在图集存在之前就读这份状态
      //    (readUiState 在前、loadAtlas() 在后),而 setAtlas 之前 atlasCapacity() 是 0
      //    ⇒ clampTexture 把"cap < 1"当"没有信息"、返回 1 ⇒ 存进去的 7 每次开机变 1,
      //    下一次 persistUi 再把 1 写回 localStorage(persistUi 存的是
      //    selectedTexture: Core.texOf(app.st.desc),而 app.st.desc 正是下面
      //    applyUiState 那个钳制结果派生的)—— 每一次开机、永远、静默地毁掉用户选中的纹理。
      //    而这一条冒烟当年看不见:测试直接注入 app.uist(绕过了 readUiState)——
      //      一个不可能失败的守卫。新守卫走真序列:readUiState → setAtlas → applyUiState。
      //    钳制没有被删掉,只是挪到了它该在的地方:applyUiState 跑在 loadAtlas()
      //      之后,那里才是"图集真的装好了"的时刻(那一处仍走 clampTexture)。
      //    这里只做"字段自身合法吗":是有限数、> 0(0 会让 Tint 抛;NaN/负数不是"没存过")。
      out.selectedTexture = Math.floor(obj.selectedTexture);
    }
    return out;
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
  async function applyUiState() {
    var u = app.uist;
    if (!u) return;
    // 缩放必须在地图打开之后恢复:setMap 自己会 fit(),先设会被它覆盖掉。
    //   u.zoom === 0 是"没存过缩放"的哨兵 ⇒ 保持 setMap 的 fit。
    var cur = app.r.view().zoom;
    if (app.map && u.zoom > 0 && cur > 0 && Math.abs(u.zoom - cur) > 1e-6) {
      await app.r.setZoomAt(app.canvas.width / 2, app.canvas.height / 2, u.zoom / cur);
    }
    setLayer(u.layer);
    app.r.setGrid(u.grid); app.r.setSubGrid(u.subGrid);
    await app.r.setTorus(u.torus);
    app.r.setDimOthers(u.dimOthers);
    app.r.setGuides(u.guides);
    for (var L = 0; L < Core.LAYER_COUNT; L++) {
      app.r.setLayerVisible(L, u.visible[L]);
      app.r.setLayerLocked(L, u.locked[L]);
    }
    syncLayerButtons();
    app.st.tool = u.tool;
    app.st.brushSize = u.brushSize;
    // 恢复工具状态后同步按钮高亮。
    selectToolButton();
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
    // DOM 必须与上面保持一致:否则"页面显示的"与"实际用的"是两回事(开关显示关着、其实开着)
    [['tg-grid', u.grid], ['tg-subgrid', u.subGrid], ['tg-torus', u.torus], ['tg-guides', u.guides]].forEach(function (pair) {
      var el = $(pair[0]);
      if (el) el.classList.toggle('on', !!pair[1]);
    });
    var dim = $('dim-others');
    if (dim) dim.checked = !!u.dimOthers;
    // 压缩开关也要按回去 —— 而且只在存过这个字段时才动它:老存档(这份状态是
    //    cyrm.ui.v1,没有 compress)里没有它,照 !!u.compress 写会把框取消勾选
    //    (页面上写死的默认是"勾上"),于是"没存过"被读成"用户不要压缩" —— 一次静默的
    //    文件格式变更。缺字段时就该保持页面默认(与 readUiState 逐字段回落同一条纪律)。
    var cp = $('opt-compress');
    if (cp && typeof u.compress === 'boolean') cp.checked = u.compress;
    var bsEl = $('brush-size');
    if (bsEl) bsEl.value = String(app.st.brushSize);
  }
  var uiSaveTimer = null;
  function persistUi() {
    if (uiSaveTimer || !app.st) return;
    uiSaveTimer = setTimeout(function () {
      uiSaveTimer = null;
      var prev = app.uist || uiStateDefaults();
      app.uist = {
        layer: app.r.layer(), zoom: app.map ? app.r.view().zoom : prev.zoom, tool: app.st.tool,
        brushSize: app.st.brushSize,
        grid: $('tg-grid') ? $('tg-grid').classList.contains('on') : true,
        subGrid: $('tg-subgrid') ? $('tg-subgrid').classList.contains('on') : false,
        torus: $('tg-torus') ? $('tg-torus').classList.contains('on') : true,
        guides: $('tg-guides').classList.contains('on'),
        visible: Array.from({length: Core.LAYER_COUNT}, (_, L) => app.r.layerVisible(L)),
        locked: Array.from({length: Core.LAYER_COUNT}, (_, L) => app.r.layerLocked(L)),
        dimOthers: $('dim-others') ? !!$('dim-others').checked : true,
        compress: optCompress(),
        panelOpen: prev.panelOpen, playerRef: prev.playerRef,
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
    $('tg-grid').addEventListener('click', function () {
      this.classList.toggle('on'); app.r.setGrid(this.classList.contains('on'));
    });
    $('tg-subgrid').addEventListener('click', function () {
      this.classList.toggle('on'); app.r.setSubGrid(this.classList.contains('on'));
    });
    $('tg-torus').addEventListener('click', function () {
      var on = this.classList.toggle('on');
      guard('环面预览', () => app.r.setTorus(on));
    });
    $('tg-guides').addEventListener('click', function () {
      app.r.setGuides(this.classList.toggle('on'));
    });
    for (var id of ['rect-mode', 'line-width']) $(id).addEventListener('change', statusLine);
    for (var type of globalThis.ENEMY_REGISTRY) $('spawn-enemy-type').add(new Option(type.name, type.id));
    var dim = $('dim-others');
    if (dim) dim.addEventListener('change', function () { app.r.setDimOthers(dim.checked); });
    var p1 = $('spawn-p1'), p2 = $('spawn-p2'), en = $('spawn-enemy'), cl = $('spawn-clear');
    if (p1) p1.addEventListener('click', () => spawnAt(1));
    if (p2) p2.addEventListener('click', () => spawnAt(2));
    if (en) en.addEventListener('click', () => spawnAt());
    // 与它三个兄弟(spawn-p1/spawn-p2/spawn-enemy,都走 spawnAt)对齐:没打开地图时
    //    说「先打开一张地图」,而不是把 clearSpawns(null) 的 TypeError 抛进 click 处理器 ——
    //    后者经 window.onerror 变成「页面异常:…」,同一个面板里四个按钮两种说法。
    if (cl) cl.addEventListener('click', function () {
      guard('清空出生点', function () {
        if (!app.map) { status('先打开一张地图'); return null; }
        return pushAndShow(clearSpawns(app.map));
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
      status(cpBox.checked ? '导出/保存:压缩(deflate)'
                           : '导出/保存:裸 body(compression=0;浏览器与 Godot 的 deflate 万一对不上,这条是退路)');
    });
    bindFileActions();    [['bg-color', 'rgba'], ['bg-color2', 'rgba2']].forEach(function (spec) {
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
    const before = snapshotSpawns(app.map);
    if (slot) {
      const at = app.map.players.findIndex(p => p.slot === slot);
      const point = { slot, x, y };
      if (at < 0) app.map.players.push(point);
      else app.map.players[at] = point;
    } else {
      app.map.enemies.push({ type: $('spawn-enemy-type').value, x, y });
    }
    pushAndShow(spawnDiff(before, snapshotSpawns(app.map)));
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
