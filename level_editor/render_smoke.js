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

(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 某个断言挂住了(分帧器的 nextFrame 没被注入?)');
    process.exit(1);
  }, 120000);

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
    throws(function () { Render.setAtlas(new Uint8ClampedArray(7), 8, 1, { backend: be }); },
           '★ setAtlas 传形状不合法的图集(7 字节不是整行 8×4) → 抛错,不静默画一片透明', '不是整行');
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

      const one = Render.createSlicer({ budgetMs: 0, now: function () { return clock.t; },
                                        nextFrame: function () { clock.t += 1; return Promise.resolve(); } });
      return one.run([1, 2, 3], function () {}).then(function (r2) {
        eq(r2.processed, 3, '★ budgetMs = 0:每帧至少做一项,3 项照样全部做完(不是死循环)');
        eq(r2.frames, 2, 'budgetMs = 0 → 每帧一项,3 项让出 2 次');
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
    eq(Render.snapHit({ X: 9, Y: 10, zoom: 8, px: 0, py: 0, kind: 'cell' }).kind, 'cell',
       'snapHit: 整数画笔吸附到格');
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
