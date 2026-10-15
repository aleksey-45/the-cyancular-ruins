'use strict';
// tests/format/40_golden_and_limits.js —— 手推的 golden 字节向量、上限尺寸往返、压缩炸弹的两道闸。
const Core = globalThis.Core;

module.exports = (async function () {
// ---- golden 字节向量(1×1 格、compress:false)----
// ★ 为什么需要这一块:上面全是"同一个 encode/decode 对跑往返",两端一起把字节序改反(比如 u32 写成大端)照样全绿,而产出的文件 Godot 读不了;这里把完整文件字节(20 字节头 + 161 字节 body)逐字节钉死。
// ★ 期望序列照着规格 §3.1/§3.2/§3.3/§3.4 手推,不是跑一遍 encodeMap 抄的 —— 抄输出只冻结当前行为,抓不出今天就存在的字节序错;推导见下面每行注释。
// ★ 唯一的例外是头部那 4 个 CRC 字节:CRC32 无法手算,故用下面的独立按位实现 refCrc32(与 core 的表驱动是两套代码)求值,并用标准向量自证它本身是对的。
await (async function () {
  function refCrc32(bytes) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) {
      c ^= bytes[i];
      for (var k = 0; k < 8; k++) c = (c & 1) ? ((c >>> 1) ^ 0xEDB88320) : (c >>> 1);
    }
    return (c ^ 0xFFFFFFFF) >>> 0;
  }
  eq(refCrc32(new TextEncoder().encode('123456789')), 0xCBF43926, 'golden: refCrc32 自证(标准向量)');

  // 手推用的最小地图:1×1 格 = 4×4 子格;前景全空气、场景前 8 格 neutralDesc(1)、后景全空气、背景偶 0x11223344 / 奇 0xAABBCCDD;meta = 1 条注释 hi + 1 个出生点 (1,2)。
  var g = Core.createMap('g', 1, 1);
  g.layers[1].desc.fill(Core.neutralDesc(1));
  for (var i = 8; i < 16; i++) g.layers[1].desc[i] = 0;
  for (i = 0; i < 16; i++) g.layers[3].rgba[i] = (i % 2 === 0) ? 0x11223344 : 0xAABBCCDD;
  g.comments = ['hi'];
  g.players = [{ x: 1, y: 2 }];

  // neutralDesc(1) = packDesc(1,4,4,4,7) = 7972 = 0x00001F24 → 小端字节 24 1F 00 00。
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

// ---- 上限尺寸必须不受「按余量反推格数上界」那条检查的影响 ----
// ★ 那条检查是上界(不精确,只需不可能通过),但松紧有真实风险:合法文件的余量并不宽裕(背景层 room 恰好 = 1 + 4n,纹理层第一个块也只比 n 多 6 + 4×调色板项),检查若写成 n >= room 或对纹理层也用 room/4,上限尺寸的图就会被误拒;故拿规格 §1 的上限 400×300 格 = 1600×1200 子格真跑一遍。
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

  // 最紧的一档:整份文件只有背景层时该层余量恰好 = 1 + n×4,上界必须恰好放行 —— 专钉"把上界收紧一格"这类只在余量贴边时现形的回归。
  var bgOnly = Core.createMap('bg', 40, 30);
  bgOnly.layers[0] = null; bgOnly.layers[1] = null; bgOnly.layers[2] = null;
  bgOnly.layers[3].rgba[7] = 0xAABBCCDD;
  var bgBack = await Core.decodeMap(await Core.encodeMap(bgOnly, { compress: false }));
  eq(bgBack.layers[3].rgba[7], 0xAABBCCDD, '上限尺寸: 只有背景层(余量恰好 1+4n)仍放行');
  eq(bgBack.layers[0], null, '上限尺寸: 缺层仍回 null');
})();

// ---- 大图端到端(走压缩路径)----
await (async function () {
  var big = Core.createMap('big', 400, 300);          // 上限尺寸:1600×1200 子格 = 192 万

  var sc = big.layers[Core.LAYER_SCENE].desc;
  var d1 = Core.neutralDesc(1), d2 = Core.neutralDesc(2);
  for (var i = 0; i < sc.length; i++) sc[i] = ((i / big.subCols) | 0) % 7 === 0 ? d1 : d2;
  for (i = 0; i < sc.length; i += 997) sc[i] = Core.neutralDesc(15);
  for (i = 0; i < big.layers[Core.LAYER_BG].rgba.length; i++) {
    big.layers[Core.LAYER_BG].rgba[i] = ((i % 256) * 0x010101) >>> 0;
  }

  var bytes = await Core.encodeMap(big);
  var back = await Core.decodeMap(bytes);

  // ★★ 跨全长比对,不是"看前 64 个":1.92M 个子格里取前 64 个 = 0.0033%,等于没验大图 ——
  //    「下标 ≥1000 之后整片填 0」这种**静默丢数据**能全绿(实测过)。步长 997 与 subCols(1600)、
  //    与背景层图案周期(256)都互素,1926 个采样点铺满全长;另加两个端点(index 0 与末位)。
  var n = big.subCols * big.subRows;
  var srcBg = big.layers[Core.LAYER_BG].rgba;
  var outSc = back.layers[Core.LAYER_SCENE].desc, outBg = back.layers[Core.LAYER_BG].rgba;
  var bad = '';
  for (i = 0; i < n && !bad; i += 997) {
    if (outSc[i] !== sc[i]) bad = '场景层 desc[' + i + ']';
    else if (outBg[i] !== srcBg[i]) bad = '背景层 rgba[' + i + ']';
  }
  ok(bad === '', '大图: 场景层 + 背景层**跨全长**(步长 997,共 ' + Math.ceil(n / 997) + ' 个采样点)往返一致' +
     (bad ? '(首个不一致: ' + bad + ')' : ''));
  eq(outSc[0], sc[0], '大图: 场景层首格往返一致');
  eq(outSc[n - 1], sc[n - 1], '大图: 场景层末格往返一致');
  eq(outBg[n - 1], srcBg[n - 1], '大图: 背景层末格往返一致');
})();

// ---- 指令 D:解压后 body 的硬上限(堵 deflate 炸弹)----
// ★ 为什么单独一道闸:deflate 最大压缩比约 1032:1 ⇒ 几十 KB 的恶意/损坏文件就能解出 GB 级内存,且完全不碰头部字段(按 body 余量反推格数那道检查对它天然无效);判在解压之后等于拒是拒了、内存已经先分配出去,故必须判在解压之前。
await (async function () {
  eq(Core.MAX_BODY_SIZE, 64 * 1024 * 1024, 'MAX_BODY_SIZE === 64MB');

  var m = Core.createMap('bomb', 6, 5);
  m.layers[Core.LAYER_SCENE].desc[9] = Core.neutralDesc(3);
  m.players = [{ x: 1, y: 1 }];
  var enc = await Core.encodeMap(m);              // 默认走 deflate 压缩

  // 只把头部 6..9(body_size,u32 小端)篡改成 0x7FFFFFFF ≈ 2GB,payload 一个字节不动 —— 这正是"声明侧"的炸弹,任何在解压之后才判的守卫都已经晚了。
  var bomb = enc.slice();
  bomb[6] = 0xFF; bomb[7] = 0xFF; bomb[8] = 0xFF; bomb[9] = 0x7F;
  await rejects(function () { return Core.decodeMap(bomb); },
    'decodeMap: body_size 被声明成 0x7FFFFFFF 时在解压前拒绝', '64MB');

  // ★★ 声明侧之外的另一半:头里的 body_size 本身也是攻击者可控的 —— 谎报成能过闸门的小值(4096)、而 deflate 流里塞真炸弹时上面那道闸完全挡不住(分配发生在解压那一步)。
  //   判据必须落在实际输出上(core/50_compress.js 的 inflateBytes maxBytes),下面这条断言钉的就是它。
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

  // ★ 上界传的必须是头部声明的 body_size,不是 MAX_BODY_SIZE:两者的差别只在谎报得不太大时现形 —— 上面那条 65MB 炸弹两种实现都会拒,证明不了上界用的是哪个值。
  // ★ 期望子串必须挑只有新实现才产生的那句:'4096' 不能用(旧实现那句"解压后 8388608 字节,头部声明 4096"里也含 4096)。
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

  // 反向:这道闸不许误伤合法文件 —— 上限尺寸(400×300)的合法 body 最坏约 20MB,64MB 是它的 ≈3.3 倍。
  // 把这层余量本身变成断言:有人把常量调小到会误拒合法大图时,这条给出的是直接错因(上限尺寸那块的往返断言也会红,但读起来只是"图读不回来了")。
  ok(Core.MAX_BODY_SIZE > 20 * 1024 * 1024,
     'MAX_BODY_SIZE: 大于上限尺寸合法文件的最坏 body(≈20MB),不会误拒');
})();

})();
