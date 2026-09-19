// core.js —— `.cyrm` v4 数据模型 + 二进制编解码 + v3 迁移 + 校验。
// ★ 纯逻辑,不引用任何 DOM API:必须能被 node 直接 new Function(src)() 求值(smoke.js 就是这么跑的)。
// ★ 格式规格:docs/superpowers/specs/2026-09-19-cyrm-v4-editor-design.md §2 / §3。
//   v3 packed = texture*16 + shape 与 v4 descriptor 是两种完全不同的编码 —— 本文件里
//   _v3Pack / _v3TexOf / _v3ShapeOf 专管前者,packDesc / texOf 专管后者,不得混用。
globalThis.Core = (function () {
  'use strict';

  // ── 常量 ──
  const SUB_PER_CELL = 4;          // 每 64px 格细分成 4×4 个 16px 子格(规格 §2.1)
  const SUB_PX = 16;               // 子格边长(世界像素)
  const CELL_PX = 64;              // 格边长(世界像素)

  // ── 图层(规格 §2.1)──
  // 顺序从外到内:前景 / 场景 / 后景 / 背景。只有「场景」参与碰撞。
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

  // ── 层块种类(规格 §3.3 / §3.4)──
  const KIND_TEX = 1;
  const KIND_COLOR = 2;

  // 纹理层块:kind(1) + 调色板 + 索引流(规格 §3.3)。
  // ★ 索引 0 恒为空气 —— 即使本层一个空气格都没有,也要占住第 0 位,
  //   这样"空图 = 调色板 [0] + 全 0 索引流"是一条无条件成立的不变量。
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
        if (p > 65535) throw new Error('encodeTexLayer: 调色板超过 65535 项');
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

  // 背景层块:kind(2) + 逐格 RGBA8888(规格 §3.4)。
  // 不做调色板 —— 背景是真彩,而平滑渐变恰好是 deflate 最擅长的一类数据。
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

  // ── meta 文本(规格 §3.2)──
  // 形状就是今天那几行 `# ...` 注释:deflate 压得掉,而且游戏侧
  // MapFormat.parse_spawn_metadata() 零改动就能继续用。
  // 本函数输出:先注释,再出生点(player / player2 / player3…),最后敌人。
  function buildMeta(map) {
    var lines = [];
    var i;
    for (i = 0; i < map.comments.length; i++) lines.push('# ' + map.comments[i]);
    for (i = 0; i < map.players.length; i++) {
      var kw = i === 0 ? 'player' : (i === 1 ? 'player2' : 'player' + (i + 1));
      lines.push('# ' + kw + ' ' + map.players[i].x + ' ' + map.players[i].y);
    }
    for (i = 0; i < map.enemies.length; i++) {
      var e = map.enemies[i];
      lines.push('# enemy ' + e.type + ' ' + e.x + ' ' + e.y);
    }
    return lines.length ? lines.join('\n') + '\n' : '';
  }

  // 解析失败(坐标不是整数、坐标个数不够)的行**降级成注释**而不是丢掉 ——
  // 编辑器不许静默吃掉用户写的东西。
  function parseMeta(text) {
    // 整数字面量(允许前导正负号)。用它而不是 isFinite,是为了拒绝 parseInt 的
    // 前缀截断:3.5 / 7abc / 1e3 / 0x10 都必须整行走降级路径。
    var INT_TOKEN = /^[+-]?\d+$/;
    var players = [], enemies = [], comments = [];
    var lines = String(text == null ? '' : text).split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
      var s = lines[i].trim();
      if (s === '') continue;
      if (s.charAt(0) !== '#') { comments.push(s); continue; }
      var body = s.slice(1).trim();
      var parts = body.split(/\s+/);
      var head = parts[0];
      // ★ 成功条件必须是「token 本身是整数字面量」,不能只判 isFinite ——
      //   parseInt('3.5')===3 / parseInt('7abc')===7 / parseInt('1e3')===1 全都不是 NaN,
      //   只判 isFinite 会把 "# player 3.5 4" 静默改写成 "# player 3 4",原文被吃掉。
      if (/^player\d*$/.test(head) && parts.length >= 3) {
        if (INT_TOKEN.test(parts[1]) && INT_TOKEN.test(parts[2])) {
          players.push({ x: parseInt(parts[1], 10), y: parseInt(parts[2], 10) });
          continue;
        }
      } else if (head === 'enemy' && parts.length >= 4) {
        if (INT_TOKEN.test(parts[2]) && INT_TOKEN.test(parts[3])) {
          enemies.push({ type: parts[1], x: parseInt(parts[2], 10), y: parseInt(parts[3], 10) });
          continue;
        }
      }
      comments.push(body);
    }
    return { players: players, enemies: enemies, comments: comments };
  }

  // ── 压缩(规格 §3.5)──
  // 用运行时原生的 CompressionStream('deflate') —— 产出 zlib(RFC1950)格式,
  // 与 Godot 侧 PackedByteArray.decompress(n, COMPRESSION_DEFLATE) 对应。
  // ★ 刻意不自造压缩器:自己写 RLE 就要自己写解压器,而解压器写错是那种
  //   "大部分时候对、偶尔静默出错"的 bug。
  function deflateBytes(bytes) {
    if (typeof CompressionStream === 'undefined' || typeof Blob === 'undefined') {
      return Promise.reject(new Error(
        'deflateBytes: 本环境没有 CompressionStream/Blob;请用 encodeMap(map, {compress:false}) 导出裸 body'));
    }
    var stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate'));
    return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
  }
  // 流式解压,累计输出超过 maxBytes 就中止并拒绝。
  // maxBytes 缺省 = 不设限(向后兼容;本仓唯一调用方是 decodeMap,它会传 MAX_BODY_SIZE)。
  // ★ 为什么不能只靠文件头里的 body_size:那个字段**本身也是攻击者可控的** —— 把它谎报成
  //   一个通过闸门的小值(比如 4096)、而 deflate 流里塞真炸弹,则「判在解压之前」那道闸
  //   完全挡不住:new Response(stream).arrayBuffer() 会**先把整份解压结果分配出来**,
  //   判在后面的长度比对处等于拒是拒了、内存已经花掉了。DEFLATE 单流最大压缩比 ≈ 1032:1
  //   ⇒ 64KB 的 .cyrm 能解出 ≈64MB、1MB 的能解出 ≈1GB(arrayBuffer 的峰值还约等于输出的
  //   2 倍)—— **结果无界、输入有界**。所以上界必须作用在**实际输出**上。
  function inflateBytes(bytes, maxBytes) {
    if (typeof DecompressionStream === 'undefined' || typeof Blob === 'undefined') {
      return Promise.reject(new Error('inflateBytes: 本环境没有 DecompressionStream/Blob'));
    }
    var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
    // ★ 不传 maxBytes = 不设限:走原来那条一条龙实现,返回语义与旧版逐字一致 ——
    //   「不设限」不另造一条分块路径,免得给"向后兼容"这句承诺多留一条会漂的分支。
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
        // ★ 判在 push **之前**:超限的那一块根本不留下 —— "先收后判"等于已经把超限数据存住了。
        //   错误信息带上上限值与已累计字节数,便于诊断是"文件坏了"还是"真炸弹"。
        if (total > maxBytes) {
          var err = new Error('inflateBytes: 解压输出超过 ' + maxBytes + ' 字节上限(已累计 ' +
                              total + ' 字节),中止');
          return reader.cancel().then(function () { throw err; }, function () { throw err; });
        }
        chunks.push(chunk);
        return pump();
      });
    }
    return pump();
  }

  // ── 整文件容器(规格 §3.1 / §3.2)──
  const FORMAT_VERSION = 4;
  const HEADER_SIZE = 20;
  const MAGIC = [0x43, 0x59, 0x52, 0x4D];   // "CYRM"

  // ── 解压后 body 的硬上限「解压后大小上限」/ MAX_BODY_SIZE(指令 D)──
  // ★ 它堵的是 **deflate 炸弹**:deflate 的最大压缩比约 1032:1 ⇒ **几十 KB** 的
  //   恶意/损坏文件就能解出 **GB 级**内存。而它**完全不碰头部字段**(magic / 版本 /
  //   尺寸 / CRC 全合法),所以下面 decodeBody 里那条「按 body 实际余量反推格数上界」
  //   的检查对它**天然无效** —— 那条管的是「头部声称的尺寸大于 body 装得下的量」,
  //   炸弹是反过来的:声明的 body 很小、解出来极大。故必须拿**头部声明的解压后大小**
  //   单独设一道闸,且判在**任何解压动作之前**:判在解压之后等于拒是拒了、
  //   内存已经先分配出去了。
  // ★ 64MB 是怎么来的 —— 合法文件最坏就多大:上限尺寸 400×300 格 = 1600×1200 子格
  //   = 1,920,000 子格(n),四层全在、且全都取到最坏编码:
  //     背景层(颜色)  1 + 4n                        = 1 + 7,680,000   ≈ 7.68MB
  //     三个纹理层各   1+2+4×调色板+1+2n,调色板 ≤65535 ⇒ 4 + 262,140 + 2n
  //                                                 = 4,102,144  ≈ 4.10MB → ×3 ≈ 12.31MB
  //     meta          2 + 65535(u16 长度字段的上限)                    ≈ 0.07MB
  //   合计 20,051,970 字节 ≈ 19.1MiB。取 64MB(67,108,864)= 它的 ≈3.3 倍:
  //   对**任何**合法文件都不可能误拒,对炸弹则是一道明确的硬闸。
  // ★ 这个常量今天用在**两道**闸上,两道都不可省(只留一道就会漏掉半个炸弹面):
  //     ① decodeMap 里「头部声明的 body_size」—— 挡"声明侧"的炸弹(头部就写着 2GB);
  //     ② inflateBytes 的 maxBytes —— 挡"谎报声明 + 真炸弹"(声明很小、解出来极大),
  //        它是作用在**实际输出**上的那一道。详见 inflateBytes 上方注释。
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
      // ★ 防「损坏的文件头触发巨量分配」:CRC32 只覆盖 body、**不覆盖文件头**,
      //   所以头部的 sub_cols / sub_rows 是**未经验证**的 —— 一枚翻错的头字节就能
      //   让格数到 65532×65532 ≈ 43 亿(解压成功 / body_size 相符 / CRC 相符 三关全照过),
      //   然后 decodeTexLayer 里那句 new Uint32Array(n) 就是一次 ≈17GB 的分配。
      //   用「本层剩余字节数」反推格数的上界 —— 纹理层每格至少 1 字节索引、
      //   颜色层每格 4 字节 RGBA,所以剩余字节数本身就是**任何一层都不可能超过**的粗筛上界
      //   (纹理层的每格下限更低,统一拿它当粗筛即可)。**不需要精确,只需要不可能通过**。
      //   ★ 必须判在 new Uint32Array(n) **之前** —— 判在后面等于拒是拒了、内存已经分配出去了。
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
      players: meta.players, enemies: meta.enemies, comments: meta.comments,
    };
  }

  // opts.compress 默认 true;传 false 走裸 body(compress=0),用来兜住
  // "两端 deflate 实现对不上"这类风险,是一条完整可用的路径而不是半成品。
  function encodeMap(map, opts) {
    opts = opts || {};
    var body, payload, compression;
    try {
      body = encodeBody(map);
    } catch (e) {
      return Promise.reject(e);
    }
    var compress = opts.compress !== false;
    var pre = compress ? deflateBytes(body) : Promise.resolve(body);
    return pre.then(function (p) {
      payload = p;
      compression = compress ? 1 : 0;
      var w = new ByteWriter(HEADER_SIZE + payload.length);
      w.u8(MAGIC[0]); w.u8(MAGIC[1]); w.u8(MAGIC[2]); w.u8(MAGIC[3]);
      w.u8(FORMAT_VERSION);
      w.u8(compression);
      w.u32(body.length);          // ★ 解压后的大小
      w.u32(crc32(body));
      w.u16(map.subCols);
      w.u16(map.subRows);
      w.u8(layerFlags(map));
      w.u8(0);
      w.bytes(payload);
      return w.finish();
    });
  }

  function decodeMap(bytes) {
    return new Promise(function (resolve) { resolve(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)); })
      .then(function (b) {
        if (b.length < HEADER_SIZE) throw new Error('decodeMap: 文件只有 ' + b.length + ' 字节,小于头部 20 字节');
        var r = new ByteReader(b);
        if (r.u8() !== MAGIC[0] || r.u8() !== MAGIC[1] || r.u8() !== MAGIC[2] || r.u8() !== MAGIC[3]) {
          throw new Error('decodeMap: magic 不是 "CYRM"');
        }
        var version = r.u8();
        if (version !== FORMAT_VERSION) {
          throw new Error('decodeMap: 版本 ' + version + ',本编辑器只认 ' + FORMAT_VERSION);
        }
        var compression = r.u8();
        var bodySize = r.u32();
        var expectCrc = r.u32();
        var subCols = r.u16(), subRows = r.u16();
        var flags = r.u8();
        r.u8();
        // ★ 指令 D:先判「头部声明的解压后大小」,再碰 payload —— 解压是把攻击者给的
        //   字节变成内存的**那一步**,判在它后面就等于没判(内存已经分配出去了)。
        //   放在这里而不是放进更下面那段 body 长度比对里,正是因为这个顺序要求。
        //   ★ 这条顺序本身有断言钉住:smoke.js 的「源码顺序」那组读本文件比位置
        //     (闸门必须早于 inflateBytes(payload…) 的调用点)—— 挪到解压之后即变红。
        if (bodySize > MAX_BODY_SIZE) {
          throw new Error('decodeMap: 头部声明的 body_size ' + bodySize +
                          ' 字节超过 64MB 上限(' + MAX_BODY_SIZE + ' 字节),拒绝解压');
        }
        if (subCols <= 0 || subRows <= 0) {
          throw new Error('decodeMap: 尺寸非法 ' + subCols + '×' + subRows);
        }
        if (subCols % SUB_PER_CELL !== 0 || subRows % SUB_PER_CELL !== 0) {
          throw new Error('decodeMap: 尺寸 ' + subCols + '×' + subRows + ' 不是 ' + SUB_PER_CELL + ' 的倍数');
        }
        var payload = r.bytes(b.length - HEADER_SIZE);
        var next;
        if (compression === 0) next = Promise.resolve(payload);
        else if (compression === 1) {
          // ★ 上界一并交给 inflateBytes:头里的 body_size 是**未经验证**的声明,只有
          //   这一道作用在**实际输出**上。合法文件的解压结果恒等于 body_size,所以这里
          //   用同一个常量是**精确**的,不是近似(不会误拒任何合法文件)。
          next = inflateBytes(payload, MAX_BODY_SIZE);
        }
        else throw new Error('decodeMap: 未知 compression=' + compression);
        return next.then(function (body) {
          if (body.length !== bodySize) {
            throw new Error('decodeMap: 解压后 ' + body.length + ' 字节,头部声明 ' + bodySize);
          }
          var actual = crc32(body);
          if (actual !== expectCrc) {
            throw new Error('decodeMap: CRC 不符(算得 0x' + actual.toString(16) +
                            ',头部 0x' + expectCrc.toString(16) + ')');
          }
          return decodeBody(body, subCols, subRows, flags);
        });
      });
  }

  // ── v3 / 旧字母格式解析(只读迁移用,规格 §3.6)──
  // ★ 这里的 packed = texture*16 + shape 是 **v3 的编码**,与 v4 的 descriptor 毫无关系。
  //   故一律走 _v3Pack / _v3TexOf / _v3ShapeOf,绝不与 packDesc / texOf 混用。
  const V3_MARKER = '# cyrm-v3';
  const SHAPE_HEX = '0123456789ABCDEF';
  // 旧字母格式只认 0-9 与 A(大小写均可),与游戏侧 MapFormat._tile_char_to_value 一致。
  const LEGACY_CHAR = { '0':0,'1':1,'2':2,'3':3,'4':4,'5':5,'6':6,'7':7,'8':8,'9':9,'A':10 };

  function _v3Pack(texture, shape) {
    if (shape === 0 || texture === 0) return 0;
    return (texture * 16 + shape) & 0xFFFF;
  }
  function _v3TexOf(v)   { return (v / 16) | 0; }
  function _v3ShapeOf(v) { return v % 16; }

  function isV3Text(text) {
    var lines = String(text == null ? '' : text).split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().indexOf(V3_MARKER) === 0) return true;
    }
    return false;
  }

  // 旧 2×2 字母网格 → 1 格 packed(纹理取组内首个非零,形状 = 2×2 掩码)。
  // 逻辑与游戏侧 MapFormat.convert_old_grid 逐字对应。
  function _convertLegacy2x2(rows) {
    var h = rows.length, w = rows[0].length;
    var out = [];
    for (var ny = 0; ny < Math.floor(h / 2); ny++) {
      var row = [];
      for (var nx = 0; nx < Math.floor(w / 2); nx++) {
        var shape = 0, tex = 0;
        for (var sy = 0; sy < 2; sy++) {
          for (var sx = 0; sx < 2; sx++) {
            var ov = rows[ny * 2 + sy][nx * 2 + sx];
            if (ov !== 0) {
              shape |= 1 << (sy * 2 + sx);
              if (tex === 0) tex = ov;
            }
          }
        }
        row.push(_v3Pack(tex, shape));
      }
      out.push(row);
    }
    return out;
  }

  function parseV3Text(text) {
    var lines = String(text == null ? '' : text).split(/\r?\n/);
    var v3 = false;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().indexOf(V3_MARKER) === 0) { v3 = true; break; }
    }
    var rows = [], width = -1;
    var metaText = '';
    for (i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line === '') continue;
      if (line.charAt(0) === '#') {
        // ★ 版本标记行不算注释。漏了这一句 `# cyrm-v3` 会被当成一条普通注释
        //   塞进 comments,于是"导入→导出"会往用户的 meta 里塞进一行垃圾。
        if (/^#\s*cyrm-v\d+\s*$/.test(line)) continue;
        metaText += line + '\n';
        continue;
      }
      var row = [];
      if (v3) {
        if (line.length % 4 !== 0) {
          throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行长度 ' + line.length + ' 不是 4 的倍数');
        }
        for (var j = 0; j < line.length; j += 4) {
          var tstr = line.substr(j, 3);
          if (!/^[0-9]{3}$/.test(tstr)) {
            throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行纹理位 "' + tstr + '" 不是 3 位数字');
          }
          var ch = line.charAt(j + 3).toUpperCase();
          var sv = SHAPE_HEX.indexOf(ch);
          if (sv < 0) throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行非法形状字符 "' + line.charAt(j + 3) + '"');
          row.push(_v3Pack(parseInt(tstr, 10), sv));
        }
      } else {
        for (j = 0; j < line.length; j++) {
          var lch = line.charAt(j).toUpperCase();
          var lv = LEGACY_CHAR[lch];
          if (lv === undefined) {
            throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行非法字符 "' + line.charAt(j) + '"(旧格式只允许 0-9/A)');
          }
          row.push(lv);
        }
      }
      if (width < 0) width = row.length;
      else if (row.length !== width) {
        throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行宽度 ' + row.length + ' 与首行 ' + width + ' 不一致');
      }
      rows.push(row);
    }
    if (rows.length === 0) throw new Error('parseV3Text: 地图里没有有效网格行');

    var meta = parseMeta(metaText);
    var players = meta.players, enemies = meta.enemies;
    if (!v3) {
      rows = _convertLegacy2x2(rows);
      // 旧格式 2×2 → 1,spawn 坐标同步 ÷2
      players = players.map(function (p) { return { x: Math.floor(p.x / 2), y: Math.floor(p.y / 2) }; });
      enemies = enemies.map(function (e) { return { type: e.type, x: Math.floor(e.x / 2), y: Math.floor(e.y / 2) }; });
    }
    var cellsW = rows[0].length, cellsH = rows.length;
    var packed = new Uint16Array(cellsW * cellsH);
    for (var y = 0; y < cellsH; y++) {
      for (var x = 0; x < cellsW; x++) packed[y * cellsW + x] = rows[y][x];
    }
    return { cellsW: cellsW, cellsH: cellsH, packed: packed,
             players: players, enemies: enemies, comments: meta.comments };
  }

  // ── 取角映射(规格 §2.2,规范定义)──
  // 子格全局坐标 (X,Y) → 目标矩形(世界像素)+ 源矩形(贴图块内偏移)。
  // 调用方按 (texture-1) 定位贴图块,再加这里的 src 偏移。
  //   dst: [x, y, w, h] 世界像素,恒为 16×16
  //   src: [x, y, w, h] 贴图块内偏移,恒为 8×8
  // ★ 象限由子格在 64px 格内的位置决定(X % 4 / Y % 4),不是存在数据里的字段 ——
  //   每个子格要能独立推出自己该画哪一块。
  function subcellRender(X, Y) {
    var qx = X % SUB_PER_CELL, qy = Y % SUB_PER_CELL;
    return { dst: [X * SUB_PX, Y * SUB_PX, SUB_PX, SUB_PX],
             src: [qx * (32 / SUB_PER_CELL), qy * (32 / SUB_PER_CELL),
                   32 / SUB_PER_CELL, 32 / SUB_PER_CELL] };
  }

  // ── v3 → v4 迁移(规格 §3.6)──
  // 旧掩码 bit (qy*2+qx) 为 1 → 新网格的 4 个子格 X∈[2qx,2qx+1], Y∈[2qy,2qy+1] 填同一纹理。
  // 配合 subcellRender 的取角映射,这保证迁移后**视觉逐像素不变**:
  // 旧的那块 32px 区域由 4 个 16px 子格拼回,每个取到的正是原来那 8px 象限放大 2×。
  // 前/后/背景三层留空 —— v3 里没有它们。
  function migrateV3(parsed) {
    var map = createMap('', parsed.cellsW, parsed.cellsH);
    var scene = map.layers[LAYER_SCENE].desc;
    var subCols = map.subCols;
    for (var cy = 0; cy < parsed.cellsH; cy++) {
      for (var cx = 0; cx < parsed.cellsW; cx++) {
        var v = parsed.packed[cy * parsed.cellsW + cx];
        if (v === 0) continue;
        var tex = _v3TexOf(v), shape = _v3ShapeOf(v);
        if (tex === 0 || shape === 0) continue;
        var d = neutralDesc(tex);
        for (var qy = 0; qy < 2; qy++) {
          for (var qx = 0; qx < 2; qx++) {
            if (!(shape & (1 << (qy * 2 + qx)))) continue;
            for (var dy = 0; dy < 2; dy++) {
              for (var dx = 0; dx < 2; dx++) {
                var X = cx * SUB_PER_CELL + qx * 2 + dx;
                var Y = cy * SUB_PER_CELL + qy * 2 + dy;
                scene[Y * subCols + X] = d;
              }
            }
          }
        }
      }
    }
    map.players = parsed.players.map(function (p) { return { x: p.x, y: p.y }; });
    map.enemies = parsed.enemies.map(function (e) { return { type: e.type, x: e.x, y: e.y }; });
    map.comments = parsed.comments.slice();
    return map;
  }

  // ── 尺寸上限(规格 §4.3 闸 1)──
  // 旧编辑器的 clampMin(v, min, def) 第三参是"非数字时的默认值"而不是上限,
  // 输 99999 就会去分配一张巨图然后卡死浏览器。这里给硬上限。
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

  // ── 导出前校验(规格 §4.7)──
  // 只报告,不阻止导出 —— 编辑器不该替用户做决定。
  // errors   = 真正非法,导出会产出坏文件
  // warnings = 能导出,但游戏里大概不按你预期跑
  function validateMap(map) {
    var errors = [], warnings = [];
    if (!map || !map.layers || map.layers.length !== LAYER_COUNT) {
      errors.push('图层数不是 ' + LAYER_COUNT);
      return { errors: errors, warnings: warnings };
    }
    if (map.subCols % SUB_PER_CELL !== 0 || map.subRows % SUB_PER_CELL !== 0) {
      errors.push('尺寸 ' + map.subCols + '×' + map.subRows + ' 不是 ' + SUB_PER_CELL + ' 的倍数');
    }
    var n = map.subCols * map.subRows;
    var L, layer;
    for (L = 0; L < LAYER_COUNT; L++) {
      layer = map.layers[L];
      if (!layer) continue;
      var arr = layer.kind === 'tex' ? layer.desc : layer.rgba;
      if (!arr || arr.length !== n) {
        errors.push(LAYER_NAMES[L] + '层长度不是 ' + map.subCols + '×' + map.subRows);
      }
    }
    if (errors.length) return { errors: errors, warnings: warnings };

    var cellsW = map.subCols / SUB_PER_CELL, cellsH = map.subRows / SUB_PER_CELL;
    var scene = map.layers[LAYER_SCENE] ? map.layers[LAYER_SCENE].desc : null;

    // 出生点
    if (map.players.length === 0) {
      warnings.push('一个出生点都没有');
    }
    if (map.players.length > 2) {
      warnings.push('有 ' + map.players.length + ' 个出生点,但游戏只认前两个' +
                    '(第 3 个及以后在 map_format.gd 里读不到)');
    }
    var i;
    for (i = 0; i < map.players.length; i++) {
      warnings = warnings.concat(_checkSpawn(map.players[i], '出生点 P' + (i + 1),
                                            cellsW, cellsH, scene));
    }
    for (i = 0; i < map.enemies.length; i++) {
      warnings = warnings.concat(_checkSpawn(map.enemies[i], '敌人 ' + map.enemies[i].type,
                                            cellsW, cellsH, scene));
    }

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

  // 越界 / 落在实心格。返回 warning 文案数组(可能为空)。
  function _checkSpawn(pt, label, cellsW, cellsH, sceneDesc) {
    var out = [];
    if (pt.x < 0 || pt.y < 0 || pt.x >= cellsW || pt.y >= cellsH) {
      out.push(label + ' 坐标 (' + pt.x + ',' + pt.y + ') 越界(地图是 ' + cellsW + '×' + cellsH + ' 格)');
      return out;
    }
    if (!sceneDesc) return out;
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
    if (solid) out.push(label + ' 落在实心格里(场景层该格被填满)');
    return out;
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

  // ── descriptor 位域(规格 §2.3)──
  //   bit  0- 2  hue         0-7
  //   bit  3- 5  brightness  0-7
  //   bit  6- 8  saturation  0-7
  //   bit  9-11  alpha       0-7
  //   bit 12-23  texture     1-4095(0 = 空气)
  //   bit 24-31  保留,固定 0
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

  // 中性描述符 = 完全按原图,一点色都不改。
  // ★ 三列的中性档不在同一行:alpha 的中性在档 7,其余在档 4。
  function neutralDesc(texture) {
    return packDesc(texture, HUE_NEUTRAL, BRI_NEUTRAL, SAT_NEUTRAL, ALPHA_NEUTRAL);
  }

  return {
    SUB_PER_CELL: SUB_PER_CELL,
    SUB_PX: SUB_PX,
    CELL_PX: CELL_PX,
    DESC_AIR: DESC_AIR,
    TEXTURE_MAX: TEXTURE_MAX,
    LAYER_COUNT: LAYER_COUNT,
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
    texOf: texOf, hueOf: hueOf, brightOf: brightOf, satOf: satOf, alphaOf: alphaOf,
    isAir: isAir, neutralDesc: neutralDesc,
    FORMAT_VERSION: FORMAT_VERSION, HEADER_SIZE: HEADER_SIZE,
    MAX_BODY_SIZE: MAX_BODY_SIZE,
    deflateBytes: deflateBytes, inflateBytes: inflateBytes,
    encodeMap: encodeMap, decodeMap: decodeMap, layerFlags: layerFlags,
    isV3Text: isV3Text, parseV3Text: parseV3Text,
    _v3Pack: _v3Pack, _v3TexOf: _v3TexOf, _v3ShapeOf: _v3ShapeOf,
    subcellRender: subcellRender, migrateV3: migrateV3,
    MAX_CELLS_W: MAX_CELLS_W, MAX_CELLS_H: MAX_CELLS_H,
    clampMapSize: clampMapSize, validateMap: validateMap,
  };
})();
