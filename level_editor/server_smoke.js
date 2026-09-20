'use strict';
// Node 冒烟 —— 本地服务器 level_editor/editor_server.js(规格 §4.9)。
// Run: cd level_editor && node server_smoke.js
// 判据:文本 `SERVER SMOKE OK` + 退出码 0。
// ★ 本文件只碰 mkdtemp 出来的临时目录:真实 maps/ 目录一次都不写。

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const { execFileSync, spawn } = require('child_process');
const srv = require('./editor_server.js');

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
// 逐字节比对,失败时报第一个不同的下标(整文件/整层比对要用它,eq(JSON) 会打出一屏数字)。
function sameBytes(actual, expected, msg) {
  const a = Array.prototype.slice.call(actual);
  const e = Array.prototype.slice.call(expected);
  if (a.length !== e.length) {
    fail++; console.error('  FAIL - ' + msg + ' (长度 ' + a.length + ' ≠ 期望 ' + e.length + ')');
    return;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== e[i]) {
      fail++; console.error('  FAIL - ' + msg + ' (第 ' + i + ' 字节: 实得 0x' + a[i].toString(16) +
                            ', 期望 0x' + e[i].toString(16) + ')');
      return;
    }
  }
  pass++; console.log('  ok  - ' + msg);
}
function errText(e) {
  let msg = (e && e.message !== undefined) ? String(e.message) : String(e);
  if (msg === '' && e && e.cause && e.cause.message) msg = String(e.cause.message);
  return msg;
}
// ★ 反向断言必须同时断言「错在哪」:只判「有没有抛」是假绿 ——
//   srv.startServer 若因拼写错误根本不存在,抛出来的 TypeError 一样算通过。
async function rejects(fn, msg, expectSub) {
  let e = null;
  try { await fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && errText(e).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + errText(e));
    return;
  }
  pass++; console.log('  ok  - ' + msg);
}

// ── 测试脚手架 ──
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
// ★★ 清理只此一份(待修 4):**每一条**退出路径都调它 —— try/finally(正常路径)、
//   看门狗超时、`.catch`。旧写法是各写各的、而且都是「先 process.exit(1) 才轮到 rmSync」,
//   于是**恰好在一跑失败时**留下一个 cyrm-srv-* 临时目录(跑成功反而清得掉)。
//   幂等:shutdown() 自己清空列表,rmSync 带 force。
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
    // ★ 不传 headers 时 node 会按 host/port 自动生成 `Host: 127.0.0.1:<port>`
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
// ★ 只用于「这条响应**可能被中止**」的请求(待修 1):**不 reject** —— 中止本身就是要断言的事实。
//   两种中止形态都算:①请求侧直接 error(socket hang up / ECONNRESET);
//   ②响应头已到但正文短于 Content-Length 就断了(res 'aborted' / 提前 close)。
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
// ★ 用**真的共享冲突**制造「stat 成功但 open 失败」。
//   为什么非得借外力:node 在 Windows 上开文件时恒定带 FILE_SHARE_READ|WRITE|DELETE
//   (libuv 写死的行为),所以**另一个 node 进程**根本锁不住文件 —— 要制造冲突,
//   必须有一个能指定 FileShare.None 的句柄,PowerShell 的 [IO.File]::Open(...,'None') 就是。
//   实测:句柄在手时 fs.stat 照样成功(它只读目录项属性),而 createReadStream 异步抛 EBUSY。
function lockFileExclusiveWin(file) {
  return new Promise(function (resolve, reject) {
    const ps = spawn('powershell', ['-NoProfile', '-NonInteractive', '-Command',
      "$h=[IO.File]::Open('" + file + "','Open','Read','None'); Write-Output 'LOCKED'; Start-Sleep -Seconds 60; $h.Close()"],
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

// ★ 全部相位(① ①b ② ③ ④ ⑤)都跑在这里,由下面的 main() 包在 try/finally 里调 —— 清理因此**必定**执行。
//   (相位体刻意留在与原先相同的缩进层级:把它们整体缩进一层会让 diff 淹没实质改动。)
async function runAllPhases() {
  // ★ 自检缝(默认关闭,只认环境变量):用来实际验证「失败路径也会清理临时目录」(待修 4)。
  //   复现:`CYRM_SMOKE_SELFTEST_THROW=1 node server_smoke.js` → 退出码 1,且 $TEMP 下
  //   **不留** cyrm-srv-* 目录(把 main() 里 try/finally 的 `await cleanup()` 去掉即可看到它留下)。
  if (process.env.CYRM_SMOKE_SELFTEST_THROW === '1') throw new Error('待修 4 自检:人为抛错');
  // ==== 相位 ① 常量与文件结构 ====
  ok(srv.DEFAULT_PORT === 8777, 'DEFAULT_PORT === 8777(避开游戏侧 7777/7800+/7999)');
  ok(srv.DEFAULT_HOST === '127.0.0.1', '★ DEFAULT_HOST === 127.0.0.1(绝不绑 0.0.0.0)');
  ok(srv.MAX_MAP_BYTES === 64 * 1024 * 1024, 'MAX_MAP_BYTES === 64MB(与 core.js 的 MAX_BODY_SIZE 同值)');
  ok(srv.DEFAULT_ROOT_DIR === __dirname, 'DEFAULT_ROOT_DIR === level_editor/');
  ok(srv.DEFAULT_MAPS_DIR === path.join(__dirname, '..', 'maps'), 'DEFAULT_MAPS_DIR === 仓库根的 maps/');
  ok(srv.DEFAULT_INDEX === 'editor.html', 'DEFAULT_INDEX === editor.html');
  ok(fs.existsSync(path.join(__dirname, 'editor.html')), '入口页 editor.html 存在');
  ok(fs.existsSync(path.join(__dirname, 'serve.bat')), 'serve.bat 存在');
  (function () {
    const bat = fs.readFileSync(path.join(__dirname, 'serve.bat'), 'utf8');
    ok(bat.charCodeAt(0) !== 0xFEFF, '★ serve.bat 不带 UTF-8 BOM(带了 cmd 会把第一行当命令报错)');
    ok(/chcp 65001/.test(bat), 'serve.bat: 切 UTF-8 代码页(否则中文错误信息在 cmd 里是乱码)');
    ok(/cd \/d "%~dp0"/.test(bat), 'serve.bat: cd 到脚本所在目录(双击时 cwd 是别的地方)');
    ok(/node\s+editor_server\.js/.test(bat), 'serve.bat: 用 node 起 editor_server.js');
    ok(/pause/.test(bat), 'serve.bat: 结尾 pause(否则启动失败时窗口一闪而过,看不到原因)');
  })();

  // ==== 相位 ①b 集成约束:旧编辑器与它的注册表标记必须原样活着 ====
  (function () {
    const oldHtml = path.join(__dirname, 'structure-editor.html');
    ok(fs.existsSync(oldHtml), '集成约束: structure-editor.html 仍在(本计划不重写它)');
    const src = fs.readFileSync(oldHtml, 'utf8');
    ok(src.indexOf('/*__ENEMY_REGISTRY_BEGIN__*/') >= 0 && src.indexOf('/*__ENEMY_REGISTRY_END__*/') >= 0,
       '集成约束: 敌人注册表两个标记都在');
    const sync = fs.readFileSync(path.join(__dirname, 'sync-enemies.js'), 'utf8');
    ok(/htmlPath = path\.join\(dir, 'structure-editor\.html'\)/.test(sync),
       '集成约束: sync-enemies.js 仍指向 structure-editor.html(搬它必须与搬标记同一 commit)');
    let out = '', code = 0;
    try {
      out = execFileSync(process.execPath, [path.join(__dirname, 'sync-enemies.js'), '--check'],
                         { encoding: 'utf8' });
    } catch (e) {
      code = (e.status === undefined || e.status === null) ? -1 : e.status;
      out = String(e.stdout || '') + String(e.stderr || '');
    }
    ok(code === 0 && /^ok:/m.test(out),
       '集成约束: node sync-enemies.js --check 退出 0(' + String(out).trim().split('\n')[0] + ')');
  })();

  // ==== 相位 ② 静态服务 ====
  const staticSrv = track(await srv.startServer({
    rootDir: __dirname, mapsDir: path.join(tmpRoot, 'maps'), port: 0,
  }));
  {
    const r1 = await request(staticSrv.port, 'GET', '/');
    ok(r1.status === 200, 'GET / → 200(实得 ' + r1.status + ')');
    ok(/^text\/html/.test(String(r1.headers['content-type'])), 'GET / → Content-Type: text/html');
    ok(/<!DOCTYPE html>/i.test(r1.body.toString('utf8')), 'GET / 返回的是入口页本身');
    ok(r1.headers['cache-control'] === 'no-store', 'GET / → Cache-Control: no-store(改完刷新就能看到新代码)');

    const r2 = await request(staticSrv.port, 'GET', '/core.js');
    ok(r2.status === 200, 'GET /core.js → 200');
    ok(/^text\/javascript/.test(String(r2.headers['content-type'])), 'GET /core.js → text/javascript');
    sameBytes(r2.body, fs.readFileSync(path.join(__dirname, 'core.js')),
              'GET /core.js 的字节与磁盘逐字节一致');

    const r3 = await request(staticSrv.port, 'GET', '/nope.js');
    ok(r3.status === 404, 'GET 不存在的文件 → 404');
    const r4 = await request(staticSrv.port, 'POST', '/core.js');
    ok(r4.status === 405, '静态路径 POST → 405');
    const r5 = await request(staticSrv.port, 'GET', '/api/nope');
    ok(r5.status === 404, '未实现的 /api/* → 404');
    const addr = staticSrv.server.address();
    ok(addr.address === '127.0.0.1' || addr.address === '::ffff:127.0.0.1',
       '★ 实际绑定地址是回环(实得 ' + addr.address + ')');

    // ── Host 白名单闸(待修 2)──
    // ★ 只绑 127.0.0.1 挡不住 DNS rebinding:恶意页面把域名解析到 127.0.0.1 就**同源**打进来了。
    //   本文件其余所有断言都靠 node http 客户端自动生成的 `Host: 127.0.0.1:<port>` —— 它们
    //   上面全绿,本身就是「正常 Host 不被误伤」的实证(闸没放太前、也没误判)。
    const rHostOk = await request(staticSrv.port, 'GET', '/');
    ok(rHostOk.status === 200,
       '★ Host 闸:正常 Host(127.0.0.1:' + staticSrv.port + ')→ 200(实得 ' + rHostOk.status + ')');
    const rHostLocal = await request(staticSrv.port, 'GET', '/', null,
                                     { Host: 'localhost:' + staticSrv.port });
    ok(rHostLocal.status === 200,
       '★ Host 闸:Host: localhost:<实际端口> → 200(实得 ' + rHostLocal.status + ')');
    const rHostEvil = await request(staticSrv.port, 'GET', '/', null, { Host: 'evil.example.com' });
    ok(rHostEvil.status === 403,
       '★★ Host 闸:Host: evil.example.com → 403(DNS rebinding 打过来时 Host 就是那个恶意域名)(实得 ' +
       rHostEvil.status + ')');
    const rHostEvilApi = await request(staticSrv.port, 'GET', '/api/nope', null, { Host: 'evil.example.com' });
    ok(rHostEvilApi.status === 403,
       '★ Host 闸在**所有路由之前** —— /api/* 也过它(实得 ' + rHostEvilApi.status + ')');
    const rHostNoPort = await request(staticSrv.port, 'GET', '/', null, { Host: '127.0.0.1:1' });
    ok(rHostNoPort.status === 403,
       '★ Host 闸比对的是**本服务器实际监听的端口**(端口写错 → 403;这条同时证明没写死 8777 —— ' +
       '本服务器跑在 ' + staticSrv.port + ' 上)(实得 ' + rHostNoPort.status + ')');
  }

  // ==== 相位 ③ 路径穿越(规格 §7 风险登记点名"必须写测试"的那一条)====
  {
    const secret = 'TOP SECRET —— 本文件在静态根之外,永远不该被读到';
    const rootDir = path.join(tmpRoot, 'level_editor');
    fs.mkdirSync(rootDir, { recursive: true });
    fs.writeFileSync(path.join(rootDir, 'editor.html'), '<!DOCTYPE html><html><body>穿越靶子</body></html>');
    fs.mkdirSync(path.join(rootDir, 'sub'), { recursive: true });
    fs.writeFileSync(path.join(tmpRoot, 'secret.txt'), secret, 'utf8');

    eq(srv.staticFileFor(rootDir, '/', 'editor.html'), { status: 200, file: path.join(rootDir, 'editor.html') },
       'staticFileFor: / → 索引页');
    eq(srv.staticFileFor(rootDir, '/core.js', 'editor.html').status, 200, 'staticFileFor: 正常文件 → 200');
    eq(srv.staticFileFor(rootDir, '/..%2f..%2fsecret.txt', 'editor.html').status, 403,
       '★ staticFileFor: /..%2f..%2fsecret.txt → 403');
    eq(srv.staticFileFor(rootDir, '/..%5c..%5csecret.txt', 'editor.html').status, 403,
       '★ staticFileFor: 反斜杠编码 %5c 一样被挡');
    eq(srv.staticFileFor(path.join(rootDir, 'sub'), '/..%2f..%2fsecret.txt', 'editor.html').status, 403,
       '★ staticFileFor: 根目录是子目录时同样被挡(判据是"落在根里面",不是"有没有 ..")');
    eq(srv.staticFileFor(rootDir, '/a%00b', 'editor.html').status, 400, 'staticFileFor: 空字节 → 400');

    const travSrv = track(await srv.startServer({ rootDir: rootDir, mapsDir: path.join(tmpRoot, 'maps'), port: 0 }));
    const paths = ['/..%2fsecret.txt', '/..%2f..%2fsecret.txt', '/..%5csecret.txt', '/%2e%2e%2fsecret.txt',
                   '/../secret.txt'];
    for (const p of paths) {
      const r = await request(travSrv.port, 'GET', p);
      ok(r.body.toString('utf8').indexOf('TOP SECRET') < 0,
         '★ HTTP 穿越被挡: GET ' + p + ' → ' + r.status + ',正文里没有那个文件');
      // ★ 只断言「正文里没 secret」是不够的:一个 500 或**空正文**也会通过(两者都读不到 secret)。
      //   这里补状态断言。★ 接受 403 **或** 404:`/../secret.txt` 会被 URL 解析器**归一化**成
      //   `/secret.txt`(节点本来就不存在)⇒ 合法地走 404;真正被穿越闸拦下的是编码过的那几条(403)。
      //   只认 403 会把归一化那条判成失败 —— 那是判据错,不是实现错。
      ok(r.status === 403 || r.status === 404,
         '★ 穿越被挡的状态码是 403(闸拦下)或 404(URL 归一化成根内不存在的名字): GET ' + p +
         ' → ' + r.status);
    }
    const rDir = await request(travSrv.port, 'GET', '/sub');
    ok(rDir.status === 404, 'GET 目录 → 404(不做目录浏览)');
  }

  // ==== 相位 ④ 启动诊断(端口占用必须说清楚是谁占的)====
  {
    const a = track(await srv.startServer({ rootDir: __dirname, mapsDir: path.join(tmpRoot, 'maps'), port: 0 }));
    await rejects(function () {
      return srv.startServer({ rootDir: __dirname, mapsDir: path.join(tmpRoot, 'maps'), port: a.port });
    }, '★ 同端口再起一个 → 抛错(不是静默退出)', '已被占用');
    // ★ 报错文本的**首行**必须点名端口号。只断言「含端口号」会被 netstat 提示里那两处
    //   出现蒙混过去(提示里本来就带端口),那样首行丢了端口也照样绿。
    let addrErr = null;
    try {
      await srv.startServer({ rootDir: __dirname, mapsDir: path.join(tmpRoot, 'maps'), port: a.port });
    } catch (e) { addrErr = e; }
    ok(addrErr !== null && errText(addrErr).split('\n')[0].indexOf('端口 ' + a.port + ' 已被占用') === 0,
       '★ EADDRINUSE 的**首行**点名端口号(实得:' +
       JSON.stringify(addrErr === null ? '(未抛错)' : errText(addrErr).split('\n')[0]) + ')');

    ok(srv.describePortOwner(a.port).indexOf('netstat') >= 0, 'describePortOwner: 给出查占用者的命令');
    ok(typeof srv.openBrowser === 'function', 'openBrowser 已导出(可注入)');
    ok(srv.parseArgs(['--no-open']).openBrowser === false, "parseArgs: --no-open → openBrowser:false");
    ok(srv.parseArgs([]).openBrowser === undefined,
       'parseArgs: 默认不设该键 —— 默认值只在命令行入口变成 true(库默认弹浏览器 = 每个冒烟用例弹一个窗口)');
  }

  // ==== 相位 ⑤ 静态读失败:stat 成功但 open 失败 —— 服务器必须活着(待修 1)====
  {
    // ★ 这里复现的是**真实的文件状态**,不是打桩:fs.stat 成功(它只读目录项属性),
    //   而随后的 open 失败(共享冲突)。制造手段与理由见 lockFileExclusiveWin 的注释。
    //   ★ 非 Windows 上跳过(打印一行,不计入 ok/FAIL):[IO.File]::Open 是 .NET API。
    const lockDir = path.join(tmpRoot, 'locked');
    fs.mkdirSync(lockDir, { recursive: true });
    const lockedPath = path.join(lockDir, 'editor.html');
    const lockedBytes = Buffer.from('<!DOCTYPE html><html><body>这个入口页会被独占锁住</body></html>', 'utf8');
    fs.writeFileSync(lockedPath, lockedBytes);
    const goodBytes = Buffer.from('// 锁事件之后的存活探针\n', 'utf8');
    fs.writeFileSync(path.join(lockDir, 'good.js'), goodBytes);
    const lockSrv = track(await srv.startServer({
      rootDir: lockDir, mapsDir: path.join(tmpRoot, 'maps'), port: 0,
    }));

    try {
      if (process.platform !== 'win32') {
        console.log('  --    相位 ⑤ 跳过:非 Windows(独占句柄需要 .NET 的 FileShare.None)');
      } else {
        lockerChild = await lockFileExclusiveWin(lockedPath);
        // 前置:故障点必须真的在 open 而不在 stat —— 否则下面几条什么都没验(比如文件已被删)。
        let st = null;
        try { st = fs.statSync(lockedPath); } catch (e) { /* 前置不成立 */ }
        ok(st !== null && st.isFile(),
           '待修 1 前置:被独占锁住的文件 fs.stat **照样成功**(故障点因此在 open,不在 stat)');

        const rLock = await requestSettled(lockSrv.port, 'GET', '/editor.html');
        ok(rLock.aborted === true && rLock.body.length < lockedBytes.length,
           '★★ 待修 1:open 失败 → 客户端拿到的是**已中止**的响应,而不是一个完整的 200 ' +
           '(实得 status=' + rLock.status + ', aborted=' + rLock.aborted + ', body=' +
           rLock.body.length + '/' + lockedBytes.length + 'B, err=' + (rLock.error || '无') + ')');

        // ★ 这条才是主断言:旧实现在这里已经是一具尸体 —— ReadStream 的 'error' 没人接管
        //   → 未捕获异常 → **整个进程退出 1**,客户端一行响应都收不到,用户只能重启 serve.bat。
        const rGood = await request(lockSrv.port, 'GET', '/good.js');
        ok(rGood.status === 200,
           '★★ 待修 1:出过坏文件之后服务器**还活着**(紧接着 GET /good.js → ' + rGood.status + ')');
        sameBytes(rGood.body, goodBytes, '待修 1:活着,而且读出来的字节正确(不是「活着但坏了」)');

        // ★ 反证:证明刚才那条**确实是**锁造成的,而不是"没锁上、一切正常"。
        await releaseLocker();
        const rAfter = await requestSettled(lockSrv.port, 'GET', '/editor.html');
        ok(rAfter.status === 200 && rAfter.body.length === lockedBytes.length,
           '待修 1 反证:句柄一放开,同一个 URL 立刻恢复正常(证明前一条确实栽在 open 上)(实得 ' +
           rAfter.status + ', ' + rAfter.body.length + 'B)');
      }
    } finally {
      // ★ 子进程一定要收掉:它握着句柄时连临时目录都删不掉(rmSync 会 EBUSY)。
      //   (断言失败走不到 kill 那一步 —— 所以这里必须再兜一次。)
      await releaseLocker();
    }
  }
}

(async function main() {
  // ★ 看门狗:任何一处挂住(server 没关 / promise 永不 settle)都走到这里,
  //   而不是让 node 静默退出。★ 刻意**不 unref**:事件循环空转时静默退出(退出码 0、
  //   一行不打)才是最难发现的假绿 —— core.js 的 inflateBytes 实测踩过这一档。
  setTimeout(async function () {
    console.error('FAIL: 120 秒超时 —— 有 server 没关,或某个 promise 永不 settle');
    await cleanup();            // ★ 超时这一支也必须清(待修 4)
    process.exit(1);
  }, 120000);

  // ★★ 清理走 try/finally(不是「跑完再清」):见 cleanup() 的说明。
  try {
    await runAllPhases();
  } finally {
    await cleanup();
  }

  // ==== 断言区结束 ====
  console.log('');
  console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
  if (fail === 0) console.log('SERVER SMOKE OK');
  process.exit(fail === 0 ? 0 : 1);
})().catch(async function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  await cleanup();              // 双保险(finally 通常已经跑过;cleanup 幂等)
  process.exit(1);
});
