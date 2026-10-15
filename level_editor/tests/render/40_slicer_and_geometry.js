'use strict';
// tests/render/40_slicer_and_geometry.js —— ③c 换图连 ①② 一起作废 / ④ 闸 2 分帧器 / ⑤~⑨ 缩放·裁剪·命中·画笔·选区 / 脏区集。
globalThis.renderChain = globalThis.renderChain.then(async function () {
const Core = globalThis.Core;
const Render = globalThis.Render;
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
  await (async function () {
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

      // ★ 预算必须是有限的数:now() - s0 >= NaN 与 >= 负数 都恒为 false ⇒ while
      //   会一口气做完整批(正是闸 2 要防的那件事),而且不报错 —— 分帧器装了等于没装。
      eq(Render.createSlicer({ budgetMs: -5 }).budgetMs, 0, '★ budgetMs: 负数 → 钳到 0(不是负数)');
      eq(Render.createSlicer({ budgetMs: Infinity }).budgetMs, Render.DEFAULT_BUDGET_MS,
         '★ budgetMs: Infinity → 回落默认预算(判的是"有限",不是"非负就行")');

      const one = Render.createSlicer({ budgetMs: 0, now: function () { return clock.t; },
                                        nextFrame: function () { clock.t += 1; return Promise.resolve(); } });
      return one.run([1, 2, 3], function () {}).then(function (r2) {
        eq(r2.processed, 3, '★ budgetMs = 0:每帧至少做一项,3 项照样全部做完(不是死循环)');
        eq(r2.frames, 2, 'budgetMs = 0 → 每帧一项,3 项让出 2 次');

        // ★★ 行为面(不只是读回那个数):NaN 预算真的按默认预算分帧。不回落的话
        //    frames 是 0、maxStepMs 是 100(一口气做完整批)—— 两条断言各看一面。
        const clockN = { t: 0 };
        const nanSlicer = Render.createSlicer({ budgetMs: NaN,
          now: function () { return clockN.t; },
          nextFrame: function () { clockN.t += 20; return Promise.resolve(); } });
        return nanSlicer.run(items, function () { clockN.t += 1; }).then(async function (r3) {
          eq(r3.frames, 12, '★★ NaN 预算的行为与默认预算**一致**(12 帧;不回落 = 0 帧,一口气做完整批)');
          eq(r3.maxStepMs, Render.DEFAULT_BUDGET_MS, '★★ NaN 预算下单帧仍守默认预算(不回落 = 100ms)');

          // ★★ 第 2 帧抛错必须让 run() 的 promise reject。只测第 1 帧抛是区分不了的:
          //    那时 step 还在 promise 执行器里同步跑,执行器本来就会接住;真正会漏的是
          //    "让出一帧之后"那条 —— 从第 2 帧起 step 跑在 nextFrame().then(step) 这条
          //    没人观察的链上,裸抛 = unhandled rejection,run() 的 promise 于是永远
          const boom = Render.createSlicer({ budgetMs: 0, now: function () { return 0; },
                                             nextFrame: function () { return Promise.resolve(); } });
          await rejects(function () {
            return boom.run([1, 2, 3], function (it) { if (it === 2) throw new Error('第二帧炸'); });
          }, '★★ 第 2 帧抛错 → run() 的 promise reject(带原始异常;不是永远悬着)', '第二帧炸');
          const dead = Render.createSlicer({ budgetMs: 0, now: function () { return 0; },
            nextFrame: function () { return Promise.reject(new Error('这一帧没等到')); } });
          await rejects(function () { return dead.run([1, 2, 3], function () {}); },
            '★★ nextFrame() 交回 rejected promise → run() 的 promise reject(不是永远悬着)', '这一帧没等到');
        });
      });
    });
  })();
  // ==== 相位 ⑤ 缩放阈值 / 缩略图刻度 / 适配 ====
  eq(Render.zoomPath(7.9), 'thumb', 'zoomPath: 7.9 → 缩略图');
  eq(Render.zoomPath(8), 'layers', 'zoomPath: 8 → 视口离屏层(阈值是"≥ 8 走后者")');
  eq(Render.clampZoom(0.01), Render.MIN_ZOOM, 'clampZoom: 下限');
  eq(Render.clampZoom(1e9), Render.MAX_ZOOM, 'clampZoom: 上限(用户输入钳制,不报错)');
  eq(Render.thumbScale(500, 300), 2, 'thumbScale: 默认 125×75 图 → 2px/子格');
  eq(Render.thumbScale(1600, 1200), 1, '★ thumbScale: 400×300 格(1600×1200 子格)降到 1px/子格(规格 §4.3 闸 1)');
  tableEq('fitZoom:取两轴较小者、留白从两边扣、永不返回 0(否则除法爆)', [
    ['1000×600 视口 / 500×300 子格 → 2', Render.fitZoom(500, 300, 1000, 600, 0), 2],
    ['留白 50 从两边扣', Render.fitZoom(500, 300, 1000, 600, 50), Render.clampZoom(Math.min(900 / 500, 500 / 300))],
    ['大图小视口 → 按比例(不是 0)', Render.fitZoom(1600, 1200, 100, 100, 0), Render.clampZoom(100 / 1600)],
    ['结果被钳在 MIN_ZOOM 之上', Render.fitZoom(1600, 1200, 100, 100, 0) >= Render.MIN_ZOOM, true],
  ]);

  // ==== 相位 ⑥ 可见区裁剪与环面 3×3 ====
  (function () {
    const view = { x: 0, y: 0, zoom: 8 };
    eq(Render.visibleSubRange(view, 800, 400, 500, 300), { x0: 0, y0: 0, x1: 100, y1: 50 },
       'visibleSubRange: 800×400 @zoom8 → 100×50 子格(半开)');
    const v2 = { x: -50, y: -10, zoom: 4 };
    eq(Render.visibleSubRange(v2, 800, 400, 500, 300), { x0: -50, y0: -10, x1: 150, y1: 90 },
       '★ visibleSubRange 返回**未折算**的坐标(折算由调用方按格做,3×3 副本要的就是它)');

    tableEq('torusOffsets:只铺与视口相交的那几份(A4:旧实现少铺一侧)', [
      ['视图在正中 → 1 份(不为接缝做无用功)', Render.torusOffsets({ x: 0, y: 0, zoom: 8 }, 800, 400, 500, 300), [[0, 0]]],
      ['越过左接缝 → [-500,0] 与 [0,0] 两份', Render.torusOffsets({ x: -50, y: 0, zoom: 4 }, 800, 400, 500, 300), [[-500, 0], [0, 0]]],
      ['跨两个方向 → 4 份', Render.torusOffsets({ x: -50, y: -60, zoom: 4 }, 800, 400, 500, 300).length, 4],
    ]);
  })();

  // ==== 相位 ⑦ 命中测试(副本上也能落笔 = A4 的另一半)====
  (function () {
    const view = { x: 0, y: 0, zoom: 8 };
    tableEq('hitTest:屏幕 → 子格坐标,且一律折回主网格(副本上也能落笔 = A4 的另一半)', [
      ['屏幕 → 子格坐标', Render.hitTest(view, 800, 400, 500, 300), { X: 100, Y: 50 }],
      ['画在接缝另一侧的副本上 → 折回主网格', Render.hitTest({ x: -1, y: -1, zoom: 8 }, 0, 0, 500, 300), { X: 499, Y: 299 }],
      ['远处也折回 [0, subCols)', Render.hitTest(view, 5000 * 8, 0, 500, 300).X, 0],
      ['负的屏幕坐标也落在 [0, subCols) 内', (function () { const b = Render.hitTest(view, -8, 0, 500, 300); return b.X >= 0 && b.X < 500; })(), true],
    ]);
  })();

  // ==== 相位 ⑧ 画笔几何(规格 §4.4 的吸附规则)====
  (function () {
    eq([Render.brushSpan(1), Render.brushSpan(3), Render.brushSpan(15), Render.brushSpan(999),
        Render.brushSpan(NaN), Render.brushSpan(0), Render.brushSpan(-3)],
       [{ unit: 'cell', n: 1 }, { unit: 'cell', n: 3 }, { unit: 'cell', n: 15 }, { unit: 'cell', n: 15 },
        { unit: 'cell', n: 1 }, { unit: 'cell', n: 1 }, { unit: 'cell', n: 1 }],
       'brushSpan: 整数画笔吸附到格、上限 15;NaN / 0 / 负数一律回落 1 格(钳制,不抛、不产生 NaN 几何)');
    eq([Render.brushSpan(0.25), Render.brushSpan(0.5), Render.brushSpan(0.75)],
       [{ unit: 'sub', n: 1 }, { unit: 'sub', n: 2 }, { unit: 'sub', n: 3 }],
       'brushSpan: 小数画笔按子格量(0.25 / 0.5 / 0.75 → 1 / 2 / 3 子格)');

    tableEq('brushRegion:以光标为中心(lo=floor((n-1)/2)、hi=ceil((n-1)/2)),格/子格两种单位不混', [
      ['1 格画笔画一格(不落在子格上)', Render.brushRegion({ kind: 'cell', x: 3, y: 4 }, 1), { unit: 'cell', x0: 3, y0: 4, x1: 3, y1: 4 }],
      ['3×3 以光标为中心', Render.brushRegion({ kind: 'cell', x: 3, y: 4 }, 3), { unit: 'cell', x0: 2, y0: 3, x1: 4, y1: 5 }],
      ['0.25 画笔盖一个子格', Render.brushRegion({ kind: 'sub', x: 5, y: 6 }, 1), { unit: 'sub', x0: 5, y0: 6, x1: 5, y1: 6 }],
      ['0.75 画笔盖 3×3 子格', Render.brushRegion({ kind: 'sub', x: 5, y: 6 }, 3), { unit: 'sub', x0: 4, y0: 5, x1: 6, y1: 7 }],
    ]);
    // ★ 两种单位的坐标含义不同(格 vs 子格),混用会让画笔大小整体错 4 倍 ——
    //   调用方必须看 unit 再决定是"每格填 16 子格"还是"直接就是子格"。
    // ★★ 断言必须覆盖整个返回对象:只判 .kind 的话,两个分支只差一个标签也算过 ——
    //   "吸附到格"就成了一句没人验的空话(把 X:9,Y:10 的子格号原样当格号传下去,恰好
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
  (function () {
    // ② 的脏区簿记是纯逻辑:编辑 → 脏矩形;切层 → 只合成;平移 → 搬移 + 补边条。
    const d = Render.createDirtySet();
    eq(d.rect(), null, '新脏区集是空的');
    d.addCell(0, 3, 4);
    eq(d.rect(), { x: 12, y: 16, w: 4, h: 4 }, 'addCell(0,3,4) → 子格矩形 (12,16,4,4)');
    d.addCell(0, 5, 4);
    eq(d.rect(), { x: 12, y: 16, w: 12, h: 4 }, '★ 两个格合并成一个包围盒(不是两次重画)');
    d.addCell(2, 0, 0);
    // ★★ 期望值取 24:三个格 (0,3)/(0,5)/(2,0) 的子格并集是 x 0..24、y 0..20 —— 与上面两条
    //   ((12,16,12,4) 已把 x 撑到 24)以及 rectUnion 的语义(两轴各取 min/max)一致;写成 w: 20
    //   会与"addCell(0,5,4) 之后 w = 12"自相矛盾(12..24 并上 0..4 不可能只有 20 宽)。
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
});