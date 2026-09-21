// io.js —— 编解码 async 门面(规格 §4.3 闸 3)。
// ★ 写成 async **不是**为了降级:编辑器只走 HTTP,Worker 原生可用。理由只有一条 ——
//   Worker 通信本来就是异步的,写成 async 让 ui.js 里的导入/导出/自动存更直。
// ★★ Worker 起不来 = **当场抛错**,没有主线程兜底:静默退回主线程会把"一帧都不阻塞"
//    这条保证悄悄取消,而症状是"大图保存时页面卡一下" —— 没人会把它当成 bug 报。
'use strict';

globalThis.Io = (function () {
  'use strict';

  var seq = 0;

  function errText(e) {
    if (!e) return '未知错误';
    var m = (e.message !== undefined) ? String(e.message) : String(e);
    if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
    return m === '' ? String(e) : m;
  }

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
    var started = 0;

    function failAll(err) {
      dead = err;
      pending.forEach(function (p) { p.reject(err); });
      pending.clear();
    }

    function ensure() {
      if (dead) throw dead;
      if (worker) return worker;
      worker = factory();
      started++;
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
      if (typeof worker.onerror !== 'function') {
        worker.onerror = function (ev) {
          var msg = (ev && ev.message) ? ev.message : 'worker 内部错误';
          failAll(new Error('Io: 编解码 worker 出错 —— ' + msg));
        };
      }
      return worker;
    }

    function call(op, payload) {
      return new Promise(function (resolve, reject) {
        var w = ensure();
        var id = ++seq;
        pending.set(id, { resolve: resolve, reject: reject });
        var msg = { id: id, op: op };
        for (var k in payload) msg[k] = payload[k];
        w.postMessage(msg);
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
      workerStarts: function () { return started; },
      isDead: function () { return dead !== null; },
      terminate: function () {
        if (worker && typeof worker.terminate === 'function') worker.terminate();
        worker = null;
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
