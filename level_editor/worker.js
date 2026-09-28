// worker.js —— 闸 3:二进制编解码 + CRC32 进 Web Worker(规格 §4.3)。
// ★ 编辑器只走 HTTP(规格 §4.9),故 `new Worker('worker.js')` **原生可用** ——
//   不需要 Blob URL 那种绕法,也**不需要降级路径**:主线程一帧都不阻塞。
// ★ 经典 Worker(不是 module worker):importScripts 同步加载 core.js,于是 worker 里
//   **只有一份格式实现**。CRC32 与 deflate 都住在 core.js 的 encodeMap/decodeMap 里,
//   本文件**一个字节的格式逻辑都不重复** —— 第二份实现的症状是"编辑器存得下、游戏读不出",
//   而且不报错。
// ★ 本文件刻意写成薄壳:只做消息收发。
'use strict';

importScripts('core.js');

function errText(e) {
  if (!e) return '未知错误';
  var m = (e.message !== undefined) ? String(e.message) : String(e);
  // core.js 在"Zlib 尾损坏"那一档抛的是**无 message 的 TypeError**,细节在 e.cause
  // (计划 1 账本 Task 7 Minor 2 实测)。不回退读它就等于把错误信息丢掉。
  if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
  return m === '' ? String(e) : m;
}

// ★ 刻意**不**用 transfer 列表搬 Uint8Array:一次保存/载入才走一趟,复制那点字节
//   远比"transfer 之后 buffer 被 detach"这一类跨环境差异便宜。少一个变量。
function reply(id, payload) {
  var msg = { id: id };
  for (var k in payload) msg[k] = payload[k];
  self.postMessage(msg);
}

self.onmessage = function (ev) {
  var msg = ev.data || {};
  var id = msg.id;
  var op = msg.op;
  if (op === 'ping') { reply(id, { ok: true, pong: true }); return; }
  if (op === 'encode') {
    Core.encodeMap(msg.map, { compress: msg.compress !== false }).then(function (bytes) {
      reply(id, { ok: true, bytes: bytes });
    }).catch(function (e) {
      reply(id, { ok: false, error: errText(e) });
    });
    return;
  }
  if (op === 'decode') {
    Core.decodeMap(msg.bytes).then(function (map) {
      reply(id, { ok: true, map: map });
    }).catch(function (e) {
      reply(id, { ok: false, error: errText(e) });
    });
    return;
  }
  reply(id, { ok: false, error: 'worker: 未知操作 ' + op });
};
