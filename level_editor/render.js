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
      preview: null,       // 拖矩形/直线时的预览框(子格单位)
      selDrag: null,       // {sel, dx, dy}:选区拖动中(拖动只记偏移,松手才提交)
    };
    var thumbs = [null, null, null, null];
    var thumbPx = THUMB_PX;
    var slicer = createSlicer(opts.slicer || {});
    var stat = { thumbMs: 0, renders: 0, lastRenderMs: 0, thumbsBuilt: 0 };

    // ── ★★ 视图入口的失败**必须看得见**(评审发现 1)──
    // Task 4 之后 resize/fit/setView/setZoomAt/panBy/setMap/invalidateAll 都返回**由分帧器
    // 派生出来的 promise**(全屏重建是分帧的)。而 ≥8 那条路上的抛错(`tileFor` 的
    // `Tint: 图集里没有纹理 N` —— 改图集/换图之后就够得着)现在发生在**任务回调**里,
    // 于是它变成 run() 的**拒绝**,不再是 render() 里那次同步抛出:
    //   · 页面侧唯一的消费者(ui.js 的 guard)是**同步** try/catch ⇒ 接不住;
    //   · `render()` 这一次根本没执行 ⇒ 画布**默默停在上一帧**,只在控制台留一行错。
    // 这正是本仓最防的那类"按了没反应"。⇒ 在**返回之前**给链子挂一个观察者。
    // ★ 两条契约同时成立,缺一不可:
    //   ① 想 await / 想自己 catch 的调用方**照样拿到那次拒绝**(这里只挂观察者,不改、不吞
    //      也不替换返回的那个 promise);
    //   ② 完全不管返回值的调用方,也能在**屏幕上的同一条通道**里看到原因(状态栏)。
    // ★ 副作用(这正是我们要的):它把这条拒绝从全局 unhandledrejection 那张网里摘了出来
    //   (窗口有了拒绝处理函数,引擎就不再报"未处理")⇒ 用户收到的是一条**指名道姓**的消息,
    //   而不是"未处理的 promise 拒绝"。两条都出现才是坏味道(catch 写在 then 链末端)。
    function msgOf(e) {
      // ui.js 有一份同款(msgOf);它本批冻结,故这里不能共享 —— 两边都只做"取出人能读的那句"。
      if (!e) return '未知错误';
      var m = (e.message !== undefined) ? String(e.message) : String(e);
      if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
      return m === '' ? String(e) : m;
    }
    function defaultErrorSink(text, err) {
      // ★ 走**页面已经在用的那条通道**:ui.js 的 status()(= 状态栏 #status-msg)。
      //   运行时查找,不在模块顶层引 ui.js —— 依赖顺序是 core → tint → render → io → ui,
      //   加载期 ui.js 还不存在(顶层引 = node 冒烟当场炸)。
      var shown = false;
      try {
        var E = globalThis.Editor;
        if (E && typeof E.status === 'function') { E.status(text); shown = true; }
      } catch (e1) { shown = false; }
      if (!shown) {
        try {
          var el = (typeof document !== 'undefined' && document.getElementById)
            ? document.getElementById('status-msg') : null;
          if (el) { el.textContent = String(text); shown = true; }
        } catch (e2) { shown = false; }
      }
      if (typeof console !== 'undefined' && console.error) console.error(text, err);
    }
    var errorSink = (typeof opts.onError === 'function') ? opts.onError : defaultErrorSink;
    function reportViewError(label, err) {
      var text = '出错了(' + label + '):' + msgOf(err);
      try { errorSink(text, err); }
      catch (e) {
        // ★ 报错通道自己坏了也不许把异常扔回调用方(那就成了第二处"看得见才怪")。
        if (typeof console !== 'undefined' && console.error) console.error(text, e);
      }
    }
    // 给"会拒绝的入口"挂观察者,并**原样**返回那个 promise(见上面两条契约)。
    function observed(label, p) {
      if (p && typeof p.then === 'function') {
        p.then(null, function (e) { reportViewError(label, e); });
      }
      return p;
    }

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
          var q = dragSource(X, Y);                    // ★ 拖动中:读**源**子格(纯读)
          var raw = q.hit ? descAt(s.map, L, q.X, q.Y) : 0;
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
    function nowMs() {
      return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
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

    // ── ② 视口离屏层(★ 绝不建全图离屏:500×300 子格按 16px 是 8000×4800 = 153MB,
    //    浏览器会直接拒绝)──
    // ★★ 像素坐标系的定义(整个 ② 都靠它):离屏层像素 (px,py) ↔ 世界子格
    //    (view.x + px/zoom, view.y + py/zoom) —— 与屏幕**同一套**坐标。于是
    //    · 平移 = 像素级自拷贝搬移 + 只补新露出的边条;
    //    · 3×3 副本 = 把这**同一张**图按「副本世界偏移 × zoom」平移后再画一次。
    var layerCv = [null, null, null, null];
    var layerDirty = [null, null, null, null];      // 每层一个子格矩形(null = 干净)
    var cellCache = null;                            // ③
    // ★ 视图/图集/尺寸的代际:在飞的那一轮重建靠它作废(见 viewChanged)。
    var layerGen = 0;
    var layersClean = false;                         // 四张离屏层是否与**当前视图**一致
    // ★★ 两个名字相近、**量的不是一件事**(评审发现 9),人眼清单两个都要读:
    //      · `layerRebuilds` = **flushDirty 的脏区重画次数**(编辑一格 = 该层 +1,单位是"块");
    //      · `layerRebuildMs` = **一次整片 buildLayers 的耗时**(单位是毫秒)。
    //    计划把这两个键名钉死了(接口表),故这里只**标注**、不改名(改名会与计划文本对不上)。
    var stat2 = { cellsHits: 0, cellsMisses: 0, cellsSize: 0,
                  layerRebuilds: 0, layerRebuildMs: 0, panCopies: 0 };

    // ★ 视图一动(平移/缩放/换图/改尺寸):在飞的那一轮重建**整个作废**。
    //   ★★ 少了这一步会留下**永久性**的错位内容:分帧重建的条带矩形是按**旧视图**算的,
    //   而 paintLayerRect 又按**当前视图**换算像素 ⇒ 视图一动,剩下的条带就画到了别处;
    //   更糟的是它会与"自拷贝搬移"混在一起(搬移的前提是整张图属于**同一次**视图的产物),
    //   而脏标记此刻已经清干净了 —— 谁都不会再补那几块。
    //   ⇒ 纪律:**视图不干净时,平移一律改走整片重建**(见 panBy 的第一条判据)。
    function viewChanged() { layerGen++; layersClean = false; }

    function ensureLayerCanvas(L) {
      if (layerCv[L] && layerCv[L].width === canvas.width && layerCv[L].height === canvas.height) return layerCv[L];
      var c = document.createElement('canvas');
      c.width = canvas.width; c.height = canvas.height;
      c.getContext('2d').imageSmoothingEnabled = false;   // ★ 离屏也必须关插值(A5)
      layerCv[L] = c;
      layerDirty[L] = null;
      return c;
    }

    // ③ 的 build 回调:把一格的 16 个子格**解析成 16 个 tile 引用**(空气 → null)。
    // ★ 像素只存在 ④ 里;这里不复制像素,所以 ③ 的条目极小(见 DEFAULT_CELL_MAX 的说明)。
    // ★★ 只有**纹理层**会走到这里 —— 颜色层的 16 个子格是 RGBA,由 paintLayerRect 的颜色
    //   分支直接取色。两者长得一模一样、含义完全不同:RGBA 喂给 Core.texOf 不抛,只是结论
    //   毫无意义(#ff0000ff 的纹理位是 0 ⇒ 整层当空气 ⇒ 看不见; #00ffffff 的纹理位是 4095
    //   ⇒ tileFor 当场抛 Tint 越界)。判据一律取 layerIsColor,不在循环里另抄一份。
    function buildCell(L, cx, cy) {
      var out = new Array(SUB * SUB);
      var bx = cx * SUB, by = cy * SUB;
      for (var qy = 0; qy < SUB; qy++) {
        for (var qx = 0; qx < SUB; qx++) {
          var raw = descAt(s.map, L, bx + qx, by + qy);
          out[qy * SUB + qx] = (raw === 0 || Core.texOf(raw) === 0) ? null : tileFor(raw, qx, qy);
        }
      }
      return out;
    }

    // 重画某一层的离屏上的一块矩形(单位 = 子格;矩形允许越出画布**与主网格**,内部裁剪)
    // ★ 越出主网格是**常态**:离屏层的像素系与屏幕同一套,视图越过接缝时那半边像素只有
    //   靠折算后的格才填得上(descAt 本来就环面折算)。绝不许按"主网格"裁剪 —— 裁了就是
    //   视图拖过边界时的一整条空白(而 3×3 副本**填不上**它,理由见 buildLayers 的注释)。
    function paintLayerRect(L, rect) {
      var cv = ensureLayerCanvas(L);
      var c = cv.getContext('2d');
      var z = s.view.zoom;
      // 世界子格 → 画布局部像素
      var px0 = Math.max(0, Math.floor((rect.x - s.view.x) * z));
      var py0 = Math.max(0, Math.floor((rect.y - s.view.y) * z));
      var px1 = Math.min(cv.width, Math.ceil((rect.x + rect.w - s.view.x) * z));
      var py1 = Math.min(cv.height, Math.ceil((rect.y + rect.h - s.view.y) * z));
      if (px1 <= px0 || py1 <= py0) return;
      c.clearRect(px0, py0, px1 - px0, py1 - py0);
      if (!layerArray(s.map, L)) return;                 // 缺席层 = 全空气(已清干净)
      var cell0x = Math.floor((s.view.x + px0 / z) / SUB), cell1x = Math.ceil((s.view.x + px1 / z) / SUB);
      var cell0y = Math.floor((s.view.y + py0 / z) / SUB), cell1y = Math.ceil((s.view.y + py1 / z) / SUB);
      // ★★ 按层种类**分派**(判据取一次,不在逐格循环里重算)—— 这就是 F1 那道闸门。
      var colorLayer = layerIsColor(L);
      var cw = Core.cellsWOf(s.map), ch = Core.cellsHOf(s.map);
      for (var cy = cell0y; cy < cell1y; cy++) {
        for (var cx = cell0x; cx < cell1x; cx++) {
          var bx = cx * SUB, by = cy * SUB;
          if (colorLayer) {
            // 颜色层:逐子格读 RGBA、直接填色。alpha = 0 = 这一格没有颜色(上面已 clearRect,
            // 这里什么都不画)。★ 这里**不许**出现 texOf(见 buildCell 的两条静默症状)。
            for (var kc = 0; kc < SUB * SUB; kc++) {
              var Xc = bx + (kc % SUB), Yc = by + Math.floor(kc / SUB);
              var qc = dragSource(Xc, Yc);                 // ★ 拖动中:读**源**子格(纯读)
              var rawc = qc.hit ? descAt(s.map, L, qc.X, qc.Y) : 0;
              if (((rawc >>> 0) & 255) === 0) continue;
              c.fillStyle = cssOfRGBA(rawc);
              c.fillRect((Xc - s.view.x) * z, (Yc - s.view.y) * z, z, z);
            }
            continue;
          }
          // ★ ③ 的键必须是**主网格上的格号**:环面让同一格有多种写法(cx = -1 与 cx = cellsW-1),
          //   不折算的话同一格会缓存两条条目,而编辑只 touch 其中一条 ⇒ 接缝另一侧的副本
          //   继续显示**陈旧内容**(画面错了、一个字都不报)。
          // ★★ 拖动偏移从这里接:拖动中读的是**源格**(纯读,不改进数据),画的位置仍是
          //   目标格(bx/by,见循环体最后一行)—— 只有"读"是偏移过的。
          //   ★ 传进去的是**子格**坐标(选区与偏移都是子格单位),取缓存键前再折回格号:
          //     偏移是格对齐时(整数画笔 + 整格选区)这一步是恒等;偏移落在子格上时按格取整
          //     —— 只见于小数画笔的选区,是拖动途中的子格级近似,松手后由 moveRegion 归位。
          var gx = wrapIdx(cx, cw), gy = wrapIdx(cy, ch);
          var q = dragSource(gx * SUB, gy * SUB);
          if (!q.hit) continue;                            // 被腾空的源区 ⇒ 这一格不画
          var tilesOfCell = cellCache.get(L, wrapIdx(Math.floor(q.X / SUB), cw),
                                             wrapIdx(Math.floor(q.Y / SUB), ch));  // ★ ③:这一格的 16 个 tile
          for (var k = 0; k < tilesOfCell.length; k++) {
            var t = tilesOfCell[k];
            if (!t) continue;
            var X = bx + (k % SUB), Y = by + Math.floor(k / SUB);   // ★ 画在**目标格**的位置
            c.drawImage(t, (X - s.view.x) * z, (Y - s.view.y) * z, z, z);
          }
        }
      }
    }

    // 重建所有"脏"的离屏层。★ 编辑之后只重画脏矩形 ⇒ 成本 O(脏区),不是 O(全屏)。
    // ★ 隐藏层**也照画**:离屏内容与可见性无关(与 ① 缩略图同一条纪律 —— 可见性/压暗只在
    //   render() 合成时生效)。反过来("隐藏就不画")会让"隐藏 → 编辑 → 显示"看到一片旧内容。
    function flushDirty() {
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        if (!layerDirty[L]) continue;
        var d = layerDirty[L];
        layerDirty[L] = null;
        if (!layerArray(s.map, L)) { ensureLayerCanvas(L).getContext('2d').clearRect(0, 0, canvas.width, canvas.height); continue; }
        paintLayerRect(L, d);
        stat2.layerRebuilds++;
      }
    }

    // 全屏重建(闸 2「全屏重建 → 分帧」):四层各切成若干条,交给分帧器。
    // ★★ 重画的世界范围就是**可见范围本身**(visibleSubRange),**不**裁到主网格 ——
    //    离屏层的像素系与屏幕同一套,所以"可见范围"里落在主网格之外的像素(视图越过接缝
    //    时必然出现)必须用**折算后**的格去填。裁了会留一整条空白,而 3×3 的副本**填不上**:
    //    副本的贴图偏移是「副本世界偏移 × zoom」,对"视口 12.5 格宽、地图 500 格"这种常态,
    //    隔壁副本被平移 −8000px、整个落在画布外,根本进不到屏幕。
    //    ⇒ 裁 = 视图拖过边界时左边一条黑带(人眼清单第 4 条会当场看到)。
    function buildLayers() {
      if (!s.map) return Promise.resolve();
      // ★★ 入口就把 layersClean **放下**(评审发现 2):`++layerGen` 只作废**在飞**的那一轮,
      //    管不到"这一轮还没落地"—— 而"还没落地"这段时间里离屏层是**半旧**的。
      //    本方法是**公开入口**(见文件尾的导出表),调用方(编辑后整批重建 / Task 8 换贴图源)
      //    完全可能**不**先走 viewChanged() 就进来;那时 layersClean 若还是 true,panBy 就会拿
      //    一张半旧的图自拷贝搬移,而脏标记此刻已经清干净了 ⇒ 谁也补不回来 = **永久错位**。
      //    仓内现有调用方都先 viewChanged(),所以今天不出事 —— 这一行是给"将来的直接调用方"的。
      layersClean = false;
      var myGen = ++layerGen;
      var r = visibleSubRange(s.view, canvas.width, canvas.height, s.map.subCols, s.map.subRows);
      var tasks = [];
      var bands = 16;
      var h = Math.max(1, Math.ceil((r.y1 - r.y0) / bands));
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        layerDirty[L] = null;
        ensureLayerCanvas(L);
        for (var y = r.y0; y < r.y1; y += h) {
          tasks.push({ L: L, rect: { x: r.x0, y: y, w: r.x1 - r.x0, h: Math.min(h, r.y1 - y) } });
        }
      }
      var t0 = nowMs();
      return slicer.run(tasks, function (t) {
        if (myGen !== layerGen) return;              // ★ 过期的一轮:整条作废(视图/尺寸/图集已变)
        paintLayerRect(t.L, t.rect);
      }).then(function () {
        if (myGen !== layerGen) return;              // ★ 过期的一轮不许把 layersClean 抬起来
        stat2.layerRebuildMs = nowMs() - t0;
        layersClean = true;
      });
    }

    // ★★ 3×3 的合成:每份副本都是把**同一张**离屏层按「副本世界偏移 × zoom」平移后再画一次。
    //    偏移是 subCols/subRows 的整数倍,而 paintLayerRect 读格时本来就环面折算
    //    ⇒ 每份副本在任意位置画出来的内容都等于"该处应有的内容"(折算前后是同一格),
    //    副本之间不会互相画错。
    // ★★ 但**别把"多份副本"读成承重**(评审发现 8;报告 §9.1):离屏层的像素系 = 屏幕系,
    //    它上面已经按**可见范围本身**把每一处应有的内容都铺好了 —— 越出主网格的那些像素由
    //    paintLayerRect 的**环面折算**补上。所以 ±subCols/±subRows 那几份副本画的是
    //    **同一批像素**,在当前坐标系下是**冗余**的;"屏幕每一处都有一份盖上去"这个保证
    //    来自 paintLayerRect 的折算,**不是**来自这里。
    //    留着它们的两个理由:① 环面 N×N 铺贴是计划明列的交付面;② `setTorus` 开关的可见
    //    行为就是它(⑩d 钉住的 [8,4])。真要省这几笔全画布 drawImage/层/帧,把 `offs` 收成
    //    [[0,0]] 即可(⑩d 的期望值要同改)—— 那是省冗余,不是拆保证。
    // ★ 切层 ≠ 重画:压暗/可见性只在**合成**这一层做(4 次 drawImage),不碰任何一层的离屏内容。
    function drawLayerPath(W, H) {
      flushDirty();
      var offs = torusList(W, H);
      var z = s.view.zoom;
      for (var oi = 0; oi < DRAW_ORDER.length; oi++) {
        var L = DRAW_ORDER[oi];
        if (!s.layerVisible[L] || !layerCv[L]) continue;
        // ★ 尺寸对不上的离屏层(改窗口之后、重建还没跑到)一路都不许画:它的像素刻度属于
        //   上一块画布,画出去是"整层错位",而空白会被下一次重建补上(resize 已经把它丢掉)。
        if (layerCv[L].width !== W || layerCv[L].height !== H) continue;
        ctx.globalAlpha = (s.dimOthers && L !== s.layer && L !== Core.LAYER_BG) ? 0.4 : 1;
        for (var i = 0; i < offs.length; i++) {
          ctx.drawImage(layerCv[L], offs[i][0] * z, offs[i][1] * z);
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
      if (s.preview) {
        var pv = subToScreen(s.preview.x, s.preview.y);
        ctx.setLineDash([6, 4]);
        ctx.strokeStyle = '#54a0ff';
        ctx.lineWidth = 1;
        ctx.strokeRect(pv.x, pv.y, s.preview.w * s.view.zoom, s.preview.h * s.view.zoom);
        ctx.setLineDash([]);
      }
      if (s.selection) {
        // ★ 拖动中:框按**偏移后**的位置画(数据还没动 —— 松手才 moveRegion)。框跟手走
        //   是拖动过程中**唯一**看得见的反馈:`setSelDrag` 只调 render(),而 render() 是
        //   合成已经烤好的 ①/② 位图(`paintLayerRect` / `paintThumbRect` 要等脏区或重建才跑)
        //   ⇒ 偏移查询要等别的重画(缩放/平移/窗口变化)才显形。见 Task 7 报告的"已知边界"。
        var sel = s.selDrag
          ? { x: s.selection.x + s.selDrag.dx, y: s.selection.y + s.selDrag.dy,
              w: s.selection.w, h: s.selection.h }
          : s.selection;
        var a = subToScreen(sel.x, sel.y);
        ctx.strokeStyle = '#e0b34a';
        ctx.lineWidth = 2;
        ctx.strokeRect(a.x, a.y, sel.w * s.view.zoom, sel.h * s.view.zoom);
      }
      ctx.restore();
    }

    // ★ 唯一渲染入口(B6:旧实现同一帧连画两次画布)
    // ★★ 三条路径按 zoom 分工:① 缩略图(< 8)、② 视口离屏层(≥ 8);**合成**那一步
    //    (层可见性/压暗/3×3 副本)两条路都走 ⇒ "切层"只是重新合成,永远不重画任何一层。
    function render() {
      if (!s.map) return;
      var W = canvas.width, H = canvas.height;
      var t0 = nowMs();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalAlpha = 1;
      ctx.fillStyle = '#0e1013';
      ctx.fillRect(0, 0, W, H);
      if (zoomPath(s.view.zoom) === 'thumb') drawThumbPath(W, H); else drawLayerPath(W, H);
      if (s.grid) drawGrid(W, H);
      drawOverlay(W, H);
      stat.renders++;
      stat.lastRenderMs = nowMs() - t0;
      // ★ ③ 的记账随 render 同步一份(状态栏/自检读 stats(),不必自己去问 ③)
      stat2.cellsHits = cellCache ? cellCache.stats().hits : 0;
      stat2.cellsMisses = cellCache ? cellCache.stats().misses : 0;
      stat2.cellsSize = cellCache ? cellCache.stats().size : 0;
    }

    // 尺寸变化:**只有一个机制**(B7:ResizeObserver 与 window.resize 同时挂 = 每次 resize 建两遍)
    function resize() {
      var wrap = canvas.parentElement;
      var w = Math.max(1, wrap ? wrap.clientWidth : canvas.width);
      var h = Math.max(1, wrap ? wrap.clientHeight : canvas.height);
      if (canvas.width === w && canvas.height === h) return;
      canvas.width = w; canvas.height = h;
      ctx.imageSmoothingEnabled = false;            // ★ 改尺寸会重置 ctx 状态,必须重设
      // ★★ 离屏层的像素是**按旧画布尺寸**铺的 ⇒ 尺寸一改整片失效,旧画布必须**丢掉**:
      //    留着的话 drawLayerPath 会把它按新目标框画出去(整层错位),而"只标脏"也不行
      //    (脏矩形只补一小块,其余留白)。丢掉之后由 buildLayers 分帧重来一遍。
      for (var L = 0; L < Core.LAYER_COUNT; L++) { layerCv[L] = null; layerDirty[L] = null; }
      viewChanged();
      if (s.map && zoomPath(s.view.zoom) === 'layers') return observed('resize', buildLayers().then(render));
      render();
    }

    function fit() {
      if (!s.map) return;
      s.view.zoom = fitZoom(s.map.subCols, s.map.subRows, canvas.width, canvas.height, 24);
      s.view.x = -(canvas.width / s.view.zoom - s.map.subCols) / 2;
      s.view.y = -(canvas.height / s.view.zoom - s.map.subRows) / 2;
      // ★ 适配改的是 zoom ⇒ 每个子格多少像素都变了,离屏层整片失效(全屏重建,闸 2 分帧)
      viewChanged();
      if (zoomPath(s.view.zoom) === 'layers') return observed('fit', buildLayers().then(render));
      render();
    }

    // ── 选区拖动:**只记偏移**(B3)。渲染时对选区内的格做**偏移查询**(纯读),
    //    松手才提交一次 moveRegion —— 老实现每次 pointermove 都深拷贝三份全图(B3)。
    function setSelDrag(sel, dx, dy) {
      s.selDrag = sel ? { sel: sel, dx: dx, dy: dy } : null;
      render();
    }
    function setPreview(rect) { s.preview = rect; render(); }
    // 拖动中的选区:目标格 (X,Y) 的内容来自源格 (X-dx, Y-dy)(纯读,不改进数据)。
    // ★ 坐标一律是**子格**(选区的 x/y/w/h 与 dx/dy 都是子格单位 —— 见 UI 的 subRectOf)。
    // ★★ 三种目标格,与"松手后 moveRegion 真正写出来的结果"**逐格一致**(预览必须等于落笔):
    //    ① 源格在选区内        ⇒ 读源格(被搬过来的那部分);
    //    ② 源格在外、目标在选区内 ⇒ 那是**被腾空的源区** ⇒ hit:false(不画);
    //    ③ 两边都在选区外      ⇒ 原样读它自己(没被动过的底)。
    //    ★ 少了 ③(把"目标不在偏移后的选区里"一律当腾空)的后果不是"少画一点":drag 的偏移
    //      一动,除选区外的**整整一张图**都判成腾空 ⇒ 拖动时地图整体消失、只剩一个框在飘。
    //      `selectionSource` 只答"源格在不在选区里",第 ③ 种情形要靠**目标格**自己判。
    function dragSource(X, Y) {
      if (!s.selDrag) return { hit: true, X: X, Y: Y };
      var sel = s.selDrag.sel, q = selectionSource(sel, s.selDrag.dx, s.selDrag.dy, X, Y);
      if (q.hit) return q;
      var vacated = (X >= sel.x && X < sel.x + sel.w && Y >= sel.y && Y < sel.y + sel.h);
      return vacated ? { hit: false, X: X, Y: Y } : { hit: true, X: X, Y: Y };
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
      // ★★ 同理,② 的离屏层也是"按内容铺的位图":整张图变了(或是尺寸变了)之后,
      //    它们一个像素都不再成立 ⇒ 与缩略图一起整片重建(丢弃 + 分帧重来)。
      //    只 render() 的话,≥8 px/子格 那条路上会继续显示**改动前**的内容(缩略图对了、
      //    放大之后不对 —— 而"放大才看得见"正是这条路径的常态)。
      for (var L = 0; L < Core.LAYER_COUNT; L++) { layerCv[L] = null; layerDirty[L] = null; }
      viewChanged();
      return observed('invalidateAll', buildThumbs().then(function () {
        return (zoomPath(s.view.zoom) === 'layers') ? buildLayers() : null;
      }).then(render));
    }

    function setMap(map) {
      s.map = map;
      s.selection = null;
      ensureThumbs(map);
      // ★ 换图 = 内容全变:③ 必须**整片**重建(旧的格位图属于上一张图,连键都可能相同)
      cellCache = createCellCache({ maxCells: DEFAULT_CELL_MAX, build: buildCell });
      attachCells(cellCache);
      // ★ ② 同理:旧离屏层画的是上一张图,连尺寸都可能不同 ⇒ 丢掉重来(见 resize 的注释)。
      for (var L = 0; L < Core.LAYER_COUNT; L++) { layerCv[L] = null; layerDirty[L] = null; }
      viewChanged();                                  // 在飞的那一轮重建画的是上一张图 ⇒ 作废
      return observed('setMap', buildThumbs().then(function () {
        s.view.zoom = fitZoom(map.subCols, map.subRows, canvas.width, canvas.height, 24);
        s.view.x = -(canvas.width / s.view.zoom - map.subCols) / 2;
        s.view.y = -(canvas.height / s.view.zoom - map.subRows) / 2;
        // ★ 适配之后落在缩略图路径(< 8)时**不**建离屏层:大图一上来就白画一屏(它是分帧的,
        //   但那几帧白费);等真放大到 ≥8 时 setZoomAt 会建。③ 与 ① 不受影响。
        return (zoomPath(s.view.zoom) === 'layers') ? buildLayers() : null;
      }).then(render));
    }

    // ── 编辑与视图操作(规格 §4.2)──
    // 把脏矩形裁到主网格(单位 = 子格)。★ 编辑永远落在 [0, 子格数) 里,所以这是**守卫**
    //   而不是必需:越界的脏矩形(将来的调用方算错)不该让离屏层去画一片莫名其妙的东西。
    function clipped(r) {
      if (!r) return null;
      var x0 = Math.max(0, r.x), y0 = Math.max(0, r.y);
      var x1 = Math.min(s.map.subCols, r.x + r.w), y1 = Math.min(s.map.subRows, r.y + r.h);
      if (x1 <= x0 || y1 <= y0) return null;
      return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    }

    // ★★ 编辑之后的**唯一**入口:三件事一次做完(否则总有一层忘了作废)
    //    ① ③ 的 touch(内容版本号)② ② 的脏矩形 ③ ① 的缩略图块
    // ★ 颜色层**不进 ③**(它的内容是 RGBA,不是 tile 引用 —— 见 buildCell 的说明):
    //   它的"内容版本号"就是地图数组本身,重画由下面的脏矩形负责。
    var dirtySet = createDirtySet();
    function editCells(L, list) {
      if (!s.map || !list || !list.length) return;
      var colorLayer = layerIsColor(L);
      for (var i = 0; i < list.length; i++) {
        if (!colorLayer) cellCache.touch(L, list[i].cx, list[i].cy);
        dirtySet.addCell(L, list[i].cx, list[i].cy);
      }
      var box = dirtySet.rect();
      dirtySet.clear();
      if (!box) return;
      // ★ 脏矩形只对**这一层**有意义(合成时按层拆):③ 的版本号是每格一条,
      //   而"这一层要不要重画"只需要一个上界(包围盒偏大只会多画一点,不会画错)。
      var inner = clipped(box);
      if (inner && layerArray(s.map, L)) layerDirty[L] = rectUnion(layerDirty[L], inner);
      invalidateCells(L, list);                       // ①(缩略图那块矩形)
      render();
    }

    // 平移(单位 = 画布像素,方向 = **视图/世界**的位移:view.x 增加 dxPx/zoom)。
    // ★★ 内容是**反向**搬移的(向右看 = 画面往左走),所以自拷贝的偏移取负 —— 与
    //    panStrips 的分工严格互补:那边给出"新露出来、要补画的边条"。
    function panBy(dxPx, dyPx) {
      if (!s.map) return;
      if (!isFinite(dxPx)) dxPx = 0;
      if (!isFinite(dyPx)) dyPx = 0;
      // ★★ 位移**先量化到整像素**(评审发现 3):自拷贝是 drawImage,而插值关掉之后光栅器会
      //    把它的偏移吸附到整像素,`s.view` 却按**精确值**前进 ⇒ 每次平移最多差 0.5px,而且
      //    **会累积** —— 边条只补"新露出来的那一条",永远不去纠正已经攒下的偏差 ⇒ 内容是
      //    "慢慢从网格/覆盖层上漂走"(改窗口大小或拖久了才看得出来,不报错)。
      //    ★ 只量化自拷贝的偏移是不够的:view / panStrips / 自拷贝三者必须**同源**,否则
      //      上面那条累积照样发生。故在这里一次量化,后面三处全用这个值。
      //    ★ 代价(照实):不足 1px 的平移被**丢弃**(0.4px 走十次 = 一步都不动)。这是刻意的
      //      ——"不动"比"越拖越歪"好,而且它与闸 1 的口径一致(钳制,不报错、不回滚)。
      dxPx = Math.round(dxPx); dyPx = Math.round(dyPx);
      if (dxPx === 0 && dyPx === 0) return;
      var W = canvas.width, H = canvas.height;
      s.view.x += dxPx / s.view.zoom;
      s.view.y += dyPx / s.view.zoom;
      if (zoomPath(s.view.zoom) !== 'layers') { render(); return; }
      // ★★ 视图一动,在飞的那一轮重建(条带按旧视图算的)就不能再往这些画布上写 ——
      //    而"自拷贝搬移"又要求整张图属于同一次视图。不干净时老实走整片重建(分帧)。
      if (!layersClean) return observed('panBy', buildLayers().then(render));
      // ★ 位移大到整块都被换掉时,自拷贝已经没有意义 ⇒ 也走分帧重建(而不是一帧画满屏)
      if (Math.abs(dxPx) >= W || Math.abs(dyPx) >= H) { viewChanged(); return observed('panBy', buildLayers().then(render)); }
      var strips = panStrips(W, H, dxPx, dyPx);
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        var cv = layerCv[L];
        if (!cv || cv.width !== W || cv.height !== H) continue;
        var c = cv.getContext('2d');
        c.globalCompositeOperation = 'copy';
        c.drawImage(cv, -dxPx, -dyPx);
        c.globalCompositeOperation = 'source-over';
        for (var i = 0; i < strips.length; i++) {
          var st = strips[i];
          // 边条对应的世界矩形:像素 → 子格(补画按**新**视图换算,与搬移后的像素对齐)
          var wx = s.view.x + st.x / s.view.zoom, wy = s.view.y + st.y / s.view.zoom;
          paintLayerRect(L, { x: wx, y: wy, w: st.w / s.view.zoom, h: st.h / s.view.zoom });
        }
      }
      stat2.panCopies++;
      render();
    }

    // 以光标为锚缩放(滚轮):★ 缩放改变的是"每个子格多少像素" ⇒ 离屏层**所有**内容失效,
    // 只能整片重建(闸 2 分帧 —— 大图上是"慢慢画出来",不是"页面死掉")。
    function setZoomAt(px, py, factor) {
      var v = zoomAround(s.view, px, py, factor);
      s.view.x = v.x; s.view.y = v.y; s.view.zoom = v.zoom;
      viewChanged();
      if (!s.map || zoomPath(s.view.zoom) !== 'layers') { render(); return Promise.resolve(); }
      return observed('setZoomAt', buildLayers().then(render));
    }

    return {
      setMap: setMap, map: function () { return s.map; },
      setLayer: function (L) { s.layer = L; render(); }, layer: function () { return s.layer; },
      setView: function (v) {
        s.view.x = v.x; s.view.y = v.y;
        s.view.zoom = clampZoom(v.zoom === undefined ? s.view.zoom : v.zoom);
        // ★ 换视图 = 离屏层整片失效(见 buildLayers 的坐标系说明);平移请走 panBy(它是
        //   像素级搬移,只补边条)。本方法留给"跳到某个视图"这种**整片换**的场合。
        viewChanged();
        if (s.map && zoomPath(s.view.zoom) === 'layers') return observed('setView', buildLayers().then(render));
        render();
      },
      view: function () { return { x: s.view.x, y: s.view.y, zoom: s.view.zoom }; },
      setGrid: function (b) { s.grid = !!b; render(); },
      setSubGrid: function (b) { s.subGrid = !!b; render(); },
      setTorus: function (b) { s.torus = !!b; render(); },
      setDimOthers: function (b) { s.dimOthers = !!b; render(); },
      // ★ 可见性只影响**合成**(离屏内容照旧保留)⇒ 开关是 4 次 drawImage 的事,不重画任何一层。
      setLayerVisible: function (L, b) { s.layerVisible[L] = !!b; render(); },
      layerVisible: function (L) { return s.layerVisible[L]; },
      setLayerLocked: function (L, b) { s.layerLocked[L] = !!b; },
      layerLocked: function (L) { return s.layerLocked[L]; },
      setSelection: function (sel) { s.selection = sel; render(); },
      selection: function () { return s.selection; },
      setSelDrag: setSelDrag, setPreview: setPreview,
      isDraggingSelection: function () { return !!s.selDrag; },
      render: render, resize: resize, fit: fit,
      invalidateCells: invalidateCells, invalidateAll: invalidateAll,
      editCells: editCells, panBy: panBy, setZoomAt: setZoomAt, buildLayers: buildLayers,
      cells: function () { return cellCache; },
      // ★ 报错通道是**可换的**(评审发现 1 的接口增补):默认写页面状态栏(= ui.js 的
      //   status() 那条通道),页面/探针可以换掉它做断言或接自己的日志。传非函数则回落默认。
      setErrorSink: function (fn) { errorSink = (typeof fn === 'function') ? fn : defaultErrorSink; },
      thumbCanvas: function (L) { return thumbs[L]; },
      thumbPx: function () { return thumbPx; },
      screenToSub: screenToSub, subToScreen: subToScreen,
      stats: function () {
        return { thumbMs: stat.thumbMs, renders: stat.renders, lastRenderMs: stat.lastRenderMs,
                 thumbsBuilt: stat.thumbsBuilt, cellsHits: stat2.cellsHits, cellsMisses: stat2.cellsMisses,
                 cellsSize: stat2.cellsSize, layerRebuilds: stat2.layerRebuilds,
                 layerRebuildMs: stat2.layerRebuildMs, panCopies: stat2.panCopies };
      },
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

  // ── ② 的脏区簿记(纯逻辑:编辑 → 标脏;切层 → 只合成;平移 → 搬移 + 补边条)──
  // ★ 跨层的脏矩形合成用**一个**盒子就够:合成时按层拆是在 ② 的离屏层上做的,
  //   而"这一帧要不要重画"只需要一个上界(包围盒偏大只会多画一点,不会画错)。
  // ★ 没有容量上限:**这是有界的**(它只装调用方交上来的那几个格/矩形,用完即 clear),
  //   与"每帧累积的集合"不是一类东西。
  function createDirtySet() {
    var box = null;
    function addRect(r) { box = rectUnion(box, r); }
    // 格坐标(64px 格)→ 子格矩形
    function addCell(L, cx, cy) { addRect({ x: cx * SUB, y: cy * SUB, w: SUB, h: SUB }); }
    return { addRect: addRect, addCell: addCell,
             rect: function () { return box ? { x: box.x, y: box.y, w: box.w, h: box.h } : null; },
             clear: function () { box = null; } };
  }

  // 画布自拷贝之后"新露出来"的那一条(单位 = 画布像素)。位移超过画布尺寸 = 整块重画。
  // ★ 参数是**视图/世界**的位移方向(view.x 增加 dxPx/zoom):画面内容是**反向**走的,
  //   所以"向右看 10px"新露出来的是**右边**那 10px。调用方那里的自拷贝偏移是它的相反数。
  function panStrips(w, h, dx, dy) {
    var out = [];
    if (dx === 0 && dy === 0) return out;
    if (Math.abs(dx) >= w || Math.abs(dy) >= h) return [{ x: 0, y: 0, w: w, h: h }];
    if (dx > 0) out.push({ x: w - dx, y: 0, w: dx, h: h });
    if (dx < 0) out.push({ x: 0, y: 0, w: -dx, h: h });
    if (dy > 0) out.push({ x: 0, y: h - dy, w: w, h: dy });
    if (dy < 0) out.push({ x: 0, y: 0, w: w, h: -dy });
    return out;
  }

  // 以光标为锚缩放:光标下的那一子格在缩放前后停在原地。
  function zoomAround(view, px, py, factor) {
    var z = clampZoom(view.zoom * (isFinite(factor) && factor > 0 ? factor : 1));
    var wx = view.x + px / view.zoom, wy = view.y + py / view.zoom;
    return { x: wx - px / z, y: wy - py / z, zoom: z };
  }

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
    createDirtySet: createDirtySet, panStrips: panStrips, zoomAround: zoomAround,
    DRAW_ORDER: DRAW_ORDER, mount: mount,
  };
})();
