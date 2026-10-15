'use strict';
// tests/format/30_meta_and_file.js —— meta 文本往返、整文件编解码(含损坏文件的拒绝)、压缩路径的独立验证。
const Core = globalThis.Core;

module.exports = (async function () {
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

  eq(Core.buildMeta(Core.createMap('t', 2, 2)), '', 'buildMeta: 什么都沒有时是空串');
  // ★ 一张表 = 一条守卫(D9):12 条"一个输入一条断言"收成一张 —— 失败时点名是哪一行。
  //   这张表钉的是**同一条规则**:非法/畸形 spawn 行一律整行降级为注释(前缀截断不许吃掉原文)。
  tableEq('parseMeta:非法/畸形 spawn 行整行降级为注释,正常行不受影响', [
    ['空串 → 三个空数组', Core.parseMeta(''), { players: [], enemies: [], comments: [] }],
    ['缺坐标的 player 注释不被误认', Core.parseMeta('# player 是主角\n').comments, ['player 是主角']],
    ['CRLF 也要能吃', Core.parseMeta('# demo\r\n# player 1 2\r\n').players, [{ x: 1, y: 2 }]],
    ['非法 player → 不当出生点', Core.parseMeta('# player abc 4\n').players, []],
    ['非法 spawn 行降级为注释(两行都留住)', Core.parseMeta('# player abc 4\n# enemy\n').comments, ['player abc 4', 'enemy']],
    ['小数坐标整行降级(parseInt 的前缀截断不许吃掉原文)', Core.parseMeta('# player 3.5 4\n').comments, ['player 3.5 4']],
    ['小数坐标不产生出生点', Core.parseMeta('# player 3.5 4\n').players, []],
    ['带后缀坐标整行降级', Core.parseMeta('# player 7abc 4\n').comments, ['player 7abc 4']],
    ['科学计数法坐标整行降级', Core.parseMeta('# player 1e3 4\n').comments, ['player 1e3 4']],
    ['敌人坐标同理', Core.parseMeta('# enemy fly_bird 3.5 4\n').comments, ['enemy fly_bird 3.5 4']],
    ['(对照)正常敌人行不受影响', Core.parseMeta('# enemy fly_bird 20 12\n').enemies, [{ type: 'fly_bird', x: 20, y: 12 }]],
    ['负号仍按整数接受(越界由 validateMap 管)', Core.parseMeta('# player -5 4\n').players, [{ x: -5, y: 4 }]],
  ]);

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

  // ── 反向断言:损坏的文件必须抛错,不能静默读成一张空图;每条都带期望子串(只判"抛了"的话,拼错名字抛的 TypeError 也会全绿)──
  var badMagic = bytes.slice(); badMagic[0] = 0x00;
  await rejects(function () { return Core.decodeMap(badMagic); }, 'decodeMap: 坏 magic 抛错', 'magic');

  var badVer = bytes.slice(); badVer[4] = 99;
  await rejects(function () { return Core.decodeMap(badVer); }, 'decodeMap: 未知版本抛错', '版本');

  // ★ 翻的是不压缩文件 body 的最后一个字节:这步没有解压、长度不变(body_size 仍对),唯一能抓住它的就是 crc32(body) 的比对 —— 这才真的验到"CRC 算在 body 内容上"。
  // ★ 期望子串必须只有它该触发的那个错误才有:'CRC' 太松(任何含 "CRC" 的运行时错误都会命中)。
  var badCrc = raw.slice(); badCrc[badCrc.length - 1] ^= 0xFF;
  await rejects(function () { return Core.decodeMap(badCrc); }, 'decodeMap: CRC 不符抛错', 'CRC 不符');

  // 压缩流本身损坏(另一个损坏面):翻 zlib 的 Adler-32 校验尾,Node 会以"message 为空的 TypeError"拒绝,错因只在 e.cause.message 里("incorrect data check")—— 故 errText 必须回退读它。
  var badStream = bytes.slice(); badStream[badStream.length - 1] ^= 0xFF;
  await rejects(function () { return Core.decodeMap(badStream); },
    'decodeMap: deflate 流损坏抛错(不静默读成空图)', 'incorrect data check');

  var badSize = bytes.slice(); badSize[14] = 0; badSize[15] = 0;     // sub_cols = 0
  await rejects(function () { return Core.decodeMap(badSize); }, 'decodeMap: 尺寸 0 抛错', '尺寸非法');

  var badAlign = bytes.slice(); badAlign[14] = 6; badAlign[15] = 0;  // sub_cols = 6,非 4 倍数
  await rejects(function () { return Core.decodeMap(badAlign); }, 'decodeMap: 尺寸非 4 倍数抛错', '倍数');

  // ★★ 防"损坏的文件头触发巨量分配":CRC32 只覆盖 body、不覆盖文件头,所以这两个尺寸字段是未经验证的输入;65532 既 > 0 又能被 4 整除,两道既有校验都拦不住,不按 body 实际大小反推上界就会走到 new Uint32Array(65532×65532) ≈ 17GB。
  // ★ 期望子串(我们自己的错误文本)承担"不是走到分配才炸"的判据:本机实测 new Uint32Array(4294443024) 能成功分配 17.2GB,所以"断言它不是 RangeError"在这台机器上是空转的。
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

  // ★ 同理,期望子串要钉完整短语:'compression' 这类松子串会被任何未声明标识符的 ReferenceError 命中(那是"探针写错了",不是守卫在跑)。
  var badComp = bytes.slice(); badComp[5] = 7;
  await rejects(function () { return Core.decodeMap(badComp); }, 'decodeMap: 未知 compression 抛错', '未知 compression');
})();

// ---- 压缩路径的独立验证(golden 用 compress:false,覆盖不到的那一半)----
// ★ 压缩路径才是这条不变量的唯一覆盖:body_size / body_crc32 算在解压后的 body 上 —— 把两端同时改成 crc32(payload),往返照样对称、全绿。
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

  // ① 用 Node 自带的 zlib 独立解压我们的流:换一套实现解出来必须一模一样(验它确实是 zlib / RFC1950)。
  var got = new Uint8Array(zlib.inflateSync(Buffer.from(enc.subarray(Core.HEADER_SIZE))));
  sameBytes(got, Array.prototype.slice.call(body), '压缩: Node zlib 独立解压结果 == 裸 body');

  // ② 头部那两个字段必须算在解压后的 body 上(两端对称改错时往返抓不到)。
  var zr = new Core.ByteReader(enc);
  zr.bytes(6);
  eq(zr.u32(), body.length, '压缩: body_size 是解压后的字节数(不是压缩后的)');
  eq(zr.u32(), Core.crc32(body), '压缩: body_crc32 是解压后 body 的 CRC(不是压缩流的)');
})();

})();
