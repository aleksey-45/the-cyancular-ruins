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

// ---- ByteWriter / ByteReader ----
(function () {
  var w = new Core.ByteWriter(4);          // 故意给小容量,顺便验扩容
  w.u8(0x12).u16(0x3456).u32(0x789ABCDE).bytes(new Uint8Array([0xAA, 0xBB]));
  var b = w.finish();
  eq(b.length, 1 + 2 + 4 + 2, 'ByteWriter: 长度累计正确');
  eq(Array.prototype.slice.call(b), [0x12, 0x56, 0x34, 0xDE, 0xBC, 0x9A, 0x78, 0xAA, 0xBB],
     'ByteWriter: 小端序');
  var r = new Core.ByteReader(b);
  eq(r.u8(), 0x12, 'ByteReader: u8');
  eq(r.u16(), 0x3456, 'ByteReader: u16');
  eq(r.u32(), 0x789ABCDE, 'ByteReader: u32 高位不为负');
  eq(Array.prototype.slice.call(r.bytes(2)), [0xAA, 0xBB], 'ByteReader: bytes');
  eq(r.remaining(), 0, 'ByteReader: remaining 归零');
  throws(function () { r.u8(); }, 'ByteReader: 越界读抛错');
  throws(function () { new Core.ByteReader(b).bytes(b.length + 1); }, 'ByteReader: bytes 越界抛错');
  throws(function () { new Core.ByteReader(new Uint8Array(0)).u8(); }, 'ByteReader: 空 buffer 读抛错');
})();

// ---- CRC32(IEEE,标准测试向量)----
eq(Core.crc32(new Uint8Array(0)), 0, 'crc32: 空输入为 0');
eq(Core.crc32(new TextEncoder().encode('123456789')), 0xCBF43926, 'crc32: 标准向量 123456789');
eq(Core.crc32(new Uint8Array([0x00])), 0xD202EF8D, 'crc32: 单字节 0x00');

// ---- 纹理层块编解码 ----
(function () {
  var subCols = 8, subRows = 4, n = subCols * subRows;
  var desc = new Uint32Array(n);
  var brick = Core.neutralDesc(3);
  var moss = Core.packDesc(15, 4, 3, 5, 7);
  for (var i = 0; i < n; i++) {
    desc[i] = i < 4 ? 0 : (i < 12 ? brick : moss);
  }
  var enc = Core.encodeTexLayer(desc, subCols, subRows);
  eq(enc[0], Core.KIND_TEX, 'encodeTexLayer: 首字节是 kind');
  var r = new Core.ByteReader(enc);
  var dec = Core.decodeTexLayer(r, subCols, subRows);
  eq(r.remaining(), 0, 'decodeTexLayer: 字节全部消费');
  eq(dec.kind, 'tex', 'decodeTexLayer: kind');
  eq(Array.prototype.slice.call(dec.desc), Array.prototype.slice.call(desc), '纹理层: 往返一致');

  // 空气必须占住调色板第 0 位
  eq(dec.desc[0], 0, '纹理层: 空气回读为 0');

  // 调色板恰好 3 项(空气 + 两种纹理)→ 单字节索引
  var r2 = new Core.ByteReader(enc);
  r2.u8();                       // kind
  eq(r2.u16(), 3, '纹理层: 调色板 3 项');
  eq(r2.u32(), 0, '纹理层: 调色板[0] 是空气');
  eq(r2.u32(), brick, '纹理层: 调色板[1]');
  eq(r2.u32(), moss, '纹理层: 调色板[2]');
  eq(r2.u8(), 1, '纹理层: 调色板 ≤256 项 → index_width = 1');
  eq(enc.length, 1 + 2 + 3 * 4 + 1 + n, '纹理层: 总长度 = 头 + 调色板 + 索引流');

  // 空层:调色板只有空气一项
  var empty = new Uint32Array(16);
  var encEmpty = Core.encodeTexLayer(empty, 4, 4);
  var r3 = new Core.ByteReader(encEmpty);
  r3.u8();
  eq(r3.u16(), 1, '空层: 调色板只有 1 项');
  eq(encEmpty.length, 1 + 2 + 4 + 1 + 16, '空层: 长度');

  // 即使整层没有空气格,索引 0 仍必须是空气
  var full = new Uint32Array(16).fill(brick);
  var rFull = new Core.ByteReader(Core.encodeTexLayer(full, 4, 4));
  rFull.u8();
  eq(rFull.u16(), 2, '满层: 调色板 = 空气 + 砖 = 2 项');
  eq(rFull.u32(), 0, '满层: 索引 0 仍留给空气');
  eq(rFull.u32(), brick, '满层: 索引 1 才是砖');

  // 尺寸校验
  throws(function () { Core.encodeTexLayer(new Uint32Array(5), 4, 4); }, 'encodeTexLayer: 长度不符报错');
  // 越界索引要抛错而不是静默
  var bad = new Uint8Array([Core.KIND_TEX, 1, 0, 0, 0, 0, 0, 1, 99]);   // 调色板 1 项,索引 99
  throws(function () { Core.decodeTexLayer(new Core.ByteReader(bad), 1, 1); }, 'decodeTexLayer: 索引越界报错');
  throws(function () { Core.decodeTexLayer(new Core.ByteReader(new Uint8Array([9])), 1, 1); }, 'decodeTexLayer: 错 kind 报错');
})();

// ---- 背景层块编解码 ----
(function () {
  var subCols = 4, subRows = 2, n = subCols * subRows;
  var rgba = new Uint32Array(n);
  for (var i = 0; i < n; i++) rgba[i] = (0x11223344 + i * 0x01010101) >>> 0;
  var enc = Core.encodeColorLayer(rgba, subCols, subRows);
  eq(enc[0], Core.KIND_COLOR, 'encodeColorLayer: 首字节是 kind');
  eq(enc.length, 1 + n * 4, 'encodeColorLayer: 长度 = 1 + n×4');
  var r = new Core.ByteReader(enc);
  var dec = Core.decodeColorLayer(r, subCols, subRows);
  eq(r.remaining(), 0, 'decodeColorLayer: 字节全部消费');
  eq(dec.kind, 'color', 'decodeColorLayer: kind');
  eq(Array.prototype.slice.call(dec.rgba), Array.prototype.slice.call(rgba), '背景层: 往返一致');

  // 全透明黑(0)是合法且最常见的空背景
  var blank = new Uint32Array(4);
  var r2 = new Core.ByteReader(Core.encodeColorLayer(blank, 2, 2));
  eq(Array.prototype.slice.call(Core.decodeColorLayer(r2, 2, 2).rgba), [0, 0, 0, 0], '背景层: 全 0 往返');
  eq(Core.decodeColorLayer(new Core.ByteReader(Core.encodeColorLayer(blank, 2, 2)), 2, 2).rgba instanceof Uint32Array,
     true, '背景层: 回读是 Uint32Array');

  throws(function () { Core.encodeColorLayer(new Uint32Array(3), 2, 2); }, 'encodeColorLayer: 长度不符报错');
  throws(function () {
    Core.decodeColorLayer(new Core.ByteReader(new Uint8Array([Core.KIND_TEX])), 1, 1);
  }, 'decodeColorLayer: 错 kind 报错');
})();

// ---- meta 文本 ----
(function () {
  var m = Core.createMap('demo', 4, 4);
  m.comments = ['demo', '这是一张测试图'];
  m.players = [{ x: 3, y: 4 }, { x: 10, y: 4 }];
  m.enemies = [{ type: 'fly_bird', x: 20, y: 12 }];
  var text = Core.buildMeta(m);
  eq(text, '# demo\n# 这是一张测试图\n# player 3 4\n# player2 10 4\n# enemy fly_bird 20 12\n',
     'buildMeta: 注释在前,再 spawn');

  var back = Core.parseMeta(text);
  eq(back.comments, ['demo', '这是一张测试图'], 'parseMeta: 注释回读');
  eq(back.players, [{ x: 3, y: 4 }, { x: 10, y: 4 }], 'parseMeta: 多个出生点回读');
  eq(back.enemies, [{ type: 'fly_bird', x: 20, y: 12 }], 'parseMeta: 敌人回读');

  // 第 3 个及以后的出生点必须原样保留(游戏侧读不到,但编辑器不许丢)
  var m3 = Core.createMap('t', 4, 4);
  m3.players = [{ x: 1, y: 1 }, { x: 2, y: 2 }, { x: 3, y: 3 }];
  eq(Core.parseMeta(Core.buildMeta(m3)).players.length, 3, 'parseMeta: 第 3 个出生点不丢');

  // 空 meta
  eq(Core.buildMeta(Core.createMap('t', 2, 2)), '', 'buildMeta: 什么都沒有时是空串');
  eq(Core.parseMeta(''), { players: [], enemies: [], comments: [] }, 'parseMeta: 空串');

  // 非法 spawn 行降级成注释,不丢信息也不崩
  var bad = Core.parseMeta('# player abc 4\n# enemy\n');
  eq(bad.players, [], 'parseMeta: 非法 player 不当出生点');
  eq(bad.comments, ['player abc 4', 'enemy'], 'parseMeta: 非法 spawn 行降级为注释');

  // 普通注释里出现 player 字样不该被误认(缺坐标)
  eq(Core.parseMeta('# player 是主角\n').comments, ['player 是主角'], 'parseMeta: player 注释不被误认');

  // CRLF 要能吃
  eq(Core.parseMeta('# demo\r\n# player 1 2\r\n').players, [{ x: 1, y: 2 }], 'parseMeta: CRLF');

  // ★ parseInt 的前缀截断必须走降级路径,不能把原文吃掉
  eq(Core.parseMeta('# player 3.5 4\n').comments, ['player 3.5 4'], 'parseMeta: 小数坐标整行降级为注释');
  eq(Core.parseMeta('# player 3.5 4\n').players, [], 'parseMeta: 小数坐标不产生出生点');
  eq(Core.parseMeta('# player 7abc 4\n').comments, ['player 7abc 4'], 'parseMeta: 带后缀坐标整行降级');
  eq(Core.parseMeta('# player 1e3 4\n').comments, ['player 1e3 4'], 'parseMeta: 科学计数法坐标整行降级');
  eq(Core.parseMeta('# enemy fly_bird 3.5 4\n').comments, ['enemy fly_bird 3.5 4'], 'parseMeta: 敌人坐标同理');
  eq(Core.parseMeta('# enemy fly_bird 20 12\n').enemies, [{ type: 'fly_bird', x: 20, y: 12 }], 'parseMeta: 正常敌人行不受影响');
  eq(Core.parseMeta('# player -5 4\n').players, [{ x: -5, y: 4 }], 'parseMeta: 负号仍按整数接受(越界由 validateMap 管)');

  // round-trip:buildMeta → parseMeta → buildMeta 稳定
  var t1 = Core.buildMeta(m);
  var m2 = Core.createMap('x', 4, 4);
  var pm = Core.parseMeta(t1);
  m2.comments = pm.comments; m2.players = pm.players; m2.enemies = pm.enemies;
  eq(Core.buildMeta(m2), t1, 'meta: build→parse→build 稳定');
})();

// ==== 断言区结束 ====

console.log('');
console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
if (fail === 0) console.log('SMOKE OK');
process.exit(fail === 0 ? 0 : 1);

})();
