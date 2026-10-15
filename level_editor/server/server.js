'use strict';

const http = require('http');
const { spawn, execFileSync } = require('child_process');

const {
  DEFAULT_HOST, DEFAULT_PORT, DEFAULT_ROOT_DIR, DEFAULT_MAPS_DIR, DEFAULT_INDEX, MAX_MAP_BYTES,
} = require('./defaults.js');
const { sendText } = require('./http_util.js');
const { hostAllowed } = require('./gates.js');
const { handleApi } = require('./api.js');
const { staticFileFor, serveStatic } = require('./static.js');

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
    // 所有路由之前(静态与 /api/* 都过):见 gates.js 的 hostAllowed。
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

// 端口占用时"点名是谁占的"。尽力而为,绝不抛错:它唯一的职责是把错误信息写清楚,
// 它自己失败会把"起不来"变成"起不来且不知道为什么"。
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
      // 默认不弹浏览器:那是命令行入口的事,库默认弹会让每个冒烟用例都弹一个窗口。
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

module.exports = {
  createServer: createServer, startServer: startServer,
  describePortOwner: describePortOwner, openBrowser: openBrowser, parseArgs: parseArgs,
};
