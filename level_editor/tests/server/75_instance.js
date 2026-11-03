'use strict';
// tests/server/75_instance.js —— 相位 ⑩:单实例(重启 = 结束上一个自己)。
// ★ 两层判据:① 判定逻辑(注入探针,秒级、确定性);② 真进程一次(两个 CLI 抢同一个端口,
//   前一个必须被结束、后一个必须起来)。第二层是唯一能证明"命令行入口真的接上了"的那条。
// ★ 全程临时目录 + 临时端口 + 临时 --pid-file:绝不碰 8777,也不在 level_editor/ 里留 PID 文件。
globalThis.serverChain = globalThis.serverChain.then(async function () {
const fs = require('fs');
const net = require('net');
const path = require('path');
const { spawn, execFileSync } = require('child_process');
const srv = require('../../editor_server.js');

const sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
const pidFile = path.join(tmpRoot, 'editor.pid');
const writeRec = function (rec) { srv.writePidFile(pidFile, rec); };

  // ==== ① PID 文件本身:写得出、读得回、坏文件不致命 ====
  {
    ok(srv.PID_FILE_NAME === '.editor_server.pid',
       '★ PID 文件名 === .editor_server.pid(实得 ' + srv.PID_FILE_NAME + ')');
    ok(srv.pidFilePath(EDITOR_DIR) === path.join(path.resolve(EDITOR_DIR), '.editor_server.pid'),
       '★ pidFilePath(rootDir) = <rootDir>/.editor_server.pid');
    eq(srv.readPidFile(pidFile), null, '没有 PID 文件 → null（不是抛错、不是空对象）');
    ok(srv.isAlive(process.pid) === true, 'isAlive(自己) → true');
    ok(srv.isAlive(0) === false && srv.isAlive(-1) === false && srv.isAlive(null) === false,
       '★ isAlive(0/-1/null) → false（pid ≤ 0 的 kill 语义是"整个进程组",绝不许拿它当探针）');
    fs.writeFileSync(pidFile, '{ 这不是 JSON', 'utf8');
    const broken = srv.readPidFile(pidFile);
    ok(broken && broken.broken === true, '★ 坏 JSON → {broken:true}（内容不可信 ⇒ 只删不用）');
    srv.removePidFile(pidFile);
    ok(!fs.existsSync(pidFile) && srv.removePidFile(pidFile) === false,
       'removePidFile:删掉了返回 true,文件已不在时返回 false 且不抛');
    // --keep / --pid-file 的解析(替换逻辑的开关只在命令行入口生效,这里钉住开关形态)
    tableEq('parseArgs:单实例开关', [
      ['默认:replaceStale 不设(= 替换开)', srv.parseArgs([]).replaceStale, undefined],
      ['--keep → replaceStale:false', srv.parseArgs(['--keep']).replaceStale, false],
      ['--no-replace 别名', srv.parseArgs(['--no-replace']).replaceStale, false],
      ['--pid-file 取值', srv.parseArgs(['--pid-file', 'x.pid']).pidFile, 'x.pid'],
    ]);
  }

  // ==== ② 判定逻辑(注入探针):每一道闸都必须能单独把"杀"拦下来 ====
  {
    const killer = function () { const r = { killed: [] }; r.killFn = function (p) { r.killed.push(p); }; return r; };
    const rec = { pid: 4242, port: 8777 };
    const base = { pidFile: pidFile, port: 8777, aliveFn: function () { return true; },
                   cmdlineFn: function () { return 'node  editor_server.js'; },
                   imageFn: function () { return 'node.exe'; },
                   portFreeFn: function () { return false; } };

    writeRec(rec);
    const k1 = killer();
    const miss = await srv.replaceStaleInstance(Object.assign({}, base, { pidFile: path.join(tmpRoot, 'nope.pid'),
                                                                         killFn: k1.killFn }));
    ok(miss.replaced === null && k1.killed.length === 0, '没有 PID 文件 → replaced:null、一次都没杀');

    writeRec(rec);
    const k2 = killer();
    await srv.replaceStaleInstance(Object.assign({}, base, { aliveFn: function () { return false; },
                                                             killFn: k2.killFn }));
    ok(k2.killed.length === 0 && !fs.existsSync(pidFile),
       '★ PID 指向的进程已经不在 → 不杀、只删掉陈旧的 PID 文件');

    writeRec(Object.assign({}, rec, { pid: process.pid }));
    const k3 = killer();
    const self = await srv.replaceStaleInstance(Object.assign({}, base, { killFn: k3.killFn,
                                                                          aliveFn: function () { return true; } }));
    ok(self.replaced === null && k3.killed.length === 0, '★★ PID 文件指向自己 → 不杀（自保护）');

    writeRec(Object.assign({}, rec, { port: 9999 }));
    const k4 = killer();
    await srv.replaceStaleInstance(Object.assign({}, base, { killFn: k4.killFn }));
    ok(k4.killed.length === 0 && fs.existsSync(pidFile),
       '★★ PID 文件记的端口与本次不同 → 不动它、不删它（那是另一台实例的记录）');

    writeRec(rec);
    const k5 = killer();
    const freed = await srv.replaceStaleInstance(Object.assign({}, base, { killFn: k5.killFn,
                                                                           portFreeFn: function () { return true; } }));
    ok(freed.replaced === null && k5.killed.length === 0 && !fs.existsSync(pidFile),
       '★★ 端口已经空着 → 一次都不杀（只清陈旧文件）—— 防的是"PID 被复用给了无关进程"那一刀');

    writeRec(rec);
    const k6 = killer();
    let refused = null;
    try { await srv.replaceStaleInstance(Object.assign({}, base, { killFn: k6.killFn,
                                                                    imageFn: function () { return 'chrome.exe'; } })); }
    catch (e) { refused = e; }
    ok(refused !== null && errText(refused).indexOf('拒绝') >= 0 && k6.killed.length === 0,
       '★★ 映像名不是 node → 拒绝结束并给出理由（实得: ' +
       (refused === null ? '(没抛错 —— 危险)' : errText(refused).split('。')[0]) + '）');

    writeRec(rec);
    const k7 = killer();
    refused = null;
    try { await srv.replaceStaleInstance(Object.assign({}, base, { killFn: k7.killFn,
                                                                    cmdlineFn: function () { return null; } })); }
    catch (e) { refused = e; }
    ok(refused !== null && errText(refused).indexOf('查不到') >= 0 && k7.killed.length === 0,
       '★★ 查不到命令行 → fail closed（拒绝杀）—— 这是"绝不无脑 taskkill"的最后一道');

    writeRec(rec);
    const k8 = killer();
    refused = null;
    try { await srv.replaceStaleInstance(Object.assign({}, base, { killFn: k8.killFn,
                                                                    cmdlineFn: function () { return 'node server_main.tscn x'; } })); }
    catch (e) { refused = e; }
    ok(refused !== null && errText(refused).indexOf('editor_server.js') >= 0 && k8.killed.length === 0,
       '★★★ 命令行里没有 editor_server.js → 拒绝结束（7777 上那个游戏服务端就是这个形状）');

    // 全过 → 杀一次,且要等端口释放之后才返回
    writeRec(rec);
    let released = false;
    const killed = [];
    const okRep = await srv.replaceStaleInstance(Object.assign({}, base, {
      killFn: function (p) { killed.push(p); released = true; },
      portFreeFn: function () { return released; },
      timeoutMs: 500, pollMs: 10,
    }));
    ok(okRep.replaced === 4242 && killed.length === 1 && killed[0] === 4242,
       '★★ 四道判据全过 → 恰好杀一次那个 PID（实得 ' + JSON.stringify(killed) + '）');
    ok(!fs.existsSync(pidFile), '★ 替换成功后 PID 文件被清掉（下一次启动从干净状态开始）');

    // 杀了但端口一直不释放 → 抛错 + 给出手工命令,而不是硬起一个必然 EADDRINUSE 的服务器
    writeRec(rec);
    refused = null;
    const k9 = killer();
    try {
      await srv.replaceStaleInstance(Object.assign({}, base, { killFn: k9.killFn,
                                                               portFreeFn: function () { return false; },
                                                               timeoutMs: 120, pollMs: 10 }));
    } catch (e) { refused = e; }
    ok(refused !== null && errText(refused).indexOf('没有释放') >= 0 && k9.killed.length === 1,
       '★★ 杀了但端口 120ms 内没释放 → 抛错并点名端口（实得: ' +
       (refused === null ? '(没抛错)' : errText(refused).slice(0, 60)) + '）');
    srv.removePidFile(pidFile);
  }

  // ==== ②b 没有 PID 文件时的兜底:按端口找占用者,再用命令行认"自己人" ====
  // ★ 这正是用户报 ③ 时的真实场景:PID 文件是这次改动才有的,而机器上早有一个老 serve.bat
  //   起的 node 占着 8777 ⇒ 只靠 PID 文件的实现第一次重启必然失败。
  {
    const free = function () { return false; };          // 端口占着
    const orphanBase = { port: 8777, portFreeFn: free,
                         cmdlineFn: function () { return 'node  editor_server.js'; },
                         imageFn: function () { return 'node.exe'; } };
    const killed = [];
    const rep = await srv.reclaimOrphanOnPort(Object.assign({}, orphanBase, {
      portOwnerFn: function () { return 7777; },
      killFn: function (p) { killed.push(p); },
      portFreeFn: function () { return killed.length > 0; },
      timeoutMs: 300, pollMs: 10,
    }));
    ok(rep.replaced === 7777 && killed.length === 1,
       '★★★ 没有 PID 文件但端口被"命令行含 editor_server.js"的进程占着 → 结束它并接管（实得 ' +
       JSON.stringify(killed) + '）');

    const k2 = [];
    let refused2 = null;
    try {
      await srv.reclaimOrphanOnPort(Object.assign({}, orphanBase, {
        portOwnerFn: function () { return 7778; },
        cmdlineFn: function () { return 'node server_main.tscn'; },     // 7777 上那个游戏服务端
        killFn: function (p) { k2.push(p); },
      }));
    } catch (e) { refused2 = e; }
    ok(refused2 !== null && errText(refused2).indexOf('拒绝') >= 0 && k2.length === 0,
       '★★★ 占用者不是编辑器服务器 → 拒绝结束（实得: ' +
       (refused2 === null ? '(没抛错 —— 危险)' : errText(refused2).split('。')[0]) + '）');

    const k3 = [];
    const noOwner = await srv.reclaimOrphanOnPort(Object.assign({}, orphanBase, {
      portOwnerFn: function () { return null; },                       // 查不到占用者
      killFn: function (p) { k3.push(p); },
    }));
    ok(noOwner.replaced === null && k3.length === 0,
       '★★ 端口被占但查不到占用者 PID → 一次都不杀（fail closed，不猜）');
  }

  // ==== ③ 真进程:第二个 CLI 必须结束第一个并接管端口 ====
  {
    const freePort = await new Promise(function (resolve, reject) {
      const s = net.createServer();
      s.once('error', reject);
      s.listen(0, '127.0.0.1', function () {
        const p = s.address().port;
        s.close(function () { resolve(p); });
      });
    });
    const instMaps = path.join(tmpRoot, 'inst_maps');
    fs.mkdirSync(instMaps, { recursive: true });
    const cliArgs = ['--port', String(freePort), '--no-open', '--maps', instMaps, '--pid-file', pidFile];
    const children = [];
    const outOf = function (c) { return c.stdoutText || ''; };
    const spawnCli = function () {
      const c = spawn(process.execPath, ['editor_server.js'].concat(cliArgs), {
        cwd: EDITOR_DIR, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
      });
      c.stdoutText = ''; c.stderrText = '';
      c.stdout.on('data', function (d) { c.stdoutText += String(d); });
      c.stderr.on('data', function (d) { c.stderrText += String(d); });
      children.push(c);
      return c;
    };
    const waitReady = async function (timeoutMs) {
      const t0 = Date.now();
      for (;;) {
        try {
          const r = await request(freePort, 'GET', '/api/maps');
          if (r.status === 200) return true;
        } catch (e) { /* 还没起来 */ }
        if (Date.now() - t0 >= timeoutMs) return false;
        await sleep(120);
      }
    };
    const waitExit = function (c, timeoutMs) {
      return new Promise(function (resolve) {
        if (c.exitCode !== null || c.signalCode !== null) return resolve(true);
        const t = setTimeout(function () { resolve(false); }, timeoutMs);
        c.once('exit', function () { clearTimeout(t); resolve(true); });
      });
    };
    try {
      const a = spawnCli();
      ok(await waitReady(20000), '③ 前置:第一个实例起来了(端口 ' + freePort + ')');
      const recA = srv.readPidFile(pidFile);
      ok(recA && recA.pid === a.pid,
         '★★ ③ 起来之后写了 PID 文件:PID 是子进程自己(' + (recA ? recA.pid : '(无)') + ' vs ' + a.pid + ')');

      const b = spawnCli();
      const aGone = await waitExit(a, 25000);
      ok(aGone, '★★★ ③ 第二次启动把第一个实例**结束**了(它没有一直占着端口活下去)');
      ok(await waitReady(25000), '★★ ③ 第二个实例接管了同一个端口');
      ok(outOf(b).indexOf('已结束旧实例 PID ' + a.pid) >= 0,
         '★ ③ 第二个实例把它干的事说出来了(实得 ' + JSON.stringify(outOf(b).split('\n')[0]) + ')');
      const recB = srv.readPidFile(pidFile);
      ok(recB && recB.pid === b.pid && recB.port === freePort,
         '★ ③ PID 文件换成了新实例(PID ' + (recB ? recB.pid : '(无)') + ',端口 ' +
         (recB ? recB.port : '(无)') + ')');
      // ★ 判据必须是"**这次测试**没往默认位置写",而不是"默认位置没有 PID 文件" —— 后者在
      //   用户正开着一个编辑器服务器时恒红(那台服务器**本该**有 PID 文件),是环境依赖的假红。
      const defPid = path.join(EDITOR_DIR, srv.PID_FILE_NAME);
      let defRec = null;
      try { defRec = JSON.parse(fs.readFileSync(defPid, 'utf8')); } catch (e) { defRec = null; }
      const defIsOurs = !!(defRec && (defRec.pid === a.pid || defRec.pid === b.pid ||
                                       defRec.port === freePort));
      ok(!defIsOurs,
         '★★ ③ 全程没有**往默认位置**写 PID 文件(用的是 --pid-file 指到临时目录;默认位置' +
         (defRec ? '有一个不属于本次测试的 PID 文件,那是用户开着的服务器' : '没有文件') + ')');
    } finally {
      for (const c of children) {
        if (c.exitCode !== null || c.signalCode !== null) continue;
        try { c.kill(); } catch (e) { /* 已经死了 */ }
        if (!(await waitExit(c, 5000))) {
          try { execFileSync('taskkill', ['/PID', String(c.pid), '/F'], { stdio: 'ignore' }); } catch (e) { /* 尽力 */ }
          await waitExit(c, 5000);
        }
      }
      srv.removePidFile(pidFile);
    }
  }
});
