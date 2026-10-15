'use strict';
// tests/render/10_mount.js —— 相位 ⑩a~⑩g:mount() 首帧 / 缩略图路径 / resize 与缩放钳制 / 脏矩形。
globalThis.renderChain = globalThis.renderChain.then(async function () {
const Core = globalThis.Core;
const Render = globalThis.Render;
const savedDoc = globalThis.document;
const made = [];
globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made.push(c); return c; } };
const SLICE = { slicer: { nextFrame: function () { return Promise.resolve(); } } };
try {
    ok(typeof Render.mount === 'function', 'Render.mount 存在(画布挂载的入口,T3 的交付面)');
    if (typeof Render.mount !== 'function') return;
    eq(Render.DRAW_ORDER, [3, 2, 1, 0],
       '★★ DRAW_ORDER 从内到外:背景(3)最先画、前景(0)最后画(盖在最上面)');
    // ★ 本相位要画真的 tile,所以图集必须先就位(Tint.get 在 setSource 之前会抛;
    Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H, { backend: spyBackend() });

      // ── ⑩a 挂载与接口面 ──
      const cv0 = fakeCanvas(240, 160);
      const r0 = Render.mount(cv0, SLICE);
      const want = ['setMap', 'map', 'setLayer', 'layer', 'setView', 'view', 'setGrid', 'setSubGrid',
        'setTorus', 'setDimOthers', 'setLayerVisible', 'layerVisible', 'setLayerLocked', 'layerLocked',
        'setSelection', 'selection', 'render', 'resize', 'fit', 'invalidateCells', 'invalidateAll',
        'thumbCanvas', 'screenToSub', 'subToScreen', 'stats'];
      const missing = want.filter(function (k) { return typeof r0[k] !== 'function'; });
      ok(missing.length === 0, '★ mount() 的接口面齐全(Task 4/5/7 照它写)' +
         (missing.length ? ':缺 ' + missing.join(', ') : ''));
      ok(cv0.ctx.imageSmoothingEnabled === false,
         '★ 主 ctx 关了插值(A5:不关,砖块放大后是糊的)');
      r0.render();
      ok(r0.map() === null && r0.stats().renders === 0, '★ 没 setMap 时 render() 是空操作(不抛、不画、不计数)');

      // ── ⑩b 首次 setMap:缩略图路径(< 8px/子格)──
      const m1 = Core.createMap('m1', 4, 3);            // 16×12 子格
      setCells(m1, Core.LAYER_SCENE, [[0, 0], [5, 5], [14, 1], [15, 2]],
               function () { return Core.neutralDesc(1); });
      fillSub(m1, Core.LAYER_BG, 0);
      const cv1 = fakeCanvas(200, 150);
      const r1 = Render.mount(cv1, SLICE);
      await r1.setMap(m1);
      ok(r1.map() === m1, 'setMap 之后 map() 拿到同一张图');
      eq(r1.layer(), Core.LAYER_SCENE, '默认图层 = 场景(与页面 .layer-row.cur 那一行一致)');
      eq(r1.stats().thumbsBuilt, 1, 'setMap **只**建一次缩略图(① 每层一张)');
      ok(r1.stats().renders >= 1, '★ setMap 末尾自己渲染首帧(不是等别人来调 render)');
      const tp = Render.thumbScale(m1.subCols, m1.subRows);
      eq(r1.thumbCanvas(Core.LAYER_SCENE).width, m1.subCols * tp,
         '★ 缩略图宽度 = 子格数 × 刻度(单位是**缩略图像素**,不是子格数、也不是屏幕像素)');
      cv1.ctx.ops.length = 0;
      // ★ setView 返回的那个 promise 一律 await:一次意外拒绝会变成未处理的拒绝,把进程直接打死(连具名 FAIL 都打不出来)。
      await r1.setView({ x: 0, y: 0, zoom: 4 });
      eq(countOps(cv1.ctx, 'op', 'drawImage'), 16,
         '★ < 8px/子格 走缩略图路径:每层**一次** drawImage 顶掉整层(4 层 × 4 份可见副本 = 16,' +
         '不是逐子格 —— 逐子格会是几百次)');

      // ── ⑩c resize / 缩放钳制 / fit ──
      const cvR = fakeCanvas(50, 40);
      const rR = Render.mount(cvR, SLICE);
      const wrap = fakeCanvas(320, 240);
      wrap.clientWidth = 320; wrap.clientHeight = 240;
      cvR.parentElement = wrap;
      cvR.ctx.imageSmoothingEnabled = true;             // 模拟浏览器在改尺寸时把 ctx 状态重置掉
      rR.resize();
      eq({ w: cvR.width, h: cvR.height }, { w: 320, h: 240 },
         'resize() 按父容器的 clientWidth/Height 定画布像素尺寸(不是 CSS 尺寸)');
      ok(cvR.ctx.imageSmoothingEnabled === false,
         '★★ 改尺寸会重置 ctx 状态 ⇒ resize 里必须**重设** imageSmoothingEnabled(漏了 = 放大后糊)');
      await rR.setView({ x: 0, y: 0, zoom: 9999 });   // 还没 setMap ⇒ 同步返回,await 无害
      eq(rR.view().zoom, Render.MAX_ZOOM, '★ setView 的缩放被钳到 MAX_ZOOM(用户输入钳制,不报错)');
      await rR.setView({ x: 0, y: 0, zoom: -5 });
      eq(rR.view().zoom, Render.MIN_ZOOM, '★ 负缩放的钳到 MIN_ZOOM');
      await rR.setView({ x: 0, y: 0, zoom: NaN });
      eq(rR.view().zoom, Render.MIN_ZOOM, '★ NaN 缩放也钳到 MIN_ZOOM(NaN 不报错地毁掉整张画布)');
      await rR.setMap(m1);
      // ★★ 下面两条一定返回分帧重建的 promise(有图 + zoom ≥ 8)—— 漏 await 的话一次
      await rR.setView({ x: 99, y: 99, zoom: 32 });
      await rR.fit();
      ok(rR.view().x < 0 && rR.view().y < 0 && rR.view().x > -4 && rR.view().y > -4,
         'fit() 把地图居中(视图原点落在 −2/−1.5 这种小负数上:CSS 的 0 点不是左上角)');

      // ── ⑩d ≥ 8px/子格:视口离屏层路径(②)+ 环面副本 ──
      // ★★ 视图一变,② 的四张离屏层整片失效 ⇒ setView 是分帧重建(闸 2),要 await。
      //    重建之后的合成次数 = 层数 × 副本数(不再与"有内容的格数"有关 —— 主画布
      //    上画的是那张离屏层,一层的副本数就是环面铺了几份)。
      cv1.ctx.ops.length = 0;
      await r1.setView({ x: 0, y: 0, zoom: 16 });
      ok(countOps(cv1.ctx, 'op', 'drawImage') > 0,
         '★ ≥ 8px/子格 换视口离屏层路径(主画布上合成的是 ② 的离屏层,不是逐子格的小图)');
      // 网格线:格线恒画,子格线只在 zoom ≥ 4 且开了子格时画(C15)
      // ★ 判据用 moveTo(线段起点)而不是 stroke(整条路径一次):两组线各 beginPath+stroke,故 stroke 恒为 2,拿它分不出子格线开没开。
      const coarseMoves = countOps(cv1.ctx, 'op', 'moveTo');
      ok(coarseMoves > 0, '格线按**可见区**画出来(moveTo ' + coarseMoves + ' 条线段;B8:不裁剪 = 每次重画整张图)');
      cv1.ctx.ops.length = 0;
      r1.setSubGrid(true);
      const subMoves = countOps(cv1.ctx, 'op', 'moveTo');
      ok(subMoves > coarseMoves,
         '★★ setSubGrid(true) 多画一层子格线(' + subMoves + ' > ' + coarseMoves +
         '):格线 64px、子格线 16px,后者密 4 倍');
      r1.setSubGrid(false);
      // ★★ 副本必须逐层铺出去:视口左边缘越过接缝时,离屏层那一份要被平移 −subCols×zoom
      //    再画一次(合成次数 = 层数 × 副本数)。★ 离屏层本身读格时就环面折算,所以
      //    副本不会画错内容(偏移是 subCols 的整数倍 ⇒ 折算前后是同一格)。
      cv1.ctx.ops.length = 0;
      await r1.setView({ x: -3, y: 0, zoom: 16 });
      const acrossSeam = countOps(cv1.ctx, 'op', 'drawImage');
      cv1.ctx.ops.length = 0;
      r1.setTorus(false);
      const noTorus = countOps(cv1.ctx, 'op', 'drawImage');
      r1.setTorus(true);
      eq([acrossSeam, noTorus], [8, 4],
         '★★ 环面开关决定"每层被**合成几次**":跨接缝 2 份副本 × 4 层 = 8 次 drawImage,' +
         '关掉环面 1 份 × 4 层 = 4 次(实得 ' + acrossSeam + ' / ' + noTorus + ')。' +
         '★ 本断言**只**数次数 —— 这个视图下 ±subCols 那几份副本必然整个落在画布外,' +
         '所以它**不是**"接缝另一侧的内容被画出来了"的判据(那一条看 ⑪e:像素画到 x ≥ 96)');
      const hs = r1.screenToSub(0, 0);
      ok(hs.X >= 0 && hs.X < m1.subCols && hs.Y >= 0 && hs.Y < m1.subRows,
         '★ screenToSub 在副本上也折回 [0, subCols)(A4:副本上能落笔)');

      // ── ⑩e 两条方向的坐标换算互为逆 ──
      await r1.setView({ x: 3, y: 2, zoom: 16 });
      const s2 = r1.subToScreen(5, 6);
      eq(s2, { x: (5 - 3) * 16, y: (6 - 2) * 16 }, 'subToScreen: 世界 → 屏幕(相对视图原点)');
      eq(r1.screenToSub(s2.x + 1, s2.y + 1), { X: 5, Y: 6 },
         '★★ screenToSub(subToScreen(X,Y)) 回到 (X,Y):两条方向互为逆(错一个整支画笔偏到别处)');
      ok(r1.screenToSub(-1000, -1000).X >= 0, '★ 负的屏幕坐标也折回 [0, subCols)(环面世界里这是常态)');

      // ── ⑩f 层可见性 / 压暗 / 选区框 ──
      // ★★ 判据从"drawImage 总次数为 0"改成"少了几次":② 之后主画布上画的是四张离屏层
      //    (每层各几份副本),藏掉一层只会让它那几份消失,其余三层照画(总次数 4 → 3)。
      //    "次数变成 0"是逐子格那条旧路径的说法。
      cv1.ctx.ops.length = 0;
      r1.setLayerVisible(Core.LAYER_SCENE, false);
      const hidden = countOps(cv1.ctx, 'op', 'drawImage');
      cv1.ctx.ops.length = 0;
      r1.setLayerVisible(Core.LAYER_SCENE, true);
      const shown = countOps(cv1.ctx, 'op', 'drawImage');
      ok(hidden === shown - 1 && hidden > 0,
         '★ 隐藏场景层之后 drawImage 正好少 1 次(实得 隐藏 ' + hidden + ' 次 / 显示 ' + shown +
         ' 次;其余 ' + hidden + ' 次照画)。★ 次数**只**说明"合成的份数少了一份"——' +
         '"那一层有没有离屏层"它分不出来(`!s.layerVisible[L]` 与 `!layerCv[L]` 共用同一个 continue);' +
         '真守卫在 ⑪a(按**对象身份**判主画布合成的就是那一层的离屏层)');
      ok(r1.layerVisible(Core.LAYER_SCENE) === true, 'layerVisible 读回 true');
      r1.setLayerLocked(Core.LAYER_FRONT, true);
      ok(r1.layerLocked(Core.LAYER_FRONT) === true && r1.layerLocked(Core.LAYER_SCENE) === false,
         'setLayerLocked/layerLocked 往返(锁定不重画 —— 它只挡绘制工具的写入)');
      r1.setLayer(Core.LAYER_FRONT);                    // 当前层换成前景 ⇒ 场景层成了"非当前层"
      ok(someOp(cv1.ctx, function (o) { return o.op === 'drawImage' && o.alpha === 0.4; }),
         '★★ 非当前层压暗 60%(globalAlpha 0.4)');
      cv1.ctx.ops.length = 0;
      r1.setDimOthers(false);
      // ★★ 判据取"**一条 0.4 都没有**",不是"存在一条 1":后者被 `LAYER_BG` 的压暗豁免恒真喂饱
      //    —— 把 `setDimOthers` 整个掐掉都照样绿(实测)。另要求这一趟真画过东西,免得空转也算过。
      ok(countOps(cv1.ctx, 'op', 'drawImage') > 0 &&
         !someOp(cv1.ctx, function (o) { return o.op === 'drawImage' && o.alpha === 0.4; }),
         'setDimOthers(false) 之后不再压暗(非当前层也不许出现 0.4;LAYER_BG 的豁免不算证据)');
      r1.setDimOthers(true);
      r1.setLayer(Core.LAYER_SCENE);
      cv1.ctx.ops.length = 0;
      r1.setSelection({ x: 2, y: 2, w: 4, h: 4 });
      eq(countOps(cv1.ctx, 'op', 'strokeRect'), 1, 'setSelection 立刻重画并画出选区框(1 个 strokeRect)');
      eq(r1.selection(), { x: 2, y: 2, w: 4, h: 4 }, 'selection() 读回选区');
      ok(r1.setSelection(null) === undefined && r1.selection() === null,
         '★ setSelection(null) 清掉选区(并重画 —— 旧框不许留在屏幕上)');

      // ── ⑩g 脏矩形:编辑几格之后只重画那几格的缩略图 ──
      eq(r1.invalidateCells(Core.LAYER_SCENE, [{ cx: 0, cy: 0 }, { cx: 3, cy: 2 }]),
         { x: 0, y: 0, w: 16, h: 12 },
         '★★ invalidateCells:格坐标 → 子格并集矩形(格 × ' + Core.SUB_PER_CELL + ',两个格并成一个矩形)');
      eq(r1.invalidateCells(Core.LAYER_SCENE, []), null, '★ invalidateCells: 空清单 → null(不做任何事)');
} finally {
  globalThis.document = savedDoc;
}
});