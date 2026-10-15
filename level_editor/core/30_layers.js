// core/30_layers.js —— 单层编解码(纹理层 / 颜色层)。


const KIND_TEX = 1;
const KIND_COLOR = 2;

// ★ 索引 0 恒为空气:即使本层一个空气格都没有也要占住第 0 位,于是"空图 = 调色板 [0] + 全 0 索引流"无条件成立。
function encodeTexLayer(desc, subCols, subRows) {
  var n = subCols * subRows;
  if (desc.length !== n) {
    throw new Error('encodeTexLayer: desc 长度 ' + desc.length + ' ≠ subCols×subRows ' + n);
  }
  var pal = [DESC_AIR];
  var seen = new Map();
  seen.set(DESC_AIR, 0);
  var idx = new Uint32Array(n);
  for (var i = 0; i < n; i++) {
    var d = desc[i] >>> 0;
    var p = seen.get(d);
    if (p === undefined) {
      p = pal.length;
      // ★ 上界判在 push 之前且必须用 >=:此刻 p 是加入前的 pal.length,故合法条件是 p ≤ 65534(推导见 docs/eng/editor-core.md)。
      if (p >= 65535) throw new Error('encodeTexLayer: 调色板超过 65535 项(u16 上限)');
      pal.push(d);
      seen.set(d, p);
    }
    idx[i] = p;
  }
  var iw = pal.length <= 256 ? 1 : 2;
  var w = new ByteWriter(8 + pal.length * 4 + n * iw);
  w.u8(KIND_TEX);
  w.u16(pal.length);
  for (var k = 0; k < pal.length; k++) w.u32(pal[k]);
  w.u8(iw);
  if (iw === 1) { for (i = 0; i < n; i++) w.u8(idx[i]); }
  else { for (i = 0; i < n; i++) w.u16(idx[i]); }
  return w.finish();
}

function decodeTexLayer(r, subCols, subRows) {
  var kind = r.u8();
  if (kind !== KIND_TEX) throw new Error('decodeTexLayer: kind=' + kind + ',期望 ' + KIND_TEX);
  var palCount = r.u16();
  if (palCount === 0) throw new Error('decodeTexLayer: 调色板为空(索引 0 必须留给空气)');
  var pal = new Uint32Array(palCount);
  for (var k = 0; k < palCount; k++) pal[k] = r.u32();
  var iw = r.u8();
  if (iw !== 1 && iw !== 2) throw new Error('decodeTexLayer: index_width=' + iw + '(只允许 1 或 2)');
  var n = subCols * subRows;
  var desc = new Uint32Array(n);
  for (var i = 0; i < n; i++) {
    var p = iw === 1 ? r.u8() : r.u16();
    if (p >= palCount) throw new Error('decodeTexLayer: 索引 ' + p + ' 越出调色板 ' + palCount + ' 项');
    desc[i] = pal[p];
  }
  return { kind: 'tex', desc: desc };
}

// 背景层不做调色板:真彩,且平滑渐变恰好是 deflate 最擅长的一类数据(规格 §3.4)。
function encodeColorLayer(rgba, subCols, subRows) {
  var n = subCols * subRows;
  if (rgba.length !== n) {
    throw new Error('encodeColorLayer: rgba 长度 ' + rgba.length + ' ≠ subCols×subRows ' + n);
  }
  var w = new ByteWriter(5 + n * 4);
  w.u8(KIND_COLOR);
  for (var i = 0; i < n; i++) w.u32(rgba[i]);
  return w.finish();
}

function decodeColorLayer(r, subCols, subRows) {
  var kind = r.u8();
  if (kind !== KIND_COLOR) throw new Error('decodeColorLayer: kind=' + kind + ',期望 ' + KIND_COLOR);
  var n = subCols * subRows;
  var rgba = new Uint32Array(n);
  for (var i = 0; i < n; i++) rgba[i] = r.u32();
  return { kind: 'color', rgba: rgba };
}
