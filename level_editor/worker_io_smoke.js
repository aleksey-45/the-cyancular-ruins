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

// ★★ 两个时限的分工(修复轮 3 的 A1)—— 加的是**一层更紧的边界**,不是替换安全网:
//   · 120000(下面看门狗,值**保持不动**)= 全局兜底:任何一处 stall 的最后一道网。
//   · PHASE5_TIMEOUT_MS = 只罩相位 ⑤ 那个并发批的**局部**时限。它存在的唯一理由是
//     "让红的形态可用":配对错的实现会把某几条请求永久留在表里 → 整批永不 settle,于是
//     整个进程被 120 秒看门狗收走 —— 输出里**没有具名 FAIL**,而且 ⑤ 之后的相位一条都评不到,
//     变异轮的断言总数被截断在 ~17(全绿基线 60),红的形态与跑了多少都不可比。
//     有了它,stall 2 秒就出一条具名 FAIL,⑥~⑪ 照常评。
//   量级:整个冒烟跑完不到一秒(全程是异步消息往返,没有真算力),2 秒是三个数量级的余量,
//   不会在负载重的机器上假红。★ 别拿它替换看门狗 —— 它只罩一个相位,罩不住别处。
const PHASE5_TIMEOUT_MS = 2000;

// ── 假 Worker:把消息异步交给**真的** worker.js,再把应答异步交回 ──
// ★★ 应答**乱序**投递(见 deliver):真 Worker 的应答顺序本来就不保证等于请求顺序
//    (不同 op 耗时不同、调度不确定),而"按 id 配对"这条断言只有**乱序**才吃劲 ——
//    交付顺序既不能是请求顺序(那样"取最老 pending"能蒙对),也不能是它的**倒序**
//    (那样"取最新 pending"能蒙对)。两种错法各有一个共轭排列,故排列必须由应答
//    **自己的 id** 决定,不能是"到达下标的某个函数"。
let live = null;
// ★ 测试自己的工厂调用计数 —— 用来钉住"那次失败**没有另起一个 worker**"。
//   `w.sent` 做不到这件事:新起的 worker 是**另一个对象**、有自己的 sent 计数器,
//   所以 `eq(w3.sent, 1)` 看不见"偷偷新建了一个"(它只看得见"忘了置空 worker,于是又往
//   那个已 terminate 的 worker 投了一条")。修复轮 2 起两条计数各钉各的,标签不再越权。
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

// ★ 攒到"这一批请求全都拿到应答了"才一次吐出,交付顺序**只由各条应答自己的 id 决定**
//   (按 id 升序后整体循环左移 ⌈n/3⌉ 位),与它们**到达的先后**无关。
//   ★★ 为什么必须"既非恒等、也非倒序":相位 ⑤ 那条「按 id 配对」断言吃劲的唯一前提就是
//     交付顺序 ≠ 请求顺序,而两个退化排列各自放走一种错法 ——
//       · 恒等(按到达顺序原样吐)⇒ 桩等价于"应答顺序 = 请求顺序",于是 io.js 的
//         `pending.get(m.id)` 换成"取**最老**的一条 pending"照样全绿;
//       · 倒序(修复轮 1 的写法)⇒ "取**最新**的一条 pending"又恰好次次命中,同样全绿
//         (实测;这正是修复轮 2 的 A:两种错法各有一个共轭排列能让它蒙对)。
//     ⌈n/3⌉ 位左移:n ≥ 3 时 k ∈ [1, n-2],天然避开恒等(k=0)与倒序(k=n-1)。
//     n=1 只有恒等一种排列、n=2 只有恒等与倒序两种 —— 这两个尺寸下"两者都不是"不存在;
//     本文件的并发批只有 n=6(相位 ⑤)与 n=1,故不受影响(将来若真出现 n=2 的批,
//     相位 ⑤ 那条断言的强度会退化到"只钉得住次序、钉不住 id 配对")。
//   判定条件是「已交付数 + 攒着数 === 已发出数」,所以最后一条应答**一定**会被交付
//   (不会因为重排被永久扣住),单独一条请求也是立刻交付。
//   ★ 它有个前提:每条**已发出**的请求最终都会回一条应答(本文件的用例都满足)。若将来出现
//     "发了请求就 terminate、不等应答"的用例,被扣住的那条应答会留到 120 秒看门狗 ——
//     那时该用例本身的形态要改,不是这里漏发。
function deliver(w, out) {
  w.ready.push(out);
  if (w.ready.length !== w.sent - w.delivered) return;
  const batch = w.ready.splice(0, w.ready.length);
  const arrivals = batch.map(function (o) { return o.id; });   // ← 到达序(batch 下面会被就地排序,先留一份)
  batch.sort(function (a, b) { return a.id - b.id; });    // ← 规范序:只由 id 决定,与到达顺序无关
  const k = Math.ceil(batch.length / 3) % batch.length;   // ← 再整体左移 k 位(n=1 → 0)
  const ordered = batch.slice(k).concat(batch.slice(0, k));
  // ★★ 桩**自己**的排列也要断言(修复轮 3 的 A2):相位 ⑤ 那条「按 id 配对」断言的全部力量
  //    都压在上面那条约定("交付序既非到达序、亦非其倒序")上,而它此前只存在于本段注释的
  //    算式里 —— 谁把 ⌈n/3⌉ 改回退化值(0 = 恒等 / reverse() = 倒序),注释不会红、相位 ⑤
  //    也不会红,那条约定就**静默**失效了。这里直接对**实际交付出去的那个序列**下断言。
  //    n ≥ 3 时左移量落进 [1, n-2],两个退化排列都够不着;n=1 只有恒等一种排列、n=2 只有
  //    恒等与倒序两种(见上),故这两个尺寸不判 —— 当前用例的并发批只有 n=6(相位 ⑤)与 n=1。
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
  // ★ 两条死法必须收场一致(修复轮 2 的 B):terminate() 会真的回收底层 worker,onerror
  //   那条一度只标死、把 worker 引用留着 —— 线程一直活着并被这个 codec 引到页面关掉为止。
  ok(live.terminated === true, '★ onerror 死法与 terminate 死法一样会**回收 worker**(线程不残留、引用不挂着)');
  const sentAfterError = live.sent;
  const spawnsAfterError = spawns;
  await rejects(function () { return c2.ping(); },
                '★ 标死之后**再调用也失败** —— 不静默新建 worker 重试', 'Io: 编解码 worker 出错');
  eq(live.sent, sentAfterError, '那次失败没有**又往同一个(已崩的)worker 投一条消息**');
  eq(spawns, spawnsAfterError, '★ 那次失败也没有**另起一个 worker** 重试(测试工厂的调用次数不变)');
  // ★★ D:死因只认**第一个** —— 这句不变量现在由 failAll 里的 `if (dead === null)` 保证
  //   (修复轮 3 把它从 terminate() 的调用点挪进了收口)。这里再走一次收口(对已死的 codec
  //   调 terminate())把它变成承重的:守卫若被删掉,下面那条断言读到的是 "已被 terminate()",
  //   而死因被后来者改写的代价正是"排查时拿到的不是谁先把它弄死的"。
  c2.terminate();
  await rejects(function () { return c2.ping(); },
                '★ 已死的 codec 再死一次:死因仍是**最先**那一个(不被后一次覆盖)',
                'Io: 编解码 worker 出错');

  // ==== 相位 ⑩ terminate() 时在飞的请求必须被拒,不能留悬挂 promise ====
  const c3 = Io.createCodec({ workerFactory: makeWorker });
  ok(c3.isDead() === false, 'terminate 之前 isDead() === false');
  const inflight3 = c3.ping();
  // ★ worker 是**惰性**建的(第一次调用才 factory()),故 live 必须在调用**之后**取。
  const w3 = live;
  const spawnsBefore = spawns;
  eq(c3.pendingCount(), 1, 'terminate 之前确实有一条在飞请求');
  c3.terminate();
  ok(w3.terminated === true, 'terminate() 真的终止了底层 worker');
  await rejects(function () { return inflight3; },
                '★ terminate() → 在飞请求被拒(不是永不 settle、把调用方挂死的 promise)', 'terminate');
  eq(c3.pendingCount(), 0, '★ terminate() 之后 pending 表清空(pendingCount() 回到 0)');
  ok(c3.isDead() === true, '★ terminate() 之后 codec 标死 —— 下一次调用不会**静默**新建一个 worker');
  await rejects(function () { return c3.ping(); }, 'terminate 之后再调用也失败', 'terminate');
  // ★ 两条计数各钉各的(w3.sent 与"有没有另起一个 worker"是**两件事**):
  //   ★★ 本行标签原先还带一句"(worker 引用确实被置空了)" —— 那句话 `eq(w3.sent, 1)`
  //     **证不出来**(修复轮 3 的 B):失败那次调用在 ensure() 里就抛了,根本走不到
  //     postMessage,所以"terminate() 置了 dead 但忘了把 worker 置空"与"确实置空了"
  //     都会让 sent 停在 1,整段 ⑩ 照样全绿。要真证它得给 io.js 加一个读 worker 引用的
  //     API —— 那是给生产面扩权,不做。故只留这条断言真正钉得住的那半句。
  eq(w3.sent, 1, '那次失败没有**又往那个已 terminate 的 worker 投一条消息**');
  eq(spawns, spawnsBefore, '★ 那次失败也没有**另起一个 worker**(测试工厂的调用次数不变)');

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

  // ==== 相位 ⑫ 每请求超时(账本那条延期"接线 ui.js 时再定"**已经到期**)====
  // ★ 这一条钉的是**唯一一种闸 4 看不见的坏法**:worker 被杀/挂住而**没有**发 onerror ⇒
  //   `await Io.encodeMap(…)` 永久悬挂 ⇒ 症状是「Ctrl+S 之后再无反应、控制台干净」
  //   (围栏拦的是**抛**,悬挂连异常都没有,故"控制台干净"是它的特征,不是"没出错")。
  // ★★ 时钟是**注入**的:`timer` 那个缝存在的唯一理由就是让这条断言不用真等 30 秒
  //    (真等的话它会被 120 秒看门狗收走,红的形态变成"整个进程超时"而不是具名 FAIL)。
  // ★★ 这个 IIFE **必须 await**:外层是 `return tailPhases()` 之后紧跟
  //    `process.exit(...)` —— 不 await 的话本相位是在**主链已经打印完结果、正要退出**
  //    的时候才跑,一个悬挂的断言会被退出**切掉**:输出里既没有它的 ok、也没有它的 FAIL
  //    (实测:变异版就是这样在"表清空"那一行之后被截断的 —— 看着像"跑完了",其实是"没跑完")。
  await (async function () {
    // ★ "宽裕"是个范围断言,不是钉死一个字面量:下限保证它**不会**在正常抖动下假红
    //   (真算力是毫秒级 —— 编码一张 125×75 的地图),上限保证它不是一个"等于没装"的值。
    ok(Io.TIMEOUT_MS >= 5000 && Io.TIMEOUT_MS <= 120000,
       '★ 默认超时是**宽裕**的一档(下限别误伤慢机器、上限别等于"没装";实得 ' + Io.TIMEOUT_MS + ' 毫秒)');
    const clocks = [];
    const fakeTimer = {
      setTimeout: function (fn, ms) { const h = { fn: fn, ms: ms, cleared: false }; clocks.push(h); return h; },
      clearTimeout: function (h) { if (h) h.cleared = true; },
    };
    // 一个**永不应答**的 worker:收下消息就丢,而且**不发 onerror**(正是那个坏法)。
    let silentSpawns = 0;
    const silent = Io.createCodec({
      timeoutMs: 1234, timer: fakeTimer,
      workerFactory: function () {
        silentSpawns++;
        return { onmessage: null, onerror: null, terminated: false,
                 postMessage: function () { /* 永不应答 */ },
                 terminate: function () { this.terminated = true; } };
      },
    });
    const p = silent.ping();                      // 不 await:它现在**永远不会** settle
    eq(clocks.length, 1, '★ 一次请求装一个闹钟(实得 ' + clocks.length + ' 个)');
    eq(clocks[0] && clocks[0].ms, 1234,
       '★★ 闹钟用的是注入的 timeoutMs(默认是 ' + Io.TIMEOUT_MS + ' 毫秒;实得 ' +
       (clocks[0] ? clocks[0].ms : '(没有闹钟)') + ')');
    eq(silent.isDead(), false, '前提:还没到点 ⇒ 这条链**没**被标死');
    clocks[0].fn();                               // ← 手动点火(真的等 30 秒会被看门狗收走)
    await rejects(function () { return p; },
                  '★★★ 永不应答的 worker ⇒ 到点被拒(不是在 await 上挂到天荒地老)', '超时');
    eq(silent.isDead(), true,
       '★★★ 超时把整条链**标死**(走的是唯一的收口 failAll —— 死因与 terminate/onerror 同一份账)');
    eq(silent.pendingCount(), 0, '★ 表清空(不泄漏)');
    // ★★ 这条用**有界等待**(而不是 `await rejects`):标死之后 `ensure()` 是**当场**
    //    (同步)抛的,1 秒是四个数量级的余量;而万一实现退化成"静默再起一个 worker"
    //    (那条路就是"到下个 30 秒再失败"的无限循环),有界等待会把它变成一条**具名 FAIL**,
    //    而不是让整条链挂到 120 秒看门狗上(红的形态要可用)。
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
       '★ 标死之后任何调用**当场**失败(而不是静默再起一个 worker);实得 ' +
       (lateErr ? JSON.stringify(errText(lateErr)) : '(没有拒绝 —— 它悬挂了)') +
       '。★ 判据取**编解码请求超时**(不是"超时"两个字):有界等待自己那条错误里也有"超时",' +
       '拿它当判据会把这个断言变成**永远绿**的');
    eq(silentSpawns, 1,
       '★★★ 那次超时之后**没有**再起第二个 worker(实得 ' + silentSpawns + ' 次工厂调用)' +
       ' —— 会"静默重试"的实现这里至少是 2');

    // ★ (对照)答得上的请求必须把闹钟**撤掉**:不撤的话每一次**成功**的请求都会在
    //   30 秒后触发一次超时收口 ⇒ 一条本来好好的链被自己的闹钟打死。
    const c5b = Io.createCodec({ timeoutMs: 777, timer: fakeTimer, workerFactory: makeWorker });
    const nBefore = clocks.length;
    const pong5 = await c5b.ping();
    ok(pong5.pong === true, '⑫ 对照:这条 codec 真答得上(经真 worker.js)');
    eq(clocks.length, nBefore + 1, '⑫ 对照:这条请求也装了自己的闹钟');
    ok(clocks[nBefore].cleared === true,
       '★★★ 应答到达时那个闹钟**被撤了**(`clearEntry` 在答复那条路上)' +
       ' —— 不撤 = 每次成功的请求都会在超时到点后把这条好心肠的 codec 打死');
    eq(c5b.isDead(), false, '⑫ 对照:撤了闹钟之后这条链仍然活着(没有被自己的闹钟误杀)');
    c5b.terminate();
  })();
}
(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 有请求永不 settle。**两种成因都要查**,别只怀疑第一种:');
    console.error('  (1) 那条请求的应答**根本没被投递**(worker 没回 / 桩把它扣住了 / 请求压根没发出去);');
    console.error('  (2) 应答**投给了别的请求**(按 id 配对错 —— 于是两条请求一起悬挂:');
    console.error('      拿到别人应答的那条结果不对、真正该拿的那条永远等不到)。');
    console.error('  先看上面有没有"未抛出异常 / 结果不对"的 FAIL 行(那是 (2) 的特征),');
    console.error('  再看桩的交付顺序(见 deliver)与 worker 是否真的回了包。');
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
        ok(allOk, '★ 6 个并发的 encode/decode 各自拿到**自己那份**结果(应答乱序到达,仍按 id 配对,首个不匹配:' + firstBad + ')');
        eq(codec.pendingCount(), 0, '全部 settle 之后 pending 表清空(不会泄漏)');
      });
    });
    // ★★ A1:本相位的**局部**时限(见文件头 PHASE5_TIMEOUT_MS 的理由)。它加的是
    //    "stall 的形态",不改本相位的任何断言 —— 下面那个 `.catch` 在本相位没走完时
    //    记一条具名 FAIL,好让 ⑥~⑪ 照常评、变异轮的断言总数与基线可比。看门狗仍是最后一道网。
    let timer = null;
    const bound = new Promise(function (_, reject) {
      timer = setTimeout(function () {
        reject(new Error('并发的 encode/decode 有请求在 ' + (PHASE5_TIMEOUT_MS / 1000) +
                         ' 秒内没有 settle —— 至少一条应答没有回到它自己的 promise' +
                         '(按 id 配对错;桩的交付排列见 deliver)'));
      }, PHASE5_TIMEOUT_MS);
    });
    // ★ 正常路径上把定时器收掉:留着它会让进程尾巴上多挂一个 2 秒的 pending timer。
    return Promise.race([batch, bound]).finally(function () { clearTimeout(timer); });
  })().catch(function (e) {
    // ★ 两种来源:上面那条局部时限(配对错 → 整批永不 settle),或本相位自己真出错
    //   (如某次 decode 被拒)。两种都在这里记一条**具名 FAIL**,而且 ⑥~⑪ 照常评 ——
    //   这正是 A1 要的形态:红的那一刻就知道破的是哪条约定、还剩几个相位没评,而不是整轮
    //   被看门狗收走(旧写法下真出错会落到最外层那个"未捕获异常,后面的断言一行都没跑")。
    //   ★ 真因由 errText(e) 带出 —— 别靠猜是哪一种。★ 不是放宽:fail>0 ⇒ 退出码仍是 1。
    ok(false, '★ 相位 ⑤ 未走完(超时 ' + (PHASE5_TIMEOUT_MS / 1000) +
       ' 秒未 settle,或本相位自身出错): ' + errText(e));
  }).then(function () {

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
