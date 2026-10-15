'use strict';

const fs = require('fs');
const path = require('path');

const { sendText } = require('./http_util.js');
const { isValidMapName } = require('./map_names.js');

// 列地图:只列打得开的(名字不过守卫的文件列出来也点不开),但绝不静默 —— 三条跳过路径
// (名字不过守卫 / stat 抛错 / 不是文件)每一个都点名记日志,否则磁盘上有东西而库里没有最难自查。
function listMaps(mapsDir, logger) {
  const out = [];
  let names = [];
  try { names = fs.readdirSync(mapsDir); }
  catch (e) { return out; }                     // 目录不存在 = 空库,不是错误
  names.sort();
  for (const n of names) {
    if (!isValidMapName(n)) { if (logger) logger('跳过不可打开的文件:' + n); continue; }
    let st;
    try { st = fs.statSync(path.join(mapsDir, n)); }
    catch (e) {
      if (logger) logger('跳过读不到属性的文件:' + n + '(' + (e && e.message ? e.message : String(e)) + ')');
      continue;
    }
    if (!st.isFile()) { if (logger) logger('跳过非文件(同名目录?):' + n); continue; }
    out.push({ name: n, size: st.size, mtime: st.mtimeMs });
  }
  return out;
}

function serveMapFile(res, target, name, headOnly) {
  fs.stat(target, function (err, st) {
    if (err || !st.isFile()) return sendText(res, 404, '找不到地图 ' + name);
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': st.size,
      'Cache-Control': 'no-store',
    });
    if (headOnly) return res.end();
    // ★★ 与 serveStatic 同一条教训:响应头已经发出去了,ReadStream 的 'error' 必须在这里接管 ——
    //   无人认领的 'error' 事件 = 未捕获异常 = 整个服务器进程死掉(上面那道 404 只覆盖 stat 失败,
    //   而「stat 成功但 open 失败」在 Windows 上是真实状态,见 docs/eng/editor-server.md)。
    let stream;
    try { stream = fs.createReadStream(target); }
    catch (e) { return res.destroy(); }
    stream.on('error', function () { res.destroy(); });
    res.on('close', function () { stream.destroy(); });     // 防 fd 泄漏:客户端提前断开时关掉源流
    stream.pipe(res);
  });
}

module.exports = { listMaps: listMaps, serveMapFile: serveMapFile };
