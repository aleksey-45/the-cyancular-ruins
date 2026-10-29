globalThis.Editor = (function () {
  'use strict';

  var Core = globalThis.Core, Render = globalThis.Render, Io = globalThis.Io;
  if (!Core) throw new Error('ui.js: 必须先加载 core.js');
  if (!Render) throw new Error('ui.js: 必须先加载 render.js');
  if (!Io) throw new Error('ui.js: 必须先加载 io.js');

  var DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;

  var app = {
    r: null, canvas: null, map: null, name: null,
    raw: null, tileDefs: null,
  };

  function $(id) { return document.getElementById(id); }
  function mapRequest(url, options) {
    return globalThis.CYRM_OFFLINE ? globalThis.CYRM_OFFLINE.request(url, options) : fetch(url, options);
  }
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
    return String(fileName == null ? '' : fileName).replace(/\.cyrm$/i, '');
  }
  function mapFromBytes(fileName, bytes) {
    return Io.decodeMap(bytes).then(function (map) {
      map.name = nameFromFile(fileName);
      return { map: map };
    });
  }

  var TOOLS = ['brush', 'rect', 'bucket', 'eraser', 'line', 'select', 'picker', 'gradient'];
  var TOOL_LABELS = { brush: '画笔', rect: '矩形', bucket: '油漆桶', eraser: '橡皮',
                      line: '直线', select: '选框', picker: '吸管', gradient: '渐变' };
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
  function regionCells(map, region, clip) {
    var out = [], seen = new Set();
    function add(X, Y) {
      var wx = Render.wrapIdx(X, map.subCols), wy = Render.wrapIdx(Y, map.subRows);
      if (!inRect(clip, wx, wy, map.subCols, map.subRows)) return;   // C12:选区约束绘制(环面)
      var i = wy * map.subCols + wx;
      if (seen.has(i)) return;                           // 环面下 3×3 会重复命中,去重
      seen.add(i); out.push(i);
    }
    var k = Core.SUB_PER_CELL;
    if (region.unit === 'cell') {
      for (var cy = region.y0; cy <= region.y1; cy++) {
        for (var cx = region.x0; cx <= region.x1; cx++) {
          for (var qy = 0; qy < k; qy++) {
            for (var qx = 0; qx < k; qx++) add(cx * k + qx, cy * k + qy);
          }
        }
      }
    } else {
      for (var y = region.y0; y <= region.y1; y++) {
        for (var x = region.x0; x <= region.x1; x++) add(x, y);
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
  function lineTargets(map, a, b, clip) {
    var pts = strokePoints({ kind: 'sub', x: a.x, y: a.y }, { kind: 'sub', x: b.x, y: b.y });
    var out = [], seen = new Set();
    for (var i = 0; i < pts.length; i++) {
      var wx = Render.wrapIdx(pts[i].x, map.subCols), wy = Render.wrapIdx(pts[i].y, map.subRows);
      if (!inRect(clip, wx, wy, map.subCols, map.subRows)) continue;
      var idx = wy * map.subCols + wx;
      if (seen.has(idx)) continue;
      seen.add(idx); out.push(idx);
    }
    return out;
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
      }, clip);
    } else if (tool === 'line') {
      idx = lineTargets(map, toSub(from), toSub(to), clip);
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

  // ── 出生点与敌人(A9:它们的增删也要进历史)──
  function snapshotSpawns(map) {
    return {
      players: map.players.map(function (p) { return { x: p.x, y: p.y }; }),
      enemies: map.enemies.map(function (e) { return { type: e.type, x: e.x, y: e.y }; }),
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
  function addSpawn(map, kind, cellX, cellY, enemyType) {
    var before = snapshotSpawns(map);
    var x = Render.wrapIdx(Math.floor(cellX), Core.cellsWOf(map));
    var y = Render.wrapIdx(Math.floor(cellY), Core.cellsHOf(map));
    if (kind === 'enemy') map.enemies.push({ type: String(enemyType || 'fly_bird'), x: x, y: y });
    else map.players.push({ x: x, y: y });
    return spawnDiff(before, snapshotSpawns(map));
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
      if (inRange(map.players[i])) out.players.push({ x: map.players[i].x, y: map.players[i].y });
      else dropped.push({ kind: 'player', x: map.players[i].x, y: map.players[i].y });
    }
    for (i = 0; i < map.enemies.length; i++) {
      var e = map.enemies[i];
      if (inRange(e)) out.enemies.push({ type: e.type, x: e.x, y: e.y });
      else dropped.push({ kind: 'enemy', type: e.type, x: e.x, y: e.y });
    }
    return { map: out, dropped: dropped, size: { w: cellsW, h: cellsH } };
  }
  // A10 要求的是"提示并清理"而不是"静默清理" —— 这一行就是那个提示的文案。
  function resizeReportLines(dropped) {
    return (dropped || []).map(function (d) {
      return d.kind === 'enemy'
        ? ('敌人 ' + d.type + ' 落在图外 (' + d.x + ',' + d.y + '),已移除')
        : ('出生点落在图外 (' + d.x + ',' + d.y + '),已移除');
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
    // before 快照必须取在改之前,而 wholeDiff 的 seal() 快照的是建它时抓的那个
    //    对象 ⇒ 中间不许换 app.map 的引用,只能把新尺寸原地装进去(adoptMapInto)。
    //    直接 app.map = out.map 的话 before === after:撤销/重做都无效,且一个字都不报。
    var wd = wholeDiff(app.map, 'resize');
    var out = resizeMap(app.map, c.w, c.h);
    adoptMapInto(app.map, out.map);
    // 走既有的落笔出口:kind:'whole' ⇒ pushAndShow 会派到 invalidateAll(画布按新尺寸
    //   重新挂)并把这一条推进历史。
    pushAndShow(wd.seal());
    // 状态栏那一格与两个输入框都要跟着翻 —— pushAndShow 只调 statusLine()(它管的是
    //   工具/纹理/选区/撤销深度那一排),不含尺寸,也不碰输入框。少了这一句,改完尺寸之后
    //   状态栏仍写着旧尺寸、框里也仍是刚输的那个数(与"DOM 必须与状态一致"同一条纪律)。
    refreshStatus();
    // 选区装不下新尺寸就清掉(Important 1;理由见 dropStaleSelection)。排在
    //    adoptMapInto 之后(app.map.subCols 此刻才是新尺寸)。
    var selDropped = dropStaleSelection();
    // A10:越界项要报出来。resizeMap 只丢不钳(钳一个出生点到边界上是替用户做决定),
    //    所以这里报的就是它丢掉的那几项 —— 静默清理等于"导出去游戏读到网格外坐标"。
    var lines = resizeReportLines(out.dropped);
    status('尺寸改为 ' + out.size.w + '×' + out.size.h + ' 格' +
           (lines.length ? (';A10 越界项已清理 ' + lines.length + ' 项:' + lines.join(';'))
                         : ';没有越界项') +
           igTxt +
           (selDropped ? ';选区超出新尺寸,已清掉' : ''));
    return null;
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
    var mod = !!(e.ctrl || e.meta);
    if (mod) {
      if (k === 'z') return e.shift ? 'redo' : 'undo';
      if (k === 'y') return 'redo';
      if (k === 'c') return 'copy';
      if (k === 'x') return 'cut';
      if (k === 'v') return 'paste';
      if (k === 's') return e.shift ? 'save-as' : 'save';
      return null;
    }
    if (KEY_TOOLS[k]) return 'tool:' + KEY_TOOLS[k];
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

  function bytesOfEntry(e) {
    if (!e) return 0;
    if (e.kind === 'cells') return 12 + e.idx.length * 4 + e.before.length * 4 + e.after.length * 4;
    if (e.kind === 'spawn') {
      var n = (e.before ? e.before.players.length + e.before.enemies.length : 0) +
              (e.after ? e.after.players.length + e.after.enemies.length : 0);
      return 64 + 32 * n;
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
    var sp = snapshotSpawns(map);
    return { subCols: map.subCols, subRows: map.subRows, layers: layers,
             players: sp.players, enemies: sp.enemies, comments: map.comments.slice() };
  }
  function bytesOfSnapshot(s) {
    var n = 0;
    for (var L = 0; L < s.layers.length; L++) {
      var lay = s.layers[L];
      if (!lay) continue;
      n += (lay.kind === 'tex' ? lay.desc.length : lay.rgba.length) * 4;
    }
    return n;
  }
  // 用法:var wd = wholeDiff(map, 'resize'); …做完改动…; wd.seal(); history.push(wd.entry);
  function wholeDiff(map, tag) {
    var entry = { kind: 'whole', tag: tag || '', before: snapshotMap(map), bytes: 0 };
    entry.bytes = bytesOfSnapshot(entry.before);
    return {
      entry: entry,
      seal: function () {
        entry.after = snapshotMap(map);
        entry.bytes += bytesOfSnapshot(entry.after);
        return entry;
      },
    };
  }
  // 把 src 的六个字段原地装进 dst(不换引用、不做拷贝)。
  // 为什么必须是"原地"而不是 app.map = out.map:改尺寸那条路要的差量是
  //    wholeDiff(app.map, …) → 改 → seal(),而 seal() 快照的是它建时抓的那个对象
  //    (闭包参数,不是"当时的 app.map")。中间换了引用 ⇒ after 拿到的仍是改前那份
  //    (before === after):撤销/重做双双无效,而一个字都不报(条目在历史里、深度也涨了)。
  // 字段表与 applyEntry 的 whole 分支同一份(它那边是防御性拷贝,因为快照与
  //    地图会长期共存;这里相反 —— out.map 是刚造出来的、只有本函数一个持有者,
  //    照搬那六个字段之后它就该被丢掉)。
  function adoptMapInto(dst, src) {
    dst.subCols = src.subCols; dst.subRows = src.subRows;
    dst.layers = src.layers;
    dst.players = src.players; dst.enemies = src.enemies;
    dst.comments = src.comments;
    return dst;
  }
  function applyEntry(map, e, dir) {
    if (!e) return;
    var i;
    if (e.kind === 'cells') {
      var arr = Render.layerArray(map, e.layer);
      if (!arr) return;
      var src = dir < 0 ? e.before : e.after;
      for (i = 0; i < e.idx.length; i++) arr[e.idx[i]] = src[i];
      return;
    }
    if (e.kind === 'spawn') {
      var v = dir < 0 ? e.before : e.after;
      map.players = v.players.map(function (p) { return { x: p.x, y: p.y }; });
      map.enemies = v.enemies.map(function (q) { return { type: q.type, x: q.x, y: q.y }; });
      return;
    }
    if (e.kind === 'whole') {
      var s = dir < 0 ? e.before : e.after;
      if (!s) {
        reportError('重做无效:这条整图级历史没有 after 快照(wholeDiff 的 seal() 还没调用,条目就进了历史)');
        return;
      }
      map.subCols = s.subCols; map.subRows = s.subRows;
      // 必须防御性拷贝:直接 alias 快照数组的话,撤销之后地图与 entry.before
      //   共用同一份 TypedArray —— 用户再落一笔就写进了历史条目里,下一次撤销恢复的是
      //   被污染的 before(「撤销没撤干净」且一个字都不报;字节数也不变,字节闸发现不了)。
      map.layers = s.layers.map(function (lay) {
        if (!lay) return null;
        return lay.kind === 'tex' ? { kind: 'tex', desc: new Uint32Array(lay.desc) }
                                  : { kind: 'color', rgba: new Uint32Array(lay.rgba) };
      });
      map.players = s.players.map(function (p) { return { x: p.x, y: p.y }; });
      map.enemies = s.enemies.map(function (q) { return { type: q.type, x: q.x, y: q.y }; });
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
    if (!diff) return false;
    undoHistory.push(diff);
    markDirty();                      // 落了笔 ⇒ 磁盘上那份已经不等于屏幕上这一份了(+ 排草稿)
    // 两条路都要走:kind:'whole'(改尺寸/换图)改的是尺寸本身,diffCells 对它是
    //   空数组 ⇒ 只 render() 的话整张图停在旧尺寸/旧内容上(画面错了、一个字都不报)。
    //   invalidateAll 会把缩略图与 ② 一起整片重建(它自己带尺寸对齐,见那边的注释)。
    if (diff.kind === 'whole') { Promise.resolve(app.r.invalidateAll()); statusLine(); return true; }
    var cells = diffCells(app.map, diff);
    if (cells.length) app.r.editCells(diff.layer, cells);
    else app.r.render();
    statusLine();
    return true;
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
    var out = null;
    markDirty();
    if (e.kind === 'whole') {
      // 尺寸可能变了 ⇒ 整片重来。不是 setMap:那个会把视图重新"适配"并清掉选区,
      //   而撤销一次尺寸变化不该把视野和选区一起重置(而且它建的是"新图"语义)。
      out = Promise.resolve(app.r.invalidateAll());
      // 但装不下的选区必须清掉(Important 1;理由见 dropStaleSelection)。这两条不矛盾:
      //    "别无条件重置视野与选区"是不要每次都清,而这是"这一条框在新尺寸下已经没有
      //    对应的格了"。撤销/重做都要(顺序:撤销把图放大 ⇒ 框还在;重做又缩小 ⇒ 那时
      //    才轮到清),而"谁在什么时候把它框小了"与用户下一次框选之间隔着任意多步操作 ⇒
      //    只能每次整片重来时判一遍。
      if (dropStaleSelection()) status('选区超出新尺寸,已清掉');
      // 还有那两处不在画布上的尺寸显示:状态栏的 #st-size 与尺寸面板的两个框。
      //   invalidateAll 只管渲染,statusLine 只管工具/纹理/选区/撤销深度 ⇒ 少了这一句,
      //   撤销一次改尺寸之后画布已经回到 4×3,而框里仍写着 400×75 —— 再按一次「应用尺寸」
      //   就把图又改回 400×75(用户以为"尺寸没变")。与 applySize 里那一句同一条纪律。
      refreshStatus();
    } else if (e.kind === 'cells') {
      var cells = diffCells(app.map, e);
      if (cells.length) app.r.editCells(e.layer, cells); else app.r.render();
    } else app.r.render();
    statusLine();
    return out;
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
    return pass().then(function () { onApply(total); });
  }
  function statusLine() {
    if (!app.map) return;
    var set = function (id, txt) { var el = $(id); if (el) el.textContent = txt; };
    set('st-tool', '工具 ' + (TOOL_LABELS[app.st.tool] || app.st.tool) + ' × ' + app.st.brushSize);
    set('st-tex', '纹理 ' + Core.texOf(app.st.desc));
    set('st-desc', '辅码 ' + Core.hueOf(app.st.desc) + '/' + Core.brightOf(app.st.desc) + '/' +
                   Core.satOf(app.st.desc) + '/' + Core.alphaOf(app.st.desc));
    var sel = app.r.selection();
    set('st-sel', sel ? ('选区 ' + (sel.w / Core.SUB_PER_CELL) + '×' + (sel.h / Core.SUB_PER_CELL) + ' 格') : '无选区');
    set('st-undo', '撤销 ' + undoHistory.depth() + ' / 重做 ' + undoHistory.redoDepth());
    renderSaveState();                // 每落一笔都要跟着翻(状态栏是"现在"的样子)
  }

  function hitOf(ev) {
    var cv = app.canvas;
    var rect = cv.getBoundingClientRect();
    var p = app.r.screenToSub(ev.clientX - rect.left, ev.clientY - rect.top);
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
             descOnly: app.st.descOnly };
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
      if (cv.setPointerCapture) cv.setPointerCapture(ev.pointerId);
      guard('pointerdown', function () {
        if (ev.button === 1 || ev.altKey || (spaceDown && ev.button === 0)) {   // 中键 / Alt / 空格+左键 = 平移
          app.st.panning = { x: ev.clientX, y: ev.clientY };
          return;
        }
        if (ev.button !== 0) return;
        var hit = hitOf(ev);
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
          return Promise.resolve(app.r.panBy(dxp, dyp));
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
          if (cur && (sd.dx !== 0 || sd.dy !== 0)) {
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
        var zp = Promise.resolve(app.r.setZoomAt(ev.clientX - rect.left, ev.clientY - rect.top,
                                                 ev.deltaY < 0 ? 1.25 : 0.8));
        statusLine();
        return zp;
      });
    }, { passive: false });

    window.addEventListener('keydown', function (ev) {
      if (isTypingTarget(ev.target)) return;
      if (ev.key === ' ') { spaceDown = true; ev.preventDefault(); return; }
      var cmd = commandFor(ev);
      if (!cmd) return;                                  // 表外的键一律不拦
      guard('keydown', function () {
        ev.preventDefault();
        var pend = null;                                 // 视图入口交回的 promise(交给 guard 收口)
        if (cmd.indexOf('tool:') === 0) { app.st.tool = cmd.slice(5); selectToolButton(); }
        else if (cmd === 'brush-smaller') { setBrush(bumpBrush(app.st.brushSize, -1)); }
        else if (cmd === 'brush-bigger') { setBrush(bumpBrush(app.st.brushSize, 1)); }
        else if (cmd.indexOf('layer:') === 0) { setLayer(parseInt(cmd.slice(6), 10)); }
        else if (cmd === 'undo') pend = doUndo();
        else if (cmd === 'redo') pend = doRedo();
        else if (cmd === 'copy') {
          clipboard = copyRegion(app.map, app.r.layer(), app.r.selection());
          status(clipboard ? '已复制 ' + clipSize(clipboard).w + '×' + clipSize(clipboard).h : '先框选一块');
        }
        else if (cmd === 'cut') {
          var s2 = app.r.selection();
          if (!s2) { status('先框选一块'); return; }
          clipboard = copyRegion(app.map, app.r.layer(), s2);
          pushAndShow(applyTool({ map: app.map, layer: app.r.layer(), desc: 0, rgba: 0,
                                  brushSize: 0.25, selection: s2 },
                                'rect', { kind: 'sub', x: s2.x, y: s2.y },
                                { kind: 'sub', x: s2.x + s2.w - 1, y: s2.y + s2.h - 1 }));
        }
        else if (cmd === 'paste') {
          var sel = app.r.selection();
          var at = sel ? { x: sel.x, y: sel.y } : { x: 0, y: 0 };
          var out = pasteRegion(app.map, app.r.layer(), clipboard, at.x, at.y);
          if (!out.ok) { status('粘贴失败:' + out.why); return; }
          pushAndShow(out.diff);
          if (sel) app.r.setSelection({ x: at.x, y: at.y, w: clipSize(clipboard).w, h: clipSize(clipboard).h });
        }
        else if (cmd.indexOf('mirror:') === 0) { pend = mirrorSelection(cmd.slice(7)); }
        else if (cmd === 'clear-selection') {
          var s3 = app.r.selection();
          if (!s3) { status('先框选一块'); return; }
          pushAndShow(applyTool({ map: app.map, layer: app.r.layer(), desc: 0, rgba: 0,
                                  brushSize: 0.25, selection: s3 },
                                'rect', { kind: 'sub', x: s3.x, y: s3.y },
                                { kind: 'sub', x: s3.x + s3.w - 1, y: s3.y + s3.h - 1 }));
        }
        else if (cmd === 'cancel-selection') {
          app.st.selDrag = null;
          app.r.setSelDrag(null, 0, 0);
          app.r.setSelection(null);
        }
        else if (cmd.indexOf('pan:') === 0) { pend = arrowPan(cmd.slice(4)); }
        else if (cmd === 'save' || cmd === 'save-as') { pend = saveCurrent(cmd === 'save-as'); }
        statusLine();
        return pend;
      });
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
    return Promise.resolve(app.r.panBy(d[0], d[1]));      // 视图入口:promise 交给 guard
  }
  function selectToolButton() {
    document.querySelectorAll('#toolbar .tool').forEach(function (b) {
      b.classList.toggle('on', b.dataset.tool === app.st.tool);
    });
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

  function freshName(base) { return Core.sanitizeName(base) + '.cyrm'; }
  function saveTargetName(asNew) {
    if (!app.map) return null;
    return asNew ? freshName((app.map.name || 'map') + '_copy') : app.name;
  }
  function saveCurrent(asNew) {
    if (!app.map) { status('先打开一张地图'); return Promise.resolve(); }
    var name = saveTargetName(asNew);
    if (!name) return Promise.resolve();
    status('保存 ' + name + ' …');
    // 草稿盘那条记录挂在存盘前那个键上("另存为"会换名字,存完再问键就找不到了
    //   —— 于是旧名字下那条脏草稿会留着,下次打开那张旧图时弹一次假的恢复提示)。
    var draftAt = currentDraftKey();
    // 写盘只走 putMapBytes 这一个出口(页面上唯一发 PUT 的地方):PUT 的
    //    Content-Type: application/json 与"body 是裸字节"这两条纪律都钉在那里
    //    (不设头 = 浏览器给 Blob 的默认类型 ⇒ 服务器 415 ⇒ "点了保存、磁盘上那份没变",
    //    而且不报错回滚)。这里再拼一份 fetch 就是第二个出口,迟早只改一处。
    return encodeForWrite(app.map).then(function (bytes) {
      return putMapBytes(name, bytes)
                .then(function (out) {
        app.name = name;
        app.raw = bytes;

        dirty = false;                 // 只有真的写成功了才清(见 dirty 那段的纪律)
        // 草稿盘那条也标干净(同一个"真的成功了"):它与磁盘上那份现在同源,
        //   下次打开不该再问一次 —— 与上面那行同一条纪律、同一处。
        markDraftSaved(draftAt);
        refreshStatus();
        statusLine();
        // 库列表刷新排在说结果之前:那条 GET 失败时 guard 会往同一条状态栏
        //    写一行错误 —— 先写「已保存 …」再被它盖掉的话,用户看到的是"刷新失败了",
        //    而保存其实成功了(人眼验收清单恰恰是叫用户去看那一行)。故:先把刷新
        //    (无论成败)走完,最后才把保存结果写在最上面那一行。
        //    代价照实说:刷新失败那行于是只在控制台(reportError 的 console.error)里
        //      留痕、状态栏上是一句「已保存」。刷新只是"列表里的字节数/时间",不影响落盘。
        // Promise.resolve(...) 不是装饰:guard 在同步抛时返回的是 null(见它的
        //   实现),直接 .then 会在这里炸成一次 TypeError —— 那会被外层 catch 说成
        //   「保存失败」,而保存其实成功了(徽标已经翻成已保存,两句话又打起来)。
        return Promise.resolve(guard('库列表刷新', function () { return refreshLibrary(); }))
               .then(function () {
                 status('已保存 ' + out.name + '(' + out.size + ' 字节)');
               });
      });
    }).catch(function (e) {
      // 保存失败要说出来;磁盘上那份没被动过(服务器是原子写)
      status('保存失败:' + msgOf(e));
    });
  }

  // ── 敌人类型(来自页面里的注册表 —— 不写死清单)──
  function importEnemyTypes() {
    var reg = globalThis.ENEMY_REGISTRY;
    if (!reg || !reg.length) return [];
    return reg.map(function (e) { return String(e.id); });
  }

  function exportReport() {
    if (!app.map) return { lines: ['还没打开地图'], ok: false };
    var rep = Core.validateMap(app.map);
    var lines = validateLines(rep);
    if (!lines.length) lines = ['校验通过:没有发现问题'];
    lines.push('尺寸 ' + Core.cellsWOf(app.map) + '×' + Core.cellsHOf(app.map) + ' 格 · 出生点 ' +
               app.map.players.length + ' · 敌人 ' + app.map.enemies.length);
    if (app.map.players.length > 2) {
      lines.push('⚠ 第 3 个及以后的出生点游戏侧读不到(map_format.gd 只认 player/player2)');
    }
    return { lines: lines, ok: rep.errors.length === 0 };
  }
  function showExportReport() {
    var rep = exportReport();
    window.alert(rep.lines.join('\n'));
    status(rep.ok ? '导出校验:没有 error' : '导出校验:有 error(encodeMap 会拒绝导出)');
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
  // "当前这张图"的键只有这一处:写进去的与读出来的必须是同一个键,
  //   否则症状是"草稿盘里明明有一条,恢复时说什么都没有"(而且不报错)。
  //   app.name 是带 .cyrm 的文件名;新建还没写盘的图只有 app.map.name(不带后缀)——
  //   draftKey 对两者归一(先去掉后缀、再 sanitizeName)。
  function currentDraftKey() {
    return draftKey(app.name || (app.map ? app.map.name : '') || '');
  }

  // 闸 4 的判据(纯函数,便于断言):崩溃槽位比主槽位新 ⇒ 上次是异常退出。
  // declined = 这条快照已经问过、用户说不要 ⇒ 不再拿它反复问:不记的话一次偶发
  //   页面异常会把每一次打开都变成「上次异常退出」(直到用户碰巧 Ctrl+S 把草稿写新,
  //   才靠"比主草稿旧"压下去)—— 一次性的异常变成一个永久的开机弹窗。
  //   新的一次崩溃会重写这条记录(不带 declined)⇒ 照问,所以它挡不住真正的下一次。
  function crashIsNewer(crashRec, mainRec) {
    if (!crashRec) return false;
    if (crashRec.declined) return false;
    if (!mainRec) return true;
    return (crashRec.savedAt || 0) > (mainRec.savedAt || 0);
  }

  // 库条目上限(闸 1:60)。先丢"已保存且最老"的 —— 脏的那份是用户还没写盘的劳动。
  function evictPlan(records, maxEntries) {
    var list = (records || []).slice();
    var cap = (maxEntries === undefined) ? MAX_LIB : maxEntries;
    if (list.length <= cap) return { keep: list.map(function (r) { return r.key; }), drop: [] };
    var sorted = list.slice().sort(function (a, b) {
      var ad = a.dirty ? 1 : 0, bd = b.dirty ? 1 : 0;
      if (ad !== bd) return ad - bd;                 // 干净的排前面(先被丢)
      return (a.savedAt || 0) - (b.savedAt || 0);     // 同样干净时,最老的先丢
    });
    var drop = sorted.slice(0, list.length - cap).map(function (r) { return r.key; });
    var keep = [];
    list.forEach(function (r) { if (drop.indexOf(r.key) < 0) keep.push(r.key); });
    return { keep: keep, drop: drop };
  }

  // ── 第 3 层:localStorage 小状态(读损坏值一律回落默认:编辑器要能开)──
  function uiStateDefaults() {
    return { layer: Core.LAYER_SCENE, zoom: 0, tool: 'brush', brushSize: 1,
             grid: true, subGrid: false, torus: true, dimOthers: true,
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
    ['grid', 'subGrid', 'torus', 'dimOthers', 'compress'].forEach(function (k) {
      if (typeof obj[k] === 'boolean') out[k] = obj[k];
    });
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
        // 新建和已有对象仓库都必须具有 savedAt 索引，供恢复查询和过期清理使用。
        var st = db.objectStoreNames.contains(DRAFT_STORE)
          ? req.transaction.objectStore(DRAFT_STORE)
          : db.createObjectStore(DRAFT_STORE, { keyPath: 'key' });
        if (st && st.indexNames && !st.indexNames.contains(DRAFT_TIME_INDEX)) {
          st.createIndex(DRAFT_TIME_INDEX, 'savedAt');
        }
        if (!db.objectStoreNames.contains(CRASH_STORE)) db.createObjectStore(CRASH_STORE, { keyPath: 'key' });
      };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { resolve(null); };      // 配额/私密模式:草稿盘不可用也要能用编辑器
      // 版本 2 带来的一种新情形:另一个标签页还按版本 1 开着这张库 ⇒ 升级被阻塞
      //    (浏览器等它关闭,期间既不 success 也不 error)。不接这一下的话这条 promise
      //    永远不 settle,而 bootLoad 正 await 着它 —— 症状是"编辑器白屏 / 永远停在启动",
      //    连面板都不建。这里按同一条口径收场:交回 null(草稿盘这一局不可用,状态栏那句话
      //    照旧会说),编辑器照常打开 —— 与"开不出草稿盘"逐字同一个退化方向。
      //    同一份文件里的 selfTest() 早就这么接了(它给的是 2 秒兜底),这不是新花样。
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
  function idbCount(db, store) {
    return new Promise(function (resolve) {
      var tx, rq;
      try { tx = db.transaction(store, 'readonly'); rq = tx.objectStore(store).count(); }
      catch (e) { resolve(null); return; }
      rq.onsuccess = function () { resolve(typeof rq.result === 'number' ? rq.result : 0); };
      rq.onerror = function () { resolve(null); };    // null = 读不到(不是"0 条")
    });
  }
  function idbGetOne(db, store, key) {
    return new Promise(function (resolve) {
      var tx, rq;
      try { tx = db.transaction(store, 'readonly'); rq = tx.objectStore(store).get(key); }
      catch (e) { resolve({ ok: false, rec: null }); return; }
      rq.onsuccess = function () { resolve({ ok: true, rec: rq.result || null }); };
      rq.onerror = function () { resolve({ ok: false, rec: null }); };
      // 事务级的失败(配额/被中止)不一定冒泡到请求上,这里兜住同一件事;已经 resolve 过
      //   的那一次不受影响(promise 只认第一个)。
      if (tx) tx.onabort = function () { resolve({ ok: false, rec: null }); };
    });
  }
  function idbNewestSavedAt(db) {
    return new Promise(function (resolve) {
      var tx, rq;
      try {
        tx = db.transaction(DRAFT_STORE, 'readonly');
        rq = tx.objectStore(DRAFT_STORE).index(DRAFT_TIME_INDEX).openKeyCursor(null, 'prev');
      } catch (e) { resolve({ ok: false, savedAt: null }); return; }
      rq.onsuccess = function () {
        var cur = rq.result;
        resolve({ ok: true, savedAt: (cur && typeof cur.key === 'number') ? cur.key : null });
      };
      rq.onerror = function () { resolve({ ok: false, savedAt: null }); };
      if (tx) tx.onabort = function () { resolve({ ok: false, savedAt: null }); };
    });
  }
  function idbWalkDraftVictims(db, need) {
    return new Promise(function (resolve) {
      var tx, rq;
      try {
        tx = db.transaction(DRAFT_STORE, 'readonly');
        rq = tx.objectStore(DRAFT_STORE).index(DRAFT_TIME_INDEX).openCursor(null, 'next');
      } catch (e) { resolve(null); return; }
      var entries = [], clean = 0, done = false;
      var finish = function (out) { if (done) return; done = true; resolve(out); };
      rq.onsuccess = function () {
        if (done) return;
        var cur = rq.result;
        if (!cur) { finish({ entries: entries, clean: clean }); return; }   // 走完了
        var rec = cur.value || {};
        if (!rec.dirty) clean++;
        entries.push({ key: cur.primaryKey, savedAt: cur.key, dirty: !!rec.dirty });
        if (clean >= need) { finish({ entries: entries, clean: clean }); return; }
        cur['continue']();                            // 不调它,游标就停在第一条上
      };
      rq.onerror = function () { finish(null); };
      if (tx) tx.onabort = function () { finish(null); };
    });
  }
  var draftTimer = null;
  var draftRev = 0;              // 地图每次变动 +1(判"这一版写过没有")
  var draftSavedRev = -1;        // 上一次草稿落盘时的 rev
  var lastAutoSaveAt = 0;        // 状态栏那一格要显示的自动保存时刻(0 = 本局还没自动存过)

  // 唯一一处"地图变了"的落笔:设脏标记 + 排一次防抖落盘。全项目五个改动点
  //   (落一笔 / 撤销重做 / 新建 / 复制 / 改名)都走这里 —— 散开写 dirty = true 的话,
  //   新加一个改动点只会忘掉草稿那一半,而那是不报错的(草稿盘悄悄少一条)。
  function markDirty() {
    dirty = true;
    draftRev++;
    scheduleDraftSave();
  }
  // 最后一笔之后延迟 DRAFT_DEBOUNCE_MS 保存，避免每笔都调用编码 worker。
  function scheduleDraftSave() {
    if (!app.map || !app.db) return;             // 草稿盘不可用:连定时器都不排
    if (draftTimer) clearTimeout(draftTimer);
    draftTimer = setTimeout(function () { draftTimer = null; return saveDraft(false); }, DRAFT_DEBOUNCE_MS);
  }
  // 离开页面/刷新前的那次补刀:防抖可能还没到点 —— 不补的话"刚画完就 F5"丢掉最后 1.5 秒的活。
  // 判据用 dirty(磁盘那一侧)而不是 rev:刚 Ctrl+S 过的图不该因为一次刷新又被标成脏草稿
  //   (那会让下次打开弹一次假的恢复提示)。
  function flushDraft() {
    if (draftTimer) { clearTimeout(draftTimer); draftTimer = null; }
    if (!dirty) return Promise.resolve();
    return saveDraft(true);                      // force:绕过节流(见 saveDraft)
  }
  // 落盘一份草稿(含字节:草图以编码后的字节存,恢复时走同一条解码路)
  // force = 不因为"这一版写过"就跳过(离开页面前那一刀要的是此刻的一份)。
  //   不带 force 时那道判据挡的是:落了笔 → Ctrl+S(markDraftSaved 把 rev 记下)→ 那个
  //   还在飞的防抖定时器到点又把同内容写回脏草稿(下次打开于是弹一次假的恢复提示)。
  // 但 force 越不过编码之后那道判据 —— 那一条不是"省点活",是正确性(见下)。
  // 一条记录的两半(它是谁 / 它是什么内容)必须在同一个瞬间取:编码是异步的
  //    (codec 是 Worker,400×300 的图 × 4 层 ≈ 30MB ⇒ 几百毫秒到几秒),而这段时间里用户
  //    完全可能换一张图(点库里的另一张 —— 见 openMap,它不问有没有没写盘的活)。
  //    编码之后再读 currentDraftKey()/app.name 的话:写出来的是 {key:'B', name:'B.cyrm',
  //    bytes: <A 的内容>} —— 下次打开 B、字节比不过 B 的文件 ⇒ 弹一次恢复 ⇒ 用户一按
  //    Ctrl+S 就把 A 的地形写进 maps/B.cyrm。字节相等那道闸让这件事更糟,不是更好:
  //    它把"一次假提示"换成了"静默的内容掉包"。
  function saveDraft(force) {
    if (!app.map || !app.db) return Promise.resolve();
    var rev = draftRev;
    if (!force && rev <= draftSavedRev) return Promise.resolve();
    // 进编码之前取:内容的来源,以及这份内容属于谁
    var mapAtEntry = app.map;
    var key = currentDraftKey();
    var name = app.name, name2 = app.map.name;
    return encodeForWrite(mapAtEntry).then(function (bytes) {
      // 编码期间可能已经有了一次 Ctrl+S:它把这一版(或更新的一版)写进了真文件,
      //    并把草稿标干净 —— 这时再写回一份 dirty 的草稿,下次打开就会弹一次假的
      //    恢复提示(而且不报错)。故落盘前再看一眼。这一条 force 也要过:
      //    离开页面前那一刀同样不该把"已经进真文件的那一版"写回成脏草稿。
      if (rev <= draftSavedRev) return null;
      // 另一半:这一版字节属于哪张图(身份,不是名字)。编码期间 app.map 被换过
      //    (openMap / 新建 / 复制 / 崩溃恢复)⇒ 这条记录没有任何意义:它的 key 是新的
      //    那张、字节是旧的那张。此时唯一正确的动作是整笔放弃 —— 新的那张图自己那一版
      //    会由它自己的防抖定时器落盘(openMap 已经把 draftSavedRev 推到当前 rev,所以
      //    "刚打开、一笔没画"的那张图连一条脏记录都不会留下 ⇒ 也不会在下一次开机弹提示)。
      if (app.map !== mapAtEntry) return null;
      var rec = { key: key, name: name, name2: name2, bytes: bytes,
                  savedAt: Date.now(), dirty: true };
      return idbPut(app.db, DRAFT_STORE, rec).then(function () {
        draftSavedRev = rev;             // 能走到这里 ⇒ 上面那道判据刚过,故这一定是推进
        lastAutoSaveAt = rec.savedAt;
      });
    }).then(function () {
      renderSaveState();
      return pruneDrafts();
    }).catch(function (e) {
      status('草稿盘写入失败:' + msgOf(e) + '(作品仍在,请尽快 Ctrl+S 写盘)');
    });
  }
  // Ctrl+S 成功之后:磁盘上那份就是屏幕上这份 ⇒ 草稿盘里那条标干净(不删:留着它,
  // 既是"上次停在哪"的记录,也让 evictPlan 优先淘汰它)。
  // 与 dirty = false 同一处、同一条纪律:只有真的写成功了才调它。
  function markDraftSaved(key) {
    if (!app.db) return Promise.resolve(false);
    draftSavedRev = draftRev;
    lastAutoSaveAt = 0;
    return loadDraft(key || currentDraftKey()).then(function (rec) {
      if (!rec) return false;
      rec.dirty = false;
      return idbPut(app.db, DRAFT_STORE, rec).then(function () { return true; });
    }).catch(function () { return false; });   // 标不干净不影响"已经存盘了"这个事实
  }
  function pruneDrafts() {
    var didNotRun = '(这次的草稿已存下,但 ' + MAX_LIB + ' 条上限这次没生效)';
    return idbCount(app.db, DRAFT_STORE).then(function (n) {
      if (n === null) { status('草稿盘清理失败:读不到条目数 ' + didNotRun); return null; }
      if (n <= MAX_LIB) return null;                  // 常态:只数一次,一条都不读
      var need = n - MAX_LIB;
      return idbWalkDraftVictims(app.db, need).then(function (walk) {
        if (walk === null) { status('草稿盘清理失败:读不到草稿列表 ' + didNotRun); return null; }
        // cap 取 entries.length - need:走的这一批要么恰好含 need 条干净的
        //    (这时 evictPlan 丢掉的就是它们),要么就是全库(干净的凑不够 ⇒ 一直走完),
        //    那时 entries.length - need 正好还原成 MAX_LIB —— 两种情形同一条公式,
        //    淘汰口径仍然只有 evictPlan 这一处。
        var plan = evictPlan(walk.entries, walk.entries.length - need);
        if (!plan.drop.length) return null;
        var tx;
        try { tx = app.db.transaction(DRAFT_STORE, 'readwrite'); }
        catch (e) { status('草稿盘清理失败:' + msgOf(e) + ' ' + didNotRun); return null; }
        plan.drop.forEach(function (k) { tx.objectStore(DRAFT_STORE).delete(k); });
        return new Promise(function (resolve) {
          tx.oncomplete = function () { status('草稿盘超过 ' + MAX_LIB + ' 条,已清掉 ' + plan.drop.length + ' 条最老的'); resolve(true); };
          tx.onerror = function () { status('草稿盘清理失败:删不掉那 ' + plan.drop.length + ' 条 ' + didNotRun); resolve(false); };
          tx.onabort = function () { status('草稿盘清理失败:删除事务被中止 ' + didNotRun); resolve(false); };
        });
      });
    }).catch(function (e) {
      status('草稿盘清理失败:' + msgOf(e) + ' ' + didNotRun);
      return null;
    });
  }
  function loadDraft(key) {
    if (!app.db) return Promise.resolve(null);
    return new Promise(function (resolve) {
      var tx = app.db.transaction(DRAFT_STORE, 'readonly');
      var rq = tx.objectStore(DRAFT_STORE).get(key);
      rq.onsuccess = function () { resolve(rq.result || null); };
      rq.onerror = function () { resolve(null); };
    });
  }
  // ── 草稿盘的读侧:启动时那份"没写盘的活"要不要恢复 ──
  // 判据是记录自己的 dirty(Ctrl+S 成功会把它标干净)—— 存过盘的下次不再问。
  // 不静默恢复:画布上突然换成一份与真文件不同的图,而用户以为它就是文件里那份,
  //   接下来一按 Ctrl+S 就把草稿盖回文件上 —— 那是这一层最坏的一种失败。故一律问一次。
  function offerDraft() {
    if (!app.db || !app.map) return Promise.resolve(false);
    var key = currentDraftKey();
    return loadDraft(key).then(function (rec) {
      if (!rec || !rec.dirty || !rec.bytes) return false;
      // 再判一道(挡"假提示"那一类):草稿那份与刚从真文件读进来的字节逐字节相同
      //    ⇒ 那一版已经在文件里了,只是"标干净"那一步没落地(页面关得太快,或者走了"另存为")。
      //    问它就是一次假恢复提示 —— 而这层的承诺是"存的活不丢",不是"每次都问一遍"。
      //    退化的方向是安全的:万一编码哪天不再确定,这里只是问得多一点。
      if (sameBytes(rec.bytes, app.raw)) return false;
      var yes = window.confirm('发现一份还没写盘的草稿(' +
                               new Date(rec.savedAt || 0).toLocaleString() + '),要恢复吗?');
      if (!yes) { status('草稿仍在草稿盘里(屏幕上的图没被动过)'); return false; }
      return Io.decodeMap(rec.bytes).then(function (map) {
        map.name = rec.name2 || map.name || '';
        app.map = map;
        if (rec.name) app.name = rec.name;
        dirty = true;                       // 屏幕上这份 ≠ 磁盘上那份 ⇒ 必须说「未保存」
        guard('草稿恢复', function () { return app.r.setMap(map); });
        refreshStatus(); statusLine();
        status('已从草稿恢复:' + (rec.name2 || key));
        return true;
      });
    }).catch(function (e) { status('草稿恢复失败:' + msgOf(e)); return false; });
  }
  // 逐字节相同(长度先过;两边都可能是 Uint8Array,也可能有一个是 null —— 那就不相同)
  function sameBytes(a, b) {
    if (!a || !b || a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  // ── UI 小状态(第 3 层):恢复与落盘 ──
  function applyUiState() {
    var u = app.uist;
    if (!u) return;
    // 缩放必须在地图打开之后恢复:setMap 自己会 fit(),先设会被它覆盖掉。
    //   u.zoom === 0 是"没存过缩放"的哨兵 ⇒ 保持 setMap 的 fit。
    var cur = app.r.view().zoom;
    if (u.zoom > 0 && cur > 0 && Math.abs(u.zoom - cur) > 1e-6) {
      // 分帧重建的错误以 Promise 拒绝返回，由 guard 处理。
      guard('恢复缩放', function () { return app.r.setZoomAt(app.canvas.width / 2, app.canvas.height / 2, u.zoom / cur); });
    }
    setLayer(u.layer);
    app.r.setGrid(u.grid); app.r.setSubGrid(u.subGrid);
    app.r.setTorus(u.torus); app.r.setDimOthers(u.dimOthers);
    app.st.tool = u.tool;
    app.st.brushSize = u.brushSize;
    // 恢复工具状态后同步按钮高亮。
    selectToolButton();
    if (u.selectedTexture > 0) {
      app.st.desc = Core.packDesc(clampTexture(u.selectedTexture, Render.atlasCapacity()),
                                  Core.hueOf(app.st.desc), Core.brightOf(app.st.desc),
                                  Core.satOf(app.st.desc), Core.alphaOf(app.st.desc));
    }
    // DOM 必须与上面保持一致:否则"页面显示的"与"实际用的"是两回事(开关显示关着、其实开着)
    [['tg-grid', u.grid], ['tg-subgrid', u.subGrid], ['tg-torus', u.torus]].forEach(function (pair) {
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
    if (uiSaveTimer || !app.map || !app.st) return;
    uiSaveTimer = setTimeout(function () {
      uiSaveTimer = null;
      var prev = app.uist || uiStateDefaults();
      app.uist = {
        layer: app.r.layer(), zoom: app.r.view().zoom, tool: app.st.tool,
        brushSize: app.st.brushSize,
        grid: $('tg-grid') ? $('tg-grid').classList.contains('on') : true,
        subGrid: $('tg-subgrid') ? $('tg-subgrid').classList.contains('on') : false,
        torus: $('tg-torus') ? $('tg-torus').classList.contains('on') : true,
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
    onWin('pagehide', function () { persistUi(); flushDraft(); });
  }

  function installCrashFence() {
    function snapshot(why) {
      if (!app.map || !app.db) return;
      encodeForWrite(app.map).then(function (bytes) {
        return idbPut(app.db, CRASH_STORE, {
          key: 'crash', name: app.name, name2: app.map.name, bytes: bytes,
          savedAt: Date.now(), why: String(why || '').slice(0, 200),
        });
      }).catch(function () { /* 崩溃路径上什么都不该再抛 */ });
    }
    onWin('error', function (ev) {
      status('页面异常:' + (ev && ev.message ? ev.message : '未知'));
      snapshot(ev && ev.message);
    });
    onWin('unhandledrejection', function (ev) {
      status('未处理的 promise 拒绝:' + msgOf(ev && ev.reason));
      snapshot('unhandledrejection');
    });
  }
  // 下次打开时看一眼崩溃槽位:比主草稿新 ⇒ 上次是异常退出 ⇒ 问一次要不要恢复。
  // 它排在 openFromUrl() 之后(bootLoad 的顺序):恢复出来的图要压住文件里那份,
  //   否则用户点了"确定"、屏幕上却是刚从文件打开的那张(人眼清单第 3 条正是看这个)。
  // 两处读取都是点读,不是整库 getAll(启动路径上每一次物化整库 = 几十 MB):
  //   崩溃槽位是一条记录(get('crash')),而"主草稿有多新"只要一个时刻 —— 走索引键游标。
  // 读失败不许折成"没有崩溃快照":那是这一层最后一次兜底,静默消失 = 作品丢了而
  //   没人知道。故两条点读都交回 ok:false,这里把它变成状态栏上的一句话。
  function checkCrashSlot() {
    if (!app.db) return Promise.resolve(false);
    return Promise.all([idbGetOne(app.db, CRASH_STORE, 'crash'),
                        idbNewestSavedAt(app.db)]).then(function (both) {
      var cre = both[0], newest = both[1];
      if (!cre.ok || !newest.ok) {
        status('崩溃槽位读取失败:草稿盘读不到(这一次的「上次异常退出」没有检查到)');
        return false;
      }
      var crash = cre.rec;
      // crashIsNewer 只读 savedAt ⇒ 这里按同一个形状交一个"记录"给它(索引键游标
      //   拿到的就是那个时刻,记录本体一个字节都没读)。
      var main = (newest.savedAt === null) ? null : { savedAt: newest.savedAt };
      if (!crashIsNewer(crash, main)) return false;
      var yes = window.confirm('上次异常退出,已恢复到崩溃前(草稿:' + (crash.name2 || crash.name || '?') +
                               ')。要打开它吗?');
      if (!yes) {
        // 记下"问过、用户不要":不记的话下一次打开又弹同一个框(crashIsNewer 读这个字段)。
        //   记录本身留着 —— 那是没写盘的活,不能因为点了一次"不要"就删掉。
        crash.declined = true;
        return idbPut(app.db, CRASH_STORE, crash).then(function () { return false; })
                 .catch(function () { return false; })      // 记不住只是下次再问一次
                 .then(function () {
                   status('崩溃快照仍在崩溃槽位里(屏幕上的图没被动过)');
                   return false;
                 });
      }
      return Io.decodeMap(crash.bytes).then(function (map) {
        map.name = crash.name2 || '';
        app.map = map; app.name = crash.name;
        dirty = true;                  // 屏幕上这份 ≠ 磁盘上那份(不回血:该 Ctrl+S 了)
        guard('崩溃恢复', function () { return app.r.setMap(map); });
        refreshStatus(); statusLine();
        status('已从崩溃前快照恢复:' + (crash.name || ''));
        return consumeCrashSlot().then(function () { return true; });
      }).catch(function (e) { status('崩溃快照解码失败:' + msgOf(e)); return false; });
    }).catch(function (e) { status('崩溃槽位读取失败:' + msgOf(e)); return false; });
  }
  // 恢复成功 ⇒ 消费掉这条快照:留着的话每一次打开都会再弹一次「上次异常退出」
  //   (一次偶发页面异常 = 一个永久的开机弹窗 —— 用户每次开编辑器都看得见)。清不掉不是致命的
  //   (下一次打开还会问,而那时用户点"不要"会被 declined 记住),故这一处失败不打扰用户
  //   —— 它是报告里"静默清单"的一条(有意的静默:退化方向是安全的)。
  function consumeCrashSlot() {
    return new Promise(function (resolve) {
      var tx;
      try { tx = app.db.transaction(CRASH_STORE, 'readwrite'); }
      catch (e) { resolve(false); return; }
      tx.objectStore(CRASH_STORE).delete('crash');
      tx.oncomplete = function () { resolve(true); };
      tx.onerror = function () { resolve(false); };
      tx.onabort = function () { resolve(false); };
    });
  }

  function buildPanels() {
    document.querySelectorAll('#layers .layer-row').forEach(function (row) {
      var L = parseInt(row.dataset.layer, 10);
      row.addEventListener('click', function () { setLayer(L); });
      row.querySelector('.vis').addEventListener('click', function (ev) {
        ev.stopPropagation();
        var on = !app.r.layerVisible(L);
        app.r.setLayerVisible(L, on);
        this.style.opacity = on ? '1' : '0.35';
      });
      row.querySelector('.lock').addEventListener('click', function (ev) {
        ev.stopPropagation();
        var on = !app.r.layerLocked(L);
        app.r.setLayerLocked(L, on);
        this.style.opacity = on ? '0.35' : '1';
      });
    });
    var pal = texturePalette(app.tileDefs);
    var box = $('palette');
    pal.forEach(function (e) {
      var b = document.createElement('button');
      b.className = 'sw';
      b.title = e.tex + ' ' + e.name + (e.type ? '(' + e.type + ')' : '');
      b.textContent = String(e.tex);
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
    document.querySelectorAll('#toolbar .tool').forEach(function (b) {
      b.addEventListener('click', function () { app.st.tool = b.dataset.tool; selectToolButton(); });
    });
    $('tg-grid').addEventListener('click', function () {
      this.classList.toggle('on'); app.r.setGrid(this.classList.contains('on'));
    });
    $('tg-subgrid').addEventListener('click', function () {
      this.classList.toggle('on'); app.r.setSubGrid(this.classList.contains('on'));
    });
    $('tg-torus').addEventListener('click', function () {
      this.classList.toggle('on'); app.r.setTorus(this.classList.contains('on'));
    });
    var dim = $('dim-others');
    if (dim) dim.addEventListener('change', function () { app.r.setDimOthers(dim.checked); });
    var p1 = $('spawn-p1'), p2 = $('spawn-p2'), en = $('spawn-enemy'), cl = $('spawn-clear');
    if (p1) p1.addEventListener('click', function () { spawnAt('player', 0); });
    if (p2) p2.addEventListener('click', function () { spawnAt('player', 1); });
    if (en) en.addEventListener('click', function () { spawnAt('enemy', 0); });
    // 与它三个兄弟(spawn-p1/spawn-p2/spawn-enemy,都走 spawnAt)对齐:没打开地图时
    //    说「先打开一张地图」,而不是把 clearSpawns(null) 的 TypeError 抛进 click 处理器 ——
    //    后者经 window.onerror 变成「页面异常:…」,同一个面板里四个按钮两种说法。
    if (cl) cl.addEventListener('click', function () {
      guard('清空出生点', function () {
        if (!app.map) { status('先打开一张地图'); return null; }
        return pushAndShow(clearSpawns(app.map));
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
    var libList = $('lib-list');
    if (libList) {
      libList.addEventListener('click', function (ev) {          // 委托一次,不给每行挂监听
        var row = ev.target.closest ? ev.target.closest('.lib-row') : null;
        // 必须经 guard 收口:openMap 的失败是常态(点到一个陈旧/写错的名字 ⇒ HTTP 404),
        //    而丢掉这个 promise 会让拒绝逃到全局围栏 —— 围栏会 snapshot(),于是
        //    "一次普通的打开失败"把当前这张图写进崩溃槽位,下次开机弹假的
        //    「上次异常退出,要恢复吗?」。这正是账本已经打过两次的那类假提示。
        //    guard 是终点:失败变成状态栏上一行「出错了(打开地图):HTTP 404」(看得见),
        //      且一个字节都不进崩溃槽位。
        if (row && row.dataset.name) {
          guard('打开地图', function () { return openMap(row.dataset.name); });
        }
      });
    }
    var bn = $('btn-new'), bd = $('btn-dup'), br = $('btn-rename'), bx = $('btn-del');
    if (bn) bn.addEventListener('click', function () {
      var name = window.prompt('新地图名字(不含 .cyrm)', 'new_map');
      if (!name) return;
      var m = createEmptyMap(name, 125, 75);       // 尺寸只经这一个闸
      app.map = m; app.name = freshName(name);

      undoHistory = createHistory({});
      markDirty();
      guard('新建地图', function () { return app.r.setMap(m); });
      status('新建 ' + app.name + '(还没写盘 —— Ctrl+S 才落盘)');
      refreshStatus(); statusLine();
    });
    if (bd) bd.addEventListener('click', function () {
      if (!app.map) { status('先打开一张地图'); return; }
      var copy = resizeMap(app.map, Core.cellsWOf(app.map), Core.cellsHOf(app.map)).map;
      copy.name = (app.map.name || 'map') + '_copy';
      app.map = copy;
      app.name = freshName(copy.name);

      undoHistory = createHistory({});
      markDirty();                    // 同上:副本也只活在内存里(还没写盘)
      guard('复制地图', function () { return app.r.setMap(copy); });   // 同上:分帧重建的 promise
      status('已复制为 ' + app.name + '(还没写盘)');
      refreshStatus();
    });
    if (br) br.addEventListener('click', function () {
      if (!app.map) { status('先打开一张地图'); return; }
      var n = window.prompt('新的名字(不含 .cyrm)', app.map.name);
      if (!n) return;
      app.map.name = Core.sanitizeName(n);
      app.name = app.map.name + '.cyrm';
      markDirty();                    // 改名只改内存里那份(磁盘上还是旧名字,要 Ctrl+S 才落盘)
      status('改名为 ' + app.name + '(还要 Ctrl+S 才写盘)');
      refreshStatus();
    });
    if (bx) bx.addEventListener('click', function () {
      status('删除地图请直接在磁盘上删 maps/ 下的文件(编辑器不做删除动作 —— 这是故意的)');
    });
    var exp = $('btn-export');
    if (exp) exp.addEventListener('click', showExportReport);
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
    var g = document.querySelector('#toolbar .tool[data-tool="gradient"]');
    if (g) g.style.opacity = isBg ? '1' : '0.45';
  }

  function spawnAt(kind, playerIndex) {
    if (!app.map) { status('先打开一张地图'); return; }
    var v = app.r.view();
    // 视图中心那一格(不猜鼠标位置:按下按钮时鼠标在按钮上)
    var cx = Math.round((v.x + app.canvas.width / v.zoom / 2) / Core.SUB_PER_CELL);
    var cy = Math.round((v.y + app.canvas.height / v.zoom / 2) / Core.SUB_PER_CELL);
    var types = importEnemyTypes();
    if (kind === 'player') {
      // P1/P2 是位置语义、不是"第几条记录":游戏侧 map_format.gd 按顺序读
      //    player / player2。故放 P1 = 写第 0 条,放 P2 = 写第 1 条。
      //    缺号一律显式拒绝并说明理由 —— 绝不 push 出一条位置不对的记录:在零出生点的
      //      图上放 P2 而 push 出去,磁盘上那条会被游戏读成 P1(状态栏刚说"P2 放到 …",
      //      数据却是 P1),而且一个字都不报。同理,"放 P1"若也走 push,图上只有 P1 时
      //      再点一次就会长出第 2 条 —— 那条位置正好是 P2,于是 P2 被悄悄换掉。
      if (app.map.players.length < playerIndex) {
        status('先放 P' + playerIndex + ':出生点按位置读(player / player2),P' + (playerIndex + 1) +
               ' 之前必须有 P' + playerIndex);
        return;
      }
      var before = snapshotSpawns(app.map);
      var px = Render.wrapIdx(Math.floor(cx), Core.cellsWOf(app.map));
      var py = Render.wrapIdx(Math.floor(cy), Core.cellsHOf(app.map));
      if (app.map.players.length === playerIndex) app.map.players.push({ x: px, y: py });
      else app.map.players[playerIndex] = { x: px, y: py };
      pushAndShow(spawnDiff(before, snapshotSpawns(app.map)));
      status('P' + (playerIndex + 1) + ' 放到 (' + px + ',' + py + ')');
      return;
    }
    pushAndShow(addSpawn(app.map, 'enemy', cx, cy, types[0] || 'fly_bird'));
    status('敌人放到 (' + cx + ',' + cy + ')');
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
      img.src = globalThis.CYRM_OFFLINE ? globalThis.CYRM_OFFLINE.atlasUrl : 'structure.png';
    });
  }

  // ── 打开地图(拉字节 → 解码 → 挂到渲染器)──
  function openMap(name) {
    status('打开 ' + name + ' …');
    return mapRequest('/api/map?p=' + encodeURIComponent(name))
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); })
      .then(function (buf) {
        // 字节先落在局部量里:解码成功之后才认领成 app.raw(见下一条注释)。
        var bytes = new Uint8Array(buf);
        return mapFromBytes(name, bytes).then(function (out) {
          return { out: out, bytes: bytes };
        });
      })
      .then(function (got) {
        var out = got.out;
        app.raw = got.bytes;
        app.map = out.map; app.name = name;
        dirty = false;                 // 打开 = 屏幕上这份与磁盘上那份同源(见 dirty 那段)
        // 同一个纪律的另两笔账也要一起归位,漏了哪一笔都是"不报错但看得见":
        //   ① draftSavedRev 推到当前 rev —— 上一张图留下的那个还在飞的防抖定时器到点
        //      时会走 saveDraft 顶部那道判据,于是不会给这张"刚从文件打开、一笔都没画过"
        //      的图写出一条 dirty:true 的草稿。不推的话:下次开机打开这张图会弹一次假的
        //      恢复提示(而且草稿里那份与文件里那份逐字节相同 —— 全靠 offerDraft 的字节闸兜住,
        //      那是第二道防线,不该当第一道用)。与 Ctrl+S 的收尾 markDraftSaved 推的是
        //      同一个变量、同一条理由。
        //   ② lastAutoSaveAt 归零 —— 否则状态栏那一格显示的是上一张图的「已自动保存
        //      12:34」,而这张图这一局还没自动存过(人眼读到的是"这张图存过了")。
        draftSavedRev = draftRev;
        lastAutoSaveAt = 0;
        return Promise.resolve(app.r.setMap(app.map)).then(function () {
          refreshStatus();
          status('已打开 ' + name);
        });
      });
  }

  function putMapBytes(name, bytes) {
    return mapRequest('/api/map?p=' + encodeURIComponent(name), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: new Blob([bytes]),
    }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status + (r.status === 415 ? '(内容类型不对)' : ''));
      return r.json();
    });
  }

  function refreshStatus() {
    var m = app.map;
    if (!m) return;
    var set = function (id, txt) { var el = $(id); if (el) el.textContent = txt; };
    set('st-name', (m.name || '(无名)') + (app.name ? ' · ' + app.name : ''));
    set('st-size', Core.cellsWOf(m) + '×' + Core.cellsHOf(m) + ' 格');
    // 尺寸面板的两个框也要跟着走 —— 与 renderSaveState 同一条纪律("DOM 必须与状态一致"):
    //    打开/新建/复制/改尺寸/草稿恢复每一条换图的路上,框里都必须是这张图的尺寸。
    //    这里挂(而不是在每一条路上各写一次):refreshStatus 就是那几条路的公共收口,
    //      漏一处就是"框里写着上一张图的尺寸,一按应用尺寸把当前这张改了"。
    sizeInputsSync();
    var rep = Core.validateMap(m);
    set('st-valid', rep.errors.length ? ('error ' + rep.errors.length)
                                      : (rep.warnings.length ? ('⚠ ' + rep.warnings.length) : '校验 OK'));
    renderSaveState();                // 打开/新建/复制/改名/保存后都要跟着翻
  }

  // ── 库列表 ──
  function refreshLibrary() {
    return mapRequest('/api/maps').then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (data) {
      var ul = $('lib-list');
      if (!ul) return;
      ul.innerHTML = '';
      var rows = (data.maps || []);
      if (!rows.length) { ul.textContent = globalThis.CYRM_OFFLINE ? '打开地图文件或选择地图目录' : 'maps/ 下没有 .cyrm'; return; }
      rows.forEach(function (mm) {
        var li = document.createElement('li');
        li.className = 'lib-row';
        li.dataset.name = mm.name;
        li.textContent = mm.name + '  ' + Math.round(mm.size / 1024) + 'KB';
        li.title = new Date(mm.mtime).toLocaleString();
        ul.appendChild(li);
      });
    });
  }

  // ── 启动 ──
  function openFromUrl() {
    var p = new URLSearchParams(location.search).get('p');
    if (p) return openMap(p);
    return refreshLibrary().then(function () {
      var first = document.querySelector('#lib-list .lib-row');
      return first ? openMap(first.dataset.name) : null;
    });
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
    // onError 指到 ui 的 sink:渲染侧那条观察者(resize/fit/setView/… 的拒绝)与
    //    guard 的报告写同一条通道,不靠 render 自己去摸 Editor.status。
    app.r = Render.mount(app.canvas, { onError: reportError });
    installInteraction();
    var ro = new ResizeObserver(function () { guard('resize', function () { return app.r.resize(); }); });
    ro.observe(app.canvas.parentElement);
    var fitBtn = $('btn-fit');
    if (fitBtn) fitBtn.addEventListener('click', function () { guard('fit', function () { return app.r.fit(); }); });

    // 图集必须先就位(渲染第一帧就要它);失败要说出来,而不是画一片黑。
    bootLoad();
  }

  function bootLoad() {
    installCrashFence();
    app.uist = readUiState(localStore());
    app.db = null;
    return openDraftStore().then(function (db) {
      app.db = db;
      if (!db) status('草稿盘不可用(私密模式?)—— 编辑器仍可用,但请及时 Ctrl+S 存盘');
    }).then(function () {
      return loadAtlas();
    }).then(function () {
      buildPanels();
      return openFromUrl();
    }).then(function () {
      return checkCrashSlot();
    }).then(function (recovered) {
      // 崩溃快照比草稿新时才轮到草稿盘(两个都问一遍会连弹两个"要不要恢复" ——
      //   而崩溃那份本来就是更新的那一份)。
      if (recovered) return false;
      return offerDraft();
    }).then(function () {
      applyUiState();
      installUiStateSave();
      return null;
    }).catch(function (e) {
      status('启动失败:' + msgOf(e));
    });
  }

  return {
    boot: boot, status: status, app: app,
    openMap: openMap, refreshLibrary: refreshLibrary,
  };
})();
