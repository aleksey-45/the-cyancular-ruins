'use strict';
// Node 冒烟入口 —— `.cyrm` v4 格式核心层(level_editor/core/)。分片在 tests/format/。
// Run: cd level_editor && node smoke.js
// 判据:文本 `SMOKE OK` + 退出码 0。
// ★ 断言助手与计数在 tests/harness.js;分片按下面的 require 顺序串行跑(导出 promise 的用 await 等它跑完)。
const harness = require('./tests/harness.js').start();
setTimeout(function () {
  console.error('FAIL: 120 秒超时 —— 某个断言挂住了');
  process.exit(1);
}, 120000);
(async function () {
  require('./tests/format/00_setup.js');
  await require('./tests/format/10_desc_and_bytes.js');
  await require('./tests/format/20_layers.js');
  await require('./tests/format/30_meta_and_file.js');
  await require('./tests/format/40_golden_and_limits.js');
  await require('./tests/format/50_v3_text.js');
  await require('./tests/format/60_migrate_and_validate.js');
  harness.finish('SMOKE OK', 331);
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
