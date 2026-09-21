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
// ★ 待修 1 起它**可以一次锁多个文件**(传数组;传字符串 = 只锁一个,与原行为一致)。
//   为什么必须是一个进程锁两份:句柄槽 `lockerChild` 只有**一个**(releaseLocker 只 kill 得到
//   最后一个),起两个 PowerShell 会让先那个句柄失去引用 —— 它的释放时机交给 GC,于是
//   `cleanup()` 删临时目录会 EBUSY。一次进程、一张句柄表,释放路径仍然只有 releaseLocker() 一条。
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

// ★ 全部相位(① ①b ② ③ ④ ⑤ 静态读失败、⑤ 地图名守卫、⑥ API)都跑在这里,由下面的 main() 包在 try/finally 里调 —— 清理因此**必定**执行。
//   ★ 两个 ⑤ 是**有意为之**:Task 1 加固时插进来的「静态读失败」与计划里 Task 2 的「地图名守卫」撞号,
//     改成 ⑥/⑦ 会让计划里 Task 3 / Task 6 的 ⑦ / ⑧ 整体错位 —— 故保留原号,两个相位头也都点了名。
//   ★★ 新相位一律加在**本函数体内**:main() 里 `// ==== 断言区结束 ====` 那句在 try/finally{ cleanup() }
//     **之后**,加在那里 = 相位跑在清理之后,每次跑都会把已删掉的 tmpRoot 重新建出来(真实踩过)。
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
    // ★★ 待修 1(/api/map 那一支):`serveMapFile` 里那 6 行守卫当时**一行断言都没有** ——
    //   把它删掉 85/0 依然全绿,直到有人在 Windows 上撞上 AV 独占锁。本仓口径是:**这类守卫
    //   必须有自己的反证**,不能靠"照抄了一份已经测过的代码"(serveStatic 那条根本盖不到这条分支)。
    //   ★ 落点必须是 tmpRoot/maps 下面(地图名守卫只放行**裸文件名**),而相位 ⑥ 的
    //     `GET /api/maps` 是**精确列表**比对 ⇒ 这个文件在本相位结束前必须删掉(见 finally)。
    const mapsDir = path.join(tmpRoot, 'maps');
    fs.mkdirSync(mapsDir, { recursive: true });
    const lockedMapName = 'locked.cyrm';
    const lockedMapPath = path.join(mapsDir, lockedMapName);
    const lockedMapBytes = Buffer.from([7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]);
    fs.writeFileSync(lockedMapPath, lockedMapBytes);

    try {
      if (process.platform !== 'win32') {
        console.log('  --    相位 ⑤ 跳过:非 Windows(独占句柄需要 .NET 的 FileShare.None)');
      } else {
        // ★ 一次锁住两个:入口页(静态那条分支)与 locked.cyrm(/api/map 那条分支)。
        lockerChild = await lockFileExclusiveWin([lockedPath, lockedMapPath]);
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

        // ── ★★ 待修 1 补:/api/map 这一支(**serveMapFile**)──
        //   与上面两条同款,但走的是**另一份代码**:两份守卫各自独立,serveStatic 测到不证明这条测到。
        //   前置:与 /editor.html 同理,故障点必须在 open 而不在 stat。
        let stMap = null;
        try { stMap = fs.statSync(lockedMapPath); } catch (e) { /* 前置不成立 */ }
        ok(stMap !== null && stMap.isFile(),
           '待修 1 前置:被独占锁住的地图 fs.stat **照样成功**(故障点因此在 serveMapFile 的 open)');

        const rMapLock = await requestSettled(lockSrv.port, 'GET', '/api/map?p=' + lockedMapName);
        ok(rMapLock.aborted === true && rMapLock.body.length < lockedMapBytes.length,
           '★★ 待修 1:/api/map 的 open 失败 → 客户端拿到的是**已中止**的响应,而不是一个完整的 200 ' +
           '(实得 status=' + rMapLock.status + ', aborted=' + rMapLock.aborted + ', body=' +
           rMapLock.body.length + '/' + lockedMapBytes.length + 'B, err=' + (rMapLock.error || '无') + ')');

        // ★ 这条才是主断言:这 6 行缺席时,ReadStream 的 'error' 无人接管 → 未捕获异常
        //   → **整个进程退出**,这条请求根本等不到响应(整支冒烟连一行结果都打不出来)。
        const rMapsAlive = await request(lockSrv.port, 'GET', '/api/maps');
        ok(rMapsAlive.status === 200,
           '★★ 待修 1:出过坏地图之后服务器**还活着**(紧接着 GET /api/maps → ' + rMapsAlive.status + ')');

        // ★ 反证:证明刚才那条**确实是**锁造成的,而不是"没锁上、一切正常"。
        await releaseLocker();
        const rAfter = await requestSettled(lockSrv.port, 'GET', '/editor.html');
        ok(rAfter.status === 200 && rAfter.body.length === lockedBytes.length,
           '待修 1 反证:句柄一放开,同一个 URL 立刻恢复正常(证明前一条确实栽在 open 上)(实得 ' +
           rAfter.status + ', ' + rAfter.body.length + 'B)');
        // ★ 反证(/api/map 那一支):同一把锁、同一时刻放开,地图这条也要恢复 —— 且字节正确。
        const rMapAfter = await requestSettled(lockSrv.port, 'GET', '/api/map?p=' + lockedMapName);
        ok(rMapAfter.status === 200 && rMapAfter.body.length === lockedMapBytes.length,
           '待修 1 反证(/api/map):句柄一放开立刻恢复(证明前一条确实栽在 serveMapFile 的 open 上)(实得 ' +
           rMapAfter.status + ', ' + rMapAfter.body.length + 'B)');
      }
    } finally {
      // ★ 子进程一定要收掉:它握着句柄时连临时目录都删不掉(rmSync 会 EBUSY)。
      //   (断言失败走不到 kill 那一步 —— 所以这里必须再兜一次。)
      await releaseLocker();
      // ★ locked.cyrm 必须在这里删掉:相位 ⑥ 的 GET /api/maps 是**精确列表**比对
      //   (['a_first.cyrm','b_second.cyrm']),留着它会把那条一直绿着的断言判红。
      //   非 Windows 上这个文件只是建了没用,一并删掉;删不到(例如上面提前抛错)也不该盖住真失败。
      try { fs.unlinkSync(lockedMapPath); } catch (e) { /* 不在就跳过 */ }
    }
  }

  // ==== 相位 ⑤ 地图名守卫(规格 §4.9,风险登记点名"必须写测试")====
  // ★ 编号沿用计划原文:Task 1 加固时插进来的「相位 ⑤ 静态读失败」占了同一个号。
  //   改号会让计划里 Task 3 / Task 6 的 ⑦ / ⑧ 错位,故两个 ⑤ 并存(有意为之,不是笔误)。
  // ★★ 本相位必须留在 runAllPhases() **里面**(不是 main() 里 `// ==== 断言区结束 ====` 之前):
  //   那句注释在 main() 的 try/finally{ cleanup() } **之后**,放那里 = 相位跑在清理之后,
  //   每次跑都会把已删掉的 tmpRoot 重新建出来 → 每次留下一个 cyrm-srv-* 临时目录(已实测)。
  {
    const bad = ['', 'demo', 'demo.txt', 'a.cyrm.bak', '..cyrm', '.cyrm', 'demo.cyrm\n',
                 '../demo.cyrm', '..%2fdemo.cyrm', '/demo.cyrm', 'a/b.cyrm', 'a\\b.cyrm',
                 'C:\\demo.cyrm', 'demo cyrm', 'demo\n.cyrm', 'demo.cyrm/x', '..\\..\\x.cyrm',
                 'demo\u0000.cyrm', 'x'.repeat(65) + '.cyrm', null, 42, undefined];
    let allRejected = true, firstFail = '';
    for (const n of bad) {
      // ★ 用「不提前 return」的写法:一条失败不该让后面 15 条一条都不跑(否则修一处红一处)。
      if (srv.isValidMapName(n) !== false) { allRejected = false; if (!firstFail) firstFail = JSON.stringify(n); }
    }
    ok(allRejected, '★ isValidMapName 拒绝全部 ' + bad.length + ' 个非法名(首个漏网:' + firstFail + ')');
    const good = ['demo.cyrm', 'factory1v1.cyrm', 'a.cyrm', 'A_1-2.cyrm', 'x'.repeat(58) + '.cyrm'];
    let allAccepted = true, firstGoodFail = '';
    for (const n of good) {
      if (srv.isValidMapName(n) !== true) { allAccepted = false; if (!firstGoodFail) firstGoodFail = n; }
    }
    ok(allAccepted, 'isValidMapName 接受全部 ' + good.length + ' 个合法名(首个漏网:' + firstGoodFail + ')');
    ok(srv.MAP_NAME_RE.source === '^[A-Za-z0-9_\\-]+\\.cyrm$', 'MAP_NAME_RE 与规格 §4.9 逐字一致');
    ok(srv.MAX_MAP_NAME_LEN === 64, 'MAX_MAP_NAME_LEN === 64(规格的正则没有长度上界,这条是防御性补充)');
    let threw = false;
    try { srv.mapPathFor(tmpRoot, '../evil.cyrm'); } catch (e) { threw = true; }
    ok(threw, 'mapPathFor: 非法名抛错(不返回一个越界的路径)');
    eq(srv.mapPathFor(tmpRoot, 'ok.cyrm'), path.join(path.resolve(tmpRoot), 'ok.cyrm'),
       'mapPathFor: 合法名 = mapsDir + 名字');
  }

  // ==== 相位 ⑥ /api/maps + GET /api/map ====
  // ★ 同相位 ⑤ 的编号说明(计划原文的号,与 Task 1 的静态读失败 ⑤ 相撞);
  //   位置同理,必须在 runAllPhases() 里面。
  {
    const mapsDir = path.join(tmpRoot, 'maps');
    fs.mkdirSync(mapsDir, { recursive: true });
    fs.writeFileSync(path.join(mapsDir, 'b_second.cyrm'), Buffer.from([1, 2, 3, 4, 5]));
    fs.writeFileSync(path.join(mapsDir, 'a_first.cyrm'), Buffer.from([9, 9]));
    fs.writeFileSync(path.join(mapsDir, 'notes.txt'), 'not a map');
    fs.mkdirSync(path.join(mapsDir, 'sub.cyrm'), { recursive: true });
    fs.writeFileSync(path.join(mapsDir, 'sub.cyrm', 'keep.txt'), 'x');
    const logged = [];
    const apiSrv = track(await srv.startServer({
      rootDir: __dirname, mapsDir: mapsDir, port: 0,
      logger: function (m) { logged.push(m); },
    }));

    eq(srv.listMaps(path.join(tmpRoot, 'no_such_dir'), null), [], 'listMaps: 目录不存在 = 空库,不抛错');

    const rm = await request(apiSrv.port, 'GET', '/api/maps');
    ok(rm.status === 200, 'GET /api/maps → 200');
    ok(/^application\/json/.test(String(rm.headers['content-type'])), 'GET /api/maps → application/json');
    const data = JSON.parse(rm.body.toString('utf8'));
    eq(data.maps.map(function (m) { return m.name; }), ['a_first.cyrm', 'b_second.cyrm'],
       '★ /api/maps: 只列合法且是文件的 .cyrm,按名字升序(notes.txt 与同名目录都不进来)');
    eq(data.maps[0].size, 2, '/api/maps: size = 文件字节数');
    ok(typeof data.maps[0].mtime === 'number' && data.maps[0].mtime > 0, '/api/maps: mtime 是数字');
    // ★ 待修 2:这两条**必须分开**。原先只有一条、而且只覆盖 notes.txt —— 而 notes.txt 走的是
    //   「名字不过守卫」那条路径;同名目录(sub.cyrm)走的是**另一条**(名字合法、stat 也成功、
    //   只是不是文件)。一个原因一条断言,才钉得住"两种跳过都不静默"这句话。
    ok(logged.some(function (m) { return m.indexOf('notes.txt') >= 0; }),
       '★ /api/maps: **名字不过守卫**而被跳过的文件点名记日志(绝不静默消失)');
    ok(logged.some(function (m) { return m.indexOf('sub.cyrm') >= 0; }),
       '★ /api/maps: **不是文件**(同名目录)而被跳过的**也**点名记日志 —— 这条路径待修 2 之前是静默 continue');

    const rg = await request(apiSrv.port, 'GET', '/api/map?p=b_second.cyrm');
    ok(rg.status === 200, 'GET /api/map → 200');
    ok(rg.headers['content-type'] === 'application/octet-stream', 'GET /api/map → octet-stream');
    sameBytes(rg.body, Buffer.from([1, 2, 3, 4, 5]), 'GET /api/map: 字节原样返回');
    ok(rg.headers['cache-control'] === 'no-store', 'GET /api/map → no-store');

    const r404 = await request(apiSrv.port, 'GET', '/api/map?p=nope.cyrm');
    ok(r404.status === 404, 'GET /api/map 不存在的名字 → 404');
    const rMiss = await request(apiSrv.port, 'GET', '/api/map');
    ok(rMiss.status === 400, 'GET /api/map 缺 p 参数 → 400');
    const rTrav = await request(apiSrv.port, 'GET', '/api/map?p=' + encodeURIComponent('../package.json'));
    ok(rTrav.status === 400, '★ GET /api/map 路径穿越名 → 400');
    ok(rTrav.body.toString('utf8').indexOf('"name"') < 0, '★ 那个 400 的正文里没有 package.json 的内容');
    const rTrav2 = await request(apiSrv.port, 'GET', '/api/map?p=' + encodeURIComponent('..%2fdemo.cyrm'));
    ok(rTrav2.status === 400, '★ GET /api/map 编码过的穿越名 → 400');
    const rPost = await request(apiSrv.port, 'POST', '/api/map?p=b_second.cyrm', Buffer.from([1]));
    ok(rPost.status === 405, 'POST /api/map → 405');
    const rMapsPost = await request(apiSrv.port, 'POST', '/api/maps', Buffer.from([1]));
    ok(rMapsPost.status === 405, 'POST /api/maps → 405');
  }

  // ==== 相位 ⑦ PUT /api/map 原子写 ====
  // ★ 同相位 ⑤ / ⑥ 的编号说明(计划原文的号,与 Task 1 的静态读失败 ⑤ 相撞);
  //   位置同理,必须在 runAllPhases() 里面。
  {
    const mapsDir = path.join(tmpRoot, 'maps');
    const readBack = function (n) { return fs.readFileSync(path.join(mapsDir, n)); };
    const noTmpLeft = function () {
      return fs.readdirSync(mapsDir).every(function (n) {
        return n.indexOf('.tmp') < 0;
      }) && fs.readdirSync(path.join(mapsDir, 'sub.cyrm')).every(function (n) {
        return n.indexOf('.tmp') < 0;
      });
    };
    // ★ 写端点只收 application/json(硬要求 A:CSRF,理由见相位末尾那一块)——
    //   所以本相位每一条**合法**的 PUT 都必须显式带上它。下面是它们的公共头。
    const PUT_JSON = { 'Content-Type': 'application/json' };
    const apiSrv = track(await srv.startServer({
      rootDir: __dirname, mapsDir: mapsDir, port: 0,
    }));
    // 一个 maxMapBytes 很小的服务器,专门用来验 413 —— 不用真发 64MB。
    const smallSrv = track(await srv.startServer({
      rootDir: __dirname, mapsDir: mapsDir, port: 0, maxMapBytes: 16,
    }));

    const put = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([7, 7, 7]), PUT_JSON);
    ok(put.status === 200, 'PUT 新文件 → 200(实得 ' + put.status + ')');
    eq(JSON.parse(put.body.toString('utf8')), { name: 'c_new.cyrm', size: 3 }, 'PUT 回 JSON {name,size}');
    sameBytes(readBack('c_new.cyrm'), Buffer.from([7, 7, 7]), 'PUT: 落盘字节与请求体一致');
    ok(noTmpLeft(), '★ PUT 之后没有残留临时文件');

    const put2 = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([1, 2, 3, 4]), PUT_JSON);
    ok(put2.status === 200, 'PUT 覆盖已有文件 → 200');
    sameBytes(readBack('c_new.cyrm'), Buffer.from([1, 2, 3, 4]), 'PUT: 覆盖后是新内容(不留尾巴)');

    // ── 反向:被拒的写绝不能动到已有文件 ──
    const before = readBack('c_new.cyrm');
    const rBadName = await request(apiSrv.port, 'PUT', '/api/map?p=' + encodeURIComponent('../evil.cyrm'),
                                   Buffer.from([0xEE]), PUT_JSON);
    ok(rBadName.status === 400, '★ PUT 路径穿越名 → 400');
    ok(!fs.existsSync(path.join(tmpRoot, 'evil.cyrm')), '★ PUT 没有在 maps/ 之外写出任何文件');
    const rEmpty = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.alloc(0), PUT_JSON);
    ok(rEmpty.status === 400, 'PUT 空请求体 → 400(不许用空内容覆盖地图)');
    const rBig = await request(smallSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.alloc(64, 1), PUT_JSON);
    ok(rBig.status === 413, '★ PUT 超过 maxMapBytes → 413(实得 ' + rBig.status + ')');
    sameBytes(readBack('c_new.cyrm'), before,
              '★★ 三种被拒的 PUT 之后,原文件逐字节没变');
    ok(noTmpLeft(), '被拒的 PUT 也没留临时文件');

    // ★ 写失败的清理路径:目标是**一个非空目录** → rename 必失败 → 临时文件必须被删掉。
    const rDir = await request(apiSrv.port, 'PUT', '/api/map?p=sub.cyrm', Buffer.from([1, 2]), PUT_JSON);
    ok(rDir.status === 500, '★ PUT 目标是个目录 → 500(写失败,实得 ' + rDir.status + ')');
    ok(fs.statSync(path.join(mapsDir, 'sub.cyrm')).isDirectory() &&
       fs.existsSync(path.join(mapsDir, 'sub.cyrm', 'keep.txt')),
       '★ 写失败后那个目录连同里面的文件都还在(没有被毁掉)');
    ok(noTmpLeft(), '★★ 写失败后临时文件被清掉(否则每次失败都在 maps/ 里留垃圾)');

    // 头请求不能带 body(顺带验 HEAD 分支)
    const rHead = await request(apiSrv.port, 'HEAD', '/api/map?p=c_new.cyrm');
    ok(rHead.status === 200 && rHead.body.length === 0, 'HEAD /api/map → 200 且无正文');

    // ── ★★ 硬要求 A:CSRF —— 写端点只收 application/json,且一个 CORS 头都不答 ──
    // ★ Host 白名单闸挡的是 **DNS rebinding**;它挡不住这一类:恶意页面直接
    //   `fetch('http://127.0.0.1:8777/api/map', {method:'PUT', body})` 时,浏览器发的 `Host`
    //   **就是** `127.0.0.1:8777` —— 完全合法,闸照过。读端点安全(没有 CORS 头 ⇒ 跨源拿不到
    //   响应体),但**写端点**上,一个「简单请求」(不触发预检的那些组合)会被**直接处理**。
    //   故写端点必须自己要求一个**非简单**形态,逼浏览器先发预检 —— 而预检我们一个 CORS 头都不答
    //   ⇒ 浏览器根本不会把那条 PUT 发出来。
    // ★★ 反过来:**绝不要加 `Access-Control-Allow-Origin`** —— 那等于把预检答成通过,
    //    会把本来安全的**读**端点一起拖下水。下面第 ④ / ⑤ 条就是钉这个的。
    {
      const beforeA = readBack('c_new.cyrm');
      // ① 简单请求的经典内容类型。★ 它本身不是"简单方法"(PUT 不在 CORS 安全方法名单里),
      //    这条钉的是**类型闸**本身:哪天有人给写端点加上 POST,它就是唯一还站着的东西。
      const rPlain = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]),
                                   { 'Content-Type': 'text/plain' });
      ok(rPlain.status === 415,
         '★★ 硬要求 A:Content-Type: text/plain(简单请求的组合)→ 415 拒绝(实得 ' + rPlain.status + ')');
      // ② 一个 Content-Type 都不带(node/curl 的默认行为)也一样拒 —— "缺省即放行"是最容易漏的缺口。
      const rNoCt = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]));
      ok(rNoCt.status === 415, '★ 硬要求 A:不带 Content-Type → 415(实得 ' + rNoCt.status + ')');
      // ③ Origin 是别的站 → 403。跨源的非简单请求一定会带 Origin。
      const rCross = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]),
                                   { 'Content-Type': 'application/json', Origin: 'http://evil.example.com' });
      ok(rCross.status === 403,
         '★ 硬要求 A:Origin 是别的站(类型对、来源错)→ 403(实得 ' + rCross.status + ')');
      // ④ Sec-Fetch-Site 是**浏览器专有**头(在 forbidden header 名单上,页面 JS 改不了它)。
      //    ★ 这条**刻意不带 Origin**:Sec-Fetch-Site 是"没有 Origin 可判"时的兜底(见实现注释)。
      const rSite = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]),
                                  { 'Content-Type': 'application/json', 'Sec-Fetch-Site': 'cross-site' });
      ok(rSite.status === 403,
         '★ 硬要求 A:没有 Origin、而 Sec-Fetch-Site: cross-site → 403(兜底那道)(实得 ' +
         rSite.status + ')');
      sameBytes(readBack('c_new.cyrm'), beforeA,
                '★★ 硬要求 A:四条被拒的跨源 / 非 JSON PUT 之后,原文件逐字节没变');
      ok(noTmpLeft(), '★ 硬要求 A:被拒的跨源 PUT 也没留临时文件');

      // ⑤ 预检本身:浏览器发的 OPTIONS 必须拿不到**任何** Access-Control-* 头 ——
      //    这是"跨源写根本发不出来"的地基(答了 ACAO 就等于把预检放行)。
      const rOpt = await request(apiSrv.port, 'OPTIONS', '/api/map?p=c_new.cyrm', null,
                                 { Origin: 'http://evil.example.com',
                                   'Access-Control-Request-Method': 'PUT',
                                   'Access-Control-Request-Headers': 'content-type' });
      const corsKeys = Object.keys(rOpt.headers).filter(function (h) { return h.indexOf('access-control-') === 0; });
      ok(corsKeys.length === 0,
         '★★ 硬要求 A:跨源预检(OPTIONS)一个 Access-Control-* 头都不答(实得 status=' + rOpt.status +
         ', ' + (corsKeys.length ? corsKeys.join(',') : '无 CORS 头') + ')');

      // ④b ★ 防**误伤自己人**:编辑器可以从 localhost 或 127.0.0.1 任一个名字打开,而按 Fetch
      //     的"同站"定义这**两个名字是两个站** —— 于是从 localhost 打开的页面去写 127.0.0.1 时,
      //     浏览器会诚实地标 `Sec-Fetch-Site: cross-site`。那时**必须放行**(Origin 是主闸),
      //     否则"用 localhost 打开编辑器"就存不进任何地图(而且只在写端点现形,读端点一切正常)。
      const rLoop = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([4, 4]),
                                  { 'Content-Type': 'application/json',
                                    Origin: 'http://localhost:' + apiSrv.port,
                                    'Sec-Fetch-Site': 'cross-site' });
      ok(rLoop.status === 200,
         '★★ 硬要求 A:Origin 是回环的另一个名字(localhost)+ Sec-Fetch-Site: cross-site → 放行' +
         '(Origin 是主闸,别用"同站"判自家页面)(实得 ' + rLoop.status + ')');
      const rLoop2 = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([4, 4]),
                                   { 'Content-Type': 'application/json',
                                     Origin: 'http://127.0.0.1:' + apiSrv.port });
      ok(rLoop2.status === 200,
         '★ 硬要求 A:Origin: http://127.0.0.1:<实际端口>(浏览器在非简单请求上一定会带)→ 放行' +
         '(实得 ' + rLoop2.status + ')');

      // ⑥ 那条**成功**的 PUT 也不许带 CORS 头(带了 = 跨源读得到响应体,把读端点也拖下水)。
      const rOkA = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([5, 5]), PUT_JSON);
      ok(rOkA.status === 200 && rOkA.headers['access-control-allow-origin'] === undefined,
         '★ 硬要求 A:同源 PUT 照常 200、且响应里没有 Access-Control-Allow-Origin(实得 ' +
         rOkA.status + ')');
      // ⑦ 带参数的 JSON 类型必须照收 —— 不然会**误伤自家前端**(浏览器 fetch 带 charset 时发的就是它)。
      const rCharset = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([6, 6]),
                                     { 'Content-Type': 'application/json; charset=utf-8' });
      ok(rCharset.status === 200,
         '★ 硬要求 A:application/json; charset=utf-8 照收(否则自家 fetch 会被自己挡掉)(实得 ' +
         rCharset.status + ')');
      sameBytes(readBack('c_new.cyrm'), Buffer.from([6, 6]), '★ 硬要求 A:带参数的 JSON 类型确实写进去了');
      // ⑧ 那个"简单请求"的**真实攻击形态**:POST + text/plain + 跨源 Origin。它**不预检**、
      //    会被浏览器直接发出去 —— 而本端点只收 PUT ⇒ 它根本进不了写路径。
      const rSimple = await request(apiSrv.port, 'POST', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]),
                                    { 'Content-Type': 'text/plain', Origin: 'http://evil.example.com' });
      ok(rSimple.status === 405,
         '★ 硬要求 A:简单请求的真实形态(POST + text/plain + 跨源 Origin)→ 405(实得 ' +
         rSimple.status + ')');
      sameBytes(readBack('c_new.cyrm'), Buffer.from([6, 6]), '★ 硬要求 A:那条简单请求也没动到文件');
    }

    // ── ★★ 硬要求 B:符号链接 —— 写端点必须按**真实路径**再判一次包含性 ──
    // ★ 现有两道闸(裸文件名正则 + mapPathFor 里的字符串包含性)判的都是**路径字符串**,
    //   而 `fs.stat` / `fs.writeFile` / `fs.realpath` 这一族**会跟随符号链接**。
    //   对读端点这只是低危(要求攻击者已经能往 maps/ 里放一个链接);但写端点走同一条路径时
    //   会升级成「把编辑器当任意文件写入器」—— 故这里按 realpath 再判一次。
    {
      const outsideDir = path.join(tmpRoot, 'outside');
      fs.mkdirSync(outsideDir, { recursive: true });
      const victimPath = path.join(outsideDir, 'victim.cyrm');
      const victimBytes = Buffer.from('★ maps/ 之外的文件 —— 写端点一个字节都不许碰它', 'utf8');
      fs.writeFileSync(victimPath, victimBytes);
      const linkName = 'link_out.cyrm';
      const linkPath = path.join(mapsDir, linkName);

      // ① 守卫本体(与"能不能建链接"无关的那一半):目标经 realpath 后落在 maps/ 之外 → 必须抛。
      //    ★ 断言必须同时判**错在哪**(照 rejects() 的纪律):只判"有没有抛"是假绿 ——
      //      守卫不存在时抛出来的 TypeError 一样算通过。
      let guardErr = null;
      try { srv.assertWriteTargetInside(mapsDir, victimPath, linkName); } catch (e) { guardErr = e; }
      ok(guardErr !== null && errText(guardErr).indexOf('maps 目录之外') >= 0,
         '★ 硬要求 B 守卫本体:目标真实路径落在 maps/ 之外 → 抛错并点名原因(实得:' +
         (guardErr === null ? '(未抛错)' : errText(guardErr)) + ')');
      sameBytes(fs.readFileSync(victimPath), victimBytes,
                '★ 硬要求 B:那次调用(它只是判,不写)之后外部文件仍逐字节未变');

      // ② 端到端:在 maps/ 里造一个指向**外部**的链接,PUT 它必须被拒。
      //    ★ 本机(Windows、非管理员)建不了**文件**符号链接(EPERM —— 需要 SeCreateSymbolicLinkPrivilege
      //      或开发者模式),但**目录联接(junction)**不需要特权。守卫判的是"真实路径落在哪里",
      //      与链接的类型无关,故这是等价的实测。建不了就打印一行跳过(**不计入 ok/FAIL**),
      //      绝不写会飘的断言。
      let linked = false;
      try { fs.symlinkSync(outsideDir, linkPath, 'junction'); linked = true; }
      catch (e) { console.log('  --    硬要求 B 跳过(端到端那两条):本环境建不了符号链接/联接(' + errText(e) + ')'); }
      try {
        if (linked) {
          ok(fs.lstatSync(linkPath).isSymbolicLink(),
             '硬要求 B 前置:' + linkName + ' 确实是一个链接(不是普通文件)');
          ok(fs.realpathSync(linkPath) === fs.realpathSync(outsideDir),
             '硬要求 B 前置:它的**真实路径**落在 maps/ 之外(' + fs.realpathSync(linkPath) + ')');
          const rLink = await request(apiSrv.port, 'PUT', '/api/map?p=' + linkName, Buffer.from([0xAA, 0xBB]),
                                      PUT_JSON);
          ok(rLink.status === 403,
             '★★ 硬要求 B:PUT 一个指向 maps/ 之外的链接 → 403 拒绝(实得 ' + rLink.status +
             ';若实得 500 说明它是走到 rename 才失败的,那就不是 realpath 闸挡的)');
          sameBytes(fs.readFileSync(victimPath), victimBytes,
                    '★★ 硬要求 B:那个外部文件逐字节未变(被拒的写一个字节都没落盘)');
          ok(fs.existsSync(linkPath), '★ 硬要求 B:链接本身也还在(没有被 rename 覆盖掉)');
          ok(fs.readdirSync(outsideDir).length === 1,
             '★ 硬要求 B:maps/ 之外那个目录里没有多出任何东西(实得 ' +
             fs.readdirSync(outsideDir).join(',') + ')');
          ok(noTmpLeft(), '★ 硬要求 B:被拒的链接写也没在 maps/ 里留临时文件');
        }
      } finally {
        // ★ 一定要收掉:留着它会让后面任何一个"列 maps/ 目录"的断言多出一个条目。
        try { if (fs.existsSync(linkPath)) fs.unlinkSync(linkPath); } catch (e) { /* 清不掉不该盖住真失败 */ }
      }
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
