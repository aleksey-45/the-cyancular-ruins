'use strict';
// tests/render/70_drag_preview.js —— 相位 ⑬a~⑬b2:拖动预览(三种目标格 / 去烤只碰活动层 / 逐块重画)。
// ★ 后半(80_drag_layers.js)要用这里的渲染器与离屏层,故末尾把状态交到 globalThis.dragState。
globalThis.renderChain = globalThis.renderChain.then(async function () {
const Core = globalThis.Core;
const Render = globalThis.Render;
Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H, { backend: spyBackend() });
const savedDocD = globalThis.document;
const made4 = [];
globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made4.push(c); return c; } };
const SLICE_D = { slicer: { nextFrame: function () { return Promise.resolve(); } } };
try {
      // 6×3 格(24×12 子格):格 (1,1) = A(纹理 5)、格 (4,1) = B(纹理 9),其余格是空气。
      // ★ 逐子格填满整格(setCells 那种"一格一个子格"在这里不够:断言要逐 16 个子格比)。
      const mD = Core.createMap('d6', 6, 3);
      const fillCell = function (L, cx, cy, desc) {
        const a = mD.layers[L].desc;
        for (let qy = 0; qy < SB; qy++) {
          for (let qx = 0; qx < SB; qx++) a[(cy * SB + qy) * mD.subCols + (cx * SB + qx)] = desc;
        }
      };
      fillCell(Core.LAYER_SCENE, 1, 1, Core.neutralDesc(5));       // A
      fillCell(Core.LAYER_SCENE, 4, 1, Core.neutralDesc(9));       // B
      // ★★ 后景层也放一格(就在选区里):它是"其余层不吃偏移"那条断言的探针 ——
      //    只有非活动层上有内容时,"它没动"才判得出来(空层的像素本来就没有)。
      fillCell(Core.LAYER_BACK, 4, 1, Core.neutralDesc(12));       // B2
      const cvD = fakeCanvas(640, 400);                          // 24×12 子格在 zoom 16 下一屏装得下
      const sinceD = made4.length;
      const rD = Render.mount(cvD, SLICE_D);
      await rD.setMap(mD);
      const offsAll = layerCanvasesSince(made4, sinceD, 640, 400);   // 下标 = 层号(见该助手)
      const offD = offsAll[Core.LAYER_SCENE];
      ok(!!offD, '⑬ 前提:纹理层的离屏层建出来了(尺寸 = 主画布)');
      // ★★ 前提:"四层都在"必须连下标 = 层号这条约定一起钉住,而旧写法
      //    offD 就是从 offsAll 里取出来的那一个,后半句恒真 ⇒ 实际只判了长度。
      //    "其余层不动 / 后景层留在原地 / 缺席层不进去烤"全都判在错的画布上。
      const composed = [];
      const imgsD = drawnImages(cvD.ctx);
      for (let i = 0; i < imgsD.length; i++) if (composed.indexOf(imgsD[i]) < 0) composed.push(imgsD[i]);
      const orderD = [Core.LAYER_BG, Core.LAYER_BACK, Core.LAYER_SCENE, Core.LAYER_FRONT];
      let mapD = (composed.length === Core.LAYER_COUNT);
      for (let i = 0; mapD && i < orderD.length; i++) if (composed[i] !== offsAll[orderD[i]]) mapD = false;
      ok(offsAll.length === Core.LAYER_COUNT && mapD,
         '⑬ 前提:四层的离屏层都在**且下标 = 层号**(实得 ' + offsAll.length + ' 张;' +
         '合成顺序里首次出现的画布数 = ' + composed.length + ',逐位对上 DRAW_ORDER 的 ' +
         '[3,2,1,0] = ' + mapD + '。★ 这一条不是"offsAll[L] === offD"那种同义反复:' +
         '创建顺序错位时那条恒真,而这条会红)');
      await rD.setView({ x: 0, y: 0, zoom: ZD });                 // ≥ 8 ⇒ ② 那条路


      const tA = rD.cells().get(Core.LAYER_SCENE, 1, 1);
      const tB = rD.cells().get(Core.LAYER_SCENE, 4, 1);
      ok(tA.every(Boolean) && tB.every(Boolean),
         '⑬ 前提:A/B 两格的 16 个子格都解析出了 tile(实得 A ' + tA.filter(Boolean).length +
         ' / B ' + tB.filter(Boolean).length + ' 个)');
      ok(tA.some(function (t, i) { return t !== tB[i]; }),
         '⑬ 前提:A 与 B 是**不同**的 tile(否则下面分不出"读的是谁")');
      ok(!cellAnyDraw(offD, 0, 1) && cellMatches(offD, 4, 1, tB),
         '⑬ 前提(基线,不空转):没拖动时格 (0,1) 是空气一个子格都不画、格 (4,1) 画的是它自己(B)');

      // ── ⑬a 三种目标格(偏移 +2 格 ⇒ 目标格 = 0:环面折算)──
      // ★ 这一批用整片重建逼出重画(而不是靠 setSelDrag 的去烤):三条断言的证据要只
      dragOn(rD, { x: 4 * SB, y: 1 * SB, w: SB, h: SB }, 2 * SB, 0);
      offD.ctx.ops.length = 0;
      await rD.buildLayers();                       // 拖动中的整片重建(滚轮缩放 / 平移那条路)
      ok(cellMatches(offD, 0, 1, tB),
         '★★★ (a) 目标格 (0,1) 读的是**源格 (4,1)** 的 16 个 tile(对象身份逐子格比):' +
         '这就是 D6 —— ③ 的缓存键按"源格"取,而像素落在**目标格**的位置');
      ok(!cellAnyDraw(offD, 4, 1),
         '★★ (b) 被腾空的源格 (4,1) 一个子格都不画(它属于选区、偏移后没人补它 —— ' +
         '画了就是"复制了一份"而不是"搬过去")');
      ok(cellMatches(offD, 1, 1, tA),
         '★★ (c) 源∪目标**之外**的格 (1,1) 原样画它自己的内容(③:少了它,偏移一动整张图都' +
         '判成腾空 ⇒ 地图整体消失、只剩一个框在飘)');
      // ★★★ (d) 其余层在整片重建里也不吃偏移:buildLayers 会重画四层(与去烤那条
      //    路不同 —— 那里只有活动层被重画),所以"偏移只算活动层"这条判据必须同时住在
      //    探针 = 后景层格 (4,1) 的 B2:它必须留在原地,目标格 (0,1) 必须空。
      const tB2 = rD.cells().get(Core.LAYER_BACK, 4, 1);
      ok(tB2.every(Boolean) && cellMatches(offsAll[Core.LAYER_BACK], 4, 1, tB2) &&
         !cellAnyDraw(offsAll[Core.LAYER_BACK], 0, 1),
         '★★★ (d) 拖动中的**整片重建**里,非活动层(后景)的内容留在原地:格 (4,1) 画的还是' +
         '它自己的 B2、目标格 (0,1) 空着。偏移只算活动层 —— 少了这条,四层的内容都会跟手、' +
         '松手又弹回去(预览 ≠ 落笔;而落笔 `moveRegion` 只搬活动层)');

      // ── ⑬b ★★ 去烤 + 只有活动层:偏移一变就必须把「上一次的 源∪目标」在那一层上
      //    逐块重画(其余三层一个像素都不许碰 —— 落笔 moveRegion 也只搬活动层)──
      const rb0 = rD.stats().layerRebuilds;
      offD.ctx.ops.length = 0;
      for (let Lz = 0; Lz < Core.LAYER_COUNT; Lz++) offsAll[Lz].ctx.ops.length = 0;
      dragOn(rD, { x: 4 * SB, y: 1 * SB, w: SB, h: SB }, SB, 0);   // 偏移改到 +1 格
      eq(rD.stats().layerRebuilds - rb0, 1,
         '★★★ 偏移一变:脏区只在**活动层**上重画一次(实得 ' +
         (rD.stats().layerRebuilds - rb0) + ' 次;旧实现这里是 4 —— 四层各烤一遍,而落笔' +
         '(`moveRegion`)只搬活动层 ⇒ 另外三层的像素在拖动时跟着走、松手又弹回去,' +
         '预览 ≠ 落笔且代价翻四倍)');
      const touchedL = [];
      for (let Lt = 0; Lt < Core.LAYER_COUNT; Lt++) {
        if (Lt !== Core.LAYER_SCENE && offsAll[Lt].ctx.ops.length > 0) touchedL.push(Lt);
      }
      eq(touchedL, [],
         '★★★ 而**其余三层一个 op 都没有**(实得被碰过的层 ' + JSON.stringify(touchedL) + '):' +
         '这是"预览 = 落笔"这一条的另一半 —— BG 层从不被压暗,它跟着动最显眼。' +
         '★ 只判"活动层重画了"是不够的(四层一起烤的实现照样满足它)');
      ok(someOp(offD.ctx, function (o) {
           return o.op === 'clearRect' && o.x === 0 && o.y === 1 * SB * ZD &&
                  o.w === SB * ZD && o.h === SB * ZD;
         }) &&
         someOp(offD.ctx, function (o) {
           return o.op === 'clearRect' && o.x === 4 * SB * ZD && o.y === 1 * SB * ZD &&
                  o.w === SB * ZD && o.h === SB * ZD;
         }),
         '★★★ 重画的矩形覆盖**上一次**偏移烤过的两块,而且是**一块一块**画的(格 0 与格 4 各自' +
         ' clearRect 64,64,64,64):新偏移只碰子格 16..19 —— 只重画当前偏移的话,更早那次偏移' +
         '烤在格 0 上的内容(提交时**不会**被 moveRegion 碰到)会永远留在画面上(评审发现 1)');
      ok(!someOp(offD.ctx, function (o) {
           return o.op === 'clearRect' && o.x === 0 && o.w === 6 * SB * ZD;
         }),
         '★★★ 而**没有**任何一条整行宽的 clearRect(旧实现这里是 clearRect(0,64,384,64)):' +
         '源与目标分居接缝两侧时 `rectUnion` 的包围盒就是整行(8 格 ⇒ 24 子格 ⇒ 384px)——' +
         '高倍 + 大选区下那是**整幅图**级别的 clearRect + 每层数千次 drawImage,**每次 ' +
         'pointermove** 都付,而它并没有走 createSlicer(闸 2:去烤是同步路径)。' +
         '规范分解(`canonRects`)本来就给了正确的两块,取包围盒是白送掉那个信息');
      ok(!cellAnyDraw(offD, 0, 1) && cellMatches(offD, 5, 1, tB),
         '★★★ 改偏移之后:格 0 那块被**清掉且什么都没画**(它是空气)、内容跟到新目标格 5 —— ' +
         '两条合起来才说明"格 0 上那次烤痕真的被抹掉了"(只看没画 = 分不出"重画过"与"没重画")');
      // ★★ 同一块不重复画(Minor):源格 (4,1) 在这次偏移里是源、在上一次偏移里也是源
      //    (选区没变 ⇒ 源块必然同时落在「当前偏移的源∪目标」与「上一次那两块」里)⇒ 两组
      //    直接 concat 会把它画两遍。旧实现取 rectUnion 的包围盒,顺带把重复"吃掉"了 ——
      //    改成逐块之后这份去重得自己补上(四元组判等,见 dedupRects)。
      const bakeClears = offD.ctx.ops.filter(function (o) { return o.op === 'clearRect'; })
        .map(function (o) { return [o.x, o.y, o.w, o.h]; });
      eq(bakeClears.length, 3,
         '★★ 去重:源格在新旧偏移里各出现一次,去重后只画 3 块(实得 ' + bakeClears.length + ' 块: ' +
         JSON.stringify(bakeClears) + ')。不去重会把它连画两遍 —— 每次 pointermove 白付一次' +
         '**最大那块**(整块选区)的 clearRect + 一格 16 次 drawImage,而画出来的像素与前一遍' +
         '逐字节相同');

      // ── ⑬d ★★ 清除(松手 / 取消):烤痕不许活过这次拖动 ──
      const rb1 = rD.stats().layerRebuilds;
      offD.ctx.ops.length = 0;
      rD.setSelDrag(null, 0, 0);
      eq(rD.stats().layerRebuilds - rb1, 1,
         '★★ 清除时同样把**活动层**上上一次那两块重画(实得 ' + (rD.stats().layerRebuilds - rb1) +
         ' 次;少了它,最后那次偏移的烤痕会一直留到有别的东西标脏那一块为止)');
      ok(someOp(offD.ctx, function (o) {
           return o.op === 'clearRect' && o.x === 4 * SB * ZD && o.y === 1 * SB * ZD &&
                  o.w === SB * ZD && o.h === SB * ZD;
         }) &&
         someOp(offD.ctx, function (o) {
           return o.op === 'clearRect' && o.x === 5 * SB * ZD && o.y === 1 * SB * ZD &&
                  o.w === SB * ZD && o.h === SB * ZD;
         }) &&
         !someOp(offD.ctx, function (o) {
           return o.op === 'clearRect' && o.w === 2 * SB * ZD;
         }),
         '★★ 重画的正是**上一次**那两个块,而且是各自一块(子格 16..19 与 20..23 ⇒ ' +
         'clearRect(256,64,64,64) 与 clearRect(320,64,64,64))—— 并且**不是**它们并成的那一条' +
         '128px 宽包围盒(旧实现正是那一条;两条缺一不可:只判"有一条 128px 宽的"会放过逐块实现, ' +
         '只判"两块都在"会放过"既画逐块又画包围盒"的写法)');
      ok(cellMatches(offD, 4, 1, tB),
         '★★ 松手后源格 (4,1) 画回**它自己**的内容(预览的"腾空"不是粘住的状态:' +
         '拖动结束时格子上的像素必须与没拖过完全一样)');

      // ── ⑬b2 ★★ 接缝:源与目标分居图的两头时逐块重画,而不是取包围盒(闸 2)──
      // ★ 这一条钉的是成本,不是像素正确性:取包围盒在画面上看不出区别(多画的那几格
      //   画的本来就是它们自己的内容),但它在高倍 + 大选区下每次 pointermove 都要付一整行
      //   (最坏一整幅图)的 clearRect + 每层数千次 drawImage —— 而这条路径没有走
      offD.ctx.ops.length = 0;
      dragOn(rD, { x: 4 * SB, y: 1 * SB, w: SB, h: SB }, 2 * SB, 0);   // 源 = 格 4,目标 = 格 0
      const seamClears = offD.ctx.ops.filter(function (o) { return o.op === 'clearRect'; })
        .map(function (o) { return [o.x, o.y, o.w, o.h]; });
      ok(seamClears.some(function (r) { return r[0] === 0 && r[2] === SB * ZD; }) &&
         seamClears.some(function (r) { return r[0] === 4 * SB * ZD && r[2] === SB * ZD; }) &&
         !seamClears.some(function (r) { return r[2] > SB * ZD; }),
         '★★★ 跨接缝拖动的两块**各画各的、都只有 1 格宽**(实得 ' + JSON.stringify(seamClears) +
         ';旧实现取包围盒 ⇒ 是一条 clearRect(0,64,320,64) —— 20 个子格宽,其中 80% 是白画的;' +
         '换成"整行/整幅图"那种选区还会更大。判据取"没有任何一条宽于 1 格":它比"没有那一条 ' +
         '320px 的"更强 —— 任何包围盒(不论多大)都会红)');
      rD.setSelDrag(null, 0, 0);
  Object.assign(globalThis.dragState,
    { rD: rD, offD: offD, tB: tB, mD: mD, cvD: cvD });
} finally {
  globalThis.document = savedDocD;
}
});