'use strict';
// tests/format/80_bg_layers.js —— 背景四层景深(层 3..6)+ layer_flags 位 0..6 + 旧文件降级。
// 契约:景深 100%/75%/50%/25% 对应层号 3/4/5/6;bit0-6 = 层 0-6;bit7 保留写 0;
// 旧文件只有 bit0-3 ⇒ 层 4-6 为 null(不报错);旧读取器忽略 bit4-6 ⇒ 只看得到背景 100%。
const Core = globalThis.Core;

module.exports = (async function () {

  // ① layerFlags:存在的层才置位;删一层 ⇒ 该位清掉;4..6 未分配时不出位
  var m = Core.createMap('t', 2, 1);              // 8×4 子格
  Core.ensureLayer(m, 4);
  Core.ensureLayer(m, 5);
  eq(Core.layerFlags(m), 0x3F,
     'layerFlags:前四层 + 层4/5 存在 ⇒ bit0-5(0x3F),层6 未分配不出位');

  // ② 四层颜色层各自独立:写不同值 → encodeMap → decodeMap → 逐格回读一致
  var vals = { 3: 0x11223344, 4: 0x55667788, 5: 0x99AABBCC, 6: 0xDDEEFF00 };
  Core.ensureLayer(m, 6);
  for (var L = 3; L <= 6; L++) m.layers[L].rgba[5] = vals[L];
  eq(Core.layerFlags(m), 0x7F, 'layerFlags:层6 分配后 ⇒ bit0-6(0x7F)');
  var back = await Core.decodeMap(await Core.encodeMap(m, { compress: false }));
  eq(back.layers.length, 7, '往返:解出 7 个层位');
  var roundtripOk = true, firstBad = '';
  for (L = 3; L <= 6; L++) {
    if (!back.layers[L] || back.layers[L].rgba[5] !== vals[L]) {
      roundtripOk = false;
      firstBad = firstBad || ('层' + L + ' 期望 0x' + vals[L].toString(16));
    }
  }
  ok(roundtripOk, '★ 四层景深背景逐层往返一致(不同值不串层)' + (firstBad ? ' —— ' + firstBad : ''));

  // ③ 旧文件降级:只有 bit0-3 的文件解出来层 4-6 必须是 null,且不报错
  var old = Core.createMap('old', 1, 1);          // 只有 0..3 层(4..6 = null)
  old.layers[Core.LAYER_BG].rgba[0] = 0xAABBCCDD;
  var oldBytes = await Core.encodeMap(old, { compress: false });
  eq(Core.layerFlags(old), 0b00001111, '旧形态:只有前四层 ⇒ flags = 0b1111');
  var oldBack = await Core.decodeMap(oldBytes);
  ok(oldBack.layers[4] === null && oldBack.layers[5] === null && oldBack.layers[6] === null,
     '★ 旧文件(bit0-3)解出层 4-6 = null(缺层不是错误)');
  eq(oldBack.layers[Core.LAYER_BG].rgba[0], 0xAABBCCDD, '旧文件:背景 100% 内容仍在');

  // ④ 只留「场景层 + 背景 50%」的稀疏形态 ⇒ 解出对应层存在、其余 null(用真编码,不手改 flags:
  //    flags 与 body 的块序列必须一致,单独改头部字节会得到自相矛盾的文件,那是另一类错误)
  var sparse = Core.createMap('f', 1, 1);
  sparse.layers[Core.LAYER_FRONT] = null;
  sparse.layers[Core.LAYER_BACK] = null;
  sparse.layers[Core.LAYER_BG] = null;
  Core.ensureLayer(sparse, 5);
  sparse.layers[5].rgba[0] = 0x01020304;
  eq(Core.layerFlags(sparse), 0b00100010, '稀疏形态:flags = bit1(场景) + bit5(背景 50%)');
  var patched = await Core.decodeMap(await Core.encodeMap(sparse, { compress: false }));
  ok(patched.layers[0] === null && patched.layers[2] === null && patched.layers[3] === null,
     '★ 稀疏形态:层 0/2/3 为 null');
  ok(patched.layers[1] !== null && patched.layers[5] !== null && patched.layers[6] === null,
     '★ 稀疏形态:层 1(场景)与层 5(背景 50%)解出,层 6 仍为 null');
  eq(patched.layers[5].rgba[0], 0x01020304, '稀疏形态:背景 50% 内容回读一致');

  // ⑤ ensureLayer:纹理层缺席时绝不凭空补(旧文件不该被悄悄改成"七层齐全")
  var hole = Core.createMap('h', 1, 1);
  hole.layers[2] = null;                            // 人为挖掉后景层
  ok(Core.ensureLayer(hole, 2) === null && hole.layers[2] === null,
     '★ ensureLayer:纹理层缺席不补(只补颜色层)');
  ok(Core.ensureLayer(hole, null) === null, 'ensureLayer:非法层号返回 null');

  // ⑥ validateMap:七层位齐全才算合法;层数不对 ⇒ error(编码前置闸)
  eq(Core.validateMap(Core.createMap('v', 1, 1)).errors.length, 0, 'validateMap:七层位的新图无 error');
  var short = Core.createMap('s', 1, 1);
  short.layers = short.layers.slice(0, 4);
  ok(Core.validateMap(short).errors.join('|').indexOf('图层数不是') >= 0,
     '★ validateMap:层数不是 7 ⇒ error(消息里点名图层数)');
})();
