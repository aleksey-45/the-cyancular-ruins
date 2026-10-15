'use strict';
// Node 冒烟 —— render.js 的纯半边(缓存 ①②③、脏区、环面、画笔几何、闸 2 分帧)。
// Run: cd level_editor && node render_smoke.js
// 判据:文本 RENDER SMOKE OK + 退出码 0。
// ★ 分片在 tests/render/ 下:require 顺序就是相位顺序;各片把相位体挂到同一条 promise 链
//   (globalThis.renderChain)上,入口统一 await 它 —— 于是相位体里的 await 一字不用改。
const harness = require('./tests/harness.js').start();
setTimeout(function () {
  console.error('FAIL: 120 秒超时 —— 某个断言挂住了(分帧器的 nextFrame 没被注入?)');
  process.exit(1);
}, 120000);
(async function () {
  try {
    require('./tests/render/00_setup.js');
    require('./tests/render/10_mount.js');
    require('./tests/render/20_bg_and_maps.js');
    require('./tests/render/30_caches.js');
    require('./tests/render/40_slicer_and_geometry.js');
    require('./tests/render/50_layer_canvas.js');
    require('./tests/render/60_error_sink.js');
    require('./tests/render/70_drag_preview.js');
    require('./tests/render/80_drag_layers.js');
    await globalThis.renderChain;
  } catch (err) {
    console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
    console.error(err && err.stack ? err.stack : String(err));
    process.exit(1);
  }
  harness.finish('RENDER SMOKE OK');
})();
