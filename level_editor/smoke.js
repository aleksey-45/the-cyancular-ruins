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

// ---- 图层常量与地图对象 ----
ok(Core.LAYER_COUNT === 4, 'LAYER_COUNT === 4');
eq(Core.LAYER_NAMES, ['前景', '场景', '后景', '背景'], 'LAYER_NAMES 顺序:前/场/后/背景');
eq(Core.LAYER_KINDS, ['tex', 'tex', 'tex', 'color'], 'LAYER_KINDS:背景层是颜色层');
ok(Core.LAYER_FRONT === 0 && Core.LAYER_SCENE === 1 && Core.LAYER_BACK === 2 && Core.LAYER_BG === 3,
   '图层索引常量');

var m = Core.createMap('demo', 125, 75);
eq(m.subCols, 500, 'createMap: subCols = 格数×4');
eq(m.subRows, 300, 'createMap: subRows = 格数×4');
eq(m.layers.length, 4, 'createMap: 四个图层');
eq(m.layers.map(function (L) { return L.kind; }), ['tex', 'tex', 'tex', 'color'], 'createMap: 图层种类');
ok(m.layers[0].desc instanceof Uint32Array, 'createMap: 前景层是 Uint32Array');
eq(m.layers[0].desc.length, 500 * 300, 'createMap: 前景层长度 = subCols×subRows');
ok(m.layers[3].rgba instanceof Uint32Array, 'createMap: 背景层是 rgba 数组');
eq(m.layers[3].rgba.length, 500 * 300, 'createMap: 背景层长度');
eq(m.players, [], 'createMap: players 初始为空数组');
eq(m.enemies, [], 'createMap: enemies 初始为空数组');
eq(m.comments, [], 'createMap: comments 初始为空数组');
eq(Core.cellsWOf(m), 125, 'cellsWOf');
eq(Core.cellsHOf(m), 75, 'cellsHOf');

eq(Core.subIndex(500, 3, 2), 2 * 500 + 3, 'subIndex: 行主序 y*subCols+x');
eq(Core.subIndex(500, 0, 0), 0, 'subIndex: 原点');

throws(function () { Core.createMap('bad', 1.5, 10); }, 'createMap: 非整数格数报错');
throws(function () { Core.createMap('bad', 0, 10); }, 'createMap: 零宽报错');

// ---- 从旧编辑器沿用、与格式无关的纯函数 ----
eq(Core.sanitizeName('My Tower #1'), 'My_Tower_1', 'sanitizeName: 非法字符被清理');
eq(Core.sanitizeName('   spaced   name  '), 'spaced_name', 'sanitizeName: 空格合并为下划线');
eq(Core.sanitizeName('---'), 'structure', 'sanitizeName: 全非法回落默认名');
eq(Core.sanitizeName(''), 'structure', 'sanitizeName: 空名回落');
eq(Core.sanitizeName('塔楼 #1'), '塔楼_1', 'sanitizeName: 保留中文');

eq(Core.brushOffsets(1), { lo: 0, hi: 0 }, 'brushOffsets: 1 → 1×1');
eq(Core.brushOffsets(2), { lo: 0, hi: 1 }, 'brushOffsets: 2 → 2×2(偏下右)');
eq(Core.brushOffsets(3), { lo: 1, hi: 1 }, 'brushOffsets: 3 → 3×3');
eq(Core.brushOffsets(4), { lo: 1, hi: 2 }, 'brushOffsets: 4 → 4×4(偏下右)');
ok((function () {
  for (var s = 1; s <= 15; s++) {
    var o = Core.brushOffsets(s);
    if (!o || o.lo + o.hi + 1 !== s || o.lo < 0 || o.hi < o.lo) return false;
  }
  return true;
})(), 'brushOffsets: 1..15 全部满足 lo+1+hi===尺寸 且 lo≤hi');

eq(Core.lineCells(0, 0, 4, 0), [[0,0],[1,0],[2,0],[3,0],[4,0]], 'lineCells: 水平线');
eq(Core.lineCells(2, 2, 2, 5), [[2,2],[2,3],[2,4],[2,5]], 'lineCells: 垂直线');
eq(Core.lineCells(0, 0, 2, 2), [[0,0],[1,1],[2,2]], 'lineCells: 对角线');
eq(Core.lineCells(4, 0, 0, 0), [[4,0],[3,0],[2,0],[1,0],[0,0]], 'lineCells: 反向水平');
eq(Core.lineCells(1, 1, 1, 1), [[1,1]], 'lineCells: 单点');
eq(Core.lineCells(0, 0, 4, 2), [[0,0],[1,0],[2,1],[3,1],[4,2]], 'lineCells: 缓坡 Bresenham 锚定');

eq(Core.normRegion(3, 2, 1, 5), { x: 1, y: 2, w: 3, h: 4 }, 'normRegion: 反向角归一化');
eq(Core.normRegion(1, 1, 1, 1), { x: 1, y: 1, w: 1, h: 1 }, 'normRegion: 单格');

// ==== 断言区结束 ====

console.log('');
console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
if (fail === 0) console.log('SMOKE OK');
process.exit(fail === 0 ? 0 : 1);

})();
