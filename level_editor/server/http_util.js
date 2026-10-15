'use strict';

const path = require('path');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.cyrm': 'application/octet-stream',
};
function mimeOf(filePath) {
  return MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
}

function sendText(res, status, message) {
  const body = Buffer.from(message + '\n', 'utf8');
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}
function sendJson(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

// 请求体超限:带显式标记,让 receiveMapFile 能把它与别的写失败分开(超限 413 / 安全闸 403 / 其余 500)。
// 与 rejectWrite 同一条纪律:用标记,不认错误文本 —— 改字面量不会让状态码静默退化。
function rejectTooLarge(message) {
  const e = new Error(message);
  e.tooLarge = true;
  return e;
}

// 读请求体,带硬上限。超限守的是内存不是带宽:超限之后不再收集,但仍把请求读完再回 413
// (中途 destroy 会让客户端拿到 ECONNRESET,而不是那条错误信息)。
function readBody(req, maxBytes) {
  return new Promise(function (resolve, reject) {
    const chunks = [];
    let total = 0;
    let overflow = false;
    req.on('data', function (c) {
      total += c.length;
      if (total > maxBytes) {
        // 判在 push 之前(与 core.js 的 inflateBytes 同款):先收后判等于已经把超限数据存住了。
        overflow = true;
        chunks.length = 0;
        return;
      }
      if (!overflow) chunks.push(c);
    });
    req.on('end', function () {
      if (overflow) return reject(rejectTooLarge('请求体超过 ' + maxBytes + ' 字节上限'));
      resolve(Buffer.concat(chunks, total));
    });
    req.on('error', reject);
  });
}

module.exports = {
  MIME: MIME, mimeOf: mimeOf, sendText: sendText, sendJson: sendJson,
  rejectTooLarge: rejectTooLarge, readBody: readBody,
};
