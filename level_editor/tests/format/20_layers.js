'use strict';
// tests/format/20_layers.js —— 纹理层 / 背景层块编解码、多字节索引与调色板上界、畸形描述符。
const Core = globalThis.Core;

module.exports = (async function () {
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

  var r2 = new Core.ByteReader(enc);
  r2.u8();                       // kind
  // ★ 顺序读的字节流:先 push 保序,再一条表比(D9)。
  {
    const pal2 = [];
    pal2.push(['调色板 3 项', r2.u16(), 3]);
    pal2.push(['调色板[0] 是空气', r2.u32(), 0]);
    pal2.push(['调色板[1]', r2.u32(), brick]);
    pal2.push(['调色板[2]', r2.u32(), moss]);
    tableEq('纹理层:调色板按顺序写/读', pal2);
  }
  eq(r2.u8(), 1, '纹理层: 调色板 ≤256 项 → index_width = 1');
  eq(enc.length, 1 + 2 + 3 * 4 + 1 + n, '纹理层: 总长度 = 头 + 调色板 + 索引流');

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

  throws(function () { Core.encodeTexLayer(new Uint32Array(5), 4, 4); }, 'encodeTexLayer: 长度不符报错', 'desc 长度');
  // 越界索引要抛错而不是静默
  var bad = new Uint8Array([Core.KIND_TEX, 1, 0, 0, 0, 0, 0, 1, 99]);   // 调色板 1 项,索引 99
  throws(function () { Core.decodeTexLayer(new Core.ByteReader(bad), 1, 1); }, 'decodeTexLayer: 索引越界报错', '越出调色板');
  throws(function () { Core.decodeTexLayer(new Core.ByteReader(new Uint8Array([9])), 1, 1); }, 'decodeTexLayer: 错 kind 报错', 'decodeTexLayer: kind=');
})();

// ---- 双字节索引(index_width = 2)与调色板上界(指令 A2)----
// ★ iw = 2 是真实的层分支(描述符种类 > 256 的层都会走它),不是罕见路径;下面的 distinctDesc 自证两两不同。
await (async function () {
  // 第 i 个非空气描述符:纹理 1..4095 循环,再用 (hue, bright) 区分档,共 4095×64 种 ≫ 65535。
  function distinctDesc(i) {
    var block = (i / 4095) | 0;
    return Core.packDesc(1 + (i % 4095), block & 7, (block >> 3) & 7, 4, 7);
  }
  // ★ 自证 distinctDesc 真的两两不同 —— 否则"300 种不同描述符"是假的,调色板缩回 ≤256 项、双字节路径根本不会被触发,而断言照样全绿。
  var PROBE_N = 17 * 4095;                 // 覆盖下界测试用到的全部 (texture, block) 组合
  var probe = new Set();
  for (var q = 0; q < PROBE_N; q++) probe.add(distinctDesc(q));
  eq(probe.size, PROBE_N, 'A2: distinctDesc 在 ' + PROBE_N + ' 个 i 上两两不同(构造前提自证;69615 > 256 ⇒ 走得到双字节索引)');

  // ── ① 300 种描述符 → index_width 必须是 2,往返逐格一致,长度与手算公式相符 ──
  var subCols = 20, subRows = 16, n = subCols * subRows;    // 320 个子格:放得下 300 种 + 空气,余 20 格
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
  // 逐格比对还不够强:把 300 种各自点名抽查一遍,区分出"索引整体串位"这类错。
  var allOk = true, badAt = -1;
  for (i = 0; i < 300; i++) if (backL.desc[i] !== distinctDesc(i)) { allOk = false; badAt = i; break; }
  ok(allOk, 'A2: 300 种描述符各自按位置回读正确' + (badAt < 0 ? '' : '(首个失败 i=' + badAt + ')'));
  eq(backL.desc[300], 0, 'A2: 第 301 格是空气(索引 0,没被串到别处)');

  // ── ② 整文件往返也要真的走通 iw = 2 ──
  // 300 种放在前景层且不带 meta ⇒ 层0 块在文件里的偏移固定,可直接读它的 palette_count / index_width。
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
  // palette_count 是 u16(最大 65535),而索引 0 必须留给空气 ⇒ 非空气描述符上限恰好 65534 种;两条都取恰好那一格。
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

  // 65536 项时 pal.length 到 65536 ⇒ w.u16 按位截断成 0 ⇒ 解码端"调色板为空"(编码器产出自己的解码器拒绝的文件):必须在 push 之前就拒。
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

// ---- descriptor 位域 vs 任意字节:解码路径不许用 isAir 判空气 ----
// ★ isAir(d) 是 d === 0 的严格相等,而解码读的是任意字节:畸形描述符(纹理 0 而辅码非 0)会让 isAir(d) 与 texOf(d) === 0 结论相反,解码路径必须按 texOf(d) 判空气。
await (async function () {
  var malformed = 0x000007FF;                    // 纹理 0,但色相/亮度/饱和度三位全 1
  eq(Core.texOf(malformed), 0, '任意字节: texOf(0x7FF) === 0(纹理位域为 0)');
  eq(Core.isAir(malformed), false, '任意字节: isAir(0x7FF) === false(整体不等 0)—— 两者结论相反');

  var g = Core.createMap('x', 1, 1);
  g.layers[0].desc[5] = malformed;
  var bytes = await Core.encodeMap(g, { compress: false });
  var back = await Core.decodeMap(bytes);
  eq(back.layers[0].desc[5], malformed, '任意字节: 畸形描述符原样穿过整文件往返(不被折成空气)');
  eq(Core.texOf(back.layers[0].desc[5]), 0, '任意字节: 回读后仍应判 texOf === 0');
  eq(back.layers[1].desc[5], 0, '任意字节: 真空气格仍是 0');
})();

})();
