'use strict';
// tests/worker_io/30_error_paths.js —— 未知 op / onerror / terminate / postMessage 抛:四条静默失败路径(看着没事,其实请求挂着或错误被吞)。
const Core = globalThis.Core;
const Io = globalThis.Io;

// ── 相位 ⑧~⑪ 全是"静默失败"那一类;它们各自新建 worker 会顶掉 live,故排在 ⑥ 的 live.terminated 之后 ──
async function tailPhases() {
  // ==== 相位 ⑧ 未列出的 op:worker.js 必须响亮应答,不能沉默 ====
  const unknown = await rawCall({ id: 4242, op: 'no-such-op' });
  eq(unknown.id, 4242, '未知 op 的应答带回**原请求的 id**(调用方能配上对)');
  eq(unknown.ok, false, '★ 未知 op → ok:false(不静默丢弃、也不假装成功)');
  ok(typeof unknown.error === 'string' && unknown.error.indexOf('worker: 未知操作') === 0,
     '★ 未知 op 的 error 文本 = 「worker: 未知操作 …」(brief 第 16 行钉的形状),实得:' +
     JSON.stringify(unknown.error));
  ok(typeof unknown.error === 'string' && unknown.error.indexOf('no-such-op') >= 0,
     '未知 op 的 error 里带上那个 op 名(报错要能定位是哪个 op)');

  // ==== 相位 ⑨ onerror:必须被订阅,且把在飞请求响亮拒掉并把 codec 标死 ====
  // ⑨a 工厂预置了 onerror —— io.js 必须无条件覆盖它(有就不装 = 失败处理静默失效)。
  const preset = function () { /* 工厂自带的 onerror:旧实现会因此**不**订阅本 codec 的处理 */ };
  const c5 = Io.createCodec({
    workerFactory: function () { const w = makeWorker(); w.onerror = preset; return w; },
  });
  await c5.ping();
  ok(typeof live.onerror === 'function' && live.onerror !== preset,
     '★ 工厂预置的 onerror 被**覆盖**(不是"有就不装" —— 有就不装 = 崩溃后所有在飞请求永久悬挂)');

  const c2 = Io.createCodec({ workerFactory: makeWorker });
  const inflight = c2.ping();
  eq(c2.pendingCount(), 1, 'onerror 之前那条请求确实进了 pending 表(下面才有的可挂)');
  live.onerror({ message: '模拟 worker 崩溃' });
  await rejects(function () { return inflight; },
                '★ worker.onerror → 在飞请求**当场被拒**(不是永远挂着)', 'Io: 编解码 worker 出错');
  eq(c2.pendingCount(), 0, 'onerror 之后 pending 表清空(没有留住不 settle 的 resolver)');
  ok(c2.isDead() === true, 'onerror 之后 codec 被标死(isDead() === true)');
  // ★ 两条死法必须收场一致:terminate() 会真的回收底层 worker,而 onerror 那条一度只标死、把 worker 引用留着(线程一直活着并被这个 codec 引到页面关掉为止)。
  ok(live.terminated === true, '★ onerror 死法与 terminate 死法一样会**回收 worker**(线程不残留、引用不挂着)');
  const sentAfterError = live.sent;
  const spawnsAfterError = spawns;
  await rejects(function () { return c2.ping(); },
                '★ 标死之后**再调用也失败** —— 不静默新建 worker 重试', 'Io: 编解码 worker 出错');
  eq(live.sent, sentAfterError, '那次失败没有**又往同一个(已崩的)worker 投一条消息**');
  eq(spawns, spawnsAfterError, '★ 那次失败也没有**另起一个 worker** 重试(测试工厂的调用次数不变)');
  // ★★ 死因只认第一个(由 failAll 里的 if (dead === null) 保证):对已死的 codec 再调一次 terminate() 也不许改写死因,否则排查时拿到的不是谁先把它弄死的。
  c2.terminate();
  await rejects(function () { return c2.ping(); },
                '★ 已死的 codec 再死一次:死因仍是**最先**那一个(不被后一次覆盖)',
                'Io: 编解码 worker 出错');

  // ==== 相位 ⑩ terminate() 时在飞的请求必须被拒,不能留悬挂 promise ====
  const c3 = Io.createCodec({ workerFactory: makeWorker });
  ok(c3.isDead() === false, 'terminate 之前 isDead() === false');
  const inflight3 = c3.ping();
  // ★ worker 是惰性建的(第一次调用才 factory()),故 live 必须在调用之后取。
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
  // ★ 两条计数各钉各的:w3.sent 只看得见"又往那个已 terminate 的 worker 投了一条",看不见"偷偷新建了一个"(新 worker 有自己的 sent)。
  eq(w3.sent, 1, '那次失败没有**又往那个已 terminate 的 worker 投一条消息**');
  eq(spawns, spawnsBefore, '★ 那次失败也没有**另起一个 worker**(测试工厂的调用次数不变)');

  // ==== 相位 ⑪ postMessage 抛(浏览器里不可克隆的 map 就是 DataCloneError)====
  // ★ 钉的是账目:单条消息发不出去时表里那条必须被清掉,否则 pendingCount() 再也回不到 0、resolver 也一直被攥着。
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

module.exports = tailPhases();
