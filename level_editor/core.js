globalThis.Core = (function () {
  'use strict';

  // ── 常量 ──
  const SUB_PER_CELL = 4;
  const SUB_PX = 16;               // 子格边长(世界像素)
  const CELL_PX = 64;
  const LAYER_COUNT = 4;
  const LAYER_FRONT = 0, LAYER_SCENE = 1, LAYER_BACK = 2, LAYER_BG = 3;
  const LAYER_NAMES = ['前景', '场景', '后景', '背景'];
  const LAYER_KINDS = ['tex', 'tex', 'tex', 'color'];

  // ── 地图对象 ──
  // 全部用 TypedArray:4 层 × 150k 子格若用嵌套 JS 数组会到几十 MB 且 GC 压力巨大。
  // 下标一律 = y * subCols + x(行主序),与文件里的排布一致。
  function createMap(name, cellsW, cellsH) {
    if (!Number.isInteger(cellsW) || !Number.isInteger(cellsH) || cellsW <= 0 || cellsH <= 0) {
      throw new Error('createMap: 格数必须是正整数,收到 ' + cellsW + '×' + cellsH);
    }
    var subCols = cellsW * SUB_PER_CELL;
    var subRows = cellsH * SUB_PER_CELL;
    var n = subCols * subRows;
    return {
      name: String(name == null ? '' : name),
      subCols: subCols,
      subRows: subRows,
      layers: [
        { kind: 'tex', desc: new Uint32Array(n) },
        { kind: 'tex', desc: new Uint32Array(n) },
        { kind: 'tex', desc: new Uint32Array(n) },
        { kind: 'color', rgba: new Uint32Array(n) },
      ],
      players: [],
      enemies: [],
      respawns: [],
      comments: [],
    };
  }
  function cellsWOf(map) { return map.subCols / SUB_PER_CELL; }
  function cellsHOf(map) { return map.subRows / SUB_PER_CELL; }
  function subIndex(subCols, X, Y) { return Y * subCols + X; }

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

  const KIND_TEX = 1;
  const KIND_COLOR = 2;
  const LEGACY_TEXTURES = globalThis.TILE_DEFS.legacy_texture_map;
  const MATERIAL_IDS = new Uint8Array(4096);
  for (var id of [...Object.keys(globalThis.TILE_DEFS.tiles), ...Object.keys(LEGACY_TEXTURES), 0]) {
    MATERIAL_IDS[id] = 1;
  }
  const RESPAWN_GUIDE_DIVISIONS = 3;

  function migrateDescriptor(desc) {
    var entry = LEGACY_TEXTURES[texOf(desc)];
    if (!entry) return desc;
    var hue = Math.max(0, Math.min(7, hueOf(desc) + entry.hue - HUE_NEUTRAL));
    return ((desc & ~((0xFFF << 12) | 7)) | (entry.base << 12) | hue) >>> 0;
  }

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
        if (p >= 65535) throw new Error('encodeTexLayer: 调色板超过 65535 项(u16 上限)');
        pal.push(migrateDescriptor(d));
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
    for (var k = 0; k < palCount; k++) pal[k] = migrateDescriptor(r.u32());
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

  function buildMeta(map) {
    var lines = [];
    var i;
    for (i = 0; i < map.comments.length; i++) lines.push('# ' + map.comments[i]);
    for (const p of map.players) {
      lines.push('# ' + (p.slot === 1 ? 'player' : 'player' + p.slot) + ' ' + p.x + ' ' + p.y);
    }
    for (i = 0; i < map.enemies.length; i++) {
      var e = map.enemies[i];
      lines.push('# enemy ' + e.type + ' ' + e.x + ' ' + e.y);
    }
    for (var r of map.respawns) {
      lines.push('# respawn ' + r.side + ' ' + r.x + ' ' + r.y);
    }
    return lines.length ? lines.join('\n') + '\n' : '';
  }

  // 解析失败的行降级为注释保留，避免丢失用户输入
  function parseMeta(text) {
    // 整数字面量(允许前导正负号)。用它而不是 isFinite,是为了拒绝 parseInt 的
    // 前缀截断:3.5 / 7abc / 1e3 / 0x10 都必须整行走降级路径。
    var INT_TOKEN = /^[+-]?\d+$/;
    var players = new Map(), enemies = [], respawns = [], comments = [];
    var lines = String(text == null ? '' : text).split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
      var s = lines[i].trim();
      if (s === '') continue;
      if (s.charAt(0) !== '#') { comments.push(s); continue; }
      var body = s.slice(1).trim();
      var parts = body.split(/\s+/);
      var head = parts[0];
      // 仅当 token 为整数字面量时才解析成功，避免 parseInt 截断非纯数字字符串
      if (/^player(?:[1-9]\d*)?$/.test(head) && parts.length === 3) {
        const slot = Number(head.slice(6) || 1);
        if (Number.isSafeInteger(slot) && INT_TOKEN.test(parts[1]) && INT_TOKEN.test(parts[2])) {
          players.set(slot, { slot, x: Number(parts[1]), y: Number(parts[2]) });
          continue;
        }
      } else if (head === 'enemy' && parts.length === 4) {
        if (INT_TOKEN.test(parts[2]) && INT_TOKEN.test(parts[3])) {
          enemies.push({ type: parts[1], x: parseInt(parts[2], 10), y: parseInt(parts[3], 10) });
          continue;
        }
      } else if (head === 'respawn' && parts.length === 4 && parts.slice(1).every(t => INT_TOKEN.test(t))) {
        var side = Number(parts[1]), x = Number(parts[2]), y = Number(parts[3]);
        if ((side === 1 || side === 2) && Number.isSafeInteger(x) && Number.isSafeInteger(y)) {
          respawns.push({ side: side, x: x, y: y });
          continue;
        }
      }
      comments.push(body);
    }
    return { players: Array.from(players.values()), enemies, respawns, comments };
  }

  function deflateBytes(bytes) {
    // 兼容性检查：确保运行环境包含 CompressionStream、Blob 与 Response
    if (typeof CompressionStream === 'undefined' || typeof Blob === 'undefined' ||
        typeof Response === 'undefined') {
      return Promise.reject(new Error(
        'deflateBytes: 本环境没有 CompressionStream/Blob/Response;请用 encodeMap(map, {compress:false}) 导出裸 body'));
    }
    var stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate'));
    return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
  }
  // 流式解压：限制解压输出最大字节数，防止超大解压数据耗尽内存
  function inflateBytes(bytes, maxBytes) {
    if (typeof DecompressionStream === 'undefined' || typeof Blob === 'undefined' ||
        typeof Response === 'undefined') {
      return Promise.reject(new Error('inflateBytes: 本环境没有 DecompressionStream/Blob/Response'));
    }
    var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
    if (maxBytes === undefined) {
      return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
    }
    var reader = stream.getReader();
    var chunks = [];
    var total = 0;
    function pump() {
      return reader.read().then(function (res) {
        if (res.done) {
          var out = new Uint8Array(total);
          var off = 0;
          for (var i = 0; i < chunks.length; i++) { out.set(chunks[i], off); off += chunks[i].length; }
          return out;
        }
        var chunk = res.value || new Uint8Array(0);
        total += chunk.length;
        // 校验解压输出累计大小，超限立即中止
        if (total > maxBytes) {
          var err = new Error('inflateBytes: 解压输出超过 ' + maxBytes + ' 字节上限(已累计 ' +
                              total + ' 字节),中止');
          reader.cancel().catch(function () {});
          throw err;
        }
        chunks.push(chunk);
        return pump();
      });
    }
    return pump();
  }

  const FORMAT_VERSION = 4;
  const HEADER_SIZE = 20;
  const MAGIC = [0x43, 0x59, 0x52, 0x4D];   // "CYRM"

  // 解压后数据体硬上限（64MB），防止超大解压数据耗尽内存
  const MAX_BODY_SIZE = 64 * 1024 * 1024;

  function layerFlags(map) {
    var f = 0;
    for (var L = 0; L < LAYER_COUNT; L++) if (map.layers[L]) f |= (1 << L);
    return f;
  }

  function encodeBody(map) {
    var metaBytes = new TextEncoder().encode(buildMeta(map));
    if (metaBytes.length > 65535) throw new Error('encodeBody: meta 超过 65535 字节');
    var w = new ByteWriter(64 + metaBytes.length);
    w.u16(metaBytes.length);
    w.bytes(metaBytes);
    for (var L = 0; L < LAYER_COUNT; L++) {
      var layer = map.layers[L];
      if (!layer) continue;                        // 缺层不写块,由 layer_flags 表达
      w.bytes(layer.kind === 'tex'
        ? encodeTexLayer(layer.desc, map.subCols, map.subRows)
        : encodeColorLayer(layer.rgba, map.subCols, map.subRows));
    }
    return w.finish();
  }

  function decodeBody(body, subCols, subRows, flags) {
    var r = new ByteReader(body);
    var metaLen = r.u16();
    var meta = parseMeta(new TextDecoder().decode(r.bytes(metaLen)));
    var layers = [];
    var n = subCols * subRows;
    for (var L = 0; L < LAYER_COUNT; L++) {
      if (!(flags & (1 << L))) { layers.push(null); continue; }
      var kind = LAYER_KINDS[L];
      // 防御损坏的文件头：根据本层剩余字节数粗估容量上界，避免非法尺寸触发异常大内存分配
      var room = r.remaining();
      var maxCells = kind === 'tex' ? room : ((room / 4) | 0);
      if (n > maxCells) {
        throw new Error('decodeBody: 图层 ' + L + '(' + kind + ')需要 ' + n + ' 个子格,但剩余 ' +
                        room + ' 字节最多只够 ' + maxCells + ' 个 —— 头部尺寸 ' +
                        subCols + '×' + subRows + ' 与 body 实际大小不符');
      }
      layers.push(kind === 'tex'
        ? decodeTexLayer(r, subCols, subRows)
        : decodeColorLayer(r, subCols, subRows));
    }
    if (r.remaining() !== 0) {
      throw new Error('decodeBody: 尾部还有 ' + r.remaining() + ' 字节未消费');
    }
    return {
      name: '', subCols: subCols, subRows: subRows, layers: layers,
      players: meta.players, enemies: meta.enemies, respawns: meta.respawns, comments: meta.comments,
    };
  }

  async function encodeMap(map, opts = {}) {
    const report = validateMap(map);
    if (report.errors.length) {
      throw new Error('encodeMap: 地图校验未通过 —— ' + report.errors.join(';'));
    }
    const body = encodeBody(map);
    const compress = opts.compress !== false;
    const payload = compress ? await deflateBytes(body) : body;
    const w = new ByteWriter(HEADER_SIZE + payload.length);
    for (const byte of MAGIC) w.u8(byte);
    w.u8(FORMAT_VERSION);
    w.u8(compress ? 1 : 0);
    w.u32(body.length);
    w.u32(crc32(body));
    w.u16(map.subCols);
    w.u16(map.subRows);
    w.u8(layerFlags(map));
    w.u8(0);
    w.bytes(payload);
    return w.finish();
  }

  async function decodeMap(bytes) {
    const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (data.length < HEADER_SIZE) throw new Error('decodeMap: 文件小于 20 字节');
    const r = new ByteReader(data);
    if (!MAGIC.every(byte => byte === r.u8())) throw new Error('decodeMap: magic 不是 "CYRM"');
    const version = r.u8();
    if (version !== FORMAT_VERSION) throw new Error('decodeMap: 不支持版本 ' + version);
    const compression = r.u8();
    const bodySize = r.u32();
    const expectedCrc = r.u32();
    const subCols = r.u16(), subRows = r.u16(), flags = r.u8();
    r.u8();  // 保留字段
    if (bodySize > MAX_BODY_SIZE) throw new Error('decodeMap: body_size 超过 64 MiB');
    if (!subCols || !subRows || subCols % SUB_PER_CELL || subRows % SUB_PER_CELL) {
      throw new Error('decodeMap: 非法尺寸 ' + subCols + '×' + subRows);
    }
    if (compression !== 0 && compression !== 1) throw new Error('decodeMap: 未知 compression=' + compression);
    const payload = r.bytes(data.length - HEADER_SIZE);
    const body = compression === 1 ? await inflateBytes(payload, bodySize) : payload;
    if (body.length !== bodySize) throw new Error('decodeMap: body_size 与实际大小不符');
    if (crc32(body) !== expectedCrc) throw new Error('decodeMap: CRC 不符');
    return decodeBody(body, subCols, subRows, flags);
  }

  async function importMap(bytes) {
    const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (MAGIC.every((byte, i) => data[i] === byte)) {
      return { map: await decodeMap(data), format: 'v4' };
    }
    if (data.length > MAX_BODY_SIZE) throw new Error('旧地图超过 64 MiB');
    return importTextMap(new TextDecoder('utf-8', { fatal: true }).decode(data));
  }

  function importTextMap(text) {
    var rows = [], meta = [], version = 0;
    for (var line of text.split(/\r?\n/)) {
      line = line.trim();
      if (!line) continue;
      var marker = /^#\s*cyrm-v(\d+)(?:\s|$)/.exec(line);
      if (marker) {
        version = Number(marker[1]);
        if (version !== 3) throw new Error('无法导入文本地图版本 ' + version);
      } else if (line.startsWith('#')) meta.push(line);
      else rows.push(line);
    }
    var v3 = version === 3;
    var width = rows.length ? rows[0].length : 0;
    var rowPattern = v3 ? /^(?:\d{3}[0-9a-f])+$/i : /^[0-9a]+$/i;
    if (!width || rows.some(row => row.length !== width || !rowPattern.test(row))) {
      throw new Error('旧地图网格为空、行宽不齐或含无效字符');
    }
    if (!v3 && (width % 2 || rows.length % 2)) throw new Error('字符地图的宽和高必须为偶数');
    var w = width / (v3 ? 4 : 2), h = rows.length / (v3 ? 1 : 2);
    if (w > MAX_CELLS_W || h > MAX_CELLS_H) throw new Error('旧地图尺寸超过编辑器上限');
    var map = Object.assign(createMap('', w, h), parseMeta(meta.join('\n')));
    var scene = map.layers[LAYER_SCENE].desc;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var tex = 0, shape = 0;
        if (v3) {
          tex = Number(rows[y].slice(x * 4, x * 4 + 3));
          shape = parseInt(rows[y][x * 4 + 3], 16);
        } else {
          for (var q = 0; q < 4; q++) {
            var value = parseInt(rows[y * 2 + (q >> 1)][x * 2 + (q & 1)], 16);
            if (!value) continue;
            shape |= 1 << q;
            if (!tex) tex = value;
          }
        }
        if (!tex || !shape) continue;
        var desc = migrateDescriptor(neutralDesc(tex));
        for (var sy = 0; sy < SUB_PER_CELL; sy++) {
          for (var sx = 0; sx < SUB_PER_CELL; sx++) {
            if (shape & (1 << ((sy >> 1) * 2 + (sx >> 1)))) {
              scene[(y * SUB_PER_CELL + sy) * map.subCols + x * SUB_PER_CELL + sx] = desc;
            }
          }
        }
      }
    }
    if (!v3) {
      for (var point of [...map.players, ...map.enemies, ...map.respawns]) {
        point.x = Math.floor(point.x / 2);
        point.y = Math.floor(point.y / 2);
      }
    }
    return { map, format: v3 ? 'v3' : 'legacy' };
  }

  function subcellRender(X, Y) {
    var qx = X % SUB_PER_CELL, qy = Y % SUB_PER_CELL;
    return { dst: [X * SUB_PX, Y * SUB_PX, SUB_PX, SUB_PX],
             src: [qx * (32 / SUB_PER_CELL), qy * (32 / SUB_PER_CELL),
                   32 / SUB_PER_CELL, 32 / SUB_PER_CELL] };
  }

  const MAX_CELLS_W = 400;
  const MAX_CELLS_H = 300;
  const DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;

  function clampMapSize(w, h) {
    var wi = parseInt(w, 10), hi = parseInt(h, 10);
    if (!isFinite(wi)) wi = DEFAULT_CELLS_W;
    if (!isFinite(hi)) hi = DEFAULT_CELLS_H;
    return {
      w: Math.max(1, Math.min(MAX_CELLS_W, wi)),
      h: Math.max(1, Math.min(MAX_CELLS_H, hi)),
    };
  }

  function validateMap(map) {
    var errors = [], warnings = [];
    if (!map || !map.layers || map.layers.length !== LAYER_COUNT) {
      errors.push('图层数不是 ' + LAYER_COUNT);
      return { errors: errors, warnings: warnings };
    }
    if (map.subCols <= 0 || map.subRows <= 0 ||
        map.subCols % SUB_PER_CELL !== 0 || map.subRows % SUB_PER_CELL !== 0) {
      errors.push('尺寸 ' + map.subCols + '×' + map.subRows + ' 必须是正数且为 ' + SUB_PER_CELL + ' 的倍数');
    }
    if (map.layers[LAYER_SCENE]?.kind !== 'tex') {
      errors.push('地图缺少场景层');
    }
    var n = map.subCols * map.subRows;
    var L, layer;
    for (L = 0; L < LAYER_COUNT; L++) {
      layer = map.layers[L];
      if (!layer) continue;
      var arr = layer.kind === 'tex' ? layer.desc : layer.rgba;
      if (!arr || arr.length !== n) {
        errors.push(LAYER_NAMES[L] + '层长度不是 ' + map.subCols + '×' + map.subRows);
      } else if (layer.kind === 'tex') {
        var unknown = new Set();
        for (var i = 0; i < arr.length; i++) {
          var tex = texOf(arr[i]);
          if (!MATERIAL_IDS[tex]) unknown.add(tex);
        }
        if (unknown.size) errors.push(LAYER_NAMES[L] + '层使用了未定义材质 ' + Array.from(unknown).join('、'));
      }
    }
    if (errors.length) return { errors: errors, warnings: warnings };

    var cellsW = map.subCols / SUB_PER_CELL, cellsH = map.subRows / SUB_PER_CELL;
    var scene = map.layers[LAYER_SCENE].desc;

    // 出生点
    if (map.players.length === 0) {
      warnings.push('一个出生点都没有');
    }
    var playerSlots = new Set();
    for (const p of map.players) {
      if (!Number.isSafeInteger(p.slot) || p.slot < 1 || playerSlots.has(p.slot)) {
        errors.push('玩家出生点编号无效或重合：' + p.slot);
        continue;
      }
      playerSlots.add(p.slot);
      if (p.slot > 2) warnings.push('游戏不使用出生点 P' + p.slot);
      _checkSpawn(p, '出生点 P' + p.slot, cellsW, cellsH, scene, warnings, p.slot <= 2 ? errors : warnings);
    }
    var i;
    for (i = 0; i < map.enemies.length; i++) {
      _checkSpawn(map.enemies[i], '敌人 ' + map.enemies[i].type, cellsW, cellsH, scene, warnings, errors);
    }
    var respawnCells = new Set();
    for (var r of map.respawns) {
      _checkSpawn(r, '侧 ' + r.side + ' 复活点', cellsW, cellsH, null, warnings);
      var cell = r.x + ',' + r.y;
      if (respawnCells.has(cell)) warnings.push('复活点 (' + cell + ') 重合');
      respawnCells.add(cell);
    }
    for (var comment of map.comments) {
      if (/^respawn(?:\s|$)/.test(comment)) warnings.push('复活点格式无效：' + comment);
      if (/^(player2?|enemy)(?:\s|$)/.test(comment.trim())) errors.push('点位元数据格式无效：' + comment);
    }
    if (map.respawns.length) checkRespawnDistribution(map.respawns, cellsW, cellsH, warnings);

    // 四层全空
    var allEmpty = true;
    for (L = 0; L < LAYER_COUNT && allEmpty; L++) {
      layer = map.layers[L];
      if (!layer) continue;
      var a = layer.kind === 'tex' ? layer.desc : layer.rgba;
      for (var k = 0; k < a.length; k++) if (a[k] !== 0) { allEmpty = false; break; }
    }
    if (allEmpty) warnings.push('四个图层全是空的');

    return { errors: errors, warnings: warnings };
  }

  function checkRespawnDistribution(points, w, h, warnings) {
    var half = w / 2, divisions = RESPAWN_GUIDE_DIVISIONS;
    var wrapDistance = (a, b, size) => Math.min(Math.abs(a - b), size - Math.abs(a - b));
    for (var side of [1, 2]) {
      var label = '侧 ' + side + ' 复活点';
      var pool = points.filter(p => p.side === side && p.x >= 0 && p.y >= 0 && p.x < w && p.y < h);
      if (pool.length < 5) warnings.push(label + '少于 5 个');
      var left = (side - 1) * half;
      var inside = pool.filter(p => p.x >= left && p.x < left + half);
      if (inside.length !== pool.length) warnings.push(label + '有点位落在另一半区');
      if (half >= 20 && inside.some(p => Math.min(p.x - left, left + half - p.x) < 10)) {
        warnings.push(label + '有点位离中线或接缝不足 10 格');
      }
      if (pool.some((a, i) => {
        for (var j = i + 1; j < pool.length; j++) {
          var b = pool[j];
          if (Math.max(wrapDistance(a.x, b.x, w), wrapDistance(a.y, b.y, h)) < 5) return true;
        }
        return false;
      })) warnings.push(label + '存在间距不足 5 格的点位');
      if (half >= divisions && h >= divisions) {
        var regions = new Set(inside.map(p =>
          Math.floor((p.x - left) * divisions / half) + ',' + Math.floor(p.y * divisions / h)));
        if (regions.size < divisions ** 2) warnings.push(label + '在 3×3 标线中仍有空区');
      }
    }
  }

  // 游戏启动依赖的点位坐标错误阻止导出。实心格和团队点位问题仍提示。
  function _checkSpawn(pt, label, cellsW, cellsH, sceneDesc, warnings, coordinateIssues = warnings) {
    if (!Number.isSafeInteger(pt.x) || !Number.isSafeInteger(pt.y)) {
      coordinateIssues.push(label + ' 坐标必须是整数');
      return;
    }
    if (pt.x < 0 || pt.y < 0 || pt.x >= cellsW || pt.y >= cellsH) {
      coordinateIssues.push(label + ' 坐标 (' + pt.x + ',' + pt.y + ') 越界(地图是 ' + cellsW + '×' + cellsH + ' 格)');
      return;
    }
    if (!sceneDesc) return;
    // 「场景」层该格 4×4 子格全非空才算实心
    var subCols = cellsW * SUB_PER_CELL;
    var solid = true;
    for (var dy = 0; dy < SUB_PER_CELL && solid; dy++) {
      for (var dx = 0; dx < SUB_PER_CELL; dx++) {
        if (sceneDesc[(pt.y * SUB_PER_CELL + dy) * subCols + (pt.x * SUB_PER_CELL + dx)] === 0) {
          solid = false; break;
        }
      }
    }
    if (solid) warnings.push(label + ' 落在实心格里(场景层该格被填满)');
  }

  // ── 与格式无关的纯工具(自旧编辑器沿用)──
  function sanitizeName(name) {
    var n = String(name == null ? '' : name).trim();
    n = n.replace(/\s+/g, '_');
    n = n.replace(/[^A-Za-z0-9_一-龥-]/g, '');
    n = n.replace(/^-+/, '');
    if (n.length > 32) n = n.slice(0, 32);
    return n === '' ? 'structure' : n;
  }

  // 画笔块偏移:以指针格为中心的上下/左右扩展量,保证 lo+1+hi===size。
  // 奇数尺寸对称;偶数尺寸偏下右(否则偶数会缩水一格)。
  function brushOffsets(size) {
    return { lo: Math.floor((size - 1) / 2), hi: Math.ceil((size - 1) / 2) };
  }

  // Bresenham 直线路径格坐标(含两端)。
  function lineCells(x0, y0, x1, y1) {
    var cells = [];
    var dx = Math.abs(x1 - x0), dy = Math.abs(y1 - y0);
    var sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    var err = dx - dy;
    var x = x0, y = y0;
    for (;;) {
      cells.push([x, y]);
      if (x === x1 && y === y1) break;
      var e2 = 2 * err;
      if (e2 > -dy) { err -= dy; x += sx; }
      if (e2 < dx) { err += dx; y += sy; }
    }
    return cells;
  }

  // 矩形区域归一化:任意两角点 → {x, y, w, h}(含两端)。
  function normRegion(x0, y0, x1, y1) {
    return { x: Math.min(x0, x1), y: Math.min(y0, y1),
             w: Math.abs(x1 - x0) + 1, h: Math.abs(y1 - y0) + 1 };
  }

  const DESC_AIR = 0;
  const TEXTURE_MAX = 4095;
  const HUE_NEUTRAL = 4, BRI_NEUTRAL = 4, SAT_NEUTRAL = 4, ALPHA_NEUTRAL = 7;

  // 打包成 u32。纹理不在 1..TEXTURE_MAX 内一律当空气(含 0 与负数)。
  function packDesc(texture, hue, bright, sat, alpha) {
    texture = texture | 0;
    if (texture <= 0 || texture > TEXTURE_MAX) return DESC_AIR;
    return (((hue & 7)) |
            ((bright & 7) << 3) |
            ((sat & 7) << 6) |
            ((alpha & 7) << 9) |
            (texture << 12)) >>> 0;
  }
  function texOf(d)    { return (d >>> 12) & 0xFFF; }
  function hueOf(d)    { return d & 7; }
  function brightOf(d) { return (d >>> 3) & 7; }
  function satOf(d)    { return (d >>> 6) & 7; }
  function alphaOf(d)  { return (d >>> 9) & 7; }
  function isAir(d)    { return d === DESC_AIR; }

  // 中性描述符：完全按原图渲染，不应用调色。alpha 中性档为 7，其余通道为 4
  function neutralDesc(texture) {
    return packDesc(texture, HUE_NEUTRAL, BRI_NEUTRAL, SAT_NEUTRAL, ALPHA_NEUTRAL);
  }

  return {
    SUB_PER_CELL: SUB_PER_CELL,
    SUB_PX: SUB_PX,
    CELL_PX: CELL_PX,
    DESC_AIR: DESC_AIR,
    TEXTURE_MAX: TEXTURE_MAX,
    LAYER_COUNT: LAYER_COUNT, RESPAWN_GUIDE_DIVISIONS: RESPAWN_GUIDE_DIVISIONS,
    LAYER_FRONT: LAYER_FRONT, LAYER_SCENE: LAYER_SCENE,
    LAYER_BACK: LAYER_BACK, LAYER_BG: LAYER_BG,
    LAYER_NAMES: LAYER_NAMES, LAYER_KINDS: LAYER_KINDS,
    createMap: createMap, cellsWOf: cellsWOf, cellsHOf: cellsHOf, subIndex: subIndex,
    sanitizeName: sanitizeName, brushOffsets: brushOffsets,
    lineCells: lineCells, normRegion: normRegion,
    ByteWriter: ByteWriter, ByteReader: ByteReader, crc32: crc32,
    KIND_TEX: KIND_TEX, KIND_COLOR: KIND_COLOR,
    encodeTexLayer: encodeTexLayer, decodeTexLayer: decodeTexLayer,
    encodeColorLayer: encodeColorLayer, decodeColorLayer: decodeColorLayer,
    buildMeta: buildMeta, parseMeta: parseMeta,
    HUE_NEUTRAL: HUE_NEUTRAL, BRI_NEUTRAL: BRI_NEUTRAL,
    SAT_NEUTRAL: SAT_NEUTRAL, ALPHA_NEUTRAL: ALPHA_NEUTRAL,
    packDesc: packDesc,
    migrateDescriptor: migrateDescriptor,
    texOf: texOf, hueOf: hueOf, brightOf: brightOf, satOf: satOf, alphaOf: alphaOf,
    isAir: isAir, neutralDesc: neutralDesc,
    FORMAT_VERSION: FORMAT_VERSION, HEADER_SIZE: HEADER_SIZE,
    MAX_BODY_SIZE: MAX_BODY_SIZE,
    deflateBytes: deflateBytes, inflateBytes: inflateBytes,
    encodeMap: encodeMap, decodeMap: decodeMap, layerFlags: layerFlags,
    importMap: importMap,
    subcellRender: subcellRender,
    MAX_CELLS_W: MAX_CELLS_W, MAX_CELLS_H: MAX_CELLS_H,
    clampMapSize: clampMapSize, validateMap: validateMap,
  };
})();
