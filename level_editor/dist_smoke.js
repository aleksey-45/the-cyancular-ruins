'use strict';
// Node 冒烟 —— 单文件版(dist/cyrm-editor.html)。这一套是"双击能不能用"的唯一自动判据:
//   ① 自包含:页面里没有一处外部 <script src>,图集与 worker 源码都内联;
//   ② 与源码同步:提交的 dist 必须与 build() 的字面输出逐字符一致(漂了就红);
//   ③ 同页 Worker 垫片:装上真垫片,走 io.js → worker.js → Core 的真协议往返;
//   ④ fetch 垫片:maps 列表 / 读 / 写(无目录句柄 → 下载)三条端点语义。
// Run: cd level_editor && node dist_smoke.js
// 判据:文本 `DIST SMOKE OK` + 退出码 0。
const fs = require('fs');
const path = require('path');
const harness = require('./tests/harness.js').start();
const loader = require('./loader.js');
const builder = require('./build_dist.js');

const built = builder.build();

// ==== ① 自包含 ====
ok(!/<script[^>]*\bsrc=/.test(built.text), '页面里没有外部 <script src>(单文件自包含)');
ok(built.text.indexOf('window.__CYRM_STANDALONE__ = true;') > 0, '开关脚本在页面里');
ok(built.text.indexOf('__CYRM_ATLAS_URL__') > 0 && built.text.indexOf('data:image/png;base64,') > 0,
   '图集内联成 data: URL(file:// 下没有 structure.png 也画得出来)');
ok(built.text.indexOf('__CYRM_WORKER_SRC__') > 0 && built.text.indexOf('本地目录') > 0,
   'worker 源码与独立版垫片都打进去了');

// ==== ② 与已提交的 dist 一致 ====
if (!fs.existsSync(builder.OUT)) {
  ok(false, 'dist/cyrm-editor.html 还不存在(先跑 node build_dist.js)');
} else {
  const cur = fs.readFileSync(builder.OUT, 'utf8');
  ok(cur === built.text, 'dist/cyrm-editor.html 与源码一致(' + built.inlined.length + ' 片内联)');
}

// ==== ③④ 装上独立版垫片 ====
globalThis.window = globalThis;
globalThis.__CYRM_STANDALONE__ = true;
globalThis.__CYRM_WORKER_SRC__ = fs.readFileSync(path.join(__dirname, 'worker.js'), 'utf8');
const anchor = { style: {}, click: function () {}, remove: function () {}, href: '', download: '' };
globalThis.document = {
  readyState: 'complete',
  getElementById: function () { return null; },
  createElement: function () { return anchor; },
  addEventListener: function () {},
  body: { appendChild: function () {}, removeChild: function () {} },
};
const store = {};
globalThis.localStorage = {
  getItem: function (k) { return k in store ? store[k] : null; },
  setItem: function (k, v) { store[k] = String(v); },
  removeItem: function (k) { delete store[k]; },
};
new Function(fs.readFileSync(path.join(__dirname, 'standalone_shim.js'), 'utf8'))();
ok(globalThis.Worker !== undefined, '垫片装上了同页 Worker');

loader.run(loader.moduleScripts('core'));
require('./io.js');
const Core = globalThis.Core;
const Io = globalThis.Io;

(async function main() {
  // ==== ③ 同页 Worker:io → worker.js → Core ====
  const codec = Io.createCodec();
  const map = Core.createMap('shim', 2, 2);
  const pong = await codec.ping();
  ok(pong.pong === true, '同页 Worker 应答 ping(协议往返)');
  const bytes = await codec.encodeMap(map, { compress: false });
  const back = await codec.decodeMap(bytes);
  const a = map.layers[Core.LAYER_SCENE].desc, b = back.layers[Core.LAYER_SCENE].desc;
  let same = a.length === b.length;
  for (let i = 0; same && i < a.length; i++) if (a[i] !== b[i]) same = false;
  ok(Core.cellsWOf(back) === 2 && Core.cellsHOf(back) === 2 && same,
     '经垫片的 encodeMap → decodeMap 往返:尺寸与场景层逐格相同');
  let err = null;
  try { await codec.decodeMap(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])); } catch (e) { err = e; }
  ok(err !== null, '坏字节经垫片带回 {ok:false}(错误不吞)');
  codec.terminate();
  err = null;
  try { await codec.decodeMap(bytes); } catch (e) { err = e; }
  ok(err !== null, 'terminate 之后当场失败,不静默再起一个 Worker');

  // ==== ④ fetch 垫片:列表 / 写 / 读 / 404 ====
  const before = await (await fetch('/api/maps')).json();
  eq(before.maps, [], '没有目录、也没打开文件时,库列表是空的');
  const put = await (await fetch('/api/map?p=sample.cyrm', {
    method: 'PUT', headers: { 'Content-Type': 'application/json' },
    body: new Blob([new Uint8Array([9, 8, 7, 6])]),
  })).json();
  eq(put, { name: 'sample.cyrm', size: 4, to: 'download' },
     '写:没有目录句柄时走下载退路,应答体是 {name,size,to}');
  const rows = (await (await fetch('/api/maps')).json()).maps;
  eq(rows.length, 1, '写过的文件出现在库列表里');
  eq(rows[0].name, 'sample.cyrm', '库列表点名那个文件');
  const got = new Uint8Array(await (await fetch('/api/map?p=sample.cyrm')).arrayBuffer());
  sameBytes(got, new Uint8Array([9, 8, 7, 6]), '读:拿回的字节与写进去的逐字节一致');
  const miss = await fetch('/api/map?p=nope.cyrm');
  eq(miss.status, 404, '读不存在的名字 → 404(不伪造空文件)');

  harness.finish('DIST SMOKE OK');
})().catch(function (e) {
  console.error('FAIL: 未捕获异常:');
  console.error(e && e.stack ? e.stack : String(e));
  process.exit(1);
});
