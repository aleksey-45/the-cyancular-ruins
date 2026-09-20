'use strict';
// Node 冒烟 —— 本地服务器 level_editor/editor_server.js(规格 §4.9)。
// Run: cd level_editor && node server_smoke.js
// 判据:文本 `SERVER SMOKE OK` + 退出码 0。
// ★ 本文件只碰 mkdtemp 出来的临时目录:真实 maps/ 目录一次都不写。

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const { execFileSync } = require('child_process');
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
function request(port, method, reqPath, body) {
  return new Promise(function (resolve, reject) {
    const req = http.request({ host: '127.0.0.1', port: port, method: method, path: reqPath },
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

(async function main() {
  // ★ 看门狗:任何一处挂住(server 没关 / promise 永不 settle)都走到这里,
  //   而不是让 node 静默退出。★ 刻意**不 unref**:事件循环空转时静默退出(退出码 0、
  //   一行不打)才是最难发现的假绿 —— core.js 的 inflateBytes 实测踩过这一档。
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 有 server 没关,或某个 promise 永不 settle');
    process.exit(1);
  }, 120000);

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
    ok(srv.describePortOwner(a.port).indexOf('netstat') >= 0, 'describePortOwner: 给出查占用者的命令');
    ok(typeof srv.openBrowser === 'function', 'openBrowser 已导出(可注入)');
    ok(srv.parseArgs(['--no-open']).openBrowser === false, "parseArgs: --no-open → openBrowser:false");
    ok(srv.parseArgs([]).openBrowser === undefined,
       'parseArgs: 默认不设该键 —— 默认值只在命令行入口变成 true(库默认弹浏览器 = 每个冒烟用例弹一个窗口)');
  }

  // ==== 断言区结束 ====
  await shutdown();
  fs.rmSync(tmpRoot, { recursive: true, force: true });
  console.log('');
  console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
  if (fail === 0) console.log('SERVER SMOKE OK');
  process.exit(fail === 0 ? 0 : 1);
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
