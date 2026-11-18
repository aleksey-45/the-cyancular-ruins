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
const EDITOR_ATLAS_PATH = path.join(DEFAULT_ROOT_DIR, 'structure.png');
const PROJECT_ATLAS_PATH = path.join(__dirname, '..', 'assets', 'textures', 'structure.png');
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

// 根据 URL 找到静态资源。路径规范化后超出编辑器目录时拒绝读取。
function staticFileFor(rootDir, urlPath, indexName) {
  let rel;
  try { rel = decodeURIComponent(String(urlPath)); }
  catch (e) { return { status: 400, message: 'URL 编码非法' }; }
  if (rel.indexOf('\0') >= 0) return { status: 400, message: '路径里含空字节' };
  rel = rel.split('\\').join('/');
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
    // HTTP 响应关闭时终止文件读取，避免客户端提前断开后仍在读取。
    res.on('close', function () { stream.destroy(); });
    stream.pipe(res);
  });
}

// 统一使用地图文件的命名规则。扩展名前最多 64 个字符，可用英文字母、数字、下划线和连字符。
const {NAME_PATTERN: MAP_NAME_RE, backupName} = require('./map_files.js');

function isValidMapName(name) {
  return MAP_NAME_RE.test(name);
}

// 文件名通过检查后才能生成地图路径。写入时另外检查路径实际指向的位置。
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

// 这类错误会转换为 HTTP 413，表示请求体过大。
function rejectTooLarge(message) {
  const e = new Error(message);
  e.tooLarge = true;
  return e;
}

// 请求体分块接收，全部读取后合并成一个缓冲区。
function readBody(req, maxBytes) {
  return new Promise(function (resolve, reject) {
    const chunks = [];
    let total = 0;
    let overflow = false;
    req.on('data', function (c) {
      total += c.length;
      if (total > maxBytes) {
        // 超出大小限制后释放已收到的数据，并停止缓存余下的数据。
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

// 写入因安全检查被拒绝时返回 HTTP 403。
function rejectWrite(message) {
  const e = new Error(message);
  e.writeRejected = true;
  return e;
}

// 写入前比较实际路径，防止符号链接将目标指向地图库之外。
function assertWriteTargetInside(mapsDir, target, name) {
  const realDir = fs.realpathSync(mapsDir);
  let st = null;
  try { st = fs.lstatSync(target); }
  catch (e) {
    if (!e || e.code !== 'ENOENT') throw rejectWrite('读不到地图目标的属性,拒绝写入:' + name +
      '(' + (e && e.code ? e.code : String(e)) + ')');
  }
  let realTarget;
  if (st === null) {
    // 新文件还没有实际路径，改用解析过的地图库路径拼接文件名。
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

// 先以独占方式创建目标文件，再移入源文件。有同名地图时会在创建阶段失败。
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

// Host 中的主机名须为 localhost 或 127.0.0.1，端口须与当前连接的本地端口一致。
const ALLOWED_HOSTS = ['127.0.0.1', 'localhost'];
function hostAllowed(req) {
  const localPort = req.socket ? req.socket.localPort : 0;
  if (!localPort) return false;
  const host = String(req.headers.host || '').toLowerCase();
  return ALLOWED_HOSTS.some(function (h) { return host === h + ':' + localPort; });
}

// 修改地图的请求使用 JSON 媒体类型。服务器还会检查浏览器提供的来源信息。
const WRITE_CONTENT_TYPE = 'application/json';

// 请求通过检查后返回 null。拒绝请求时返回 HTTP 状态码和原因。
function writeGuardReject(req) {
  const raw = String(req.headers['content-type'] || '');
  const mediaType = raw.split(';')[0].trim().toLowerCase();
  if (mediaType !== WRITE_CONTENT_TYPE) {
    return { status: 415, message: '写端点只接受 Content-Type: ' + WRITE_CONTENT_TYPE +
      '(非简单内容类型 ⇒ 跨源的浏览器请求会先发预检,而预检不被放行);实得 ' +
      JSON.stringify(raw === '' ? '(缺失)' : raw) };
  }
  // 有 Origin 标头时，将它与本机编辑器的 HTTP 地址比较。
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
    return null;
  }
  // 没有 Origin 时，若 Sec-Fetch-Site 将请求标为跨站，就拒绝写入。
  const site = req.headers['sec-fetch-site'];
  if (site === 'cross-site') {
    return { status: 403, message: '跨源写被拒:没有 Origin 可判,而 Sec-Fetch-Site 是 ' +
      String(site) };
  }
  return null;
}

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
    const file = resolved.file === EDITOR_ATLAS_PATH ? PROJECT_ATLAS_PATH : resolved.file;
    serveFile(res, file, req.method === 'HEAD');
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

// 若指定端口 0，操作系统会分配监听端口。
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
  // 从命令行启动后会打开浏览器。--no-open 关闭自动打开。
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
