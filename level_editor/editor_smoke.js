'use strict';
// Node 冒烟 —— 浏览器地图编辑器的纯半边(工具内核 / 钳制 / 热键 / 历史 / 交互接线 / 持久化)。
// Run: cd level_editor && node editor_smoke.js
// 判据:文本 `EDITOR SMOKE OK` + 退出码 0。
// ★ 分片在 tests/editor/ 下,加载顺序 = 下面 PARTS 的顺序;断言助手在 tests/harness.js。
//   分片是各自独立的 CJS 模块(裸 ok/eq/… 沿作用域链落到 globalThis),导出的是自己的 promise。
const harness = require('./tests/harness.js').start();
setTimeout(function () {
  console.error('FAIL: 120 秒超时 —— 某个断言挂住了(多半是 lineCells 拿到非整数坐标)');
  process.exit(1);
}, 120000);

globalThis.window = globalThis;              // tile_defs.js 是 `window.TILE_DEFS = {…}`

// ★★ Worker 替身(node 里 `typeof Worker === 'undefined'`)。
//    为什么必须有:① 的 v4 二进制要走 `Editor.mapFromBytes` → `Io.decodeMap`,而 io.js 的
//    defaultFactory 在没有 Worker 时**会抛**(闸 3 没有降级路径,这是对的)⇒ 整条冒烟会在
//    第一个 await 上死掉,后面的分片一行都跑不到。
//    ★ 这里**不写第二份协议**:worker.js 是经典脚本,只用 `importScripts` 与 `self` 两个全局
//      (与 worker_io_smoke.js 同一个手法)—— 打桩这两个名字就能把**真的** worker.js 装进来、
//      用真的消息协议跑真的 core.js。替身只做"把 postMessage 转给 self.onmessage、
//      把 self.postMessage 转回实例的 onmessage"这件事。
globalThis.importScripts = function () { /* core/ 分片由下面的 loader 装,这里只是让 worker.js 能加载 */ };
const inProc = { onmessage: null, postMessage: null };
globalThis.self = inProc;
require('./worker.js');                      // ← 定义 inProc.onmessage
let liveWorker = null;                       // ★ 一个 codec 只起一个 worker(io.js 的 sharedCodec)
globalThis.Worker = function () {
  const w = this;
  this.onmessage = null;
  this.onerror = null;
  this.terminate = function () { /* 无副作用 */ };
  this.postMessage = function (msg) {
    liveWorker = w;
    inProc.postMessage = function (reply) { if (w.onmessage) w.onmessage({ data: reply }); };
    inProc.onmessage({ data: msg });
  };
};

const loader = require('./loader.js');
loader.loadModules(['core', 'tile_defs', 'tint', 'render', 'io', 'ui']);

const PARTS = [
  '00_setup', '10_core_tools', '20_hotkeys_errors', '30_history_clipboard',
  '40_interaction', '42_boot_ui_state', '50_save_names_persist', '52_save_flow',
  '54_save_backup_boot', '60_draft_write_race', '62_draft_restore_boot',
  '64_draft_guard', '66_draft_crash_evict', '70_wiring_mirror_resize',
  '72_wiring_compress_pan', '80_recheck_open_resize', '82_recheck_lib_space',
];
(async function () {
  try {
    for (const p of PARTS) await require('./tests/editor/' + p + '.js');
  } catch (err) {
    console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
    console.error(err && err.stack ? err.stack : String(err));
    process.exit(1);
  }
  harness.finish('EDITOR SMOKE OK', 527);
})();
