'use strict';
// tests/render/80_drag_layers.js —— 相位 ⑬c~⑬i:切层拖动 / 缺席层 / ① 那条路 / 颜色层 / 折算口径 / Esc / 代价形状。
// ★ 承接 70 交下来的渲染器与离屏层(dragState);DOM 替身与 made 是本片自己的。
globalThis.renderChain = globalThis.renderChain.then(async function () {
const Core = globalThis.Core;
const Render = globalThis.Render;
const drag = globalThis.dragState;
const rD = drag.rD, offD = drag.offD, tB = drag.tB, mD = drag.mD, cvD = drag.cvD;
const savedDocD = globalThis.document;
const made4 = [];
globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made4.push(c); return c; } };
const SLICE_D = { slicer: { nextFrame: function () { return Promise.resolve(); } } };
try {
      // ── ⑬c ★★ 拖动途中切层(数字键 1-4 在拖动时照样按得下去):偏移只跟活动层走 ──
      // ★ 判据分三段:① 拖在场景层上 ⇒ 只有它动;② 切到后景层 ⇒ 偏移烤到后景层、
      //   ③ 在后景层上继续拖 ⇒ 场景层一个 op 都没有(四层一起烤的实现在 ③ 就会红)。
      const mSw = Core.createMap('sw', 6, 3);
      const fillSw = function (L, cx, cy, d) {
        const a = mSw.layers[L].desc;
        for (let qy = 0; qy < SB; qy++) {
          for (let qx = 0; qx < SB; qx++) a[(cy * SB + qy) * mSw.subCols + (cx * SB + qx)] = d;
        }
      };
      fillSw(Core.LAYER_SCENE, 1, 1, Core.neutralDesc(5));    // A
      fillSw(Core.LAYER_BACK, 1, 1, Core.neutralDesc(9));     // B(同一格,好让两层各自看得出自己的)
      const cvSw = fakeCanvas(640, 400);
      const sinceSw = made4.length;
      const rSw = Render.mount(cvSw, SLICE_D);
      await rSw.setMap(mSw);
      await rSw.setView({ x: 0, y: 0, zoom: ZD });
      const offSw = layerCanvasesSince(made4, sinceSw, 640, 400);      // 下标 = 层号
      const opsOf = function (L) { return offSw[L].ctx.ops.length; };
      for (let Lz = 0; Lz < Core.LAYER_COUNT; Lz++) offSw[Lz].ctx.ops.length = 0;
      dragOn(rSw, { x: 1 * SB, y: 1 * SB, w: SB, h: SB }, 3 * SB, 0);   // 格 1 → 格 4
      ok(opsOf(Core.LAYER_SCENE) > 0 && opsOf(Core.LAYER_BACK) === 0,
         '★★★ ① 拖动预览只烤**活动层**(场景层):后景层一个 op 都没有(实得 场景 ' +
         opsOf(Core.LAYER_SCENE) + ' / 后景 ' + opsOf(Core.LAYER_BACK) + ')');
      for (let Lz = 0; Lz < Core.LAYER_COUNT; Lz++) offSw[Lz].ctx.ops.length = 0;
      rSw.setLayer(Core.LAYER_BACK);                        // ← 用户按了 4
      const erased = someOp(offSw[Core.LAYER_SCENE].ctx, function (o) {
        return o.op === 'clearRect' && o.x === 4 * SB * ZD;    // 场景层上"目标格"那块被擦掉
      });
      ok(opsOf(Core.LAYER_BACK) > 0 && erased,
         '★★★ ② 拖动途中切层:偏移**烤到新层**且旧层上那批**被擦掉**(实得 后景 ' +
         opsOf(Core.LAYER_BACK) + ' 个 op / 场景层擦了目标格 ' + erased +
         ';不擦 = 旧层留着一次拖动预览的残影,直到有别的东西标脏它)');
      for (let Lz = 0; Lz < Core.LAYER_COUNT; Lz++) offSw[Lz].ctx.ops.length = 0;
      dragOn(rSw, { x: 1 * SB, y: 1 * SB, w: SB, h: SB }, 3 * SB, 0);
      ok(opsOf(Core.LAYER_BACK) > 0 && opsOf(Core.LAYER_SCENE) === 0,
         '★★★ ③ 切层之后继续拖:动的是**后景层**、场景层一个 op 都没有(实得 后景 ' +
         opsOf(Core.LAYER_BACK) + ' / 场景 ' + opsOf(Core.LAYER_SCENE) +
         ';四层一起烤的实现会在这里红)');
      rSw.setSelDrag(null, 0, 0);

      // ── ⑬c2 ★ 缺席层(map.layers[L] === null)不进去烤名单 ──
      // ★ flushDirty 对缺席层走的是"整张画布 clearRect"那条路,而拖动中每帧都要走一遍
      //   ⇒ 每帧白付一次全屏清屏(它一个像素都没有,没有"偏移内容"可擦),而且不计数
      const mAb = Core.createMap('ab', 4, 2);
      mAb.layers[Core.LAYER_FRONT] = null;                   // 前景层缺席(只有 layer_flags 缺位的图会这样)
      const cvAb = fakeCanvas(256, 200);
      const sinceAb = made4.length;
      const rAb = Render.mount(cvAb, SLICE_D);
      await rAb.setMap(mAb);
      await rAb.setView({ x: 0, y: 0, zoom: ZD });
      const offAb = layerCanvasesSince(made4, sinceAb, 256, 200);
      rAb.setLayer(Core.LAYER_FRONT);                        // 活动层本身就是缺席层
      offAb[Core.LAYER_FRONT].ctx.ops.length = 0;
      dragOn(rAb, { x: 0, y: 0, w: SB, h: SB }, SB, 0);
      ok(offAb[Core.LAYER_FRONT].ctx.ops.length === 0,
         '★ 缺席层不被去烤碰:拖动一步之后它**一个 op 都没有**(实得 ' +
         offAb[Core.LAYER_FRONT].ctx.ops.length + ' 个;旧实现在这里是一条整张画布宽的 ' +
         'clearRect —— 每帧一次全屏清屏,还不计数)');
      rAb.setSelDrag(null, 0, 0);

      // ★ 它在今天只有一个入口:invalidateAll(→ buildThumbs)或 invalidateCells ——
      //   拖动时照样按得下去。烤进 ① 的偏移同样会在更早的偏移上永远留着(< 8 合成的就是 ①)。
      const thumbD = rD.thumbCanvas(Core.LAYER_SCENE);
      const tpx = thumbD.width / mD.subCols;
      ok(!!thumbD && tpx >= 1, '⑬ 前提:① 的缩略图在(刻度 ' + tpx + 'px/子格)');
      const thumbDrawsIn = function (cx, cy) {
        return thumbD.ctx.ops.filter(function (o) {
          return o.op === 'drawImage' && o.x >= cx * SB * tpx && o.x < (cx + 1) * SB * tpx &&
                 o.y >= cy * SB * tpx && o.y < (cy + 1) * SB * tpx;
        });
      };
      await rD.setView({ x: 0, y: 0, zoom: 2 });                 // < 8 ⇒ ① 那条路
      thumbD.ctx.ops.length = 0;
      dragOn(rD, { x: 4 * SB, y: 1 * SB, w: SB, h: SB }, 2 * SB, 0);
      const tG0 = thumbDrawsIn(0, 1);
      ok(tG0.length === SB * SB && tG0.every(function (o) { return tB.indexOf(o.img) >= 0; }) &&
         thumbDrawsIn(4, 1).length === 0,
         '★★★ ① 也被去烤:目标格 0 的 16 个子格画的是**源格 (4,1)** 的 tile、被腾空的源格一格不画' +
         '(实得目标格 ' + tG0.length + ' 笔 / 源格 ' + thumbDrawsIn(4, 1).length + ' 笔;' +
         '不重画的话这里是 0 笔 —— 偏移被烤进 ①,而 < 8 合成的正是 ①)');
      await rD.setView({ x: 0, y: 0, zoom: ZD });                // 回到 ② 那条路

      // ── ⑬f ★★ 颜色层的拖动:同一个 dragSource,但这条分支传进去的是子格坐标 ──
      // ★ 它可能是负的(视图越过左侧接缝时 cx = −1 ⇒ Xc = −4),全靠 wrapIdx 折回来。
      //   ⑪c 只钉过"颜色层不把 RGBA 喂进 texOf",拖动这一段此前一条断言都没有。
      const mCol = Core.createMap('col6', 6, 3);
      mCol.layers[Core.LAYER_BG].rgba[(1 * SB) * mCol.subCols + (4 * SB)] = 0xff0000ff;  // 格(4,1)的左上子格 = 不透明红
      const cvCol = fakeCanvas(640, 400);
      const sinceCol = made4.length;
      const rCol = Render.mount(cvCol, SLICE_D);
      await rCol.setMap(mCol);
      const offCol = layerCanvasesSince(made4, sinceCol, 640, 400)[Core.LAYER_BG];
      ok(!!offCol, '⑬ 前提:颜色层的离屏层建出来了');
      await rCol.setView({ x: 0, y: 0, zoom: ZD });
      // ★★ 必须先切到背景层再拖:偏移只烤在活动层上(与落笔 moveRegion 同口径),
      //   而 mount 的默认活动层是场景层 —— 这条红在 BG 上,不切层的话它根本不该动
      //   (旧实现在这条上是"四层都动",所以不切层也能过;那正是被修掉的行为)。
      rCol.setLayer(Core.LAYER_BG);
      offCol.ctx.ops.length = 0;
      dragOn(rCol, { x: 4 * SB, y: 1 * SB, w: SB, h: SB }, 2 * SB, 0);
      ok(someOp(offCol.ctx, function (o) {
           return o.op === 'fillRect' && o.style === 'rgba(255,0,0,1)' &&
                  o.x === 0 && o.y === 1 * SB * ZD;
         }),
         '★★ 颜色层拖动:源子格 (16,4) 的红被画到**目标格 0 的 (0,4)** —— 与纹理分支共用同一个' +
         'dragSource(若那条分支不折算,这里读到的是目标格自己的 RGBA = alpha 0 ⇒ 什么都不画)');
      ok(!someOp(offCol.ctx, function (o) {
           return o.op === 'fillRect' && o.style === 'rgba(255,0,0,1)' &&
                  o.x === 4 * SB * ZD && o.y === 1 * SB * ZD;
         }),
         '★★ 被腾空的源格不再画那块红(不然就是"复制"而不是"搬")');

      // ── ⑬g ★★ 折算口径(与 UI 的 idxOf / moveRegion 同一个 wrap)──
      const SEL_X = { x: 4 * SB, y: 1 * SB, w: SB, h: SB };      // 格 (4,1)
      eq(Render.selectionSource(SEL_X, 2 * SB, 0, 0, 1 * SB, 24, 12), { hit: true, X: 4 * SB, Y: 1 * SB },
         '★★★ selectionSource 给了 W/H 就按环面折算:目标格 (0,1) 的内容来自**源格 (4,1)**' +
         '(24 → 0)。不折算的那版在这里读到的是"目标格自己的内容" ⇒ 预览 ≠ 落笔(评审发现 2)');
      eq(Render.selectionSource(SEL_X, 2 * SB, 0, 0, 1 * SB), { hit: false, X: 0, Y: 1 * SB },
         '★★ (对照)5 实参 = 旧的非折算口径:老调用点的语义一个字没变(它们都在主网格内,' +
         '折算与非折算在那里是恒等)');
      eq(Render.selectionSource({ x: 22, y: 4, w: 4, h: 4 }, 0, 0, 0, 4, 24, 12).hit, true,
         '★★ 选区**自己**跨着接缝(子格 22..25)时成员判据照样对:折算后它盖住子格 0' +
         '(与 regionCells / moveRegion 的 from 集合同口径 —— 绝对比大小在那种选区上恒 false)');
      eq(Render.selectionSource({ x: 22, y: 4, w: 4, h: 4 }, 0, 0, 8, 4, 24, 12).hit, false,
         '★ 折算不是"整行都算在选区内"(子格 8 不在 22..25 折算后的那一段里)');

      // ── ⑬h ★★ Esc 取消选区、左键还按着(拖动中)时 render() 不许抛 ──
      // ★ "选区为空而 selDrag 还在"是真到得了的状态(Esc 走 cancel-selection,而左键
      //   还按着)。今天挡住这次读的是外层那句 if (s.selection)(不是 drawOverlay 里
      //   的那一行)⇒ 下面两条钉的是不变量本身:
      let threwSel = null;
      cvD.ctx.ops.length = 0;
      try {
        rD.setSelection({ x: 4 * SB, y: 1 * SB, w: SB, h: SB });
        rD.setSelDrag({ x: 4 * SB, y: 1 * SB, w: SB, h: SB }, SB, 0);
        cvD.ctx.ops.length = 0;                     // ★ 只留"选区已空"之后那一次 render 的笔迹
        offD.ctx.ops.length = 0;                    // ★ 同上(离屏那一侧:烤痕记在这里)
        rD.setSelection(null);                      // ← 用户按 Esc(cancel-selection)
        const drawsInCell = function (off, cx, cy) {
          const x0 = cx * SB * ZD, y0 = cy * SB * ZD;
          return drawnOps(off).filter(function (o) {
            return o.x >= x0 && o.x < x0 + SB * ZD && o.y >= y0 && o.y < y0 + SB * ZD;
          }).length;
        };
        ok(cellMatches(offD, 4, 1, tB) && !cellAnyDraw(offD, 5, 1),
           '★★★ Esc(选区置空)那一刻内容就**归位**:源格 (4,1) 画回它自己的 16 个 tile、' +
           '偏移目标格 (5,1) 一个子格都不画(实得 源格 ' + drawsInCell(offD, 4, 1) + ' 笔 / 目标格 ' +
           drawsInCell(offD, 5, 1) + ' 笔)。' +
           '少了 `dragSource` 那道"选区没了 ⇒ 偏移不生效"的判据,这一次重画画的是**同一份偏移**' +
           '(偏移来源 `s.selDrag` 还在)⇒ 源格继续空着、目标格继续是 tB —— 框没了、内容却还在' +
           '偏移上,而且一条错误都没有');
        cvD.ctx.ops.length = 0;
        rD.render();
      } catch (e) { threwSel = e; }
      ok(threwSel === null, '★★ 选区被取消而拖动还在时 render() 不抛(实得 ' +
         (threwSel ? String(threwSel.message) : '无异常') + ')');
      ok(!someOp(cvD.ctx, function (o) { return o.op === 'strokeRect' && o.style === '#e0b34a'; }),
         '★★ 选区已经为空时**不画**拖动框(框属于选区;这条同时钉住外层那道判据还在 —— ' +
         '少了它,块内读 `s.selection.x` 会抛)');
      rD.setSelDrag(null, 0, 0);

      // ★ 背景:①(缩略图)与 ②(视口离屏层)是两份数据,同一时刻只有一份在屏幕上,
      //   而两条路的成本形状恰好相反 ——
      //     · ② 的成本 = "与画布相交的格"数 × 每格 16 次 drawImage,低倍时最大(整幅图都
      //       可能落在画布内),而低倍走的正是 ① 那条路 ⇒ 那份活一个字都看不见;
      const mBig = Core.createMap('big', 62, 37);              // 248×148 子格(大图量级)
      fillSub(mBig, Core.LAYER_SCENE, Core.neutralDesc(7));    // 整层都是砖:② 的活最重
      const cvBig = fakeCanvas(1600, 1200);
      const sinceBig = made4.length;
      const rBig = Render.mount(cvBig, SLICE_D);
      await rBig.setMap(mBig);
      const fitBig = rBig.view().zoom;
      ok(fitBig > 0 && fitBig < Render.ZOOM_THRESHOLD && Render.zoomPath(fitBig) === 'thumb',
         '⑬i 前提:默认 fit 视图落在**缩略图**那条路(实得 ' + fitBig.toFixed(2) +
         ' px/子格)—— 这一条正是评审发现 I1 的触发条件:大图的默认视图就是它');
      const thumbBig = rBig.thumbCanvas(Core.LAYER_SCENE);
      ok(!!thumbBig, '⑬i 前提:① 的缩略图建出来了');
      // 先把 ② 建出来(≥8 那条路),再回到 ① 那条路 —— 断言要判的是"另一条路没被动过",
      // 那一条路得先存在(否则"零个 op"是空转)。
      await rBig.setView({ x: 0, y: 0, zoom: 16 });
      const offsBig = layerCanvasesSince(made4, sinceBig, 1600, 1200);
      ok(offsBig.length === Core.LAYER_COUNT,
         '⑬i 前提:② 的四张离屏层建出来了(实得 ' + offsBig.length + ' 张)');
      const opsOnBig = function (which) {
        let n = 0;
        offsBig.forEach(function (c) { n += c.ctx.ops.length; });
        return n;
      };
      // 大选区:20×12 格(80×48 子格)。★ 它同时是"① 那条路的活"的量化口径。
      const SEL_BIG = { x: 20 * SB, y: 10 * SB, w: 20 * SB, h: 12 * SB };
      const selSubBig = SEL_BIG.w * SEL_BIG.h;
      await rBig.setView({ x: 0, y: 0, zoom: 16 });            // 回到 ② 那条路(已建好)
      offsBig.forEach(function (c) { c.ctx.ops.length = 0; });
      thumbBig.ctx.ops.length = 0;
      dragOn(rBig, SEL_BIG, SB, 0);                            // ← 一次 pointermove
      const layOpsBig = opsOnBig(), thmOpsOnLayers = thumbBig.ctx.ops.length;
      // 高倍下 ② 的活的上界 = "与画布相交的格"数 × 16(每格 16 子格各一次 drawImage):
      //   视图在 (0,0)、z=16、1600×1200 ⇒ 可见 100×75 子格 = 25×19 格。
      const cellsVisBig = Math.ceil(1600 / 16 / SB) * Math.ceil(1200 / 16 / SB);
      ok(thmOpsOnLayers === 0 && layOpsBig > 0 && layOpsBig <= cellsVisBig * SB * SB,
         '★★★ ≥8(② 那条路)上拖动一步:① 侧**一个 op 都没有**(实得 ' + thmOpsOnLayers +
         ' 个),② 侧的活**有界**且在可见区之内(' + layOpsBig + ' 个 op ≤ 可见格数 ' +
         cellsVisBig + ' × 16 = ' + (cellsVisBig * SB * SB) + ')。' +
         '★ ① 在高倍下根本不在屏幕上(合成走 drawLayerPath)⇒ 那份活是白付');
      rBig.setSelDrag(null, 0, 0);
      // 换到 ① 那条路(< 8):这一次只许碰 ①。② 的四张画布一个 op 都不许涨 ——
      await rBig.setView({ x: 0, y: 0, zoom: 3 });
      offsBig.forEach(function (c) { c.ctx.ops.length = 0; });
      thumbBig.ctx.ops.length = 0;
      dragOn(rBig, SEL_BIG, SB, 0);                            // ← 再走一次 pointermove
      const layOpsThumb = opsOnBig(), thmOpsBig = thumbBig.ctx.ops.length;
      ok(layOpsThumb === 0 && thmOpsBig > 0 && thmOpsBig <= selSubBig * 2,
         '★★★ <8(① 那条路)上拖动一步:② 侧**一个 op 都没有**(实得 ' + layOpsThumb +
         ' 个);① 侧的活与**选区面积**成正比(' + thmOpsBig + ' 个 op ≤ 选区 ' + selSubBig +
         ' 子格 × 2 = ' + (selSubBig * 2) + ')。' +
         '★ 去分派之前这里是「源 ∪ 目标(∪ 上一次那两块)」与画布的交集 × 每格 16 次 ' +
         'drawImage —— 低倍时画布覆盖的格数**最大**(整幅图都可能落在里面),与选区大小无关, ' +
         '而低倍合成的偏偏是 ① ⇒ 那一整份活一个字都看不见');
      rBig.setSelDrag(null, 0, 0);
} finally {
  globalThis.document = savedDocD;
}
});