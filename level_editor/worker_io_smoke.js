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
let live = null;
function makeWorker() {
  const w = {
    onmessage: null, onerror: null, terminated: false, sent: 0,
    postMessage: function (msg) {
      w.sent++;
      // ★ 异步投递:真 Worker 是异步的;同步回包会掩盖"发完就 terminate"那一类错。
      setImmediate(function () {
        if (w.terminated) return;
        inProc.postMessage = function (out) {
          if (typeof w.onmessage === 'function') w.onmessage({ data: out });
        };
        inProc.onmessage({ data: msg });
      });
    },
    terminate: function () { w.terminated = true; },
  };
  live = w;
  return w;
}

function fillMap(map, L, seed) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (let i = 0; i < a.length; i++) a[i] = ((i * 2654435761 + seed) >>> 0) % (L === Core.LAYER_BG ? 0xFFFFFFFF : 0xFFFF);
  return map;
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

  // ==== 相位 ⑤ 并发:按 id 配对,不许串台 ====
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
        ok(allOk, '★ 6 个并发的 encode/decode 各自拿到**自己那份**结果(按 id 配对,首个不匹配:' + firstBad + ')');
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
      ok(!/xmlhttprequest|activexobject|importScripts\(/i.test(io),
         '★ io.js 里没有 Blob URL / 主线程兜底那类绕法(闸 3 明说不做降级路径)');
    })();

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
