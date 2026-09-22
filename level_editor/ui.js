// ui.js —— 编辑器界面(规格 §4.4–§4.8)。
//
// ★★ 顶层一行都不碰 DOM:DOM 只在 boot() 与它装上的回调里取。于是 node 能把
//    "错了也不报错、只在屏幕上看出来"的那几层(工具内核 / 撤销差量 / 名字 / 尺寸钳制)
//    逐条断言 —— 见 editor_smoke.js。
// ★ 页面里不许有第二份数学:像素走 Tint.*,编解码与迁移走 Core.*,几何走 Render.*。
// ★ 依赖顺序:core.js → tile_defs.js → tint.js → render.js → io.js → ui.js。
// ★ 本文件是 T3 的**启动最小版**:图集 / 库列表 / 打开地图 / 挂载渲染 / 状态栏 / 自检。
//   工具、撤销、面板交互、持久化分别在 Task 5~9 落地。
globalThis.Editor = (function () {
  'use strict';

  var Core = globalThis.Core, Render = globalThis.Render, Io = globalThis.Io;
  if (!Core) throw new Error('ui.js: 必须先加载 core.js');
  if (!Render) throw new Error('ui.js: 必须先加载 render.js');
  if (!Io) throw new Error('ui.js: 必须先加载 io.js');

  var UI_STATE_KEY = 'cyrm.ui.v1';
  var DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;

  // 运行时状态(页面用;node 冒烟不碰它)
  // ★ 计划 2b 的接口表把 raw/name/sourceFormat 写成 `Editor.rawBytes()/rawName()/sourceFormat()`
  //   —— 那三个**函数不存在**,真身是下面这个 `app` 对象上的三个字段(`Editor.app.raw` /
  //   `Editor.app.name` / `Editor.app.sourceFormat`,经导出表的 `app: app` 暴露);
  //   Task 8/9 消费的正是 `app.*` 那形式,故无下游断裂,是**接口表那份文本错了**。
  var app = {
    r: null, canvas: null, map: null, name: null,
    raw: null, sourceFormat: null, tileDefs: null,
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

  // ── 错误可见性(★ 症状"按了没反应"的那条通道)──
  // ★★ 面板与渲染里抛出的异常必须**当场说人话**。这条通道做成可替换的 sink,是因为
  //    **两件不同的事**都要落到它上面:
  //    ① `guard` 的同步 try/catch(工具、面板的落笔);
  //    ② Task 4 之后 `resize` / `fit` / `setView` / `setZoomAt` / `panBy` / `setMap` /
  //       `invalidateAll` 返回的是**分帧重建派生出来的 promise** —— 抛在任务回调里 =
  //       一次**拒绝**,同步 try/catch 接不住,画布默默停在上一帧(用户看到的就是
  //       "按了没反应")。`guard` 因此把 thenable 也接住;`Render.mount` 的 `onError`
  //       指到同一个 sink,于是渲染侧那条观察者也写在这条通道上。
  // ★ 默认 sink = 状态栏;有自定义 sink 时**不再** console.error 一次(node 冒烟会故意
  //   触发失败,否则 stderr 里恒有字节,"stderr 有字节 = 有东西红了"这个信号就废了)。
  var errorSinkFn = null;
  function setErrorSink(fn) { errorSinkFn = (typeof fn === 'function') ? fn : null; }
  function reportError(text, err) {
    var custom = errorSinkFn;
    try {
      if (custom) custom(String(text), err);
      else status(text);
    } catch (e) {
      // ★ 报错通道自己坏了也不许把异常扔回调用方(那就成了第二处"看得见才怪")。
      if (typeof console !== 'undefined') console.error(text, e);
    }
    if (!custom && typeof console !== 'undefined') console.error(text, err);
  }

  // ★ 面板与渲染里抛出的异常必须**可见**:症状"按了没反应"最难查,而静默捕获更糟。
  function guard(label, fn) {
    var out;
    try { out = fn(); }
    catch (e) { reportError('出错了(' + label + '):' + msgOf(e), e); return null; }
    // ★ thenable ⇒ 挂收口并**交回已收口的** promise:调用方 await 也好、完全不接也好,
    //   都不会再冒"未处理的 promise 拒绝"(那条全局通道只会说"有个 promise 被拒了",
    //   不说是谁 —— 而这条说的是"哪个入口").
    if (out && typeof out.then === 'function') {
      return out.then(null, function (e) {
        reportError('出错了(' + label + '):' + msgOf(e), e);
      });
    }
    return out;
  }

  // ── 纯函数(editor_smoke.js 直接断言)──
  // ★★ 库的身份就是**文件名**(计划 2a 的裁决 ②),而 v4 的 body 里**没有** name 字段
  //    (decodeMap 返回 name:'')⇒ 导入方必须自己用文件名补 map.name,否则
  //    sanitizeName 会把它回落成 'structure'(地图名字全体变成 structure)。
  function nameFromFile(fileName) {
    return String(fileName == null ? '' : fileName).replace(/\.cyrm$/i, '');
  }
  // 三种输入(规格 §3.6):v4 二进制 / 带 `# cyrm-v3` 标记的 v3 文本 / 旧字母格式。
  // ★ 判据只此一处:先嗅 v4 的 magic(4 字节),否则当文本看 —— 有没有 v3 标记由
  //   Core.isV3Text 判,没有标记就是旧字母格式(parseV3Text 自己会走 2×2 折叠那条路)。
  function detectFormat(bytes) {
    var b = (bytes && bytes.length !== undefined) ? bytes : null;
    if (b && b.length >= 4 && b[0] === 0x43 && b[1] === 0x59 && b[2] === 0x52 && b[3] === 0x4D) return 'v4';
    var text = new TextDecoder('utf-8', { fatal: false }).decode(b ? b.subarray(0, 4096) : new Uint8Array(0));
    return Core.isV3Text(text) ? 'v3' : 'legacy';
  }
  function mapFromBytes(fileName, bytes) {
    var fmt = detectFormat(bytes);
    if (fmt === 'v4') {
      return Io.decodeMap(bytes).then(function (map) {
        map.name = nameFromFile(fileName);          // ★★ 见 nameFromFile 的说明
        return { map: map, sourceFormat: 'v4' };
      });
    }
    var text = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
    var map = Core.migrateV3(Core.parseV3Text(text));
    map.name = nameFromFile(fileName);
    return Promise.resolve({ map: map, sourceFormat: fmt });
  }

  // ── 工具集(规格 §4.4)──
  var TOOLS = ['brush', 'rect', 'bucket', 'eraser', 'line', 'select', 'picker', 'gradient'];
  var TOOL_LABELS = { brush: '画笔', rect: '矩形', bucket: '油漆桶', eraser: '橡皮',
                      line: '直线', select: '选框', picker: '吸管', gradient: '渐变' };
  // ★ 纹理 22(水面)在编辑器里可选、在**游戏里是自动派生**(审计 A7):做成可点选调色板
  //   只会产出"编辑器里画的、游戏里看到的"不一样的图(而且不报错),故排除,只在提示里点名。
  var DERIVED_TEXTURES = [22];

  // ── 尺寸与纹理的硬上限(闸 1:一律**钳制**,不报错回滚)──
  // ★★ 唯一的造图入口。Core.createMap **不判** 400×300 上限(它只要求正整数),
  //    所以输入 99999 的那条路必须在这里被 Core.clampMapSize 截住(A8 的原样复发形态:
  //    旧编辑器的 clampMin 第三参是"非数字时的默认值",根本没有上限)。
  function createEmptyMap(name, w, h) {
    var c = Core.clampMapSize(w, h);
    return Core.createMap(Core.sanitizeName(name), c.w, c.h);
  }
  // 纹理号必须**同时**避开两个坑:0(空气,没有贴图)与超出图集容量(越界会抛)。
  // ★★ 上界**派生自图集**(列 × 行,换图集就变):调用方不传就自己问 Render。
  //    容量 < 1(= 图集还没加载 / 一块都放不下 / 畸形图集算出的负数)一律当**"没有信息"**
  //    ⇒ 只给 1,**不是**放宽到描述符位宽那个上界 —— tint 的越界判据是"图集里有没有
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
  // 校验清单(规格 §4.7):只**报告**,不阻止导出。
  function validateLines(report) {
    var out = [];
    var r = report || { errors: [], warnings: [] };
    (r.errors || []).forEach(function (e) { out.push('✖ ' + e); });
    (r.warnings || []).forEach(function (w) { out.push('⚠ ' + w); });
    return out;
  }

  // ── 目标集合(单位换算 + 环面 + 选区约束)──
  function inRect(r, x, y) { return !r || (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h); }
  function idxOf(map, X, Y) {
    return Render.wrapIdx(Y, map.subRows) * map.subCols + Render.wrapIdx(X, map.subCols);
  }
  // ★ 两种单位(格 / 子格)的换算只此一处:region.unit === 'cell' ⇒ 每格 16 个子格。
  function regionCells(map, region, clip) {
    var out = [], seen = new Set();
    function add(X, Y) {
      var wx = Render.wrapIdx(X, map.subCols), wy = Render.wrapIdx(Y, map.subRows);
      if (!inRect(clip, wx, wy)) return;                 // ★ C12:选区约束绘制
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
  // ★★ Core.lineCells 的坐标必须是整数:非整数或 NaN 会让它的 `for(;;)` **死循环、
  //    挂住整个标签页**(计划 1 账本 Task 2 Minor 3)。**所有**调用点都在这里 floor,
  //    editor_smoke 相位 ⑪ 会扫源码钉住"没有第二个没 floor 的调用点"。
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
      if (!inRect(clip, wx, wy)) continue;
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

  // ── Shift 约束(规格 §4.8:直线约束 / 选区等比)──
  // ★ 纯函数,而且是**唯一**一处做这个判断的地方:两个调用点(预览与落笔)必须用同一个
  //   结果,否则预览画的是 A、松手落下去的是 B。
  // ★ 返回值一律 floor:它的产物会直接喂给 lineCells —— 非整数 = 死循环挂住整个标签页。
  //   (★ 本行**刻意不写成**带括号的调用形式:editor_smoke 相位 ⑪ 按"同一行出现调用就必须
  //     出现 Math.floor"这条**逐行**规则扫源码,注释里那半截会被它当成一个调用点。)
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
      // ★ "只改辅码":空气仍是空气(不能凭空长出纹理),有纹理的保留**原纹理**、只换辅码。
      //   少了这一支,整片墙"变暗"的操作会把墙**换成画笔当前选的那个纹理**。
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
  // 返回一个**作业对象**而不是一次性跑完:500×300 的地图跨环面时是 19.2 万格,
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
          if (!inRect(opts.clip, nx, ny)) continue;        // 选区内外是两块互不连通的地
          if (arr && arr[ni] !== seedVal) continue;
          seen.add(ni); queue.push(ni);
        }
      }
      if (head >= queue.length) done = true;
      return { done: done, scanned: n, total: out.length };
    }
    return { runChunk: runChunk, result: function () { return out.slice(); } };
  }

  // ── 渐变(规格 §4.4:**仅背景层**)──
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
    var all = regionCells(map, { unit: 'sub', x0: 0, y0: 0, x1: map.subCols - 1, y1: map.subRows - 1 },
                          opts.clip || null);
    var out = [];
    var head = 0, done = false;
    function runChunk(maxSteps) {
      var n = 0;
      var lim = (maxSteps === undefined || maxSteps < 1) ? 1 : maxSteps;
      while (head < all.length && n < lim) {
        var i = all[head++];
        n++;
        var X = i % map.subCols, Y = Math.floor(i / map.subCols);
        var t = len2 === 0 ? 0 : ((X - ax) * dx + (Y - ay) * dy) / len2;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        out.push({ i: i, rgba: lerpRGBA(rgba0, rgba1, t) });
      }
      if (head >= all.length) done = true;
      return { done: done, scanned: n, total: out.length };
    }
    return { runChunk: runChunk, result: function () { return out.slice(); } };
  }

  // ── 出生点与敌人(★ A9:它们的增删**也要进历史**)──
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

  // ── 改尺寸(★ 与 A8/A10 同源)──
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
  // ★ A10 要求的是"提示并清理"而不是"静默清理" —— 这一行就是那个提示的文案。
  function resizeReportLines(dropped) {
    return (dropped || []).map(function (d) {
      return d.kind === 'enemy'
        ? ('敌人 ' + d.type + ' 落在图外 (' + d.x + ',' + d.y + '),已移除')
        : ('出生点落在图外 (' + d.x + ',' + d.y + '),已移除');
    });
  }

  // ── 热键表(规格 §4.8)──
  // ★ 纯函数:输入事件对象的一个子集,输出命令字符串。★ Ctrl 与 Cmd 一视同仁
  //   (meta):本工具只在本机跑,而 Mac 上那个键是 Cmd。表外的键一律返回 null ——
  //   返回 null 才是"不拦浏览器自己的快捷键"。
  var KEY_TOOLS = { b: 'brush', e: 'eraser', g: 'bucket', l: 'line', m: 'select', i: 'picker' };
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
  // ★ 差量而不是整图快照:一张 125×75 的图是 2.4MB,200 份就是 480MB。
  // ★ 但"改尺寸/换图"这类操作没法差量(table 级),故留一条整图快照的通道
  //   (kind:'whole'),并按**字节**记账 —— 字节预算才是真闸,步数只是廉价上界。
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
      // ★ 至少留一条:一条都留不住时"撤销"这个功能就整体失效了(比多占几 MB 更糟)
      while (total > maxBytes && undos.length > 1) { total -= bytesOfEntry(undos.shift()); }
    }
    return {
      push: function (e) {
        if (!e) return false;                       // 空操作不进历史
        undos.push(e); total += bytesOfEntry(e);
        redos.length = 0;                           // ★ 新编辑之后重做链断掉(标准语义)
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
      if (!s) return;
      map.subCols = s.subCols; map.subRows = s.subRows;
      // ★★ 必须**防御性拷贝**:直接 alias 快照数组的话,撤销之后地图与 entry.before
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
  // ★ 决定 ④:两种数据类型不互相猜。拒绝时**给出原因**(状态栏要显示),不静默。
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

  // ── 选区移动(A1 的重写)──
  // ★ 旧实现的病灶:maxDX = 宽 − 选区宽 **漏了 − 选区.x**,拖动越界后
  //   moveRegion(先清源区再贴目标区)把被裁掉的列静默删掉。
  // ★ 新实现没有"裁剪"这一步:目标格 = 源格 + 偏移(两边都环面折算),
  //   源区里**没被目标覆盖**的格被清空。于是"拖到图外"在环面上就是恒等位移,
  //   结果是"什么都没变"而不是"内容被裁掉"。
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
        to.set(di, arr[si]);                       // ★ 一次性算出目标值(基于**旧**数组读)
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

  // ── 镜像(规格 §4.4 的选框:可移动 / 删除 / 复制粘贴 / 镜像)──
  function mirrorRegion(map, L, sel, axis) {
    if (!sel) return null;
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

  // ── 图集(Task 3:结构图 一次装进来;换图由 Task 8 的"重载贴图"按钮触发)──
  function loadAtlas() {
    return new Promise(function (resolve, reject) {
      var img = new Image();
      img.onload = function () {
        var c = document.createElement('canvas');
        c.width = img.width; c.height = img.height;
        var g = c.getContext('2d', { willReadFrequently: true });
        g.drawImage(img, 0, 0);
        var d = g.getImageData(0, 0, img.width, img.height);
        Render.setAtlas(d.data, img.width, img.height);   // ★ 同时作废 ③ 与 ④
        resolve({ width: img.width, height: img.height });
      };
      img.onerror = function () { reject(new Error('structure.png 加载失败')); };
      img.src = 'structure.png';
    });
  }

  // ── 打开地图(拉字节 → 迁移/解码 → 挂到渲染器)──
  function openMap(name) {
    status('打开 ' + name + ' …');
    return fetch('/api/map?p=' + encodeURIComponent(name))
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); })
      .then(function (buf) {
        app.raw = new Uint8Array(buf);
        return mapFromBytes(name, app.raw);
      })
      .then(function (out) {
        app.map = out.map; app.name = name; app.sourceFormat = out.sourceFormat;
        return Promise.resolve(app.r.setMap(app.map)).then(function () {
          refreshStatus();
          status('已打开 ' + name + '(' + out.sourceFormat + ')');
        });
      });
  }

  // ── 写端点(**页面上唯一会改磁盘的那个调用**)──
  // ★★ 纪律:PUT **必须显式带** `Content-Type: application/json`。服务器(`editor_server.js`)
  //    的写端点只收这一个类型,别的类型一律 415 —— 而不写 `headers` 时浏览器按 body 的
  //    类型推,`new Blob([bytes])` 推出来的是 `application/octet-stream` ⇒ 415。
  //    症状是"点了保存、磁盘上那份没变、只有一行红字",而且**不报错回滚**。故把这条
  //    纪律钉在**唯一**发 PUT 的地方(Task 8 的保存流程调它,不再自己拼一份 fetch)。
  // ★ 不写 method 的都是只读(GET:openMap / refreshLibrary)。
  // ★ 失败原样抛出(不是静默返回):调用方(保存流程)负责把它变成状态栏上的一句话。
  function putMapBytes(name, bytes) {
    return fetch('/api/map?p=' + encodeURIComponent(name), {
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
    var rep = Core.validateMap(m);
    set('st-valid', rep.errors.length ? ('error ' + rep.errors.length)
                                      : (rep.warnings.length ? ('⚠ ' + rep.warnings.length) : '校验 OK'));
  }

  // ── 库列表 ──
  function refreshLibrary() {
    return fetch('/api/maps').then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (data) {
      var ul = $('lib-list');
      if (!ul) return;
      ul.innerHTML = '';
      if (!data.maps.length) { ul.textContent = 'maps/ 下没有 .cyrm'; return; }
      data.maps.forEach(function (mm) {
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
    // ★ 闸 3 没有降级路径 ⇒ 缺 Worker 时的**唯一**正确行为是把话说清楚(而不是静默退回主线程)
    if (!Io.workerAvailable()) {
      var b = $('boot-error');
      if (b) { b.hidden = false; b.textContent = '本环境没有 Web Worker —— 请用 serve.bat 起服务器后打开 http://127.0.0.1:8777/(file:// 下没有 Worker)。'; }
      return;
    }
    // ★★ onError 指到 ui 的 sink:渲染侧那条观察者(resize/fit/setView/… 的拒绝)与
    //    guard 的报告写**同一条通道**,不靠 render 自己去摸 Editor.status。
    app.r = Render.mount(app.canvas, { onError: reportError });
    var ro = new ResizeObserver(function () { guard('resize', function () { app.r.resize(); }); });
    ro.observe(app.canvas.parentElement);
    window.addEventListener('error', function (ev) {
      status('页面异常:' + (ev && ev.message ? ev.message : '未知'));
    });
    window.addEventListener('unhandledrejection', function (ev) {
      status('未处理的 promise 拒绝:' + msgOf(ev && ev.reason));
    });
    var selftestBtn = $('btn-selftest');
    if (selftestBtn) {
      selftestBtn.addEventListener('click', function () {
        selfTest().then(function (line) { status(line); });
      });
    }
    var fitBtn = $('btn-fit');
    if (fitBtn) fitBtn.addEventListener('click', function () { guard('fit', function () { app.r.fit(); }); });

    // ★ 图集必须先就位(渲染第一帧就要它);失败要说出来,而不是画一片黑。
    loadAtlas().then(function () {
      return openFromUrl();
    }).then(function () {
      if (new URLSearchParams(location.search).has('selftest')) {
        return selfTest().then(function (line) { status(line); });
      }
      return null;
    }).catch(function (e) {
      status('启动失败:' + msgOf(e));
    });
  }

  // ── 浏览器自检(★ node 到不了的那半边 —— 人眼验收就靠它打印的那一行)──
  // 判据:文本 `SELFTEST OK`;失败逐条列出。人在浏览器里点「自检」按钮,把那行贴回报告。

  // ★ localStorage:写 → 读 → 删。隐私模式或被策略禁用时 setItem **会抛** ——
  //   这是纯浏览器的失败面,node 侧一条断言都拦不住(持久化在 Task 9 落地在那上面)。
  function probeLocalStorage() {
    try {
      var k = 'cyrm.selftest', v = String(nowMs());
      localStorage.setItem(k, v);
      var same = localStorage.getItem(k) === v;
      localStorage.removeItem(k);
      return same;
    } catch (e) { return false; }
  }
  // ★ IndexedDB:真**开一次库**(只看 typeof 是查不出"被策略拦/隐私模式"的)。
  //   ★ 超时也必须收口:open 被拦时**可能一个回调都不来**,那时自检那一行永远不出现,
  //     看着像按钮坏了 —— 所以 2 秒没有回调就判失败并把原因写出来。
  function probeIndexedDb() {
    return new Promise(function (resolve) {
      var done = false;
      var finish = function (okv, why) {
        if (done) return;
        done = true;
        resolve({ ok: okv, why: why || '' });
      };
      if (typeof indexedDB === 'undefined' || !indexedDB) { finish(false, '本环境没有 indexedDB'); return; }
      var timer = setTimeout(function () { finish(false, '2 秒内没有任何回调(被拦?)'); }, 2000);
      var req;
      try { req = indexedDB.open('cyrm.selftest', 1); }
      catch (e) { clearTimeout(timer); finish(false, msgOf(e)); return; }
      req.onupgradeneeded = function () { /* 建库,不需要任何表 */ };
      req.onerror = function () { clearTimeout(timer); finish(false, 'open 失败'); };
      req.onblocked = function () { clearTimeout(timer); finish(false, 'open 被阻塞'); };
      req.onsuccess = function () {
        clearTimeout(timer);
        var db = req.result;
        try { db.close(); } catch (e) { /* 关不上不影响判据 */ }
        // ★ 顺手删掉自检建的库:不在用户机器上留垃圾(删不掉同样不影响判据)。
        try { indexedDB.deleteDatabase('cyrm.selftest'); } catch (e) { /* 同上 */ }
        finish(true, '');
      };
    });
  }

  function selfTest() {
    var lines = [];
    var fails = 0;
    var check = function (name, cond, extra) {
      if (cond) { lines.push('  ok  - ' + name); }
      else { fails++; lines.push('  FAIL - ' + name + (extra ? '(' + extra + ')' : '')); }
    };
    return Promise.resolve().then(function () {
      check('Worker 可用', Io.workerAvailable());
      check('图集已加载', Render.atlasInfo() !== null,
            Render.atlasInfo() ? '' : 'structure.png 没加载成功');
      check('图集容量 > 0', Render.atlasCapacity() > 0, '实得 ' + Render.atlasCapacity());
      // ★ 工具内核(Task 5):它的产物是**差量**、不碰 DOM,所以能在这里拿一张一次性的
      //   小图真落一笔 —— node 侧那 149 条断言的是同一批纯函数,这里验的是"装进浏览器
      //   之后它们还活着"(脚本没加载全 / 被 CSP 拦 这类失败只有浏览器里看得见)。
      check('工具内核就绪(8 个工具)', TOOLS.length === 8 && typeof applyTool === 'function');
      try {
        var tm = createEmptyMap('selftest-tools', 2, 1);
        var td = applyTool({ map: tm, layer: Core.LAYER_SCENE, desc: Core.neutralDesc(1),
                             rgba: 0xFF00FFFF, brushSize: 1, selection: null, descOnly: false },
                           'brush', { kind: 'cell', x: 0, y: 0 }, null);
        check('落笔产出差量(整格 16 个子格)', !!td && td.idx.length === 16,
              td ? ('实得 ' + td.idx.length) : '没有产出差量');
      } catch (eTool) { check('落笔产出差量(整格 16 个子格)', false, msgOf(eTool)); }
      // ★ "按了没反应"那条通道:故意抛一次,看它有没有落在 sink 上(自定义 sink 时不会
      //   写状态栏、也不会 console.error —— 所以这一条不会污染下面的画面与控制台)。
      var sinkGot = null;
      setErrorSink(function (t) { sinkGot = t; });
      guard('自检', function () { throw new Error('自检用的假错'); });
      setErrorSink(null);
      check('guard 的失败上报到 sink(可见)', !!sinkGot && sinkGot.indexOf('自检用的假错') >= 0,
            sinkGot || '没有上报 —— 那就成了"按了没反应"');
      check('地图已打开', app.map !== null);
      check('画布有尺寸', app.canvas.width > 1 && app.canvas.height > 1,
            app.canvas.width + '×' + app.canvas.height);
      // ★ 持久化的两个 API(Task 9 才落地)现在就探一遍:它们**只在浏览器里**会失败
      //   (隐私模式 / 被策略禁用),而那时症状是"设置存不住" —— 最难查的一类。
      check('localStorage 可读写', probeLocalStorage());
      if (app.map) {
        // ★ 真正的性质是"map.name 等于文件名去掉后缀"(v4 body 里没有 name 字段)
        check('map.name 来自文件名', app.map.name === nameFromFile(app.name),
              'name=' + app.map.name + ' / 文件 ' + app.name);
        check('缩略图已建', app.r.stats().thumbsBuilt > 0);
      }
      return probeIndexedDb().then(function (idb) {
        check('IndexedDB 可打开', idb.ok, idb.why);
        return Io.ping().then(function (p) {
          check('Worker ping 有应答', p && p.pong === true);
          // 端到端:真浏览器里的 Worker + CompressionStream 往返一次
          var m = Core.createMap('selftest', 4, 3);
          for (var i = 0; i < m.layers[Core.LAYER_SCENE].desc.length; i++) {
            m.layers[Core.LAYER_SCENE].desc[i] = Core.neutralDesc(1);
          }
          return Io.encodeMap(m).then(function (bytes) {
            check('浏览器里 encodeMap 产出 "CYRM"', bytes[0] === 0x43 && bytes[1] === 0x59);
            check('压缩路径(compression=1)', bytes[5] === 1);
            return Io.decodeMap(bytes).then(function (back) {
              var a = back.layers[Core.LAYER_SCENE].desc;
              var same = a.length === m.layers[Core.LAYER_SCENE].desc.length;
              for (var k = 0; same && k < a.length; k++) if (a[k] !== m.layers[Core.LAYER_SCENE].desc[k]) same = false;
              check('经 Worker 往返逐格一致', same);
            });
          });
        });
      });
    }).then(function () {
      var head = fails === 0 ? 'SELFTEST OK' : ('SELFTEST FAIL: ' + fails + ' 条');
      if (typeof console !== 'undefined') console.log(head + '\n' + lines.join('\n'));
      return head + ' · 共 ' + lines.length + ' 条检查';
    });
  }

  return {
    boot: boot, guard: guard, status: status, msgOf: msgOf,
    setErrorSink: setErrorSink, reportError: reportError,
    nameFromFile: nameFromFile, detectFormat: detectFormat, mapFromBytes: mapFromBytes,
    openMap: openMap, openFromUrl: openFromUrl, refreshLibrary: refreshLibrary,
    putMapBytes: putMapBytes,
    selfTest: selfTest, refreshStatus: refreshStatus,
    app: app,

    TOOLS: TOOLS, TOOL_LABELS: TOOL_LABELS, DERIVED_TEXTURES: DERIVED_TEXTURES,
    createEmptyMap: createEmptyMap, resizeMap: resizeMap, resizeReportLines: resizeReportLines,
    texturePalette: texturePalette, clampTexture: clampTexture, validateLines: validateLines,
    paintCells: paintCells, valueFor: valueFor, regionCells: regionCells, inRect: inRect,
    idxOf: idxOf, strokePoints: strokePoints, lineTargets: lineTargets, toSub: toSub,
    constrainLine: constrainLine, constrainSquare: constrainSquare,
    applyTool: applyTool, pickAt: pickAt,
    createBucketJob: createBucketJob, createGradientJob: createGradientJob, lerpRGBA: lerpRGBA,
    snapshotSpawns: snapshotSpawns, spawnDiff: spawnDiff, spawnIndexAt: spawnIndexAt,
    addSpawn: addSpawn, removeSpawn: removeSpawn, clearSpawns: clearSpawns,
    commandFor: commandFor, hasSelection: hasSelection,
    MAX_UNDO: MAX_UNDO, MAX_UNDO_BYTES: MAX_UNDO_BYTES, bytesOfEntry: bytesOfEntry,
    createHistory: createHistory, snapshotMap: snapshotMap, bytesOfSnapshot: bytesOfSnapshot,
    wholeDiff: wholeDiff, applyEntry: applyEntry, diffCells: diffCells, cellCountOf: cellCountOf,
    copyRegion: copyRegion, clipSize: clipSize, pasteRegion: pasteRegion,
    moveRegion: moveRegion, mirrorRegion: mirrorRegion,
  };
})();
