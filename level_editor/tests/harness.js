// tests/harness.js —— 6 个 node 冒烟的公共底座(断言助手 + 计数 + 判词)。
// ★ 助手装在 globalThis 上:分片是各自独立的 CJS 模块,裸 `ok(...)` 沿作用域链落到
//   全局,于是从原单文件里逐字搬出来的相位体一个字都不用改。
// ★ 判词由 finish() 打:先 `结果: N 通过, M 失败`,再打该套件的判词行(见文档里的判据)。
'use strict';

let pass = 0;
let fail = 0;

function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function sameBytes(actual, expected, msg) {
  const a = Array.prototype.slice.call(actual);
  const e = Array.prototype.slice.call(expected);
  if (a.length !== e.length) {
    fail++; console.error('  FAIL - ' + msg + ' (长度 ' + a.length + ' ≠ 期望 ' + e.length + ')');
    return;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== e[i]) {
      fail++; console.error('  FAIL - ' + msg + ' (第 ' + i + ' 字节 ' + a[i] + ' ≠ ' + e[i] + ')');
      return;
    }
  }
  pass++; console.log('  ok  - ' + msg);
}
// 反向断言必须断言「错在哪」:只判"抛了没有"是假绿(拼错名字抛的 TypeError 一样算过)。
function errText(e) {
  let msg = (e && e.message !== undefined) ? String(e.message) : String(e);
  if (msg === '' && e && e.cause && e.cause.message) msg = String(e.cause.message);
  return msg;
}
// ★★ D9 的收口工具:一张表 = **一条**守卫。逐值断言("一个键一条 / 一个数值一条")会让改一次表
//    就要动 N 行,而纯数组比又会丢掉"哪一行错" —— 它两头都要:一条 assertion,失败时**点名首个**不匹配。
//    行 = [标签, 实得, 期望];标签会被原样打进失败信息里(所以别写空标签)。
function tableEq(msg, rows) {
  for (let i = 0; i < rows.length; i++) {
    const label = rows[i][0], got = rows[i][1], want = rows[i][2];
    if (JSON.stringify(got) !== JSON.stringify(want)) {
      fail++;
      console.error('  FAIL - ' + msg + '(第 ' + (i + 1) + ' 行:' + label + ')\n        got: ' +
        JSON.stringify(got) + '\n        exp: ' + JSON.stringify(want));
      return;
    }
  }
  pass++;
  console.log('  ok  - ' + msg + '(' + rows.length + ' 行)');
}
function throws(fn, msg, expectSub) {
  let e = null;
  try { fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && errText(e).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + errText(e));
    return;
  }
  pass++; console.log('  ok  - ' + msg);
}
async function rejects(fn, msg, expectSub) {
  let e = null;
  try { await fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未拒绝)'); return; }
  if (expectSub !== undefined && errText(e).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (拒绝原因里没有 "' + expectSub + '")\n        got: ' + errText(e));
    return;
  }
  pass++; console.log('  ok  - ' + msg);
}

function start() {
  pass = 0; fail = 0;
  globalThis.ok = ok;
  globalThis.eq = eq;
  globalThis.tableEq = tableEq;
  globalThis.sameBytes = sameBytes;
  globalThis.errText = errText;
  globalThis.throws = throws;
  globalThis.rejects = rejects;
  Object.defineProperty(globalThis, 'pass', { get: () => pass, configurable: true });
  Object.defineProperty(globalThis, 'fail', { get: () => fail, configurable: true });
  return module.exports;
}
function counts() { return { pass, fail }; }
// ★★ 第二参 = **条数闸**(实测过的条数)。`pass+fail===0` 只挡"一条都没跑";**掉一整个分片照绿**
//    (实测:把某一个分片从入口的 require 列表里注释掉 ⇒ 275 通过 / 0 失败,判词照打 OK)。
//    判据取 `>=` 而不是 `==`:多出来的断言不该红,少了必须红。加/删断言要同步改入口里那个数。
function finish(verdict, minChecks) {
  console.log('\n结果: ' + pass + ' 通过, ' + fail + ' 失败');
  // ★★ 0 条断言 = 假绿:判词只证明"没有任何失败输出",而分片根本没跑起来时也是这个输出
  //    (拆分期间真出现过:入口 require 了一堆工厂函数,断言一条没执行,却照打 SMOKE OK)。
  if (pass + fail === 0) {
    console.log('FAIL: 0 条断言 —— 判词不算数(分片是不是没跑起来?)');
    process.exit(1);
  }
  if (minChecks && pass + fail < minChecks) {
    console.log('FAIL: 只跑了 ' + (pass + fail) + ' 条断言(条数闸 ' + minChecks +
                ') —— 有分片没跑?被注释掉了?');
    process.exit(1);
  }
  if (fail === 0) { console.log(verdict); process.exit(0); }
  console.log('FAIL: ' + fail + ' 条');
  process.exit(1);
}

module.exports = { start, counts, finish, ok, eq, tableEq, sameBytes, errText, throws, rejects };
