'use strict';
// Node 冒烟 —— 辅码像素数学与 tinted-tile 缓存(level_editor/tint.js)。
// Run: cd level_editor && node tint_smoke.js
// 判据:文本 `TINT SMOKE OK` + 退出码 0。
// ★ 分片在 tests/tint/ 下,加载顺序就是下面的 require 顺序;断言助手在 tests/harness.js。
const harness = require('./tests/harness.js').start();
setTimeout(function () {
  console.error('FAIL: 120 秒超时 —— 某个断言挂住了');
  process.exit(1);
}, 120000);
try {
  require('./tests/tint/00_setup.js');
  require('./tests/tint/10_levels_and_hsv.js');
  require('./tests/tint/20_golden_and_exhaustive.js');
  require('./tests/tint/30_tiles_and_cache.js');
} catch (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
}
harness.finish('TINT SMOKE OK', 85);
