'use strict';
// Node 冒烟 —— render.js 的**纯半边**(缓存 ①②③、脏区、环面、画笔几何、闸 2 分帧)。
// Run: cd level_editor && node render_smoke.js
// 判据:文本 `RENDER SMOKE OK` + 退出码 0。
// ★ 加载顺序是硬依赖:core → tint → render(tint 要 Core,render 要两者)。

require('./core.js');
require('./tint.js');
require('./render.js');
const Core = globalThis.Core;
const Tint = globalThis.Tint;
const Render = globalThis.Render;

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function throws(fn, msg, expectSub) {
  let e = null;
  try { fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && String(e.message).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + e.message); return;
  }
  pass++; console.log('  ok  - ' + msg);
}

// 合成图集:3 行 × 10 列、每块 32×32(R = 块内 x×8,G = 块内 y×8,B = 块号)。
const COLS = 10, ATLAS_W = COLS * 32, ATLAS_H = 96;
function makeAtlas() {
  const a = new Uint8ClampedArray(ATLAS_W * ATLAS_H * 4);
  for (let y = 0; y < ATLAS_H; y++) {
    for (let x = 0; x < ATLAS_W; x++) {
      const i = (y * ATLAS_W + x) * 4;
      a[i] = (x % 32) * 8; a[i + 1] = (y % 32) * 8;
      a[i + 2] = Math.floor(y / 32) * COLS + Math.floor(x / 32); a[i + 3] = 255;
    }
  }
  return a;
}
// 记录型 backend:每次建图都记账,于是能断言"空气**没有**进 Tint"(只判颜色是抓不住它的)。
function spyBackend() {
  const calls = [];
  return {
    calls: calls,
    createTile: function (pixels, size) { calls.push({ size: size }); return { fake: true, n: calls.length }; },
  };
}
function makeMap(cellsW, cellsH) {
  const m = Core.createMap('t', cellsW, cellsH);
  return m;
}
function setCells(map, L, list, descOf) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (const c of list) a[c[1] * map.subCols + c[0]] = descOf(c[0], c[1]);
  return map;
}

// ── 相位 ⑩ 的替身:一个把每次 ctx 调用都记下来的假画布 ──
// ★ `this.fillStyle` / `this.globalAlpha` 在**调用那一刻**取 —— 渲染代码是"先设样式再画",
//   不看调用点取值就分不出"用了哪个颜色",而背景层那两条断言的判据正是颜色。
function fakeCtx() {
  const ops = [];
  const c = {
    ops: ops,
    imageSmoothingEnabled: true, globalAlpha: 1,
    fillStyle: '', strokeStyle: '', font: '', textAlign: '', textBaseline: '', lineWidth: 1,
    setTransform: function () {}, save: function () {}, restore: function () {},
    beginPath: function () {},
    moveTo: function (x, y) { ops.push({ op: 'moveTo', x: x, y: y }); },
    lineTo: function () {},
    stroke: function () { ops.push({ op: 'stroke', style: String(this.strokeStyle) }); },
    fillRect: function (x, y, w, h) {
      ops.push({ op: 'fillRect', style: String(this.fillStyle), alpha: this.globalAlpha, x: x, y: y, w: w, h: h });
    },
    clearRect: function (x, y, w, h) { ops.push({ op: 'clearRect', x: x, y: y, w: w, h: h }); },
    drawImage: function (img, x, y, w, h) {
      // ★ `img` 也记下来:② 之后主画布上画的是**离屏层那张画布**(不是小图),而
      //   "隐藏的那一层没被合成""主画布合成的是哪一张离屏层"这类断言只能靠**对象身份**判
      //   (数次数是分不出来的:一层的副本数与别的层一样)。
      // ★ `comp` 是调用那一刻的 globalCompositeOperation:平移的自拷贝用 'copy'
      //   (整块替换),拿它才能把"搬移"与"合成"分开判。
      ops.push({ op: 'drawImage', img: img, comp: this.globalCompositeOperation,
                 alpha: this.globalAlpha, x: x, y: y, w: w, h: h });
    },
    fillText: function (t, x, y) { ops.push({ op: 'fillText', t: String(t), x: x, y: y }); },
    strokeRect: function (x, y, w, h) {
      ops.push({ op: 'strokeRect', style: String(this.strokeStyle), x: x, y: y, w: w, h: h });
    },
  };
  return c;
}
function fakeCanvas(w, h) {
  const c = { width: w | 0, height: h | 0, parentElement: null, ctx: fakeCtx() };
  c.getContext = function () { return c.ctx; };
  return c;
}
// 把一整层的每一格都写成同一个值(背景层 = 一个颜色,纹理层 = 一个描述符)
function fillSub(map, L, v) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  a.fill(v >>> 0);
  return map;
}
function countOps(ctx, prop, val) {
  return ctx.ops.filter(function (o) { return o[prop] === val; }).length;
}
function someOp(ctx, fn) { return ctx.ops.some(fn); }
// ★ 主画布上被 drawImage 过的**画布对象**(按出现顺序,允许重复):② 之后"这一层有没有
//   被合成上去"只能按对象身份判(数次数分不出来 —— 各层的副本数是一样的)。
function drawnImages(ctx) {
  return ctx.ops.filter(function (o) { return o.op === 'drawImage' && o.img; })
    .map(function (o) { return o.img; });
}
// ★ 从 `made` 里挑出"尺寸等于主画布"的那几张 —— 就是 ② 的离屏层(缩略图的尺寸是
//   子格数 × 刻度,两者只有在极小图上才会撞上;这一批用到的图都撞不上)。
//   ensureLayerCanvas 按 L 递增创建 ⇒ 顺序就是 [前景, 场景, 后景, 背景]。
function layerCanvasesSince(made, sinceIdx, w, h) {
  return made.slice(sinceIdx).filter(function (c) { return c.width === w && c.height === h; });
}

(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 某个断言挂住了(分帧器的 nextFrame 没被注入?)');
    process.exit(1);
  }, 120000);

  // ==== 相位 ⑩ 画布挂载:首帧渲染 + 背景层是 RGBA 不是描述符(mount 一族)====
  // ★★ **位置是承重的**:本相位排在 ① 之前,因为它是**唯一**用 `await` 的相位 —— 而
  //    `await` 只在这个函数体里合法。相位 ④ 的那个 IIFE 是**同步**的,⑤~⑨ 又都嵌在它的
  //    `.then(回调)` 里(那个回调不是 async)⇒ 把本相位写在 ⑨ 后面就是
  //    `ReferenceError: await is not defined`(它被当成一个未声明的标识符、
  //    在**所有断言都跑完之后**才抛)。★ 这一条是实测踩出来的,不是推理。
  // ★ 本相位在 node 里**真的跑** mount():三样替身 —— document.createElement('canvas')、
  //   画布 ctx(把每次调用记进 ops)、分帧器的 nextFrame(mount 的 opts.slicer 注入缝,与
  //   createSlicer 的 opts.now/nextFrame 同一个先例)。DOM 只出现在 mount() 内部(顶层
  //   一行不碰),所以在这里置替身是安全的。
  // ★★ 这里真正防的两件事都是**静默**的,只有"真的画一遍并记账"才看得见:
  //    ① 背景层是 RGBA、纹理层是描述符 —— 拿 texOf 判背景层不抛,只是结论没意义
  //       (纹理位恰好为 0 的颜色会被当成空气 ⇒ 整层不可见);
  //    ② < 8px/子格(缩略图路径)与 ≥ 8px/子格(逐子格路径)是**两条完全不同的实现**,
  //       只测一条,另一条坏了照样全绿。
  await (async function () {
    ok(typeof Render.mount === 'function', 'Render.mount 存在(画布挂载的入口,T3 的交付面)');
    if (typeof Render.mount !== 'function') return;
    eq(Render.DRAW_ORDER, [3, 2, 1, 0],
       '★★ DRAW_ORDER 从内到外:背景(3)最先画、前景(0)最后画(盖在最上面)');
    // ★ 本相位要画真的 tile,所以图集必须先就位(`Tint.get` 在 `setSource` 之前会**抛**;
    //   合成图集与 backend 替身与相位 ②/③b 同一份 —— 默认 backend 走 ImageData,node 里没有)。
    Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H, { backend: spyBackend() });

    const savedDoc = globalThis.document;
    const made = [];
    globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made.push(c); return c; } };
    const SLICE = { slicer: { nextFrame: function () { return Promise.resolve(); } } };
    try {
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
      // 场景层放 4 个点,其中两个**贴着右边界**(14/15 子格)—— ⑩d 要靠它们判环面副本。
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
      // ★ 组视图入口现在**可能**返回分帧重建的 promise(评审发现 6):一律 await,别让一次
      //   意外拒绝变成"未处理的 promise 拒绝"把进程直接打死(那样一条具名 FAIL 都不会有)。
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
      // ★★ 下面两条**一定**返回分帧重建的 promise(有图 + zoom ≥ 8)—— 漏 await 的话一次
      //    意外拒绝会在断言全绿之后以"未处理的 promise 拒绝"收场(评审发现 6)。
      await rR.setView({ x: 99, y: 99, zoom: 32 });
      await rR.fit();
      ok(rR.view().x < 0 && rR.view().y < 0 && rR.view().x > -4 && rR.view().y > -4,
         'fit() 把地图居中(视图原点落在 −2/−1.5 这种小负数上:CSS 的 0 点不是左上角)');

      // ── ⑩d ≥ 8px/子格:视口离屏层路径(②)+ 环面副本 ──
      // ★★ 视图一变,② 的四张离屏层整片失效 ⇒ setView 是**分帧重建**(闸 2),要 await。
      //    重建之后的合成次数 = **层数 × 副本数**(不再与"有内容的格数"有关 —— 主画布
      //    上画的是那张离屏层,一层的副本数就是环面铺了几份)。
      cv1.ctx.ops.length = 0;
      await r1.setView({ x: 0, y: 0, zoom: 16 });
      ok(countOps(cv1.ctx, 'op', 'drawImage') > 0,
         '★ ≥ 8px/子格 换视口离屏层路径(主画布上合成的是 ② 的离屏层,不是逐子格的小图)');
      // 网格线:格线恒画,子格线只在 zoom ≥ 4 且开了子格时画(C15)
      // ★ 判据用 moveTo(线段起点)而不是 stroke(整条路径一次):两组线各 `beginPath`+`stroke`,
      //   于是 stroke 恒为 2 —— 拿它判"子格线开没开"是**分不出来**的(两条线都画了空路径)。
      const coarseMoves = countOps(cv1.ctx, 'op', 'moveTo');
      ok(coarseMoves > 0, '格线按**可见区**画出来(moveTo ' + coarseMoves + ' 条线段;B8:不裁剪 = 每次重画整张图)');
      cv1.ctx.ops.length = 0;
      r1.setSubGrid(true);
      const subMoves = countOps(cv1.ctx, 'op', 'moveTo');
      ok(subMoves > coarseMoves,
         '★★ setSubGrid(true) 多画一层子格线(' + subMoves + ' > ' + coarseMoves +
         '):格线 64px、子格线 16px,后者密 4 倍');
      r1.setSubGrid(false);
      // ★★ 副本必须**逐层铺出去**:视口左边缘越过接缝时,离屏层那一份要被平移 −subCols×zoom
      //    再画一次(合成次数 = 层数 × 副本数)。★ 离屏层本身读格时就**环面折算**,所以
      //    副本不会画错内容(偏移是 subCols 的整数倍 ⇒ 折算前后是同一格)。
      // ★★ 本节**只**数次数(评审发现 5):这个视图下 ±subCols 那几份副本必然整个落在画布外
      //    ("接缝另一侧的内容画出来了没有"它答不了)—— 那一条的真守卫是 ⑪e(接缝另一侧的
      //    像素有没有被画到 x ≥ 96)。
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
      //    (每层各几份副本),藏掉一层只会让**它那几份**消失,其余三层照画(总次数 4 → 3)。
      //    "次数变成 0"是**逐子格**那条旧路径的说法。
      // ★★ 但**次数分不出两件事**(评审发现 5):"可见性闸拦住了那一层"与"那一层压根没有
      //    离屏层"—— drawLayerPath 里 `!s.layerVisible[L]` 与 `!layerCv[L]` 走的是**同一个**
      //    continue。真守卫在 ⑪a(按**对象身份**判"主画布合成的就是那一层的离屏层")。
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
      ok(someOp(cv1.ctx, function (o) { return o.op === 'drawImage' && o.alpha === 1; }),
         'setDimOthers(false) 之后不再压暗(同一层、同一个绘制点)');
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

      // ── ⑩h ★★ 背景层是 RGBA,不是描述符(F1:两种颜色、两种不同的静默失败)──
      // 不透明红 #FF0000FF 的**纹理位域**恰好是 0(#FF0000FF >>> 12 & 0xFFF = 0)⇒ 拿它当
      // 空气判 = 整层**看不见**;不透明青 #00FFFFFF(页面背景色输入框的默认值)的纹理位域是
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
      // ★★ ② 之后主画布上画的是**离屏层那张画布**,颜色层的 fillRect 落在离屏层自己的
      //    ctx 上 —— 所以这几条判据要看**离屏层**(按对象身份取:尺寸等于主画布的
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
      // ★ 缩略图路径与逐格路径**处置不同**,且都对:缩略图是长期存在的位图(有旧像素要清),
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
      // ★ 缺席层不进 thumbTasks(省一次全图扫描),于是它**不会**被重画 —— 尺寸相同时
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
      // ★ zoom 16 + 有图 ⇒ 返回分帧重建的 promise,必须 await(评审发现 6);漏了的话
      //   下面的记账就建在"重建还没落地"的半旧状态上,而拒绝还会静默打死进程。
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

      // ── ⑩k ★★ 换到一张"同宽更高"的图:缩略图必须按**高度**判、整张重建 ──
      // ★★ ⑩i 用的是**同尺寸**换图(那张图改的只是"缺层"),走的正是复用那条路 ⇒ 它
      //    天然抓不到"复用条件漏判高度"。这里的两张图**同宽、不同高**:
      //    `thumbScale` 只看总字节数,所以两者拿到**同一个刻度**(前提断言把这一点钉住,
      //    否则"复用"这条路根本不走,本相位就是空转);于是只判宽度的实现在第二张图上
      //    复用了那张**矮**画布,而 drawThumbPath 用五实参 drawImage 把它整张缩进
      //    subRows*px*scale 的目标框 ⇒ 画面纵向被拉伸/截断 —— 且默认视图(fitZoom 之后
      //    zoom < 8)走的**正是**缩略图这条路,所以"默认视图是错的"而没有任何报错。
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
    ok(made.length >= 8, '★ 缩略图确实经 document.createElement("canvas") 建出来(' +
       made.length + ' 张:每层一张 × 每张图)');
  })();

  // ==== 相位 ① 环面折算与空层 ====
  eq(Render.wrapIdx(-1, 4), 3, 'wrapIdx: -1 → 3(负数也折回正区间)');
  eq(Render.wrapIdx(-5, 4), 3, 'wrapIdx: -5 → 3');
  eq(Render.wrapIdx(4, 4), 0, 'wrapIdx: 4 → 0');
  eq(Render.wrapIdx(0, 4), 0, 'wrapIdx: 0 → 0');
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

  // ==== 相位 ② 空气短路(账本 I4:air 是地图里最常见的一格)====
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
    // ★★ 抛错之后**一个字都不许提交**。注入 backend 那条路最容易写错 —— 先 `tiles = 新缓存`
    //   再 `setSource`,抛错就留下一个**没有贴图源的新 ④**:`atlasInfo()` 还报旧图集、③ 也
    //   没作废,于是下一次 `tileFor` 抛 `Tint: 还没 setSource…` 而不是照旧画老图集。
    //   (只判"抛了没有"是拦不住它的 —— 缺陷发生时异常照样抛,只是留下了半个换图。)
    ok(Render.tileCache() === t4prev,
       '★★ 抛错之后 ④ **还是原来那一个对象**(注入 backend 也不许先把 ④ 换掉)');
    eq(Render.atlasInfo(), infoPrev, '★★ 抛错之后 atlasInfo 仍报上一张图集(换图没提交)');
    // ★ 包一层 try:变异(先换 ④ 再校验)下这里**会抛**,裸写会让整支冒烟当场崩掉、
    //   连命名 FAIL 都打不出来 —— 那样"红"是红了,却看不出红在哪。
    const prevStillWorks = (function () {
      try { return Render.tileFor(Core.neutralDesc(3), 0, 0) !== null; } catch (e) { return false; }
    })();
    ok(prevStillWorks,
       '★★ 抛错之后上一张图集**照旧可用**(tileFor 照旧返回小图,而不是抛 `Tint: 还没 setSource,…`)');

    // ★★ 容量也不许为**负**。`w` 由 `Tint.setSource` 校验,而 `h` 没有任何人校验(setAtlas
    //   原样 `h | 0` 存下)—— 畸形的 h 让 floor(h / BLOCK_PX) 为负 ⇒ 容量是负数。而计划的
    //   `clampTexture` 把任何 **< 1** 的容量都当"没有信息"、**静默**放宽到 TEXTURE_MAX,
    //   负数正好从那道闸下钻过去。钳到 0 就堵住了(0 = 明确的"一块都放不下")。
    Render.setAtlas(makeAtlas(), ATLAS_W, -64);
    eq(Render.atlasCapacity(), 0,
       '★★ 畸形高度(h = -64)下容量钳到 0、不是负数(负数会被 clampTexture 读成"没有信息"、静默放宽到 TEXTURE_MAX)');
    Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H);   // 还原:下面的相位还要用这张好图集
  })();

  // ==== 相位 ③ ③ 格位图缓存:两条独立的失效轴 ====
  (function () {
    let built = 0;
    // ★ 判据是"**这一步**有没有动模块状态",不是"模块里现在是不是 null":Task 4 起
    //   mount 的 setMap 会 attachCells(换图的作废链条靠它闭合,见相位 ③b),所以
    //   本相位跑到这里时模块里**已经有**一个(前面那些 mount 装上去的)。
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

    // ★★ 重建出来的条目也必须挪到**最近端**。`Map.set` 对**已存在**的键保留原来的插入位置,
    //   而这条重建路径恰恰常落在"换图后 setSource 刻意不清表"留下的陈旧条目上 —— 不先
    //   `delete` 的话,刚重建出来的条目仍蹲在最冷位置,下一次淘汰就把它扔掉(它才刚建过)。
    //   ★ 两面各用一个**新**缓存:同一个缓存里连着判两面的话,第一个 `get` 已经把 LRU 序改了,
    //     第二面在新旧实现下都是 miss,分不出来。两面共用同一个序列(`lruSeq`):
    //   get(A) → get(B) → touch(A) → get(A)(★ 走**重建**)→ get(C)(超上限 → 淘汰一个)。
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

  // ==== 相位 ③b ★★ 换图必须**同时**作废 ③ 与 ④(走生产路径 setAtlas)====
  // ★ 账本点名带进计划 2b 的那条不变量。判据走 setAtlas 这条**真实**路径,不各自
  //   调一遍 setSource —— 只测"每个缓存自己的 setSource 有效"证明不了"换图事件
  //   真的碰到了两层",而漏掉 ③ 的症状是审计 A2 在上一层原样复发。
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
    // ★★ 换图**不清表** —— 陈旧条目留着,靠代际不等恒 miss 作废(见 `setSource` 的注释:
    //   清了表,`e.gen === gen` 就成了死代码,Step 5 那条变异再也杀不掉任何东西)。
    eq(c3.stats().size, 1, '★ 换图之后 ③ **不清表**(陈旧条目还在 —— 它靠代际作废,不是靠清空)');
    eq(c3.stats().generation, 1, '★ ③ 的代际 +1(setSource 追的是它)');
    eq(t4.stats().size, 0, '★★ 换图之后 ④ 被清空(Tint.setSource 自己做的)');
    const after3 = c3.get(Core.LAYER_SCENE, 0, 0);
    ok(after3 !== before3, '★★ 换图之后同一个格键**是新对象**(漏了 = A2 在上一层复发)');
    eq(c3.stats().misses, 2, '★★ 换图之后同一个格键**必须重新构建**(只判内容版本号的话这里会是命中)');
    const after4 = t4.get(3, 0, 0, d3);
    ok(after4 !== before4, '★★ 换图之后同一块小图也是新对象(调用方不得跨换图持有 tile)');
    ok(be.calls.length >= 2, '换图之后 ④ 真的重算过(实得 backend 调用 ' + be.calls.length + ' 次)');

    // ★★ 相位 ②b(承相位 ② 那条 throws 的另一半 —— 那一条只判了"抛没抛"):换图**抛错时
    //    一层都不许提交**。③ 要先 `attachCells` 才有,故这一相位落在相位 ③b 里。
    //    ★ 本相位**不是**"这个缺陷唯一抓得住的地方":真正承重的是**两面** —— **④ 的对象
    //      身份**与**"旧图集还能不能画"** —— 而相位 ② 那一对(`tileCache()` 身份 +
    //      `tileFor` 照旧返回小图)没挂 ③ 也照样抓得住同一个缺陷(变异实测:四条红全在这两面上)。
    //    ★ 反过来,下面这几条在这个缺陷(先换 ④ 再校验)下**照样绿**,别把它们读成判据:
    //      `atlasInfo()`、③ 的**代际**、③ 的条目身份 —— 改动只落在 ④ 那一侧,
    //      `cells.setSource()` 压根没被走到;旧 ④ 的条目那条同理(旧缓存对象根本没被碰过)。
    //    ★ 其中"③ 的代际"与"③ 的条目身份"是一对:凡是"把 ③ 的作废提到校验之前"这一类变异,
    //      两条会**一起**红(代际一动,条目身份那条必然跟着变)—— 即那种变异下有一条是冗余的。
    //      两条都留着,是因为它们各自记录一件事(代际动没动 / 条目还是不是原来那个);
    //      这里只是**不**声称"每一面都能独立判别"。
    const infoBefore = Render.atlasInfo(), genBefore = c3.stats().generation;
    const warm3 = c3.get(Core.LAYER_SCENE, 0, 0);        // 先预热,好判"③ 没被作废"
    const warm4 = t4.get(3, 0, 0, d3);
    throws(function () { Render.setAtlas(new Uint8ClampedArray(7), 8, 1, { backend: be }); },
           '★★ 换图抛错:注入 backend 时整条换图也不许提交(形状非法 → 抛)', '不是整行');
    ok(Render.tileCache() === t4, '★★ 抛错之后 ④ 还是原来那一个对象(没被先换掉)');
    eq(Render.atlasInfo(), infoBefore, '★★ 抛错之后 atlasInfo 仍报上一张图集');
    eq(c3.stats().generation, genBefore, '★★ 抛错之后 ③ 的代际**没动**(换图事件根本没碰到 ③)');
    ok(c3.get(Core.LAYER_SCENE, 0, 0) === warm3, '★★ 抛错之后 ③ 的条目仍是原来那个对象(没被作废)');
    ok(t4.get(3, 0, 0, d3) === warm4, '★★ 抛错之后 ④ 的条目还在(上一张图集照旧可用)');
    const stillWorks = (function () {
      try { return Render.tileFor(Core.neutralDesc(3), 0, 0) !== null; } catch (e) { return false; }
    })();
    ok(stillWorks, '★★ 抛错之后 tileFor 照旧返回小图(不是抛 `Tint: 还没 setSource,…`)');
  })();

  // ==== 相位 ③c ★★ 换图必须**连 ① 与 ② 一起**作废(终审评审发现 I2)====
  // ★ ③b 钉的是 ③ 与 ④(那条不变量当年就是按这两层写的),①② **此前零覆盖** —— 而它们
  //   各有一条"看着不对、一个字都不报"的路:
  //     · ① 是**默认 fit 视图**走的那条(大图必然 < 8 px/子格)⇒ 换图之后继续画旧图集的砖,
  //       直到某次 invalidateAll/setMap(A2 原样复发);
  //     · ② 更糟:`layersClean` 不被碰 ⇒ ≥8 下平移时 `panBy` 判"这一层是干净的",自拷贝
  //       旧像素、只把新露出的边条按**新**图集补上 ⇒ 屏幕上是**新旧混着**。
  // ★ 判据落在**像素的来源**上(与 ③b 同款,不是"重画过没有"):换图之后 ①/② 收到的每一张
  //   小图都必须是**新图集**算出来的。替身 backend 每次建图都记一个序号 ⇒ "旧图集的小图"
  //   可以被指名(它画出来的正是"一半新一半旧"那张脸)。
  await (async function () {
    const savedDoc3c = globalThis.document;
    const made3c = [];
    globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made3c.push(c); return c; } };
    const tick3c = function () { return new Promise(function (res) { setTimeout(res, 0); }); };
    try {
      const be = spyBackend();
      Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H, { backend: be });
      const m = Core.createMap('atlas3c', 6, 3);              // 24×12 子格
      fillSub(m, Core.LAYER_SCENE, Core.neutralDesc(5));       // 整层都是砖 ⇒ ①② 都有像素
      const cv = fakeCanvas(640, 400);
      const r = Render.mount(cv, { slicer: { nextFrame: function () { return Promise.resolve(); } } });
      await r.setMap(m);
      await r.setView({ x: 0, y: 0, zoom: 16 });               // ≥8 ⇒ 两条路都在用
      const thumbOld = r.thumbCanvas(Core.LAYER_SCENE);
      const offOld = layerCanvasesSince(made3c, 0, 640, 400)[Core.LAYER_SCENE];
      ok(!!thumbOld && !!offOld && countOps(thumbOld.ctx, 'op', 'drawImage') > 0 &&
         countOps(offOld.ctx, 'op', 'drawImage') > 0,
         '③c 前提:换图**之前** ① 与 ② 都画过(drawImage 笔迹分别 ' +
         (thumbOld ? countOps(thumbOld.ctx, 'op', 'drawImage') : -1) + ' / ' +
         (offOld ? countOps(offOld.ctx, 'op', 'drawImage') : -1) + ' 笔)—— 否则下面两条是空转');
      const nOld = be.calls.length;                           // 旧图集一共建了多少张小图
      const a2 = makeAtlas(); a2[0] = 111; a2[1] = 222;       // 两张**不同**的图集
      Render.setAtlas(a2, ATLAS_W, ATLAS_H);                  // ← 换图(不换 backend:同一个 ④)
      // ★ 惰性作废:setAtlas 只记账,①② 的丢弃与重画在下一次 render() 里落地
      cv.ctx.ops.length = 0;
      r.render();
      const since3c = made3c.length;                          // 这之后建出来的才是**新**一代
      const offsNew = function () { return layerCanvasesSince(made3c, since3c, 640, 400); };
      let waited = 0;
      for (; waited < 60; waited++) {
        const th = r.thumbCanvas(Core.LAYER_SCENE);
        const offs = offsNew();
        if (th && th !== thumbOld && countOps(th.ctx, 'op', 'drawImage') > 0 &&
            offs.length === Core.LAYER_COUNT &&
            offs.some(function (c) { return c.ctx.ops.length > 0; })) break;
        await tick3c();
      }
      const thumbNew = r.thumbCanvas(Core.LAYER_SCENE);
      const thumbDraws = thumbNew ? drawnImages(thumbNew.ctx) : [];
      const thumbOldBricks = thumbDraws.filter(function (t) { return t.n <= nOld; }).length;
      ok(thumbNew && thumbNew !== thumbOld && thumbDraws.length > 0 && thumbOldBricks === 0,
         '★★★ 换图之后 ① **整片重建**,且画的全是**新图集**的小图(实得 ' + thumbDraws.length +
         ' 笔,其中旧图集的 ' + thumbOldBricks + ' 笔;等 ' + waited + ' 拍)。' +
         '★ 只判"重画过一次"是不够的:重画时照样可以读旧的 ③/旧小图 ⇒ A2 原样复发 —— ' +
         '判据必须落在**小图是谁算出来的**上');
      const offsN = offsNew();
      const offDraws = [];
      offsN.forEach(function (c) { drawnImages(c.ctx).forEach(function (t) { offDraws.push(t); }); });
      const offOldBricks = offDraws.filter(function (t) { return t.n <= nOld; }).length;
      ok(offsN.length === Core.LAYER_COUNT && offDraws.length > 0 && offOldBricks === 0,
         '★★★ ② 同样按新图集整片重铺(实得 ' + offsN.length + ' 张新离屏层 / ' + offDraws.length +
         ' 笔,其中旧图集的 ' + offOldBricks + ' 笔)。' +
         '★ 少了它,`layersClean` 不被碰 ⇒ ≥8 下平移会自拷贝旧像素、只给新露出的边条补新砖');
      ok(drawnImages(cv.ctx).indexOf(offOld) < 0,
         '★★★ 换图之后主画布**不再合成旧的 ② 画布**(它必须被丢掉、由新的那张顶上;' +
         '实得旧画布出现 ' + drawnImages(cv.ctx).filter(function (c) { return c === offOld; }).length +
         ' 次)。★ 不丢的话屏幕上就是"一半旧图集、一半新图集"');
    } finally {
      globalThis.document = savedDoc3c;
      Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H);         // 还原(与相位 ② 末尾同款)
    }
  })();

  // ==== 相位 ④ 闸 2:单帧预算分帧器 ====
  (function () {
    // 注入时钟与"下一帧":每项花 1ms,让出一帧再走 20ms(模拟真实的帧间隔)。
    const clock = { t: 0 };
    const slicer = Render.createSlicer({
      budgetMs: 8,
      now: function () { return clock.t; },
      nextFrame: function () { clock.t += 20; return Promise.resolve(); },
    });
    const items = [];
    for (let i = 0; i < 100; i++) items.push(i);
    const seen = [];
    return slicer.run(items, function (it) { seen.push(it); clock.t += 1; }).then(function (rep) {
      eq(seen.length, 100, '★ 分帧器把 100 项**全部**做完(慢,但不丢)');
      eq(rep.processed, 100, 'report.processed = 100');
      // 预算 8ms、每项 1ms、每帧至少一项 ⇒ 每帧 8 项;100 项 ⇒ 让出 12 次,
      // 第 13 帧把剩下的 4 项做完并 resolve。
      eq(rep.frames, 12, '★ 每帧 8 项 × 12 帧 = 96 项,余 4 项在第 13 帧(去掉预算判断 = 这里变 0)');
      eq(rep.maxStepMs, 8, '★★ 单帧**真的**没超预算(实得 ' + rep.maxStepMs + 'ms;把预算判断删掉 = 100ms)');

      // ★ 预算必须是**有限的数**:`now() - s0 >= NaN` 与 `>= 负数` 都**恒为 false** ⇒ while
      //   会一口气做完整批(正是闸 2 要防的那件事),而且**不报错** —— 分帧器装了等于没装。
      eq(Render.createSlicer({ budgetMs: NaN }).budgetMs, Render.DEFAULT_BUDGET_MS,
         '★ budgetMs: NaN → 回落默认预算(原样传出的话预算判断恒 false)');
      eq(Render.createSlicer({ budgetMs: -5 }).budgetMs, 0, '★ budgetMs: 负数 → 钳到 0(不是负数)');
      eq(Render.createSlicer({ budgetMs: Infinity }).budgetMs, Render.DEFAULT_BUDGET_MS,
         '★ budgetMs: Infinity → 回落默认预算(判的是"有限",不是"非负就行")');

      const one = Render.createSlicer({ budgetMs: 0, now: function () { return clock.t; },
                                        nextFrame: function () { clock.t += 1; return Promise.resolve(); } });
      return one.run([1, 2, 3], function () {}).then(function (r2) {
        eq(r2.processed, 3, '★ budgetMs = 0:每帧至少做一项,3 项照样全部做完(不是死循环)');
        eq(r2.frames, 2, 'budgetMs = 0 → 每帧一项,3 项让出 2 次');

        // ★★ 行为面(不只是读回那个数):NaN 预算**真的**按默认预算分帧。不回落的话
        //    frames 是 0、maxStepMs 是 100(一口气做完整批)—— 两条断言各看一面。
        const clockN = { t: 0 };
        const nanSlicer = Render.createSlicer({ budgetMs: NaN,
          now: function () { return clockN.t; },
          nextFrame: function () { clockN.t += 20; return Promise.resolve(); } });
        return nanSlicer.run(items, function () { clockN.t += 1; }).then(function (r3) {
          eq(r3.frames, 12, '★★ NaN 预算的行为与默认预算**一致**(12 帧;不回落 = 0 帧,一口气做完整批)');
          eq(r3.maxStepMs, Render.DEFAULT_BUDGET_MS, '★★ NaN 预算下单帧仍守默认预算(不回落 = 100ms)');

          // ★★ 第 2 帧抛错必须让 run() 的 promise **reject**。只测第 1 帧抛是**区分不了**的:
          //    那时 step 还在 promise 执行器里同步跑,执行器本来就会接住;真正会漏的是
          //    "让出一帧之后"那条 —— 从第 2 帧起 step 跑在 `nextFrame().then(step)` 这条
          //    **没人观察**的链上,裸抛 = unhandled rejection,run() 的 promise 于是**永远
          //    不 settle**(调用方 await 到天荒地老,且看不到任何错误)。
          //    每帧一项靠 budgetMs = 0(负预算会被钳成 0,这里要的正是它)。
          const boom = Render.createSlicer({ budgetMs: 0, now: function () { return 0; },
                                             nextFrame: function () { return Promise.resolve(); } });
          return boom.run([1, 2, 3], function (it) { if (it === 2) throw new Error('第二帧炸'); })
            .then(function () {
              fail++;
              console.error('  FAIL - ★★ 第 2 帧抛错必须 reject 掉 run()(实得:promise 正常 settle 了)');
            }, function (err) {
              ok(String(err && err.message).indexOf('第二帧炸') >= 0,
                 '★★ 第 2 帧抛错 → run() 的 promise reject(带原始异常;不是永远悬着)');
            })
            .then(function () {
              // ★★ 上面那条只堵住了"**step 自己**抛"。同一个洞的另一半是"**让出的那一帧**
              //    自己失败":注入的 `nextFrame()` 交回 rejected promise 时,只写
              //    `.then(step)` 的实现既不 resolve 也不 reject —— `step` 一次都不会再被
              //    调到,`run()` 的 promise **永远悬着**(浏览器里就是一条 unhandledrejection
              //    + 调用方 await 到天荒地老)。判据与上面那条同款:必须 reject、带原始异常。
              const dead = Render.createSlicer({ budgetMs: 0, now: function () { return 0; },
                nextFrame: function () { return Promise.reject(new Error('这一帧没等到')); } });
              return dead.run([1, 2, 3], function () {}).then(function () {
                fail++;
                console.error('  FAIL - ★★ 让出那一帧 reject 时也必须 reject 掉 run()(实得:promise 正常 settle 了)');
              }, function (err) {
                ok(String(err && err.message).indexOf('这一帧没等到') >= 0,
                   '★★ nextFrame() 交回 rejected promise → run() 的 promise reject(不是永远悬着)');
              });
            });
        });
      });
    });
  })().then(async function () {
  // ★★ 这个回调是 **async** 的:相位 ⑪ 要 await(mount 的 setView/setMap 是分帧重建,
  //    不 await 就会在"重建还没落地"的状态上做断言)。★ 相位 ⑩(本回调开头那一块)是
  //    **同步** IIFE —— 它没有 await,放这里是合法的;反过来,谁往这个回调里加 await
  //    都必须先确认它在 async 函数里(本文件顶部那段注释记的就是这个坑:await 写在
  //    非 async 函数里,只会在**所有断言跑完之后**抛 `ReferenceError: await is not defined`)。

  // ==== 相位 ⑤ 缩放阈值 / 缩略图刻度 / 适配 ====
  eq(Render.ZOOM_THRESHOLD, 8, '阈值 8 px/子格(规格 §4.2 的分工表)');
  eq(Render.zoomPath(7.9), 'thumb', 'zoomPath: 7.9 → 缩略图');
  eq(Render.zoomPath(8), 'layers', 'zoomPath: 8 → 视口离屏层(阈值是"≥ 8 走后者")');
  eq(Render.clampZoom(0.01), Render.MIN_ZOOM, 'clampZoom: 下限');
  eq(Render.clampZoom(1e9), Render.MAX_ZOOM, 'clampZoom: 上限(用户输入钳制,不报错)');
  eq(Render.thumbScale(500, 300), 2, 'thumbScale: 默认 125×75 图 → 2px/子格');
  eq(Render.thumbScale(1600, 1200), 1, '★ thumbScale: 400×300 格(1600×1200 子格)降到 1px/子格(规格 §4.3 闸 1)');
  eq(Render.fitZoom(500, 300, 1000, 600, 0), 2, 'fitZoom: 1000×600 视口 / 500×300 子格 → 2');
  eq(Render.fitZoom(500, 300, 1000, 600, 50), Render.clampZoom(Math.min(900 / 500, 500 / 300)),
     'fitZoom: 留白从两边扣,取两轴较小者');
  eq(Render.fitZoom(1600, 1200, 100, 100, 0), Render.clampZoom(100 / 1600), '★ fitZoom 不返回 0(否则除法爆)');
  ok(Render.fitZoom(1600, 1200, 100, 100, 0) >= Render.MIN_ZOOM, '★ fitZoom 结果被钳在下限之上');

  // ==== 相位 ⑥ 可见区裁剪与环面 3×3 ====
  (function () {
    const view = { x: 0, y: 0, zoom: 8 };
    eq(Render.visibleSubRange(view, 800, 400, 500, 300), { x0: 0, y0: 0, x1: 100, y1: 50 },
       'visibleSubRange: 800×400 @zoom8 → 100×50 子格(半开)');
    const v2 = { x: -50, y: -10, zoom: 4 };
    eq(Render.visibleSubRange(v2, 800, 400, 500, 300), { x0: -50, y0: -10, x1: 150, y1: 90 },
       '★ visibleSubRange 返回**未折算**的坐标(折算由调用方按格做,3×3 副本要的就是它)');

    eq(Render.torusOffsets({ x: 0, y: 0, zoom: 8 }, 800, 400, 500, 300), [[0, 0]],
       'torusOffsets: 视图在正中 → 只需 1 份(不为接缝做无用功)');
    eq(Render.torusOffsets({ x: -50, y: 0, zoom: 4 }, 800, 400, 500, 300), [[-500, 0], [0, 0]],
       '★ torusOffsets: 视图越过左接缝 → 铺 [-500,0] 与 [0,0] 两份(A4:旧实现只铺 [0,1]、少一侧)');
    eq(Render.torusOffsets({ x: -50, y: -60, zoom: 4 }, 800, 400, 500, 300).length, 4,
       '★ 跨两个方向 = 4 份(3×3 里只保留与视口相交的那些)');
  })();

  // ==== 相位 ⑦ 命中测试(副本上也能落笔 = A4 的另一半)====
  (function () {
    const view = { x: 0, y: 0, zoom: 8 };
    eq(Render.hitTest(view, 800, 400, 500, 300), { X: 100, Y: 50 }, 'hitTest: 屏幕 → 子格坐标');
    eq(Render.hitTest({ x: -1, y: -1, zoom: 8 }, 0, 0, 500, 300), { X: 499, Y: 299 },
       '★ hitTest: 画在接缝另一侧的副本上 → 折回主网格坐标(旧实现副本不可落笔)');
    eq(Render.hitTest(view, 5000 * 8, 0, 500, 300).X, 0, '★ hitTest: 远处也折回 [0, subCols)');
    const back = Render.hitTest(view, -8, 0, 500, 300);
    ok(back.X >= 0 && back.X < 500, 'hitTest: 负的屏幕坐标也落在 [0, subCols) 内');
  })();

  // ==== 相位 ⑧ 画笔几何(规格 §4.4 的吸附规则)====
  (function () {
    eq(Render.brushSpan(1), { unit: 'cell', n: 1 }, 'brushSpan(1) = 1 格');
    eq(Render.brushSpan(3), { unit: 'cell', n: 3 }, 'brushSpan(3) = 3 格');
    eq(Render.brushSpan(15), { unit: 'cell', n: 15 }, 'brushSpan(15) = 15 格(规格的上限)');
    eq(Render.brushSpan(999), { unit: 'cell', n: 15 }, '★ brushSpan(999) 钳到 15(用户输入钳制,不报错)');
    eq(Render.brushSpan(NaN), { unit: 'cell', n: 1 }, '★ brushSpan(NaN) → 1 格(不抛、不产生 NaN 几何)');
    eq(Render.brushSpan(0), { unit: 'cell', n: 1 }, 'brushSpan(0) → 1 格');
    eq(Render.brushSpan(-3), { unit: 'cell', n: 1 }, 'brushSpan(-3) → 1 格');
    eq(Render.brushSpan(0.25), { unit: 'sub', n: 1 }, '★ brushSpan(0.25) = 1 子格');
    eq(Render.brushSpan(0.5), { unit: 'sub', n: 2 }, '★ brushSpan(0.5) = 2 子格');
    eq(Render.brushSpan(0.75), { unit: 'sub', n: 3 }, '★ brushSpan(0.75) = 3 子格');

    eq(Render.brushRegion({ kind: 'cell', x: 3, y: 4 }, 1), { unit: 'cell', x0: 3, y0: 4, x1: 3, y1: 4 },
       'brushRegion: 1 格画笔画一格(整数大小只画整格,不落在子格上)');
    eq(Render.brushRegion({ kind: 'cell', x: 3, y: 4 }, 3), { unit: 'cell', x0: 2, y0: 3, x1: 4, y1: 5 },
       'brushRegion: 3×3 以光标为中心(lo = floor((n-1)/2)、hi = ceil((n-1)/2))');
    eq(Render.brushRegion({ kind: 'sub', x: 5, y: 6 }, 1), { unit: 'sub', x0: 5, y0: 6, x1: 5, y1: 6 },
       'brushRegion: 0.25 画笔盖一个子格');
    eq(Render.brushRegion({ kind: 'sub', x: 5, y: 6 }, 3), { unit: 'sub', x0: 4, y0: 5, x1: 6, y1: 7 },
       'brushRegion: 0.75 画笔盖 3×3 子格');
    // ★ 两种单位的坐标含义不同(格 vs 子格),混用会让画笔大小整体错 4 倍 ——
    //   调用方必须看 unit 再决定是"每格填 16 子格"还是"直接就是子格"。
    // ★★ 断言必须覆盖**整个返回对象**:只判 `.kind` 的话,两个分支只差一个标签也算过 ——
    //   "吸附到格"就成了一句没人验的空话(把 `X:9,Y:10` 的子格号原样当格号传下去,恰好
    //   也满足 `.kind === 'cell'`)。X/Y 也要取**跨格边界**的值,否则 floor(X/SUB) 与
    //   floor(X) 分不出来(9 ÷ 4 = 2 与 9 才分得开)。
    eq(Render.snapHit({ X: 9, Y: 10, zoom: 8, px: 0, py: 0, kind: 'cell' }), { kind: 'cell', x: 2, y: 2 },
       '★★ snapHit: 整数画笔吸附到**格**(X/Y 是子格号 → ÷ ' + Core.SUB_PER_CELL +
       ' 换成格号,不是原样传出去;与 UI 的 hitOf 同一条式子)');
    eq(Render.snapHit({ X: 9, Y: 10, zoom: 8, px: 0, py: 0, kind: 'sub' }), { kind: 'sub', x: 9, y: 10 },
       'snapHit: 小数画笔吸附到子格(当前子格就是命中子格)');
  })();

  // ==== 相位 ⑨ 选区拖动:纯读的偏移查询(B3 / 规格 §4.2)====
  (function () {
    const sel = { x: 4, y: 4, w: 4, h: 4 };
    eq(Render.selectionSource(sel, 2, 0, 6, 5), { hit: true, X: 4, Y: 5 },
       'selectionSource: 目标格 (6,5) 的内容来自源格 (4,5)(drag 只记 dx/dy,渲染时纯读)');
    eq(Render.selectionSource(sel, 2, 0, 4, 4), { hit: false, X: 4, Y: 4 },
       '★ selectionSource: 目标格**不在**偏移后的选区里 → hit:false(源区自己已被腾空)');
    eq(Render.selectionSource(sel, -100, 0, 6, 5).hit, false, '★ 偏移可以很大,查询照样不越界');
    eq(Render.selectionSource(sel, 0, 0, 5, 5), { hit: true, X: 5, Y: 5 }, 'dx=dy=0 时是恒等查询');
    eq(Render.rectUnion({ x: 1, y: 1, w: 2, h: 2 }, { x: 4, y: 0, w: 1, h: 1 }), { x: 1, y: 0, w: 4, h: 3 },
       'rectUnion: 脏区合并(缩略图/离屏层按它重画)');
  })();

  // ==== 相位 ⑩ 脏区与"编辑一格只重画一格"(规格 §4.2 ②③)====
  (function () {
    // ② 的脏区簿记是纯逻辑:编辑 → 脏矩形;切层 → 只合成;平移 → 搬移 + 补边条。
    const d = Render.createDirtySet();
    eq(d.rect(), null, '新脏区集是空的');
    d.addCell(0, 3, 4);
    eq(d.rect(), { x: 12, y: 16, w: 4, h: 4 }, 'addCell(0,3,4) → 子格矩形 (12,16,4,4)');
    d.addCell(0, 5, 4);
    eq(d.rect(), { x: 12, y: 16, w: 12, h: 4 }, '★ 两个格合并成一个包围盒(不是两次重画)');
    d.addCell(2, 0, 0);
    // ★★ 期望值是**计划里的笔误订正**:计划在这一条写的是 `w: 20`(那是 h 的值)。
    //    三个格 (0,3)/(0,5)/(2,0) 的子格并集是 x 0..24、y 0..20 —— 与本节前两条
    //    ((12,16,12,4) 已经把 x 撑到 24)以及相位 ⑨ 钉住的 rectUnion 语义(两轴各取
    //    min/max)一致;`w: 20` 与"addCell(0,5,4) 之后 w = 12"**自相矛盾**(12..24 并上
    //    0..4 不可能只有 20 宽)。按语义取 24(实现不改 —— 改的是这条期望值)。
    eq(d.rect(), { x: 0, y: 0, w: 24, h: 20 }, '★ 跨层也并进同一个盒子(合成时才按层拆)');
    d.clear();
    eq(d.rect(), null, 'clear 之后又空了');
    d.addRect({ x: 1, y: 2, w: 3, h: 4 });
    eq(d.rect(), { x: 1, y: 2, w: 3, h: 4 }, 'addRect: 直接给子格矩形');

    // 平移后的"补边条"几何:画布自拷贝之后只重画新露出来的那一条
    eq(Render.panStrips(800, 600, 10, 0), [{ x: 790, y: 0, w: 10, h: 600 }],
       '★ panStrips: 向右移 10px → 只有右边 10px 需要重画(整块搬移 + 补边条)');
    eq(Render.panStrips(800, 600, 0, -10), [{ x: 0, y: 0, w: 800, h: 10 }],
       '★ panStrips: 向上移 10px → 只有上边 10px');
    eq(Render.panStrips(800, 600, 900, 0), [{ x: 0, y: 0, w: 800, h: 600 }],
       '★ panStrips: 位移超过画布尺寸 → 整块重画(自拷贝已经没有意义)');
    eq(Render.panStrips(800, 600, 0, 0), [], '位移为 0 → 没有要补的边条');

    // 以光标为锚的缩放:光标下的那一子格在缩放前后必须停在原地
    const v0 = { x: 100, y: 50, zoom: 8 };
    const v1 = Render.zoomAround(v0, 400, 300, 2);
    eq(v1.zoom, 16, 'zoomAround: 倍率 2 → zoom 8 → 16');
    const before = { X: v0.x + 400 / v0.zoom, Y: v0.y + 300 / v0.zoom };
    const after = { X: v1.x + 400 / v1.zoom, Y: v1.y + 300 / v1.zoom };
    ok(Math.abs(before.X - after.X) < 1e-9 && Math.abs(before.Y - after.Y) < 1e-9,
       '★★ zoomAround: 光标下的子格缩放前后**不动**(锚点保持,这是"缩放到鼠标位置"的全部含义)');
    const v2 = Render.zoomAround(v0, 400, 300, 1e9);
    ok(v2.zoom <= Render.MAX_ZOOM, '★ zoomAround 也钳在上限(用户输入钳制)');
  })();

  // ==== 相位 ⑪ ② 的离屏层:画布侧(三条路径 / 脏区 / 平移 / 环面 / 闸 2)====
  // ★★ 相位 ⑩ 只钉了**纯逻辑**(脏区集/边条几何/锚点缩放)。这一相位钉的是另一半:
  //    三条路径各自**画的是谁**、编辑一格只重画一格、平移靠自拷贝、环面在 ≥8 那条路上
  //    把接缝另一侧画满、全屏重建真的过了分帧器。★ 它**真的**跑 mount()(三样替身与
  //    相位 ⑩ 同款:document.createElement / 记录型 ctx / 注入的 nextFrame),故必须
  //    自己装一次 document 替身(相位 ⑩ 那次的 finally 已经把它还原了)。
  // ★ 判"哪条路径画了哪张图"一律按**对象身份**(drawImage 的第一个实参),不数次数:
  //   ② 之后主画布上画的是离屏层那张画布,一层画几次与"有内容的格数"完全无关。
  await (async function () {
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
      // 视图越过左接缝时,离屏层读到的是 cx = −1 这样的**负格号**(折算后才是 3。视口
      // x ∈ [−3, 9.5) ⇒ 格 −1,0,1,2 —— 格 3 **只**会以 −1 这个写法被读到)。
      // 键不折算的话同一格会缓存两条,而编辑只 touch 得掉其中一条 ⇒ 接缝另一侧的副本
      // 继续显示陈旧内容(画面错了、一个字都不报)。
      // ★ 先 clear():不然后面那次"未命中"可能来自**上一个视图**留下的条目(那个视图
      //   正好直读过格 3),断言就变成空转(变异实测:不清 = M2 全绿)。
      r.cells().clear();
      await r.setView({ x: -3, y: 0, zoom: 16 });
      const mSeam = r.cells().stats().misses;      // ★ 读 ③ 自己的计数器(stat2 只在 render 里同步)
      r.cells().get(Core.LAYER_SCENE, 3, 0);
      eq(r.cells().stats().misses - mSeam, 0,
         '★★ 同一格在环面下只有**一条**缓存条目(未命中 ' + (r.cells().stats().misses - mSeam) +
         ' 次 ⇒ 键没折算:同一格两条,编辑只作废得掉一条)');

      // ── ⑪c 颜色层:在 ≥8 这条路上也走**颜色分支**(全屏重建 + 脏区重画两条都过)──
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
        // ★ 编辑**格** (0,0):青色在子格 (1,0),它属于格 (0,0)(rgba 数组按**子格**下标,
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

      // ── ⑪d2 ★★ 视图没重建完时**不做**自拷贝搬移(搬移的前提是整张图属于同一次视图)──
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
      // ⑪d2 钉的是"不干净就不搬移"这条**后果**;这一条钉"谁把 layersClean 放下的"。
      // 本方法是**公开入口**(文件尾的导出表里有它),调用方(编辑后整批重建 / Task 8 换贴图源)
      // 完全可能**不**先走 viewChanged() 就进来 —— 那一刻重建已经在飞、离屏层是半旧的,
      // 而 layersClean 若还是 true,panBy 就会拿一张半旧的图自拷贝搬移,脏标记此刻已经清干净
      // ⇒ **永久错位**(谁也补不回来)。故 layersClean 必须在 buildLayers 的**入口**就放下。
      const pc2 = r.stats().panCopies;
      const pRebuild = r.buildLayers();               // 不 await:重建在飞,且**没**走 viewChanged
      await r.panBy(16, 0);
      eq(r.stats().panCopies, pc2,
         '★★ 重建在飞(直接调 buildLayers、没走 viewChanged)时平移**不做**自拷贝搬移' +
         '(实得 ' + pc2 + ' → ' + r.stats().panCopies + ';入口没放下 layersClean 的话这里会 +1)');
      await pRebuild;

      // ── ⑪i ★★ 平移的位移先量化到整像素(view / 边条 / 自拷贝三者同源)──
      // 自拷贝是 drawImage,而插值关掉之后光栅器会把偏移**吸附到整像素**;`s.view` 若按精确值
      // 前进 ⇒ 每次平移最多差 0.5px、而且**会累积**(边条只补"新露出来的那一条",永远不去纠正
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
      // ★★ 判据取**一次纯 buildLayers()** 前后的让出次数:setMap 里那条 rebuild 与缩略图
      //    共用同一座分帧器,拿"setMap 之后 yields > 0"判会**被缩略图那条路蒙过去**
      //    (变异实测:把 buildLayers 改成一次循环画完,那版断言照样全绿)。
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

      // ── ⑪g ★★ 代际守卫:过期那一轮的条带**一项都不画** ──
      // ⑪d2 钉的是它的后果之一(不干净就不搬移);这一条钉守卫**本身**。视图/尺寸/图集一变,
      // 在飞那一轮剩下的条带必须一条都不落笔 —— 否则它会在**新**内容之上再糊一层旧像素,
      // 而 layersClean 此刻已经(或马上会)变成真 ⇒ 画面**永久**错位、没有任何报错。
      // ★ 观测量取 clearRect 的次数:paintLayerRect 每处理一项恰好 clearRect 一次(缺席层那条
      //   分支至多多一次整画布 clearRect)。假画布没有像素,但"这一项落没落笔"它记得下来。
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
    ok(made2.length > 0, '★ ⑪ 的离屏层确实经 document.createElement("canvas") 建出来(' +
       made2.length + ' 张:每层一张 × 每张图)');
  })();

  // ==== 相位 ⑫ ★★ 视图入口的失败必须**看得见**(不能变成一条没人观察的 promise 拒绝)====
  // ★★ 要防的症状(评审发现 1):改图集/换图之后 `tileFor` 会抛(`图集里没有纹理 N`)。
  //    Task 4 **之前** ≥8 那条路是 render() 里的**同步**循环 ⇒ 抛出直接落进 ui.js 的 guard
  //    (同步 try/catch),用户看到 `出错了(...)`。Task 4 **之后**同一个抛出发生在**分帧器的
  //    任务回调**里 ⇒ 它变成 run() 的**拒绝**:guard 接不住,而 render() 这一次根本没执行
  //    ⇒ 画布**默默停在上一帧**、只在控制台留一行错 —— 正是本仓最防的"按了没反应"。
  // ★ 本相位把两条契约**分开**钉:① 屏幕上看得见(经渲染自己的 error sink);② 想 await 的
  //   调用方**照样拿到那次拒绝**(修法只挂观察者:不吞错、也不替换返回的那个 promise)。
  await (async function () {
    const savedDoc2 = globalThis.document;
    const savedEditor = globalThis.Editor;
    const made3 = [];
    globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made3.push(c); return c; } };
    // ★ 页面那条通道就是 ui.js 的 status()(= 状态栏 #status-msg);这里换成一个记账替身。
    //   node 里本来没有 globalThis.Editor(ui.js 不在场),所以这也顺带钉住了"渲染是**运行时**
    //   找那条通道、不在模块顶层引 ui.js"。
    const seen = [];
    globalThis.Editor = { status: function (t) { seen.push(String(t)); } };
    const SLICE2 = { slicer: { nextFrame: function () { return Promise.resolve(); } } };
    // ★ 本相位**故意**触发两次真实抛错,而默认 sink 除了写状态栏还会 `console.error`(那是
    //   调试轨迹,不是测试失败)—— 但它会把"stderr 0 字节"这条验收指标弄脏。⇒ 局部接住
    //   console.error,收尾时**只**把测试自己那几行 FAIL 回放到真 stderr(不回放 = 本相位里的
    //   失败会被静默吞掉,而计数照样红 —— 一条没有消息的 FAIL)。
    const realConsoleError = console.error;
    const errLines = [];
    console.error = function () {
      errLines.push(Array.prototype.map.call(arguments, String).join(' '));
    };
    try {
      // ★ 图集必须是**确定的那一张**:默认 backend 在 node 里会抛 `Tint: 本环境没有 document`
      //   —— 那样"抛了"虽然也成立,却钉不住是哪条路在抛、报的是哪个原因。
      Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H, { backend: spyBackend() });
      const badMap = Core.createMap('bad', 2, 2);                    // 8×8 子格
      fillSub(badMap, Core.LAYER_BG, 0);
      fillSub(badMap, Core.LAYER_SCENE, 0);
      badMap.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(99); // ★ 图集只有 3×10 = 30 块
      const cvB = fakeCanvas(200, 200);
      const rB = Render.mount(cvB, SLICE2);
      // 缩略图那条路(< 8)同样会抛 —— 那一条由 ui.js 的 guard(同步 try/catch)兜住,这里先吃掉。
      await rB.setMap(badMap).catch(function () {});
      seen.length = 0;
      let rej = null;
      const p = rB.setView({ x: 0, y: 0, zoom: 16 });                 // ≥ 8 ⇒ 走到 tileFor 的抛错
      ok(!!p && typeof p.then === 'function',
         '⑫ 前提:setView 在 ≥ 8 这条路上返回分帧重建的 promise(实得 ' +
         (p === undefined ? 'undefined' : typeof p) + ')');
      await p.then(function () {}, function (e) { rej = e; });
      ok(rej !== null,
         '★★ 视图入口返回的那个 promise **仍然拒绝**(实得 ' + (rej ? 'rejected' : 'fulfilled') +
         '):修法只给它挂了一个观察者 —— 没吞错、没替换返回对象,想 await / 想自己 catch 的调用方照旧拿得到');
      eq(seen.length, 1,
         '★★ 同一次失败**在屏幕上看得见**:经渲染自己的 error sink(= ui.js 那条状态栏通道)' +
         '报了 1 条。修之前这里是 0 —— 那是一条没人观察的拒绝,画布默默停在上一帧');
      const msg = rej ? String(rej.message) : '';
      ok(seen.length === 1 && seen[0].indexOf('出错了(setView)') === 0 && msg !== '' &&
         seen[0].indexOf(msg) >= 0,
         '★★ 那条消息**指名道姓**:以 `出错了(setView)` 开头、并把抛出原因带上(' + msg +
         ')—— 不是一条泛泛的"未处理的 promise 拒绝"(实得 ' + JSON.stringify(seen[0]) + ')');
      // ★ 接口增补:报错通道**可换**(页面/探针接自己的日志 / 断言)。换掉之后默认那条就不该再收到。
      const alt = [];
      rB.setErrorSink(function (t) { alt.push(String(t)); });
      seen.length = 0;
      await rB.setView({ x: 0, y: 0, zoom: 16 }).catch(function () {});
      eq([seen.length, alt.length], [0, 1],
         '★ setErrorSink 换掉了报错通道(默认那条收到 0 条 / 换上的收到 1 条)');
      ok(errLines.some(function (l) { return l.indexOf('出错了(setView)') === 0; }),
         '默认 sink 除了写页面的那条通道,也把原因写进了 console.error(调试轨迹留着,' +
         '共 ' + errLines.length + ' 行)');
    } finally {
      globalThis.document = savedDoc2;
      globalThis.Editor = savedEditor;
      // 还原图集(与相位 ② 末尾同款):别把"带替身 backend 的那张"留给下一位。
      Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H);
      console.error = realConsoleError;
      for (let i = 0; i < errLines.length; i++) {
        if (errLines[i].indexOf('  FAIL - ') === 0) realConsoleError(errLines[i]);
      }
    }
    ok(made3.length > 0, '★ ⑫ 的离屏层确实经 document.createElement("canvas") 建出来(' +
       made3.length + ' 张)');
  })();

  // ==== 相位 ⑬ ★★ 拖动预览:三种目标格 / 环面折算 / **去烤**(评审发现 1、2、5、6)====
  // ★ 这条链(Task 7 的 `dragSource` 一族)此前**零覆盖**,而它正是 D6 的全部内容:
  //   `paintLayerRect` 的纹理分支在"拖动中"改用**源格**的 `cellCache.get`(③ 的键替换)。
  //   故这里在**纹理层 + 真图集**上按 tile 的**对象身份**逐子格判三种情形:
  //     ① 目标格读**源格**的内容;② 被腾空的源区**一个子格都不画**;③ 源∪目标之外原样不动。
  // ★ 另两件只有"真的画一遍并记账"才看得见:
  //   · 拖动跨过接缝时预览读的是**哪一格**(评审发现 2:非折算的查询会让预览与落笔分岔);
  //   · 偏移一变 / 清除时「源 ∪ 目标」必须被**重画**(评审发现 1:烤进 ② 的偏移内容若不
  //     重画,会在更早的偏移上**永远留着** —— 提交只按最终偏移结算)。
  // ★ 替身与相位 ⑩/⑪/⑫ 同款(document.createElement / 记录型 ctx / 注入的 nextFrame),
  //   图集必须**带替身 backend** 重设一次:相位 ⑫ 收尾时还原的是**默认** backend(它走
  //   ImageData,node 里没有)⇒ 本相位里任何一次 tileFor 都会抛。
  await (async function () {
    Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H, { backend: spyBackend() });
    const savedDocD = globalThis.document;
    const made4 = [];
    globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made4.push(c); return c; } };
    const SLICE_D = { slicer: { nextFrame: function () { return Promise.resolve(); } } };
    try {
      const SB = Core.SUB_PER_CELL;
      const ZD = 16;                                        // 子格 → 像素(视图在 x=y=0)
      // 6×3 格(24×12 子格):格 (1,1) = A(纹理 5)、格 (4,1) = B(纹理 9),其余格是空气。
      // ★ 逐**子格**填满整格(setCells 那种"一格一个子格"在这里不够:断言要逐 16 个子格比)。
      const mD = Core.createMap('d6', 6, 3);
      const fillCell = function (L, cx, cy, desc) {
        const a = mD.layers[L].desc;
        for (let qy = 0; qy < SB; qy++) {
          for (let qx = 0; qx < SB; qx++) a[(cy * SB + qy) * mD.subCols + (cx * SB + qx)] = desc;
        }
      };
      fillCell(Core.LAYER_SCENE, 1, 1, Core.neutralDesc(5));       // A
      fillCell(Core.LAYER_SCENE, 4, 1, Core.neutralDesc(9));       // B
      // ★★ 后景层也放一格(**就在选区里**):它是"其余层不吃偏移"那条断言的探针 ——
      //    只有非活动层上**有内容**时,"它没动"才判得出来(空层的像素本来就没有)。
      fillCell(Core.LAYER_BACK, 4, 1, Core.neutralDesc(12));       // B2
      const cvD = fakeCanvas(640, 400);                          // 24×12 子格在 zoom 16 下一屏装得下
      const sinceD = made4.length;
      const rD = Render.mount(cvD, SLICE_D);
      await rD.setMap(mD);
      const offsAll = layerCanvasesSince(made4, sinceD, 640, 400);   // 下标 = 层号(见该助手)
      const offD = offsAll[Core.LAYER_SCENE];
      ok(!!offD, '⑬ 前提:纹理层的离屏层建出来了(尺寸 = 主画布)');
      // ★★ 前提:"四层都在"必须连**下标 = 层号**这条约定一起钉住,而旧写法
      //    `offsAll.length === LAYER_COUNT && offsAll[LAYER_SCENE] === offD` 是**半句同义反复**:
      //    `offD` 就是从 `offsAll` 里取出来的那一个,后半句恒真 ⇒ 实际只判了长度。
      //    索引与层号一旦错位(`ensureLayerCanvas` 的创建顺序变了),它**照样全绿**,而下面
      //    "其余层不动 / 后景层留在原地 / 缺席层不进去烤"全都判在**错的画布**上。
      // ★ 判据改用一条**独立**的证据 —— 合成顺序里的对象身份:`drawLayerPath` 按
      //    DRAW_ORDER = [背景, 后景, 场景, 前景] 逐层 drawImage ⇒ 主画布上**首次出现的
      //    四个不同画布**,按顺序就该是 3,2,1,0 号层的离屏层。这条与 made4 的创建顺序
      //    无关,故"下标 = 层号"是被**另一条链**验证的,不再是同义反复。
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

      // 这一格画的是不是**这些** tile:16 个子格逐个按**对象身份**比(位置 = 子格号 × zoom)
      const drawnOps = function (off) {
        return off.ctx.ops.filter(function (o) { return o.op === 'drawImage'; });
      };
      const subPx = function (sx, sy) { return { x: sx * ZD, y: sy * ZD }; };
      const cellMatches = function (off, cx, cy, tiles) {
        for (let k = 0; k < SB * SB; k++) {
          const p = subPx(cx * SB + (k % SB), cy * SB + Math.floor(k / SB));
          const got = drawnOps(off).filter(function (o) { return o.x === p.x && o.y === p.y; });
          // ★ 同一格**允许多次落笔**,但每一笔都必须是**这一张** tile:② 的条带按**格**迭代,
          //   而一格(4 个子格行)常常跨两条带 ⇒ 相邻条带各画它一次(像素上幂等 —— 同一张图
          //   画在同一处)。判"画的**是不是**这张"才是这条断言的全部内容,"画几次"不是。
          if (got.length < 1 || !got.every(function (o) { return o.img === tiles[k]; })) return false;
        }
        return true;
      };
      const cellAnyDraw = function (off, cx, cy) {
        for (let k = 0; k < SB * SB; k++) {
          const p = subPx(cx * SB + (k % SB), cy * SB + Math.floor(k / SB));
          if (drawnOps(off).some(function (o) { return o.x === p.x && o.y === p.y; })) return true;
        }
        return false;
      };

      // ★★ 拖动**必须锚在一份选区上**(本相位所有拖动步骤的共用前提):生产里 pointerdown
      //    只在"按在选区里"时才起拖动(ui.js),故 `s.selection`(已提交的选区)与
      //    `s.selDrag.sel`(拖动锚着的那份)**从不分叉**。而 `dragSource` 的早退现在含
      //    `!s.selection`(选区被取消 ⇒ 偏移不再生效 —— 少了它,Esc 之后内容会留在偏移上)。
      //    ⇒ 替身这边要自己满足这个前提:只调 setSelDrag 而不先设选区 = **生产到不了的状态**,
      //    偏移根本不会生效(整段预览断言都会红,而那是**前提**不成立,不是功能坏了)。
      //    ★ 两步的顺序照生产:先有选区,再起/改拖动。
      //    ★ 选区**已经在同一个矩形上**时不再调 setSelection:那会多出一次去烤重画,把
      //      「改偏移恰好重画一次」这类记账断言搅乱(量到的会是 2)。这一步只在**本渲染器
      //      第一次**拖动时落地,之后各步与旧口径逐字相同。
      const dragOn = function (rr, sel, dx, dy) {
        const cur = rr.selection();
        if (!cur || cur.x !== sel.x || cur.y !== sel.y || cur.w !== sel.w || cur.h !== sel.h) {
          rr.setSelection(sel);
        }
        rr.setSelDrag(sel, dx, dy);
      };

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
      // ★ 这一批用**整片重建**逼出重画(而不是靠 setSelDrag 的去烤):三条断言的证据要**只**
      //   来自 `dragSource` —— 去烤那条路坏了不该让它们跟着红(两件事的变异归属要分得开)。
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
      // ★★★ (d) **其余层在整片重建里也不吃偏移**:`buildLayers` 会重画**四层**(与去烤那条
      //    路不同 —— 那里只有活动层被重画),所以"偏移只算活动层"这条判据必须**同时**住在
      //    `dragSource` 里。★ 这条断言是靠变异补上的:只把 `dragSource` 的层判据删掉时,
      //    去烤那几条**全绿**(它们只看活动层),而 BACK 层的内容会被搬到目标格。
      //    探针 = 后景层格 (4,1) 的 B2:它必须**留在原地**,目标格 (0,1) 必须**空**。
      const tB2 = rD.cells().get(Core.LAYER_BACK, 4, 1);
      ok(tB2.every(Boolean) && cellMatches(offsAll[Core.LAYER_BACK], 4, 1, tB2) &&
         !cellAnyDraw(offsAll[Core.LAYER_BACK], 0, 1),
         '★★★ (d) 拖动中的**整片重建**里,非活动层(后景)的内容留在原地:格 (4,1) 画的还是' +
         '它自己的 B2、目标格 (0,1) 空着。偏移只算活动层 —— 少了这条,四层的内容都会跟手、' +
         '松手又弹回去(预览 ≠ 落笔;而落笔 `moveRegion` 只搬活动层)');

      // ── ⑬b ★★ 去烤 + **只有活动层**:偏移一变就必须把「上一次的 源∪目标」在那**一层**上
      //    逐块重画(其余三层一个像素都不许碰 —— 落笔 `moveRegion` 也只搬活动层)──
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
      // ★★ 同一块**不重复画**(Minor):源格 (4,1) 在这次偏移里是源、在上一次偏移里**也是源**
      //    (选区没变 ⇒ 源块必然同时落在「当前偏移的源∪目标」与「上一次那两块」里)⇒ 两组
      //    直接 concat 会把它画两遍。旧实现取 `rectUnion` 的包围盒,顺带把重复"吃掉"了 ——
      //    改成逐块之后这份去重得自己补上(四元组判等,见 `dedupRects`)。
      // ★ 判据取**块数恰好 3**(源格 4 / 新目标格 5 / 上一次的目标格 0):不去重是 4。
      //   它与上面两条都不同面 —— 上面两条判"哪些块被画了",这条判"有没有一块被画两遍"。
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

      // ── ⑬b2 ★★ 接缝:源与目标分居图的两头时**逐块**重画,而不是取包围盒(闸 2)──
      // ★ 这一条钉的是**成本**,不是像素正确性:取包围盒在画面上看不出区别(多画的那几格
      //   画的本来就是它们自己的内容),但它在高倍 + 大选区下每次 pointermove 都要付一整行
      //   (最坏一整幅图)的 clearRect + 每层数千次 drawImage —— 而这条路径**没有**走
      //   createSlicer(去烤是同步的),闸 2 的单帧预算就是这么破的。
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

      // ── ⑬c ★★ 拖动途中切层(数字键 1-4 在拖动时照样按得下去):偏移只跟**活动层**走 ──
      // ★ 判据分三段:① 拖在场景层上 ⇒ 只有它动;② 切到后景层 ⇒ 偏移**烤到后景层**、
      //   而场景层上那批必须**擦掉**(它现在读到的是"没拖过"的内容 —— dragSource 只认活动层);
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

      // ── ⑬c2 ★ 缺席层(`map.layers[L] === null`)不进去烤名单 ──
      // ★ flushDirty 对缺席层走的是"整张画布 clearRect"那条路,而拖动中每帧都要走一遍
      //   ⇒ 每帧白付一次全屏清屏(它一个像素都没有,没有"偏移内容"可擦),而且**不计数**
      //   (layerRebuilds 只数 paintLayerRect 那一条——正是闸 2 要避免的那种看不见的成本)。
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

      // ── ⑬e ★★ ① 缩略图那条路(< 8px/子格)同样去烤(评审发现 1 的另一条路)──
      // ★ 它在**今天**只有一个入口:`invalidateAll`(→ buildThumbs)或 `invalidateCells` ——
      //   而"撤销/重做一条 kind='whole' 的差量"就会走 invalidateAll,而 Ctrl+Z 在按住左键
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

      // ── ⑬f ★★ 颜色层的拖动:同一个 dragSource,但这条分支传进去的是**子格**坐标 ──
      // ★ 它可能是**负的**(视图越过左侧接缝时 cx = −1 ⇒ Xc = −4),全靠 `wrapIdx` 折回来。
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
      // ★★ 必须先切到**背景层**再拖:偏移只烤在活动层上(与落笔 `moveRegion` 同口径),
      //   而 mount 的默认活动层是场景层 —— 这条红在 BG 上,不切层的话它**根本不该动**
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
      // ★ "选区为空而 selDrag 还在"是**真到得了**的状态(Esc 走 cancel-selection,而左键
      //   还按着)。今天挡住这次读的是**外层**那句 `if (s.selection)`(不是 drawOverlay 里
      //   的那一行)⇒ 下面两条钉的是**不变量**本身:
      //     ① 这个状态下 render() 不抛(外层判据哪天被放松、而块内照旧读 `s.selection.x`,
      //        这条会红 —— 那是每帧一次 TypeError、画布整个停住);
      //     ② 选区为空时**不画**那个拖动框(框是"选区"的视觉,没有选区就没有框)。
      //   ★ 别把 ① 读成"review 说的 TypeError 今天在场上":实测把块内换回 `s.selection`
      //     (保留外层判据)照样全绿 —— 机制到不了这里,false positive 已写进报告。
      //     ③ ★★ 而且**取消选区那一刻内容就该归位**(见下第 ③ 条断言)。
      //     ★★ ③ 的判据必须落在**内容**上(逐子格比 tile),不能是"哪一块被重画过":
      //        "重画过"这件事在**旧实现**里同样成立 —— 去烤重画的偏移来源是 `s.selDrag`
      //        (它此刻还在),画的还是**同一份偏移**,像素与重画前逐字节相同 ⇒
      //        `clearRect(5*SB*ZD, …) 存在`这类断言**恒真**,它只证明"setSelection 调过
      //        markDragDirty",证不了内容归位(旧写法就是那样,两种实现都放行)。
      //        换成"源格 (4,1) 画回**它自己**的 tile、偏移目标格 (5,1) 一格都不画"之后:
      //        旧实现下这两半**同时**红(源格继续空着、目标格继续是 tB)。
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

      // ── ⑬i ★★★ 去烤的**代价形状**:只重画**当前那条路**那份数据(终审评审发现 I1)──
      // ★ 背景:①(缩略图)与 ②(视口离屏层)是**两份**数据,同一时刻只有一份在屏幕上,
      //   而两条路的成本形状**恰好相反** ——
      //     · ② 的成本 = "与画布相交的格"数 × 每格 16 次 drawImage,**低倍时最大**(整幅图都
      //       可能落在画布内),而低倍走的正是 ① 那条路 ⇒ 那份活一个字都看不见;
      //     · ① 的成本 = 选区面积 × 缩略图刻度(与缩放无关),高倍时同样看不见。
      // ★★ 判据取**读数**(不是"块宽 ≤ 1 格"那种代理):把一次 pointermove 在两条路上各自产生
      //   的 op 数出来,并断言**另一条路一个 op 都没有**、当前那条路的活**有界**(有界在那里
      //   才说明它没在替整幅图干活)。数字直接印在断言里 —— 这就是"每次 pointermove 付多少"
      //   的量化口径(变异:把 repaintDrag 的路径分派删掉 ⇒ 两条"另一条路 0 个 op"当场红)。
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
      // 先把 ② 建出来(≥8 那条路),再回到 ① 那条路 —— 断言要判的是"另一条路**没被动过**",
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
      // 换到 ① 那条路(< 8):这一次**只许碰 ①**。② 的四张画布一个 op 都不许涨 ——
      // 那正是评审发现 I1 量到的那笔(低倍时 ② 的活最大,却一个字都看不见)。
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
    ok(made4.length > 0, '★ ⑬ 的离屏层确实经 document.createElement("canvas") 建出来(' +
       made4.length + ' 张)');
  })();

  }).then(function () {
  console.log('');
  console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
  if (fail === 0) console.log('RENDER SMOKE OK');
  process.exit(fail === 0 ? 0 : 1);
  });
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
