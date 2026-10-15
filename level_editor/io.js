// io.js —— 编解码 async 门面(规格 §4.3 闸 3):写成 async 只为对齐 Worker 的异步通信,让 ui/ 更直。
// ★ Worker 起不来就当场抛错,没有主线程兜底 —— 静默退回主线程会悄悄取消"一帧都不阻塞"这条保证。
// ★ 本文件没有 errText():错误文本由 worker.js 的 reply 一处格式化后经 {ok:false, error} 原样带回。
'use strict';

globalThis.Io = (function () {
  'use strict';

  var seq = 0;

  // ★ 每请求超时:worker 被挂住而没发 onerror 时,await 永远不 settle(没有异常、没有日志);
  //   超时是唯一能把"悬挂"变成"一次响亮的失败"的东西,30 秒远超真算力(毫秒级),不会假红(推导见 docs/eng/editor-io.md)。
  var DEFAULT_TIMEOUT_MS = 30000;

  // ★ timer 注入契约:setTimeout 与 clearTimeout 必须成对给 —— 缺后者,应答到达时撤不掉闹钟。
  function defaultTimer() {
    return {
      setTimeout: function (fn, ms) { return setTimeout(fn, ms); },
      clearTimeout: function (h) { clearTimeout(h); },
    };
  }

  function defaultFactory() {
    if (typeof Worker === 'undefined') {
      throw new Error('Io: 本环境没有 Worker —— 编辑器只通过 HTTP 打开(规格 §4.9),' +
                      'file:// 下没有 Worker。请用 serve.bat 起服务器再打开页面。');
    }
    return new Worker('worker.js');
  }

  function createCodec(opts) {
    opts = opts || {};
    var factory = opts.workerFactory || defaultFactory;
    var timer = opts.timer || defaultTimer();
    // ★ timeoutMs <= 0 = 关掉超时(嵌入方自己控);缺省用 DEFAULT_TIMEOUT_MS。
    var timeoutMs = (opts.timeoutMs === undefined || opts.timeoutMs === null)
      ? DEFAULT_TIMEOUT_MS : opts.timeoutMs;
    var worker = null;
    var pending = new Map();
    var dead = null;

    // ★ 答复到达与发出失败两条路都必须撤闹钟:漏掉答复到达,每次成功请求都会在 30 秒后打死整条链。
    function clearEntry(entry) {
      if (entry && entry.timer !== null) {
        timer.clearTimeout(entry.timer);
        entry.timer = null;
      }
    }

    // ★ 先置空引用再 terminate:terminate 抛错也不留下一个看着还活着的 worker。
    function reapWorker() {
      var w = worker;
      worker = null;
      if (w && typeof w.terminate === 'function') w.terminate();
    }
    // ★★ 整条链死掉的唯一收口:标死 + 拒光在飞 + 清表 + 回收 worker —— terminate、onerror 与超时都走这里。
    //   dead 只认第一个错因;回收放最后:worker.terminate() 万一抛,在飞的 promise 也已经拿到失败了。
    function failAll(err) {
      if (dead === null) dead = err;
      // ★ 在飞的每一条都连定时器一起撤,免得 30 秒后对一条已经死透的链再响一次。
      pending.forEach(function (p) { clearEntry(p); p.reject(err); });
      pending.clear();
      reapWorker();
    }

    function ensure() {
      if (dead) throw dead;
      if (worker) return worker;
      worker = factory();
      worker.onmessage = function (ev) {
        var m = (ev && ev.data) ? ev.data : {};
        var p = pending.get(m.id);
        // ★ 表里没有的应答直接丢(只可能来自 terminate 前那一批),否则上一次的迟到结果会写进这一次的 promise。
        if (!p) return;
        pending.delete(m.id);
        clearEntry(p);                   // ★ 答复到了 ⇒ 那个闹钟必须撤掉(见 clearEntry)
        if (m.ok) p.resolve(m);
        else p.reject(new Error(m.error || 'worker 报告失败但没给原因'));
      };
      // ★ 无条件覆盖 onerror:写成 if 判断时,自带 onerror 的 worker 就不订阅本 codec 的失败处理了。
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
        var entry = { resolve: resolve, reject: reject, timer: null };
        // ★★ 回调里不自己拒这一条,而是走唯一收口 failAll:只拒自己那一条(不标死)的话,
        //   下一次调用会静默再起一个 worker,变成"每 30 秒一次失败"的死循环。
        if (timeoutMs > 0) {
          entry.timer = timer.setTimeout(function () {
            entry.timer = null;            // 这个闹钟已经响过,别再撤销一次
            failAll(new Error('Io: 编解码请求超时(' + timeoutMs + ' 毫秒没有应答)—— ' +
                              'worker 多半已经死了(它没有发 onerror)。这条链已标死,' +
                              '之后的每一次调用都会**当场**失败,而不是静默再起一个 worker。'));
          }, timeoutMs);
        }
        pending.set(id, entry);
        var msg = { id: id, op: op };
        for (var k in payload) msg[k] = payload[k];
        try {
          w.postMessage(msg);
        } catch (e) {
          // ★ postMessage 抛(不可结构化克隆的 map)时只清自己那条:单条消息发不出去不等于整条链坏了。
          //   表里那条不删,resolver 被永久攥着、pendingCount() 再也回不到 0;闹钟不撤,30 秒后还会误杀整条链。
          clearEntry(entry);
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
        // ★ terminate 之后不可能再有应答,在飞请求必须当场拒掉并连带标死(两条死法与超时逐字只走 failAll)。
        failAll(new Error('Io: codec 已被 terminate() —— 在飞的请求不会再有应答'));
      },
    };
  }

  var shared = null;
  function sharedCodec() { if (!shared) shared = createCodec(); return shared; }

  return {
    createCodec: createCodec,
    TIMEOUT_MS: DEFAULT_TIMEOUT_MS,
    workerAvailable: function () { return typeof Worker !== 'undefined'; },
    encodeMap: function (map, o) { return sharedCodec().encodeMap(map, o); },
    decodeMap: function (bytes) { return sharedCodec().decodeMap(bytes); },
    ping: function () { return sharedCodec().ping(); },
  };
})();
