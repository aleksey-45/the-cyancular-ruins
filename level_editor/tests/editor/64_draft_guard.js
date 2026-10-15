'use strict';
// 两处 async 入口必须收口 —— 普通的失败不许换来一个假的崩溃提示。
// ★ 机制:入口把 promise 丢掉 ⇒ 拒绝逃到全局围栏 ⇒ 围栏会 `snapshot()` ⇒ 一次普通的打开
//   失败(HTTP 404)就把当前这张图写进崩溃槽位 ⇒ 下次开机弹一个假的恢复提示。
// ★★ node 里 `window` 没有真的 unhandledrejection 事件,故架一座桥:
//   `process.on('unhandledRejection')` → 交给生产挂上去的那个处理器;桥先被反证一次。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
require('./lib/stubs_draft.js').getStubs15();

module.exports = (async function () {

  const hooked15b = {};
  const savedAdd15b = globalThis.addEventListener;
  const savedSink15b = null;                  // 生产默认通道 = 无自定义 sink
  const escaped15 = [];
  const onUnhandled15 = function (reason) {
    escaped15.push(reason);
    if (typeof hooked15b.unhandledrejection === 'function') {
      hooked15b.unhandledrejection({ reason: reason });
    }
  };
  globalThis.addEventListener = function (evt, fn) { hooked15b[evt] = fn; };
  process.on('unhandledRejection', onUnhandled15);
  try {
    // ★ 报错通道换成"转发给状态栏"(= 生产无自定义 sink 时 `reportError` 的 `else status(text)`
    //   那一条):既能断言"用户看得见",又不往 stderr 写一个字。
    Editor.setErrorSink(function (t) { Editor.status(String(t)); });
    Editor.installCrashFence();
    Editor.app.map = Editor.createEmptyMap('open_fail_probe', 4, 4);
    Editor.app.name = 'open_fail_probe.cyrm';
    Editor.app.sourceFormat = 'v4';

    // ── 反证:桥真的通(裸拒绝会逃进来 + 真的落到崩溃槽位)──
    tab15.crash.clear();
    escaped15.length = 0;
    Promise.reject(new Error('裸拒绝(证明这座桥真的通)'));
    ok(await until15(function () { return escaped15.length > 0; }),
       '★★ ⑩b 前提(反证):一个**裸拒绝**真的会逃到全局围栏(等不到 ⇒ 下面两条"没逃"是空转)');
    ok(await until15(function () { return tab15.crash.has('crash'); }),
       '★★ ⑩b 前提(反证):而围栏**真的**会把当前这张图写进崩溃槽位 —— 这就是"假提示"的来路');

    // ── 库列表点击 → 打开地图(HTTP 404)──
    // ★★ 驱动的是真的那个点击处理器(buildPanels 挂在 `#lib-list` 上的委托那一只),
    //    不是"直接调 openMap" —— 后者对"入口把 promise 丢掉"这个改动完全不敏感。
    globalThis.fetch = function (url) {
      const u = String(url);
      if (u.indexOf('/api/maps') === 0) {
        return Promise.resolve({ ok: true, status: 200,
                                 json: function () { return Promise.resolve({ maps: [] }); } });
      }
      return Promise.resolve({ ok: false, status: 404 });
    };
    tab15.crash.clear();
    escaped15.length = 0;
    el15('status-msg').textContent = '';
    const libHandlers15b = (els15['lib-list'] && els15['lib-list']._h &&
                            els15['lib-list']._h.click) || [];
    ok(libHandlers15b.length > 0,
       '★★ ⑩b 前提:`#lib-list` 上真的挂着生产那个点击处理器(实得 ' +
       libHandlers15b.length + ' 个)');
    libHandlers15b.forEach(function (h) {
      h({ target: { closest: function () { return { dataset: { name: 'ghost.cyrm' } }; } } });
    });
    ok(await until15(function () {
         return el15('status-msg').textContent.indexOf('打开地图') >= 0;
       }),
       '★★★ 打开失败在状态栏上**说出来**了(「出错了(打开地图):…」;实得 "' +
       el15('status-msg').textContent + '")');
    ok(el15('status-msg').textContent.indexOf('404') >= 0,
       '★ 那句话里带着原因(HTTP 404 —— 不是一句没有线索的"出错了")');
    // ★ 反向断言给足时间:拒绝事件是异步投递的,只 tick 一次就判"没逃"是假绿。
    //   预算与上面那条反证同一个(until15 的 200 次 tick),故红的形态可比。
    await until15(function () { return false; });
    eq(escaped15.length, 0,
       '★★★ 那一次失败**没有**逃到全局围栏(逃了就说明入口又变成裸调用了;实得 ' +
       escaped15.length + ' 次)');
    eq(tab15.crash.size, 0,
       '★★★ 崩溃槽位里**什么都没有**(这就是"下次开机弹假提示"的全部内容;实得 ' +
       tab15.crash.size + ' 条)');

    // ── 长作业(`runJob`)的两个入口:油漆桶 / 渐变 ──
    // ★★ 判据同款:`runJob` 交回的是一整条分帧链的 promise,丢掉它 = 一次普通的落笔失败
    //    换来一个假的崩溃提示。
    const savedCanvas15b = Editor.app.canvas, savedSt15b = Editor.app.st;
    const savedEdit15b = Editor.app.r.editCells, savedScreen15b = Editor.app.r.screenToSub;
    const savedPreview15b = Editor.app.r.setPreview;   // pointerup 的渐变分支会调它
    const canvasH15b = {};
    Editor.app.canvas = {
      width: 80, height: 80,
      setPointerCapture: function () {},
      getBoundingClientRect: function () { return { left: 0, top: 0 }; },
      addEventListener: function (t, fn) { canvasH15b[t] = fn; },
    };
    Editor.app.r.screenToSub = function () { return { X: 0, Y: 0 }; };   // 落格 (0,0)
    Editor.app.r.setPreview = function () {};
    Editor.app.r.editCells = function () { throw new Error('测试:批量落笔失败'); };
    // ★★ rAF 桩(只为这一小段装、收尾还回去):`runJob` 的分帧器默认走 `requestAnimationFrame`,
    //    而 node 里没有这个全局 ⇒ 只要那条链需要第二帧,它就会以"rAF is not defined"
    //    拒掉 —— 那是测试环境的产物,会把这条断言想看的那个错整个盖掉。
    const savedRaf15b = globalThis.requestAnimationFrame;
    globalThis.requestAnimationFrame = function (cb) { realSetTimeout15(cb, 0); };
    Editor.installInteraction();                 // 真装一遍(它建的处理器才是生产那一份)
    try {
      ok(typeof canvasH15b.pointerdown === 'function' &&
         typeof canvasH15b.pointerup === 'function',
         '⑩b 前提:画布上挂着 pointerdown/up');
      Editor.app.st.tool = 'bucket';
      tab15.crash.clear(); escaped15.length = 0;
      el15('status-msg').textContent = '';
      canvasH15b.pointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
      ok(await until15(function () {
           return el15('status-msg').textContent.indexOf('油漆桶填充') >= 0;
         }),
         '★★★ 油漆桶那条链失败也**说出来**了(「出错了(油漆桶填充):…」;实得 "' +
         el15('status-msg').textContent + '")');
      await until15(function () { return false; });
      eq(escaped15.length, 0,
         '★★★ 油漆桶失败**没有**逃到全局围栏(裸 `runJob(...)` 的实现这里 ≥1)');
      eq(tab15.crash.size, 0, '★★★ 也没有写崩溃槽位');
      // 渐变(pointerdown 起终点、pointerup 才真跑那条分帧链)
      Editor.setLayer(Core.LAYER_BG);            // 规格 §4.4:渐变仅背景层
      Editor.app.st.tool = 'gradient';
      tab15.crash.clear(); escaped15.length = 0;
      el15('status-msg').textContent = '';
      canvasH15b.pointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
      ok(!!Editor.app.st.gradStart, '⑩b 前提:pointerdown 起了渐变起点');
      canvasH15b.pointerup({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
      ok(await until15(function () {
           return el15('status-msg').textContent.indexOf('渐变') >= 0;
         }),
         '★★★ 渐变那条链失败也**说出来**了(「出错了(渐变):…」;实得 "' +
         el15('status-msg').textContent + '")');
      await until15(function () { return false; });
      eq(escaped15.length, 0, '★★★ 渐变失败**没有**逃到全局围栏');
      eq(tab15.crash.size, 0, '★★★ 也没有写崩溃槽位');
    } finally {
      Editor.app.r.editCells = savedEdit15b;
      Editor.app.r.screenToSub = savedScreen15b;
      globalThis.requestAnimationFrame = savedRaf15b;
      Editor.app.r.setPreview = savedPreview15b;
      Editor.app.canvas = savedCanvas15b;
      Editor.app.st = savedSt15b;
    }

    // ── 自检那条入口(同一类"没护栏的异步入口")──
    // ★★ `selfTest()` 会拒绝:它消费 `Io.ping()` / `Io.encodeMap` / `Io.decodeMap`。丢掉那条
    //    promise = 一次未处理的拒绝 ⇒ 围栏写一份崩溃快照 ⇒ 下次开机弹一个假的恢复提示。
    // ★★ 关键在于不接它交回的那个 promise(生产里按钮那一侧也不接):接了这条断言就成空转。
    const savedStats15b = Editor.app.r.stats;
    const savedPing15b = globalThis.Io.ping;
    Editor.app.r.stats = function () { return { thumbsBuilt: 0 }; };
    globalThis.Io.ping = function () {
      return Promise.reject(new Error('自检用的假 ping 失败(复核 Important 2)'));
    };
    tab15.crash.clear();
    escaped15.length = 0;
    el15('status-msg').textContent = '';
    Editor.runSelfTest();                     // ★ 故意不接(见上);也不 await
    ok(await until15(function () {
         return el15('status-msg').textContent.indexOf('出错了(自检)') >= 0;
       }),
       '★★★ 自检失败经 `guard` 落到**状态栏**(「出错了(自检):…」;实得 "' +
       el15('status-msg').textContent + '")—— 没有护栏的实现这里写的是' +
       '「未处理的 promise 拒绝:…」,那一句本身就是护栏缺位的症状');
    ok(el15('status-msg').textContent.indexOf('假 ping 失败') >= 0,
       '★ 那句话里带着**原因**(不是一句没有线索的"出错了";实得 "' +
       el15('status-msg').textContent + '")');
    // ★ 反向断言给足时间:拒绝是异步投递的(与 ① 同一个 `until15` 预算 ⇒ 红的形态可比)。
    await until15(function () { return false; });
    eq(escaped15.length, 0,
       '★★★ 那次自检失败**没有**逃到全局围栏(裸 `selfTest().then(...)` 的实现这里 ≥1)');
    eq(tab15.crash.size, 0,
       '★★★ 也没有写崩溃槽位 —— 这就是"下次开机弹一个假提示"的全部内容(实得 ' +
       tab15.crash.size + ' 条)');
    globalThis.Io.ping = savedPing15b;
    Editor.app.r.stats = savedStats15b;
  } finally {
    process.removeListener('unhandledRejection', onUnhandled15);
    globalThis.addEventListener = savedAdd15b;
    Editor.setErrorSink(savedSink15b);
  }

})();
