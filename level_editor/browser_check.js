// browser_check.js —— 在**真 Chrome** 里跑编辑器页面的「自检」,并把逐条结论打印出来。
// 为什么需要它:编辑器是浏览器产物 —— node 侧 6 套冒烟全绿也证明不了"页面能 boot/能画/能存"
// (拆分期间就出过"渲染分片一个语法错误 ⇒ 页面白屏而单看某套绿"的形态)。这是那一半的自动化判据。
// ★ 为什么不用 `chrome --dump-dom`:它在本页 `load` 那一刻就导出 DOM,而 boot 的链
//   (草稿盘 IndexedDB → 图集 → 库 → 打开图)全在那之后;`--virtual-time-budget` 又会让
//   IndexedDB 的回调永远不来(实测:自检报"草稿盘没开",而真实时序下它是好的)。
//   所以走 CDP:轮询到 boot 真走完(调色板有格子 + 渲染器挂上)再求值。
// 用法:
//   node level_editor/browser_check.js                                   # 跑 dist 单文件版(file://)
//   node level_editor/browser_check.js http://127.0.0.1:8777/            # 跑 serve.bat 起的那个
//   CHROME=/path/to/chrome node level_editor/browser_check.js <url>      # 指浏览器
// 判据:文本 `SELFTEST OK` + **条数闸**(≥ EXPECTED_CHECKS 条)+ 退出码 0(自检由真点按钮触发)。
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const DIR = __dirname;
const CHROME_CANDIDATES = [
  process.env.CHROME,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
].filter(Boolean);

function findChrome() {
  for (const c of CHROME_CANDIDATES) {
    try { if (fs.existsSync(c)) return c; } catch (e) { /* 继续找 */ }
  }
  return null;
}

function toFileUrl(p) {
  return 'file:///' + path.resolve(p).replace(/\\/g, '/');
}

const argUrl = process.argv[2];
const distPath = path.join(DIR, 'dist', 'cyrm-editor.html');
const url = argUrl || (fs.existsSync(distPath) ? toFileUrl(distPath) : null);
if (!url) {
  console.error('找不到 ' + distPath + ' —— 先跑 `node build_dist.js` 产出单文件版,或直接给一个 URL。');
  process.exit(2);
}
const chrome = findChrome();
if (!chrome) {
  console.error('找不到 Chrome/Edge。设 CHROME=<可执行文件路径> 再跑。');
  process.exit(2);
}

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'cyrm-browser-'));
const child = spawn(chrome, [
  '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
  '--remote-debugging-pipe', '--user-data-dir=' + profile, 'about:blank',
], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });

const toBrowser = child.stdio[3];
const fromBrowser = child.stdio[4];
let buf = '';
const pending = new Map();
let seq = 1;
fromBrowser.on('data', function (chunk) {
  buf += chunk.toString('utf8');
  let i;
  while ((i = buf.indexOf('\0')) >= 0) {
    const raw = buf.slice(0, i);
    buf = buf.slice(i + 1);
    let msg;
    try { msg = JSON.parse(raw); } catch (e) { continue; }
    const p = msg.id && pending.get(msg.id);
    if (!p) continue;
    pending.delete(msg.id);
    msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result);
  }
});
function send(method, params, sessionId) {
  const id = seq++;
  const msg = { id: id, method: method, params: params || {} };
  if (sessionId) msg.sessionId = sessionId;
  toBrowser.write(JSON.stringify(msg) + '\0');
  return new Promise(function (resolve, reject) { pending.set(id, { resolve: resolve, reject: reject }); });
}
function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

function cleanup(code) {
  try { child.kill(); } catch (e) { /* 已经退了 */ }
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch (e) { /* Windows 上偶尔占用 */ }
  process.exit(code);
}

// boot 真的走完的判据:调色板建出来了(它在 loadAtlas 之后)+ 渲染器挂上了。
// 只等 document.readyState/Editor 会跑在 boot 的异步链前面,自检会报"草稿盘没开/没地图"这类假红。
const READY_EXPR = 'document.readyState === "complete" && !!window.Editor && !!Editor.app && ' +
                   '!!Editor.app.r && document.querySelectorAll("#palette .sw").length > 0';
// ★★ 真**点一下**「自检」按钮,而不是直接调 Editor.selfTest():接线是 `if (btn) addEventListener(...)`,
//    直接调会绕过"id 打错 / 漏接 ⇒ 按钮静默失效"那条路(`#btn-fit` 是同一个静默守卫,一并要求它存在)。
//    判据取**状态栏**(成功写 SELFTEST…,失败由 guard 写错误)⇒"点了没反应"与"自检自己失败"都红。
const CLICK_EXPR =
  '(function(){' +
  'var logs=[];var o=console.log;console.log=function(){logs.push(Array.prototype.map.call(arguments,String).join(" "));};' +
  'function done(v){console.log=o;return String(v)+"\\n"+logs.join("\\n");}' +
  'var a=document.getElementById("btn-selftest"),b=document.getElementById("btn-fit"),s=document.getElementById("status-msg");' +
  'if(!a||!b||!s)return done("MISSING:"+(!a?"btn-selftest ":"")+(!b?"btn-fit ":"")+(!s?"status-msg":""));' +
  's.textContent="";a.click();' +
  'return new Promise(function(res){var n=0;var t=setInterval(function(){' +
  'if(s.textContent!==""){clearInterval(t);res(done(s.textContent));}' +
  'else if(++n>300){clearInterval(t);res(done("CLICK 超时:状态栏 15 秒一直是空的 —— 按钮没接线?"));}},50);});' +
  '})()';
// ★★ 条数闸:`SELFTEST OK` 只证明"没有任何失败输出",不证明每条检查都跑过。17 = ui/96_selftest.js
//    里 `check(` 的调用条数 —— 加/删一条检查要同步改这里(改不动会假红,那正是它该做的事)。
const EXPECTED_CHECKS = 17;

(async function main() {
  const t = await send('Target.createTarget', { url: 'about:blank' });
  const a = await send('Target.attachToTarget', { targetId: t.targetId, flatten: true });
  const sid = a.sessionId;
  await send('Runtime.enable', {}, sid);
  await send('Page.navigate', { url: url }, sid);
  const t0 = Date.now();
  let ready = false;
  while (Date.now() - t0 < 30000) {
    const r = await send('Runtime.evaluate', { expression: READY_EXPR, returnByValue: true }, sid);
    if (r.result && r.result.value === true) { ready = true; break; }
    await sleep(250);
  }
  if (!ready) {
    const why = await send('Runtime.evaluate', {
      expression: '({url:location.href, ready:document.readyState, editor:typeof window.Editor,' +
                  ' boot:document.getElementById("status-msg")?document.getElementById("status-msg").textContent:"",' +
                  ' err:document.getElementById("boot-error")?document.getElementById("boot-error").textContent:""})',
      returnByValue: true,
    }, sid);
    console.error('页面 30 秒内没 boot 完:' + JSON.stringify(why.result && why.result.value));
    cleanup(1);
  }
  await sleep(1200);                       // 让 boot 尾部的崩溃/草稿检查也走完
  const out = await send('Runtime.evaluate', { expression: CLICK_EXPR, awaitPromise: true, returnByValue: true }, sid);
  const text = out.result && out.result.value !== undefined ? String(out.result.value) : JSON.stringify(out);
  console.log(text);
  const m = /共 (\d+) 条检查/.exec(text);
  const checks = m ? Number(m[1]) : 0;
  const saidOk = text.indexOf('SELFTEST OK') >= 0;
  if (saidOk && checks < EXPECTED_CHECKS) {
    console.error('自检只报了 ' + checks + ' 条(条数闸 ' + EXPECTED_CHECKS + ') ⇒ SELFTEST OK 不算数');
  }
  const pass = saidOk && checks >= EXPECTED_CHECKS;
  console.log(pass ? 'BROWSER CHECK OK(' + checks + ' 条 · ' + url + ')' : 'BROWSER CHECK FAIL(' + url + ')');
  cleanup(pass ? 0 : 1);
})().catch(function (e) {
  console.error('CDP 失败:' + (e && e.message ? e.message : e));
  cleanup(1);
});
