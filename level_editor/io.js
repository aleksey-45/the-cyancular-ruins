'use strict';

globalThis.Io = (() => {
  let worker, failure;
  let sequence = 0;
  const pending = new Map();

  function fail(error) {
    failure = error;
    worker.terminate();
    for (const request of pending.values()) {
      clearTimeout(request.timeout);
      request.reject(error);
    }
    pending.clear();
  }

  function startWorker() {
    worker = new Worker(globalThis.CYRM_OFFLINE?.workerUrl ?? 'worker.js');
    worker.onmessage = ({data}) => {
      const request = pending.get(data.id);
      if (!request) return;
      pending.delete(data.id);
      clearTimeout(request.timeout);
      if (data.ok) request.resolve(data);
      else request.reject(new Error(data.error));
    };
    worker.onerror = event => fail(new Error('编解码 Worker 运行失败：' + event.message));
  }

  function call(op, payload) {
    return new Promise((resolve, reject) => {
      if (failure) throw failure;
      if (!worker) startWorker();
      const id = ++sequence;
      worker.postMessage({id, op, ...payload});
      const timeout = setTimeout(() => fail(new Error('编解码 Worker 在 30 秒内没有响应')), 30000);
      pending.set(id, {resolve, reject, timeout});
    });
  }

  return {
    workerAvailable: () => typeof Worker !== 'undefined',
    encodeMap: async (map, {compress = true} = {}) => (await call('encode', {map, compress})).bytes,
    decodeMap: async bytes => (await call('decode', {bytes})).map,
    importMap: bytes => call('import', {bytes}),
    ping: () => call('ping'),
  };
})();
