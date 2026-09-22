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
  // ── 选区(clip)的成员判据 ──
  // ★★ **判据本体只有一处**:`Render.inSel`(render.js)—— 拖动预览的源格查询
  //    (`selectionSource`)、`moveRegion` 的 from 集合与这里转调的是同一个函数,所以
  //    "预览 / 落笔 / 框内落笔"三处**不可能**再分岔。
  // ★★ 给了 `W`/`H` 就按**环面**折算(先各自折算到主网格、再比相对偏移)。这修掉的是
  //    "接缝另一侧的那半截静默漏掉"那一类:`regionCells` 此前是"先把每一格折算回主网格、
  //    再用**非折算**的 `inRect` 比大小" —— 于是一个**自己跨着接缝**的选区(如 96 宽的图上
  //    `{x:93,w:6}` 盖住 93..95 与 0..2)只在 93..95 上落笔,0..2 那半边**画不进去、也不报错**
  //    (评审发现:Important 2)。非折算的调用点(不给 W/H)语义与从前逐字相同。
  function inRect(r, x, y, W, H) { return !r || Render.inSel(r, x, y, W, H); }
  function idxOf(map, X, Y) {
    return Render.wrapIdx(Y, map.subRows) * map.subCols + Render.wrapIdx(X, map.subCols);
  }
  // ★ 两种单位(格 / 子格)的换算只此一处:region.unit === 'cell' ⇒ 每格 16 个子格。
  function regionCells(map, region, clip) {
    var out = [], seen = new Set();
    function add(X, Y) {
      var wx = Render.wrapIdx(X, map.subCols), wy = Render.wrapIdx(Y, map.subRows);
      if (!inRect(clip, wx, wy, map.subCols, map.subRows)) return;   // ★ C12:选区约束绘制(环面)
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
    // ★★ **不预展开整张图**:旧版在这里对全图调一次 regionCells(500×300 = 15 万条,外加
    //    一个同样大的 Set)—— 那一下是**同步**跑完的,作业还没开始分帧就先卡一帧。
    //    改成逐格推进:顺序仍是行主序(与"全图 regionCells"逐条相同 ⇒ `result()` 的次序不变),
    //    但第一块只算第一块。★ 唯一的语义差异:`scanned` 现在数的是**扫过的格**(含被选区
    //    挡掉的),与油漆桶那边的口径一致(它也数扫过的),而不再是"被收下的格"。
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
        if (!inRect(opts.clip, X, Y, cols, rows)) continue;   // ★ 选区约束(与 regionCells 同一条判据)
        var t = len2 === 0 ? 0 : ((X - ax) * dx + (Y - ay) * dy) / len2;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        out.push({ i: Y * cols + X, rgba: lerpRGBA(rgba0, rgba1, t) });
      }
      if (head >= totalCells) done = true;
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
  // 事件目标是不是一个"正在打字"的控件(评审发现 4)。★ 判据取 tagName 与 isContentEditable,
  // **不取** `ev.target === document.activeElement` 之类:合成事件 / 焦点在 body 时 target 就是
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
      if (!s) {
        // ★ 原先这里是**静默 return**,而它的成因只有一种:`wholeDiff` 还没 `seal()` 就把
        //   entry 塞进了历史(seal 之前 `after` 快照根本不存在)。症状是"撤销有反应、重做
        //   一点反应都没有",且一个字都不报 —— 接口没法强制调用顺序(entry 就是普通对象),
        //   所以**如实上报**,而不是吞掉。
        // ★ 不抛异常:走到这里时历史栈已经动过了(undo 已把这条 pop 进 redo 栈),
        //   抛出会把历史留在半截状态。这是"要看得见",不是"要炸掉"。
        reportError('重做无效:这条整图级历史没有 after 快照(wholeDiff 的 seal() 还没调用,条目就进了历史)');
        return;
      }
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
    // ★★ 非法 axis 必须**当场说人话**,不能靠"两个坐标算出来一样"退化成恒等、再静默回 null ——
    //    那与"镜像了一圈、内容恰好没变"在返回值上**完全同形**,调用方(历史栈/工具栏)分不出
    //    "轴写错了"和"这次镜像没改动任何格"。
    // ★ 处理方式与 `createGradientJob` 对非法图层同款(调用方的**编程错误** ⇒ 抛一条带原因的
    //   中文错),而不是回一个 `{ok:false, why}`:后者会把本函数文档化的返回类型 `diff|null`
    //   破成三种形状,而 Task 7 的 `history.push(mirrorRegion(...))` 会直接拿到那个对象当真。
    //   抛出的错在上层被 `guard(...)` 接住 → 落进状态栏,用户看得见、程序不崩。
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

  // ── 交互(指针 / 滚轮 / 热键)──
  // ★ 一切落笔都走同一条路:applyTool(只碰地图)→ 差量进历史 → renderer.editCells
  //   (只碰缓存与像素)。把"改数据"与"作废缓存"分成两步是刻意的:漏了哪一半
  //   都能在断言里指名道姓。
  var undoHistory = null;
  var clipboard = null;

  // ── 磁盘状态(`#st-save` 那一格,规格 §4.5 的状态栏)──
  // ★★ 状态栏右侧并排的是**两件事**:`#st-save` 说"磁盘上那份是不是这一份",`#status-msg`
  //    说"刚刚发生了什么"。没有这个标志时 `#st-save` 是一格**没有任何写入者**的静态文案
  //    (`editor.html` 写死「未保存」),于是 Ctrl+S 成功的那一刻同一条状态栏上会同时出现
  //    「未保存 | 已保存 demo_copy.cyrm(1234 字节)」—— 两个相邻的 span 当场互相打脸。
  // ★★ 纪律:它**只**在「保存真的成功」与「打开真的成功」两处清零,**绝不**挂在
  //    `guard(...)` 的决议上 —— `guard` 失败时决议的是 `undefined`(见它的实现),把清零
  //    链在它上面会把一次**失败**的保存标成「已保存」,而磁盘上那份一个字都没变。
  // ★ 今天它写的是「未保存 / 已保存」;Task 9 的草稿盘会接管这一格(改成「已自动保存 12:34」),
  //    届时这两个文案就是"没有草稿盘"时的降级值。
  var dirty = false;
  function renderSaveState() {
    var el = $('st-save');
    if (el) el.textContent = dirty ? '未保存' : '已保存';
  }

  function pushAndShow(diff) {
    if (!diff) return false;
    undoHistory.push(diff);
    dirty = true;                     // ★ 落了笔 ⇒ 磁盘上那份已经不等于屏幕上这一份了
    // ★ 两条路都要走:kind:'whole'(改尺寸/换图)改的是**尺寸本身**,`diffCells` 对它是
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
    // ★ 撤销/重做也是一次**改动**:回到"保存时那一刻"的图上仍然显示「未保存」——
    //   这是刻意的(要判"撤销回去了没有"得比整份字节,那是 Task 9 草稿盘的事)。
    //   反过来(把撤销当"变干净")会把"撤了两步、其实还脏着"标成已保存,那才是错的。
    dirty = true;
    if (e.kind === 'whole') {
      // ★ 尺寸可能变了 ⇒ 整片重来。**不是** setMap:那个会把视图重新"适配"并清掉选区,
      //   而撤销一次尺寸变化不该把视野和选区一起重置(而且它建的是"新图"语义)。
      out = Promise.resolve(app.r.invalidateAll());
    } else if (e.kind === 'cells') {
      var cells = diffCells(app.map, e);
      if (cells.length) app.r.editCells(e.layer, cells); else app.r.render();
    } else app.r.render();
    statusLine();
    return out;
  }
  // 长作业(油漆桶 / 渐变):分帧驱动(闸 2)。★★ 让出帧的判据是**时间预算**
  //   (`Render.createSlicer`,默认 8ms/帧),不是固定条数 —— 固定条数在慢机器上照样能把
  //   一帧撑爆,而那正是闸 2 要防的。作业对象只提供"跑一个量子",**一帧跑几个量子由预算定**。
  var JOB_QUANTUM = 2048;        // 一个量子的格数:小到慢机器上一帧也撑不爆(它是超调的上界)
  var JOB_QUANTA = 4096;         // 一轮的量子额度。★ 取得**故意大**:一轮结束必须是因为
                                 //   **预算到点**,而不是因为"条数跑完了"—— 后者又变成固定条数节拍器;
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
    renderSaveState();                // ★ 每落一笔都要跟着翻(状态栏是"现在"的样子)
  }

  function hitOf(ev) {
    var cv = app.canvas;
    var rect = cv.getBoundingClientRect();
    var p = app.r.screenToSub(ev.clientX - rect.left, ev.clientY - rect.top);
    // ★ 两种单位的吸附只在 hitOf 里决定一次:整数画笔吸附到格、小数画笔吸附到子格
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
  // Shift 约束后的落点(★ 规格 §4.8)。★ 预览与落笔**必须**走同一个函数 ——
  //   否则预览画的是 A、松手落下去的是 B(这类不一致只在动手时才看得出来)。
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
    // ★ 两个颜色槽:规格 §4.4 的渐变是"两端各选一色" ⇒ 必须**两个**颜色状态
    //   (rgba = 起点、rgba2 = 终点)。页面今天只有一个 #bg-color 色槽(Task 8 接),
    //   所以第二个先给一个与起点**明显不同**的默认值 —— 给成同一个色的话渐变会退化成
    //   纯色填充,而且看不出来(那一版的"渐变"就是那样)。
    app.st = { tool: 'brush', brushSize: 1, desc: Core.neutralDesc(1),
               rgba: 0xFF00FFFF, rgba2: 0x101820FF,
               descOnly: false, selStart: null, stroke: null, panning: null, selDrag: null,
               gradStart: null };

    cv.addEventListener('contextmenu', function (e) { e.preventDefault(); });

    cv.addEventListener('pointerdown', function (ev) {
      if (cv.setPointerCapture) cv.setPointerCapture(ev.pointerId);
      guard('pointerdown', function () {
        if (ev.button === 1 || ev.altKey) {          // 中键 / Alt = 平移
          app.st.panning = { x: ev.clientX, y: ev.clientY };
          return;
        }
        if (ev.button !== 0) return;
        var hit = hitOf(ev);
        var sel = app.r.selection();
        // ★ 没打开地图时退回线性口径(与 Render.inSel 的 W/H 缺省同款)——指针事件比 setMap
        //   早到是可能的(闸 1:钳制,不报错)
        var W = app.map ? app.map.subCols : 0, H = app.map ? app.map.subRows : 0;
        if (app.st.tool === 'select') {
          // ★ 判"按在选区里"必须先把命中**换算到子格**:整格命中给的是格号,而选区是子格单位
          //   —— 直接比会差 4 倍(而且**永远不成立**),表现为"选框工具一拖就是在重新框选,
          //   选区永远拖不动"。换算只有 toSub 一处。
          // ★★ 判据与 `regionCells` 的 clip **同一个**(`inRect` → `Render.inSel`,带环面折算):
          //   三个"选区"口径(按下算不算在选区里 / 框内落笔算不算有目标 / moveRegion 的 from
          //   集合)此前是**三种**,各自在接缝那一侧给出不同答案 —— 最刺眼的一种是"框里画，
          //   一半画得进去、一半什么都没发生"。
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
          else if (Core.texOf(v) !== 0) app.st.desc = v >>> 0;   // ★ 空气不吸(会吸出一个空纹理)
          status('吸管:0x' + (v >>> 0).toString(16) + (Core.texOf(v) === 0 ? '(空气,未采用)' : ''));
          statusLine();
          return;
        }
        if (app.st.tool === 'bucket') {
          var s0 = stNow();
          var job = createBucketJob(app.map, s0.layer, hit.x * k2of(hit), hit.y * k2of(hit),
                                    { clip: s0.selection });
          runJob(job, function () {
            pushAndShow(paintCells(app.map, s0.layer, job.result(), valueFor(s0, s0.layer)));
          }, '油漆桶填充');
          return;
        }
        if (app.st.tool === 'gradient') {
          // ★ 规格 §4.4:渐变**仅背景层**。工具按钮只是压暗(视觉提示),真正的闸在这里 ——
          //   少了它,在纹理层拖渐变会**悄悄改掉背景层**(屏幕上看不出,因为背景在最底下)。
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
          // ★ 视图入口返回**分帧重建派生出来的 promise**:交回给 guard 收口(相位 ⑪ 的
          //   逐行规则同源 —— 漏了就是"按了没反应"只在控制台留一行)。
          return Promise.resolve(app.r.panBy(dxp, dyp));
        }
        var hit = hitOf(ev);
        if (app.st.selDrag) {                          // ★ 拖动只记偏移(不碰数据)
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
            app.st.stroke.painted = true;              // ★ 见 pointerup:单击也要落一次笔
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
        // ★★ 拖动分支:记录先取到**局部变量**再判 —— **没有在飞的记录就整支跳过**(早退)。
        //    这条早退是承重的,而且它挡的是**两种**"没有记录":
        //    ① 本次按下起的是别的动作(框选/笔画),那两条分支在下面各管各的;
        //    ② 这次拖动**已经被取消**了 —— Esc 的 cancel-selection 会把 `app.st.selDrag`
        //       清掉(见那里):视觉上已经取消,松手就**一个格都不许搬**(否则"看着取消了、
        //       数据却动了"是最坏那种不一致)。
        //    ★ `sd` 的**字段**必须排在判过 `sd` 之后才读:取消之后 `sd` 是 null,少了这层
        //      判会去读它的 `dx`(在 pointerup 里抛 TypeError = 落笔路径整个断掉 ——
        //      "点了一下,什么都没发生,控制台里一条错")。
        var sd = app.st.selDrag;
        if (sd) {
          app.st.selDrag = null;
          app.r.setSelDrag(null, 0, 0);
          // ★ 选区**可能已经**没有了(Esc 走 cancel-selection,而左键还按着)⇒ 没有可搬的
          //   东西。少了这层判,下面那句 `cur.x` 会抛 TypeError(同款后果)。
          var cur = app.r.selection();
          if (cur && (sd.dx !== 0 || sd.dy !== 0)) {
            pushAndShow(moveRegion(app.map, app.r.layer(), cur, sd.dx, sd.dy));
            // ★★ 存回去的选区必须**折算**(评审发现 3):拖动跨过接缝时 `cur.x + sd.dx` 会
            //    落到 [0, subCols) 之外,而 `regionCells` 是"先折算每一格、再 inRect(clip, wx, wy)"
            //    ⇒ clip.x < 0 时**一格都进不来**:框内所有画笔/矩形/直线/油漆桶都产出空集合,
            //    `paintCells` 回 null、`pushAndShow` 回 false —— 而且**一条状态栏消息都没有**
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
            s1.rgba, s1.rgba2, { clip: s1.selection });   // ★ 两端各一色(不是同一个色)
          runJob(gj, function () {
            var res = gj.result(), targets = [], values = [], n = 0;
            for (var i = 0; i < res.length; i++) { targets.push(res[i].i); values.push(res[i].rgba); }
            pushAndShow(paintCells(app.map, Core.LAYER_BG, targets, function () { return values[n++]; }));
          }, '渐变');
          return;
        }
        if (app.st.stroke) {
          var st0 = app.st.stroke;
          app.st.stroke = null;
          app.r.setPreview(null);
          if (app.st.tool === 'rect') {
            pushAndShow(applyTool(stNow(), 'rect', st0.from, hit));
          } else if (app.st.tool === 'line') {
            // ★ Shift 约束(规格 §4.8):直线锁水平/垂直/45° —— 与预览同一个函数
            pushAndShow(applyTool(stNow(), 'line', st0.from, shiftHit(st0.from, hit, ev.shiftKey)));
          } else if (!st0.painted) {
            // ★ 按下与松开之间**没有** pointermove(单击)时,画笔/橡皮的落笔只在 pointermove
            //   那条路上发生 ⇒ 一次单击什么都不画。矩形/直线是松手才落笔、故单击有效;
            //   而"拿画笔点一格"是最常见的编辑动作,必须同样有效。
            // ★ 判据取 `painted` 而不是"last 是否等于 from":pointermove 在**同一格**内也会落笔
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
        // ★ 视图入口的 promise 同样收口(见上面 pointermove 的说明)
        var zp = Promise.resolve(app.r.setZoomAt(ev.clientX - rect.left, ev.clientY - rect.top,
                                                 ev.deltaY < 0 ? 1.25 : 0.8));
        statusLine();
        return zp;
      });
    }, { passive: false });

    window.addEventListener('keydown', function (ev) {
      // ★★ 焦点在**输入控件**里时,一个键都不许拦(评审发现 4):本处理器按键**命令**分发,
      //    而表里有 `Backspace/Delete → clear-selection`、`0-9 → 切层`、`b/e/g/l/m/i → 换工具`、
      //    方向键 → 平移。焦点在输入框里时这些键是**打字**:按 Backspace 会**先被 preventDefault**
      //    (数字删不掉)再**真去 erase 掉整个选区** —— 数据被改,而用户以为自己只是在删一个字符。
      //    `#brush-size` 这类输入框今天就在 DOM 里(editor.html),Task 8 还会把面板的输入全部接上。
      // ★ 判据:`input` / `textarea` / `select` / contenteditable(规格 §4.8 的热键只在画布上生效)。
      if (isTypingTarget(ev.target)) return;
      var cmd = commandFor(ev);
      if (!cmd) return;                                  // ★ 表外的键一律不拦
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
        else if (cmd === 'clear-selection') {
          var s3 = app.r.selection();
          if (!s3) { status('先框选一块'); return; }
          pushAndShow(applyTool({ map: app.map, layer: app.r.layer(), desc: 0, rgba: 0,
                                  brushSize: 0.25, selection: s3 },
                                'rect', { kind: 'sub', x: s3.x, y: s3.y },
                                { kind: 'sub', x: s3.x + s3.w - 1, y: s3.y + s3.h - 1 }));
        }
        else if (cmd === 'cancel-selection') {
          // ★★ Esc 可能在**拖动途中**按下去(左键还按着、`selDrag` 还在飞)而照样合法:选区没了
          //    ⇒ **没有可搬的东西**,这次拖动整支作废。要一起做的是三件事:
          //    ① 清**在飞的拖动记录**(`app.st.selDrag`)—— 它是"这一支拖动还算不算数"的唯一
          //       依据:松手时 pointerup 的拖动分支因此**根本不进**(少了它,提交与否只剩"选区
          //       还在不在"一条判据,"取消"与"别的什么把选区清掉了"就分不开了);
          //    ② 让渲染侧撤掉偏移(`setSelDrag(null)`):内部走一遍 `markDragDirty`,把烤过的
          //       两块按"内容归位"重画 —— 归位是**当场**的,不必等下一次指针事件;
          //    ③ 清选区,框消失。
          //    ★ ②③ 谁先谁后都一样(去烤按哪几块画由 `s.selDrag` 决定,而重画出来的是**什么**
          //      由 `dragSource` 决定 —— 两条判据现在都含 `s.selection`);① 必须排在最前,
          //      因为紧随其后的 pointermove/pointerup 判的正是它。
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
    return Promise.resolve(app.r.panBy(d[0], d[1]));      // ★ 视图入口:promise 交给 guard
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
    // ★ 规格 §4.5:选中的是**背景层**时,右侧的纹理调色板换成颜色选择器,工具条里只有
    //   「渐变」额外可用。这个 hook 由 Task 8 提供(typeof 守卫:Task 7 单独跑时也能过)。
    if (typeof syncPanelForLayer === 'function') syncPanelForLayer();
    statusLine();
  }

  // ── 保存(★ 决定 ⑤:v3 源首次保存要一次显式确认)──
  // ★ 为什么必须确认:仓库里 maps/*.cyrm **今天全是 v3 文本**,而 Ctrl+S 写回原文件
  //   (规格 §4.6)⇒ 一次 Ctrl+S 就把 v3 原文转成 v4 二进制,而迁移是**单向**的
  //   (规格 §3.6「迁移是一次性的」)。期 E 会专门做迁移并先提交一份 v3 原文留档。
  var v3Confirmed = false;
  function needsV3Confirm(srcFmt, confirmed) {
    if (!srcFmt) return false;
    return (srcFmt === 'v3' || srcFmt === 'legacy') && !confirmed;
  }
  function freshName(base) { return Core.sanitizeName(base) + '.cyrm'; }
  function saveTargetName(asNew) {
    if (!app.map) return null;
    return asNew ? freshName((app.map.name || 'map') + '_copy') : app.name;
  }
  function saveCurrent(asNew) {
    if (!app.map) { status('先打开一张地图'); return Promise.resolve(); }
    if (needsV3Confirm(app.sourceFormat, v3Confirmed)) {
      var okGo = window.confirm('原文件是 v3 文本,保存会把它转成 v4 二进制(不可逆)。\n' +
                                '期 E 会专门做迁移并先提交一份 v3 原文留档。(本次会话不再询问)');
      if (!okGo) { status('已取消保存(磁盘上那份没有被碰过)'); return Promise.resolve(); }
      v3Confirmed = true;
    }
    var name = saveTargetName(asNew);
    if (!name) return Promise.resolve();
    status('保存 ' + name + ' …');
    // ★★ 写盘**只走 `putMapBytes` 这一个出口**(页面上唯一发 PUT 的地方):PUT 的
    //    `Content-Type: application/json` 与"body 是**裸字节**"这两条纪律都钉在那里
    //    (不设头 = 浏览器给 Blob 的默认类型 ⇒ 服务器 415 ⇒ "点了保存、磁盘上那份没变",
    //    而且**不报错回滚**)。这里再拼一份 fetch 就是第二个出口,迟早只改一处。
    return Io.encodeMap(app.map, { compress: true }).then(function (bytes) {
      return putMapBytes(name, bytes).then(function (out) {
        app.name = name;
        app.raw = bytes;
        app.sourceFormat = 'v4';
        dirty = false;                 // ★★ 只有**真的**写成功了才清(见 dirty 那段的纪律)
        refreshStatus();
        statusLine();
        // ★★ 库列表刷新排在**说结果之前**:那条 GET 失败时 `guard` 会往**同一条状态栏**
        //    写一行错误 —— 先写「已保存 …」再被它盖掉的话,用户看到的是"刷新失败了",
        //    而保存其实**成功了**(人眼验收清单恰恰是叫用户去看那一行)。故:先把刷新
        //    (无论成败)走完,最后才把保存结果写在最上面那一行。
        //    ★ 代价照实说:刷新失败那行于是只在控制台(reportError 的 console.error)里
        //      留痕、状态栏上是一句「已保存」。刷新只是"列表里的字节数/时间",不影响落盘。
        // ★ `Promise.resolve(...)` 不是装饰:`guard` 在**同步**抛时返回的是 `null`(见它的
        //   实现),直接 `.then` 会在这里炸成一次 TypeError —— 那会被外层 catch 说成
        //   「保存失败」,而保存其实成功了(徽标已经翻成已保存,两句话又打起来)。
        return Promise.resolve(guard('库列表刷新', function () { return refreshLibrary(); }))
               .then(function () { status('已保存 ' + out.name + '(' + out.size + ' 字节)'); });
      });
    }).catch(function (e) {
      // ★ 保存失败要**说出来**;磁盘上那份没被动过(服务器是原子写)
      status('保存失败:' + msgOf(e));
    });
  }

  // ── 敌人类型(来自页面里的注册表 —— 不写死清单)──
  function importEnemyTypes() {
    var reg = globalThis.ENEMY_REGISTRY;
    if (!reg || !reg.length) return [];
    return reg.map(function (e) { return String(e.id); });
  }

  // ── 导出校验(规格 §4.7:只警告,不阻止导出)──
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

  // ── 面板构建(★ 每个控件只挂一次监听 —— 审计 A16:旧实现同时挂了 22 个独立监听
  //    与一个容器委托,点一次跑两遍)──
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
    // 纹理调色板(★ 从 tile_defs 派生;纹理 22 不在其中 —— 审计 A7)
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
      // ★★ 给它一个 id:它是 `#palette` 的**派生行**,背景层上必须跟着一起藏 —— 否则
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
    // ★★ 与它三个兄弟(`spawn-p1`/`spawn-p2`/`spawn-enemy`,都走 spawnAt)对齐:没打开地图时
    //    说「先打开一张地图」,而不是把 `clearSpawns(null)` 的 TypeError 抛进 click 处理器 ——
    //    后者经 window.onerror 变成「页面异常:…」,同一个面板里四个按钮两种说法。
    if (cl) cl.addEventListener('click', function () {
      guard('清空出生点', function () {
        if (!app.map) { status('先打开一张地图'); return null; }
        return pushAndShow(clearSpawns(app.map));
      });
    });
    var libList = $('lib-list');
    if (libList) {
      libList.addEventListener('click', function (ev) {          // ★ 委托一次,不给每行挂监听
        var row = ev.target.closest ? ev.target.closest('.lib-row') : null;
        if (row && row.dataset.name) openMap(row.dataset.name);
      });
    }
    var bn = $('btn-new'), bd = $('btn-dup'), br = $('btn-rename'), bx = $('btn-del');
    if (bn) bn.addEventListener('click', function () {
      var name = window.prompt('新地图名字(不含 .cyrm)', 'new_map');
      if (!name) return;
      var m = createEmptyMap(name, 125, 75);       // ★ 尺寸只经这一个闸
      app.map = m; app.name = freshName(name);
      app.sourceFormat = 'v4';
      undoHistory = createHistory({});
      dirty = true;                   // ★ 新建只活在内存里(还没写盘)⇒ 磁盘状态是「未保存」
      // ★ setMap 返回的是**分帧重建**派生出来的 promise(Task 4)⇒ 必须收口:抛在任务回调里
      //   是一次 promise 拒绝,同步 try/catch 接不住(用户看到的就是"点了新建、画面不动")。
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
      app.sourceFormat = 'v4';
      undoHistory = createHistory({});
      dirty = true;                   // ★ 同上:副本也只活在内存里(还没写盘)
      guard('复制地图', function () { return app.r.setMap(copy); });   // ★ 同上:分帧重建的 promise
      status('已复制为 ' + app.name + '(还没写盘)');
      refreshStatus();
    });
    if (br) br.addEventListener('click', function () {
      if (!app.map) { status('先打开一张地图'); return; }
      var n = window.prompt('新的名字(不含 .cyrm)', app.map.name);
      if (!n) return;
      app.map.name = Core.sanitizeName(n);
      app.name = app.map.name + '.cyrm';
      dirty = true;                   // ★ 改名只改内存里那份(磁盘上还是旧名字,要 Ctrl+S 才落盘)
      status('改名为 ' + app.name + '(还要 Ctrl+S 才写盘)');
      refreshStatus();
    });
    if (bx) bx.addEventListener('click', function () {
      status('删除地图请直接在磁盘上删 maps/ 下的文件(编辑器不做删除动作 —— 这是故意的)');
    });
    var exp = $('btn-export');
    if (exp) exp.addEventListener('click', showExportReport);
    // ★ 背景层的两个颜色槽(规格 §4.4/§4.5):①起点 ②终点。**两个槽是渐变的全部**——
    //   只接一个的话"渐变"永远退化成一个纯色(两端同色),而且看不出来。
    //   背景层是不透明的真彩(#RRGGBB → 0xRRGGBBFF;alpha 由辅码那一路管不了它)。
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

  // 背景层时把"纹理调色板 + 辅码"换成"颜色选择器"(规格 §4.5)。
  // ★ 只切显示,不动任何数据:切回纹理层时用户刚才选的纹理/辅码还在。
  function syncPanelForLayer() {
    var isBg = (app.r.layer() === Core.LAYER_BG);
    var show = function (id, on) { var el = $(id); if (el) el.style.display = on ? '' : 'none'; };
    // ★★ 藏的是**整行**,不是控件的直接父节点:面板里各控件的父节点并不统一 —— 四个档位
    //    select 的父节点就是 `.desc-row`,而「只改辅码」那个 input 外面还包着一层 <label>
    //    ⇒ 直接写 parentNode 的话后者只藏掉 label,那一行仍占着位置(而且只读得出"少了个
    //    勾选框",看不出是故意的)。故一律向上找到 `.desc-row`。
    var hideRow = function (id, on) {
      var el = $(id);
      if (!el) return;
      var row = el;
      while (row && !(row.classList && row.classList.contains('desc-row'))) row = row.parentNode;
      if (row) row.style.display = on ? '' : 'none';
    };
    show('palette', !isBg);
    show('palette-hint', !isBg);       // ★ 派生行跟着调色板走(见 buildPanels 里插它的那一段)
    show('bg-color-row', isBg);
    show('bg-color-row2', isBg);
    show('bg-color-title', isBg);
    ['desc-hue', 'desc-bri', 'desc-sat', 'desc-alp'].forEach(function (id) { hideRow(id, !isBg); });
    // ★ 「只改辅码」与四个档位是**同一组**(它管的就是那四档),故同显同藏 —— 否则背景层上
    //   它会挂在一个已经没有别的控件的「辅码」区块里。
    hideRow('desc-only', !isBg);
    var titles = document.querySelectorAll('#right h2');
    for (var i = 0; i < titles.length; i++) {
      if (titles[i].textContent === '辅码') titles[i].style.display = isBg ? 'none' : '';
    }
    // ★ 工具条上"渐变只在背景层可用":其余工具照旧(纹理层没有颜色可插值,故渐变**只在**背景层)
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
      // ★★ P1/P2 是**位置**语义、不是"第几条记录":游戏侧 `map_format.gd` 按顺序读
      //    `player` / `player2`。故放 P1 = **写第 0 条**,放 P2 = **写第 1 条**。
      //    ★ 缺号一律**显式拒绝**并说明理由 —— 绝不 push 出一条位置不对的记录:在零出生点的
      //      图上放 P2 而 push 出去,磁盘上那条会被游戏读成 **P1**(状态栏刚说"P2 放到 …",
      //      数据却是 P1),而且**一个字都不报**。同理,"放 P1"若也走 push,图上只有 P1 时
      //      再点一次就会长出第 2 条 —— 那条位置正好是 **P2**,于是 P2 被**悄悄换掉**。
      if (app.map.players.length < playerIndex) {
        status('先放 P' + playerIndex + ':出生点按位置读(player / player2),P' + (playerIndex + 1) +
               ' 之前必须有 P' + playerIndex);
        return;
      }
      var before = snapshotSpawns(app.map);
      // ★★ 折算回本图范围:`addSpawn`(436)与 `spawnIndexAt`(420)都这么做,这条路此前漏了。
      //    `panBy` **不钳**视图(render.js)⇒ 环面模式下把视图拖到图外时,"视图中心那一格"
      //    算出来是越界的,于是磁盘上多出一条 x/y 出圈的出生点 —— 只有 `Core.validateMap`
      //    看得见它(而游戏侧读到的位置是另一回事)。两条路必须同量纲。
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
        dirty = false;                 // ★★ 打开 = 屏幕上这份与磁盘上那份**同源**(见 dirty 那段)
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
    renderSaveState();                // ★ 打开/新建/复制/改名/保存后都要跟着翻
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
    // ★ 指针 / 滚轮 / 热键 / 撤销重做 / 长作业驱动都挂在 installInteraction 里(它自己初始化
    //   工具状态)—— 必须在 mount **之后**:它一进来就要用 app.r。★ 工具条与图层行的**点击**
    //   由 Task 8 的 installPanels() 接(那时才有面板),这里只管画布上的指针与键盘。
    installInteraction();
    var ro = new ResizeObserver(function () { guard('resize', function () { return app.r.resize(); }); });
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
    if (fitBtn) fitBtn.addEventListener('click', function () { guard('fit', function () { return app.r.fit(); }); });

    // ★ 图集必须先就位(渲染第一帧就要它);失败要说出来,而不是画一片黑。
    bootLoad();
  }

  // ── 启动装载(★ 抽成函数是为了让"打开失败"那条路也能被 node 单独驱动:editor_smoke 相位 ⑭e)──
  // ★★ 面板**必须建在打开之前**。原先它挂在"打开之后"(计划 Step 3 的写法),那条链是
  //    `loadAtlas → openFromUrl → buildPanels`,而 `.catch` 只有一个 —— 于是 `openFromUrl()`
  //    一旦拒绝(`?p=` 是个陈旧或写错的名字 → `openMap` 抛 HTTP 404;`.cyrm` 解不开;
  //    structure.png 拿不到),整条链**短路到 catch**,`buildPanels()` 一行都没跑:
  //    工具条、图层行、调色板、出生点四个按钮**一个监听都没装上**,从此**没有重建路径**,
  //    屏幕上只有一行「启动失败:…」。用户会以为编辑器坏了,而不是"这张图打不开"。
  // ★ `buildPanels` 只读 `app.tileDefs`(boot 里就位)与 `app.r`(已 mount),对 `app.map`
  //    只有**一处**引用(清空出生点那个处理器)且不读任何地图尺寸 —— 所以"等图打开"没有
  //    任何理由;而它自己带 null 守卫,没图也能建。
  function bootLoad() {
    return loadAtlas().then(function () {
      buildPanels();
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
    boot: boot, bootLoad: bootLoad, guard: guard, status: status, msgOf: msgOf,
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
    commandFor: commandFor, hasSelection: hasSelection, isTypingTarget: isTypingTarget,
    MAX_UNDO: MAX_UNDO, MAX_UNDO_BYTES: MAX_UNDO_BYTES, bytesOfEntry: bytesOfEntry,
    createHistory: createHistory, snapshotMap: snapshotMap, bytesOfSnapshot: bytesOfSnapshot,
    wholeDiff: wholeDiff, applyEntry: applyEntry, diffCells: diffCells, cellCountOf: cellCountOf,
    copyRegion: copyRegion, clipSize: clipSize, pasteRegion: pasteRegion,
    moveRegion: moveRegion, mirrorRegion: mirrorRegion,
    installInteraction: installInteraction, runJob: runJob, statusLine: statusLine,
    pushAndShow: pushAndShow, doUndo: doUndo, doRedo: doRedo, hitOf: hitOf,
    brushSteps: function () { return BRUSH_STEPS.slice(); }, setBrush: setBrush, setLayer: setLayer,

    buildPanels: buildPanels, syncPanelForLayer: syncPanelForLayer,
    saveCurrent: saveCurrent, saveTargetName: saveTargetName,
    needsV3Confirm: needsV3Confirm, freshName: freshName,
    importEnemyTypes: importEnemyTypes, exportReport: exportReport, showExportReport: showExportReport,
    spawnAt: spawnAt,
  };
})();
