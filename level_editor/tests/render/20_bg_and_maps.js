'use strict';
// tests/render/20_bg_and_maps.js —— 相位 ⑩h~⑩k:背景层是 RGBA / 换图的缺席层与尺寸判定 / 出生点标记。
globalThis.renderChain = globalThis.renderChain.then(async function () {
const Core = globalThis.Core;
const Render = globalThis.Render;
const savedDoc = globalThis.document;
const made = [];
globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made.push(c); return c; } };
const SLICE = { slicer: { nextFrame: function () { return Promise.resolve(); } } };
try {
      // ── ⑩h ★★ 背景层是 RGBA,不是描述符(F1:两种颜色、两种不同的静默失败)──
      // 不透明红 #FF0000FF 的纹理位域恰好是 0(#FF0000FF >>> 12 & 0xFFF = 0)⇒ 拿它当
      // 空气判 = 整层看不见;不透明青 #00FFFFFF(页面背景色输入框的默认值)的纹理位域是
      // 4095 = "图集里没有的那块砖" ⇒ 漏掉"先判层再判纹理"的地方会当场抛 Tint 越界错。
      const bgMap = Core.createMap('bg', 2, 2);          // 8×8 子格
      fillSub(bgMap, Core.LAYER_SCENE, 0);               // 纹理层全空气 ⇒ texOf 一次都不该被调到
      fillSub(bgMap, Core.LAYER_BG, 0);
      bgMap.layers[Core.LAYER_BG].rgba[0] = 0xff0000ff;  // (0,0) 不透明红
      bgMap.layers[Core.LAYER_BG].rgba[1] = 0x00ffffff;  // (1,0) 不透明青
      bgMap.layers[Core.LAYER_BG].rgba[2] = 0xff000000;  // (2,0) 全透明(alpha 0)= 这一格没颜色
      const cvBg = fakeCanvas(200, 200);
      const rBg = Render.mount(cvBg, SLICE);
      const madeBeforeBg = made.length;
      await rBg.setMap(bgMap);
      const thumbBg = rBg.thumbCanvas(Core.LAYER_BG);
      // ★★ ② 之后主画布上画的是离屏层那张画布,颜色层的 fillRect 落在离屏层自己的
      //    ctx 上 —— 所以这几条判据要看离屏层(按对象身份取:尺寸等于主画布的
      //    四张就是它,创建顺序 = 层号递增),同时另判"那张离屏层确实被合成到主画布上"。
      const bgLayerCvs = layerCanvasesSince(made, madeBeforeBg, 200, 200);
      const bgOff = bgLayerCvs[Core.LAYER_BG];
      ok(bgLayerCvs.length === Core.LAYER_COUNT && !!bgOff,
         '⑩h 前提:② 的离屏层按层各建了一张(实得 ' + bgLayerCvs.length + ' 张,尺寸 = 主画布)');
      const origTexOf = Core.texOf;
      const texOfArgs = [];
      Core.texOf = function (d) { texOfArgs.push(d >>> 0); return origTexOf(d); };
      let bgThrew = null;
      try {
        cvBg.ctx.ops.length = 0;
        await rBg.setView({ x: 0, y: 0, zoom: 16 });      // ≥ 8 ⇒ ② 的离屏层路径(另一条是缩略图)
        await rBg.invalidateAll();                       // 顺手把 ① 缩略图整片重画(两条路径都过一遍)
      } catch (e) { bgThrew = e; } finally { Core.texOf = origTexOf; }
      ok(bgThrew === null, '★★ 不透明青背景(#00FFFFFF,纹理位域 = 4095)渲染不抛异常(' +
         (bgThrew ? String(bgThrew.message) : '无异常') + ')');
      eq(texOfArgs.length, 0,
         '★★ 背景层的 RGBA 一个都没进 Core.texOf(实得 ' + texOfArgs.length + ' 次):' +
         'RGBA 与描述符长得一样、含义完全不同,按层种类分派才是唯一正确的读法');
      ok(countOps(bgOff.ctx, 'style', 'rgba(255,0,0,1)') > 0,
         '★★ 不透明红背景**画出来了**(② 的离屏层里有 fillRect rgba(255,0,0,1))—— 它的纹理' +
         '位域是 0,按"空气"判会整层不可见(静默)');
      ok(countOps(bgOff.ctx, 'style', 'rgba(0,255,255,1)') > 0,
         '★★ 不透明青背景也画出来了(rgba(0,255,255,1) = cssOfRGBA 的 0xRRGGBBAA 次序)');
      ok(someOp(cvBg.ctx, function (o) { return o.op === 'drawImage' && o.img === bgOff; }),
         '★★ 主画布上合成的正是**那一张**颜色层离屏层(颜色像素只落在 ② 里,靠合成才上屏)');
      ok(!someOp(bgOff.ctx, function (o) { return o.style === 'rgba(255,0,0,0)'; }),
         '★ alpha = 0 的格**不画**全透明色块(画了 = 把下面的像素改成"什么都没画",而离屏层上' +
         '那意味着留着上一帧的内容)');
      // ★ 缩略图路径与逐格路径处置不同,且都对:缩略图是长期存在的位图(有旧像素要清),
      //   逐格路径的底色由 render() 开头的整屏 fillRect 负责(那里没有旧像素)。
      ok(someOp(thumbBg.ctx, function (o) {
           return o.op === 'clearRect' && o.x === 2 * rBg.thumbPx() && o.y === 0 &&
                  o.w === rBg.thumbPx() && o.h === rBg.thumbPx();
         }),
         '★★ 缩略图里 alpha = 0 的格被**清掉**(那一格有上一帧的像素,不清就留着)');
      ok(someOp(thumbBg.ctx, function (o) { return o.op === 'fillRect' && o.style === 'rgba(255,0,0,1)'; }),
         '★★ **缩略图**路径同样把红色背景画进 ① 的缩略图(两条绘制路径都得按层种类分派,' +
         '只修一条另一条照样是看不见的)');
      cvBg.ctx.ops.length = 0;
      rBg.setGrid(false);
      eq(countOps(cvBg.ctx, 'op', 'stroke'), 0,
         '★ setGrid(false) 之后一个 stroke 都不画(网格是两遍全屏描线里的一遍)');
      rBg.setGrid(true);

      // ── ⑩i 换到一张"缺层"的图:那一层的旧缩略图必须清掉 ──
      // ★ 缺席层不进 thumbTasks(省一次全图扫描),于是它不会被重画 —— 尺寸相同时
      //   ensureThumbs 走复用那条路,旧像素就留在那儿了(症状:换图后那一层继续显示上一张图)。
      const noBg = Core.createMap('nobg', 2, 2);         // 同尺寸 ⇒ 复用缩略图
      noBg.layers[Core.LAYER_BG] = null;                 // 缺席层 = 全空气(规格 §2.4)
      thumbBg.ctx.ops.length = 0;
      await rBg.setMap(noBg);
      ok(someOp(thumbBg.ctx, function (o) {
           return o.op === 'clearRect' && o.w === thumbBg.width && o.h === thumbBg.height;
         }),
         '★★ 换到缺背景层的图之后,那一张旧缩略图被整片清掉(否则它继续显示上一张图的内容,' +
         '而缩略图路径会把它当"这一层的画面"贴上去)');

      // ── ⑩j 出生点 / 敌人标记 ──
      const mSp = Core.createMap('sp', 2, 2);
      fillSub(mSp, Core.LAYER_BG, 0);
      mSp.players.push({ x: 0, y: 0 });
      mSp.players.push({ x: 1, y: 1 });
      mSp.enemies.push({ x: 1, y: 0 });
      const cvSp = fakeCanvas(200, 200);
      const rSp = Render.mount(cvSp, SLICE);
      await rSp.setMap(mSp);
      rSp.setTorus(false);                              // 只留 [0,0] 那一份副本 ⇒ 每个标记一次
      // ★ zoom ≥ 8 + 有图 ⇒ setView 返回分帧重建的 promise,必须 await:漏了的话下面的记账就建在"重建还没落地"的半旧状态上,而拒绝还会静默打死进程。
      await rSp.setView({ x: 0, y: 0, zoom: 16 });
      cvSp.ctx.ops.length = 0;                          // ★ 清在**视图定好之后**(set* 自己会渲染)
      rSp.render();
      const labels = cvSp.ctx.ops.filter(function (o) { return o.op === 'fillText'; })
        .map(function (o) { return o.t; });
      eq(labels.slice().sort().join(','), 'E,P1,P2',
         '★★ 出生点/敌人标记:3 个标记 = 3 次 fillText(不是整图遍历,只画有标记的格;' +
         'P 的编号与 players 的顺序一致)');
      cvSp.ctx.ops.length = 0;
      rSp.setTorus(true);
      ok(cvSp.ctx.ops.filter(function (o) { return o.op === 'fillText'; }).length > 3,
         '★ 环面开着时同一批标记会随副本各画一遍(> 3 次)');

      // ── ⑩k ★★ 换到一张"同宽更高"的图:缩略图必须按高度判、整张重建 ──
      // ★★ ⑩i 用的是同尺寸换图(那张图改的只是"缺层"),走的正是复用那条路 ⇒ 它
      //    天然抓不到"复用条件漏判高度"。这里的两张图同宽、不同高:
      //    thumbScale 只看总字节数,所以两者拿到同一个刻度(前提断言把这一点钉住,
      //    否则"复用"这条路根本不走,本相位就是空转);于是只判宽度的实现在第二张图上
      const shortM = Core.createMap('sh', 4, 3);        // 16×12 子格 ⇒ 缩略图 32×24
      fillSub(shortM, Core.LAYER_SCENE, Core.neutralDesc(1));
      fillSub(shortM, Core.LAYER_BG, 0);
      const tallM = Core.createMap('ta', 4, 5);         // 16×20 子格 ⇒ 缩略图 32×40(同宽、更高)
      fillSub(tallM, Core.LAYER_SCENE, Core.neutralDesc(1));
      fillSub(tallM, Core.LAYER_BG, 0);
      eq(Render.thumbScale(shortM.subCols, shortM.subRows),
         Render.thumbScale(tallM.subCols, tallM.subRows),
         '⑩k 前提:这两张图的缩略图刻度**相同**(否则复用的那条路根本不走,本相位是空转)');
      const cvH = fakeCanvas(200, 200);
      const rH = Render.mount(cvH, SLICE);
      await rH.setMap(shortM);
      const thumbH1 = rH.thumbCanvas(Core.LAYER_SCENE);
      eq({ w: thumbH1.width, h: thumbH1.height },
         { w: shortM.subCols * rH.thumbPx(), h: shortM.subRows * rH.thumbPx() },
         '⑩k 前提:第一张图的缩略图尺寸 = 子格数 × 刻度(32×24)');
      await rH.setMap(tallM);
      const thumbH2 = rH.thumbCanvas(Core.LAYER_SCENE);
      ok(thumbH2 !== thumbH1,
         '★★ 换到**同宽更高**的图必须换一张缩略图画布(只判宽度的实现会在这里复用那张' +
         '矮画布,而它随后会被整张缩进更高的目标框里 ⇒ 画面纵向拉伸/截断)');
      eq({ w: thumbH2.width, h: thumbH2.height },
         { w: tallM.subCols * rH.thumbPx(), h: tallM.subRows * rH.thumbPx() },
         '★★ 缩略图的**高度**跟着新图走(期望 ' + (tallM.subRows * rH.thumbPx()) +
         'px;漏判高度的话这里还是上一张图的 ' + (shortM.subRows * rH.thumbPx()) + 'px)');
      ok(thumbH2.width > 0 && thumbH2.height > 0 &&
         countOps(thumbH2.ctx, 'op', 'drawImage') > 0,
         '★ 新缩略图确实被**画过**(钉住"建一张空白画布交差"这种假绿:' +
         countOps(thumbH2.ctx, 'op', 'drawImage') + ' 次 drawImage)');
} finally {
  globalThis.document = savedDoc;
}
});