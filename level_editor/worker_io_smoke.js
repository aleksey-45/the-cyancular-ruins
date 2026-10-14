'use strict';
// Node 冒烟测试：测试 worker.js 与 io.js
// 运行命令: cd level_editor && node worker_io_smoke.js
// 成功判定: 控制台输出 WORKER IO SMOKE OK 且退出码为 0。

globalThis.importScripts = function () { require('./core.js'); };
const inProc = { onmessage: null, postMessage: null };
globalThis.self = inProc;
require('./worker.js');                       // 定义 inProc.onmessage
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
async function rejects(fn, msg, expectSub) {
  let e = null;
  try { await fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && errText(e).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + errText(e)); return;
  }
  pass++; console.log('  ok  - ' + msg);
}

// 并发批测试超时时间
const PHASE5_TIMEOUT_MS = 2000;

// 模拟 Worker：异步将消息提交给 worker.js 并将应答异步交回
let live = null;
let spawns = 0;
function makeWorker() {
  spawns++;
  const w = {
    onmessage: null, onerror: null, terminated: false, sent: 0, delivered: 0, ready: [],
    postMessage: function (msg) {
      w.sent++;
      // 异步投递消息
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

// 模拟乱序交付应答以检验 ID 匹配逻辑
function deliver(w, out) {
  w.ready.push(out);
  if (w.ready.length !== w.sent - w.delivered) return;
  const batch = w.ready.splice(0, w.ready.length);
  const arrivals = batch.map(function (o) { return o.id; });
  batch.sort(function (a, b) { return a.id - b.id; });
  const k = Math.ceil(batch.length / 3) % batch.length;
  const ordered = batch.slice(k).concat(batch.slice(0, k));
  if (arrivals.length >= 3) {
    const delivered = ordered.map(function (o) { return o.id; });
    const reversed = arrivals.slice().reverse();
    ok(delivered.join(',') !== arrivals.join(','),
       '桩交付顺序与到达顺序不同: 到达 ' + arrivals.join(',') + ' → 交付 ' + delivered.join(','));
    ok(delivered.join(',') !== reversed.join(','),
       '桩交付顺序与到达顺序的倒序不同: 到达 ' + arrivals.join(',') + ' → 交付 ' + delivered.join(','));
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

// 直接向模拟 Worker 发送原始消息
function rawCall(msg) {
  return new Promise(function (resolve, reject) {
    const w = makeWorker();
    w.onmessage = function (ev) { resolve(ev.data); };
    w.onerror = function () { reject(new Error('裸调用:worker 报错')); };
    w.postMessage(msg);
  });
}

// 异常与边界场景测试
async function tailPhases() {
  // 相位 8：未知 op 必须返回错误应答
  const unknown = await rawCall({ id: 4242, op: 'no-such-op' });
  eq(unknown.id, 4242, '未知 op 的应答带回原请求 ID');
  eq(unknown.ok, false, '未知 op 返回 ok:false');
  ok(typeof unknown.error === 'string' && unknown.error.indexOf('worker: 未知操作') === 0,
     '未知 op 错误信息包含指定前缀，实得:' + JSON.stringify(unknown.error));
  ok(typeof unknown.error === 'string' && unknown.error.indexOf('no-such-op') >= 0,
     '未知 op 错误信息包含对应 op 名称');

  // 相位 9：onerror 必须被正确处理，拒绝在途请求并标记 codec 失效
  const preset = function () {   };
  const c5 = Io.createCodec({
    workerFactory: function () { const w = makeWorker(); w.onerror = preset; return w; },
  });
  await c5.ping();
  ok(typeof live.onerror === 'function' && live.onerror !== preset,
     '工厂预置的 onerror 被覆盖');

  const c2 = Io.createCodec({ workerFactory: makeWorker });
  const inflight = c2.ping();
  eq(c2.pendingCount(), 1, 'onerror 之前请求已进入 pending 表');
  live.onerror({ message: '模拟 worker 崩溃' });
  await rejects(function () { return inflight; },
                'worker.onerror 触发后在途请求被拒绝', 'Io: 编解码 worker 出错');
  eq(c2.pendingCount(), 0, 'onerror 之后 pending 表清空');
  ok(c2.isDead() === true, 'onerror 之后 codec 被标记为失效');
  ok(live.terminated === true, 'onerror 触发后回收 worker 实例');
  const sentAfterError = live.sent;
  const spawnsAfterError = spawns;
  await rejects(function () { return c2.ping(); },
                '标记失效后再次调用依然失败', 'Io: 编解码 worker 出错');
  eq(live.sent, sentAfterError, '失败调用未向崩溃 worker 发送消息');
  eq(spawns, spawnsAfterError, '失败调用不创建新 worker 实例');
  c2.terminate();
  await rejects(function () { return c2.ping(); },
                '已标记失效的 codec 再次终止时保持原始错误原因',
                'Io: 编解码 worker 出错');

  // 相位 10：terminate() 时在途请求必须被拒绝
  const c3 = Io.createCodec({ workerFactory: makeWorker });
  ok(c3.isDead() === false, 'terminate 之前 isDead() 为 false');
  const inflight3 = c3.ping();
  const w3 = live;
  const spawnsBefore = spawns;
  eq(c3.pendingCount(), 1, 'terminate 之前存在在途请求');
  c3.terminate();
  ok(w3.terminated === true, 'terminate() 终止底层 worker 实例');
  await rejects(function () { return inflight3; },
                'terminate() 触发时在途请求被拒绝', 'terminate');
  eq(c3.pendingCount(), 0, 'terminate() 之后 pending 表清空');
  ok(c3.isDead() === true, 'terminate() 之后 codec 标记为失效');
  await rejects(function () { return c3.ping(); }, 'terminate 之后再次调用失败', 'terminate');
  eq(w3.sent, 1, '失败调用未向已终止 worker 发送消息');
  eq(spawns, spawnsBefore, 'terminate 后再次调用不创建新 worker');

  // 相位 11：postMessage 异常处理
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
                'postMessage 异常时 promise 被拒绝', 'DataCloneError');
  eq(c4.pendingCount(), 0, 'postMessage 异常后 pending 表清空');
  ok(c4.isDead() === false, '单次消息发送失败不将整条通道标记失效');
  const pong4 = await c4.ping();
  ok(pong4.pong === true, '通道在发送异常后仍可正常使用');

  // 相位 12：每请求超时控制
  await (async function () {
    ok(Io.TIMEOUT_MS >= 5000 && Io.TIMEOUT_MS <= 120000,
       '默认超时时间配置合理(实得 ' + Io.TIMEOUT_MS + ' 毫秒)');
    const clocks = [];
    const fakeTimer = {
      setTimeout: function (fn, ms) { const h = { fn: fn, ms: ms, cleared: false }; clocks.push(h); return h; },
      clearTimeout: function (h) { if (h) h.cleared = true; },
    };
    let silentSpawns = 0;
    const silent = Io.createCodec({
      timeoutMs: 1234, timer: fakeTimer,
      workerFactory: function () {
        silentSpawns++;
        return { onmessage: null, onerror: null, terminated: false,
                 postMessage: function () { /* 模拟未响应 */ },
                 terminate: function () { this.terminated = true; } };
      },
    });
    const p = silent.ping();
    eq(clocks.length, 1, '每次请求设置一个超时定时器(实得 ' + clocks.length + ' 个)');
    eq(clocks[0] && clocks[0].ms, 1234,
       '定时器使用传入的 timeoutMs(实得 ' + (clocks[0] ? clocks[0].ms : '(无定时器)') + ')');
    eq(silent.isDead(), false, '未到达超时时间前通道未失效');
    clocks[0].fn();
    await rejects(function () { return p; },
                  '未响应的 worker 在超时后请求被拒绝', '超时');
    eq(silent.isDead(), true,
       '超时后将 codec 标记为失效');
    eq(silent.pendingCount(), 0, '超时后 pending 表清空');
    let lateErr = null;
    try {
      await Promise.race([
        silent.ping(),
        new Promise(function (_, rej) {
          setTimeout(function () { rej(new Error('有界等待超时(1 秒)—— 这次调用没有当场失败')); }, 1000);
        }),
      ]);
    } catch (e6) { lateErr = e6; }
    ok(lateErr && errText(lateErr).indexOf('编解码请求超时') >= 0,
       '标记失效后任何调用立即失败;实得 ' + (lateErr ? JSON.stringify(errText(lateErr)) : '(未拒绝)') +
       '。判据校验包含编解码请求超时');
    eq(silentSpawns, 1,
       '超时后再次调用不创建新 worker(实得 ' + silentSpawns + ' 次调用)');

    // 正常应答测试：应答到达时清除定时器
    const c5b = Io.createCodec({ timeoutMs: 777, timer: fakeTimer, workerFactory: makeWorker });
    const nBefore = clocks.length;
    const pong5 = await c5b.ping();
    ok(pong5.pong === true, '正常应答通道收到 pong 应答');
    eq(clocks.length, nBefore + 1, '正常请求同样设置定时器');
    ok(clocks[nBefore].cleared === true,
       '应答到达时清理对应定时器');
    eq(c5b.isDead(), false, '清理定时器后通道保持正常状态');
    c5b.terminate();
  })();
}
(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 有请求未能在限定时间内返回。');
    process.exit(1);
  }, 120000);

  // 相位 1：环境与常量验证
  ok(Io.workerAvailable() === false, 'Node 环境下 workerAvailable() 返回 false');
  await rejects(function () { return Io.encodeMap(Core.createMap('x', 1, 1)); },
                '无 Worker 环境且未提供 factory 时抛出异常',
                'Worker');
  ok(live === null, '异常调用不创建 Worker 实例');

  // 相位 2：完整协议往返验证
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
            '头部 magic 为 CYRM');
  eq(bytes[4], Core.FORMAT_VERSION, '版本字节 = ' + Core.FORMAT_VERSION);
  eq(bytes[5], 1, '默认走压缩路径(compression = 1)');

  const back = await codec.decodeMap(bytes);
  sameBytes(back.layers[Core.LAYER_SCENE].desc, m.layers[Core.LAYER_SCENE].desc, '往返:场景层一致');
  sameBytes(back.layers[Core.LAYER_FRONT].desc, m.layers[Core.LAYER_FRONT].desc, '往返:前景层一致');
  sameBytes(back.layers[Core.LAYER_BG].rgba, m.layers[Core.LAYER_BG].rgba, '往返:背景层一致');
  eq(back.players, m.players, '往返:出生点一致');
  eq(back.enemies, m.enemies, '往返:敌人一致');
  eq(back.comments, m.comments, '往返:注释一致');

  // 相位 3：未压缩路径往返
  const raw = await codec.encodeMap(m, { compress: false });
  eq(raw[5], 0, 'compress:false 对应 compression 字节为 0');
  const backRaw = await codec.decodeMap(raw);
  sameBytes(backRaw.layers[Core.LAYER_SCENE].desc, m.layers[Core.LAYER_SCENE].desc, '未压缩路径往返一致');

  // 相位 4：错误应答传递
  await rejects(function () { return codec.decodeMap(new Uint8Array(20)); },
                '损坏文件请求被拒绝', 'magic');
  await rejects(function () { return codec.decodeMap(new Uint8Array([1, 2, 3])); },
                '过短文件请求被拒绝', '小于头部');
  const bad = new Uint8Array(bytes);
  bad[5] = 9;                                   // 未知 compression
  await rejects(function () { return codec.decodeMap(bad); }, '未知 compression 抛出异常', 'compression');

  // 相位 5：并发请求按 ID 配对
  (function () {
    const jobs = [];
    for (let n = 1; n <= 6; n++) {
      const mm = fillMap(Core.createMap('c' + n, n, 2), Core.LAYER_SCENE, n * 31);
      jobs.push(codec.encodeMap(mm).then(function (b) { return { n: n, b: b }; }));
    }
    const batch = Promise.all(jobs).then(function (outs) {
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
        ok(allOk, '并发 encode/decode 各自正确配对应答(首个不匹配:' + firstBad + ')');
        eq(codec.pendingCount(), 0, '请求完成后 pending 表清空');
      });
    });
    let timer = null;
    const bound = new Promise(function (_, reject) {
      timer = setTimeout(function () {
        reject(new Error('并发的 encode/decode 有请求在 ' + (PHASE5_TIMEOUT_MS / 1000) +
                         ' 秒内没有 settle —— 至少一条应答没有回到它自己的 promise' +
                         '(按 id 配对错;桩的交付排列见 deliver)'));
      }, PHASE5_TIMEOUT_MS);
    });
    return Promise.race([batch, bound]).finally(function () { clearTimeout(timer); });
  })().catch(function (e) {
    ok(false, '相位 5 未完成(超时 ' + (PHASE5_TIMEOUT_MS / 1000) +
       ' 秒未 settle 或出错): ' + errText(e));
  }).then(function () {

  // 相位 6：ping 与 terminate
  return codec.ping().then(function (p) {
    ok(p.pong === true, 'ping 返回 pong 应答');
    ok(typeof codec.isDead() === 'boolean' && codec.isDead() === false, '正常状态下 isDead() 返回 false');
    codec.terminate();
    ok(live.terminated === true, 'terminate() 终止底层 worker 实例');

    // 相位 7：源码约束验证
    (function () {
      const fs = require('fs'), path = require('path');
      const src = fs.readFileSync(path.join(__dirname, 'worker.js'), 'utf8');
      ok(/importScripts\(['"]core\.js['"]\)/.test(src),
         "worker.js 使用 importScripts('core.js') 引入格式实现");
      ok(src.indexOf('encodeTexLayer') < 0 && src.indexOf('decodeTexLayer') < 0 &&
         src.indexOf('crc32') < 0 && src.indexOf('inflate') < 0,
         'worker.js 不包含冗余格式与压缩逻辑');
      ok(/self\.onmessage\s*=/.test(src), 'worker.js 定义 self.onmessage');
      const io = fs.readFileSync(path.join(__dirname, 'io.js'), 'utf8');
      ok(io.indexOf('new Worker(') >= 0, "io.js 使用 new Worker('worker.js')");
      ok(!/xmlhttprequest|activexobject|importScripts\(|createObjectURL|new\s+Blob\(/i.test(io),
         'io.js 不包含 Blob URL / XHR / importScripts 等降级实现');
    })();

    // 相位 8~11：异常与边界场景测试
    return tailPhases();
  }).then(function () {
    console.log('');
    console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
    if (fail === 0) console.log('WORKER IO SMOKE OK');
    process.exit(fail === 0 ? 0 : 1);
  });
  });
})().catch(function (err) {
  console.error('FAIL: 未捕获异常:');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
