'use strict';

importScripts('core.js');

function errText(e) {
  if (!e) return '未知错误';
  var m = (e.message !== undefined) ? String(e.message) : String(e);
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
