'use strict';
// Node 冒烟入口 —— worker.js(闸 3 的 Worker 壳)与 io.js(async 门面)。分片在 tests/worker_io/。
// Run: cd level_editor && node worker_io_smoke.js
// 判据:文本 `WORKER IO SMOKE OK` + 退出码 0。
const harness = require('./tests/harness.js').start();
setTimeout(function () {
  console.error('FAIL: 120 秒超时 —— 有请求永不 settle。两种成因都要查,别只怀疑第一种:');
  console.error('  (1) 那条请求的应答根本没被投递(worker 没回 / 桩把它扣住了 / 请求压根没发出去);');
  console.error('  (2) 应答投给了别的请求(按 id 配对错 —— 于是两条请求一起悬挂)。');
  console.error('  先看上面有没有"结果不对"的 FAIL 行(那是 (2) 的特征),再看桩的交付顺序(见 00_setup)。');
  process.exit(1);
}, 120000);
(async function () {
  require('./tests/worker_io/00_setup.js');
  await require('./tests/worker_io/10_env_and_roundtrip.js');
  await require('./tests/worker_io/20_concurrency_and_ping.js');
  await require('./tests/worker_io/30_error_paths.js');
  await require('./tests/worker_io/40_request_timeout.js');
  harness.finish('WORKER IO SMOKE OK', 68);
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
