'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Worker } = require('node:worker_threads');
require('./standalone_files.js');
require('./core.js');
const { build } = require('./build_dist.js');

async function run() {
  const downloads = [];
  const store = StandaloneFiles.createStore(async (name, bytes) => downloads.push({ name, bytes }));
  const content = new Blob([new Uint8Array([1, 2, 3])]);
  assert.equal((await store.request('/api/map?p=test.cyrm', { method: 'PUT', body: content })).status, 200);
  assert.equal(downloads[0].name, 'test.cyrm');
  assert.deepEqual(new Uint8Array(await (await store.request('/api/map?p=test.cyrm')).arrayBuffer()), new Uint8Array([1, 2, 3]));
  assert.equal((await (await store.request('/api/maps')).json()).maps[0].name, 'test.cyrm');
  assert.equal((await store.request('/api/map?p=..%2Ftest.cyrm')).status, 400);
  assert.equal((await store.request('/api/map?p=missing.cyrm')).status, 404);
  let writes = 0, aborted = 0;
  store.useDirectory({
    getFileHandle: async () => ({ createWritable: async () => ({
      write: async () => { writes++; }, close: async () => { throw new Error('disk full'); },
      abort: async () => { aborted++; },
    }) }),
  });
  await assert.rejects(store.request('/api/map?p=test.cyrm', { method: 'PUT', body: content }), /disk full/);
  assert.equal(writes, 1);
  assert.equal(aborted, 1);
  assert.equal(downloads.length, 1, '目录写入失败不能被当作导出成功');

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'cyrm-offline-'));
  try {
    const html = fs.readFileSync(build(path.join(temporary, 'editor.html')), 'utf8');
    assert(!/<script src=/.test(html), '离线页不能依赖外部脚本');
    assert(html.includes('data:image/png;base64,'));
    const packed = html.match(/workerUrl: URL.createObjectURL\(new Blob\(\[("(?:[^"\\]|\\.)*")\]/);
    assert(packed, '打包页包含真实 Worker 源码');
    // 在独立线程执行打包产物的实际 worker，验证隔离后的 Core 和压缩依赖。
    const worker = new Worker(
      'const {parentPort}=require("node:worker_threads");globalThis.self=globalThis;' +
      'self.postMessage=m=>parentPort.postMessage(m);parentPort.on("message",m=>self.onmessage({data:m}));\n' + JSON.parse(packed[1]),
      { eval: true });
    try {
      let sequence = 0;
      function call(payload) {
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => finish(reject, new Error('packed worker timeout')), 5000);
          function message(value) { finish(resolve, value); }
          function error(value) { finish(reject, value); }
          function finish(done, value) {
            clearTimeout(timer); worker.off('message', message); worker.off('error', error); done(value);
          }
          worker.once('message', message); worker.once('error', error);
          worker.postMessage({ id: ++sequence, ...payload });
        });
      }
      assert.deepEqual(await call({ op: 'ping' }), { id: 1, ok: true, pong: true });
      const map = Core.createMap('offline', 4, 3);
      map.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(15);
      const encoded = await call({ op: 'encode', map, compress: true });
      assert.equal(encoded.ok, true);
      const decoded = await call({ op: 'decode', bytes: encoded.bytes });
      assert.equal(decoded.ok, true);
      assert.deepEqual(decoded.map.layers[Core.LAYER_SCENE].desc, map.layers[Core.LAYER_SCENE].desc);
    } finally { await worker.terminate(); }
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
  console.log('STANDALONE SMOKE: OK');
}

run().catch(error => { console.error(error); process.exitCode = 1; });
