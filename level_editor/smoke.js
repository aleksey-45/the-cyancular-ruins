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
// ★ 反向断言必须断言「错在哪」,不能只断言「抛了」—— 只判「有没有抛」是假绿:
//   Core.decodeMap 若因拼写错误根本不存在,抛出来的 TypeError 一样算通过。
//   故 expectSub 是可选但强烈建议的期望子串;给了就必须出现在异常文本里。
// ★ 为什么还要看 e.cause:Node 的 DecompressionStream 在 zlib 的 Adler-32 尾损坏时,
//   抛的是一个 **message 为空字符串**的 TypeError,真实原因只在 e.cause.message 里
//   (实测 "incorrect data check")。只看 e.message 的话那条断言永远取不到错因,
//   就退化成「任何异常都算过」的假绿。
// ★ e.cause 是 **非标准扩展**(浏览器里可能没有),故写成「有则用、无则退回空串」,
//   绝不能让它成为硬依赖。
function errText(e) {
  var msg = (e && e.message !== undefined) ? String(e.message) : String(e);
  if (msg === '' && e && e.cause && e.cause.message) msg = String(e.cause.message);
  return msg;
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
// 异步版的 throws —— decodeMap 是 async,「坏文件必须抛错」那批断言要用它。
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
// 逐字节比对,失败时报**第一个不同的下标** —— 整文件 golden 向量要用它,
// 用 eq(JSON) 时一条差字节会打出 181 个数字的 got/exp,读不出是哪一位错。
function sameBytes(actual, expected, msg) {
  const a = Array.prototype.slice.call(actual);
  if (a.length !== expected.length) {
    fail++; console.error('  FAIL - ' + msg + ' (长度 ' + a.length + ' ≠ 期望 ' + expected.length + ')');
    return;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== expected[i]) {
      fail++; console.error('  FAIL - ' + msg + ' (第 ' + i + ' 字节: 实得 0x' + a[i].toString(16) +
                            ', 期望 0x' + expected[i].toString(16) + ')');
      return;
    }
  }
  pass++; console.log('  ok  - ' + msg);
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

throws(function () { Core.createMap('bad', 1.5, 10); }, 'createMap: 非整数格数报错', '格数必须是正整数');
throws(function () { Core.createMap('bad', 0, 10); }, 'createMap: 零宽报错', '格数必须是正整数');

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
  // ★ 指令 B6:`>>> 0` 此前没有确定性断言 —— 上面那串 0x789ABCDE 的 bit31 是 0,
  //   把 u32 写成 `|` 拼完不回绕也照样绿。全 0xFF 是唯一能逼出符号位的那组字节:
  //   少了 `>>> 0`,`(0xFF<<24)` 是 -16777216,读出来的会是 -1 而不是 4294967295。
  eq(new Core.ByteReader(new Uint8Array([0xFF, 0xFF, 0xFF, 0xFF])).u32(), 4294967295,
     'ByteReader: u32 读 [FF FF FF FF] → 4294967295(bit31 置位仍是无符号)');
  eq(new Core.ByteReader(new Uint8Array([0x00, 0x00, 0x00, 0x80])).u32(), 2147483648,
     'ByteReader: u32 读 [00 00 00 80] → 2147483648(高位单 bit 也不是负数)');
  eq(Array.prototype.slice.call(r.bytes(2)), [0xAA, 0xBB], 'ByteReader: bytes');
  eq(r.remaining(), 0, 'ByteReader: remaining 归零');
  // ByteReader 的三处越界共用一个错误信息('ByteReader: 越界读(p+n > len)'),
  // 故三处的期望子串相同 —— 它仍是**本类错误独有**的(不含通用词)。
  throws(function () { r.u8(); }, 'ByteReader: 越界读抛错', '越界读');
  throws(function () { new Core.ByteReader(b).bytes(b.length + 1); }, 'ByteReader: bytes 越界抛错', '越界读');
  throws(function () { new Core.ByteReader(new Uint8Array(0)).u8(); }, 'ByteReader: 空 buffer 读抛错', '越界读');
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
  throws(function () { Core.encodeTexLayer(new Uint32Array(5), 4, 4); }, 'encodeTexLayer: 长度不符报错', 'desc 长度');
  // 越界索引要抛错而不是静默
  var bad = new Uint8Array([Core.KIND_TEX, 1, 0, 0, 0, 0, 0, 1, 99]);   // 调色板 1 项,索引 99
  throws(function () { Core.decodeTexLayer(new Core.ByteReader(bad), 1, 1); }, 'decodeTexLayer: 索引越界报错', '越出调色板');
  throws(function () { Core.decodeTexLayer(new Core.ByteReader(new Uint8Array([9])), 1, 1); }, 'decodeTexLayer: 错 kind 报错', 'decodeTexLayer: kind=');
})();

// ---- 双字节索引(index_width = 2)与调色板上界(指令 A2)----
// ★ 为什么单起一块:此前 grep 全仓(断言里)没有任何一处涉及 iw === 2 / 65535 / 65536 ——
//   已覆盖的只有 index_width = 1。于是**双字节编码循环、双字节解码分支、它的
//   `p >= palCount` 错误臂、以及编码器的调色板上界本身统统没有验证**。
//   iw = 2 不是罕见分支:任何描述符种类超过 256 的层都会走它,一张装饰丰富的
//   400×300 地图完全够得着(1,920,000 个子格,而描述符的组合有 90,112 种)。
await (async function () {
  // 第 i 个非空气描述符 —— 给出一个**合法且互不相同**的描述符。
  // texture 取 1..4095 循环,再用 (hue, bright) 区分档:共 4095×64 种 ≫ 65535。
  function distinctDesc(i) {
    var block = (i / 4095) | 0;
    return Core.packDesc(1 + (i % 4095), block & 7, (block >> 3) & 7, 4, 7);
  }
  // ★ 自证 distinctDesc 真的两两不同 —— 否则"300 种不同描述符"是假的,
  //   调色板会缩回 ≤256 项、双字节路径根本不会被触发,而断言照样全绿。
  var PROBE_N = 17 * 4095;                 // 覆盖下界测试用到的全部 (texture, block) 组合
  var probe = new Set();
  for (var q = 0; q < PROBE_N; q++) probe.add(distinctDesc(q));
  eq(probe.size, PROBE_N, 'A2: distinctDesc 在 ' + PROBE_N + ' 个 i 上两两不同(构造前提自证)');
  ok(probe.size > 256, 'A2: 描述符种类确实超过 256(否则走不到双字节索引)');

  // ── ① 300 种描述符 → index_width 必须是 2,往返逐格一致,长度与手算公式相符 ──
  var subCols = 20, subRows = 16, n = subCols * subRows;    // 320 个子格
  eq(n, 320, 'A2: 样本子格数 320(放得下 300 种 + 空气,且余 20 格空气)');
  var desc = new Uint32Array(n);
  for (var i = 0; i < 300; i++) desc[i] = distinctDesc(i);
  var encL = Core.encodeTexLayer(desc, subCols, subRows);

  var r = new Core.ByteReader(encL);
  eq(r.u8(), Core.KIND_TEX, 'A2: 层块首字节 kind');
  eq(r.u16(), 301, 'A2: 调色板 301 项(索引 0 空气 + 300 种)');
  r.bytes(4 * 301);
  eq(r.u8(), 2, 'A2: 调色板 > 256 项 → index_width = 2(此前零覆盖的那条分支)');
  // 长度 = kind(1) + palette_count(2) + 调色板(4×301) + index_width(1) + 索引流(2×n)
  eq(encL.length, 1 + 2 + 4 * 301 + 1 + 2 * n,
     'A2: 总长度与手算公式相符(双字节索引流 ⇒ 2×n,不是 n)');

  var backL = Core.decodeTexLayer(new Core.ByteReader(encL), subCols, subRows);
  eq(Array.prototype.slice.call(backL.desc), Array.prototype.slice.call(desc),
     'A2: 双字节索引往返逐格一致');
  // 逐格比对还不够强(样本里 300 之后的 20 格是空气,而空气的索引是 0):
  // 把 300 种各自点名抽查一遍,区分出"索引整体串位"这类错。
  var allOk = true, badAt = -1;
  for (i = 0; i < 300; i++) if (backL.desc[i] !== distinctDesc(i)) { allOk = false; badAt = i; break; }
  ok(allOk, 'A2: 300 种描述符各自按位置回读正确' + (badAt < 0 ? '' : '(首个失败 i=' + badAt + ')'));
  eq(backL.desc[300], 0, 'A2: 第 301 格是空气(索引 0,没被串到别处)');

  // ── ② 整文件往返也要真的走通 iw = 2 ──
  // 把 300 种放在**前景层**(层 0),且不带任何 meta ⇒ body = metaLen(2,值为 0) + 层0 块,
  // 于是层0 块在文件里的偏移是固定的,可以直接读它的 palette_count / index_width。
  var mPal = Core.createMap('pal', 5, 4);                  // 5×4 格 = 20×16 = 320 子格
  var front = mPal.layers[Core.LAYER_FRONT].desc;
  for (i = 0; i < 300; i++) front[i] = distinctDesc(i);
  eq(Core.buildMeta(mPal), '', 'A2: 样本图无注释/出生点/敌人 ⇒ meta 为空串(下面按固定偏移读层块的前提)');
  var rawPal = await Core.encodeMap(mPal, { compress: false });
  var rr = new Core.ByteReader(rawPal);
  rr.bytes(Core.HEADER_SIZE + 2);                          // 跳过头部与 meta_len(=0)
  eq(rr.u8(), Core.KIND_TEX, 'A2: 整文件:层0 块首字节 kind');
  eq(rr.u16(), 301, 'A2: 整文件:层0 的 palette_count === 301');
  rr.bytes(4 * 301);
  eq(rr.u8(), 2, 'A2: 整文件:层0 的 index_width === 2(双字节路径在整文件里也走通)');

  var compPal = await Core.encodeMap(mPal);                // 默认走 deflate
  var backPal = await Core.decodeMap(compPal);
  eq(Array.prototype.slice.call(backPal.layers[Core.LAYER_FRONT].desc),
     Array.prototype.slice.call(front), 'A2: 整文件往返(压缩路径,300 种描述符 / iw = 2)');

  // ── ③ 调色板上界:恰好 65535 项可以,65536 项必须抛(指令 A1 的边界)──
  // palette_count 是 u16 ⇒ 能表达的最大值是 65535;索引 0 又必须留给空气,
  // 故"装得下的非空气描述符"上限恰好 65534 种。两条都取**恰好**那一格。
  var nOk = 65534;
  var descOk = new Uint32Array(nOk);
  for (i = 0; i < nOk; i++) descOk[i] = distinctDesc(i);
  var encOk = Core.encodeTexLayer(descOk, 2, 32767);       // 2×32767 = 65534
  var rOk = new Core.ByteReader(encOk);
  eq(rOk.u8(), Core.KIND_TEX, 'A2 上界: 65535 项样本的 kind');
  eq(rOk.u16(), 65535, 'A2 上界: 恰好 65535 项调色板可以编码(且没有被截断成 0)');
  rOk.bytes(4 * 65535);
  eq(rOk.u8(), 2, 'A2 上界: 65535 项仍走双字节索引(最大索引 65534 放得进 u16)');
  eq(encOk.length, 1 + 2 + 4 * 65535 + 1 + 2 * nOk, 'A2 上界: 65535 项时总长度与公式相符');
  var backOk = Core.decodeTexLayer(new Core.ByteReader(encOk), 2, 32767);
  eq(backOk.desc[0], distinctDesc(0), 'A2 上界: 65535 项 → 第 0 格回读');
  eq(backOk.desc[nOk - 1], distinctDesc(nOk - 1), 'A2 上界: 65535 项 → 最后一格回读');

  // 65536 项:加入第 65535 个非空气描述符时 pal.length 会到 65536 ⇒ w.u16 按位截断成 0
  // ⇒ 解码端「调色板为空」—— 即"编码器产出自己的解码器拒绝的文件"。必须在 push 之前就拒。
  var nBad = 65535;
  var descBad = new Uint32Array(nBad);
  for (i = 0; i < nBad; i++) descBad[i] = distinctDesc(i);
  throws(function () { Core.encodeTexLayer(descBad, 3, 21845); },   // 3×21845 = 65535
         'A2 上界: 恰好 65536 项调色板必须抛错(A1 的 off-by-one 就差在这一格)',
         '调色板超过 65535 项');
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

  throws(function () { Core.encodeColorLayer(new Uint32Array(3), 2, 2); }, 'encodeColorLayer: 长度不符报错', 'rgba 长度');
  throws(function () {
    Core.decodeColorLayer(new Core.ByteReader(new Uint8Array([Core.KIND_TEX])), 1, 1);
  }, 'decodeColorLayer: 错 kind 报错', 'decodeColorLayer: kind=');
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

// ---- 整文件编解码 ----
await (async function () {
  function mkMap() {
    var m = Core.createMap('demo', 6, 5);
    var brick = Core.neutralDesc(1);
    var moss = Core.packDesc(15, 5, 3, 6, 7);
    var half = Core.packDesc(3, 2, 4, 4, 4);
    for (var i = 0; i < m.layers[0].desc.length; i += 7) m.layers[0].desc[i] = half;      // 前景:稀疏装饰
    for (i = 0; i < m.layers[1].desc.length; i++) {
      m.layers[1].desc[i] = (i % m.subCols < 4) ? brick : 0;                              // 场景:左边一堵墙
    }
    for (i = 0; i < m.layers[2].desc.length; i += 13) m.layers[2].desc[i] = moss;         // 后景:零星
    for (i = 0; i < m.layers[3].rgba.length; i++) {
      m.layers[3].rgba[i] = ((0x102030 | (i & 0xFF)) * 0x010101) >>> 0;                   // 背景:条带
    }
    m.comments = ['demo', '带中文的注释'];
    m.players = [{ x: 3, y: 4 }, { x: 10, y: 4 }];
    m.enemies = [{ type: 'fly_bird', x: 20, y: 12 }];
    return m;
  }

  var src = mkMap();
  var bytes = await Core.encodeMap(src);
  eq(Array.prototype.slice.call(bytes.subarray(0, 4)), [0x43, 0x59, 0x52, 0x4D], 'encodeMap: magic "CYRM"');
  eq(bytes[4], Core.FORMAT_VERSION, 'encodeMap: 版本 4');
  eq(bytes[5], 1, 'encodeMap: 默认压缩');
  eq(bytes.length >= Core.HEADER_SIZE, true, 'encodeMap: 至少有头部');

  var hr = new Core.ByteReader(bytes);
  hr.bytes(6);
  var bodySize = hr.u32(); hr.u32();
  eq(hr.u16(), src.subCols, 'encodeMap: 头部 sub_cols');
  eq(hr.u16(), src.subRows, 'encodeMap: 头部 sub_rows');
  eq(hr.u8(), 0b1111, 'encodeMap: layer_flags 四位全开');
  eq(hr.u8(), 0, 'encodeMap: reserved 为 0');

  var back = await Core.decodeMap(bytes);
  eq(back.subCols, src.subCols, 'decodeMap: subCols');
  eq(back.subRows, src.subRows, 'decodeMap: subRows');
  eq(back.layers.length, 4, 'decodeMap: 四层');
  for (var L = 0; L < 4; L++) {
    var key = L === 3 ? 'rgba' : 'desc';
    eq(Array.prototype.slice.call(back.layers[L][key]), Array.prototype.slice.call(src.layers[L][key]),
       '整文件往返: 图层 ' + L);
  }
  eq(back.players, src.players, '整文件往返: players');
  eq(back.enemies, src.enemies, '整文件往返: enemies');
  eq(back.comments, src.comments, '整文件往返: comments');
  eq(back.layers[3].kind, 'color', '整文件往返: 背景层 kind');
  eq(back.layers[0].kind, 'tex', '整文件往返: 前景层 kind');

  // 不压缩路径
  var raw = await Core.encodeMap(src, { compress: false });
  eq(raw[5], 0, 'encodeMap: compress:false → compression = 0');
  eq(raw.length, Core.HEADER_SIZE + bodySize, 'encodeMap: 不压缩时文件长度 = 20 + body_size');
  var rawBack = await Core.decodeMap(raw);
  eq(Array.prototype.slice.call(rawBack.layers[1].desc), Array.prototype.slice.call(src.layers[1].desc),
     '不压缩路径: 往返一致');
  ok(raw.length > bytes.length, '不压缩确实更大(否则压缩没起作用)');

  // 缺层:置 null 的图层不进文件,解码回 null
  var partial = Core.createMap('p', 4, 4);
  partial.layers[0] = null;
  partial.layers[2] = null;
  var pEnc = await Core.encodeMap(partial, { compress: false });
  var pr = new Core.ByteReader(pEnc); pr.bytes(18);
  eq(pr.u8(), 0b1010, '缺层: layer_flags 只开场景与背景');
  var pBack = await Core.decodeMap(pEnc);
  eq(pBack.layers[0], null, '缺层: 前景回来是 null');
  eq(pBack.layers[2], null, '缺层: 后景回来是 null');
  ok(pBack.layers[1] !== null && pBack.layers[3] !== null, '缺层: 场景与背景仍在');

  // ── 反向断言:损坏的文件必须抛错,不能静默读成一张空图 ──
  // ★ 每条都带期望子串:只判「抛了」的话,decodeMap 拼错名字抛的 TypeError 也会全绿。
  var badMagic = bytes.slice(); badMagic[0] = 0x00;
  await rejects(function () { return Core.decodeMap(badMagic); }, 'decodeMap: 坏 magic 抛错', 'magic');

  var badVer = bytes.slice(); badVer[4] = 99;
  await rejects(function () { return Core.decodeMap(badVer); }, 'decodeMap: 未知版本抛错', '版本');

  // ★ 这一条与 brief 给的字节不同(报告里已点名):brief 是翻压缩流的最后一个字节,
  //   而那是 zlib 的 Adler-32 校验尾 —— Node 的 DecompressionStream 会直接以
  //   「message 为空的 TypeError」拒绝,根本走不到我们自己的 CRC 比对。
  //   于是断言名(CRC 不符)与实际验到的东西(解压流损坏)不是一回事,带上期望子串后当场红。
  //   改成翻**不压缩文件 body 的最后一个字节**:这步没有解压,长度不变(body_size 仍对),
  //   唯一能抓住它的就是 crc32(body) 的比对 —— 这才真的验到「CRC 是算在 body 内容上的」。
  // ★ 指令 B5:期望子串必须**只有它该触发的那个错误**才有。'CRC' 太松 ——
  //   任何含 "CRC" 的运行时错误(如 `ReferenceError: CRC is not defined`)都会命中。
  var badCrc = raw.slice(); badCrc[badCrc.length - 1] ^= 0xFF;
  await rejects(function () { return Core.decodeMap(badCrc); }, 'decodeMap: CRC 不符抛错', 'CRC 不符');

  // 压缩流本身损坏(另一个损坏面):翻的是 zlib 的 Adler-32 校验尾,Node 的
  // DecompressionStream 会以「message 为空的 TypeError」拒绝 —— 错因只在 e.cause.message 里
  // ("incorrect data check")。故这条**能**带期望子串,依据是 errText 的 cause 回退。
  var badStream = bytes.slice(); badStream[badStream.length - 1] ^= 0xFF;
  await rejects(function () { return Core.decodeMap(badStream); },
    'decodeMap: deflate 流损坏抛错(不静默读成空图)', 'incorrect data check');

  var badSize = bytes.slice(); badSize[14] = 0; badSize[15] = 0;     // sub_cols = 0
  await rejects(function () { return Core.decodeMap(badSize); }, 'decodeMap: 尺寸 0 抛错', '尺寸非法');

  var badAlign = bytes.slice(); badAlign[14] = 6; badAlign[15] = 0;  // sub_cols = 6,非 4 倍数
  await rejects(function () { return Core.decodeMap(badAlign); }, 'decodeMap: 尺寸非 4 倍数抛错', '倍数');

  // ★★ 防「损坏的文件头触发巨量分配」:CRC32 只覆盖 body、**不覆盖文件头**,所以
  //   「CRC 有效」根本不代表头是对的 —— 这两个尺寸字段是**未经验证**的输入。
  //   65532 既 > 0 又能被 4 整除,两道既有校验都拦不住;若不按 body 实际大小反推上界,
  //   就会一路走到 decodeTexLayer 的 new Uint32Array(65532×65532) ≈ 17GB。
  //   ★ 期望子串在这里**同时**承担「不是走到分配才炸」的判据:实测本机
  //     new Uint32Array(4294443024) 是**能成功**的(实测 arrayBuffers 涨到 17177.8MB,
  //     即 17.2GB 真的分配出去了),所以去掉这条检查后**也是抛错的** —— 抛的是解码途中的
  //     另一个错误(实测 "decodeTexLayer: 索引 2 越出调色板 2 项",那时内存已经分配完了)。
  //     因此「断言它不是 RangeError」在这台机器上是**空转**的:那条断言在检查被删掉时照样通过。
  //     只有钉住我们自己的错误文本(下面这个子串)才真的验到这条检查在跑。
  var badDims = raw.slice();
  badDims[14] = 0xFC; badDims[15] = 0xFF;      // sub_cols = 65532(>0,且是 4 的倍数)
  badDims[16] = 0xFC; badDims[17] = 0xFF;      // sub_rows = 65532
  await rejects(function () { return Core.decodeMap(badDims); },
    'decodeMap: 头部尺寸被改成 65532×65532 时在分配前拒绝', '最多只够');

  await rejects(function () { return Core.decodeMap(new Uint8Array(10)); }, 'decodeMap: 短于头部抛错', '小于头部');

  // 不压缩但 body_size 与真实长度不符
  var badLen = raw.slice();
  badLen[6] = (bodySize + 1) & 0xFF;
  await rejects(function () { return Core.decodeMap(badLen); }, 'decodeMap: body_size 不符抛错', '头部声明');

  // ★ 指令 B5:同理,'compression' 这个子串**任何一个**未声明标识符的
  //   `ReferenceError: compression is not defined` 都会命中 —— 而那种红是"探针写错了",
  //   不是"这条守卫真的在跑"。钉住完整短语才排得掉这类假绿。
  var badComp = bytes.slice(); badComp[5] = 7;
  await rejects(function () { return Core.decodeMap(badComp); }, 'decodeMap: 未知 compression 抛错', '未知 compression');
})();

// ---- golden 字节向量(1×1 格、compress:false)----
// ★ 为什么需要这一块:上面所有断言都是「同一个 encode/decode 对跑往返」,两端一起
//   把字节序改反(比如 u32 写成大端)整套照样全绿,而产出的文件 Godot 读不了。
//   这里把**完整文件字节**(20 字节头 + 161 字节 body)逐字节钉死。
// ★ 期望序列是照着规格 §3.1/§3.2/§3.3/§3.4 **手推**出来的,不是跑一遍 encodeMap 抄的
//   —— 抄输出只能冻结当前行为,抓不出今天就存在的字节序错。推导见下面每行注释。
// ★ 唯一的例外是头部那 4 个 CRC 字节:CRC32 无法手算,故用一个**独立的按位实现**
//   (下面的 refCrc32,与 core.js 的表驱动实现是两套代码)对手推出来的那 161 字节
//   body 求值 —— 值在下面写死为 0xA9 0x79 0xF5 0x3F,并在同一个断言块里用 refCrc32
//   复核一遍(顺带用标准向量 123456789 → 0xCBF43926 自证 refCrc32 本身是对的)。
await (async function () {
  // 独立按位 CRC32(无查表),只服务于本断言块
  function refCrc32(bytes) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) {
      c ^= bytes[i];
      for (var k = 0; k < 8; k++) c = (c & 1) ? ((c >>> 1) ^ 0xEDB88320) : (c >>> 1);
    }
    return (c ^ 0xFFFFFFFF) >>> 0;
  }
  eq(refCrc32(new TextEncoder().encode('123456789')), 0xCBF43926, 'golden: refCrc32 自证(标准向量)');

  // 手推用的最小地图:1×1 格 = 4×4 子格 = 16 个子格
  //   前景 = 全空气;场景 = 前 8 格 neutralDesc(1)、后 8 格空气;
  //   后景 = 全空气;背景 = 偶 0x11223344 / 奇 0xAABBCCDD
  //   meta = 1 条注释 'hi' + 1 个出生点 (1,2)
  var g = Core.createMap('g', 1, 1);
  g.layers[1].desc.fill(Core.neutralDesc(1));
  for (var i = 8; i < 16; i++) g.layers[1].desc[i] = 0;
  for (i = 0; i < 16; i++) g.layers[3].rgba[i] = (i % 2 === 0) ? 0x11223344 : 0xAABBCCDD;
  g.comments = ['hi'];
  g.players = [{ x: 1, y: 2 }];

  // neutralDesc(1) = packDesc(1,4,4,4,7) = 4 | 4<<3 | 4<<6 | 7<<9 | 1<<12
  //                = 4 + 32 + 256 + 3584 + 4096 = 7972 = 0x00001F24 → 小端字节 24 1F 00 00
  eq(Core.neutralDesc(1), 0x00001F24, 'golden: 手推依据 neutralDesc(1) === 0x00001F24');

  // meta 文本 = "# hi\n# player 1 2\n" 共 18 字节(buildMeta:先注释、再出生点、末尾补 \n)
  eq(Core.buildMeta(g), '# hi\n# player 1 2\n', 'golden: 手推依据 meta 文本');
  var metaBytes = Array.prototype.slice.call(new TextEncoder().encode('# hi\n# player 1 2\n'));
  eq(metaBytes.length, 18, 'golden: 手推依据 meta 长度 18');

  // body 手推:18(meta)+ 24(层0)+ 28(层1)+ 24(层2)+ 65(层3)= 161 = 0xA1
  var expectedBody = [].concat(
    [0x12, 0x00],                       // 20..21  meta_len = 18(u16 小端)
    metaBytes,                          // 22..39  meta UTF-8 原文
    // ── 层0(前景)块:调色板只有空气,16 个索引全 0 → 1+2+4+1+16 = 24 字节 ──
    [0x01],                             // 40      kind = 1(纹理层)
    [0x01, 0x00],                       // 41..42  palette_count = 1
    [0x00, 0x00, 0x00, 0x00],           // 43..46  palette[0] = 描述符 0(空气)
    [0x01],                             // 47      index_width = 1(palette_count ≤ 256)
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],  // 48..63  16 个子格索引全 0
    // ── 层1(场景)块:palette = [空气, 0x1F24] → 1+2+8+1+16 = 28 字节 ──
    [0x01],                             // 64      kind = 1
    [0x02, 0x00],                       // 65..66  palette_count = 2
    [0x00, 0x00, 0x00, 0x00],           // 67..70  palette[0] = 空气
    [0x24, 0x1F, 0x00, 0x00],           // 71..74  palette[1] = 0x00001F24(小端!)
    [0x01],                             // 75      index_width = 1
    [0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],  // 76..91  前 8 格索引 1、后 8 格 0
    // ── 层2(后景)块:与层0 同(全空气)→ 24 字节 ──
    [0x01],                             // 92      kind = 1
    [0x01, 0x00],                       // 93..94  palette_count = 1
    [0x00, 0x00, 0x00, 0x00],           // 95..98  palette[0] = 空气
    [0x01],                             // 99      index_width = 1
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],  // 100..115
    // ── 层3(背景)块:无调色板,16 格 × RGBA8888 → 1+64 = 65 字节 ──
    [0x02],                             // 116     kind = 2(背景层)
    [0x44, 0x33, 0x22, 0x11],           // 117..120 i=0: 0x11223344(小端 → 44 33 22 11)
    [0xDD, 0xCC, 0xBB, 0xAA],           // 121..124 i=1: 0xAABBCCDD
    [0x44, 0x33, 0x22, 0x11],           // 125..128 i=2
    [0xDD, 0xCC, 0xBB, 0xAA],           // 129..132 i=3
    [0x44, 0x33, 0x22, 0x11],           // 133..136 i=4
    [0xDD, 0xCC, 0xBB, 0xAA],           // 137..140 i=5
    [0x44, 0x33, 0x22, 0x11],           // 141..144 i=6
    [0xDD, 0xCC, 0xBB, 0xAA],           // 145..148 i=7
    [0x44, 0x33, 0x22, 0x11],           // 149..152 i=8
    [0xDD, 0xCC, 0xBB, 0xAA],           // 153..156 i=9
    [0x44, 0x33, 0x22, 0x11],           // 157..160 i=10
    [0xDD, 0xCC, 0xBB, 0xAA],           // 161..164 i=11
    [0x44, 0x33, 0x22, 0x11],           // 165..168 i=12
    [0xDD, 0xCC, 0xBB, 0xAA],           // 169..172 i=13
    [0x44, 0x33, 0x22, 0x11],           // 173..176 i=14
    [0xDD, 0xCC, 0xBB, 0xAA]            // 177..180 i=15
  );
  eq(expectedBody.length, 161, 'golden: 手推 body 长度 = 161');

  var crcVal = refCrc32(expectedBody);
  var crcLe = [crcVal & 0xFF, (crcVal >>> 8) & 0xFF, (crcVal >>> 16) & 0xFF, (crcVal >>> 24) & 0xFF];
  eq(crcVal, 0x3FF579A9, 'golden: 独立实现算出的 body CRC32 === 0x3FF579A9');
  eq(crcLe, [0xA9, 0x79, 0xF5, 0x3F], 'golden: 头部 CRC 字段的小端字节');

  var expectedFile = [].concat(
    [0x43, 0x59, 0x52, 0x4D],           // 0..3    magic "CYRM"(规格 §3.1)
    [0x04],                             // 4       version = 4
    [0x00],                             // 5       compression = 0(compress:false)
    [0xA1, 0x00, 0x00, 0x00],           // 6..9    body_size = 161(**解压后**字节数,小端)
    crcLe,                              // 10..13  body_crc32(**解压后** body 的 CRC32,小端)
    [0x04, 0x00],                       // 14..15  sub_cols = 4(1 格 × 4 子格)
    [0x04, 0x00],                       // 16..17  sub_rows = 4
    [0x0F],                             // 18      layer_flags = 0b1111(四层全在)
    [0x00],                             // 19      reserved = 0
    expectedBody                        // 20..180 body
  );
  eq(expectedFile.length, 181, 'golden: 手推文件长度 = 20 + 161 = 181');

  var gBytes = await Core.encodeMap(g, { compress: false });
  sameBytes(gBytes, expectedFile, 'golden: 完整文件字节逐字节比对');

  // 反过来也要能读回来(免得 golden 只钉住编码侧)
  var gBack = await Core.decodeMap(gBytes);
  eq(gBack.subCols, 4, 'golden: 回读 subCols');
  eq(gBack.subRows, 4, 'golden: 回读 subRows');
  eq(gBack.players, [{ x: 1, y: 2 }], 'golden: 回读出生点');
  eq(Array.prototype.slice.call(gBack.layers[1].desc),
     Array.prototype.slice.call(g.layers[1].desc), 'golden: 回读场景层');
})();

// ---- 压缩路径的独立验证(golden 用 compress:false,覆盖不到的那一半)----
// ★ 为什么还缺这一块:golden 走的是不压缩路径,那里 payload === body —— 所以
//   「body_size / body_crc32 算在**解压后**的 body 上」这条不变量在**默认(压缩)路径**
//   上一条断言都没有。实测:把 crc32(body) 与解码侧的比对**两端同时**改成 crc32(payload),
//   170 条断言全绿 —— 因为往返是对称的,而文件里的 CRC 值谁也没验过。
//   这正是指令 A 想堵的那类洞(只是 golden 按指令用的是 compress:false,够不到压缩侧),
//   故补下面两条。★ 超出 brief,报告里已点名。
await (async function () {
  var zlib = require('zlib');         // smoke.js 是 Node 测试,这里刻意用另一套 zlib 实现

  var m = Core.createMap('z', 6, 5);
  var brick = Core.neutralDesc(2);
  for (var i = 0; i < m.layers[1].desc.length; i++) m.layers[1].desc[i] = (i % 7 === 0) ? brick : 0;
  for (i = 0; i < m.layers[3].rgba.length; i++) m.layers[3].rgba[i] = ((0x304050 | (i & 0x3F)) * 0x010101) >>> 0;
  m.comments = ['zlib'];
  m.players = [{ x: 2, y: 3 }];

  var enc = await Core.encodeMap(m);                              // 默认压缩
  var plain = await Core.encodeMap(m, { compress: false });
  var body = plain.subarray(Core.HEADER_SIZE);                    // compression=0:body 就是 payload

  // ① 用 Node 自带的 zlib 独立解压我们的流 —— 验它确实是 zlib(RFC1950)。
  //    这是规格 §3.5 登记的头号风险(「两端库对 zlib 头的处理历史上有过细微差异」),
  //    也是在没有 Godot 的情况下能对它做的最强验证:换一套实现解出来必须一模一样。
  var got = new Uint8Array(zlib.inflateSync(Buffer.from(enc.subarray(Core.HEADER_SIZE))));
  sameBytes(got, Array.prototype.slice.call(body), '压缩: Node zlib 独立解压结果 == 裸 body');
  ok(enc.length < plain.length, '压缩: 压缩后确实比裸 body + 20 小');

  // ② 头部那两个字段必须算在**解压后**的 body 上(两端对称改错时往返抓不到)
  var zr = new Core.ByteReader(enc);
  zr.bytes(6);
  eq(zr.u32(), body.length, '压缩: body_size 是解压后的字节数(不是压缩后的)');
  eq(zr.u32(), Core.crc32(body), '压缩: body_crc32 是解压后 body 的 CRC(不是压缩流的)');
})();

// ---- 上限尺寸必须不受「按余量反推格数上界」那条检查的影响 ----
// ★ 上面新加的检查是**上界**(不精确,只需要不可能通过),但松紧仍有真实风险:
//   合法文件的余量并不宽裕 —— 最后一层若是背景层,room 恰好 = 1 + 4n,
//   而纹理层的第一个块也只比 n 多出 6 + 4×调色板项。检查若被写成 `n >= room`
//   或对纹理层也用 `room/4`,上限尺寸的图就会被**误拒**(而且只在图够大时才现形)。
//   故这里拿规格 §1 的上限 400×300 格 = 1600×1200 子格真跑一遍整文件往返。
//   ★ 走 compress:false 只为省掉这 13MB body 的 deflate 时间,与这条检查无关
//     (检查作用在解压后的 body 上,两条路径的 body 逐字节相同)。
await (async function () {
  var big = Core.createMap('big', 400, 300);
  eq(big.subCols, 1600, '上限尺寸: subCols = 400 格 × 4');
  eq(big.subRows, 1200, '上限尺寸: subRows = 300 格 × 4');
  var bigN = big.subCols * big.subRows;
  eq(bigN, 1920000, '上限尺寸: 子格总数 = 1600×1200');
  big.layers[1].desc[12345] = Core.neutralDesc(7);          // 场景层:只点一格,其余空气
  big.layers[3].rgba[999] = 0x11223344;                    // 背景层:只点一格
  var enc = await Core.encodeMap(big, { compress: false });
  var back = await Core.decodeMap(enc);
  eq(back.subCols, 1600, '上限尺寸: 回读 subCols(没被误拒)');
  eq(back.subRows, 1200, '上限尺寸: 回读 subRows');
  eq(back.layers[1].desc[12345], Core.neutralDesc(7), '上限尺寸: 场景层点格回读');
  eq(back.layers[3].rgba[999], 0x11223344, '上限尺寸: 背景层点格回读');
  eq(back.layers[1].desc.length, bigN, '上限尺寸: 场景层长度 = 子格总数');

  // 最紧的一档:整份文件**只有背景层**时,进入该层那一刻的余量恰好 = 1 + n×4,
  // 上界必须**恰好放行**(n > floor((1+4n)/4) 为假)。紧不紧与图多大无关,小图即可验。
  // 这条专钉"把上界收紧一格"这类回归 —— 它只在余量贴边时现形。
  var bgOnly = Core.createMap('bg', 40, 30);
  bgOnly.layers[0] = null; bgOnly.layers[1] = null; bgOnly.layers[2] = null;
  bgOnly.layers[3].rgba[7] = 0xAABBCCDD;
  var bgBack = await Core.decodeMap(await Core.encodeMap(bgOnly, { compress: false }));
  eq(bgBack.layers[3].rgba[7], 0xAABBCCDD, '上限尺寸: 只有背景层(余量恰好 1+4n)仍放行');
  eq(bgBack.layers[0], null, '上限尺寸: 缺层仍回 null');
})();

// ---- descriptor 位域 vs 任意字节:解码路径不许用 isAir 判空气 ----
// ★ 这一块钉 指令 B:isAir(d) 是 d === 0 的严格相等,而 decodeTexLayer 读的是**任意
//   字节**。一个「辅码非 0 而纹理为 0」的畸形描述符(0x000007FF)会让 isAir(d)===false
//   与 texOf(d)===0 得出相反结论 —— 解码路径若拿 isAir 判「这格是空气」就会判错。
//   解码路径的正确判据是 texOf(d) === 0(按纹理位域取值),不是整体等 0。
await (async function () {
  var malformed = 0x000007FF;                    // 纹理 0,但色相/亮度/饱和度三位全 1
  eq(Core.texOf(malformed), 0, '任意字节: texOf(0x7FF) === 0(纹理位域为 0)');
  eq(Core.isAir(malformed), false, '任意字节: isAir(0x7FF) === false(整体不等 0)—— 两者结论相反');

  // 让这个畸形描述符真的走一遍文件:encoder 不校验纹理位域,原样进调色板
  var g = Core.createMap('x', 1, 1);
  g.layers[0].desc[5] = malformed;
  var bytes = await Core.encodeMap(g, { compress: false });
  var back = await Core.decodeMap(bytes);
  eq(back.layers[0].desc[5], malformed, '任意字节: 畸形描述符原样穿过整文件往返(不被折成空气)');
  eq(Core.texOf(back.layers[0].desc[5]), 0, '任意字节: 回读后仍应判 texOf === 0');
  eq(back.layers[1].desc[5], 0, '任意字节: 真空气格仍是 0');
})();

// ---- v3 文本解析 ----
(function () {
  ok(Core.isV3Text('# cyrm-v3\n0000001F0031\n'), 'isV3Text: 有标记为真');
  ok(!Core.isV3Text('# 普通地图\n11\n11\n'), 'isV3Text: 无标记为假');

  // ★ 指令 B4:版本标记行的**同一个**谓词。此前 isV3Text 与 parseV3Text 各写一份且
  //   不等价(跳过用 /^#\s*cyrm-v\d+\s*$/,识别用 indexOf('# cyrm-v3') === 0),
  //   于是两种输入一头一尾各错一半:
  //     '#cyrm-v3'(无空格)  → 被跳过、却**不被识别为 v3** ⇒ 网格掉进旧字母格式(静默错位)
  //     '# cyrm-v3 (demo)'  → 被识别为 v3、却**不被跳过** ⇒ 标记行落进 comments,污染往返
  //   ★ 判据刻意用**全是 0-9 的网格行** `0011`:它在两种解析器下都合法,于是旧实现
  //     不抛错,而是安静地给出"被 2×2 折叠、格数减半"的结果 —— 那正是这类缺陷最危险的
  //     样子。两边的期望值**自行推导**:
  //       v3(正确)  : `0011` = 纹理 001 + 形状 hex 1 → 1*16+1 = 17;两行各 1 格 → [17,17],1×2 格
  //       旧字母(错) : [[0,0,1,1],[0,0,1,1]] 折叠 → 组(0)=[[0,0],[0,0]]=0、组(1)=[[1,1],[1,1]]=31
  //                    → [0,31],2×1 格
  //     三个维度(格宽/格高/packed)都不同,不存在"改错方向却仍撞对"的巧合。
  ok(Core.isV3Text('#cyrm-v3\n0000001F0031\n'),
     'B4 标记行:无空格的 #cyrm-v3 也算 v3(此前不算)');
  var nospace = Core.parseV3Text('#cyrm-v3\n0011\n0011\n');
  eq(nospace.cellsW, 1, 'B4 标记行:无空格的 #cyrm-v3 → cellsW 1(不是旧格式折叠后的 2)');
  eq(nospace.cellsH, 2, 'B4 标记行:无空格的 #cyrm-v3 → cellsH 2(不是旧格式折叠后的 1)');
  eq(Array.prototype.slice.call(nospace.packed), [17, 17],
     'B4 标记行:无空格的 #cyrm-v3 也按 v3 解析(此前掉进旧字母格式 → [0,31] 且格数减半)');
  ok(Core.isV3Text('# cyrm-v3 (demo)\n0000001F0031\n'),
     'B4 标记行:# cyrm-v3 后面跟着别的字仍算 v3(识别侧本来就这样)');
  eq(Core.parseV3Text('# cyrm-v3 (demo)\n0000001F0031\n').comments, [],
     'B4 标记行:# cyrm-v3 (demo) 不被当成注释(此前会把它塞进 comments、污染导入→导出)');
  // 反面:谓词不能宽到把"提到 cyrm-v 的普通注释"也吃掉
  eq(Core.parseV3Text('# cyrm-v3\n# 说明:cyrm-v3 是我们的文本格式\n0000\n').comments,
     ['说明:cyrm-v3 是我们的文本格式'],
     'B4 标记行:普通注释里提到 cyrm-v3 不算标记行(谓词不越界)');

  // v3:每格 4 字符 = 3 位纹理 + 1 位形状 hex
  var v3 = '# cyrm-v3\n# demo\n# player 12 34\n# enemy jump_bird 100 50\n0000001F0031\n';
  var p = Core.parseV3Text(v3);
  eq(p.cellsW, 3, 'parseV3Text: 宽 3 格');
  eq(p.cellsH, 1, 'parseV3Text: 高 1 格');
  eq(Array.prototype.slice.call(p.packed), [0, 31, 49], 'parseV3Text: packed 0/31(纹理1 全砖)/49(纹理3 左上 1/4)');
  eq(p.players, [{ x: 12, y: 34 }], 'parseV3Text: players');
  eq(p.enemies, [{ type: 'jump_bird', x: 100, y: 50 }], 'parseV3Text: enemies');
  eq(p.comments, ['demo'], 'parseV3Text: 注释保留,标记行不算注释');

  // 旧字母格式:单字符 0-9/A,2×2 收缩成 1 格,spawn 坐标 ÷2
  // ★ 指令 B:样本里必须带 `# enemy` 行 —— 唯一那份旧样本里没有它,于是
  //   **enemies 的 ÷2 与 `type` 字段此前零覆盖**(写漏一个 ÷2、或把 type 丢了都不会报错)。
  var old = Core.parseV3Text('# old\n# player 112 95\n# enemy jump_bird 100 50\n11\n11\n');
  eq(old.cellsW, 1, '旧格式: 2×2 → 1 格宽');
  eq(old.cellsH, 1, '旧格式: 2×2 → 1 格高');
  eq(Array.prototype.slice.call(old.packed), [31], '旧格式: 2×2 全实心 → 全砖 31');
  eq(old.players, [{ x: 56, y: 47 }], '旧格式: spawn 坐标 ÷2');
  eq(old.enemies, [{ type: 'jump_bird', x: 50, y: 25 }], '旧格式: enemies 坐标 ÷2 且 type 不丢');

  // ★ 指令 B(续):`LEGACY_CHAR['A']` 到此前只被**拒绝**路径碰过(b/B 报错),
  //   **接受**路径上一次都没走到 —— 把它写成 11、或整行漏出 LEGACY_CHAR
  //   (查表得 undefined → 报「非法字符」)都是"看着能跑"的静默错。
  //   `A1\n11` 的 4 个象限全实心、组内首个非零是 `A` ⇒ pack 成 10*16+15。
  var oldA = Core.parseV3Text('# old\nA1\n11\n');
  eq(Array.prototype.slice.call(oldA.packed), [175], '旧格式: A 参与 pack(2×2 全实心 → 10*16+15)');
  eq(Core._v3TexOf(oldA.packed[0]), 10, '旧格式: A 映射成纹理 10(不是 0/9/11)');

  // ★ 指令 E:旧字母格式的**非对称**象限样本。
  //   `_convertLegacy2x2` 里那句 `shape |= 1 << (sy * 2 + sx)` 此前只被两类样本碰过:
  //   全实心的 2×2(→ shape 15,**与象限顺序无关**)与抛错样本(b/B)。于是把它写成
  //   转置的 `1 << (sx * 2 + sy)` —— 或把 `sy/sx` 取反 —— 整份 smoke 仍然全绿,
  //   而**每张导入的旧 `.txt` 的每个非对称象限都转 90°**(静默错位)。
  //   这与 Task 9 刚修的 `migrateV3` 是同一类缺陷的另一处;区别是 migrateV3 那边
  //   已被「非对称形状逐个钉死」那块覆盖,这边没有。
  //   ★ 期望值**自行推导**(不照抄任何现成数字),依据就是本文件那两句实现:
  //       shape |= 1 << (sy * 2 + sx)      sy = 行偏移(0 上 / 1 下),sx = 列偏移(0 左 / 1 右)
  //       _v3Pack(tex, shape) = tex * 16 + shape
  //     样本一 `'10'` / `'11'`:非零象限 (sy,sx) = (0,0)、(1,0)、(1,1)
  //       → shape = 1<<0 | 1<<2 | 1<<3 = 1 + 4 + 8 = 13 → packed = 1*16 + 13 = 29
  //     样本二 `'11'` / `'01'`:非零象限 (sy,sx) = (0,0)、(0,1)、(1,1)
  //       → shape = 1<<0 | 1<<1 | 1<<3 = 1 + 2 + 8 = 11 → packed = 1*16 + 11 = 27
  //   ★ 两个样本互为「上/下镜像」,在转置下**恰好互换**(29 ↔ 27)—— 即变异会让两条
  //     断言同时变红,不存在"改错方向却仍撞对"的巧合。
  eq(Array.prototype.slice.call(Core.parseV3Text('# old\n10\n11\n').packed), [29],
     '旧格式: 非对称样本(右上缺)→ packed 29 = 纹理1 + shape 13(bit0|bit2|bit3)');
  eq(Array.prototype.slice.call(Core.parseV3Text('# old\n11\n01\n').packed), [27],
     '旧格式: 非对称样本(左下缺)→ packed 27 = 纹理1 + shape 11(bit0|bit1|bit3)');

  // 旧格式只认 0-9 与 A —— 游戏侧 _tile_char_to_value 就是这么定的,
  // 编辑器多认 b-k 会让"导得进、跑起来一片变空气"(审计 A11)。
  // ★ 指令 C(Task 8 遗留的 8 条裸 `throws` 补齐 —— 超出 brief,报告已点名):
  //   这 8 条是 A11/A12 审计的守卫点,偏偏是**最不能假绿**的一批:裸 `throws` 只要
  //   "抛了任何异常"就算过,`parseV3Text` 哪天因拼写错误而不存在、抛出的 `TypeError`
  //   会让它们**全部静默变绿**。故每条都给一个只属于它该触发的那个错误的子串。
  throws(function () { Core.parseV3Text('# old\n1b\n11\n'); },
         '旧格式: 小写 b 报错(游戏侧不认)', '非法字符 "b"');
  throws(function () { Core.parseV3Text('# old\n1B\n11\n'); },
         '旧格式: 大写 B 报错(游戏侧不认)', '非法字符 "B"');

  // ★ 指令 A4:旧字母格式靠 2×2 折叠成 1 格 ⇒ 宽高必须都是 **≥2 的偶数**。
  //   此前直接交给 Math.floor(h/2) / Math.floor(w/2),后果分两档:
  //     · 单行输入 → 转换后 rows 为空,紧接着的 rows[0].length 抛**裸 TypeError**;
  //     · 宽 3 × 高 4 → 返回 1×2 格,**一句话不说、两整列永久消失**(而按 §3.6 迁移是
  //       单向的,吃掉的东西找不回来)。本模块自己的约束是「编辑器不许静默吃掉用户写的东西」,
  //       故必须在进转换之前拦成一条与邻近解析错误同形状的中文错误。
  //   ★ 期望子串挑「旧字母格式的宽高」—— 它只属于这一条错误;并另钉一条「收到 3×2」,
  //     确保错误信息里带**实际收到的尺寸**(否则用户拿着报错也对照不出原文哪不对)。
  throws(function () { Core.parseV3Text('# old\n111\n111\n'); },
         'A4 旧格式: 奇数宽(3)报错,不再静默丢掉一整列', '旧字母格式的宽高');
  throws(function () { Core.parseV3Text('# old\n111\n111\n'); },
         'A4 旧格式: 奇数宽的错误信息里带实际尺寸 3×2', '收到 3×2');
  throws(function () { Core.parseV3Text('# old\n11\n11\n11\n'); },
         'A4 旧格式: 奇数高(3)报错,不再静默丢掉一整行', '旧字母格式的宽高');
  throws(function () { Core.parseV3Text('# old\n11\n'); },
         'A4 旧格式: 单行输入报错(此前抛裸 TypeError: 读 undefined 的 length)', '旧字母格式的宽高');
  throws(function () { Core.parseV3Text('# old\n1\n1\n'); },
         'A4 旧格式: 宽 1(奇数且 <2)报错', '旧字母格式的宽高');
  // 反面:合法的偶数尺寸一个都不能被误伤 —— 上面那串旧格式样本已经全跑通了,
  // 这里再钉一条 2×2 的下界与一条更宽的偶数尺寸,免得把守卫写成 `width <= 2`。
  eq(Core.parseV3Text('# old\n11\n11\n').cellsW, 1, 'A4 旧格式: 下界 2×2 仍可解析');
  eq(Core.parseV3Text('# old\n1111\n1111\n').cellsW, 2, 'A4 旧格式: 宽 4(偶数)仍可解析');
  eq(Core.parseV3Text('# old\n11\n11\n11\n11\n').cellsH, 2, 'A4 旧格式: 高 4(偶数)仍可解析');

  // 非法输入必须抛错,不能静默截断成空气(审计 A12:parseInt("0A1") === 0)
  throws(function () { Core.parseV3Text('# cyrm-v3\n0A10\n'); },
         'v3: 纹理位含字母报错', '不是 3 位数字');
  throws(function () { Core.parseV3Text('# cyrm-v3\n000X\n'); },
         'v3: 非法形状字符报错', '非法形状字符 "X"');
  throws(function () { Core.parseV3Text('# cyrm-v3\n00000000\n0000\n'); },
         'v3: 行宽不一致报错', '宽度 1 与首行 2 不一致');
  throws(function () { Core.parseV3Text('# cyrm-v3\n000\n'); },
         'v3: 字符数非 4 倍数报错', '不是 4 的倍数');
  throws(function () { Core.parseV3Text('# cyrm-v3\n# 只有注释\n'); },
         'v3: 没有网格行报错', '没有有效网格行');
  throws(function () { Core.parseV3Text('# old\n'); },
         '旧格式: 没有网格行报错', '没有有效网格行');

  // CRLF 与空行
  var crlf = Core.parseV3Text('# cyrm-v3\r\n\r\n0000001F0031\r\n');
  eq(Array.prototype.slice.call(crlf.packed), [0, 31, 49], 'parseV3Text: CRLF 与空行');

  // 小写形状字符仍要能读(v3 写法上允许,游戏侧 shape_char_to_value 也认)
  // ★ 输入从 brief 的 "000f" 改成 "001f"(报告里已点名):brief 里纹理位 000 = 空气,
  //   而 _v3Pack 对 texture === 0 无条件返回 0(与游戏侧 MapFormat.pack 逐字一致),
  //   故 "000f" 恒为 0 —— 那个输入根本走不到形状字符,断言等于空转(实测 got [0])。
  //   换成 001 后,31 = 1*16 + 15 才真的证明 'f' 被读成了 15 而不是被当成 0/报错。
  eq(Array.prototype.slice.call(Core.parseV3Text('# cyrm-v3\n001f\n').packed), [31], 'v3: 小写形状字符 f 可读');

  // ★ 指令 A：`_v3Pack` 的两个空气守卫（`shape === 0 || texture === 0` → 0）
  //   是「迁移等价」所依赖的地基之一，此前**只被 `0000` 这一个退化样本覆盖过** ——
  //   那里 shape 与 texture 同时为 0，分不出是哪一条守卫在生效（任意一条删掉都照样绿）。
  //   下面两条各钉一条独立情形，两者都与游戏侧 `MapFormat.pack` 逐字同款。
  eq(Array.prototype.slice.call(Core.parseV3Text('# cyrm-v3\n000f\n').packed), [0],
     'v3: 纹理 000 = 空气,形状位不生效(与游戏 MapFormat.pack 同)');
  eq(Array.prototype.slice.call(Core.parseV3Text('# cyrm-v3\n0010\n').packed), [0],
     'v3: 形状 0 = 空气,纹理位不生效(纹理 1 也留不住)');
})();

// ---- 取角映射(§2.2 的规范定义,游戏侧 shader 必须与此一致)----
(function () {
  eq(Core.subcellRender(0, 0), { dst: [0, 0, 16, 16], src: [0, 0, 8, 8] }, 'subcellRender: 格内 (0,0)');
  eq(Core.subcellRender(3, 0), { dst: [48, 0, 16, 16], src: [24, 0, 8, 8] }, 'subcellRender: 格内 (3,0)');
  eq(Core.subcellRender(0, 3), { dst: [0, 48, 16, 16], src: [0, 24, 8, 8] }, 'subcellRender: 格内 (0,3)');
  eq(Core.subcellRender(4, 4), { dst: [64, 64, 16, 16], src: [0, 0, 8, 8] }, 'subcellRender: 象限按 X%4 循环');
  eq(Core.subcellRender(7, 5), { dst: [112, 80, 16, 16], src: [24, 8, 8, 8] }, 'subcellRender: 第二格右下');

  // ★ 迁移正确性的全部依据:v3 的一个 32px 象限 ↔ v4 的 2×2 个 16px 子格,
  //   目标矩形与源矩形都必须**精确铺满**(尺寸相等 + 包围盒相等 ⇒ 不重不漏)。
  function v3QuadrantRender(cellX, cellY, qx, qy) {
    return { dst: [cellX * 64 + qx * 32, cellY * 64 + qy * 32, 32, 32],
             src: [qx * 16, qy * 16, 16, 16] };
  }
  function quadrantEquivalent(cellX, cellY, qx, qy) {
    var o = v3QuadrantRender(cellX, cellY, qx, qy);
    var dMinX = Infinity, dMinY = Infinity, dMaxX = -Infinity, dMaxY = -Infinity, dArea = 0;
    var sMinX = Infinity, sMinY = Infinity, sMaxX = -Infinity, sMaxY = -Infinity;
    for (var dy = 0; dy < 2; dy++) {
      for (var dx = 0; dx < 2; dx++) {
        var s = Core.subcellRender(cellX * 4 + qx * 2 + dx, cellY * 4 + qy * 2 + dy);
        dArea += s.dst[2] * s.dst[3];
        dMinX = Math.min(dMinX, s.dst[0]); dMinY = Math.min(dMinY, s.dst[1]);
        dMaxX = Math.max(dMaxX, s.dst[0] + s.dst[2]); dMaxY = Math.max(dMaxY, s.dst[1] + s.dst[3]);
        sMinX = Math.min(sMinX, s.src[0]); sMinY = Math.min(sMinY, s.src[1]);
        sMaxX = Math.max(sMaxX, s.src[0] + s.src[2]); sMaxY = Math.max(sMaxY, s.src[1] + s.src[3]);
      }
    }
    return dArea === o.dst[2] * o.dst[3] &&
           dMinX === o.dst[0] && dMinY === o.dst[1] &&
           dMaxX === o.dst[0] + o.dst[2] && dMaxY === o.dst[1] + o.dst[3] &&
           sMinX === o.src[0] && sMinY === o.src[1] &&
           sMaxX === o.src[0] + o.src[2] && sMaxY === o.src[1] + o.src[3];
  }
  // ★ 累积成一个布尔量时失败只知道"错了",不知道是哪个格/象限;这条断言是本计划的关键
  //   证明,失败必须可诊断 —— 故把**首个**失败组合记进消息(一旦失败就短路,不再往下算)。
  var eqAll = true, firstBad = null;
  for (var cx = 0; cx < 3; cx++) for (var cy = 0; cy < 3; cy++)
    for (var qx = 0; qx < 2; qx++) for (var qy = 0; qy < 2; qy++)
      if (eqAll && !quadrantEquivalent(cx, cy, qx, qy)) {
        eqAll = false;
        firstBad = 'cx=' + cx + ' cy=' + cy + ' qx=' + qx + ' qy=' + qy;
      }
  ok(eqAll, '★ 取角等价:v3 的每个象限都能被 v4 的 2×2 子格精确铺满(3×3 格 × 4 象限全查)'
            + (firstBad === null ? '' : ' —— 首个失败组合:' + firstBad));
})();

// ---- v3 → v4 迁移 ----
await (async function () {
  var v3 = '# cyrm-v3\n# demo\n# player 1 1\n0000001F0031\n000000000000\n';
  var p = Core.parseV3Text(v3);
  var m = Core.migrateV3(p);

  eq(m.subCols, p.cellsW * 4, 'migrateV3: subCols = 格数×4');
  eq(m.subRows, p.cellsH * 4, 'migrateV3: subRows = 格数×4');
  eq(m.comments, ['demo'], 'migrateV3: 注释带过来');
  eq(m.players, [{ x: 1, y: 1 }], 'migrateV3: 出生点带过来(坐标不缩放)');
  // ★ 超出 brief(报告已点名):brief 的样本里没有 `# enemy` 行,于是同在 migrateV3 里的
  //   `map.enemies = parsed.enemies.map(…)` 那**一行零覆盖** —— `type` 字段写丢或坐标
  //   被缩放都不会让任何断言变红(指令 B 点名的正是这个风险类,只是它还有这半边)。
  //   单起一格样本钉住它,不动上面那段的样本。
  var em = Core.migrateV3(Core.parseV3Text('# cyrm-v3\n# enemy jump_bird 100 50\n001F\n'));
  eq(em.enemies, [{ type: 'jump_bird', x: 100, y: 50 }],
     'migrateV3: 敌人带过来(type 保留、坐标不缩放)');
  eq(m.layers[Core.LAYER_FRONT].desc.some(function (v) { return v !== 0; }), false, 'migrateV3: 前景层留空');
  eq(m.layers[Core.LAYER_BACK].desc.some(function (v) { return v !== 0; }), false, 'migrateV3: 后景层留空');
  eq(m.layers[Core.LAYER_BG].rgba.some(function (v) { return v !== 0; }), false, 'migrateV3: 背景层留空(全透明黑)');

  var scene = m.layers[Core.LAYER_SCENE].desc;
  var brick = Core.neutralDesc(1);
  // 格 (1,0) 的 packed = 31 = 纹理1 全砖 → 该格 16 个子格全是 brick
  for (var dy = 0; dy < 4; dy++) {
    for (var dx = 0; dx < 4; dx++) {
      eq(scene[(0 * 4 + dy) * m.subCols + (1 * 4 + dx)], brick,
         'migrateV3: 全砖格 (1,0) 的子格 (' + dx + ',' + dy + ') 填满纹理1 中性');
    }
  }
  // 格 (2,0) 的 packed = 49 = 纹理3 shape 1(仅左上 1/4)→ 只有子格 (0,0),(1,0),(0,1),(1,1) 被填
  var g3 = 3;
  var t3 = Core.neutralDesc(g3);
  eq(scene[(0 * 4 + 0) * m.subCols + (2 * 4 + 0)], t3, 'migrateV3: 1/4 砖格 → 子格(0,0) 有纹理3');
  eq(scene[(0 * 4 + 0) * m.subCols + (2 * 4 + 1)], t3, 'migrateV3: 1/4 砖格 → 子格(1,0) 有纹理3');
  eq(scene[(0 * 4 + 1) * m.subCols + (2 * 4 + 0)], t3, 'migrateV3: 1/4 砖格 → 子格(0,1) 有纹理3');
  eq(scene[(0 * 4 + 1) * m.subCols + (2 * 4 + 1)], t3, 'migrateV3: 1/4 砖格 → 子格(1,1) 有纹理3');
  eq(scene[(0 * 4 + 0) * m.subCols + (2 * 4 + 2)], 0, 'migrateV3: 1/4 砖格 → 子格(2,0) 是空气');
  eq(scene[(0 * 4 + 2) * m.subCols + (2 * 4 + 0)], 0, 'migrateV3: 1/4 砖格 → 子格(0,2) 是空气');
  eq(scene[(0 * 4 + 3) * m.subCols + (2 * 4 + 3)], 0, 'migrateV3: 1/4 砖格 → 子格(3,3) 是空气');

  // 全空行不留任何东西
  var occupied = 0;
  for (var i = 0; i < scene.length; i++) if (scene[i] !== 0) occupied++;
  eq(occupied, 16 + 4, 'migrateV3: 非空子格总数 = 一整格(16) + 1/4 格(4)');

  // 旧字母格式也能一路迁到底
  var oldMap = Core.migrateV3(Core.parseV3Text('# old\n11\n11\n'));
  eq(oldMap.layers[Core.LAYER_SCENE].desc.length, 16, 'migrateV3: 旧格式迁移后尺寸');
  eq(oldMap.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(1), 'migrateV3: 旧格式全砖格');

  // 迁移出来的图必须能原样过整文件往返
  var bytes = await Core.encodeMap(m);
  var back = await Core.decodeMap(bytes);
  eq(Array.prototype.slice.call(back.layers[Core.LAYER_SCENE].desc),
     Array.prototype.slice.call(m.layers[Core.LAYER_SCENE].desc), 'migrateV3: 迁移结果可二进制往返');
  eq(back.comments, ['demo'], 'migrateV3: 往返后注释仍是 demo(标记行没被当成注释)');
})();

// ---- migrateV3:非对称象限的位序与展开方向(规格 §3.6「必须写死」)----
// ★ 上面那批样本全都**对位序不敏感**,构成一个真实的盲区:
//     shape 15(全砖)填满四格 —— 与象限顺序无关;
//     shape 1(bit0)的象限 (qx=0,qy=0) —— 是唯一在象限转置下不变的形状。
//   于是把 `1 << (qy*2+qx)` 写成 `1 << (qx*2+qy)`、或把展开处的 X/Y 对调,
//   整份 smoke 仍然全绿,而每张导入图的每个非对称象限整体转 90°(静默错位)。
//   ★ 取角等价那条断言帮不上忙:它在自己的循环里硬编码了 `cellX*4+qx*2+dx`,
//     从不调用 migrateV3,证明不了 migrateV3 里的 qx/qy 有没有被对调。
//   故这里用**非对称**形状逐个钉死 bit → 子格位置:
//     bit(qy*2+qx) 为 1 → 展开到 X∈[2qx,2qx+1]、Y∈[2qy,2qy+1](各 2×2 子格)。
//   '#' = 该子格是纹理2 的中性描述、'.' = 空气、'?' = 非空气但纹理不对
//   —— 三者是同一串图案里的不同字符,所以"填错纹理"与"填错位置"一样会让断言变红。
(function () {
  var SAMPLES = [
    ['1', '左上/bit0 (qx0,qy0)', ['##..', '##..', '....', '....']],
    ['2', '右上/bit1 (qx1,qy0)', ['..##', '..##', '....', '....']],
    ['4', '左下/bit2 (qx0,qy1)', ['....', '....', '##..', '##..']],
    ['8', '右下/bit3 (qx1,qy1)', ['....', '....', '..##', '..##']],
  ];
  SAMPLES.forEach(function (s) {
    var m = Core.migrateV3(Core.parseV3Text('# cyrm-v3\n002' + s[0] + '\n'));
    var sc = m.layers[Core.LAYER_SCENE].desc, cols = m.subCols;
    var t = Core.neutralDesc(2);
    var got = [];
    for (var Y = 0; Y < 4; Y++) {
      var row = '';
      for (var X = 0; X < 4; X++) row += (sc[Y * cols + X] === 0 ? '.'
                                       : (sc[Y * cols + X] === t ? '#' : '?'));
      got.push(row);
    }
    eq(got, s[2], 'migrateV3: shape ' + s[0] + '(' + s[1] + ')的子格图案(4×4 全查,'
                + '位序 bit(qy*2+qx) 与展开方向同时被钉住)');
  });
})();

// ---- 尺寸钳制(审计 A8:旧 clampMin 的第三参是"默认值"而不是上限,输 99999 直接卡死)----
eq(Core.MAX_CELLS_W, 400, 'MAX_CELLS_W');
eq(Core.MAX_CELLS_H, 300, 'MAX_CELLS_H');
eq(Core.clampMapSize(125, 75), { w: 125, h: 75 }, 'clampMapSize: 正常值原样');
eq(Core.clampMapSize(99999, 99999), { w: 400, h: 300 }, 'clampMapSize: 超上限被钳');
eq(Core.clampMapSize(0, -5), { w: 1, h: 1 }, 'clampMapSize: 下限 1');
eq(Core.clampMapSize(NaN, 'x'), { w: 125, h: 75 }, 'clampMapSize: 非数字回落默认');

// ---- validateMap ----
(function () {
  var good = Core.createMap('ok', 8, 8);
  good.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(1);
  good.players = [{ x: 1, y: 1 }];
  var v = Core.validateMap(good);
  eq(v.errors, [], 'validateMap: 正常图无 error');

  // 出生点落在实心格里
  var inWall = Core.createMap('bad', 8, 8);
  var sc = inWall.layers[Core.LAYER_SCENE].desc;
  // ★ 超出 brief(报告已点名):brief 这里写的是 `for (i = 0; i < 16; i++) sc[i] = ...`,
  //   注释声称「格 (0,0) 填实」—— 但那是**行主序的前 16 个子格**,即子行 0 的 X∈[0,15],
  //   只铺满了 (0,0)(1,0)(2,0)(3,0) 四格各自的**顶行**。判据要求该格 4×4 子格**全**非空
  //   ⇒ 格 (0,0) 远没被填实 ⇒ 恒不产生 warning ⇒ 这条断言**空转到永远为假**
  //   (实测 brief 原样跑必红)。改成按「格内 4×4」逐个填,才是注释声称的那件事。
  for (var dy = 0; dy < 4; dy++) {
    for (var dx = 0; dx < 4; dx++) sc[dy * inWall.subCols + dx] = Core.neutralDesc(1);
  }
  inWall.players = [{ x: 0, y: 0 }];
  // ★ 判据是 '实心' 而不是 '出生点':后者**任何**出生点相关的 warning 都满足
  //   (「一个出生点都没有」/「坐标越界」),这条断言今天只能匹配到实心那一支,
  //   纯粹因为 (0,0) 恰好没越界。钉住'实心'才真正钉在它要覆盖的那一支上。
  ok(Core.validateMap(inWall).warnings.some(function (s) { return s.indexOf('实心') >= 0; }),
     'validateMap: 出生点在实心格里给 warning');

  // 一个出生点都没有
  var noSpawn = Core.createMap('n', 8, 8);
  ok(Core.validateMap(noSpawn).warnings.some(function (s) { return s.indexOf('出生点') >= 0; }),
     'validateMap: 没有出生点给 warning');

  // 第 3 个及以后的出生点游戏读不到(审计 A3)
  var three = Core.createMap('t', 8, 8);
  three.players = [{ x: 1, y: 1 }, { x: 2, y: 2 }, { x: 3, y: 3 }];
  ok(Core.validateMap(three).warnings.some(function (s) { return s.indexOf('第 3 个') >= 0; }),
     'validateMap: >2 个出生点给 warning');

  // 敌人坐标越界(改尺寸后的残留,审计 A10)
  var oob = Core.createMap('o', 8, 8);
  oob.players = [{ x: 1, y: 1 }];
  oob.enemies = [{ type: 'fly_bird', x: 99, y: 0 }];
  ok(Core.validateMap(oob).warnings.some(function (s) { return s.indexOf('越界') >= 0; }),
     'validateMap: 敌人坐标越界给 warning');

  // 四层全空
  var blank = Core.createMap('b', 8, 8);
  blank.players = [{ x: 1, y: 1 }];
  ok(Core.validateMap(blank).warnings.some(function (s) { return s.indexOf('空') >= 0; }),
     'validateMap: 四层全空给 warning');

  // error 只给真正非法的东西:尺寸非 4 倍数
  var badSize = Core.createMap('s', 8, 8);
  badSize.subCols = 30;
  ok(Core.validateMap(badSize).errors.length > 0, 'validateMap: 尺寸非 4 倍数给 error');
})();

// ---- encodeMap 必须自己校验(指令 A3)----
// ★ 为什么:decodeMap 在尺寸/图层长度上是**严格**的,而 encodeMap 此前**一处校验都没有**
//   ⇒ 一张 subCols 非 4 倍数的图能编码成功,产出的文件却连本编辑器自己都读不回来
//   —— 又一个「导出后再也导不回来」(A6 类)。errors / warnings 的划分本来就是为这件事
//   定的。★ 同时钉住**反向**:只有 warnings 时**不许**拒导出 —— 规格 §4.7 明说校验
//   只报告不阻止,拿 warnings 拦导出就是把"只报告"偷偷变成"阻止"。
await (async function () {
  // ① errors 非空 ⇒ reject(两条导出路径都要)
  var bad = Core.createMap('bad', 8, 8);
  bad.players = [{ x: 1, y: 1 }];
  bad.subCols = 30;                                    // 非 4 的倍数
  ok(Core.validateMap(bad).errors.length > 0,
     'A3: 前提 —— 这张图 validateMap 确实有 error(否则下面两条验的不是这件事)');
  await rejects(function () { return Core.encodeMap(bad); },
    'A3: encodeMap: 有 error 的地图必须 reject,而不是产出读不回来的文件', '校验未通过');
  await rejects(function () { return Core.encodeMap(bad, { compress: false }); },
    'A3: encodeMap: 不压缩路径同样要拒(校验在两条路径之前,不分叉)', '校验未通过');

  // ② 图层长度不符(另一条 error 分支)
  var badLen = Core.createMap('bad', 8, 8);
  badLen.players = [{ x: 1, y: 1 }];
  badLen.layers[Core.LAYER_SCENE].desc = new Uint32Array(16);   // 8×8 格应是 32×32 = 1024 子格
  ok(Core.validateMap(badLen).errors.length > 0, 'A3: 前提 —— 图层长度不符也是 error');
  await rejects(function () { return Core.encodeMap(badLen); },
    'A3: encodeMap: 图层长度不符也必须 reject', '校验未通过');

  // ③ 只有 warnings 时必须照常导出(「只拒 errors」的那一半)
  var warnOnly = Core.createMap('warn', 8, 8);          // 无出生点 + 四层全空 = 2 条 warning
  var wv = Core.validateMap(warnOnly);
  eq(wv.errors.length, 0, 'A3: 前提 —— 这张图没有 error');
  ok(wv.warnings.length >= 2, 'A3: 前提 —— 这张图确有 warning(' + wv.warnings.length + ' 条)');
  var wEnc = await Core.encodeMap(warnOnly, { compress: false });
  var wBack = await Core.decodeMap(wEnc);
  eq(wBack.subCols, warnOnly.subCols, 'A3: 只有 warnings 的地图照常导出(warnings 不阻止导出)');
  eq(wBack.subRows, warnOnly.subRows, 'A3: 只有 warnings 的地图照常导出(subRows)');

  // ④ ★ 真正「导出后再也导不回来」的那一格 —— 上面那两张图 encodeBody 自己也会顺手抛
  //   (尺寸与图层长度对不上),所以它们**证明不了**这道校验是必须的。这里手工构造一张
  //   **自洽**的图:subCols 非 4 的倍数,但每层数组长度**恰好**等于 subCols×subRows
  //   ⇒ encodeBody 一路成功(它只看 layer.desc.length 与 subCols×subRows 是否相等),
  //     而产出的文件头写着 sub_cols = 6,decodeMap 的尺寸检查**当场拒收**。
  //   这正是 A3 要堵的那个洞:不加校验就会**安静地写出一份自己读不回来的 .cyrm**。
  //   ★ 那份"未过校验的文件"的结局另有断言钉住('decodeMap: 尺寸非 4 倍数抛错' ——
  //     把合法文件的头部改成 sub_cols = 6 后 decodeMap 当场拒收),这里不重复造一遍。
  var odd = Core.createMap('odd', 8, 8);
  odd.subCols = 6;                                       // 6 不是 SUB_PER_CELL(4)的倍数
  var oddN = odd.subCols * odd.subRows;                  // 6×32 = 192
  odd.layers[0].desc = new Uint32Array(oddN);
  odd.layers[1].desc = new Uint32Array(oddN);
  odd.layers[2].desc = new Uint32Array(oddN);
  odd.layers[3].rgba = new Uint32Array(oddN);
  odd.players = [{ x: 1, y: 1 }];
  var ov = Core.validateMap(odd);
  eq(ov.errors.length > 0, true, 'A3: 前提 —— 自洽的非 4 倍数尺寸图确有 error');
  eq(ov.errors.some(function (s) { return s.indexOf('倍数') >= 0; }), true,
     'A3: 前提 —— 那条 error 正是尺寸非 4 的倍数(图层长度对得上,所以只有这一条)');
  await rejects(function () { return Core.encodeMap(odd, { compress: false }); },
    'A3: 自洽的非 4 倍数尺寸图必须 reject 而不是安静地写出读不回来的文件(变异:去掉校验即红)',
    '校验未通过');
})();

// ---- 大图端到端 + 性能守卫 ----
await (async function () {
  var t0 = Date.now();
  var big = Core.createMap('big', 400, 300);          // 上限尺寸:1600×1200 子格 = 192 万
  var tCreate = Date.now() - t0;
  ok(tCreate < 2000, '大图: createMap(400×300) 耗时 ' + tCreate + 'ms < 2000ms');

  // 铺一层可压缩的内容(条带),再叠一点稀疏噪声防止退化成全部相同
  var sc = big.layers[Core.LAYER_SCENE].desc;
  var d1 = Core.neutralDesc(1), d2 = Core.neutralDesc(2);
  for (var i = 0; i < sc.length; i++) sc[i] = ((i / big.subCols) | 0) % 7 === 0 ? d1 : d2;
  for (i = 0; i < sc.length; i += 997) sc[i] = Core.neutralDesc(15);
  for (i = 0; i < big.layers[Core.LAYER_BG].rgba.length; i++) {
    big.layers[Core.LAYER_BG].rgba[i] = ((i % 256) * 0x010101) >>> 0;
  }

  t0 = Date.now();
  var bytes = await Core.encodeMap(big);
  var tEnc = Date.now() - t0;
  ok(tEnc < 8000, '大图: encodeMap 耗时 ' + tEnc + 'ms < 8000ms(压缩后 ' + bytes.length + ' 字节)');

  t0 = Date.now();
  var back = await Core.decodeMap(bytes);
  var tDec = Date.now() - t0;
  ok(tDec < 8000, '大图: decodeMap 耗时 ' + tDec + 'ms < 8000ms');

  eq(back.subCols, big.subCols, '大图: subCols 往返');
  eq(Array.prototype.slice.call(back.layers[Core.LAYER_SCENE].desc, 0, 64),
     Array.prototype.slice.call(sc, 0, 64), '大图: 场景层前 64 格往返一致');
  eq(back.layers[Core.LAYER_SCENE].desc.length, sc.length, '大图: 场景层长度');

  // 高度重复的内容必须被压掉一大截。
  // 单是场景层的裸索引流就有 sc.length 字节,压完若还比它大,说明压缩没起作用。
  ok(bytes.length < sc.length,
     '大图: 压缩后 ' + bytes.length + ' 字节 < 场景层裸索引流 ' + sc.length + ' 字节');
})();

// ---- 指令 D:解压后 body 的硬上限(堵 deflate 炸弹)----
// ★ 为什么需要单独一道闸:deflate 的最大压缩比约 1032:1 ⇒ **几十 KB** 的恶意/损坏
//   文件就能解出 **GB 级**内存,而它**完全不碰头部字段**(magic/版本/尺寸/CRC 全合法),
//   所以「按 body 实际余量反推格数上界」那条检查对它**天然无效** —— 那条管的是
//   「头部声称的尺寸大于 body 装得下的量」,炸弹是反过来的:body 声称很小、解出来极大。
//   判在解压之后等于拒是拒了、内存已经先分配出去了,故必须判在**解压之前**。
await (async function () {
  eq(Core.MAX_BODY_SIZE, 64 * 1024 * 1024, 'MAX_BODY_SIZE === 64MB');

  var m = Core.createMap('bomb', 6, 5);
  m.layers[Core.LAYER_SCENE].desc[9] = Core.neutralDesc(3);
  m.players = [{ x: 1, y: 1 }];
  var enc = await Core.encodeMap(m);              // 默认走 deflate 压缩

  // 只把头部 6..9(body_size,u32 小端)篡改成 0x7FFFFFFF ≈ 2GB,payload 一个字节不动
  // —— 这正是"声明侧"的炸弹:任何在解压之后才判的守卫都已经晚了。
  var bomb = enc.slice();
  bomb[6] = 0xFF; bomb[7] = 0xFF; bomb[8] = 0xFF; bomb[9] = 0x7F;
  await rejects(function () { return Core.decodeMap(bomb); },
    'decodeMap: body_size 被声明成 0x7FFFFFFF 时在解压前拒绝', '64MB');

  // ★★ 声明侧之外的另一半:头里的 body_size **本身也是攻击者可控的** —— 把它谎报成
  //   一个能过闸门的小值(4096)、而 deflate 流里塞真炸弹,则上面那道闸**完全挡不住**:
  //   真正的分配发生在解压那一步(`new Response(stream).arrayBuffer()` 会先把整份解压
  //   结果分配出来),判在后面的长度比对处等于拒是拒了、内存已经花掉了。
  //   判据必须落在**实际输出**上(core.js inflateBytes 的 maxBytes),这条断言钉的就是它。
  //   造法:合法文件头(尺寸/flags 都对)+ 把 body_size 改成 4096 + payload 换成
  //   65MB 零字节的 deflate 流(压完 ≈66KB;DEFLATE 单流最大压缩比 ≈1032:1)。
  var zlib = require('zlib');
  var bombPayload = zlib.deflateSync(Buffer.alloc(65 * 1024 * 1024));   // 65MB > 64MB 上限
  var head = enc.slice(0, Core.HEADER_SIZE);
  head[6] = 0x00; head[7] = 0x10; head[8] = 0x00; head[9] = 0x00;       // body_size = 4096
  var lie = new Uint8Array(head.length + bombPayload.length);
  lie.set(head, 0);
  lie.set(bombPayload, head.length);
  ok(4096 <= Core.MAX_BODY_SIZE,
     '谎报的 body_size 4096 确实能通过「声明侧」那道闸(否则本相验的不是这条)');
  await rejects(function () { return Core.decodeMap(lie); },
    'decodeMap: body_size 谎报成 4096 + 真炸弹,在 inflateBytes 的实际输出上界处被拒',
    'inflateBytes');

  // ★ 指令 B1:上界传的必须是**头部声明的 body_size**,不是 MAX_BODY_SIZE。
  //   两者的差别只在"谎报得**不太大**"时现形 —— 上面那条 65MB 炸弹太大,两种实现**都会拒**
  //   (只是一个在 4KB 处拒、一个在 64MB 处拒),所以它**证明不了**上界用的是哪个值。
  //   这里谎报 4096、真输出 8MB:远小于 64MB 上限 ⇒
  //     传 MAX_BODY_SIZE 时这道闸**完全不响**,要等解压完 8MB、走到长度比对处才拒(已经花掉 8MB)
  //     传 bodySize 时第一个 chunk 就拒(约 4KB + 一个 chunk)
  //   ★ 期望子串必须挑**只有新实现才产生**的那句:'4096' 不能用 —— 旧实现那句
  //     "解压后 8388608 字节,头部声明 4096" 里也含 '4096',拿它当判据会**假绿**。
  var smallBomb = zlib.deflateSync(Buffer.alloc(8 * 1024 * 1024));       // 8MB ≪ 64MB 上限
  var head2 = enc.slice(0, Core.HEADER_SIZE);
  head2[6] = 0x00; head2[7] = 0x10; head2[8] = 0x00; head2[9] = 0x00;    // body_size = 4096
  var lie2 = new Uint8Array(head2.length + smallBomb.length);
  lie2.set(head2, 0);
  lie2.set(smallBomb, head2.length);
  ok(smallBomb.length < 1024 * 1024,
     'B1 前提: 8MB 输出压完只有 ' + smallBomb.length + ' 字节(输入有界、结果无界)');
  await rejects(function () { return Core.decodeMap(lie2); },
    'B1: 谎报 4096 + 8MB 真输出(仍在 64MB 之内)时,闸门落在实际输出上、且上界 = bodySize',
    '解压输出超过');

  // 兼容:不传 maxBytes = 不设限,旧调用语义一字不改
  var tiny = zlib.deflateSync(Buffer.from('cyrm', 'utf8'));
  sameBytes(await Core.inflateBytes(tiny), [0x63, 0x79, 0x72, 0x6D],
    'inflateBytes: 不传 maxBytes 时仍解出全部内容(向后兼容)');

  // 反向:这道闸不许误伤合法文件。上限尺寸(400×300)的合法 body 最坏约 20MB
  // (推导见 core.js 该常量上方的注释),64MB 是它的 ≈3.3 倍。
  // 把这层余量本身变成断言 —— 有人把常量调小到会误拒合法大图时,「上限尺寸」那块
  // 的往返断言也会红,但这条给出的是**直接错因**(而不是"图读不回来了")。
  ok(Core.MAX_BODY_SIZE > 20 * 1024 * 1024,
     'MAX_BODY_SIZE: 大于上限尺寸合法文件的最坏 body(≈20MB),不会误拒');
})();

// ---- 源码顺序:body_size 闸门必须**早于**解压(指令 D 的证据机制)----
// ★ 为什么需要这条:上面那条反向断言用 expectSub 匹配 '64MB' —— 而**把闸门挪到
//   inflateBytes 之后、长度比对之前**的实现**同样会**匹配到 '64MB'(拒的还是同一份文件),
//   于是"它确实在解压之前生效"这件事只靠读源码、没有断言钉住。本仓有源码级探针的习惯
//   (tests/*_probe.gd 直接读生产源码做断言),这里照办:读 core.js 的源码文本比位置。
// ★ 锚 'inflateBytes(payload' 而不锚 'inflateBytes(' —— 后者会先在**函数定义**
//   (function inflateBytes(bytes, maxBytes))处命中,那个位置在闸门之前,
//   断言会与实现无关地恒红。
(function () {
  var dmAt = coreSrc.indexOf('function decodeMap');
  ok(dmAt >= 0, '源码顺序: core.js 里找得到 function decodeMap');
  if (dmAt < 0) return;
  // 剥掉行注释再找 —— 否则注释里提一句 'inflateBytes(' 就能让断言在代码没动时"通过"。
  var body = coreSrc.slice(dmAt).split('\n')
    .map(function (l) { return l.replace(/\/\/.*$/, ''); }).join('\n');
  var gateAt = body.indexOf('bodySize > MAX_BODY_SIZE');
  var callAt = body.indexOf('inflateBytes(payload');
  ok(gateAt >= 0, '源码顺序: decodeMap 里有 body_size 闸门');
  ok(callAt >= 0, '源码顺序: decodeMap 里有 inflateBytes(payload…) 调用点');
  ok(gateAt >= 0 && callAt >= 0 && gateAt < callAt,
     '源码顺序: body_size 闸门(偏移 ' + gateAt + ')早于解压调用(偏移 ' + callAt + ')');
})();

// ==== 断言区结束 ====

console.log('');
console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
if (fail === 0) console.log('SMOKE OK');
process.exit(fail === 0 ? 0 : 1);

})();
