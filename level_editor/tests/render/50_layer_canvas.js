'use strict';
// tests/render/50_layer_canvas.js —— 相位 ⑪:② 的离屏层(三条路径 / 脏区 / 平移 / 环面 / 闸 2 / 代际守卫)。
globalThis.renderChain = globalThis.renderChain.then(async function () {
const Core = globalThis.Core;
const Render = globalThis.Render;
    const savedDoc = globalThis.document;
    const made2 = [];
    globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made2.push(c); return c; } };
    const SLICE = { slicer: { nextFrame: function () { return Promise.resolve(); } } };
    try {
      // 4×3 格(16×12 子格)的小图:内容在 (0,0)/(1,1)/(3,2) 三格 —— (0,0) 是给 ⑪e 的
      // 跨接缝那条用的(它折算后落在屏幕右侧那半张上)。
      const mM = Core.createMap('t4', 4, 3);
      fillSub(mM, Core.LAYER_BG, 0);
      fillSub(mM, Core.LAYER_SCENE, 0);
      setCells(mM, Core.LAYER_SCENE, [[0, 0], [1, 1], [3, 2]],
               function () { return Core.neutralDesc(1); });
      const cv = fakeCanvas(200, 150);
      const since = made2.length;
      const r = Render.mount(cv, SLICE);
      await r.setMap(mM);
      const offs = layerCanvasesSince(made2, since, 200, 150);
      ok(offs.length === Core.LAYER_COUNT && !!offs[Core.LAYER_SCENE],
         '⑪ 前提:② 为四层各建了一张离屏层(尺寸 = 主画布;实得 ' + offs.length + ' 张)');
      const offScene = offs[Core.LAYER_SCENE];

      // ── ⑪a 三条路径各画各的:缩略图(< 8)与离屏层(≥ 8)是两套完全不同的实现 ──
      cv.ctx.ops.length = 0;                                // ★ 清在 set* 之前(set* 自己会渲染)
      await r.setView({ x: 0, y: 0, zoom: 4 });
      ok(drawnImages(cv.ctx).indexOf(r.thumbCanvas(Core.LAYER_SCENE)) >= 0 &&
         drawnImages(cv.ctx).indexOf(offScene) < 0,
         '★ < 8px/子格 合成的是 ① 的缩略图(② 的离屏层一次都没上场)');
      cv.ctx.ops.length = 0;
      await r.setView({ x: 0, y: 0, zoom: 16 });
      ok(drawnImages(cv.ctx).indexOf(offScene) >= 0 &&
         drawnImages(cv.ctx).indexOf(r.thumbCanvas(Core.LAYER_SCENE)) < 0,
         '★★ ≥ 8px/子格 合成的是 ② 的离屏层(缩略图不上场)—— 同一个 render() 入口,两条路径互斥');

      // ── ⑪b 编辑一格:只重画那一层的一块(不是整层、不是四层)──
      const rb0 = r.stats().layerRebuilds;
      const miss0 = r.stats().cellsMisses;
      r.editCells(Core.LAYER_SCENE, [{ cx: 1, cy: 1 }]);
      eq(r.stats().layerRebuilds - rb0, 1,
         '★★ 编辑一格 → 只重画**那一层**的一块脏区(实得 ' + (r.stats().layerRebuilds - rb0) +
         ' 次;整片重建会是 ' + Core.LAYER_COUNT + ' 次 —— 这正是 ② 存在的理由)');
      eq(r.cells().version(Core.LAYER_SCENE, 1, 1), 1,
         '★ editCells 走了 ③ 的 touch(被编辑那一格的内容版本号 +1)');
      eq(r.cells().version(Core.LAYER_SCENE, 3, 2), 0,
         '★ 没被编辑的格**不**动版本号(动了 = 整层都白重建)');
      ok(r.stats().cellsMisses > miss0,
         '★ 被 touch 的那一格在重画时是**未命中**(③ 真的重新算过它,不是继续交旧 tile)');

      // ── ⑪b2 ★★ ③ 的键必须折算到主网格:同一格只有一条条目 ──
      // 视图越过左接缝时,离屏层读到的是 cx = −1 这样的负格号(折算后才是 3。视口
      // x ∈ [−3, 9.5) ⇒ 格 −1,0,1,2 —— 格 3 只会以 −1 这个写法被读到)。
      // 键不折算的话同一格会缓存两条,而编辑只 touch 得掉其中一条 ⇒ 接缝另一侧的副本
      r.cells().clear();
      await r.setView({ x: -3, y: 0, zoom: 16 });
      const mSeam = r.cells().stats().misses;      // ★ 读 ③ 自己的计数器(stat2 只在 render 里同步)
      r.cells().get(Core.LAYER_SCENE, 3, 0);
      eq(r.cells().stats().misses - mSeam, 0,
         '★★ 同一格在环面下只有**一条**缓存条目(未命中 ' + (r.cells().stats().misses - mSeam) +
         ' 次 ⇒ 键没折算:同一格两条,编辑只作废得掉一条)');

      // ── ⑪c 颜色层:在 ≥8 这条路上也走颜色分支(全屏重建 + 脏区重画两条都过)──
      const cMap = Core.createMap('c4', 2, 2);
      fillSub(cMap, Core.LAYER_SCENE, 0);
      fillSub(cMap, Core.LAYER_BG, 0);
      cMap.layers[Core.LAYER_BG].rgba[0] = 0xff0000ff;   // 不透明红(纹理位域 = 0)
      cMap.layers[Core.LAYER_BG].rgba[1] = 0x00ffffff;   // 不透明青(纹理位域 = 4095)
      const cvC = fakeCanvas(200, 200);
      const sinceC = made2.length;
      const rC = Render.mount(cvC, SLICE);
      await rC.setMap(cMap);
      const offC = layerCanvasesSince(made2, sinceC, 200, 200)[Core.LAYER_BG];
      ok(!!offC, '⑪c 前提:颜色层的离屏层建出来了(尺寸 = 主画布)');
      const cyanRects = function () {
        return countOps(offC.ctx, 'style', 'rgba(0,255,255,1)');
      };
      const origTexOf2 = Core.texOf;
      const texOfArgs2 = [];
      Core.texOf = function (d) { texOfArgs2.push(d >>> 0); return origTexOf2(d); };
      let threw2 = null;
      let cyanBefore = -1;
      try {
        await rC.setView({ x: 0, y: 0, zoom: 16 });         // ★ 全屏重建那条路
        cyanBefore = cyanRects();
        // ★ 编辑格 (0,0):青色在子格 (1,0),它属于格 (0,0)(rgba 数组按子格下标,
        //   4 个子格 = 1 格)。编辑格 (1,0) 是碰不到它的。
        rC.editCells(Core.LAYER_BG, [{ cx: 0, cy: 0 }]);     // ★ 脏区重画那条路
      } catch (e) { threw2 = e; } finally { Core.texOf = origTexOf2; }
      ok(threw2 === null, '★★ 颜色层在 ≥8 这条路上不抛异常(' +
         (threw2 ? String(threw2.message) : '无异常') + ')');
      eq(texOfArgs2.length, 0,
         '★★ 颜色层在 ≥8 这条路上也没把 RGBA 喂进 Core.texOf(实得 ' + texOfArgs2.length +
         ' 次)—— RGBA 的纹理位域要么是 0(整层当空气 ⇒ 看不见)、要么是 4095(当场抛)');
      ok(cyanRects() > cyanBefore,
         '★★ 颜色层的**脏区重画**同样走颜色分支(编辑之后那块又画了一遍 rgba(0,255,255,1))');
      ok(!someOp(offC.ctx, function (o) { return o.style === 'rgba(255,0,0,0)'; }),
         '★ alpha = 0 的子格不画全透明色块(它已经有底色,画了就是把内容抹掉)');

      // ── ⑪d 平移:canvas 自拷贝搬移 + 只补新露出的边条 ──
      const pc0 = r.stats().panCopies;
      const clears0 = countOps(offScene.ctx, 'op', 'clearRect');
      await r.panBy(16, 0);                                 // 视图往右看 16px
      eq(r.stats().panCopies, pc0 + 1, '★ 平移走的是自拷贝搬移那条路(panCopies +1)');
      ok(someOp(offScene.ctx, function (o) {
           return o.op === 'drawImage' && o.comp === 'copy' && o.x === -16 && o.y === 0;
         }),
         '★★ 自拷贝的偏移是 **−dxPx**(视图往右 = 画面往左):写成 +16 的话画面会以两倍速度反向跑,而边条又补在右边');
      eq(countOps(offScene.ctx, 'op', 'clearRect') - clears0, 1,
         '★★ 搬移之后只补**一条**边条(1 次 clearRect,不是整屏重画 —— 那条路是 O(全屏))');
      const stripClear = offScene.ctx.ops.filter(function (o) {
        return o.op === 'clearRect' && o.x === 184 && o.w === 16 && o.h === 150;
      });
      ok(stripClear.length === 1,
         '★★ 补的正是**新露出来的右边**那 16px(clearRect 184,0,16,150;世界矩形 = 新视图的右边缘)');

      // ── ⑪d2 ★★ 视图没重建完时不做自拷贝搬移(搬移的前提是整张图属于同一次视图)──
      const pPending = r.setView({ x: 40, y: 40, zoom: 16 });   // 不 await:重建在飞
      const pc1 = r.stats().panCopies;
      await r.panBy(16, 0);
      eq(r.stats().panCopies, pc1,
         '★★ 离屏层还没跟当前视图对齐时,平移**不做**自拷贝搬移(否则搬的是一张半旧的图,而脏标记已清 ⇒ 永久错位)');
      await pPending;
      await r.panBy(16, 0);
      eq(r.stats().panCopies, pc1 + 1,
         '★ 对齐之后平移才走搬移那条路(上一条不是"把搬移整条删掉"也能过的空断言)');

      // ── ⑪h ★★ 直接调 buildLayers()(不经 viewChanged)时,平移同样不许自拷贝 ──
      // ⑪d2 钉的是"不干净就不搬移"这条后果;这一条钉"谁把 layersClean 放下的"。
      // 完全可能不先走 viewChanged() 就进来 —— 那一刻重建已经在飞、离屏层是半旧的,
      // 而 layersClean 若还是 true,panBy 就会拿一张半旧的图自拷贝搬移,脏标记此刻已经清干净
      const pc2 = r.stats().panCopies;
      const pRebuild = r.buildLayers();               // 不 await:重建在飞,且**没**走 viewChanged
      await r.panBy(16, 0);
      eq(r.stats().panCopies, pc2,
         '★★ 重建在飞(直接调 buildLayers、没走 viewChanged)时平移**不做**自拷贝搬移' +
         '(实得 ' + pc2 + ' → ' + r.stats().panCopies + ';入口没放下 layersClean 的话这里会 +1)');
      await pRebuild;

      // ── ⑪i ★★ 平移的位移先量化到整像素(view / 边条 / 自拷贝三者同源)──
      // 自拷贝是 drawImage,而插值关掉之后光栅器会把偏移吸附到整像素;s.view 若按精确值
      // 前进 ⇒ 每次平移最多差 0.5px、而且会累积(边条只补"新露出来的那一条",永远不去纠正
      // 已经攒下的偏差)= 内容慢慢从网格/覆盖层上漂走(不报错、只看着不对)。⇒ 位移在入口一次量化。
      const v0i = r.view();
      const opsBefore = offScene.ctx.ops.length;
      await r.panBy(16.4, 0);
      const opsPan = offScene.ctx.ops.slice(opsBefore);   // ★ 只看这次平移新记下的那几笔
      ok(opsPan.some(function (o) {
           return o.op === 'drawImage' && o.comp === 'copy' && o.x === -16 && o.y === 0;
         }),
         '★★ 自拷贝的偏移是**整像素**的 −16(不是 −16.4)—— 光栅器不会替我们吸附,' +
         '让它吸附一次就攒一次偏差');
      eq(r.view().x - v0i.x, 16 / v0i.zoom,
         '★★ view 前进的也是**量化后**的 16px(不是 16.4/zoom):与自拷贝**同源**,偏差不再累积');
      ok(opsPan.some(function (o) { return o.op === 'clearRect' && o.x === 184 && o.w === 16; }),
         '★★ 补的边条也是量化后的 16px 宽(clearRect 184,0,16,150)—— 三条链同源,' +
         '搬移与补画才不会错开');
      const v0drop = r.view();
      await r.panBy(0.4, 0);
      eq([r.view().x, r.view().y], [v0drop.x, v0drop.y],
         '★ 不足 1px 的平移被**丢弃**(0.4px 走十次 = 一步都不动)。这是量化刻意付的代价,' +
         '与闸 1 同口径(钳制,不报错、不回滚):"不动"好过"越拖越歪"');

      // ── ⑪e 环面:视图越过右边界时,接缝另一侧的内容照样画进离屏层(不是黑的)──
      const cvE = fakeCanvas(200, 150);
      const sinceE = made2.length;
      const rE = Render.mount(cvE, SLICE);
      await rE.setMap(mM);
      const offE = layerCanvasesSince(made2, sinceE, 200, 150)[Core.LAYER_SCENE];
      offE.ctx.ops.length = 0;
      await rE.setView({ x: 10, y: 0, zoom: 16 });          // 可见 [10, 22.5):主网格只到 16
      const xs = offE.ctx.ops.filter(function (o) { return o.op === 'drawImage'; })
        .map(function (o) { return o.x; });
      const maxX = xs.length ? Math.max.apply(null, xs) : -1;
      ok(maxX >= 96,
         '★★ 视图越过右边界(主网格右缘落在屏幕 x = 96)时,离屏层被画到 x = ' + maxX +
         ':接缝另一侧的格由**环面折算**补上(按主网格裁剪 = 右边一大条黑 —— 人眼清单第 4 条)');

      // ── ⑪f 闸 2:全屏重建经分帧器(不是一帧画完)──
      // ★★ 判据取一次纯 buildLayers() 前后的让出次数:setMap 里那条 rebuild 与缩略图
      //    共用同一座分帧器,拿"setMap 之后 yields > 0"判会被缩略图那条路蒙过去
      let yields = 0;
      const cvF = fakeCanvas(200, 150);
      const sinceF = made2.length;
      const rF = Render.mount(cvF, {
        slicer: { budgetMs: 0, nextFrame: function () { yields++; return Promise.resolve(); } },
      });
      await rF.setMap(mM);
      const y0 = yields;
      await rF.buildLayers();
      ok(yields > y0,
         '★★ 全屏重建(换图/改缩放/改窗口)走分帧器:一次 buildLayers 让出了 ' + (yields - y0) +
         ' 帧 —— 闸 2 要的是"慢慢画出来",不是"页面死掉"');

      // ── ⑪g ★★ 代际守卫:过期那一轮的条带一项都不画 ──
      // ⑪d2 钉的是它的后果之一(不干净就不搬移);这一条钉守卫本身。视图/尺寸/图集一变,
      // 在飞那一轮剩下的条带必须一条都不落笔 —— 否则它会在新内容之上再糊一层旧像素,
      // 而 layersClean 此刻已经(或马上会)变成真 ⇒ 画面永久错位、没有任何报错。
      await rF.setView({ x: 0, y: 0, zoom: 16 });        // ★ 整数 zoom:条带不会退化,基线才可比
      const offF = layerCanvasesSince(made2, sinceF, 200, 150);
      ok(offF.length === Core.LAYER_COUNT,
         '⑪g 前提:rF 的四张离屏层都在(实得 ' + offF.length + ' 张,尺寸 = 主画布)');
      const sumClears = function () {
        let n = 0;
        for (let i = 0; i < Core.LAYER_COUNT; i++) n += countOps(offF[i].ctx, 'op', 'clearRect');
        return n;
      };
      let cF0 = sumClears();
      await rF.buildLayers();                            // 基准:单独一轮落了多少笔
      const single = sumClears() - cF0;
      ok(single > 0, '⑪g 前提:单独一轮全屏重建确实落了笔(' + single + ' 次 clearRect)');
      cF0 = sumClears();
      const pStale = rF.buildLayers();                   // 同步跑掉第 1 项(此刻它还**是**新鲜的)
      const firstTask = sumClears() - cF0;               // 过期那一轮唯一允许落笔的那一项
      const pFresh = rF.buildLayers();                   // ★ 代际 +1 ⇒ pStale 剩下的整条作废
      await Promise.all([pStale, pFresh]);
      const both = sumClears() - cF0;
      ok(firstTask > 0, '⑪g 前提:在飞那一轮同步跑掉的那 1 项确实落了笔(' + firstTask + ' 次 clearRect)');
      eq(both, single + firstTask,
         '★★ 两轮重叠时的落笔数 = 一轮 + 它同步跑掉的第一项:期望 ' + (single + firstTask) +
         ' (= ' + single + ' + ' + firstTask + '),实得 ' + both +
         ' ⇒ 过期那一轮**除了第一项一项都不画**。' +
         '守卫没了这里会是 ' + (2 * single) + ' —— 过期条带在新内容上再糊一层旧像素,' +
         '而 layersClean 已经是真 ⇒ 永久错位');
    } finally {
      globalThis.document = savedDoc;
    }
});