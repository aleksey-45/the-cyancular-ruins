'use strict';
// tests/render/60_error_sink.js —— 相位 ⑫:视图入口的失败必须看得见(渲染自己的 error sink)。
globalThis.renderChain = globalThis.renderChain.then(async function () {
const Core = globalThis.Core;
const Render = globalThis.Render;
    const savedDoc2 = globalThis.document;
    const savedEditor = globalThis.Editor;
    const made3 = [];
    globalThis.document = { createElement: function () { const c = fakeCanvas(0, 0); made3.push(c); return c; } };
    // ★ 页面那条通道就是 ui.js 的 status()(= 状态栏 #status-msg);这里换成一个记账替身。
    //   node 里本来没有 globalThis.Editor(ui.js 不在场),所以这也顺带钉住了"渲染是运行时
    //   找那条通道、不在模块顶层引 ui.js"。
    const seen = [];
    globalThis.Editor = { status: function (t) { seen.push(String(t)); } };
    const SLICE2 = { slicer: { nextFrame: function () { return Promise.resolve(); } } };
    // ★ 本相位故意触发两次真实抛错,而默认 sink 除了写状态栏还会 console.error(那是
    //   调试轨迹,不是测试失败)—— 但它会把"stderr 0 字节"这条验收指标弄脏。⇒ 局部接住
    //   console.error,收尾时只把测试自己那几行 FAIL 回放到真 stderr(不回放 = 本相位里的
    //   失败会被静默吞掉,而计数照样红 —— 一条没有消息的 FAIL)。
    const realConsoleError = console.error;
    const errLines = [];
    console.error = function () {
      errLines.push(Array.prototype.map.call(arguments, String).join(' '));
    };
    try {
      // ★ 图集必须是确定的那一张:默认 backend 在 node 里会抛 Tint: 本环境没有 document
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
      // ★ 接口增补:报错通道可换(页面/探针接自己的日志 / 断言)。换掉之后默认那条就不该再收到。
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
});