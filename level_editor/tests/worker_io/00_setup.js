'use strict';
// tests/worker_io/00_setup.js —— 浏览器 Worker 桩 + 本套件共享状态;打桩 importScripts/self 就能把真的 worker.js 与真的 core.js 跑起来(不是另写一个假实现冒充它)。
const loader = require('../../loader.js');
globalThis.importScripts = function () { loader.run(loader.moduleScripts('core')); };
const inProc = { onmessage: null, postMessage: null };
globalThis.self = inProc;
require('../../worker.js');                       // ← 定义 inProc.onmessage
require('../../io.js');
const Core = globalThis.Core;

// ★ 两个时限的分工:120000(入口看门狗)是全局兜底;PHASE5_TIMEOUT_MS = 只罩相位 ⑤ 并发批的局部时限。
//   它存在的唯一理由是让红的形态可用:配对错的实现会让整批永不 settle,于是一个具名 FAIL 都没有、整个进程被看门狗收走;2 秒是三个数量级的余量,不会在负载重的机器上假红 —— 但它只罩一个相位,替不了看门狗。
const PHASE5_TIMEOUT_MS = 2000;

// ── 假 Worker:把消息异步交给真的 worker.js,再把应答异步交回;应答乱序投递(见 deliver)—— 只有乱序才让"按 id 配对"吃劲。
let live = null;
// ★ spawns(工厂调用计数)钉"那次失败没有另起一个 worker":w.sent 看不见偷偷新建的对象(新 worker 有自己的 sent 计数器)。
let spawns = 0;
function makeWorker() {
  spawns++;
  const w = {
    onmessage: null, onerror: null, terminated: false, sent: 0, delivered: 0, ready: [],
    postMessage: function (msg) {
      w.sent++;
      // ★ 异步投递:真 Worker 是异步的;同步回包会掩盖"发完就 terminate"那一类错。
      setImmediate(function () {
        if (w.terminated) return;
        inProc.postMessage = function (out) { deliver(w, out); };
        inProc.onmessage({ data: msg });
      });
    },
    terminate: function () { w.terminated = true; },
  };
  live = w;
  return w;
}

// ★ 攒到"这一批请求全都拿到应答"才一次吐出,交付顺序只由各条应答自己的 id 决定(按 id 升序后整体循环左移 ⌈n/3⌉ 位),与到达先后无关。
//   为什么必须既非恒等、也非倒序:恒等会让"取最老 pending"蒙对,倒序会让"取最新 pending"蒙对;n ≥ 3 时 k ∈ [1, n-2] 天然避开两者。判定条件是「已交付 + 攒着 === 已发出」,所以最后一条一定会被交付。
function deliver(w, out) {
  w.ready.push(out);
  if (w.ready.length !== w.sent - w.delivered) return;
  const batch = w.ready.splice(0, w.ready.length);
  const arrivals = batch.map(function (o) { return o.id; });   // ← 到达序(batch 下面会被就地排序,先留一份)
  batch.sort(function (a, b) { return a.id - b.id; });    // ← 规范序:只由 id 决定,与到达顺序无关
  const k = Math.ceil(batch.length / 3) % batch.length;   // ← 再整体左移 k 位(n=1 → 0)
  const ordered = batch.slice(k).concat(batch.slice(0, k));
  // ★★ 对实际交付出去的那个序列下断言:上面那条"既非到达序亦非其倒序"的约定若被改回退化值,注释不会红、相位 ⑤ 也不会红,它就静默失效了。
  if (arrivals.length >= 3) {
    const delivered = ordered.map(function (o) { return o.id; });
    const reversed = arrivals.slice().reverse();
    ok(delivered.join(',') !== arrivals.join(','),
       '★ 桩的交付序 ≠ 到达序(恒等排列会让「取**最老** pending」蒙对 —— 相位 ⑤ 的强度全靠这里):' +
       '到达 ' + arrivals.join(',') + ' → 交付 ' + delivered.join(','));
    ok(delivered.join(',') !== reversed.join(','),
       '★ 桩的交付序 ≠ 到达序的倒序(倒序排列会让「取**最新** pending」蒙对):' +
       '到达 ' + arrivals.join(',') + ' → 交付 ' + delivered.join(','));
  }
  w.delivered += ordered.length;
  ordered.forEach(function (o) {
    if (typeof w.onmessage === 'function') w.onmessage({ data: o });
  });
}

function fillMap(map, L, seed) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (let i = 0; i < a.length; i++) a[i] = ((i * 2654435761 + seed) >>> 0) % (L === Core.LAYER_BG ? 0xFFFFFFFF : 0xFFFF);
  return map;
}

// 不经 io.js,直接把一条原始消息交给那个假 Worker(于是走的是真的 worker.js)。
function rawCall(msg) {
  return new Promise(function (resolve, reject) {
    const w = makeWorker();
    w.onmessage = function (ev) { resolve(ev.data); };
    w.onerror = function () { reject(new Error('裸调用:worker 报错')); };
    w.postMessage(msg);
  });
}

// ★ codec 是本套件新加的跨分片可变状态,用存取器挂在全局上(同 harness 的 pass/fail);live 与 spawns 声明在上面的桩代码里,分片里裸名读写即可。
let codec = null;
Object.defineProperty(globalThis, 'live', { get: function () { return live; }, set: function (v) { live = v; }, configurable: true });
Object.defineProperty(globalThis, 'spawns', { get: function () { return spawns; }, set: function (v) { spawns = v; }, configurable: true });
Object.defineProperty(globalThis, 'codec', { get: function () { return codec; }, set: function (v) { codec = v; }, configurable: true });

Object.assign(globalThis, {
  makeWorker: makeWorker, deliver: deliver, fillMap: fillMap, rawCall: rawCall,
  PHASE5_TIMEOUT_MS: PHASE5_TIMEOUT_MS,
});
