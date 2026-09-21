'use strict';
// Node 冒烟 —— worker.js(闸 3 的 Worker 壳)与 io.js(async 门面)。
// Run: cd level_editor && node worker_io_smoke.js
// 判据:文本 `WORKER IO SMOKE OK` + 退出码 0。
//
// ★★ 怎么在 node 里测"一个浏览器 Worker":worker.js 是**经典脚本**,只用两个全局
//    (`importScripts` 与 `self`)。本文件给这两个名字打桩,于是能把**真的** worker.js
//    加载进来、用真的消息协议跑真的 core.js —— 不是另写一个假实现冒充它。
//    (node 的 worker_threads 是另一套 API,拿它测等于测一份只在测试里存在的代码。)

globalThis.importScripts = function () { require('./core.js'); };
const inProc = { onmessage: null, postMessage: null };
globalThis.self = inProc;
require('./worker.js');                       // ← 定义 inProc.onmessage
require('./io.js');
const Core = globalThis.Core;
const Io = globalThis.Io;

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function sameBytes(actual, expected, msg) {
  const a = Array.prototype.slice.call(actual), e = Array.prototype.slice.call(expected);
  if (a.length !== e.length) {
    fail++; console.error('  FAIL - ' + msg + ' (长度 ' + a.length + ' ≠ 期望 ' + e.length + ')'); return;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== e[i]) {
      fail++; console.error('  FAIL - ' + msg + ' (第 ' + i + ' 字节: 实得 ' + a[i] + ', 期望 ' + e[i] + ')'); return;
    }
  }
  pass++; console.log('  ok  - ' + msg);
}
function errText(e) {
  let m = (e && e.message !== undefined) ? String(e.message) : String(e);
  if (m === '' && e && e.cause && e.cause.message) m = String(e.cause.message);
  return m;
}
// ★ 反向断言必须同时断言「错在哪」:只判「有没有抛」是假绿(拼错标识符抛的 TypeError 一样算过)。
async function rejects(fn, msg, expectSub) {
  let e = null;
  try { await fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && errText(e).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + errText(e)); return;
  }
  pass++; console.log('  ok  - ' + msg);
}

// ── 假 Worker:把消息异步交给**真的** worker.js,再把应答异步交回 ──
// ★★ 应答**乱序**投递(见 deliver)。真 Worker 的应答顺序本来就不保证等于请求顺序
//    (不同 op 耗时不同、调度不确定),而"按 id 配对"这条断言只有**乱序**才吃劲:
//    桩若按 request 顺序回包,"最老的那条 pending"永远就是发起者 —— 把 io.js 的
//    `pending.get(m.id)` 换成"取最老的一条"照样全绿(task-1-report §6 C 实测)。
let live = null;
function makeWorker() {
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

// ★ 攒到"这一批请求全都拿到应答了"才一次**倒序**吐出:最早那条请求的应答最后到,
//   于是"取最老 pending"的实现在这里必红。判定条件是「已交付数 + 攒着数 === 已发出数」,
//   所以最后一条应答**一定**会被交付(不会因为倒序永远扣住它),单独一条请求也是立刻交付。
//   ★ 它有个前提:每条**已发出**的请求最终都会回一条应答(本文件的用例都满足)。若将来出现
//     "发了请求就 terminate、不等应答"的用例,被扣住的那条应答会留到 120 秒看门狗 ——
//     那时该用例本身的形态要改,不是这里漏发。
function deliver(w, out) {
  w.ready.push(out);
  if (w.ready.length !== w.sent - w.delivered) return;
  const batch = w.ready.splice(0, w.ready.length).reverse();
  w.delivered += batch.length;
  batch.forEach(function (o) {
    if (typeof w.onmessage === 'function') w.onmessage({ data: o });
  });
}

function fillMap(map, L, seed) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (let i = 0; i < a.length; i++) a[i] = ((i * 2654435761 + seed) >>> 0) % (L === Core.LAYER_BG ? 0xFFFFFFFF : 0xFFFF);
  return map;
}

// 不经 io.js,直接把一条原始消息交给那个假 Worker(于是走的是**真的** worker.js)。
function rawCall(msg) {
  return new Promise(function (resolve, reject) {
    const w = makeWorker();
    w.onmessage = function (ev) { resolve(ev.data); };
    w.onerror = function () { reject(new Error('裸调用:worker 报错')); };
    w.postMessage(msg);
  });
}

// ── 末尾四组相位(⑧~⑪):全是"静默失败"那一类(看着没事,其实请求挂着 / 错误被吞) ──
// ★ 放在最后是因为它们各自新建 worker,会顶掉 live;前面相位 ⑥ 的 `live.terminated` 断言
//   依赖 live 指向**那个 codec** 的 worker。
async function tailPhases() {
  // ==== 相位 ⑧ 未列出的 op:worker.js 必须**响亮应答**,不能沉默 ====
  const unknown = await rawCall({ id: 4242, op: 'no-such-op' });
  eq(unknown.id, 4242, '未知 op 的应答带回**原请求的 id**(调用方能配上对)');
  eq(unknown.ok, false, '★ 未知 op → ok:false(不静默丢弃、也不假装成功)');
  ok(typeof unknown.error === 'string' && unknown.error.indexOf('worker: 未知操作') === 0,
     '★ 未知 op 的 error 文本 = 「worker: 未知操作 …」(brief 第 16 行钉的形状),实得:' +
     JSON.stringify(unknown.error));
  ok(typeof unknown.error === 'string' && unknown.error.indexOf('no-such-op') >= 0,
     '未知 op 的 error 里带上那个 op 名(报错要能定位是哪个 op)');

  // ==== 相位 ⑨ onerror:必须被**订阅**,且把在飞请求响亮拒掉并把 codec 标死 ====
  // ⑨a 工厂**预置**了 onerror —— io.js 必须无条件覆盖它(有就不装 = 失败处理静默失效)。
  const preset = function () { /* 工厂自带的 onerror:旧实现会因此**不**订阅本 codec 的处理 */ };
  const c5 = Io.createCodec({
    workerFactory: function () { const w = makeWorker(); w.onerror = preset; return w; },
  });
  await c5.ping();
  ok(typeof live.onerror === 'function' && live.onerror !== preset,
     '★ 工厂预置的 onerror 被**覆盖**(不是"有就不装" —— 有就不装 = 崩溃后所有在飞请求永久悬挂)');

  // ⑨b 真·崩一次
  const c2 = Io.createCodec({ workerFactory: makeWorker });
  const inflight = c2.ping();
  eq(c2.pendingCount(), 1, 'onerror 之前那条请求确实进了 pending 表(下面才有的可挂)');
  live.onerror({ message: '模拟 worker 崩溃' });
  await rejects(function () { return inflight; },
                '★ worker.onerror → 在飞请求**当场被拒**(不是永远挂着)', 'Io: 编解码 worker 出错');
  eq(c2.pendingCount(), 0, 'onerror 之后 pending 表清空(没有留住不 settle 的 resolver)');
  ok(c2.isDead() === true, 'onerror 之后 codec 被标死(isDead() === true)');
  const sentAfterError = live.sent;
  await rejects(function () { return c2.ping(); },
                '★ 标死之后**再调用也失败** —— 不静默新建 worker 重试', 'Io: 编解码 worker 出错');
  eq(live.sent, sentAfterError, '那次失败没有偷偷再往 worker 发一条消息');

  // ==== 相位 ⑩ terminate() 时在飞的请求必须被拒,不能留悬挂 promise ====
  const c3 = Io.createCodec({ workerFactory: makeWorker });
  ok(c3.isDead() === false, 'terminate 之前 isDead() === false');
  const inflight3 = c3.ping();
  // ★ worker 是**惰性**建的(第一次调用才 factory()),故 live 必须在调用**之后**取。
  const w3 = live;
  eq(c3.pendingCount(), 1, 'terminate 之前确实有一条在飞请求');
  c3.terminate();
  ok(w3.terminated === true, 'terminate() 真的终止了底层 worker');
  await rejects(function () { return inflight3; },
                '★ terminate() → 在飞请求被拒(不是永不 settle、把调用方挂死的 promise)', 'terminate');
  eq(c3.pendingCount(), 0, '★ terminate() 之后 pending 表清空(pendingCount() 回到 0)');
  ok(c3.isDead() === true, '★ terminate() 之后 codec 标死 —— 下一次调用不会**静默**新建一个 worker');
  await rejects(function () { return c3.ping(); }, 'terminate 之后再调用也失败', 'terminate');
  eq(w3.sent, 1, '那次失败没有偷偷再往 worker 发一条消息');

  // ==== 相位 ⑪ postMessage 抛(浏览器里不可克隆的 map 就是 DataCloneError)====
  // ★ 这一条钉的是**账目**:单条消息发不出去,表里那条必须被清掉,否则 pendingCount()
  //   再也回不到 0(而症状只是"那一次失败"),resolver 也一直被攥着。
  let throwOnce = true;
  const c4 = Io.createCodec({
    workerFactory: function () {
      const w = makeWorker();
      const raw = w.postMessage;
      w.postMessage = function (msg) {
        if (throwOnce) { throwOnce = false; throw new Error('DataCloneError: 该对象无法被克隆'); }
        return raw.call(w, msg);
      };
      return w;
    },
  });
  await rejects(function () { return c4.ping(); },
                '★ postMessage 抛 → promise 被拒(错误回到调用方,不吞)', 'DataCloneError');
  eq(c4.pendingCount(), 0, '★ postMessage 抛之后 pending 表**不残留**:pendingCount() 回到 0');
  ok(c4.isDead() === false, '单条消息发不出去**不**把整条 codec 标死(它不是 worker 崩了)');
  const pong4 = await c4.ping();
  ok(pong4.pong === true, '同一条 codec 之后仍能正常往返(不是一次性废掉)');
}

(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 有请求永不 settle(应答没被投递?)');
    process.exit(1);
  }, 120000);

  // ==== 相位 ① 环境与常量 ====
  ok(Io.workerAvailable() === false, '★ node 里 workerAvailable() === false(node 没有浏览器 Worker)');
  await rejects(function () { return Io.encodeMap(Core.createMap('x', 1, 1)); },
                '★ 没有 Worker 且没注入 factory → 抛错(不静默退回主线程)',
                'Worker');
  ok(live === null, '那次失败**没有**建出任何 worker');

  // ==== 相位 ② 真协议往返(经真的 worker.js 与真的 core.js)====
  const codec = Io.createCodec({ workerFactory: makeWorker });
  const m = fillMap(fillMap(fillMap(Core.createMap('w', 3, 2), Core.LAYER_SCENE, 7), Core.LAYER_FRONT, 11),
                    Core.LAYER_BG, 13);
  m.players = [{ x: 1, y: 1 }];
  m.enemies = [{ type: 'fly_bird', x: 2, y: 1 }];
  m.comments = ['经 Worker 往返'];

  const bytes = await codec.encodeMap(m);
  ok(bytes instanceof Uint8Array, 'encodeMap 经 Worker 拿回 Uint8Array');
  ok(bytes.length > Core.HEADER_SIZE, '字节数 > 20(实得 ' + bytes.length + ')');
  sameBytes(bytes.subarray(0, 4), new Uint8Array([0x43, 0x59, 0x52, 0x4D]),
            '★ 头部 magic 仍是 "CYRM"(worker 没动内容)');
  eq(bytes[4], Core.FORMAT_VERSION, '版本字节 = ' + Core.FORMAT_VERSION);
  eq(bytes[5], 1, '默认走压缩路径(compression = 1)');

  const back = await codec.decodeMap(bytes);
  sameBytes(back.layers[Core.LAYER_SCENE].desc, m.layers[Core.LAYER_SCENE].desc, '往返:场景层一致');
  sameBytes(back.layers[Core.LAYER_FRONT].desc, m.layers[Core.LAYER_FRONT].desc, '往返:前景层一致');
  sameBytes(back.layers[Core.LAYER_BG].rgba, m.layers[Core.LAYER_BG].rgba, '往返:背景层一致');
  eq(back.players, m.players, '往返:出生点一致');
  eq(back.enemies, m.enemies, '往返:敌人一致');
  eq(back.comments, m.comments, '往返:注释一致');

  // ==== 相位 ③ 裸路径(compression = 0)也要经 Worker ====
  const raw = await codec.encodeMap(m, { compress: false });
  eq(raw[5], 0, 'compress:false → compression 字节是 0');
  const backRaw = await codec.decodeMap(raw);
  sameBytes(backRaw.layers[Core.LAYER_SCENE].desc, m.layers[Core.LAYER_SCENE].desc, '裸路径往返一致');

  // ==== 相位 ④ 错误要带错因回到调用方 ====
  await rejects(function () { return codec.decodeMap(new Uint8Array(20)); },
                '损坏文件 → promise 被拒', 'magic');
  await rejects(function () { return codec.decodeMap(new Uint8Array([1, 2, 3])); },
                '太短的文件 → promise 被拒', '小于头部');
  const bad = new Uint8Array(bytes);
  bad[5] = 9;                                   // 未知 compression
  await rejects(function () { return codec.decodeMap(bad); }, '未知 compression → 被拒', 'compression');

  // ==== 相位 ⑤ 并发:按 id 配对,不许串台(应答**乱序**到达,见 deliver)====
  (function () {
    const jobs = [];
    for (let n = 1; n <= 6; n++) {
      const mm = fillMap(Core.createMap('c' + n, n, 2), Core.LAYER_SCENE, n * 31);
      jobs.push(codec.encodeMap(mm).then(function (b) { return { n: n, b: b }; }));
    }
    return Promise.all(jobs).then(function (outs) {
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
  })().then(function () {

  // ==== 相位 ⑥ ping 与 terminate ====
  return codec.ping().then(function (p) {
    ok(p.pong === true, 'ping → pong(唤醒与就绪检测用)');
    ok(typeof codec.isDead() === 'boolean' && codec.isDead() === false, 'isDead(): 正常态返回 false');
    codec.terminate();
    ok(live.terminated === true, 'terminate() 真的终止了底层 worker');

    // ==== 相位 ⑦ 源码级纪律 ====
    (function () {
      const fs = require('fs'), path = require('path');
      const src = fs.readFileSync(path.join(__dirname, 'worker.js'), 'utf8');
      ok(/importScripts\(['"]core\.js['"]\)/.test(src),
         "★ worker.js 用 importScripts('core.js') 拿格式实现(只有一份实现,不抄第二份)");
      ok(src.indexOf('encodeTexLayer') < 0 && src.indexOf('decodeTexLayer') < 0 &&
         src.indexOf('crc32') < 0 && src.indexOf('inflate') < 0,
         '★★ worker.js 里没有任何格式/压缩逻辑(全在 core.js 里 —— 第二份实现迟早漂,而漂了不报错)');
      ok(/self\.onmessage\s*=/.test(src), 'worker.js 定义 self.onmessage');
      const io = fs.readFileSync(path.join(__dirname, 'io.js'), 'utf8');
      ok(io.indexOf('new Worker(') >= 0, "io.js 用 new Worker('worker.js')(只走 HTTP,故原生可用)");
      // ★ 模式必须与标签说的是同一回事:原先只扫 xhr/activexobject/importScripts,
      //   而标签写的是「没有 Blob URL」—— 那半个承诺没人守(Blob URL 正是"file:// 下起
      //   一个内联 worker"的绕法,闸 3 明说不做降级路径)。故把 createObjectURL/new Blob 纳入。
      ok(!/xmlhttprequest|activexobject|importScripts\(|createObjectURL|new\s+Blob\(/i.test(io),
         '★ io.js 里没有 Blob URL(createObjectURL / new Blob)/ XHR / importScripts 那类绕法' +
         '(闸 3 明说不做降级路径)');
    })();

    // ==== 相位 ⑧~⑪ 未知 op / onerror / terminate / postMessage 抛 ====
    return tailPhases();
  }).then(function () {
    console.log('');
    console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
    if (fail === 0) console.log('WORKER IO SMOKE OK');
    process.exit(fail === 0 ? 0 : 1);
  });
  // ★ 计划 2b Task 1 的代码块**漏印了这一行**(相位 ⑤ 那个 `.then(function () {` 回调的收尾)。
  //   缺了它整个文件是 SyntaxError: Unexpected end of input —— 一行断言都跑不到。
  //   按括号平衡补上;**没有任何断言被改动**。
  });
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
