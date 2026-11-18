'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8777;
const DEFAULT_ROOT_DIR = __dirname;
const DEFAULT_MAPS_DIR = path.join(__dirname, '..', 'maps');
const DEFAULT_INDEX = 'editor.html';
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

// 解析静态文件相对路径为绝对路径，并校验其必须位于 rootDir 根目录内，防御目录遍历攻击
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

function serveFile(res, target, headOnly) {
  fs.stat(target, function (error, stat) {
    if (error && error.code !== 'ENOENT') return sendFileError(res, error);
    if (error || !stat.isFile()) return sendText(res, 404, '找不到 ' + path.basename(target));
    res.writeHead(200, {
      'Content-Type': mimeOf(target),
      'Content-Length': stat.size,
      'Cache-Control': 'no-store',
    });
    if (headOnly) return res.end();
    const stream = fs.createReadStream(target);
    stream.on('error', function () { res.destroy(); });
    // 客户端提前断开连接时销毁可读流，防止文件句柄泄露
    res.on('close', function () { stream.destroy(); });
    stream.pipe(res);
  });
}

// 地图文件名：裸文件名，1-64 个 ASCII 安全字符加 .cyrm 后缀。
const {NAME_PATTERN: MAP_NAME_RE, backupName} = require('./map_files.js');

function isValidMapName(name) {
  return MAP_NAME_RE.test(name);
}

// 名字已限定为裸文件名，resolve 结果必然在 mapsDir 下；符号链接越界只在写盘前检查。
function mapPathFor(mapsDir, name) {
  if (!isValidMapName(name)) throw new Error('地图名非法:' + JSON.stringify(name));
  return path.resolve(mapsDir, name);
}

function listMaps(mapsDir, logger) {
  const out = [];
  let names = [];
  try { names = fs.readdirSync(mapsDir); }
  catch (error) {
    if (error.code === 'ENOENT') return out;
    throw error;
  }
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

// 请求体超限错误：带有 tooLarge 标记，便于将超限（413）与其他错误区分
function rejectTooLarge(message) {
  const e = new Error(message);
  e.tooLarge = true;
  return e;
}

// 读取请求体并限制最大字节数，防止超大请求耗尽内存
function readBody(req, maxBytes) {
  return new Promise(function (resolve, reject) {
    const chunks = [];
    let total = 0;
    let overflow = false;
    req.on('data', function (c) {
      total += c.length;
      if (total > maxBytes) {
        // 发现超限立即丢弃后续 chunk，不再保留超限数据
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

// 安全校验拦截错误：带有 writeRejected 标记，便于将权限拒绝（403）与写入故障（500）区分
function rejectWrite(message) {
  const e = new Error(message);
  e.writeRejected = true;
  return e;
}

// 针对写路径的符号链接二次校验，确保解析真实路径后仍位于 mapsDir 内
function assertWriteTargetInside(mapsDir, target, name) {
  const realDir = fs.realpathSync(mapsDir);            // 调用方保证 mapsDir 已存在
  let st = null;
  try { st = fs.lstatSync(target); }
  catch (e) {
    if (!e || e.code !== 'ENOENT') throw rejectWrite('读不到地图目标的属性,拒绝写入:' + name +
      '(' + (e && e.code ? e.code : String(e)) + ')');
  }
  let realTarget;
  if (st === null) {
    // 目标文件尚不存在时，校验其父目录必须为 mapsDir
    if (path.resolve(path.dirname(target)) !== path.resolve(mapsDir)) {
      throw rejectWrite('地图目标不在 maps 目录正下方,拒绝写入:' + name);
    }
    realTarget = path.join(realDir, path.basename(target));
  } else {
    try { realTarget = fs.realpathSync(target); }
    catch (e) {
      throw rejectWrite('地图目标读不出真实路径(悬空符号链接?),拒绝写入:' + name +
        '(' + (e && e.code ? e.code : String(e)) + ')');
    }
  }
  if (realTarget.indexOf(realDir + path.sep) !== 0) {
    throw rejectWrite('地图目标经符号链接指到 maps 目录之外,拒绝写入:' + name +
      '(真实路径 ' + realTarget + ' 不在 ' + realDir + ' 里面)');
  }
}

// 同步保留目标名并提交，服务端在一次操作中完成改名。
function installNewFile(source, target) {
  fs.closeSync(fs.openSync(target, 'wx'));
  try { fs.renameSync(source, target); }
  catch (error) { fs.unlinkSync(target); throw error; }
}

async function writeMapAtomic(mapsDir, name, bytes, {create, backup} = {}) {
  const target = mapPathFor(mapsDir, name);
  fs.mkdirSync(mapsDir, { recursive: true });
  assertWriteTargetInside(mapsDir, target, name);
  const tmp = target + '.' + require('node:crypto').randomUUID() + '.tmp';
  const original = backup ? backupName(name) : null;
  fs.writeFileSync(tmp, bytes, {flag: 'wx'});
  try {
    if (original) fs.copyFileSync(target, path.join(mapsDir, original), fs.constants.COPYFILE_EXCL);
    if (create) installNewFile(tmp, target);
    else await fs.promises.rename(tmp, target);
  } finally {
    fs.rmSync(tmp, {force: true});
  }
  return {name, size: bytes.length, backup: original};
}

function queueWrite(ctx, write) {
  const done = ctx.writes.then(write);
  ctx.writes = done.catch(() => {});
  return done;
}

function sendFileError(res, error) {
  if (error.tooLarge) return sendText(res, 413, error.message);
  if (error.writeRejected) return sendText(res, 403, error.message);
  if (error.code === 'EEXIST') return sendText(res, 409, '同名文件已存在');
  if (error.code === 'ENOENT') return sendText(res, 404, '地图文件不存在');
  return sendText(res, 500, error.message);
}

async function receiveMapFile(req, res, name, ctx, options) {
  try {
    const bytes = await readBody(req, ctx.maxMapBytes);
    if (bytes.length === 0) return sendText(res, 400, '地图内容为空');
    const out = await queueWrite(ctx, () => writeMapAtomic(ctx.mapsDir, name, bytes, options));
    ctx.logger('写入 ' + name + ' ' + out.size + ' 字节');
    return sendJson(res, 200, out);
  } catch (error) { return sendFileError(res, error); }
}

function changeMapFile(mapsDir, name, newName) {
  const source = mapPathFor(mapsDir, name);
  assertWriteTargetInside(mapsDir, source, name);
  if (!fs.lstatSync(source).isFile()) throw rejectWrite('地图必须是普通文件');
  if (!newName) {
    fs.unlinkSync(source);
    return {name};
  }
  const target = mapPathFor(mapsDir, newName);
  assertWriteTargetInside(mapsDir, target, newName);
  installNewFile(source, target);
  return {name: newName};
}

// Host 请求头白名单检查，防御 DNS 重绑定攻击
const ALLOWED_HOSTS = ['127.0.0.1', 'localhost'];
function hostAllowed(req) {
  const localPort = req.socket ? req.socket.localPort : 0;
  if (!localPort) return false;                       // 无法获取本地监听端口时直接拒绝
  const host = String(req.headers.host || '').toLowerCase();
  // Host 必须与回环地址及端口完全匹配
  return ALLOWED_HOSTS.some(function (h) { return host === h + ':' + localPort; });
}

// 写接口 CSRF 防护：仅允许 application/json 内容类型并校验 Origin 请求头
const WRITE_CONTENT_TYPE = 'application/json';

// 返回 null = 放行; 返回 {status, message} = 拒绝
function writeGuardReject(req) {
  // 校验 Content-Type 的媒体类型（忽略参数部分）
  const raw = String(req.headers['content-type'] || '');
  const mediaType = raw.split(';')[0].trim().toLowerCase();
  if (mediaType !== WRITE_CONTENT_TYPE) {
    return { status: 415, message: '写端点只接受 Content-Type: ' + WRITE_CONTENT_TYPE +
      '(非简单内容类型 ⇒ 跨源的浏览器请求会先发预检,而预检不被放行);实得 ' +
      JSON.stringify(raw === '' ? '(缺失)' : raw) };
  }
  // 校验跨域 Origin 是否在允许的回环地址白名单内
  const localPort = req.socket ? req.socket.localPort : 0;
  const origin = req.headers['origin'];
  if (origin !== undefined) {
    const sameOrigin = localPort && ALLOWED_HOSTS.some(function (h) {
      return origin === 'http://' + h + ':' + localPort;
    });
    if (!sameOrigin) {
      return { status: 403, message: '跨源写被拒:Origin: ' + String(origin) +
        '(只接受 http://127.0.0.1:' + localPort + ' / http://localhost:' + localPort + ')' };
    }
    // Origin 校验通过后直接放行
    return null;
  }
  // 当缺少 Origin 请求头时，若 Sec-Fetch-Site 标为 cross-site 则拒绝写入
  const site = req.headers['sec-fetch-site'];
  if (site === 'cross-site') {
    return { status: 403, message: '跨源写被拒:没有 Origin 可判,而 Sec-Fetch-Site 是 ' +
      String(site) };
  }
  return null;
}

// /api/* 接口路由分派
function handleApi(req, res, parsed, ctx) {
  if (parsed.pathname === '/api/maps') {
    if (req.method !== 'GET' && req.method !== 'HEAD') return sendText(res, 405, '只接受 GET');
    try {
      const maps = listMaps(ctx.mapsDir, ctx.logger);
      ctx.logger('列出 ' + maps.length + ' 张地图');
      return sendJson(res, 200, {maps});
    } catch (error) { return sendFileError(res, error); }
  }
  if (parsed.pathname === '/api/map') {
    const name = parsed.searchParams.get('p');
    // 地图文件名不合法时在操作文件系统前直接返回 400
    if (!isValidMapName(name)) {
      return sendText(res, 400,
        '地图名非法(只接受裸文件名 ' + MAP_NAME_RE.source + '):' + JSON.stringify(name));
    }
    const target = mapPathFor(ctx.mapsDir, name);
    if (req.method === 'GET' || req.method === 'HEAD') {
      return serveFile(res, target, req.method === 'HEAD');
    }
    if (!['PUT', 'POST', 'DELETE'].includes(req.method)) return sendText(res, 405, '只接受 GET / PUT / POST / DELETE');
    const bad = writeGuardReject(req);
    if (bad) return sendText(res, bad.status, bad.message);
    if (req.method === 'PUT') {
      const create = parsed.searchParams.get('create') === '1';
      const backup = !create && parsed.searchParams.get('backup') === '1';
      return receiveMapFile(req, res, name, ctx, {create, backup});
    }
    const newName = parsed.searchParams.get('to');
    if (req.method === 'POST' && !isValidMapName(newName)) return sendText(res, 400, '新地图名非法');
    return queueWrite(ctx, () => changeMapFile(ctx.mapsDir, name, req.method === 'POST' ? newName : null))
      .then(out => sendJson(res, 200, out), error => sendFileError(res, error));
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
    writes: Promise.resolve(),
  };
  return http.createServer(function (req, res) {
    // 全局 Host 白名单校验
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
    const resolved = staticFileFor(ctx.rootDir, parsed.pathname, ctx.indexName);
    if (resolved.status !== 200) return sendText(res, resolved.status, resolved.message);
    serveFile(res, resolved.file, req.method === 'HEAD');
  });
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

// 绑定并起服务。port:0 = 由系统分配一个空闲端口（冒烟测试用）
function startServer(opts) {
  opts = opts || {};
  const host = opts.host || DEFAULT_HOST;
  const port = opts.port === undefined ? DEFAULT_PORT : opts.port;
  const server = createServer(opts);
  return new Promise(function (resolve, reject) {
    server.once('error', reject);
    server.listen(port, host, function () {
      const addr = server.address();
      const url = 'http://' + host + ':' + addr.port + '/';
      // 启动时仅在明确指定时自动打开浏览器（避免自动化测试时弹出窗口）
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
  // 命令行启动时默认打开浏览器，--no-open 可关闭该行为
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
  isValidMapName, writeMapAtomic, startServer,
};
