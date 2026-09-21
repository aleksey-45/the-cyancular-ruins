// editor_server.js —— 编辑器本地服务器(规格 §4.9)。
// ★ 编辑器**只通过它打开**:`file://` 支持被刻意放弃(规格 §1.2),换来原生 Worker、
//   无同源限制、能直接读写磁盘上的 `maps/*.cyrm`。代价是每次要先起服务器。
// ★ 用 node 写 —— 仓库的编辑器工具链(sync-tiles.js / sync-enemies.js)本来就是 node,
//   不引入新的运行时依赖。
// ★ 只绑 127.0.0.1;端口 8777 刻意避开游戏侧已占用的一切端口
//   (7777 大厅 / 7800+ worker / 7999 测试)。
// ★ 它是**哑文件服务器**:不校验 .cyrm 格式 —— 那是 core.js 的事。
//   服务器若也判一遍格式,就是第二份格式实现,分歧的症状是"编辑器存得下、游戏读不出",且不报错。
// ★ **不做**:认证、TLS、目录浏览、多用户、range 请求。它是本机自用工具,不是服务。
// 用法:node editor_server.js [--port 8777] [--maps <dir>] [--root <dir>] [--no-open]
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8777;
const DEFAULT_ROOT_DIR = __dirname;
const DEFAULT_MAPS_DIR = path.join(__dirname, '..', 'maps');
const DEFAULT_INDEX = 'editor.html';
// ★ 闸 1「一切有硬上限」(规格 §4.3):PUT 的请求体也要有上限,否则一个坏掉的前端
//   循环就能把磁盘写满。取 core.js 的 MAX_BODY_SIZE 同值(64MB)—— 合法文件最坏约
//   19.1MiB(core.js 里那段推导),对合法文件不会误拒,对跑飞的客户端是一道硬闸。
const MAX_MAP_BYTES = 64 * 1024 * 1024;

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

// 静态路径 → 绝对文件路径,并保证它**落在 rootDir 里面**。
// ★ 这是本文件后果最重的一处:没有这道检查,一个本地网页就能读整块磁盘
//   (GET /../../../../Windows/win.ini)。
// ★ 判据刻意用「解析后的绝对路径必须落在 rootAbs 里面」,而不是「字符串里有没有 ..」:
//   后者漏掉 URL 编码(%2e%2e 会被 URL 解析器归一化掉、但 %2f 不会)与一切别的变体,
//   而前者是**结构性**的 —— 无论输入长什么样,解析完都得落在根里面。
// ★ URL 解析器本身也会归一化掉 `..`(实测 /../x → /x),所以这里是**第二道**闸;
//   真正危险的是 /..%2f..(编码过的分隔符),那一个必须靠这一道挡。
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
    // ★ 目录也走这里 → 404:规格 §4.9 明写「不做目录浏览」。
    if (err || !st.isFile()) return sendText(res, 404, '找不到 ' + path.basename(resolved.file));
    res.writeHead(200, {
      'Content-Type': mimeOf(resolved.file),
      'Content-Length': st.size,
      // ★ 一定要关缓存:编辑器是"改完立刻刷新看效果"的工作流,
      //   浏览器缓存住旧 .js 会让用户对着旧代码调半天。
      'Cache-Control': 'no-store',
    });
    if (headOnly) return res.end();
    // ★★ 响应头**已经发出去了**,这一支只能把本次响应中止掉,不能回头改状态码。
    //   ReadStream 的 'error' 必须在这里接管:没人接管就是一次**无人认领的 'error' 事件**
    //   = 未捕获异常 = **整个编辑器服务器进程死掉**(客户端什么响应都收不到,用户只能重启 serve.bat)。
    //   「stat 成功但 open 失败」是真实存在的状态,不是理论:Windows 上文件被 AV/扫描器
    //   独占锁定、ACL 拒绝、负载下的 EMFILE、以及文件在 stat 与 createReadStream 之间被删掉
    //   (编辑器自己重写文件时正会如此)。上面那道 404 只覆盖「stat 失败」,根本走不到这里。
    // ★ 同步抛(createReadStream 的参数非法)与异步 'error' 是同一类「这一次读不出去」,
    //   一并兜住:它们的正确处理都是「中止这一条响应」,而不是把服务器带走。
    let stream;
    try { stream = fs.createReadStream(resolved.file); }
    catch (e) { return res.destroy(); }
    stream.on('error', function () { res.destroy(); });
    // ★ 防泄漏的另一半:客户端提前断开时把**源流**关掉,否则 fd 与流对象一直留到进程结束。
    res.on('close', function () { stream.destroy(); });
    stream.pipe(res);
  });
}

// ── 地图名守卫(规格 §4.9)──
// ★ 没有这一条,一个本地网页就能读写整块磁盘 —— 它是本文件唯一的安全边界,
//   也是规格 §7 风险登记里点名"这条必须写测试"的那一条。
// 只接受**裸文件名**:不接受路径分隔符(/ 与 \)、不接受 ..、不接受空字节、不接受绝对路径。
const MAP_NAME_RE = /^[A-Za-z0-9_\-]+\.cyrm$/;
// 规格的正则没有长度上界;这条是防御性补充(真名由 core.js 的 sanitizeName 生成,
// ≤32 字符 + ".cyrm" = 37,64 留了一倍余量)。
const MAX_MAP_NAME_LEN = 64;

function isValidMapName(name) {
  if (typeof name !== 'string') return false;
  if (name.length === 0 || name.length > MAX_MAP_NAME_LEN) return false;
  // 空字节:正则本来就不放行,这里再挡一次 —— 防的是"将来有人把正则改宽"。
  if (name.indexOf('\0') >= 0) return false;
  return MAP_NAME_RE.test(name);
}

function mapPathFor(mapsDir, name) {
  if (!isValidMapName(name)) throw new Error('地图名非法:' + JSON.stringify(name));
  const dir = path.resolve(mapsDir);
  const target = path.resolve(dir, name);
  // 双保险:即便正则哪天被改宽,这里也保证出去的路径一定在 maps/ 里面。
  if (target.indexOf(dir + path.sep) !== 0) throw new Error('地图名越出 maps 目录:' + name);
  return target;
}

// 列地图。★ 只列**打得开**的(名字不过守卫的文件列出来也点不开),但绝不静默 ——
// 跳过的每一个都记一条日志点名。
function listMaps(mapsDir, logger) {
  const out = [];
  let names = [];
  try { names = fs.readdirSync(mapsDir); }
  catch (e) { return out; }                     // 目录不存在 = 空库,不是错误
  names.sort();
  for (const n of names) {
    if (!isValidMapName(n)) { if (logger) logger('跳过不可打开的文件:' + n); continue; }
    let st;
    try { st = fs.statSync(path.join(mapsDir, n)); } catch (e) { continue; }
    if (!st.isFile()) continue;
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
    // ★★ 与 serveStatic 同一条教训(Task 1 的待修 1):响应头**已经发出去了**,
    //   这一支只能把本次响应中止掉,不能回头改状态码。ReadStream 的 'error' 必须在这里接管:
    //   没人接管就是一次**无人认领的 'error' 事件** = 未捕获异常 = **整个编辑器服务器进程死掉**
    //   (而 serve.bat 是整场开着的 ⇒ 一个坏文件把编辑器打下来,用户只能重启)。
    //   「stat 成功但 open 失败」是真实状态,不是理论:Windows 上 AV/扫描器独占锁、ACL 拒绝、
    //   负载下的 EMFILE、以及文件在 stat 与 createReadStream 之间被删掉(编辑器自己正在重写它)。
    //   上面那道 404 只覆盖「stat 失败」,根本走不到这里。
    let stream;
    try { stream = fs.createReadStream(target); }
    catch (e) { return res.destroy(); }
    stream.on('error', function () { res.destroy(); });
    // ★ 防泄漏的另一半:客户端提前断开时把**源流**关掉,否则 fd 与流对象一直留到进程结束。
    res.on('close', function () { stream.destroy(); });
    stream.pipe(res);
  });
}

// ★ Host 白名单闸(所有路由之前)。
//   只绑 127.0.0.1 **挡不住 DNS rebinding**:用户访问一个恶意页面时,那个页面可以把
//   自己的域名解析到 127.0.0.1,于是它就以**同源**身份打到这个服务器上 —— 绑回环完全帮不上忙。
//   今天它只读一个源码目录,危害有限;但只要长出可写接口(计划里的 `PUT /api/map`),
//   它就是「从任意网页触发的任意文件写入」。
//   ★ 判据是 Host 头必须点名**回环主机 + 本服务器实际监听的端口**:
//     正常浏览器访问 http://127.0.0.1:8777/ 发的就是 `127.0.0.1:8777`,而 rebinding 打过来时
//     Host 是那个恶意域名 ⇒ 正好被挡。端口取 `req.socket.localPort`(**不要写死 8777**:
//     startServer 支持 port:0 由系统分配,冒烟测试正是这么跑的)。
const ALLOWED_HOSTS = ['127.0.0.1', 'localhost'];
function hostAllowed(req) {
  const localPort = req.socket ? req.socket.localPort : 0;
  if (!localPort) return false;                       // 拿不到监听端口 → 一律拒(宁严勿松)
  const host = String(req.headers.host || '').toLowerCase();
  // ★ 判据取「host:port 全等」,**不含裸主机名**:浏览器/curl 访问非默认端口时一定带端口,
  //   放行裸名只会多开一扇门(而且裸名只在 80 端口才有意义,那不是本服务器)。
  return ALLOWED_HOSTS.some(function (h) { return host === h + ':' + localPort; });
}

// /api/* 的分派。Task 3 再长出 PUT /api/map。
function handleApi(req, res, parsed, ctx) {
  if (parsed.pathname === '/api/maps') {
    if (req.method !== 'GET' && req.method !== 'HEAD') return sendText(res, 405, '只接受 GET');
    const maps = listMaps(ctx.mapsDir, ctx.logger);
    ctx.logger('列出 ' + maps.length + ' 张地图');
    return sendJson(res, 200, { maps: maps });
  }
  if (parsed.pathname === '/api/map') {
    const name = parsed.searchParams.get('p');
    // ★ 名字不过关一律在**碰文件系统之前**回 400。
    if (!isValidMapName(name)) {
      return sendText(res, 400,
        '地图名非法(只接受裸文件名 ' + MAP_NAME_RE.source + '):' + JSON.stringify(name));
    }
    const target = mapPathFor(ctx.mapsDir, name);
    if (req.method === 'GET' || req.method === 'HEAD') {
      return serveMapFile(res, target, name, req.method === 'HEAD');
    }
    return sendText(res, 405, '只接受 GET');
  }
  return sendText(res, 404, '未知接口 ' + parsed.pathname);
}

function createServer(opts) {
  opts = opts || {};
  const ctx = {
    rootDir: opts.rootDir || DEFAULT_ROOT_DIR,
    mapsDir: opts.mapsDir || DEFAULT_MAPS_DIR,
    indexName: opts.index || DEFAULT_INDEX,
    maxMapBytes: opts.maxMapBytes === undefined ? MAX_MAP_BYTES : opts.maxMapBytes,
    logger: opts.logger || function () {},
  };
  return http.createServer(function (req, res) {
    // ★ 所有路由之前(静态与 /api/* 都过):见 ALLOWED_HOSTS 的说明。
    if (!hostAllowed(req)) {
      return sendText(res, 403, 'Host 头不被接受:' + String(req.headers.host || '(缺失)') +
                                '(只接受本机回环地址)');
    }
    let parsed;
    try { parsed = new URL(req.url, 'http://' + DEFAULT_HOST); }
    catch (e) { return sendText(res, 400, '请求 URL 非法'); }
    if (parsed.pathname.indexOf('/api/') === 0) return handleApi(req, res, parsed, ctx);
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return sendText(res, 405, '静态路径只接受 GET/HEAD,收到 ' + req.method);
    }
    serveStatic(res, staticFileFor(ctx.rootDir, parsed.pathname, ctx.indexName), req.method === 'HEAD');
  });
}

// 端口占用时"点名是谁占的"(规格 §7 风险登记)。
// ★ 尽力而为:拿不到就退回一句让用户自己查的命令,**绝不抛错** ——
//   它的唯一职责是把错误信息写清楚,它自己失败会把"起不来"变成"起不来且不知道为什么"。
function describePortOwner(port) {
  const hint = '  查占用者:netstat -ano | findstr :' + port + '(最后一列是 PID),再 taskkill /PID <PID> /F';
  if (process.platform !== 'win32') return hint;
  try {
    const out = execFileSync('netstat', ['-ano'], { encoding: 'utf8' });
    const lines = out.split(/\r?\n/).filter(function (l) {
      return l.indexOf(':' + port) >= 0 && /LISTENING/i.test(l);
    });
    if (lines.length) {
      return '  占用者:\n' + lines.map(function (l) { return '    ' + l.trim(); }).join('\n') + '\n' + hint;
    }
  } catch (e) { /* 拿不到就只给 hint */ }
  return hint;
}

function openBrowser(url) {
  try {
    if (process.platform === 'win32') {
      spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore' }).unref();
    } else if (process.platform === 'darwin') {
      spawn('open', [url], { detached: true, stdio: 'ignore' }).unref();
    } else {
      spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();
    }
  } catch (e) {
    console.error('[editor] 打开浏览器失败(请手动访问 ' + url + '):' + e.message);
  }
}

// 绑定并起服务。port:0 = 由系统分配一个空闲端口(冒烟测试用,互不打架)。
function startServer(opts) {
  opts = opts || {};
  const host = opts.host || DEFAULT_HOST;
  const port = opts.port === undefined ? DEFAULT_PORT : opts.port;
  const server = createServer(opts);
  return new Promise(function (resolve, reject) {
    server.once('error', function (err) {
      if (err && err.code === 'EADDRINUSE') {
        return reject(new Error('端口 ' + port + ' 已被占用 —— 编辑器服务器起不来。\n' +
                                describePortOwner(port)));
      }
      reject(err);
    });
    server.listen(port, host, function () {
      const addr = server.address();
      const url = 'http://' + host + ':' + addr.port + '/';
      // ★ 默认**不**弹浏览器:弹浏览器是命令行入口的事(startServer 是给测试与嵌入方用的)。
      //   反过来(库默认弹)会让每一个冒烟用例都在开发机上弹出一个浏览器窗口。
      if (opts.openBrowser === true) openBrowser(url);
      resolve({ server: server, port: addr.port, host: host, url: url });
    });
  });
}

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--no-open') o.openBrowser = false;
    else if (a === '--port') { const n = parseInt(argv[++i], 10); if (isFinite(n)) o.port = n; }
    else if (a === '--maps') o.mapsDir = argv[++i];
    else if (a === '--root') o.rootDir = argv[++i];
    else console.error('[editor] 未知参数 ' + a);
  }
  return o;
}

if (require.main === module) {
  const opts = parseArgs(process.argv.slice(2));
  // ★ 只有命令行入口默认开浏览器;--no-open 关掉(parseArgs 会写进 openBrowser:false)。
  startServer(Object.assign({ openBrowser: true }, opts)).then(function (r) {
    console.log('[editor] 服务器就绪 ' + r.url);
    console.log('[editor] 静态根 ' + path.resolve(opts.rootDir || DEFAULT_ROOT_DIR));
    console.log('[editor] 地图目录 ' + path.resolve(opts.mapsDir || DEFAULT_MAPS_DIR));
  }).catch(function (err) {
    console.error('[editor] 启动失败:' + (err && err.message ? err.message : String(err)));
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_HOST: DEFAULT_HOST, DEFAULT_PORT: DEFAULT_PORT,
  DEFAULT_ROOT_DIR: DEFAULT_ROOT_DIR, DEFAULT_MAPS_DIR: DEFAULT_MAPS_DIR,
  DEFAULT_INDEX: DEFAULT_INDEX, MAX_MAP_BYTES: MAX_MAP_BYTES,
  MIME: MIME, mimeOf: mimeOf, sendText: sendText, sendJson: sendJson,
  staticFileFor: staticFileFor, serveStatic: serveStatic, handleApi: handleApi,
  MAP_NAME_RE: MAP_NAME_RE, MAX_MAP_NAME_LEN: MAX_MAP_NAME_LEN,
  isValidMapName: isValidMapName, mapPathFor: mapPathFor, listMaps: listMaps,
  serveMapFile: serveMapFile,
  createServer: createServer, startServer: startServer,
  describePortOwner: describePortOwner, openBrowser: openBrowser, parseArgs: parseArgs,
};
