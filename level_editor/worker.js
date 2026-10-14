'use strict';

importScripts('core.js');

function errText(e) {
  if (!e) return '未知错误';
  var m = (e.message !== undefined) ? String(e.message) : String(e);
  if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
  return m === '' ? String(e) : m;
}

// 避免使用 transfer 转移 Uint8Array 所有权，保持结构化克隆以确保环境兼容性
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
