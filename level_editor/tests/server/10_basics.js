'use strict';
// tests/server/10_basics.js —— 相位 ①/①b/②/③/④:常量与集成约束 / 静态服务与 Host 闸 / 路径穿越 / 启动诊断。
globalThis.serverChain = globalThis.serverChain.then(async function () {
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const srv = require('../../editor_server.js');
  if (process.env.CYRM_SMOKE_SELFTEST_THROW === '1') throw new Error('待修 4 自检:人为抛错');
  // ==== 相位 ① 常量与文件结构 ====
  ok(srv.DEFAULT_PORT === 8777, 'DEFAULT_PORT === 8777(避开游戏侧 7777/7800+/7999)');
  ok(srv.DEFAULT_HOST === '127.0.0.1', '★ DEFAULT_HOST === 127.0.0.1(绝不绑 0.0.0.0)');
  ok(srv.MAX_MAP_BYTES === 64 * 1024 * 1024, 'MAX_MAP_BYTES === 64MB(与 core.js 的 MAX_BODY_SIZE 同值)');
  ok(srv.DEFAULT_ROOT_DIR === EDITOR_DIR, 'DEFAULT_ROOT_DIR === level_editor/');
  ok(srv.DEFAULT_MAPS_DIR === path.join(EDITOR_DIR, '..', 'maps'), 'DEFAULT_MAPS_DIR === 仓库根的 maps/');
  ok(srv.DEFAULT_INDEX === 'editor.html', 'DEFAULT_INDEX === editor.html');
      // ★ 入口页是 editor.html:敌人注册表由 sync-enemies.js 从 data/enemies.json 生成,下面跑
      //   --check 对账(漂移即红);旧页 structure-editor.html 已退休。
  (function () {
    let out = '', code = 0;
    try {
      out = execFileSync(process.execPath, [path.join(EDITOR_DIR, 'sync-enemies.js'), '--check'],
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
    rootDir: EDITOR_DIR, mapsDir: path.join(tmpRoot, 'maps'), port: 0,
  }));
  {
    const r1 = await request(staticSrv.port, 'GET', '/');
    ok(r1.status === 200, 'GET / → 200(实得 ' + r1.status + ')');
    ok(/^text\/html/.test(String(r1.headers['content-type'])), 'GET / → Content-Type: text/html');
    ok(/<!DOCTYPE html>/i.test(r1.body.toString('utf8')), 'GET / 返回的是入口页本身');
    ok(r1.headers['cache-control'] === 'no-store', 'GET / → Cache-Control: no-store(改完刷新就能看到新代码)');

    const r2 = await request(staticSrv.port, 'GET', '/core/00_constants.js');
    ok(r2.status === 200, 'GET /core/00_constants.js → 200');
    ok(/^text\/javascript/.test(String(r2.headers['content-type'])), 'GET 分片 → text/javascript');
    sameBytes(r2.body, fs.readFileSync(path.join(EDITOR_DIR, 'core', '00_constants.js')),
              'GET 分片的字节与磁盘逐字节一致');

    const r3 = await request(staticSrv.port, 'GET', '/nope.js');
    ok(r3.status === 404, 'GET 不存在的文件 → 404');
    const r4 = await request(staticSrv.port, 'POST', '/core/00_constants.js');
    ok(r4.status === 405, '静态路径 POST → 405');
    const r5 = await request(staticSrv.port, 'GET', '/api/nope');
    ok(r5.status === 404, '未实现的 /api/* → 404');
    const addr = staticSrv.server.address();
    ok(addr.address === '127.0.0.1' || addr.address === '::ffff:127.0.0.1',
       '★ 实际绑定地址是回环(实得 ' + addr.address + ')');

    // ★ 只绑 127.0.0.1 挡不住 DNS rebinding:恶意页面把域名解析到 127.0.0.1 就同源打进来了。
    //   本文件其余所有断言都靠 node http 客户端自动生成的 Host: 127.0.0.1:<port> —— 它们
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
      // ★ 只断言「正文里没 secret」是不够的:一个 500 或空正文也会通过(两者都读不到 secret)。
      //   这里补状态断言。★ 接受 403 或 404:/../secret.txt 会被 URL 解析器归一化成
      //   /secret.txt(节点本来就不存在)⇒ 合法地走 404;真正被穿越闸拦下的是编码过的那几条(403)。
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
    const a = track(await srv.startServer({ rootDir: EDITOR_DIR, mapsDir: path.join(tmpRoot, 'maps'), port: 0 }));
    await rejects(function () {
      return srv.startServer({ rootDir: EDITOR_DIR, mapsDir: path.join(tmpRoot, 'maps'), port: a.port });
    }, '★ 同端口再起一个 → 抛错(不是静默退出)', '已被占用');
    // ★ 报错文本的首行必须点名端口号。只断言「含端口号」会被 netstat 提示里那两处
    //   出现蒙混过去(提示里本来就带端口),那样首行丢了端口也照样绿。
    let addrErr = null;
    try {
      await srv.startServer({ rootDir: EDITOR_DIR, mapsDir: path.join(tmpRoot, 'maps'), port: a.port });
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
});