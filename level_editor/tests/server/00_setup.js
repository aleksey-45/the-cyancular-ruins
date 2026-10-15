'use strict';
// tests/server/00_setup.js —— 装载被测模块 + 本套件的脚手架(临时根目录 / 记账 / 清理 / HTTP 助手 / 独占锁)。
// ★ 本套件只碰 mkdtemp 出来的临时目录:真实 maps/ 目录一次都不写。
const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const { execFileSync, spawn } = require('child_process');
const srv = require('../../editor_server.js');
// 相位体是从 level_editor/ 下的单文件搬来的,那里 __dirname 就是 level_editor/ —— 用 EDITOR_DIR 顶替。
const EDITOR_DIR = path.join(__dirname, '..', '..');
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'cyrm-srv-'));
const openServers = [];
function track(r) { openServers.push(r.server); return r; }
async function shutdown() {
  for (const s of openServers) {
    if (typeof s.closeAllConnections === 'function') s.closeAllConnections();
    await new Promise(function (res) { s.close(function () { res(); }); });
  }
  openServers.length = 0;
}
    // ★★ 清理只此一份:每一条退出路径都调它(try/finally、看门狗超时、.catch)。旧写法各写各的、
    //   而且都是「先 process.exit(1) 才轮到 rmSync」⇒ 恰好在一跑失败时留下一个 cyrm-srv-* 临时
    //   目录(跑成功反而清得掉)。幂等:shutdown() 自己清空列表,rmSync 带 force。
async function cleanup() {
  // ★ 先收相位 ⑤ 那个攥着独占句柄的 PowerShell:它在,临时目录就删不掉(EBUSY)。
  await releaseLocker();
  await shutdown();
  try { fs.rmSync(tmpRoot, { recursive: true, force: true }); }
  catch (e) { console.error('  --    临时目录没删干净(' + errText(e) + '):' + tmpRoot); }
}
// ★ 模块级:清理路径(包括看门狗那一条)要能拿到它,不能是相位里的局部变量。
let lockerChild = null;
async function releaseLocker() {
  if (!lockerChild) return;
  const c = lockerChild;
  lockerChild = null;
  try { c.kill(); } catch (e) { /* 已经死了 */ }
  await exited(c);            // ★ 句柄随进程终止释放,不等它就没法安全删目录
}
function request(port, method, reqPath, body, headers) {
  return new Promise(function (resolve, reject) {
    // ★ 不传 headers 时 node 会按 host/port 自动生成 Host: 127.0.0.1:<port>
    //   —— 本文件的其余断言都靠这一条默认行为过 Host 白名单闸。
    const req = http.request({ host: '127.0.0.1', port: port, method: method, path: reqPath, headers: headers },
      function (res) {
        const chunks = [];
        res.on('data', function (c) { chunks.push(c); });
        res.on('end', function () {
          resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) });
        });
      });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}
    // ★ 只用于「这条响应可能被中止」的请求:不 reject —— 中止本身就是要断言的事实。两种中止
    //   形态都算:①请求侧直接 error(socket hang up / ECONNRESET);②响应头已到但正文短于 Content-Length 就断了。
function requestSettled(port, method, reqPath, body) {
  return new Promise(function (resolve) {
    let done = false;
    function settle(o) { if (!done) { done = true; resolve(o); } }
    const out = { status: 0, headers: {}, body: Buffer.alloc(0), aborted: false, error: '' };
    const req = http.request({ host: '127.0.0.1', port: port, method: method, path: reqPath },
      function (res) {
        const chunks = [];
        out.status = res.statusCode;
        out.headers = res.headers;
        res.on('data', function (c) { chunks.push(c); });
        res.on('aborted', function () { out.aborted = true; });
        res.on('end', function () {
          out.body = Buffer.concat(chunks);
          const cl = Number(res.headers['content-length'] || 0);
          if (cl > 0 && out.body.length < cl) out.aborted = true;
          settle(out);
        });
      });
    req.on('error', function (e) {
      out.aborted = true;
      out.error = (e && e.code ? e.code + ': ' : '') + errText(e);
      settle(out);
    });
    if (body) req.write(body);
    req.end();
  });
}
// ★ 等一个子进程真的退出(句柄/锁随进程终止释放,不等它就没法安全删临时目录)。
function exited(child) {
  return new Promise(function (resolve) {
    if (child.exitCode !== null || child.signalCode !== null) return resolve();
    child.once('exit', function () { resolve(); });
  });
}
// ★ 用真的共享冲突制造「stat 成功但 open 失败」。
//   (libuv 写死的行为),所以另一个 node 进程根本锁不住文件 —— 要制造冲突,必须有一个能指定
//   FileShare.None 的句柄:PowerShell 的 [IO.File]::Open(..., 'None') 就是。
function lockFileExclusiveWin(files) {
  const list = Array.isArray(files) ? files : [files];
  const openList = list.map(function (f) { return "'" + f + "'"; }).join(',');
  const cmd = '$hs=@(); foreach ($f in @(' + openList + ')) { $hs += [IO.File]::Open($f,\'Open\',\'Read\',\'None\') }; ' +
              "Write-Output 'LOCKED'; Start-Sleep -Seconds 60; $hs | ForEach-Object { $_.Close() }";
  return new Promise(function (resolve, reject) {
    const ps = spawn('powershell', ['-NoProfile', '-NonInteractive', '-Command', cmd],
      { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', settled = false;
    const timer = setTimeout(function () {
      if (settled) return;
      settled = true;
      try { ps.kill(); } catch (e) { /* 已经死了 */ }
      reject(new Error('PowerShell 20 秒内没拿到独占句柄'));
    }, 20000);
    ps.stdout.on('data', function (d) {
      out += String(d);
      if (!settled && out.indexOf('LOCKED') >= 0) { settled = true; clearTimeout(timer); resolve(ps); }
    });
    ps.on('error', function (e) { if (!settled) { settled = true; clearTimeout(timer); reject(e); } });
    ps.on('exit', function (c) {
      if (!settled) { settled = true; clearTimeout(timer); reject(new Error('PowerShell 提前退出 code=' + c)); }
    });
  });
}
// ★ lockerChild 走访问器挂到全局:相位 ⑤ 里那行 lockerChild = await … 一字不改就能写进本模块的变量。
//   清理路径必须看到它 —— 那个攥着独占句柄的 PowerShell 收不掉时,临时目录会 EBUSY 删不掉。
Object.defineProperty(globalThis, 'lockerChild', {
  get: function () { return lockerChild; },
  set: function (v) { lockerChild = v; },
  configurable: true,
});
// 相位体照旧裸名调用这些助手;链上的顺序就是入口 require 的顺序。
globalThis.serverChain = Promise.resolve();
Object.assign(globalThis, { EDITOR_DIR: EDITOR_DIR, tmpRoot: tmpRoot, track: track, shutdown: shutdown,
  cleanup: cleanup, releaseLocker: releaseLocker, request: request, requestSettled: requestSettled,
  exited: exited, lockFileExclusiveWin: lockFileExclusiveWin });