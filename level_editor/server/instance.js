'use strict';

const fs = require('fs');
const net = require('net');
const path = require('path');
const { execFileSync } = require('child_process');

// 编辑器服务器的"单实例"机制:重启 = 结束上一个自己,而不是撞一个 EADDRINUSE 让用户去开 netstat。
// ★★ 唯一的安全边界:**只杀"我们自己记下来、且命令行里点名 editor_server.js"的那个进程**。
//    绝不按端口乱杀 —— 7777 上是游戏服务端(AGENTS §1 的 7777 禁令同源),而且在同一台机器上
//    "端口被谁占"是随时会变的。四道判据缺一不可:① PID 文件里的 pid 还活着;② 端口与 PID 文件记的
//    相同;③ 那个端口**真的还被占着**(没占就没必要杀);④ 该 pid 的命令行含 'editor_server.js'。
//    判不出来(查不到命令行)就 fail closed:拒绝杀,把手工命令打给用户。

const PID_FILE_NAME = '.editor_server.pid';
const WAIT_PORT_FREE_MS = 3000;
const WAIT_POLL_MS = 100;
const PROBE_TIMEOUT_MS = 400;
const INFER_TIMEOUT_MS = 15000;          // powershell / ps / tasklist 的外层上限(冷启动实测 ~2s)

function pidFilePath(rootDir) {
  return path.join(path.resolve(rootDir), PID_FILE_NAME);
}

function defaultSleep(ms) {
  return new Promise(function (r) { setTimeout(r, ms); });
}

function msgOf(e) {
  return (e && e.message !== undefined) ? String(e.message) : String(e);
}

// 读 PID 文件:null = 没有;{broken:true} = 有但解不开(内容不可信 ⇒ 只删不用)。
function readPidFile(file) {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); } catch (e) { return null; }
  let o = null;
  try { o = JSON.parse(raw); } catch (e) { return { broken: true, raw: raw }; }
  if (!o || typeof o !== 'object' || Array.isArray(o)) return { broken: true, raw: raw };
  return o;
}

function writePidFile(file, rec) {
  fs.writeFileSync(file, JSON.stringify(rec, null, 2) + '\n', 'utf8');
}

// 删不掉不致命(下次会当成陈旧记录覆盖掉);也绝不因为删不掉而让退出路径抛错。
function removePidFile(file) {
  try { fs.unlinkSync(file); return true; } catch (e) { return false; }
}

// 进程还在不在。EPERM = 活着但没权限给它发信号(仍然是活着)。
// ★ pid <= 0 一律当"不在":process.kill(0, …) 的语义是"整个进程组",拿它当探针会误伤。
function isAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return !!(e && e.code === 'EPERM'); }
}

// 进程命令行 —— 「这是我们自己的进程」的**主闸**。查不到返回 null,调用方必须 fail closed。
function procCmdline(pid) {
  try {
    if (process.platform === 'linux') {
      const s = fs.readFileSync('/proc/' + pid + '/cmdline', 'utf8').split('\u0000').filter(Boolean).join(' ');
      return s.trim() || null;
    }
    if (process.platform === 'win32') {
      const out = execFileSync('powershell', ['-NoProfile', '-NonInteractive', '-Command',
        "(Get-CimInstance Win32_Process -Filter 'ProcessId=" + pid + "').CommandLine"],
        { encoding: 'utf8', timeout: INFER_TIMEOUT_MS, windowsHide: true });
      const s = String(out).trim();
      return s || null;
    }
    const out = execFileSync('ps', ['-p', String(pid), '-o', 'command='],
                             { encoding: 'utf8', timeout: INFER_TIMEOUT_MS });
    return String(out).trim() || null;
  } catch (e) { return null; }
}

// 映像名(win32 专用,便宜的前置筛子:~0.3s)。拿不到返回 null(跳过这道理,仍要过命令行那道主闸)。
function procImageName(pid) {
  if (process.platform !== 'win32') return null;
  try {
    const out = execFileSync('tasklist', ['/FI', 'PID eq ' + pid, '/FO', 'CSV', '/NH'],
                             { encoding: 'utf8', timeout: INFER_TIMEOUT_MS, windowsHide: true });
    const m = /^"([^"]+)"/m.exec(String(out));
    return m ? m[1] : null;
  } catch (e) { return null; }
}

// 端口是不是空着:只有 ECONNREFUSED 才算空;超时 / 其它错误一律当"占着"(fail closed)。
function isPortFree(port, host) {
  return new Promise(function (resolve) {
    const sock = net.connect({ port: port, host: host });
    let settled = false;
    const done = function (v) {
      if (settled) return;
      settled = true;
      try { sock.destroy(); } catch (e) { /* 已经断了 */ }
      resolve(v);
    };
    sock.setTimeout(PROBE_TIMEOUT_MS, function () { done(false); });
    sock.once('connect', function () { done(false); });
    sock.once('error', function (e) { done(!!(e && e.code === 'ECONNREFUSED')); });
  });
}

function killPid(pid) {
  if (process.platform === 'win32') {
    execFileSync('taskkill', ['/PID', String(pid), '/F'], { stdio: 'ignore', timeout: INFER_TIMEOUT_MS });
    return;
  }
  process.kill(pid, 'SIGTERM');
}

function killHint(pid, port) {
  return process.platform === 'win32'
    ? 'taskkill /PID ' + pid + ' /F'
    : 'kill ' + pid + '(它占着端口 ' + port + ')';
}

// 轮询等端口释放,返回 true/false(不抛 —— 超时那句话由调用方组织,它才知道 PID)。
async function waitPortFree(port, host, o) {
  o = o || {};
  const timeout = o.timeoutMs === undefined ? WAIT_PORT_FREE_MS : o.timeoutMs;
  const poll = o.pollMs === undefined ? WAIT_POLL_MS : o.pollMs;
  const free = o.portFreeFn || isPortFree;
  const sleep = o.sleepFn || defaultSleep;
  const t0 = Date.now();
  for (;;) {
    if (await free(port, host)) return true;
    if (Date.now() - t0 >= timeout) return false;
    await sleep(poll);
  }
}

// 结束上一个自己。返回 {replaced: pid|null, note};拒绝杀 / 等不到端口释放时抛错(带手工命令)。
async function replaceStaleInstance(o) {
  o = o || {};
  const file = o.pidFile;
  const port = Number(o.port);
  const host = o.host || '127.0.0.1';
  const aliveFn = o.aliveFn || isAlive;
  const cmdlineFn = o.cmdlineFn || procCmdline;
  const imageFn = o.imageFn || procImageName;
  const freeFn = o.portFreeFn || isPortFree;
  const killFn = o.killFn || killPid;
  const rec = readPidFile(file);
  if (rec === null) return { replaced: null, note: '没有 PID 文件' };
  if (rec.broken) { removePidFile(file); return { replaced: null, note: 'PID 文件损坏,已删掉' }; }
  if (!aliveFn(rec.pid)) { removePidFile(file); return { replaced: null, note: 'PID 文件指向的进程已经不在了' }; }
  if (rec.pid === process.pid) return { replaced: null, note: 'PID 文件指向的就是自己' };
  if (Number(rec.port) !== port) {
    return { replaced: null, note: 'PID 文件记的是端口 ' + rec.port + ',本次是 ' + port + ' ⇒ 不动它' };
  }
  // ★ 端口空着就什么都不杀(旧进程可能已经死掉但 PID 被复用给了别的程序 —— 那种情况下杀它是灾难)。
  if (await freeFn(port, host)) {
    removePidFile(file);
    return { replaced: null, note: '端口已经空着(旧实例已退出),只清掉陈旧 PID 文件' };
  }
  const image = imageFn(rec.pid);
  if (image && !/^node(\.exe)?$/i.test(image)) {
    throw new Error('PID ' + rec.pid + ' 的映像名是 ' + image + ',不是 node —— 拒绝结束它。' +
                    '若确实要重启,请手动:' + killHint(rec.pid, port));
  }
  const cmd = cmdlineFn(rec.pid);
  if (cmd === null) {
    throw new Error('查不到 PID ' + rec.pid + ' 的命令行,无法确认它是编辑器服务器 ⇒ 拒绝结束它。' +
                    '请手动:' + killHint(rec.pid, port));
  }
  if (cmd.indexOf('editor_server.js') < 0) {
    throw new Error('PID ' + rec.pid + ' 的命令行里没有 editor_server.js(实得 ' + JSON.stringify(cmd) +
                    ') ⇒ 拒绝结束它。请手动确认:' + killHint(rec.pid, port));
  }
  try { killFn(rec.pid); }
  catch (e) {
    throw new Error('结束旧实例 PID ' + rec.pid + ' 失败:' + msgOf(e) +
                    '。请手动:' + killHint(rec.pid, port));
  }
  const freed = await waitPortFree(port, host, { timeoutMs: o.timeoutMs, pollMs: o.pollMs,
                                                 portFreeFn: freeFn, sleepFn: o.sleepFn });
  if (!freed) {
    throw new Error('旧实例 PID ' + rec.pid + ' 已结束,但端口 ' + port + ' 在 ' +
                    (o.timeoutMs === undefined ? WAIT_PORT_FREE_MS : o.timeoutMs) +
                    'ms 内没有释放。请确认没有别的进程占着它:' +
                    (process.platform === 'win32'
                      ? 'netstat -ano | findstr :' + port + ',再 ' + killHint('<PID>', port)
                      : 'lsof -i :' + port));
  }
  removePidFile(file);
  if (typeof o.logger === 'function') o.logger('已结束旧实例 PID ' + rec.pid + '(' + cmd + ')');
  return { replaced: rec.pid, note: '已替换旧实例', cmdline: cmd };
}

// 端口占用者的 PID。查不到返回 null(调用方必须当成"不知道是谁"处理,不许乱杀)。
// ★ 只用操作系统的现成读数:win32 走 netstat -ano(LISTENING 那行最后一列就是 PID)、
//   linux 走 ss -lptn 的 pid=NNN;其它平台直接放弃(返回 null ⇒ fail closed)。
function portOwnerPid(port) {
  try {
    if (process.platform === 'win32') {
      const out = execFileSync('netstat', ['-ano'], { encoding: 'utf8', timeout: INFER_TIMEOUT_MS,
                                                     windowsHide: true });
      const lines = String(out).split(/\r?\n/);
      for (const l of lines) {
        if (!/LISTENING/i.test(l)) continue;
        if (l.indexOf(':' + port + ' ') < 0) continue;
        const parts = l.trim().split(/\s+/);
        const pid = parseInt(parts[parts.length - 1], 10);
        if (Number.isInteger(pid) && pid > 0) return pid;
      }
      return null;
    }
    if (process.platform === 'linux') {
      const out = execFileSync('ss', ['-lptn', 'sport = :' + port], { encoding: 'utf8',
                                                                      timeout: INFER_TIMEOUT_MS });
      const m = /pid=(\d+)/.exec(String(out));
      return m ? parseInt(m[1], 10) : null;
    }
  } catch (e) { return null; }
  return null;
}

// ★★ 「重启要结束旧的」在**第一次**遇上老版本时是拿不到 PID 文件的(那份文件是这次改动才有的),
//    所以还要一条"按端口找占用者、再用命令行认自己人"的兜底。判据与 PID 文件那条**同样严格**:
//    端口真的被占 + 映像名是 node + 命令行含 editor_server.js,少一条就 fail closed 拒绝杀。
//    这条能覆盖:老版本 serve.bat 起的孤儿、PID 文件被手删、PID 文件损坏后被清掉。
async function reclaimOrphanOnPort(o) {
  o = o || {};
  const port = Number(o.port);
  const host = o.host || '127.0.0.1';
  const freeFn = o.portFreeFn || isPortFree;
  const ownerFn = o.portOwnerFn || portOwnerPid;
  const cmdlineFn = o.cmdlineFn || procCmdline;
  const imageFn = o.imageFn || procImageName;
  const killFn = o.killFn || killPid;
  if (await freeFn(port, host)) return { replaced: null, note: '端口空着,没有孤儿' };
  let pid = null;
  try { pid = ownerFn(port); } catch (e) { pid = null; }
  if (!pid) return { replaced: null, note: '端口被占,但查不到占用者 PID(不做任何动作)' };
  if (pid === process.pid) return { replaced: null, note: '占用者就是自己' };
  const image = imageFn(pid);
  if (image && !/^node(\.exe)?$/i.test(image)) {
    throw new Error('端口 ' + port + ' 被 ' + image + '(PID ' + pid + ')占着,不是 node ⇒ 拒绝结束它。' +
                    '请手动确认:' + killHint(pid, port));
  }
  const cmd = cmdlineFn(pid);
  if (!cmd) {
    throw new Error('查不到端口 ' + port + ' 占用者 PID ' + pid + ' 的命令行,无法确认它是编辑器服务器 ⇒ 拒绝结束它。' +
                    '请手动:' + killHint(pid, port));
  }
  if (cmd.indexOf('editor_server.js') < 0) {
    throw new Error('端口 ' + port + ' 的占用者 PID ' + pid + ' 不是编辑器服务器(命令行 ' +
                    JSON.stringify(cmd) + ') ⇒ 拒绝结束它。请手动确认:' + killHint(pid, port));
  }
  try { killFn(pid); }
  catch (e) {
    throw new Error('结束占用端口的旧实例 PID ' + pid + ' 失败:' + msgOf(e) +
                    '。请手动:' + killHint(pid, port));
  }
  const freed = await waitPortFree(port, host, { timeoutMs: o.timeoutMs, pollMs: o.pollMs,
                                                 portFreeFn: freeFn, sleepFn: o.sleepFn });
  if (!freed) {
    throw new Error('旧实例 PID ' + pid + ' 已结束,但端口 ' + port + ' 没有释放。请确认没有别的进程占着它:' +
                    (process.platform === 'win32'
                      ? 'netstat -ano | findstr :' + port
                      : 'lsof -i :' + port));
  }
  if (typeof o.logger === 'function') o.logger('已结束占用端口的旧实例 PID ' + pid + '(' + cmd + ')');
  return { replaced: pid, note: '已结束占用端口的旧编辑器实例(没有 PID 文件)', cmdline: cmd };
}

// 启动成功后挂上:退出时删 PID 文件。★ 删不掉不致命(PID 文件里只是记录,下一次会被判陈旧)。
function installPidCleanup(file) {
  const bye = function () { removePidFile(file); };
  process.once('exit', bye);
  ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGBREAK'].forEach(function (sig) {
    try {
      process.on(sig, function () { bye(); process.exit(0); });
    } catch (e) { /* 平台没有这个信号:忽略 */ }
  });
}

module.exports = {
  PID_FILE_NAME: PID_FILE_NAME, WAIT_PORT_FREE_MS: WAIT_PORT_FREE_MS, WAIT_POLL_MS: WAIT_POLL_MS,
  pidFilePath: pidFilePath, readPidFile: readPidFile, writePidFile: writePidFile,
  removePidFile: removePidFile, isAlive: isAlive, procCmdline: procCmdline,
  procImageName: procImageName, isPortFree: isPortFree, killPid: killPid,
  waitPortFree: waitPortFree, replaceStaleInstance: replaceStaleInstance,
  portOwnerPid: portOwnerPid, reclaimOrphanOnPort: reclaimOrphanOnPort,
  installPidCleanup: installPidCleanup, msgOf: msgOf,
};
