'use strict';
// Node 冒烟 —— 本地服务器 level_editor/editor_server.js(规格 §4.9)。
// Run: cd level_editor && node server_smoke.js
// 判据:文本 SERVER SMOKE OK + 退出码 0。
// ★ 本文件只碰 mkdtemp 出来的临时目录:真实 maps/ 目录一次都不写。
// ★ 分片在 tests/server/ 下:require 顺序就是相位顺序;各片把相位体挂到同一条 promise 链
//   (globalThis.serverChain)上,入口统一 await 它 —— 于是相位体里的 await 一字不用改。
// ★★ 全部相位都必须挂在链上、在 try 里 await:cleanup() 在 finally —— 挂在链外 = 相位跑在
//    清理之后,会把已删掉的 tmpRoot 重新建出来(每次跑漏一个 cyrm-srv-* 临时目录)。
const harness = require('./tests/harness.js').start();
(async function main() {
  setTimeout(async function () {
    console.error('FAIL: 120 秒超时 —— 有 server 没关,或某个 promise 永不 settle');
    await cleanup();            // 超时这一支也必须清
    process.exit(1);
  }, 120000);

  try {
    require('./tests/server/00_setup.js');
    require('./tests/server/10_basics.js');
    require('./tests/server/20_static_read_failure.js');
    require('./tests/server/30_map_name_guard.js');
    require('./tests/server/40_api_read.js');
    require('./tests/server/50_write_gates.js');
    require('./tests/server/60_rename_retry.js');
    require('./tests/server/70_e2e.js');
    await globalThis.serverChain;
  } finally {
    await cleanup();
  }
  harness.finish('SERVER SMOKE OK', 170);
})().catch(async function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  if (typeof cleanup === 'function') await cleanup();   // 双保险(finally 通常已经跑过;cleanup 幂等)
  process.exit(1);
});
