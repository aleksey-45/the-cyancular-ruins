'use strict';
// tests/format/70_legacy_migration.js —— legacy 纹理 id 的读时迁移(core/95_legacy.js)
// 与 validateMap 的「纹理不在 tile_defs」闸(core/80_validate.js)。
// ★ 本分片自己把 tile_defs 装进来(迁移表的真相源):format 套件默认只装 core,而表缺席时
//   migrateDescriptor 按契约是 no-op(⑤ 钉住那半边)—— 前面 00..60 各分片跑的就是无表分支。
globalThis.window = globalThis;              // tile_defs.js 是 `window.TILE_DEFS = {…}`(editor_smoke 同法)
require('../../loader.js').loadModules(['tile_defs']);
const Core = globalThis.Core;
const DEFS = globalThis.TILE_DEFS;

module.exports = (async function () {

  // ① 前提:表真的装上了(否则下面每一条测的都是"无表分支",全绿也是假绿)
  ok(!!(DEFS && DEFS.tiles && DEFS.legacy_texture_map) &&
     Object.keys(DEFS.tiles).length === 15 &&
     Object.keys(DEFS.legacy_texture_map).length === 7,
     '70 前提:TILE_DEFS 已装(tiles 15 块 + legacy_texture_map 7 条;实得 ' +
     (DEFS ? Object.keys(DEFS.tiles || {}).length + '/' +
       Object.keys(DEFS.legacy_texture_map || {}).length : '没装') + ')');

  // ② migrateDescriptor 全表:7 条 legacy(中性)+ 非 legacy 不变 + 非中性合成 + 钳制两端 + 空气/畸形
  const N = function (tex) { return Core.neutralDesc(tex); };
  const P = function (tex, h, b, s, a) { return Core.packDesc(tex, h, b, s, a); };
  tableEq('migrateDescriptor:全表(7 条 legacy + 不变项 + 非中性合成/钳制 + 空气/畸形)', [
    ['tex2 中性 → (tex1,hue3)', Core.migrateDescriptor(N(2)), P(1, 3, 4, 4, 7)],
    ['tex3 中性 → (tex1,hue1)', Core.migrateDescriptor(N(3)), P(1, 1, 4, 4, 7)],
    ['tex4 中性 → (tex1,hue5)', Core.migrateDescriptor(N(4)), P(1, 5, 4, 4, 7)],
    ['tex5 中性 → (tex1,hue0)', Core.migrateDescriptor(N(5)), P(1, 0, 4, 4, 7)],
    ['tex16 中性 → (tex15,hue2)', Core.migrateDescriptor(N(16)), P(15, 2, 4, 4, 7)],
    ['tex17 中性 → (tex15,hue7)', Core.migrateDescriptor(N(17)), P(15, 7, 4, 4, 7)],
    ['tex18 中性 → (tex15,hue7)', Core.migrateDescriptor(N(18)), P(15, 7, 4, 4, 7)],
    ['tex1 中性不变', Core.migrateDescriptor(N(1)), N(1)],
    ['tex15 中性不变', Core.migrateDescriptor(N(15)), N(15)],
    ['tex22 中性不变(派生纹理也合法)', Core.migrateDescriptor(N(22)), N(22)],
    ['非中性合成:(tex2,hue5,b2,s6,a3) → (tex1,hue=clamp(5+3−4)=4,其余原样)',
     Core.migrateDescriptor(P(2, 5, 2, 6, 3)), P(1, 4, 2, 6, 3)],
    ['钳上界:(tex17,hue7) → hue=clamp(7+7−4)=7', Core.migrateDescriptor(P(17, 7, 0, 1, 2)), P(15, 7, 0, 1, 2)],
    ['钳下界:(tex5,hue0) → hue=clamp(0+0−4)=0', Core.migrateDescriptor(P(5, 0, 7, 7, 0)), P(1, 0, 7, 7, 0)],
    ['空气 0 不变', Core.migrateDescriptor(0), 0],
    ['畸形 desc(tex0 辅码非 0)原样', Core.migrateDescriptor(0x7FF), 0x7FF],
    ['非 legacy 的辅码原样(tex21,hue3)', Core.migrateDescriptor(P(21, 3, 4, 4, 7)), P(21, 3, 4, 4, 7)],
  ]);

  // ③ migrateMap:三个 tex 层都迁、color 层一个字节不动、原地改写、null 层跳过
  (function () {
    const m = Core.createMap('mig', 2, 1);            // 8×4 子格
    const sc = m.layers[Core.LAYER_SCENE].desc;
    sc[0] = Core.neutralDesc(2);                      // legacy → (1,hue3)
    sc[1] = Core.packDesc(17, 5, 4, 4, 7);            // legacy 非中性 → (15,clamp(5+7−4)=7)
    sc[2] = Core.neutralDesc(9);                      // 非 legacy 不变
    m.layers[Core.LAYER_FRONT].desc[3] = Core.neutralDesc(16);
    m.layers[Core.LAYER_BACK].desc[4] = Core.neutralDesc(18);
    const bg = m.layers[Core.LAYER_BG].rgba;
    bg[0] = 0xFF00FFFF;
    bg[1] = 0x000020FF;                               // texOf 恰好 = 2 的 RGBA:错迁它就现形
    const same = Core.migrateMap(m);
    eq(same === m, true, 'migrateMap:原地改写,交回同一个对象');
    tableEq('migrateMap:三个 tex 层都迁,color 层一个字节不动', [
      ['scene[0] tex2 → (1,hue3)', sc[0], Core.packDesc(1, 3, 4, 4, 7)],
      ['scene[1] (17,hue5) → (15,hue7)', sc[1], Core.packDesc(15, 7, 4, 4, 7)],
      ['scene[2] tex9 不变', sc[2], Core.neutralDesc(9)],
      ['front[3] tex16 → (15,hue2)', m.layers[Core.LAYER_FRONT].desc[3], Core.packDesc(15, 2, 4, 4, 7)],
      ['back[4] tex18 → (15,hue7)', m.layers[Core.LAYER_BACK].desc[4], Core.packDesc(15, 7, 4, 4, 7)],
      ['bg[0] RGBA 原样', bg[0] >>> 0, 0xFF00FFFF],
      ['bg[1] texOf=2 的 RGBA 也原样(color 层不是描述符)', bg[1] >>> 0, 0x000020FF],
    ]);
    const m2 = Core.createMap('mig2', 2, 1);
    m2.layers[Core.LAYER_FRONT] = null;               // 缺席层(layer_flags 缺位)
    m2.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(3);
    Core.migrateMap(m2);
    eq(m2.layers[Core.LAYER_SCENE].desc[0], Core.packDesc(1, 1, 4, 4, 7),
       'migrateMap:缺席层(null)跳过不抛,其余层照迁');
    eq(Core.migrateMap(null), null, 'migrateMap(null) → null(不抛)');
  })();

  // ④ v3 文本 / 旧字母格式:migrateV3 在产出 desc 时就迁移
  (function () {
    const m3 = Core.migrateV3(Core.parseV3Text('# cyrm-v3\n002f\n'));   // tex2 shape15(整格)
    eq(m3.layers[Core.LAYER_SCENE].desc[0], Core.packDesc(1, 3, 4, 4, 7),
       'v3 文本:tex2 → 迁移后的 (tex1,hue3)(去掉 migrateV3 里的 migrateDescriptor 即红)');
    const m4 = Core.migrateV3(Core.parseV3Text('22\n22\n'));             // 旧字母 '2' = tex2 满砖
    eq(m4.layers[Core.LAYER_SCENE].desc[0], Core.packDesc(1, 3, 4, 4, 7),
       '旧字母格式:字符 2(tex2)→ 迁移后的 (tex1,hue3)');
    const m5 = Core.migrateV3(Core.parseV3Text('# cyrm-v3\n009f\n'));   // tex9 非 legacy
    eq(m5.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(9),
       'v3 文本:非 legacy 纹理原样(中性)');
  })();

  // ⑤ validateMap 纹理闸 + encodeMap 拦截:legacy/越界 ⇒ error;合法/空气放行
  await (async function () {
    const mk = function (tex) {
      const m = Core.createMap('v', 4, 4);
      m.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(tex);
      m.players = [{ x: 1, y: 1 }];
      return m;
    };
    const hasErr = function (m) {
      return Core.validateMap(m).errors.some(function (s) { return s.indexOf('不在 tile_defs') >= 0; });
    };
    tableEq('validateMap:纹理闸(legacy 与越界是 error,合法与空气放行)', [
      ['legacy tex2 → error', hasErr(mk(2)), true],
      ['legacy tex18 → error', hasErr(mk(18)), true],
      ['越界 tex23 → error', hasErr(mk(23)), true],
      ['越界 tex4095 → error', hasErr(mk(4095)), true],
      ['合法 tex1 → 无 error', hasErr(mk(1)), false],
      ['合法 tex22 → 无 error', hasErr(mk(22)), false],
    ]);
    const air = Core.createMap('a', 4, 4); air.players = [{ x: 1, y: 1 }];
    eq(hasErr(air), false, 'validateMap:全空气的图不触发纹理闸(tex 0 不判)');
    ok(Core.validateMap(mk(16)).errors.join(';').indexOf('16') >= 0,
       'error 文案点名具体的纹理号(用户得知道是哪块砖)');
    // 迁移 → 校验 → 编码闭环:内存即干净 ⇒ 新保存的文件不再含 legacy id
    const mig = mk(2);
    Core.migrateMap(mig);
    eq(Core.validateMap(mig).errors, [], 'migrateMap 之后 errors 清零');
    const bytes = await Core.encodeMap(mig, { compress: false });
    const back = await Core.decodeMap(bytes);
    eq(back.layers[Core.LAYER_SCENE].desc[0], Core.packDesc(1, 3, 4, 4, 7),
       '迁移后的图可编码往返:写出去的就是迁移后的描述符');
    await rejects(function () { return Core.encodeMap(mk(3), { compress: false }); },
      'encodeMap:还带着 legacy id 的内存必须拒(手改内存的最后防线;去掉纹理闸即红)', '校验未通过');
  })();

  // ⑥ 表缺席(TILE_DEFS 没装的环境)必须是 no-op,不许抛 —— worker_io 等套件只装 core
  (function () {
    const saved = globalThis.TILE_DEFS;
    globalThis.TILE_DEFS = undefined;
    let threw = null, out = null;
    try { out = Core.migrateDescriptor(Core.neutralDesc(2)); } catch (e) { threw = e; }
    ok(threw === null, '表缺席:migrateDescriptor 不抛(实得 ' + (threw ? errText(threw) : 'null') + ')');
    eq(out, Core.neutralDesc(2), '表缺席:原样返回(没有表 = 不迁移)');
    const m = Core.createMap('nd', 2, 1);
    m.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(16);
    let threw2 = null;
    try { Core.migrateMap(m); } catch (e) { threw2 = e; }
    eq([threw2 === null, m.layers[Core.LAYER_SCENE].desc[0]], [true, Core.neutralDesc(16)],
       '表缺席:migrateMap 同样 no-op');
    eq(Core.validateMap(m).errors, [], '表缺席:validateMap 跳过纹理闸(没有表可判,不是"全非法")');
    globalThis.TILE_DEFS = saved;
  })();

})();
