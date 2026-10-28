'use strict';

globalThis.Io = (function () {
  'use strict';

  var seq = 0;

  // 请求超时时间（30 秒）。
  // 当 Worker 进程异常退出或挂起未触发 onerror 时，避免请求永久挂起。
  var DEFAULT_TIMEOUT_MS = 30000;

  // 默认定时器包装，便于测试时注入时钟模拟
  function defaultTimer() {
    return {
      setTimeout: function (fn, ms) { return setTimeout(fn, ms); },
      clearTimeout: function (h) { clearTimeout(h); },
    };
  }

  function defaultFactory() {
    if (typeof Worker === 'undefined') {
      throw new Error('Io: 浏览器不支持 Web Worker，请使用支持 Worker 的浏览器。');
    }
    return new Worker(globalThis.CYRM_OFFLINE ? globalThis.CYRM_OFFLINE.workerUrl : 'worker.js');
  }

  // 单个编解码通道：管理 Worker 实例与在途请求映射
  function createCodec(opts) {
    opts = opts || {};
    var factory = opts.workerFactory || defaultFactory;
    var timer = opts.timer || defaultTimer();
    // timeoutMs <= 0 表示关闭超时检查，默认使用 DEFAULT_TIMEOUT_MS
    var timeoutMs = (opts.timeoutMs === undefined || opts.timeoutMs === null)
      ? DEFAULT_TIMEOUT_MS : opts.timeoutMs;
    var worker = null;
    var pending = new Map();
    var dead = null;

    // 清除在途请求的超时定时器
    function clearEntry(entry) {
      if (entry && entry.timer !== null) {
        timer.clearTimeout(entry.timer);
        entry.timer = null;
      }
    }

    // 终止 Worker 实例
    function reapWorker() {
      var w = worker;
      worker = null;
      if (w && typeof w.terminate === 'function') w.terminate();
    }

    // 标记通道失败，拒绝所有在途请求并清理 Worker 实例
    function failAll(err) {
      if (dead === null) dead = err;
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
        // 丢弃未记录的应答（如已超时的请求）
        if (!p) return;
        pending.delete(m.id);
        clearEntry(p);
        if (m.ok) p.resolve(m);
        else p.reject(new Error(m.error || 'worker 报告失败但没给原因'));
      };
      // 统一监听 Worker 错误并终止当前通道
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
        // 设置请求超时定时器
        if (timeoutMs > 0) {
          entry.timer = timer.setTimeout(function () {
            entry.timer = null;
            failAll(new Error('Io: 编解码请求超时(' + timeoutMs + ' 毫秒没有应答)—— ' +
                              'worker 多半已经死了(它没有发 onerror)。这条链已标死,' +
                              '之后的每一次调用都会当场失败,而不是静默再起一个 worker。'));
          }, timeoutMs);
        }
        pending.set(id, entry);
        var msg = { id: id, op: op };
        for (var k in payload) msg[k] = payload[k];
        try {
          w.postMessage(msg);
        } catch (e) {
          // postMessage 失败（如结构化克隆异常）时清理当前请求，但不标记整条通道失效
          clearEntry(entry);
          pending.delete(id);
          throw e;
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
        // 主动终止：拒绝所有在途请求并标记通道失效
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
