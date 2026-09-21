// render.js —— 画布渲染 + 四层缓存 + 脏区(规格 §4.2;闸 2 见 §4.3)。
//
// ★★ 本文件的**顶层一行都不碰 DOM**:DOM 只出现在 Task 3/4 加进来的 mount() 一族里。
//    于是 node 能 require 它,把"错了也不报错、只在屏幕上看出来"的那几层逐条断言 ——
//    缓存 ③ 的失效、空层、空气短路、环面命中、画笔几何、单帧预算。
// ★ 依赖顺序:core.js → tint.js → render.js(tint 要 Core,render 要两者)。
// ★ 规格 §4.2 的四层缓存:① 地图缩略图(每层一张)② 视口离屏层 ③ 格位图缓存 ④ tinted-tile。
//    ④ 住在 tint.js 里(它自己的 8192 张上限),本文件只负责**在换图时同时作废 ③ 与 ④**。
globalThis.Render = (function () {
  'use strict';

  var Core = globalThis.Core, Tint = globalThis.Tint;
  if (!Core) throw new Error('render.js: 必须先加载 core.js');
  if (!Tint) throw new Error('render.js: 必须先加载 tint.js');

  var SUB = Core.SUB_PER_CELL;

  var MIN_ZOOM = 1, MAX_ZOOM = 64;              // px / 子格
  var ZOOM_THRESHOLD = 8;                       // 规格 §4.2 的分工阈:< 8 走缩略图,≥ 8 走离屏层
  var THUMB_PX = 2;                             // 缩略图 2px/子格(规格 §4.2 ①)
  var THUMB_MAX_BYTES = 24 * 1024 * 1024;       // 超过就降到 1px/子格(400×300 格 @2px = 30MB,偏大)
  var DEFAULT_BUDGET_MS = 8;                    // 闸 2 的单帧 CPU 预算
  // ③ 的条目上限。条目 = **16 个 tile 引用**(不是 64×64 的 canvas),约 128 字节,
  // 8192 条 ≈ 1MB —— 而像素本身只存在 ④ 里,由它自己的上限管。
  // (若把"合成好的 64×64 canvas"存进来,一屏 925 格就是 15MB,缓存比工作集还小 = 没缓存。)
  var DEFAULT_CELL_MAX = 8192;

  // ── 环面折算 ──
  // ★ 两处都要它:格/子格坐标的读取,与象限坐标(quadOf)。负数在环面世界里是常态
  //   (视图越过接缝、选区拖动),而 `%` 对负数返回负数。
  function wrapIdx(v, n) { return v - Math.floor(v / n) * n; }
  function quadOf(v) { return wrapIdx(v, SUB); }        // 恒在 0..SUB-1(否则 Tint 会抛)

  // ── 图层读取(缺席层 = 全空气)──
  // ★ 规格 §2.4 的 createMap 恒建四层,而 layer_flags 允许某个层**不存在** ⇒ 解码出来的
  //   map.layers[L] 可以是 null(null = 全空气,不是"错误")。渲染路径上任何地方
  //   直接摸 map.layers[L].desc 都会在"打开一个缺层的文件"时当场炸。
  function layerArray(map, L) {
    var lay = map.layers[L];
    if (!lay) return null;
    return lay.kind === 'tex' ? lay.desc : lay.rgba;
  }
  function descAt(map, L, X, Y) {
    var a = layerArray(map, L);
    if (!a) return 0;
    return a[wrapIdx(Y, map.subRows) * map.subCols + wrapIdx(X, map.subCols)];
  }
  function rgbaAt(map, X, Y) {
    var a = layerArray(map, Core.LAYER_BG);
    if (!a) return 0;
    return a[wrapIdx(Y, map.subRows) * map.subCols + wrapIdx(X, map.subCols)];
  }

  // ── 贴图源与 ④(换图 = 两层一起作废)──
  var atlasPixels = null, atlasW = 0, atlasH = 0;
  var tiles = null;                              // ④:惰性建(见 tileCache())
  var cells = null;                              // ③:由 attachCells 装上(Task 4 的 mount 装它)

  function tileCache() { if (!tiles) tiles = Tint.createTileCache(); return tiles; }
  // 装上 ③。★ 做成显式的 attach 而不是"createCellCache 顺手写进模块变量":
  //   后者会让"谁最后建的谁生效",而 ③ 的作废是**必须由 setAtlas 触发**的一条不变量。
  function attachCells(cache) { cells = cache; return cells; }
  function cellCache() { return cells; }

  // ★ 唯一的换图入口。它必须**同时**作废 ③ 与 ④ —— 这一条是账本点名带进计划 2b 的
  //   不变量(规格 §4.2 的 ③ 与 ④ 是两层,换图是它们共同的失效事件)。
  //   ④ 那一侧由 Tint.setSource 自己做;③ 这一侧漏了的话,它会继续交出"用旧图集算出来、
  //   内容版本却没变"的格位图 ⇒ 审计 A2 在上一层原样复发(整张图是色块,"有时好有时坏",
  //   不报错)。★ 顺序是"先让 Tint 校验形状、再作废" —— 形状非法时 Tint.setSource 抛错,
  //   此时两层都还是旧的(而不是"作废了一半")。
  // ★ opts.backend 是给 node 冒烟用的注入缝(与 tint.js 的注入式画布同一个先例):
  //   传它就换一个新的 ④,于是"空气到底有没有进 Tint"能被**记账**而不是靠肉眼。
  function setAtlas(pixels, w, h, opts) {
    if (opts && opts.backend) tiles = Tint.createTileCache({ backend: opts.backend });
    tileCache().setSource(pixels, w);
    atlasPixels = pixels; atlasW = w | 0; atlasH = h | 0;
    if (cells) cells.setSource();
  }
  function atlasInfo() { return atlasPixels ? { width: atlasW, height: atlasH } : null; }
  // ★ 图纸容量 = 列 × 行(320×320 的图集 = 100 块)。**不是**描述符位宽 4095 ——
  //   tint 的越界判据就是"图集里有没有这一块",拿 4095 当上界 ⇒ 101~4095 全部抛。
  function atlasCapacity() { return atlasW > 0 ? Math.floor(atlasW / Tint.BLOCK_PX) * Math.floor(atlasH / Tint.BLOCK_PX) : 0; }

  // 取一张 16×16 小图。**唯一**该调 Tint.get 的地方。
  // ★★ desc === 0(空气)必须在**进 Tint 之前**短路:空气是地图数据里最常见的一格,
  //    而 Tint.get → buildTilePixels 对空气**会抛**(I4 契约)—— 渲染循环漏了这句,
  //    第一帧就抛、而且每帧都在同一处抛。
  // ★ 纹理实参**从 desc 推导**(不另传):账本 Task 5 的遗留是"实参与 texOf(desc) 不一致时
  //   buildTilePixels 会静默画另一块砖";从 desc 推导让不一致**不可能发生**。
  function tileFor(desc, qx, qy) {
    if (desc === 0) return null;
    var tex = Core.texOf(desc);
    if (tex === 0) return null;                  // 畸形描述符(辅码非 0、纹理 0)= 空气
    return tileCache().get(tex, quadOf(qx), quadOf(qy), desc);
  }

  // ── ③ 格位图缓存(规格 §4.2 ③)──
  // 缓存的是"这一格的 16 个子格**各用哪张 tile**",不是像素 —— 像素只存在 ④ 里。
  // ★★ 两条**独立**的失效轴,必须都判:
  //    ① 内容版本号(touch):编辑某格 → 该格版本 +1 → 下次只重建这一格;
  //    ② 代际(gen,由 setSource 递增):换贴图源之后,即便内容一个字没改,
  //       旧的 tile 也已作废 —— 只判 ① 的话这里会交出**上一张图集**算出来的 tile,
  //       症状与审计 A2 一模一样(整张图是色块,"有时好有时坏",不报错)。
  function createCellCache(opts) {
    opts = opts || {};
    var maxCells = opts.maxCells === undefined ? DEFAULT_CELL_MAX : opts.maxCells;
    var build = opts.build;
    if (typeof build !== 'function') throw new Error('createCellCache: 缺 build 回调');
    var ver = new Map();                         // 内容版本号
    var entries = new Map();                     // 键 -> {v, gen, tile}
    var gen = 0, hits = 0, misses = 0, evictions = 0;

    function key(L, cx, cy) { return L + '/' + cx + '/' + cy; }
    function version(L, cx, cy) { var v = ver.get(key(L, cx, cy)); return v === undefined ? 0 : v; }
    function touch(L, cx, cy) { ver.set(key(L, cx, cy), version(L, cx, cy) + 1); }
    // ★★ ③ 的作废。规格 §4.2 ③ 的"内容版本号"说的是轴 ①;换图是轴 ②。
    // ★★ **刻意不清表**:陈旧条目留着,靠 gen 不等**恒 miss**、被重建覆盖。
  //   清了表的话 `get` 里那句 `e.gen === gen` 就成了**死代码** —— 表里不可能有旧代际的条目,
  //   那句判断永远为真,Task 2 Step 5 那条变异(删掉 gen 比较)便再也杀不掉任何东西,
  //   而它正是审计 A2 复发时唯一抓得住的地方。2026-09-21 用户裁定:让 gen 承重。
  function setSource() { gen++; }
    function get(L, cx, cy) {
      var k = key(L, cx, cy);
      var v = version(L, cx, cy);
      var e = entries.get(k);
      if (e !== undefined && e.v === v && e.gen === gen) {
        hits++;
        entries.delete(k); entries.set(k, e);    // 命中提到最近端(Map 的插入序 = LRU 序)
        return e.tile;
      }
      misses++;
      var tile = build(L, cx, cy);
      entries.set(k, { v: v, gen: gen, tile: tile });
      while (entries.size > maxCells) { entries.delete(entries.keys().next().value); evictions++; }
      return tile;
    }
    function clear() { entries.clear(); }
    function stats() {
      return { hits: hits, misses: misses, evictions: evictions,
               size: entries.size, maxCells: maxCells, generation: gen };
    }
    return { version: version, touch: touch, setSource: setSource,
             get: get, clear: clear, stats: stats };
  }

  // ── 闸 2:单帧预算的时间切片器(规格 §4.3)──
  // ★ 分帧是"慢慢画出来",不是"页面死掉"。注入 now/nextFrame 是为了在 node 里
  //   确定性地断言"确实切了、且单帧真的没超预算"(真 rAF 在 node 里不存在)。
  // ★ 「每帧至少做一项」是必须的:否则 budgetMs = 0 时循环会一项不做就让出、
  //   让出之后又一项不做 —— 死循环(而 0 是合法的注入值,测试就在用它)。
  function createSlicer(opts) {
    opts = opts || {};
    var budget = opts.budgetMs === undefined ? DEFAULT_BUDGET_MS : opts.budgetMs;
    var now = opts.now || function () {
      return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
    };
    var nextFrame = opts.nextFrame || function () {
      return new Promise(function (r) { requestAnimationFrame(function () { r(); }); });
    };
    function run(items, fn) {
      var i = 0, frames = 0, maxStep = 0;
      return new Promise(function (resolve) {
        function step() {
          var s0 = now();
          while (i < items.length) {
            fn(items[i], i); i++;
            // ★ 判在**做完之后**:预算是软的(到手一项就做完它),但一格都不许超。
            if (now() - s0 >= budget) break;
          }
          var d = now() - s0;
          if (d > maxStep) maxStep = d;
          if (i >= items.length) { resolve({ frames: frames, processed: i, maxStepMs: maxStep }); return; }
          frames++;
          // ★ 时间基准在**让出之后**重新取:让出一帧自己也花时间,把那段算进下一帧的
          //   预算里会让"下一帧刚做一项就又超预算"—— 分帧退化成逐项让出。
          nextFrame().then(step);
        }
        step();
      });
    }
    return { run: run, budgetMs: budget };
  }

  // ── 缩放与适配 ──
  function zoomPath(pxPerSub) { return pxPerSub < ZOOM_THRESHOLD ? 'thumb' : 'layers'; }
  function clampZoom(z) {
    if (!isFinite(z) || z <= 0) return MIN_ZOOM;   // 用户输入钳制,不报错回滚
    return Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, z));
  }
  function fitZoom(subCols, subRows, viewW, viewH, pad) {
    var p = pad === undefined ? 8 : pad;
    var zx = (viewW - 2 * p) / subCols, zy = (viewH - 2 * p) / subRows;
    return clampZoom(Math.min(zx, zy));
  }
  function thumbScale(subCols, subRows) {
    var bytes = subCols * THUMB_PX * subRows * THUMB_PX * 4;
    return bytes > THUMB_MAX_BYTES ? 1 : THUMB_PX;
  }

  // ── 可见区裁剪(B8:网格线/spawn 标记/边框不做裁剪 = 每次重画整张图)──
  // ★ 返回的是**未折算**的坐标(3×3 副本要的正是它):调用方按格自己 wrapIdx。
  function visibleSubRange(view, viewW, viewH, subCols, subRows) {
    var x0 = Math.floor(view.x), y0 = Math.floor(view.y);
    var x1 = Math.ceil(view.x + viewW / view.zoom), y1 = Math.ceil(view.y + viewH / view.zoom);
    return { x0: x0, y0: y0, x1: x1, y1: y1 };
  }

  // ── 环面 3×3:A4 说旧实现只铺 [0,1]、少一侧,且副本上不能落笔 ──
  // ★ 返回"与视口相交"的那些副本偏移(最多 3×3 = 9 份,通常 1 份)——
  //   无脑铺 9 份是 9 倍开销,而屏幕上绝大多数时候只看得到一份。
  function intersects(a0, a1, b0, b1) { return a1 > b0 && a0 < b1; }
  function torusOffsets(view, viewW, viewH, mapW, mapH) {
    var r = visibleSubRange(view, viewW, viewH, mapW, mapH);
    var out = [];
    for (var ky = -1; ky <= 1; ky++) {
      var lo = ky * mapH, hi = lo + mapH;
      if (!intersects(r.y0, r.y1, lo, hi)) continue;
      for (var kx = -1; kx <= 1; kx++) {
        var lox = kx * mapW, hix = lox + mapW;
        if (!intersects(r.x0, r.x1, lox, hix)) continue;
        out.push([lox, lo]);
      }
    }
    return out;
  }

  // 屏幕 → 子格(折算回主网格)。★ 副本上落笔靠的就是这一步:无论点在哪个副本上,
  // 结果都落在 [0, subCols) 里。
  function hitTest(view, px, py, subCols, subRows) {
    var X = Math.floor(view.x + px / view.zoom);
    var Y = Math.floor(view.y + py / view.zoom);
    return { X: wrapIdx(X, subCols), Y: wrapIdx(Y, subRows) };
  }

  // ── 画笔几何(规格 §4.4 的吸附规则)──
  // 单位仍是 64px 格,输入步进 0.25:
  //   整数大小 → 只画**整格**,吸附到 64px 格边界;
  //   小数(0.25/0.5/0.75)→ 画**子格**,吸附到 16px 子格边界(0.25=1 子格、0.5=2、0.75=3)。
  var MAX_BRUSH_CELLS = 15;
  function brushSpan(size) {
    var s = (typeof size === 'number' && isFinite(size)) ? size : 1;
    if (s <= 0) s = 1;
    if (Math.floor(s) === s) return { unit: 'cell', n: Math.max(1, Math.min(MAX_BRUSH_CELLS, s)) };
    var n = Math.round(s * SUB);                 // 0.25→1、0.5→2、0.75→3、2.5→10
    return { unit: 'sub', n: Math.max(1, Math.min(MAX_BRUSH_CELLS * SUB, n)) };
  }
  function brushRegion(hit, size) {
    var sp = brushSpan(size);
    var c = (typeof hit === 'object' && hit) ? hit : {};
    var x = Math.floor(isFinite(c.x) ? c.x : 0);
    var y = Math.floor(isFinite(c.y) ? c.y : 0);
    var lo = Math.floor((sp.n - 1) / 2), hi = Math.ceil((sp.n - 1) / 2);
    // ★★ unit 必须描述 x0..x1 **所在的**坐标空间:它们就是 `hit` 的空间(hit.x 是格号还是
    //    子格号 —— Task 5 的 `regionCells` 正是据此决定要不要 ×4),而**不是** `size` 那一侧的
    //    空间。稳态下两者相等(UI 的 `hitOf` 用 `brushSpan(size).unit` 定 kind,且只在那里
    //    定一次),但一旦不等,按 size 标注就会让 `regionCells` 把子格坐标当成格号去 ×4
    //    ⇒ 整支画笔偏到别处 —— 即下面注释警告的"错 4 倍"。Task 5 的 rect 分支就是这么标
    //    它的 region 的(`unit: from.kind`,同样取自 hit)。
    var unit = (c.kind === 'cell' || c.kind === 'sub') ? c.kind : sp.unit;
    return { unit: unit, x0: x - lo, y0: y - lo, x1: x + hi, y1: y + hi };
  }
  function snapHit(h) {
    if (h.kind === 'sub') return { kind: 'sub', x: Math.floor(h.X), y: Math.floor(h.Y) };
    return { kind: 'cell', x: Math.floor(h.X), y: Math.floor(h.Y) };
  }

  // ── 选区拖动:纯读的偏移查询(B3;规格 §4.2「拖动只记 dx/dy,松手才提交」)──
  function selectionSource(sel, dx, dy, X, Y) {
    var sx = X - dx, sy = Y - dy;
    if (sx >= sel.x && sx < sel.x + sel.w && sy >= sel.y && sy < sel.y + sel.h) {
      return { hit: true, X: sx, Y: sy };
    }
    return { hit: false, X: X, Y: Y };
  }

  // ── 脏区 ──
  function rectUnion(a, b) {
    if (!a) return { x: b.x, y: b.y, w: b.w, h: b.h };
    if (!b) return { x: a.x, y: a.y, w: a.w, h: a.h };
    var x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
    var x2 = Math.max(a.x + a.w, b.x + b.w), y2 = Math.max(a.y + a.h, b.y + b.h);
    return { x: x, y: y, w: x2 - x, h: y2 - y };
  }
  function rectIsEmpty(r) { return !r || r.w <= 0 || r.h <= 0; }

  return {
    MIN_ZOOM: MIN_ZOOM, MAX_ZOOM: MAX_ZOOM, ZOOM_THRESHOLD: ZOOM_THRESHOLD,
    THUMB_PX: THUMB_PX, THUMB_MAX_BYTES: THUMB_MAX_BYTES,
    DEFAULT_BUDGET_MS: DEFAULT_BUDGET_MS, DEFAULT_CELL_MAX: DEFAULT_CELL_MAX,
    wrapIdx: wrapIdx, quadOf: quadOf,
    layerArray: layerArray, descAt: descAt, rgbaAt: rgbaAt,
    setAtlas: setAtlas, atlasInfo: atlasInfo, atlasCapacity: atlasCapacity, tileCache: tileCache,
    attachCells: attachCells, cellCache: cellCache,
    tileFor: tileFor,
    createCellCache: createCellCache,
    createSlicer: createSlicer,
    zoomPath: zoomPath, clampZoom: clampZoom, fitZoom: fitZoom, thumbScale: thumbScale,
    visibleSubRange: visibleSubRange, torusOffsets: torusOffsets, hitTest: hitTest,
    MAX_BRUSH_CELLS: MAX_BRUSH_CELLS, brushSpan: brushSpan, brushRegion: brushRegion, snapHit: snapHit,
    selectionSource: selectionSource, rectUnion: rectUnion, rectIsEmpty: rectIsEmpty,
  };
})();
