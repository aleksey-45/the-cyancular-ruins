// core/20_bytes.js —— 小端字节读写器与 CRC32。


// ── 字节读写器(一律小端)──
function ByteWriter(capacity) {
  this.buf = new Uint8Array(capacity || 256);
  this.len = 0;
}
ByteWriter.prototype._need = function (n) {
  if (this.len + n <= this.buf.length) return;
  var cap = this.buf.length;
  while (cap < this.len + n) cap *= 2;
  var nb = new Uint8Array(cap);
  nb.set(this.buf.subarray(0, this.len));
  this.buf = nb;
};
ByteWriter.prototype.u8 = function (v) {
  this._need(1); this.buf[this.len++] = v & 0xFF; return this;
};
ByteWriter.prototype.u16 = function (v) {
  this._need(2);
  this.buf[this.len++] = v & 0xFF;
  this.buf[this.len++] = (v >>> 8) & 0xFF;
  return this;
};
ByteWriter.prototype.u32 = function (v) {
  this._need(4);
  this.buf[this.len++] = v & 0xFF;
  this.buf[this.len++] = (v >>> 8) & 0xFF;
  this.buf[this.len++] = (v >>> 16) & 0xFF;
  this.buf[this.len++] = (v >>> 24) & 0xFF;
  return this;
};
ByteWriter.prototype.bytes = function (arr) {
  this._need(arr.length);
  this.buf.set(arr, this.len);
  this.len += arr.length;
  return this;
};
ByteWriter.prototype.finish = function () {
  return this.buf.slice(0, this.len);
};

function ByteReader(bytes) {
  this.b = bytes;
  this.p = 0;
}
ByteReader.prototype._need = function (n) {
  if (this.p + n > this.b.length) {
    throw new Error('ByteReader: 越界读(' + this.p + '+' + n + ' > ' + this.b.length + ')');
  }
};
ByteReader.prototype.u8 = function () {
  this._need(1); return this.b[this.p++];
};
ByteReader.prototype.u16 = function () {
  this._need(2);
  var v = this.b[this.p] | (this.b[this.p + 1] << 8);
  this.p += 2;
  return v >>> 0;
};
ByteReader.prototype.u32 = function () {
  this._need(4);
  var v = (this.b[this.p] | (this.b[this.p + 1] << 8) |
           (this.b[this.p + 2] << 16) | (this.b[this.p + 3] << 24)) >>> 0;
  this.p += 4;
  return v;
};
ByteReader.prototype.bytes = function (n) {
  this._need(n);
  var s = this.b.subarray(this.p, this.p + n);
  this.p += n;
  return s;
};
ByteReader.prototype.remaining = function () { return this.b.length - this.p; };

// ── CRC32(IEEE 802.3,多项式 0xEDB88320)──
const CRC_TABLE = (function () {
  var t = new Uint32Array(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(bytes) {
  var c = 0xFFFFFFFF;
  for (var i = 0; i < bytes.length; i++) {
    c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) >>> 0;
}
