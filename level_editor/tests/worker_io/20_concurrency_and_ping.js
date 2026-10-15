'use strict';
// tests/worker_io/20_concurrency_and_ping.js —— 并发批按 id 配对(应答乱序到达)与 ping / terminate。
const Core = globalThis.Core;
const Io = globalThis.Io;

module.exports = (async function () {
  // ==== 相位 ⑤ 并发:按 id 配对,不许串台(应答乱序到达,见 deliver)====
  const phase5 = (function () {
    const jobs = [];
    for (let n = 1; n <= 6; n++) {
      const mm = fillMap(Core.createMap('c' + n, n, 2), Core.LAYER_SCENE, n * 31);
      jobs.push(codec.encodeMap(mm).then(function (b) { return { n: n, b: b }; }));
    }
    const batch = Promise.all(jobs).then(function (outs) {
      let allOk = true, firstBad = '';
      return Promise.all(outs.map(function (o) {
        return codec.decodeMap(o.b).then(function (mm) {
          const src = Core.createMap('c' + o.n, o.n, 2);
          fillMap(src, Core.LAYER_SCENE, o.n * 31);
          const a = mm.layers[Core.LAYER_SCENE].desc;
          if (a.length !== src.layers[Core.LAYER_SCENE].desc.length) { allOk = false; firstBad = 'n=' + o.n + ' 长度'; return; }
          for (let i = 0; i < a.length; i++) {
            if (a[i] !== src.layers[Core.LAYER_SCENE].desc[i]) { allOk = false; firstBad = 'n=' + o.n + ' 第 ' + i + ' 项'; return; }
          }
        });
      })).then(function () {
        ok(allOk, '★ 6 个并发的 encode/decode 各自拿到**自己那份**结果(应答乱序到达,仍按 id 配对,首个不匹配:' + firstBad + ')');
        eq(codec.pendingCount(), 0, '全部 settle 之后 pending 表清空(不会泄漏)');
      });
    });
    // ★★ 本相位的局部时限(见 00_setup 的 PHASE5_TIMEOUT_MS):stall 时记一条具名 FAIL,让 ⑥ 照常评、断言总数与基线可比;看门狗仍是最后一道网。
    let timer = null;
    const bound = new Promise(function (_, reject) {
      timer = setTimeout(function () {
        reject(new Error('并发的 encode/decode 有请求在 ' + (PHASE5_TIMEOUT_MS / 1000) +
                         ' 秒内没有 settle —— 至少一条应答没有回到它自己的 promise' +
                         '(按 id 配对错;桩的交付排列见 deliver)'));
      }, PHASE5_TIMEOUT_MS);
    });
    // ★ 正常路径上把定时器收掉:留着它会让进程尾巴上多挂一个 2 秒的 pending timer。
    return Promise.race([batch, bound]).finally(function () { clearTimeout(timer); });
  })().catch(function (e) {
    // ★ 两种来源(局部时限超时,或本相位自己真出错)都在这里记一条具名 FAIL:红的那一刻就知道破的是哪条约定,而不是整轮被看门狗收走;真因由 errText(e) 带出。
    ok(false, '★ 相位 ⑤ 未走完(超时 ' + (PHASE5_TIMEOUT_MS / 1000) +
       ' 秒未 settle,或本相位自身出错): ' + errText(e));
  });

  await phase5;

  // ==== 相位 ⑥ ping 与 terminate ====
  await codec.ping().then(function (p) {
    ok(p.pong === true, 'ping → pong(唤醒与就绪检测用)');
    ok(typeof codec.isDead() === 'boolean' && codec.isDead() === false, 'isDead(): 正常态返回 false');
    codec.terminate();
    ok(live.terminated === true, 'terminate() 真的终止了底层 worker');
  });
})();
