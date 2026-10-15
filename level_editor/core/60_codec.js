// core/60_codec.js —— v4 容器:头 + body_size 闸 + 分层读写。


const FORMAT_VERSION = 4;
const HEADER_SIZE = 20;
const MAGIC = [0x43, 0x59, 0x52, 0x4D];   // "CYRM"

// ★ MAX_BODY_SIZE 是解压后 body 的硬上限,专堵 deflate 炸弹(压缩比 ≈1032:1,几十 KB 解出 GB 级内存);
//   它完全不碰头部字段,所以「按 body 实际余量反推格数」那道检查对它天然无效。
//   它用在两道闸上、两道都不可省:decodeMap 的头部声明、inflateBytes 的 maxBytes(推导见 docs/eng/editor-core.md)。
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
    // ★ 头部的 sub_cols / sub_rows 未经验证(CRC 只覆盖 body),一枚翻错的头字节就能让格数到 ≈43 亿
    //   ⇒ 用本层剩余字节数反推粗筛上界,且必须判在 new Uint32Array(n) 之前(不需精确,只需不可能通过)。
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

// opts.compress 默认 true;传 false 走裸 body(compress=0),用来兜住"两端 deflate 实现对不上"这类风险。
function encodeMap(map, opts) {
  opts = opts || {};
  // ★ 导出前必须跑一遍 validateMap:decodeMap 在尺寸/图层长度上很严格,encodeMap 不校验就会产出坏文件。
  //   只拒 errors、不拒 warnings —— 规格 §4.7 明说校验只报告不阻止导出(拿 warnings 拦导出 = 把"只报告"变成"阻止")。
  var report = validateMap(map);
  if (report.errors.length) {
    return Promise.reject(new Error('encodeMap: 地图校验未通过 —— ' + report.errors.join(';')));
  }
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

// decodeMap 对外来文件的保证(不满足就 reject,绝不静默返回一张残缺的图):头部与尺寸合法、解压闸门、
// body 长度精确、CRC 相符、body 全消费、索引与调色板边界、每层分配前的粗筛。
// ★ 它不保证:调色板[0] 是空气、纹理 0 与整体 0 一致、尺寸在上限内、坐标落在非实心格 —— 完整清单见 docs/eng/editor-core.md。
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
      // ★ reserved 字节与 layer_flags 的 bit4-7 一律读掉不判:这是有意的前向兼容(将来头部扩字段时老编辑器降级忽略),
      //   故不要加 reserved === 0 或 flags & 0xF0 === 0 的校验 —— 实测 0xAB / 0xFF 的头部今天都能正常解码。
      r.u8();
      // ★ 先判头部声明的解压后大小、再碰 payload:解压是把攻击者给的字节变成内存的那一步,判在它后面等于没判。
      //   零守卫(读源码比位置的「源码顺序」那组已随测试面削减删掉·2026-10-15):挪到解压之后
      //   不会变红,改这里只能靠人看。行为侧只剩"声明超限必须拒"那一条,它钉不住位置。
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
        // ★ 上界一并交给 inflateBytes:头里的 body_size 是未经验证的声明,只有这一道作用在实际输出上。
        //   传 bodySize 而不是 MAX_BODY_SIZE:合法文件的解压结果恒等于 bodySize,故它是精确上界、不误拒;
        //   拿松值当闸则"谎报 + 真炸弹"要真解压出 64MB 才被拒(安全边界不该比需要的宽一万六千倍)。
        next = inflateBytes(payload, bodySize);
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
