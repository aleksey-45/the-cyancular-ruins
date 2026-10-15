'use strict';
// tests/render/30_caches.js —— 相位 ①~③b:环面折算与空层 / 空气短路 / ③ 格位图缓存两条失效轴 / 换图同时作废 ③④。
globalThis.renderChain = globalThis.renderChain.then(async function () {
const Core = globalThis.Core;
const Render = globalThis.Render;
  eq([Render.wrapIdx(-1, 4), Render.wrapIdx(-5, 4), Render.wrapIdx(4, 4), Render.wrapIdx(0, 4)], [3, 3, 0, 0],
     'wrapIdx: 负数与越界都折回 [0, w)(-1→3、-5→3、4→0、0→0)');
  eq(Render.quadOf(-1), 3, 'quadOf: -1 → 3(与 Tint.quadIndex 的合法范围一致)');
  let quadOk = true;
  for (let v = -20; v <= 20; v++) { const q = Render.quadOf(v); if (q < 0 || q >= Core.SUB_PER_CELL || Math.floor(q) !== q) quadOk = false; }
  ok(quadOk, '★ quadOf 对 [-20,20] 每个整数都落在 0..' + (Core.SUB_PER_CELL - 1) + '(Tint 对越界象限**会抛**)');

  const m2 = makeMap(2, 1);                     // 8 × 4 子格
  setCells(m2, Core.LAYER_SCENE, [[0, 0], [7, 3]], function () { return Core.neutralDesc(3); });
  eq(Render.descAt(m2, Core.LAYER_SCENE, 0, 0), Core.neutralDesc(3), 'descAt: 命中');
  eq(Render.descAt(m2, Core.LAYER_SCENE, 8, 4), Core.neutralDesc(3), '★ descAt: 坐标环面折算(8,4) → (0,0)');
  eq(Render.descAt(m2, Core.LAYER_SCENE, -8, -4), Core.neutralDesc(3), '★ descAt: 负数环面折算');
  eq(Render.descAt(m2, Core.LAYER_FRONT, 0, 0), 0, 'descAt: 空的前景层 → 0(空气)');

  // ★★ 缺席层(null)= 全空气。规格 §2.4 的 createMap 恒建四层,而 layer_flags 允许缺层
  //    ⇒ 解码出来的一层可以是 null。渲染必须把 null 当"全空气",而不是当场抛。
  const mNull = makeMap(2, 1);
  mNull.layers[Core.LAYER_BACK] = null;
  eq(Render.layerArray(mNull, Core.LAYER_BACK), null, 'layerArray: 缺席层返回 null');
  ok(Render.descAt(mNull, Core.LAYER_BACK, 0, 0) === 0 && Render.descAt(mNull, Core.LAYER_BACK, 5, 2) === 0,
     '★★ 缺席层每一格都读成 0(空气)—— 不抛、也不当成别的东西');
  eq(Render.layerArray(mNull, Core.LAYER_BG).length, 8 * 4, 'layerArray: 背景层返回 rgba 数组');
  (function () {
    const be = spyBackend();
    Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H, { backend: be });
    ok(Render.atlasInfo() !== null && Render.atlasInfo().width === ATLAS_W, 'setAtlas 之后 atlasInfo 有值');
    eq(Render.atlasCapacity(), 30, 'atlasCapacity 从图集尺寸派生(320×96 → 10 列 × 3 行 = 30 块)');
    ok(Render.tileFor(0, 0, 0) === null, '★ tileFor(空气) → null');
    eq(be.calls.length, 0, '★★ 空气**没有**进 Tint(漏了这一步 = 第一帧就抛、每帧都在同一处抛)');
    ok(Render.tileFor(0x000007FF, 0, 0) === null,
       '★ 畸形描述符(辅码非 0 而纹理为 0,如 0x7FF)→ 也当空气(null),不走 Tint');
    eq(be.calls.length, 0, '畸形描述符同样没进 Tint');
    // ★ 正向对照:少了它,上面两条"0 次调用"在"tileFor 从不调 Tint"的坏实现下也全绿。
    ok(Render.tileFor(Core.neutralDesc(3), 0, 0) !== null, '正向对照:真砖能取到小图');
    eq(be.calls.length, 1, '正向对照:真砖**确实**进了 backend(证明上面那两条不是空转)');
    eq(be.calls[0].size, Tint.TILE_PX, 'backend 收到的小图边长 = ' + Tint.TILE_PX);
    ok(Render.tileFor(Core.neutralDesc(3), 0, 0) !== null && be.calls.length === 1,
       '同一块第二次命中缓存(不再进 backend)');
    const t4prev = Render.tileCache();            // 抛错**前**的 ④(捕获引用,好判"换没换")
    const infoPrev = Render.atlasInfo();
    throws(function () { Render.setAtlas(new Uint8ClampedArray(7), 8, 1, { backend: be }); },
           '★ setAtlas 传形状不合法的图集(7 字节不是整行 8×4) → 抛错,不静默画一片透明', '不是整行');
    // ★★ 抛错之后一个字都不许提交。注入 backend 那条路最容易写错 —— 先 tiles = 新缓存
    //   (只判"抛了没有"是拦不住它的 —— 缺陷发生时异常照样抛,只是留下了半个换图。)
    ok(Render.tileCache() === t4prev,
       '★★ 抛错之后 ④ **还是原来那一个对象**(注入 backend 也不许先把 ④ 换掉)');
    eq(Render.atlasInfo(), infoPrev, '★★ 抛错之后 atlasInfo 仍报上一张图集(换图没提交)');
    // ★ 这里包一层 try:变异(先换 ④ 再校验)下会抛,裸写会让整支冒烟当场崩掉、连一条具名 FAIL 都打不出来。
    const prevStillWorks = (function () {
      try { return Render.tileFor(Core.neutralDesc(3), 0, 0) !== null; } catch (e) { return false; }
    })();
    ok(prevStillWorks,
       '★★ 抛错之后上一张图集**照旧可用**(tileFor 照旧返回小图,而不是抛 `Tint: 还没 setSource,…`)');

    // ★★ 容量也不许为负。w 由 Tint.setSource 校验,而 h 没有任何人校验(setAtlas
    //   负数正好从那道闸下钻过去。钳到 0 就堵住了(0 = 明确的"一块都放不下")。
    Render.setAtlas(makeAtlas(), ATLAS_W, -64);
    eq(Render.atlasCapacity(), 0,
       '★★ 畸形高度(h = -64)下容量钳到 0、不是负数(负数会被 clampTexture 读成"没有信息"、静默放宽到 TEXTURE_MAX)');
    Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H);   // 还原:下面的相位还要用这张好图集
  })();
  (function () {
    let built = 0;
    // ★ 判据是"这一步有没有动模块状态",不是"模块里现在是不是 null":mount 的 setMap 会 attachCells
    //   (换图的作废链条靠它闭合,见相位 ③b),故本相位跑到这里时模块里已经有一个(前面那些 mount 装上去的)。
    const cellsBefore = Render.cellCache();
    const c3 = Render.createCellCache({
      maxCells: 4,
      build: function (L, cx, cy) { built++; return { L: L, cx: cx, cy: cy, n: built }; },
    });
    ok(Render.cellCache() === cellsBefore, 'createCellCache 本身**不**改模块状态(装上要走 attachCells)');
    Render.attachCells(c3);
    ok(Render.cellCache() === c3, 'attachCells 之后 cellCache() 就是它');
    const a1 = c3.get(Core.LAYER_SCENE, 0, 0);
    eq(built, 1, '未命中 → 建一次');
    const a2 = c3.get(Core.LAYER_SCENE, 0, 0);
    ok(a1 === a2, '同键第二次命中同一个对象');
    eq(built, 1, '命中不再重建');
    eq(c3.stats().hits, 1, 'stats: hits = 1');

    // 轴 1:内容版本号。编辑某格必须 touch 它,否则 ③ 继续交出旧内容合成的格位图。
    c3.touch(Core.LAYER_SCENE, 0, 0);
    eq(c3.version(Core.LAYER_SCENE, 0, 0), 1, 'touch → 版本 +1');
    c3.get(Core.LAYER_SCENE, 0, 0);
    eq(built, 2, '★ 内容版本变了 → 该格重建(其余格不受影响)');
    c3.get(Core.LAYER_SCENE, 0, 1);
    eq(built, 3, '没被 touch 的隔壁格是**另一个键**,本来就该建一次');

    // LRU:maxCells 4,塞第 5 格 → 最久未用的键被淘汰
    c3.clear();
    built = 0;
    [[0, 0], [1, 0], [2, 0], [3, 0]].forEach(function (k) { c3.get(Core.LAYER_SCENE, k[0], k[1]); });
    eq(built, 4, 'LRU: 4 个键都建了');
    c3.get(Core.LAYER_SCENE, 4, 0);
    eq(c3.stats().evictions, 1, 'LRU: 超出上限淘汰 1 个');
    eq(c3.stats().size, 4, 'LRU: 容量守住 maxCells');

    // ★★ 重建出来的条目也必须挪到最近端。Map.set 对已存在的键保留原来的插入位置,
    //   而这条重建路径恰恰常落在"换图后 setSource 刻意不清表"留下的陈旧条目上 —— 不先
    //   delete 的话,刚重建出来的条目仍蹲在最冷位置,下一次淘汰就把它扔掉(它才刚建过)。
    //   ★ 两面各用一个新缓存:同一个缓存里连着判两面的话,第一个 get 已经把 LRU 序改了,
    //     第二面在新旧实现下都是 miss,分不出来。两面共用同一个序列(lruSeq):
    const lruSeq = function (c) {
      c.get(Core.LAYER_SCENE, 0, 0);               // A
      c.get(Core.LAYER_SCENE, 1, 0);               // B
      c.touch(Core.LAYER_SCENE, 0, 0);             // A 内容变了 → 下一次 get(A) 走**重建**
      c.get(Core.LAYER_SCENE, 0, 0);               // ← 被修的那一处:重建后要移到最近端
      c.get(Core.LAYER_SCENE, 2, 0);               // C:maxCells = 2 → 淘汰一个
    };
    const lru1 = (function () {
      let n = 0;
      const c = Render.createCellCache({ maxCells: 2, build: function () { n++; return { n: n }; } });
      lruSeq(c);
      return { c: c, built: function () { return n; } };
    })();
    const b1 = lru1.built();
    lru1.c.get(Core.LAYER_SCENE, 0, 0);            // 刚重建的那个键
    eq(lru1.built(), b1,
       '★★ LRU: 刚**重建**出来的条目已经在最近端(got 比 exp 多 1 = 它被自己这次重建后的第一次淘汰扔掉了,正是旧实现)');
    const lru2 = (function () {
      let n = 0;
      const c = Render.createCellCache({ maxCells: 2, build: function () { n++; return { n: n }; } });
      lruSeq(c);
      return { c: c, built: function () { return n; } };
    })();
    const b2 = lru2.built();
    lru2.c.get(Core.LAYER_SCENE, 1, 0);            // 这一面里该被淘汰的是 B
    eq(lru2.built(), b2 + 1,
       '★★ LRU: 被淘汰的正是 B(它已被扔掉 → 这里必须重建一次;exp 就是那个 +1。旧实现下 B 还在 = 命中,got 差 1)');

    const st = c3.stats();
    ok(typeof st.hits === 'number' && typeof st.misses === 'number' &&
       typeof st.evictions === 'number' && typeof st.size === 'number' &&
       typeof st.maxCells === 'number' && typeof st.generation === 'number',
       'stats 的键是 {hits, misses, evictions, size, maxCells, generation}');
  })();
  (function () {
    const be = spyBackend();
    const a1 = makeAtlas(), a2 = makeAtlas();
    a2[0] = 111; a2[1] = 222;                    // 两张**不同**的图集:换图之后像素必须变
    Render.setAtlas(a1, ATLAS_W, ATLAS_H, { backend: be });   // ← 装了一个可记账的 ④
    const c3 = Render.attachCells(Render.createCellCache({
      maxCells: 8, build: function (L, cx, cy) { return { L: L, cx: cx, cy: cy, v: 1 }; },
    }));
    const t4 = Render.tileCache();
    const d3 = Core.neutralDesc(3);
    const before3 = c3.get(Core.LAYER_SCENE, 0, 0);
    const before4 = t4.get(3, 0, 0, d3);
    ok(c3.stats().size === 1 && t4.stats().size === 1, '两层各有一条条目(前置条件)');

    Render.setAtlas(a2, ATLAS_W, ATLAS_H);       // ★ 换图(**不换 backend**,要的就是同一个 ④)
    // ★★ 换图不清表 —— 陈旧条目留着,靠代际不等恒 miss 作废(见 setSource 的注释:
      //   清了表,e.gen === gen 就成了死代码(陈旧条目恒 miss 的判据也就失效了)。
    eq(c3.stats().size, 1, '★ 换图之后 ③ **不清表**(陈旧条目还在 —— 它靠代际作废,不是靠清空)');
    eq(c3.stats().generation, 1, '★ ③ 的代际 +1(setSource 追的是它)');
    eq(t4.stats().size, 0, '★★ 换图之后 ④ 被清空(Tint.setSource 自己做的)');
    const after3 = c3.get(Core.LAYER_SCENE, 0, 0);
    ok(after3 !== before3, '★★ 换图之后同一个格键**是新对象**(漏了 = A2 在上一层复发)');
    eq(c3.stats().misses, 2, '★★ 换图之后同一个格键**必须重新构建**(只判内容版本号的话这里会是命中)');
    const after4 = t4.get(3, 0, 0, d3);
    ok(after4 !== before4, '★★ 换图之后同一块小图也是新对象(调用方不得跨换图持有 tile)');
    ok(be.calls.length >= 2, '换图之后 ④ 真的重算过(实得 backend 调用 ' + be.calls.length + ' 次)');

    // ★★ 相位 ②b(承相位 ② 那条 throws 的另一半 —— 那一条只判了"抛没抛"):换图抛错时
    //    一层都不许提交。③ 要先 attachCells 才有,故这一相位落在相位 ③b 里。
    //    ★ 本相位不是"这个缺陷唯一抓得住的地方":真正承重的是两面 —— ④ 的对象
    //      身份与"旧图集还能不能画" —— 而相位 ② 那一对(tileCache() 身份 + tileFor 照旧返回小图)已经覆盖了它。
    const infoBefore = Render.atlasInfo(), genBefore = c3.stats().generation;
    const warm3 = c3.get(Core.LAYER_SCENE, 0, 0);        // 先预热,好判"③ 没被作废"
    const warm4 = t4.get(3, 0, 0, d3);
    throws(function () { Render.setAtlas(new Uint8ClampedArray(7), 8, 1, { backend: be }); },
           '★★ 换图抛错:注入 backend 时整条换图也不许提交(形状非法 → 抛)', '不是整行');
    eq(c3.stats().generation, genBefore, '★★ 抛错之后 ③ 的代际**没动**(换图事件根本没碰到 ③)');
    ok(c3.get(Core.LAYER_SCENE, 0, 0) === warm3, '★★ 抛错之后 ③ 的条目仍是原来那个对象(没被作废)');
    const stillWorks = (function () {
      try { return Render.tileFor(Core.neutralDesc(3), 0, 0) !== null; } catch (e) { return false; }
    })();
  })();
});