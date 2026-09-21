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
      ops.push({ op: 'drawImage', alpha: this.globalAlpha, x: x, y: y, w: w, h: h });
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
      r1.setView({ x: 0, y: 0, zoom: 4 });
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
      rR.setView({ x: 0, y: 0, zoom: 9999 });
      eq(rR.view().zoom, Render.MAX_ZOOM, '★ setView 的缩放被钳到 MAX_ZOOM(用户输入钳制,不报错)');
      rR.setView({ x: 0, y: 0, zoom: -5 });
      eq(rR.view().zoom, Render.MIN_ZOOM, '★ 负缩放的钳到 MIN_ZOOM');
      rR.setView({ x: 0, y: 0, zoom: NaN });
      eq(rR.view().zoom, Render.MIN_ZOOM, '★ NaN 缩放也钳到 MIN_ZOOM(NaN 不报错地毁掉整张画布)');
      await rR.setMap(m1);
      rR.setView({ x: 99, y: 99, zoom: 32 });
      rR.fit();
      ok(rR.view().x < 0 && rR.view().y < 0 && rR.view().x > -4 && rR.view().y > -4,
         'fit() 把地图居中(视图原点落在 −2/−1.5 这种小负数上:CSS 的 0 点不是左上角)');

      // ── ⑩d ≥ 8px/子格:逐子格路径 + 环面副本 ──
      cv1.ctx.ops.length = 0;
      r1.setView({ x: 0, y: 0, zoom: 16 });
      ok(countOps(cv1.ctx, 'op', 'drawImage') > 0,
         '★ ≥ 8px/子格 换逐子格路径(每格一次 drawImage,Task 4 才换成 ② + ③ + 脏区)');
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
      // ★★ 副本坐标必须折回主网格再读:视口左边缘越过接缝时,另一侧的副本上要**照样有内容**
      cv1.ctx.ops.length = 0;
      r1.setView({ x: -3, y: 0, zoom: 16 });
      const acrossSeam = countOps(cv1.ctx, 'op', 'drawImage');
      cv1.ctx.ops.length = 0;
      r1.setTorus(false);
      const noTorus = countOps(cv1.ctx, 'op', 'drawImage');
      r1.setTorus(true);
      eq([acrossSeam, noTorus], [4, 2],
         '★★ 跨接缝时副本上有内容(贴着右边界的 14/15 子格):环面开 4 次绘制、关 2 次' +
         '(实得 ' + acrossSeam + ' / ' + noTorus + ')');
      const hs = r1.screenToSub(0, 0);
      ok(hs.X >= 0 && hs.X < m1.subCols && hs.Y >= 0 && hs.Y < m1.subRows,
         '★ screenToSub 在副本上也折回 [0, subCols)(A4:副本上能落笔)');

      // ── ⑩e 两条方向的坐标换算互为逆 ──
      r1.setView({ x: 3, y: 2, zoom: 16 });
      const s2 = r1.subToScreen(5, 6);
      eq(s2, { x: (5 - 3) * 16, y: (6 - 2) * 16 }, 'subToScreen: 世界 → 屏幕(相对视图原点)');
      eq(r1.screenToSub(s2.x + 1, s2.y + 1), { X: 5, Y: 6 },
         '★★ screenToSub(subToScreen(X,Y)) 回到 (X,Y):两条方向互为逆(错一个整支画笔偏到别处)');
      ok(r1.screenToSub(-1000, -1000).X >= 0, '★ 负的屏幕坐标也折回 [0, subCols)(环面世界里这是常态)');

      // ── ⑩f 层可见性 / 压暗 / 选区框 ──
      cv1.ctx.ops.length = 0;
      r1.setLayerVisible(Core.LAYER_SCENE, false);
      const hidden = countOps(cv1.ctx, 'op', 'drawImage');
      cv1.ctx.ops.length = 0;
      r1.setLayerVisible(Core.LAYER_SCENE, true);
      const shown = countOps(cv1.ctx, 'op', 'drawImage');
      eq([hidden, shown > 0], [0, true], '★ 层可见性闸真的拦住了绘制(隐藏 0 次 / 打开 ' + shown + ' 次)');
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
      await rBg.setMap(bgMap);
      const thumbBg = rBg.thumbCanvas(Core.LAYER_BG);
      const origTexOf = Core.texOf;
      const texOfArgs = [];
      Core.texOf = function (d) { texOfArgs.push(d >>> 0); return origTexOf(d); };
      let bgThrew = null;
      try {
        cvBg.ctx.ops.length = 0;
        rBg.setView({ x: 0, y: 0, zoom: 16 });           // ≥ 8 ⇒ 逐子格路径(另一条是缩略图)
        await rBg.invalidateAll();                       // 顺手把 ① 缩略图整片重画(两条路径都过一遍)
      } catch (e) { bgThrew = e; } finally { Core.texOf = origTexOf; }
      ok(bgThrew === null, '★★ 不透明青背景(#00FFFFFF,纹理位域 = 4095)渲染不抛异常(' +
         (bgThrew ? String(bgThrew.message) : '无异常') + ')');
      eq(texOfArgs.length, 0,
         '★★ 背景层的 RGBA 一个都没进 Core.texOf(实得 ' + texOfArgs.length + ' 次):' +
         'RGBA 与描述符长得一样、含义完全不同,按层种类分派才是唯一正确的读法');
      ok(countOps(cvBg.ctx, 'style', 'rgba(255,0,0,1)') > 0,
         '★★ 不透明红背景**画出来了**(fillRect rgba(255,0,0,1))—— 它的纹理位域是 0,' +
         '按"空气"判会整层不可见(静默)');
      ok(countOps(cvBg.ctx, 'style', 'rgba(0,255,255,1)') > 0,
         '★★ 不透明青背景也画出来了(rgba(0,255,255,1) = cssOfRGBA 的 0xRRGGBBAA 次序)');
      ok(!someOp(cvBg.ctx, function (o) { return o.style === 'rgba(255,0,0,0)'; }),
         '★ alpha = 0 的格**不画**全透明色块(画了 = 把下面的像素改成"什么都没画",而缩略图上' +
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
      rSp.setView({ x: 0, y: 0, zoom: 16 });
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
    const c3 = Render.createCellCache({
      maxCells: 4,
      build: function (L, cx, cy) { built++; return { L: L, cx: cx, cy: cy, n: built }; },
    });
    eq(Render.cellCache(), null, 'createCellCache 本身**不**改模块状态(装上要走 attachCells)');
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
  })().then(function () {

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
