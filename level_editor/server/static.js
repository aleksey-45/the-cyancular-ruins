'use strict';

const fs = require('fs');
const path = require('path');

const { mimeOf, sendText } = require('./http_util.js');

// 静态路径 → 绝对文件路径,并保证它落在 rootDir 里面。
// 判据刻意是「解析后的绝对路径必须落在 rootAbs 里面」而不是「字符串里有没有 ..」:后者漏掉编码过的
// 分隔符(/..%2f.. 不会被 URL 解析器归一化),前者是结构性的 —— 无论输入长什么样都得落在根里面。
function staticFileFor(rootDir, urlPath, indexName) {
  let rel;
  try { rel = decodeURIComponent(String(urlPath)); }
  catch (e) { return { status: 400, message: 'URL 编码非法' }; }
  if (rel.indexOf('\0') >= 0) return { status: 400, message: '路径里含空字节' };
  rel = rel.split('\\').join('/');                 // Windows 上反斜杠也是分隔符
  if (rel === '/' || rel === '') rel = '/' + indexName;
  const rootAbs = path.resolve(rootDir);
  const target = path.resolve(rootAbs, '.' + (rel.charAt(0) === '/' ? rel : '/' + rel));
  if (target !== rootAbs && target.indexOf(rootAbs + path.sep) !== 0) {
    return { status: 403, message: '路径越出静态根目录' };
  }
  return { status: 200, file: target };
}

function serveStatic(res, resolved, headOnly) {
  if (resolved.status !== 200) return sendText(res, resolved.status, resolved.message);
  fs.stat(resolved.file, function (err, st) {
    if (err || !st.isFile()) return sendText(res, 404, '找不到 ' + path.basename(resolved.file));   // 目录也走这里:不做目录浏览
    res.writeHead(200, {
      'Content-Type': mimeOf(resolved.file),
      'Content-Length': st.size,
      'Cache-Control': 'no-store',      // 编辑器是"改完立刻刷新看效果"的工作流,缓存住旧 .js 会白调半天
    });
    if (headOnly) return res.end();
    // ★★ 响应头已经发出去了,这一支只能中止本次响应。ReadStream 的 'error' 必须在这里接管:
    //   无人认领的 'error' 事件 = 未捕获异常 = 整个服务器进程死掉(上面那道 404 只覆盖 stat 失败,
    //   而「stat 成功但 open 失败」是真实状态:Windows 上 AV/扫描器独占锁、ACL、EMFILE)。
    let stream;
    try { stream = fs.createReadStream(resolved.file); }
    catch (e) { return res.destroy(); }
    stream.on('error', function () { res.destroy(); });
    res.on('close', function () { stream.destroy(); });     // 防 fd 泄漏:客户端提前断开时关掉源流
    stream.pipe(res);
  });
}

module.exports = { staticFileFor: staticFileFor, serveStatic: serveStatic };
