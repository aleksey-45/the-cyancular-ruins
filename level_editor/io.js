// io.js —— 编解码 async 门面(规格 §4.3 闸 3)。
// ★ 写成 async **不是**为了降级:编辑器只走 HTTP,Worker 原生可用。理由只有一条 ——
//   Worker 通信本来就是异步的,写成 async 让 ui.js 里的导入/导出/自动存更直。
// ★★ Worker 起不来 = **当场抛错**,没有主线程兜底:静默退回主线程会把"一帧都不阻塞"
//    这条保证悄悄取消,而症状是"大图保存时页面卡一下" —— 没人会把它当成 bug 报。
// ★ 这里**没有** errText():错误文本在 worker 里就由 worker.js 的 reply(errText(e)) 格式化好,
//   经 {ok:false, error} 原样带回。评审发现 1 —— 本文件曾抄过一份同名的死副本(零调用点):
//   同一条归一化规则存在两份时,改了一份的另一份不会有任何信号。
'use strict';

globalThis.Io = (function () {
  'use strict';

  var seq = 0;

  function defaultFactory() {
    if (typeof Worker === 'undefined') {
      throw new Error('Io: 本环境没有 Worker —— 编辑器只通过 HTTP 打开(规格 §4.9),' +
                      'file:// 下没有 Worker。请用 serve.bat 起服务器再打开页面。');
    }
    return new Worker('worker.js');
  }

  // 一个 codec = 一个 worker + 一张"等应答"的表。
  function createCodec(opts) {
    opts = opts || {};
    var factory = opts.workerFactory || defaultFactory;
    var worker = null;
    var pending = new Map();
    var dead = null;

    // ★ 唯一的"整条链死掉"收口:拒光在飞请求 + 清表 + 标死。
    //   dead 一立,ensure() 就抛 —— 于是之后**任何**调用都当场失败,而不是悄悄再起一个 worker。
    function failAll(err) {
      dead = err;
      pending.forEach(function (p) { p.reject(err); });
      pending.clear();
    }

    function ensure() {
      if (dead) throw dead;
      if (worker) return worker;
      worker = factory();
      worker.onmessage = function (ev) {
        var m = (ev && ev.data) ? ev.data : {};
        var p = pending.get(m.id);
        // ★ 表里没有的应答**直接丢**:它只可能来自 terminate 前发出去的那一批。
        //   不丢的话就是"上一次的迟到结果写进这一次的 promise"。
        if (!p) return;
        pending.delete(m.id);
        if (m.ok) p.resolve(m);
        else p.reject(new Error(m.error || 'worker 报告失败但没给原因'));
      };
      // ★ **无条件**覆盖,不能写成 `if (typeof worker.onerror !== 'function')`:
      //   工厂若返回一个自带 onerror 的 worker,那种写法就**不订阅**本 codec 的失败处理 ——
      //   于是 worker 崩溃后所有在飞请求永久悬挂,而代码看上去"已经处理了 onerror"。
      worker.onerror = function (ev) {
        var msg = (ev && ev.message) ? ev.message : 'worker 内部错误';
        failAll(new Error('Io: 编解码 worker 出错 —— ' + msg));
      };
      return worker;
    }

    function call(op, payload) {
      return new Promise(function (resolve, reject) {
        var w = ensure();
        var id = ++seq;
        pending.set(id, { resolve: resolve, reject: reject });
        var msg = { id: id, op: op };
        for (var k in payload) msg[k] = payload[k];
        try {
          w.postMessage(msg);
        } catch (e) {
          // ★ postMessage 会抛(浏览器里不可结构化克隆的 map 就是 DataCloneError)。
          //   不把表里那条删掉的话:resolver 被永久攥着、pendingCount() 再也回不到 0,
          //   而调用方只看到一次失败 —— "表里悄悄漏了一条"这种账目错没人会去查。
          //   这里只清自己那条:**单条消息发不出去不等于整条链坏了**,codec 不标死。
          pending.delete(id);
          throw e;                       // 在 Promise 执行器里抛 = 这个 promise 被拒
        }
      });
    }

    return {
      encodeMap: function (map, o) {
        return call('encode', { map: map, compress: !(o && o.compress === false) })
          .then(function (m) { return m.bytes; });
      },
      decodeMap: function (bytes) {
        return call('decode', { bytes: bytes }).then(function (m) { return m.map; });
      },
      ping: function () { return call('ping', {}); },
      pendingCount: function () { return pending.size; },
      isDead: function () { return dead !== null; },
      terminate: function () {
        if (worker && typeof worker.terminate === 'function') worker.terminate();
        worker = null;
        // ★ terminate 之后**不可能**再有应答回来(worker 已死,worker.js 的应答也走不回来),
        //   所以在飞请求必须当场拒掉:留着就是永不 settle 的 promise,调用方以为"停掉它
        //   就不再有后台活动"却一直挂在 await 上。连带标死 —— 否则下一次调用会**静默**
        //   新建一个 worker,而调用方以为自己已经把它关掉了。
        if (dead === null) failAll(new Error('Io: codec 已被 terminate() —— 在飞的请求不会再有应答'));
      },
    };
  }

  var shared = null;
  function sharedCodec() { if (!shared) shared = createCodec(); return shared; }

  return {
    createCodec: createCodec,
    workerAvailable: function () { return typeof Worker !== 'undefined'; },
    encodeMap: function (map, o) { return sharedCodec().encodeMap(map, o); },
    decodeMap: function (bytes) { return sharedCodec().decodeMap(bytes); },
    ping: function () { return sharedCodec().ping(); },
  };
})();
