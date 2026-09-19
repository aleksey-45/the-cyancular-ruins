'use strict';

// Node smoke test —— `.cyrm` v4 格式核心层(level_editor/core.js)。
// 直接读 core.js 并求值,不依赖浏览器、不依赖 structure-editor.html。
//
// Run: node smoke.js

const fs = require('fs');
const path = require('path');

const corePath = path.join(__dirname, 'core.js');
if (!fs.existsSync(corePath)) {
  console.error('FAIL: 找不到 ' + corePath);
  process.exit(1);
}
const coreSrc = fs.readFileSync(corePath, 'utf8');
try {
  new Function(coreSrc)();
} catch (err) {
  console.error('core.js 执行失败（可能是语法错误）:', err.message);
  process.exit(1);
}
const Core = globalThis.Core;
if (!Core) {
  console.error('FAIL: core.js 没有导出 globalThis.Core');
  process.exit(1);
}

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
function throws(fn, msg) {
  let threw = false;
  try { fn(); } catch (e) { threw = true; }
  if (threw) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); }
}
// 异步版的 throws —— decodeMap 是 async,「坏文件必须抛错」那批断言要用它。
async function rejects(fn, msg) {
  try { await fn(); fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); }
  catch (e) { pass++; console.log('  ok  - ' + msg); }
}

(async function main() {

// ==== 断言区 ====

// ---- descriptor 位域 ----
ok(Core.SUB_PER_CELL === 4, 'SUB_PER_CELL === 4');
ok(Core.DESC_AIR === 0, 'DESC_AIR === 0');
eq(Core.packDesc(0, 0, 0, 0, 0), 0, 'packDesc: 纹理 0 恒为空气');
eq(Core.packDesc(0, 7, 7, 7, 7), 0, 'packDesc: 空气忽略辅码');
ok(Core.packDesc(1, 4, 4, 4, 7) !== 0, 'packDesc: 纹理 1 中性描述符非 0');

var d1 = Core.packDesc(5, 4, 3, 2, 7);
eq(Core.texOf(d1), 5, 'descriptor: 纹理回读');
eq(Core.hueOf(d1), 4, 'descriptor: 色相回读');
eq(Core.brightOf(d1), 3, 'descriptor: 亮度回读');
eq(Core.satOf(d1), 2, 'descriptor: 饱和度回读');
eq(Core.alphaOf(d1), 7, 'descriptor: 透明度回读');

var all = Core.packDesc(4095, 7, 7, 7, 7);
eq(Core.texOf(all), 4095, 'descriptor: 纹理上界 4095');
eq(Core.hueOf(all) + Core.brightOf(all) + Core.satOf(all) + Core.alphaOf(all), 28, 'descriptor: 四个辅码全 7');
eq(Core.packDesc(4096, 4, 4, 4, 7), 0, 'descriptor: 纹理 4096 溢出为空气');
eq(Core.packDesc(-1, 4, 4, 4, 7), 0, 'descriptor: 负纹理为空气');

var n9 = Core.neutralDesc(9);
ok(Core.texOf(n9) === 9 && Core.hueOf(n9) === 4 && Core.brightOf(n9) === 4 &&
   Core.satOf(n9) === 4 && Core.alphaOf(n9) === 7, 'neutralDesc: (4,4,4,7) 且保留纹理');
ok(Core.isAir(0) && !Core.isAir(n9), 'isAir: 只对 0 为真');

// ==== 断言区结束 ====

console.log('');
console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
if (fail === 0) console.log('SMOKE OK');
process.exit(fail === 0 ? 0 : 1);

})();
