'use strict';
// tests/format/50_v3_text.js —— v3 文本格式(含旧字母格式)的解析与拒绝。
const Core = globalThis.Core;

// ---- v3 文本解析 ----
(function () {
  ok(Core.isV3Text('# cyrm-v3\n0000001F0031\n'), 'isV3Text: 有标记为真');
  ok(!Core.isV3Text('# 普通地图\n11\n11\n'), 'isV3Text: 无标记为假');

  // ★ 版本标记行必须用同一个谓词:无空格的 #cyrm-v3 曾被跳过却不被识别(网格掉进旧字母格式、静默错位),而 # cyrm-v3 (demo) 被识别却不被跳过(标记行污染 comments)。
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

  // 旧字母格式:单字符 0-9/A,2×2 收缩成 1 格,spawn 坐标 ÷2;样本必须带 # enemy 行 —— 唯一那份旧样本没有它,enemies 的 ÷2 与 type 字段此前零覆盖。
  var old = Core.parseV3Text('# old\n# player 112 95\n# enemy jump_bird 100 50\n11\n11\n');
  eq(old.cellsW, 1, '旧格式: 2×2 → 1 格宽');
  eq(old.cellsH, 1, '旧格式: 2×2 → 1 格高');
  eq(Array.prototype.slice.call(old.packed), [31], '旧格式: 2×2 全实心 → 全砖 31');
  eq(old.players, [{ x: 56, y: 47 }], '旧格式: spawn 坐标 ÷2');
  eq(old.enemies, [{ type: 'jump_bird', x: 50, y: 25 }], '旧格式: enemies 坐标 ÷2 且 type 不丢');

  // ★ LEGACY_CHAR 里的 A 其接受路径此前零覆盖:写成 11、或整行漏出 LEGACY_CHAR(查表得 undefined → 报非法字符)都是看着能跑的静默错。A1 与 11 的 4 个象限全实心、组内首个非零是 A ⇒ pack 成 10*16+15。
  var oldA = Core.parseV3Text('# old\nA1\n11\n');
  eq(Array.prototype.slice.call(oldA.packed), [175], '旧格式: A 参与 pack(2×2 全实心 → 10*16+15)');
  eq(Core._v3TexOf(oldA.packed[0]), 10, '旧格式: A 映射成纹理 10(不是 0/9/11)');

  // ★ 旧字母格式的非对称象限:全实心样本(shape 15)与抛错样本(b/B)都对位序不敏感,于是把 1 << (sy*2+sx) 写成转置、或把 sy/sx 取反,整份冒烟仍然全绿,而每张导入的旧 .txt 的每个非对称象限都转 90°(静默错位);这与 migrateV3 那边是同一类缺陷的另一处。
  //   期望值自行推导:样本 10/11 的非零象限 (0,0),(1,0),(1,1) → shape 13 → packed 29;样本 11/01 的非零象限 (0,0),(0,1),(1,1) → shape 11 → packed 27;两样本互为上下镜像,转置下恰好互换 ⇒ 变异会让两条同时红。
  eq(Array.prototype.slice.call(Core.parseV3Text('# old\n10\n11\n').packed), [29],
     '旧格式: 非对称样本(右上缺)→ packed 29 = 纹理1 + shape 13(bit0|bit2|bit3)');
  eq(Array.prototype.slice.call(Core.parseV3Text('# old\n11\n01\n').packed), [27],
     '旧格式: 非对称样本(左下缺)→ packed 27 = 纹理1 + shape 11(bit0|bit1|bit3)');

  // 旧格式只认 0-9 与 A(游戏侧 _tile_char_to_value 同款;多认 b-k 会"导得进、跑起来一片变空气");这批 throws 各带只属于自己那条错误的子串 —— 裸 throws 会被拼错名字抛的 TypeError 静默骗过。
  throws(function () { Core.parseV3Text('# old\n1b\n11\n'); },
         '旧格式: 小写 b 报错(游戏侧不认)', '非法字符 "b"');
  throws(function () { Core.parseV3Text('# old\n1B\n11\n'); },
         '旧格式: 大写 B 报错(游戏侧不认)', '非法字符 "B"');

  // ★ 旧字母格式靠 2×2 折叠 ⇒ 宽高必须都是 ≥2 的偶数:此前单行输入抛裸 TypeError,宽 3 × 高 4 则一句话不说地永久吃掉两整列(迁移是单向的);错误信息里还要带实际收到的尺寸。
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
  eq(Core.parseV3Text('# old\n11\n11\n').cellsW, 1, 'A4 旧格式: 下界 2×2 仍可解析');
  eq(Core.parseV3Text('# old\n1111\n1111\n').cellsW, 2, 'A4 旧格式: 宽 4(偶数)仍可解析');
  eq(Core.parseV3Text('# old\n11\n11\n11\n11\n').cellsH, 2, 'A4 旧格式: 高 4(偶数)仍可解析');

  // 非法输入必须抛错,不能静默截断成空气(parseInt("0A1") === 0 那类)。
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

  var crlf = Core.parseV3Text('# cyrm-v3\r\n\r\n0000001F0031\r\n');
  eq(Array.prototype.slice.call(crlf.packed), [0, 31, 49], 'parseV3Text: CRLF 与空行');

  // 小写形状字符 f 仍要能读:样本用 001f 而不是 000f —— 纹理 0 会让 _v3Pack 无条件返回 0,那个输入根本走不到形状字符(空转)。
  eq(Array.prototype.slice.call(Core.parseV3Text('# cyrm-v3\n001f\n').packed), [31], 'v3: 小写形状字符 f 可读');

  // ★ _v3Pack 的两个空气守卫(shape === 0 || texture === 0 → 0)此前只被 0000 这一个退化样本覆盖过(分不出哪条在生效),下面两条各钉一条独立情形,与游戏侧 MapFormat.pack 同款。
  eq(Array.prototype.slice.call(Core.parseV3Text('# cyrm-v3\n000f\n').packed), [0],
     'v3: 纹理 000 = 空气,形状位不生效(与游戏 MapFormat.pack 同)');
  eq(Array.prototype.slice.call(Core.parseV3Text('# cyrm-v3\n0010\n').packed), [0],
     'v3: 形状 0 = 空气,纹理位不生效(纹理 1 也留不住)');
})();
