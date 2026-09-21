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
  //   不报错)。★ 顺序是"先把新 ④ 建出来、让它校验形状,**校验过了才提交**" —— 形状非法时
  //   `setSource` 抛错,此时 `tiles`/`atlasPixels`/③ 的代际**一个字都没动**,两层都还是旧的
  //   (而不是"作废了一半")。
  // ★★ 注入 backend 那条路**尤其**要这样写(先 `tiles = 新缓存` 再 `setSource` 是缺陷):
  //   抛错会留下一个**没有贴图源的新 ④**,而 `atlasInfo()` 仍报旧图集、③ 也没作废 ——
  //   下一次 `tileFor` 于是抛 `Tint: 还没 setSource,拿不到贴图`,而不是照旧画老图集
  //   (上面那句"两层都还是旧的"就成了一句假话。no-backend 那条路看不出来,因为它复用的
  //   是同一个对象,换不换都一样)。守卫:render_smoke 相位 ②b。
  // ★ opts.backend 是给 node 冒烟用的注入缝(与 tint.js 的注入式画布同一个先例):
  //   传它就换一个新的 ④,于是"空气到底有没有进 Tint"能被**记账**而不是靠肉眼。
  function setAtlas(pixels, w, h, opts) {
    // ★ 这里**不**走 `tileCache()`:那个 getter 自己就会写 `tiles`(惰性建),先调它等于
    //   先把 ④ 换了再校验 —— 正是本条要修的那件事。没注入 backend 时就复用现成的那个。
    var next = (opts && opts.backend) ? Tint.createTileCache({ backend: opts.backend })
                                      : (tiles || Tint.createTileCache());
    next.setSource(pixels, w);                   // 形状非法 → 抛,两层都还是旧的
    tiles = next;
    atlasPixels = pixels; atlasW = w | 0; atlasH = h | 0;
    if (cells) cells.setSource();
  }
  function atlasInfo() { return atlasPixels ? { width: atlasW, height: atlasH } : null; }
  // ★ 图纸容量 = 列 × 行(320×320 的图集 = 100 块)。**不是**描述符位宽 4095 ——
  //   tint 的越界判据就是"图集里有没有这一块",拿 4095 当上界 ⇒ 101~4095 全部抛。
  // ★★ `Math.max(0, …)` 不是装饰:`w` 由 `Tint.setSource` 校验,**`h` 从来没被任何人校验过**
  //   (setAtlas 原样 `h | 0` 存下),畸形的 `h`(如负数)会让 `floor(h / BLOCK_PX)` 为负 ⇒
  //   容量算出**负数**;而计划的 `clampTexture` 把任何 **< 1** 的容量都当"没有信息"、
  //   **静默**放宽到 TEXTURE_MAX —— 负数于是伪装成"没信息"穿过那道闸。钳到 0 就堵住这条路
  //   (0 = 明确的"一块都放不下",不是一个负数)。
  function atlasCapacity() {
    return atlasW > 0 ? Math.max(0, Math.floor(atlasW / Tint.BLOCK_PX) * Math.floor(atlasH / Tint.BLOCK_PX)) : 0;
  }

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
      // ★ 重建的键也要移到**最近端**。`Map.set` 对**已存在**的键会保留原来的插入位置,
      //   而这条路径恰恰常发生在"换图后 setSource 刻意不清表"留下的陈旧条目上 ——
      //   不先删,刚重建出来的条目可能还蹲在最冷的位置,下一次淘汰就把它扔掉(它才刚建过)。
      //   与上面命中那条(`entries.delete(k); entries.set(k, e)`)同款。
      entries.delete(k);
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
    var raw = opts.budgetMs === undefined ? DEFAULT_BUDGET_MS : opts.budgetMs;
    // ★ 预算必须是**有限的数**:`now() - s0 >= NaN` 恒为 false,负预算同理永远不成立 ——
    //   两者都会让 while 一口气做完整批,而那正是闸 2 要防的那件事,并且**不报错**
    //   (症状是"分帧器装了等于没装",只能靠量单帧耗时才发现)。
    //   非法值一律:非有限数 → 回落默认预算;负数 → 钳到 0(0 是合法注入值,
    //   "每帧至少做一项"会兜住它,不会死循环)。
    var budget = (typeof raw === 'number' && isFinite(raw)) ? Math.max(0, raw) : DEFAULT_BUDGET_MS;
    var now = opts.now || function () {
      return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
    };
    var nextFrame = opts.nextFrame || function () {
      return new Promise(function (r) { requestAnimationFrame(function () { r(); }); });
    };
    function run(items, fn) {
      var i = 0, frames = 0, maxStep = 0;
      return new Promise(function (resolve, reject) {
        // ★★ 抛错必须**落到这个 promise 上**。第 2 帧起 `step` 是在 `nextFrame().then(step)`
        //   这条**没人观察**的链上跑的:裸抛会变成 unhandled rejection,`run()` 返回的
        //   promise 于是**永远不 settle**(调用方 await 到天荒地老),而第一帧抛却能正常
        //   reject(那时 step 还在 promise 执行器里同步跑,执行器自己会接住)。
        //   两条路径的症状完全不同,所以只测"第一帧抛"是**区分不了**的。
        function step() {
          try {
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
            // ★★ 第二个实参同样是承重的:上面那个洞堵的是"`step` 自己抛",这一个堵的是
            //   "**让出的那一帧**抛"(注入的 `nextFrame()` 交回 rejected promise,例如
            //   帧回调里出了错 / 分帧被中止)。只写 `.then(step)` 的话,这个 rejection 落在
            //   **没人观察**的派生链上 —— `step` 一次都不会被调到,`run()` 的 promise 就悬
            //   在那里(与上面同一个病,只换了输入),症状是一模一样的"永远不 settle"。
            nextFrame().then(step, reject);
          } catch (err) {
            reject(err);                           // ← 让第 2 帧起的抛错也 settle 掉 run()
          }
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
  // ★★ 吸附 = **换算坐标空间**,不只是贴个标签。`hitTest` 交出来的 X/Y 是**子格号**
  //    (与 `kind` 无关),所以 `kind: 'cell'` 的命中必须 `floor(X / SUB)` 换成**格号** ——
  //    两个分支只差一个 `kind` 标签的话,格空间的命中会把子格号当成格号传下去,而下游
  //    (`brushRegion` 的 unit、Task 5 的 `regionCells`)正是按 `kind` 决定要不要 ×4,
  //    于是整支画笔偏到别处(即上文警告的"错 4 倍")。
  //    与 UI 的 `hitOf` 同一条式子:`Math.floor(p.X / Core.SUB_PER_CELL)`。
  //    `sub` 分支就是子格本身,`floor` 只作取整(命中坐标已经是整数)。
  function snapHit(h) {
    if (h.kind === 'sub') return { kind: 'sub', x: Math.floor(h.X), y: Math.floor(h.Y) };
    return { kind: 'cell', x: Math.floor(h.X / SUB), y: Math.floor(h.Y / SUB) };
  }

  // ── 选区拖动:纯读的偏移查询(B3;规格 §4.2「拖动只记 dx/dy,松手才提交」)──
  function selectionSource(sel, dx, dy, X, Y) {
    var sx = X - dx, sy = Y - dy;
    if (sx >= sel.x && sx < sel.x + sel.w && sy >= sel.y && sy < sel.y + sel.h) {
      return { hit: true, X: sx, Y: sy };
    }
    return { hit: false, X: X, Y: Y };
  }

  // ── 图层绘制顺序 ──
  // 前景(0)是"从外到内"的第一层 ⇒ **最后**画(盖在最上面);背景(3)最先画。
  var DRAW_ORDER = [3, 2, 1, 0];

  // ── 层的**种类**:决定那一格怎么读 ──
  // ★★ 纹理层是**描述符**(走 Core.texOf / Tint),背景层是 **RGBA 0xRRGGBBAA**
  //    (走 cssOfRGBA / fillRect)。两者都是 32 位无符号数,长得一模一样、含义完全不同 ——
  //    把 RGBA 喂给 Core.texOf **不抛**,只是结论毫无意义,而两种颜色各有一种静默症状:
  //      · 不透明红 #FF0000FF(背景色输入框里随手就有):(0xFF0000FF >>> 12) & 0xFFF = 0
  //        ⇒ 被当成**空气** ⇒ 整层看不见;
  //      · 不透明青 #00FFFFFF(输入框的默认值):texOf = 4095 = "图集里没有的那块砖"
  //        ⇒ 任何一处漏掉"先判层、再判纹理"的地方都当场抛 Tint 的越界错(闸门越少越容易漏)。
  //    判据取 core.js 的单一来源(LAYER_KINDS),**别**在渲染层再抄一份 [0,0,0,1] ——
  //    那就是第二份实现,而两份实现迟早漂、且漂了不报错。
  function layerIsColor(L) { return Core.LAYER_KINDS[L] === 'color'; }

  // ── 画布挂载(规格 §4.2)──
  // ★ T3 这一版是**朴素**的:缩略图路径走 ①(每层一张、按脏矩形更新),
  //   而 ≥ 8 px/子格 的路径逐子格 drawImage(旧编辑器的 B2 做法,能看但慢)。
  //   Task 4 把后者换成 ② 视口离屏层 + ③ 格位图缓存 + 脏区 + 3×3。
  // ★ opts.slicer 是**注入缝**(与 setAtlas 的 opts.backend / createSlicer 的 opts.now 同款):
  //   浏览器里不传,node 冒烟传一个确定的 nextFrame —— 不传的话缩略图那座分帧器在 node 里
  //   会去碰不存在的 requestAnimationFrame。
  function mount(canvas, opts) {
    opts = opts || {};
    var ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;      // ★ 审计 A5:主 ctx 不关插值 ⇒ 放大后砖块是糊的
    var s = {
      map: null, layer: Core.LAYER_SCENE,
      view: { x: 0, y: 0, zoom: 8 },
      grid: true, subGrid: false, torus: true, dimOthers: true,
      layerVisible: [true, true, true, true],
      layerLocked: [false, false, false, false],
      selection: null,
    };
    var thumbs = [null, null, null, null];
    var thumbPx = THUMB_PX;
    var slicer = createSlicer(opts.slicer || {});
    var stat = { thumbMs: 0, renders: 0, lastRenderMs: 0, thumbsBuilt: 0 };

    function ensureThumbs(map) {
      var px = thumbScale(map.subCols, map.subRows);
      // ★★ 复用条件必须**逐轴**判(宽 **与** 高),只判宽度是不够的:
      //    `thumbScale` 只看**总字节数**,所以"同宽更高"的两张图可以拿到同一个刻度
      //    (如 demo 的 500×300 子格 → 1000×600,与 500×400 子格 → 1000×800,刻度都是 2)。
      //    这时宽度那条对得上 ⇒ 复用了那张**矮**画布,而 drawThumbPath 用五实参 drawImage
      //    把它整张缩进 subRows*px*scale 的目标框里 ⇒ 画面纵向被拉伸/截断(默认视图
      //    fitZoom 之后 zoom < 8,走的正是缩略图这条路,所以**默认视图就是错的**)。
      if (thumbs[0] && thumbPx === px &&
          thumbs[0].width === map.subCols * px && thumbs[0].height === map.subRows * px) {
        // ★★ 复用尺寸相同的旧缩略图之前,先把**新图里缺席的层**清掉:缺席层不进 thumbTasks
        //    (省一次全图扫描),于是它**不会**被重画 —— 留着旧像素的话,换到一张少层的图
        //    之后那一层会继续显示**上一张图的内容**(而缩略图路径会把它当"这一层的画面"贴出去)。
        //    只判"尺寸变了没"是抓不住的(尺寸一样 ⇒ 走的就是这条路)。
        for (var Lc = 0; Lc < Core.LAYER_COUNT; Lc++) {
          if (thumbs[Lc] && !layerArray(map, Lc)) {
            thumbs[Lc].getContext('2d').clearRect(0, 0, thumbs[Lc].width, thumbs[Lc].height);
          }
        }
        return false;
      }
      thumbPx = px;
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        thumbs[L] = document.createElement('canvas');
        thumbs[L].width = map.subCols * px;
        thumbs[L].height = map.subRows * px;
        var c = thumbs[L].getContext('2d');
        c.imageSmoothingEnabled = false;
      }
      return true;
    }

    // 画缩略图的一块矩形(单位 = 子格;rect 由调用方保证在图内)
    // ★ 逐子格 drawImage / fillRect 是这里唯一的成本(默认图 15 万次),所以缩略图**总是**
    //   经分帧器建(闸 2):大图上是"慢慢画出来",不是"页面死掉"。
    // ★★ **先按层种类分派**、再谈内容:RGBA 永远走不到 Core.texOf / Tint 那条路上
    //    (见 layerIsColor —— 这一句就是那个缺陷的闸门,不是装饰)。
    function paintThumbRect(L, rect) {
      var tc = thumbs[L] && thumbs[L].getContext('2d');
      if (!tc) return;
      var px = thumbPx;
      var colorLayer = layerIsColor(L);              // 判据取一次,不在逐格循环里重算
      for (var Y = rect.y; Y < rect.y + rect.h; Y++) {
        for (var X = rect.x; X < rect.x + rect.w; X++) {
          var raw = descAt(s.map, L, X, Y);
          if (colorLayer) {
            // 背景层 = RGBA:alpha = 0(createMap 的初值就是 0)⇒ 这一格**没有颜色**,
            // 清掉;其余一律按颜色画。
            // ★ 这里**不许**出现 texOf:红色 #FF0000FF 的纹理位恰好是 0,拿 texOf 当"空气"判
            //   会把整层判没(见 layerIsColor 的两条症状)。
            if (((raw >>> 0) & 255) === 0) { tc.clearRect(X * px, Y * px, px, px); continue; }
            tc.fillStyle = cssOfRGBA(raw);
            tc.fillRect(X * px, Y * px, px, px);
            continue;
          }
          if (raw === 0 || Core.texOf(raw) === 0) { tc.clearRect(X * px, Y * px, px, px); continue; }
          var t = tileFor(raw, X, Y);
          if (t) tc.drawImage(t, X * px, Y * px, px, px);
        }
      }
    }

    // 把一整层的缩略图切成"每 8 行一组"的任务交给分帧器
    function thumbTasks(map) {
      var tasks = [], rows = 8;
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        if (!layerArray(map, L)) continue;             // 缺席层不画(全空气)
        for (var y = 0; y < map.subRows; y += rows) {
          tasks.push({ L: L, rect: { x: 0, y: y, w: map.subCols, h: Math.min(rows, map.subRows - y) } });
        }
      }
      return tasks;
    }

    function buildThumbs() {
      if (!s.map) return Promise.resolve();
      var t0 = (typeof performance !== 'undefined' ? performance.now() : Date.now());
      var tasks = thumbTasks(s.map);
      stat.thumbsBuilt++;
      return slicer.run(tasks, function (t) { paintThumbRect(t.L, t.rect); }).then(function () {
        stat.thumbMs = (typeof performance !== 'undefined' ? performance.now() : Date.now()) - t0;
      });
    }

    function cssOfRGBA(v) {
      var u = v >>> 0;
      return 'rgba(' + ((u >>> 24) & 255) + ',' + ((u >>> 16) & 255) + ',' +
             ((u >>> 8) & 255) + ',' + ((u & 255) / 255) + ')';
    }

    // ★ 用鼠标坐标算世界坐标的两个方向:命中(C15 子格级)与反算(画 spawn 标记)
    function screenToSub(px, py) {
      // ★ 还没打开地图时返回中性值(闸 1:用户输入钳制,不报错回滚)——
      //   指针事件比 setMap 早到是完全可能的,而这里抛错只会表现为"点了没反应"。
      if (!s.map) return { X: 0, Y: 0 };
      return hitTest(s.view, px, py, s.map.subCols, s.map.subRows);
    }
    function subToScreen(X, Y) {
      return { x: (X - s.view.x) * s.view.zoom, y: (Y - s.view.y) * s.view.zoom };
    }

    function torusList(W, H) {
      if (!s.torus) return [[0, 0]];
      return torusOffsets(s.view, W, H, s.map.subCols, s.map.subRows);
    }

    // 路径一:< 8 px/子格 → 一次 drawImage 顶掉几十万次(规格 §4.2 ①)
    function drawThumbPath(W, H) {
      var px = thumbPx;
      var scale = s.view.zoom / px;                  // 缩略图像素 → 屏幕像素
      var offs = torusList(W, H), i, L;
      for (i = 0; i < offs.length; i++) {
        for (var oi = 0; oi < DRAW_ORDER.length; oi++) {
          L = DRAW_ORDER[oi];
          if (!s.layerVisible[L] || !thumbs[L]) continue;
          ctx.globalAlpha = (s.dimOthers && L !== s.layer && L !== Core.LAYER_BG) ? 0.4 : 1;
          ctx.drawImage(thumbs[L],
                        (offs[i][0] - s.view.x) * s.view.zoom,
                        (offs[i][1] - s.view.y) * s.view.zoom,
                        s.map.subCols * px * scale, s.map.subRows * px * scale);
        }
      }
      ctx.globalAlpha = 1;
    }

    // 路径二:≥ 8 px/子格 → 逐子格(Task 4 换成 ② + ③ + 脏区)
    function drawLayerPath(W, H) {
      var r = visibleSubRange(s.view, W, H, s.map.subCols, s.map.subRows);
      var offs = torusList(W, H);
      for (var oi = 0; oi < DRAW_ORDER.length; oi++) {
        var L = DRAW_ORDER[oi];
        if (!s.layerVisible[L]) continue;
        var colorLayer = layerIsColor(L);            // ★ 与 paintThumbRect 同一道分派
        ctx.globalAlpha = (s.dimOthers && L !== s.layer && L !== Core.LAYER_BG) ? 0.4 : 1;
        for (var i = 0; i < offs.length; i++) {
          var dx = offs[i][0], dy = offs[i][1];
          var x0 = Math.max(r.x0, dx), x1 = Math.min(r.x1, dx + s.map.subCols);
          var y0 = Math.max(r.y0, dy), y1 = Math.min(r.y1, dy + s.map.subRows);
          for (var Y = y0; Y < y1; Y++) {
            for (var X = x0; X < x1; X++) {
              // ★ 副本坐标折回主网格后再读(所以副本上也能落笔、也画得对)
              var raw = descAt(s.map, L, X - dx, Y - dy);
              var p;
              if (colorLayer) {
                // ★★ 背景层 = RGBA,读完**直接**画颜色 —— 见 layerIsColor 的两条症状。
                if (((raw >>> 0) & 255) === 0) continue;
                p = subToScreen(X, Y);
                ctx.fillStyle = cssOfRGBA(raw);
                ctx.fillRect(p.x, p.y, s.view.zoom, s.view.zoom);
                continue;
              }
              if (raw === 0 || Core.texOf(raw) === 0) continue;
              p = subToScreen(X, Y);
              var t = tileFor(raw, X - dx, Y - dy);
              if (t) ctx.drawImage(t, p.x, p.y, s.view.zoom, s.view.zoom);
            }
          }
        }
      }
      ctx.globalAlpha = 1;
    }

    // 网格线:格线恒画,子格线只在 zoom ≥ 4 时画。★ 规格 C15 只要求"有子格开关 + 子格级
    //   命中",**没有**规定阈值 ⇒ 这个 4 是**本文件自己的选择**(取 4 的理由:4 px/子格
    //   时一个子格还有 4 个屏幕像素、线还分得开;再稀就只是给画面加噪点),不是规格里的数字。
    // ★ 只画可见区(B8:不裁剪 = 每次重画整张图的线)
    function drawGrid(W, H) {
      var r = visibleSubRange(s.view, W, H, s.map.subCols, s.map.subRows);
      var z = s.view.zoom;
      ctx.lineWidth = 1;
      ctx.strokeStyle = 'rgba(255,255,255,0.16)';
      ctx.beginPath();
      if (s.subGrid && z >= 4) {
        for (var X = Math.floor(r.x0 / 1); X <= r.x1; X++) {
          var sx = Math.round((X - s.view.x) * z) + 0.5;
          if (sx < -1 || sx > W + 1) continue;
          ctx.moveTo(sx, 0); ctx.lineTo(sx, H);
        }
        for (var Y = r.y0; Y <= r.y1; Y++) {
          var sy = Math.round((Y - s.view.y) * z) + 0.5;
          if (sy < -1 || sy > H + 1) continue;
          ctx.moveTo(0, sy); ctx.lineTo(W, sy);
        }
      }
      ctx.stroke();
      // 格线(64px = 4 个子格)
      ctx.strokeStyle = 'rgba(255,255,255,0.30)';
      ctx.beginPath();
      for (var X2 = Math.floor(r.x0 / SUB) * SUB; X2 <= r.x1; X2 += SUB) {
        var sx2 = Math.round((X2 - s.view.x) * z) + 0.5;
        if (sx2 < -1 || sx2 > W + 1) continue;
        ctx.moveTo(sx2, 0); ctx.lineTo(sx2, H);
      }
      for (var Y2 = Math.floor(r.y0 / SUB) * SUB; Y2 <= r.y1; Y2 += SUB) {
        var sy2 = Math.round((Y2 - s.view.y) * z) + 0.5;
        if (sy2 < -1 || sy2 > H + 1) continue;
        ctx.moveTo(0, sy2); ctx.lineTo(W, sy2);
      }
      ctx.stroke();
    }

    // spawn 标记 + 选区框。★ 字体/对齐**设一次**(B8:每标记重设 font 是排版最贵的一项)。
    function drawOverlay(W, H) {
      if (!s.map) return;
      ctx.save();
      ctx.font = '12px Consolas, monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      var offs = torusList(W, H);
      var mark = function (cellX, cellY, color, label) {
        for (var i = 0; i < offs.length; i++) {
          var X = cellX * SUB - offs[i][0], Y = cellY * SUB - offs[i][1];
          var p = subToScreen(X, Y);
          if (p.x < -64 || p.y < -64 || p.x > W + 64 || p.y > H + 64) continue;
          ctx.fillStyle = color;
          ctx.globalAlpha = 0.75;
          ctx.fillRect(p.x, p.y, 4 * s.view.zoom, 4 * s.view.zoom);
          ctx.globalAlpha = 1;
          ctx.fillStyle = '#000';
          ctx.fillText(label, p.x + 2 * s.view.zoom, p.y + 2 * s.view.zoom);
        }
      };
      for (var i = 0; i < s.map.players.length; i++) {
        mark(s.map.players[i].x, s.map.players[i].y, '#54a0ff', 'P' + (i + 1));
      }
      for (var j = 0; j < s.map.enemies.length; j++) {
        mark(s.map.enemies[j].x, s.map.enemies[j].y, '#c96fb0', 'E');
      }
      if (s.selection) {
        var a = subToScreen(s.selection.x, s.selection.y);
        ctx.strokeStyle = '#e0b34a';
        ctx.lineWidth = 2;
        ctx.strokeRect(a.x, a.y, s.selection.w * s.view.zoom, s.selection.h * s.view.zoom);
      }
      ctx.restore();
    }

    // ★ 唯一渲染入口(B6:旧实现同一帧连画两次画布)
    function render() {
      if (!s.map) return;
      var W = canvas.width, H = canvas.height;
      var t0 = (typeof performance !== 'undefined' ? performance.now() : Date.now());
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalAlpha = 1;
      ctx.fillStyle = '#0e1013';
      ctx.fillRect(0, 0, W, H);
      if (zoomPath(s.view.zoom) === 'thumb') drawThumbPath(W, H); else drawLayerPath(W, H);
      if (s.grid) drawGrid(W, H);
      drawOverlay(W, H);
      stat.renders++;
      stat.lastRenderMs = (typeof performance !== 'undefined' ? performance.now() : Date.now()) - t0;
    }

    // 尺寸变化:**只有一个机制**(B7:ResizeObserver 与 window.resize 同时挂 = 每次 resize 建两遍)
    function resize() {
      var wrap = canvas.parentElement;
      var w = Math.max(1, wrap ? wrap.clientWidth : canvas.width);
      var h = Math.max(1, wrap ? wrap.clientHeight : canvas.height);
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w; canvas.height = h;
        ctx.imageSmoothingEnabled = false;            // ★ 改尺寸会重置 ctx 状态,必须重设
        render();
      }
    }

    function fit() {
      if (!s.map) return;
      s.view.zoom = fitZoom(s.map.subCols, s.map.subRows, canvas.width, canvas.height, 24);
      s.view.x = -(canvas.width / s.view.zoom - s.map.subCols) / 2;
      s.view.y = -(canvas.height / s.view.zoom - s.map.subRows) / 2;
      render();
    }

    // 编辑某几个格之后:重画它们的缩略图块(Uint32Array 的下标 → 格坐标)
    function invalidateCells(L, list) {
      if (!s.map) return null;
      var rect = null;
      for (var i = 0; i < list.length; i++) {
        var r = { x: list[i].cx * SUB, y: list[i].cy * SUB, w: SUB, h: SUB };
        rect = rectUnion(rect, r);
      }
      if (!rect) return null;
      if (thumbs[L]) paintThumbRect(L, rect);
      return rect;
    }
    function invalidateAll() {
      if (!s.map) return Promise.resolve();
      // ★★ 先让缩略图的**尺寸**对齐当前图:本方法是一条**公开入口**,而它此前不经过
      //    ensureThumbs —— 调用方完全可能在"改了 s.map 的尺寸"之后直接进来(撤销/重做一条
      //    kind='whole' 的差量就是这么把 subCols/subRows 就地改掉的)。少了这一步,
      //    paintThumbRect 会往画布外写(被静默裁掉)、drawThumbPath 又会把那张旧画布拉伸到
      //    新尺寸的目标框里 —— 两条路径都是"画面错了但不报错"。
      // ★ 只有本方法配得起这一步:它紧接着 buildThumbs() 把**整张**重画一遍,故"重建出
      //    空白画布"不会留下半张空白。invalidateCells(单块脏矩形)恰恰相反 —— 那里重建 =
      //    只补一小块、其余留白,所以它继续依赖 setMap 那一侧的 ensureThumbs(尺寸只在
      //    setMap 或本方法里才可能变,而 setMap 自己会调)。
      ensureThumbs(s.map);
      return buildThumbs().then(render);
    }

    function setMap(map) {
      s.map = map;
      s.selection = null;
      ensureThumbs(map);
      return buildThumbs().then(function () {
        s.view.zoom = fitZoom(map.subCols, map.subRows, canvas.width, canvas.height, 24);
        s.view.x = -(canvas.width / s.view.zoom - map.subCols) / 2;
        s.view.y = -(canvas.height / s.view.zoom - map.subRows) / 2;
        render();
      });
    }

    return {
      setMap: setMap, map: function () { return s.map; },
      setLayer: function (L) { s.layer = L; render(); }, layer: function () { return s.layer; },
      setView: function (v) {
        s.view.x = v.x; s.view.y = v.y;
        s.view.zoom = clampZoom(v.zoom === undefined ? s.view.zoom : v.zoom);
        render();
      },
      view: function () { return { x: s.view.x, y: s.view.y, zoom: s.view.zoom }; },
      setGrid: function (b) { s.grid = !!b; render(); },
      setSubGrid: function (b) { s.subGrid = !!b; render(); },
      setTorus: function (b) { s.torus = !!b; render(); },
      setDimOthers: function (b) { s.dimOthers = !!b; render(); },
      setLayerVisible: function (L, b) { s.layerVisible[L] = !!b; render(); },
      layerVisible: function (L) { return s.layerVisible[L]; },
      setLayerLocked: function (L, b) { s.layerLocked[L] = !!b; },
      layerLocked: function (L) { return s.layerLocked[L]; },
      setSelection: function (sel) { s.selection = sel; render(); },
      selection: function () { return s.selection; },
      render: render, resize: resize, fit: fit,
      invalidateCells: invalidateCells, invalidateAll: invalidateAll,
      thumbCanvas: function (L) { return thumbs[L]; },
      thumbPx: function () { return thumbPx; },
      screenToSub: screenToSub, subToScreen: subToScreen,
      stats: function () { return { thumbMs: stat.thumbMs, renders: stat.renders,
                                    lastRenderMs: stat.lastRenderMs, thumbsBuilt: stat.thumbsBuilt }; },
    };
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
    DRAW_ORDER: DRAW_ORDER, mount: mount,
  };
})();
