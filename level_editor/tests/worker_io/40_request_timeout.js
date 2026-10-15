'use strict';
// tests/worker_io/40_request_timeout.js —— 每请求超时:worker 挂住而没发 onerror 时唯一能红的那条路。
const Core = globalThis.Core;
const Io = globalThis.Io;

module.exports = (async function () {
  // ==== 相位 ⑫ 每请求超时 ====
  // ★ 钉的是唯一一种闸 4 看不见的坏法:worker 被杀/挂住而没发 onerror ⇒ await Io.encodeMap 永久悬挂,症状是"Ctrl+S 之后再无反应、控制台干净"(围栏拦的是抛,悬挂连异常都没有)。
  // ★★ 时钟是注入的(timer 缝存在的唯一理由就是不用真等 30 秒);这个 IIFE 必须 await —— 否则它是在主链打完结果、正要退出时才跑,悬挂的断言会被 process.exit 切掉(输出里既没有 ok 也没有 FAIL)。
  await (async function () {
    // ★ 下限别误伤慢机器、上限别等于"没装":真算力是毫秒级(编码一张 125×75 的地图)。
    ok(Io.TIMEOUT_MS >= 5000 && Io.TIMEOUT_MS <= 120000,
       '★ 默认超时是**宽裕**的一档(下限别误伤慢机器、上限别等于"没装";实得 ' + Io.TIMEOUT_MS + ' 毫秒)');
    const clocks = [];
    const fakeTimer = {
      setTimeout: function (fn, ms) { const h = { fn: fn, ms: ms, cleared: false }; clocks.push(h); return h; },
      clearTimeout: function (h) { if (h) h.cleared = true; },
    };
    // 一个永不应答的 worker:收下消息就丢,而且不发 onerror(正是那个坏法)。
    let silentSpawns = 0;
    const silent = Io.createCodec({
      timeoutMs: 1234, timer: fakeTimer,
      workerFactory: function () {
        silentSpawns++;
        return { onmessage: null, onerror: null, terminated: false,
                 postMessage: function () { /* 永不应答 */ },
                 terminate: function () { this.terminated = true; } };
      },
    });
    const p = silent.ping();                      // 不 await:它现在**永远不会** settle
    eq(clocks.length, 1, '★ 一次请求装一个闹钟(实得 ' + clocks.length + ' 个)');
    eq(clocks[0] && clocks[0].ms, 1234,
       '★★ 闹钟用的是注入的 timeoutMs(默认是 ' + Io.TIMEOUT_MS + ' 毫秒;实得 ' +
       (clocks[0] ? clocks[0].ms : '(没有闹钟)') + ')');
    eq(silent.isDead(), false, '前提:还没到点 ⇒ 这条链**没**被标死');
    clocks[0].fn();                               // ← 手动点火(真的等 30 秒会被看门狗收走)
    await rejects(function () { return p; },
                  '★★★ 永不应答的 worker ⇒ 到点被拒(不是在 await 上挂到天荒地老)', '超时');
    eq(silent.isDead(), true,
       '★★★ 超时把整条链**标死**(走的是唯一的收口 failAll —— 死因与 terminate/onerror 同一份账)');
    eq(silent.pendingCount(), 0, '★ 表清空(不泄漏)');
    // ★★ 用有界等待而不是 await rejects:标死之后 ensure() 是当场(同步)抛的;万一实现退化成"静默再起一个 worker",有界等待会把它变成具名 FAIL,而不是让整条链挂到看门狗上。
    let lateErr = null;
    try {
      await Promise.race([
        silent.ping(),
        new Promise(function (_, rej) {
          setTimeout(function () { rej(new Error('有界等待超时(1 秒)—— 这次调用没有当场失败')); }, 1000);
        }),
      ]);
    } catch (e6) { lateErr = e6; }
    ok(lateErr && errText(lateErr).indexOf('编解码请求超时') >= 0,
       '★ 标死之后任何调用**当场**失败(而不是静默再起一个 worker);实得 ' +
       (lateErr ? JSON.stringify(errText(lateErr)) : '(没有拒绝 —— 它悬挂了)') +
       '。★ 判据取**编解码请求超时**(不是"超时"两个字):有界等待自己那条错误里也有"超时",' +
       '拿它当判据会把这个断言变成**永远绿**的');
    eq(silentSpawns, 1,
       '★★★ 那次超时之后**没有**再起第二个 worker(实得 ' + silentSpawns + ' 次工厂调用)' +
       ' —— 会"静默重试"的实现这里至少是 2');

    // ★ (对照)答得上的请求必须把闹钟撤掉:不撤的话每次成功的请求都会在超时到点后把这条链打死。
    const c5b = Io.createCodec({ timeoutMs: 777, timer: fakeTimer, workerFactory: makeWorker });
    const nBefore = clocks.length;
    const pong5 = await c5b.ping();
    ok(pong5.pong === true, '⑫ 对照:这条 codec 真答得上(经真 worker.js)');
    eq(clocks.length, nBefore + 1, '⑫ 对照:这条请求也装了自己的闹钟');
    ok(clocks[nBefore].cleared === true,
       '★★★ 应答到达时那个闹钟**被撤了**(`clearEntry` 在答复那条路上)' +
       ' —— 不撤 = 每次成功的请求都会在超时到点后把这条好心肠的 codec 打死');
    eq(c5b.isDead(), false, '⑫ 对照:撤了闹钟之后这条链仍然活着(没有被自己的闹钟误杀)');
    c5b.terminate();
  })();
})();
