'use strict';
// tests/format/10_desc_and_bytes.js —— 描述符位域、地图对象与图层常量、与格式无关的纯函数、
// 小端字节读写器与 CRC32、尺寸钳制。
const Core = globalThis.Core;

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

throws(function () { Core.createMap('bad', 1.5, 10); }, 'createMap: 非整数格数报错', '格数必须是正整数');
throws(function () { Core.createMap('bad', 0, 10); }, 'createMap: 零宽报错', '格数必须是正整数');

// ---- 从旧编辑器沿用、与格式无关的纯函数 ----
tableEq('sanitizeName:非法字符清理 / 空格合并 / 全非法回落默认名', [
  ['非法字符被清理', Core.sanitizeName('My Tower #1'), 'My_Tower_1'],
  ['空格合并为下划线', Core.sanitizeName('   spaced   name  '), 'spaced_name'],
  ['全非法回落默认名', Core.sanitizeName('---'), 'structure'],
  ['空名回落', Core.sanitizeName(''), 'structure'],
  ['保留中文', Core.sanitizeName('塔楼 #1'), '塔楼_1'],
]);

tableEq('brushOffsets:边长 → 居中偏移(偏下右)', [
  ['1 → 1×1', Core.brushOffsets(1), { lo: 0, hi: 0 }],
  ['2 → 2×2', Core.brushOffsets(2), { lo: 0, hi: 1 }],
  ['3 → 3×3', Core.brushOffsets(3), { lo: 1, hi: 1 }],
  ['4 → 4×4', Core.brushOffsets(4), { lo: 1, hi: 2 }],
]);
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
  // ★ 全 0xFF 那组字节钉住 u32 回绕:少了 >>> 0 时 (0xFF<<24) 是 -16777216,读出来会是 -1 而不是 4294967295(0x789ABCDE 的 bit31 是 0,钉不住)。
  eq(new Core.ByteReader(new Uint8Array([0xFF, 0xFF, 0xFF, 0xFF])).u32(), 4294967295,
     'ByteReader: u32 读 [FF FF FF FF] → 4294967295(bit31 置位仍是无符号)');
  eq(new Core.ByteReader(new Uint8Array([0x00, 0x00, 0x00, 0x80])).u32(), 2147483648,
     'ByteReader: u32 读 [00 00 00 80] → 2147483648(高位单 bit 也不是负数)');
  eq(Array.prototype.slice.call(r.bytes(2)), [0xAA, 0xBB], 'ByteReader: bytes');
  eq(r.remaining(), 0, 'ByteReader: remaining 归零');
  // ByteReader 三处越界共用同一条错误信息,故期望子串相同 —— 它仍是本类错误独有的(不含通用词)。
  throws(function () { r.u8(); }, 'ByteReader: 越界读抛错', '越界读');
  throws(function () { new Core.ByteReader(b).bytes(b.length + 1); }, 'ByteReader: bytes 越界抛错', '越界读');
  throws(function () { new Core.ByteReader(new Uint8Array(0)).u8(); }, 'ByteReader: 空 buffer 读抛错', '越界读');
})();

// ---- CRC32(IEEE,标准测试向量)----
tableEq('crc32:IEEE 标准测试向量', [
  ['空输入为 0', Core.crc32(new Uint8Array(0)), 0],
  ['标准向量 `123456789`', Core.crc32(new TextEncoder().encode('123456789')), 0xCBF43926],
  ['单字节 0x00', Core.crc32(new Uint8Array([0x00])), 0xD202EF8D],
]);

// ---- 尺寸钳制(旧 clampMin 的第三参是"默认值"而不是上限,输 99999 直接卡死)----
eq(Core.MAX_CELLS_W, 400, 'MAX_CELLS_W');
eq(Core.MAX_CELLS_H, 300, 'MAX_CELLS_H');
tableEq('clampMapSize:正常值原样 / 超上限钳 / 下限 1 / 非数字回落默认', [
  ['正常值原样', Core.clampMapSize(125, 75), { w: 125, h: 75 }],
  ['超上限被钳', Core.clampMapSize(99999, 99999), { w: 400, h: 300 }],
  ['下限 1', Core.clampMapSize(0, -5), { w: 1, h: 1 }],
  ['非数字回落默认', Core.clampMapSize(NaN, 'x'), { w: 125, h: 75 }],
]);
