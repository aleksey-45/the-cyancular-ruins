'use strict';
// 相位 ①~⑧:名字与格式分派 / 尺寸与纹理钳制 / 调色板 / 工具内核 / 油漆桶 / 渐变 / 改尺寸 / spawn 增删。
// 这些都是**纯内核**断言:没有 DOM,也没有接线;接线那一半在 40_interaction 起的分片里。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const TILE_DEFS = globalThis.TILE_DEFS;

module.exports = (async function () {

  // ── 相位 ① 名字与格式分派 ──
  tableEq('nameFromFile:只去掉**结尾**那个 .cyrm(大小写不敏感)', [
    ['普通名', Editor.nameFromFile('demo.cyrm'), 'demo'],
    ['大写后缀', Editor.nameFromFile('factory1v1.CYRM'), 'factory1v1'],
    ['中间的点保留', Editor.nameFromFile('a.b.cyrm'), 'a.b'],
    ['空串仍是空串', Editor.nameFromFile(''), ''],
  ]);

  const src = Core.createMap('x', 3, 2);
  src.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(7);
  const bytes = await Core.encodeMap(src);
  const out = await Editor.mapFromBytes('demo.cyrm', bytes);
  eq(out.sourceFormat, 'v4', 'mapFromBytes: v4 二进制');
  eq(out.map.name, 'demo', '★★ 导入必须用文件名补 map.name(decodeMap 返回的是空串)');
  eq(Core.sanitizeName(out.map.name), 'demo',
     '★★ 补完之后 sanitizeName **不**回落成 structure(v4 body 里没有 name 字段)');
  eq(Core.sanitizeName(''), 'structure', '(对照)空名字才会回落成 structure');
  eq(out.map.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(7), 'v4 内容读回来了');

  const enc = new TextEncoder();
  tableEq('detectFormat:嗅 magic / v3 标记 / 旧字母格式', [
    ['CYRM magic → v4 二进制', Editor.detectFormat(bytes), 'v4'],
    ['带 `# cyrm-v3` 标记 → v3 文本', Editor.detectFormat(enc.encode('# cyrm-v3\n001f001f\n')), 'v3'],
    ['无标记 → 旧字母格式', Editor.detectFormat(enc.encode('11\n11\n')), 'legacy'],
  ]);
  const o3 = await Editor.mapFromBytes('old.cyrm', enc.encode('# cyrm-v3\n001f001f\n'));
  eq(o3.sourceFormat, 'v3', 'mapFromBytes: v3 文本走迁移路径');
  eq(o3.map.name, 'old', 'v3 路径同样用文件名补 map.name');
  eq(o3.map.subCols, 8, 'v3: 2 格宽 → 8 子格');
  const o4 = await Editor.mapFromBytes('legacy.cyrm', enc.encode('11\n11\n'));
  eq(o4.sourceFormat, 'legacy', 'mapFromBytes: 旧字母格式(规格 §3.6 的第三种输入)');
  eq(o4.map.subCols, 4, 'legacy: 2×2 字符 → 1 格 = 4 子格');

  // ── 相位 ② 尺寸/纹理钳制(闸 1:用户输入一律钳制,不报错回滚)──
  tableEq('createEmptyMap 走 clampMapSize(闸 1:钳制而不是报错回滚)', [
    ['99999 格 → 400(宽)', Editor.createEmptyMap('x', 99999, 99999).subCols, 400 * SUB],
    ['99999 格 → 300(高)', Editor.createEmptyMap('x', 99999, 99999).subRows, 300 * SUB],
    ['0/负数 → 至少 1 格', Editor.createEmptyMap('x', 0, -5).subCols, 4],
    ['NaN → 默认 125×75', Editor.createEmptyMap('x', NaN, NaN).subCols, 125 * SUB],
  ]);
  // ★ 一条判定类别 = 一条守卫:7 条"一个数值一条断言"收成一张表 —— 失败时点名是哪一行。
  //   `cap` 那条**不能**给 0:Tint 对纹理号 0 会抛(空气另有描述符),所以钳制的下界是 1。
  tableEq('clampTexture:上界来自图集容量,下界恒为 1(绝不给 0)', [
    ['0 → 1(纹理号 0 是空气,给了就抛)', Editor.clampTexture(0, 100), 1],
    ['超过容量 → 钳到容量', Editor.clampTexture(999, 100), 100],
    ['正常值不动', Editor.clampTexture(3, 100), 3],
    ['NaN → 1', Editor.clampTexture(NaN, 100), 1],
    ['图集还没加载(cap 0)→ 1,不放宽', Editor.clampTexture(5, 0), 1],
    ['容量是负数(畸形图集)→ 1,不当"没有信息"放宽', Editor.clampTexture(5, -3), 1],
    ['容量缺省时问图集(node 没装图集 ⇒ 容量 0 ⇒ 1)', Editor.clampTexture(5, undefined), 1],
  ]);

  // ── 相位 ③ 调色板从 tile_defs 派生(纹理 22 不可点选)──
  const pal = Editor.texturePalette(TILE_DEFS);
  eq(pal.length, 21, '★ 调色板 21 项(1..22 去掉自动派生的 22)');
  ok(pal.every(function (e) { return e.tex !== 22; }),
     '★★ 纹理 22(水面)不在可点选调色板里 —— 游戏侧它是自动派生的,画了会不一致(A7)');
  eq(Editor.DERIVED_TEXTURES, [22], 'DERIVED_TEXTURES = [22](A7 那一条,写成常量便于 UI 提示)');
  ok(pal.every(function (e) { return e.tex > 0 && e.name.length > 0 && typeof e.type === 'string'; }),
     '调色板每项都有 tex/name/type');
  eq(pal.map(function (e) { return e.tex; }).join(','),
     pal.map(function (e) { return e.tex; }).sort(function (a, b) { return a - b; }).join(','),
     '调色板按纹理号升序(版面稳定)');
  eq(Editor.texturePalette(null), [], 'texturePalette(null) → 空数组(不抛)');

  // ── 相位 ④ 画笔/直线/矩形:目标集合与两种单位(格 / 子格)──
  let m = Core.createMap('t', 2, 1);                 // 2 格宽 × 1 格高 = 8 × 4 子格
  let st = stOf(m, Core.LAYER_SCENE);
  st.brushSize = 0.25;
  let d = Editor.applyTool(st, 'brush', { kind: 'sub', x: 0, y: 0 }, null);
  eq(d.idx.length, 1, '★ 0.25 画笔 = 1 个子格');
  eq(m.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(5), '那一格被写上了当前描述符');

  m = Core.createMap('t', 2, 1);
  st = stOf(m, Core.LAYER_SCENE);
  st.brushSize = 1;
  d = Editor.applyTool(st, 'brush', { kind: 'cell', x: 0, y: 0 }, null);
  eq(d.idx.length, 16, '★ 整数画笔 1 = 一整格(16 个子格;整数大小只画整格,不落在子格上)');
  eq(countNonZero(m, Core.LAYER_SCENE), 16, '地图上确实只有 16 个子格被写');

  m = Core.createMap('t', 2, 1);
  st = stOf(m, Core.LAYER_SCENE);
  st.brushSize = 3;
  d = Editor.applyTool(st, 'brush', { kind: 'cell', x: 0, y: 0 }, null);
  eq(d.idx.length, 32, '★ 3×3 格画笔在 2×1 的环面图上绕回:只剩 2 个不同的格 = 32 个子格');

  // 选区激活时绘制被约束在选区内
  m = Core.createMap('t', 2, 1);
  st = stOf(m, Core.LAYER_SCENE);
  st.brushSize = 1;
  st.selection = { x: 0, y: 0, w: 4, h: 4 };
  d = Editor.applyTool(st, 'brush', { kind: 'cell', x: 0, y: 0 }, null);
  eq(d.idx.length, 16, '★ C12:选区 {0,0,4,4} 内只有第 1 格那 16 个子格被画(选区约束绘制)');
  eq(Editor.applyTool(st, 'brush', { kind: 'cell', x: 1, y: 0 }, null), null,
     '★ 选区外的落笔 = 什么都没改(返回 null,不是"改了但不报错")');

  // 直线:坐标必须整数(否则 Core.lineCells 会**死循环挂住**)
  m = Core.createMap('t', 2, 1);
  st = stOf(m, Core.LAYER_SCENE);
  st.brushSize = 0.25;
  d = Editor.applyTool(st, 'line', { kind: 'sub', x: 0.7, y: 0.2 }, { kind: 'sub', x: 7.9, y: 0.6 });
  eq(d.idx.length, 8, '★★ 直线 (0.7,0.2)→(7.9,0.6) 先 floor 成 (0,0)→(7,0):8 个子格,而且**没有挂住**');
  eq(d.idx[0], 0, '直线从起点开始');
  eq(d.idx[7], 7, '直线到终点结束');

  // 矩形:跟随画笔的单位
  m = Core.createMap('t', 2, 1);
  st = stOf(m, Core.LAYER_SCENE);
  st.brushSize = 1;
  d = Editor.applyTool(st, 'rect', { kind: 'cell', x: 0, y: 0 }, { kind: 'cell', x: 1, y: 0 });
  eq(d.idx.length, 32, '矩形(整数画笔)按格:2 格 = 32 个子格');

  // 橡皮:置空气
  m = filled(Core.createMap('t', 2, 1), Core.LAYER_SCENE, Core.neutralDesc(3));
  st = stOf(m, Core.LAYER_SCENE);
  d = Editor.applyTool(st, 'eraser', { kind: 'cell', x: 0, y: 0 }, null);
  eq(d.idx.length, 16, '橡皮:改 16 个子格');
  eq(d.after[0], 0, '★ 橡皮写的是空气(0)');
  eq(countNonZero(m, Core.LAYER_SCENE), 16, '擦掉一格之后还剩 16 个非空');

  // 只改辅码(§4.4):空气仍是空气,有纹理的保留原纹理
  m = Core.createMap('t', 2, 1);
  m.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(5);       // 一格里的第 1 个子格
  st = stOf(m, Core.LAYER_SCENE);
  st.desc = Core.packDesc(9, 0, 0, 0, 0);                          // 换个明显不同的辅码
  st.descOnly = true;
  st.brushSize = 1;
  d = Editor.applyTool(st, 'brush', { kind: 'cell', x: 0, y: 0 }, null);
  eq(d.idx.length, 1, '★★ 只改辅码:只有**本来就有纹理**的那 1 个子格进了差量(空气不长纹理)');
  const v = m.layers[Core.LAYER_SCENE].desc[0];
  eq(Core.texOf(v), 5, '★ 只改辅码:纹理仍是 5(没被画笔描述符里的 9 顶掉)');
  eq(Core.hueOf(v), 0, '★ 只改辅码:辅码换成了画笔的(色相档 0)');
  ok(m.layers[Core.LAYER_SCENE].desc[1] === 0, '★ 只改辅码:空气格**没有**被写成 0x9xxx(仍然没纹理)');

  // 背景层写的是颜色不是描述符
  m = Core.createMap('t', 2, 1);
  st = stOf(m, Core.LAYER_BG);
  st.rgba = 0x11223344;
  st.brushSize = 0.25;
  d = Editor.applyTool(st, 'brush', { kind: 'sub', x: 3, y: 2 }, null);
  eq(m.layers[Core.LAYER_BG].rgba[2 * 8 + 3], 0x11223344, '背景层:写的是 RGBA(不是描述符)');
  eq(Editor.pickAt(m, Core.LAYER_BG, 3, 2), 0x11223344, '吸管:背景层取回颜色');

  // ── 相位 ⑤ 油漆桶:跨环面 + 分帧(闸 2)──
  const mb = filled(Core.createMap('t', 2, 1), Core.LAYER_SCENE, Core.neutralDesc(3));
  const job = Editor.createBucketJob(mb, Core.LAYER_SCENE, 7, 3, {});
  const chunks = [];
  let r = job.runChunk(4);
  chunks.push(r.scanned);
  let guard = 0;
  while (!r.done && guard++ < 100) { r = job.runChunk(4); chunks.push(r.scanned); }
  ok(r.done, '油漆桶:跑完了');
  eq(job.result().length, 32, '★★ 油漆桶跨环面:(7,3) 起填能把**全部 32 个子格**填到(接缝另一侧的也算)');
  ok(chunks.every(function (n) { return n <= 4; }) && chunks.length === 8,
     '★ 分帧:每个 runChunk(4) 至多推进 4 格、32 格共 8 次(实得 ' + JSON.stringify(chunks) + ')');
  eq(job.runChunk(4), { done: true, scanned: 0, total: 32 }, '跑完之后再调 runChunk 是 no-op(幂等)');

  // 边界:另一种纹理挡住填充
  const m2 = filled(Core.createMap('t', 2, 1), Core.LAYER_SCENE, Core.neutralDesc(3));
  m2.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(9);
  const job2 = Editor.createBucketJob(m2, Core.LAYER_SCENE, 7, 3, {});
  let r2 = job2.runChunk(64);
  guard = 0;
  while (!r2.done && guard++ < 100) { r2 = job2.runChunk(64); }
  eq(job2.result().length, 31, '油漆桶:遇到不同纹理就停(32 − 1 = 31)');

  // 种子本身是空气也要能填(给空图上色最常用)
  const m3 = Core.createMap('t', 2, 1);
  const job3 = Editor.createBucketJob(m3, Core.LAYER_SCENE, 0, 0, {});
  let r3 = job3.runChunk(64);
  guard = 0;
  while (!r3.done && guard++ < 100) { r3 = job3.runChunk(64); }
  eq(job3.result().length, 32, '★ 种子是空气也能填(空图 32 个子格)');

  // ── 相位 ⑥ 渐变(仅背景层)──
  const mg = Core.createMap('t', 2, 1);
  const gj = Editor.createGradientJob(mg, { x: 0, y: 0 }, { x: 7, y: 0 }, 0x000000FF, 0xFFFFFFFF, {});
  let gr = gj.runChunk(64);
  guard = 0;
  while (!gr.done && guard++ < 100) { gr = gj.runChunk(64); }
  const res = gj.result();
  eq(res.length, 32, '渐变覆盖全图(32 个子格)');
  const byIdx = {};
  res.forEach(function (o) { byIdx[o.i] = o.rgba; });
  eq(byIdx[0], 0x000000FF, '★ 渐变起点 = 起点色(黑,alpha 满)');
  eq(byIdx[7], 0xFFFFFFFF, '★ 渐变终点 = 终点色(白)');
  const mid = byIdx[3];
  ok(((mid >>> 8) & 255) > 100 && ((mid >>> 8) & 255) < 160,
     '★ 中点是插值出来的灰(实得 ' + ((mid >>> 8) & 255) + ',应在 100~160)');
  throws(function () {
    Editor.createGradientJob(mg, { x: 0, y: 0 }, { x: 3, y: 0 }, 0, 0, { layer: Core.LAYER_SCENE });
  }, '★ 渐变用在纹理层 → 抛错(规格 §4.4:渐变**仅背景层**)', '背景层');

  // ── 相位 ⑦ 改尺寸(A8/A10)──
  const mr = Core.createMap('t', 2, 1);
  mr.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(4);
  mr.players = [{ x: 1, y: 0 }, { x: 9, y: 9 }];
  mr.enemies = [{ type: 'fly_bird', x: 0, y: 0 }, { type: 'jump_bird', x: 40, y: 40 }];
  const rz = Editor.resizeMap(mr, 4, 3);
  eq(rz.size, { w: 4, h: 3 }, 'resizeMap: 4×3');
  eq(rz.map.subCols, 16, 'resizeMap: 子格数跟着变');
  eq(rz.map.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4), '★ 重叠区的内容被保留');
  eq(rz.map.players.length, 1, '★ 越界的出生点被丢掉(留在图外 = 游戏读到网格外坐标,A10)');
  eq(rz.dropped.length, 2, '★★ 丢掉的项**报告**出来(1 个出生点 + 1 个敌人),不静默');
  eq(rz.dropped[0], { kind: 'player', x: 9, y: 9 }, 'dropped 里点名了是哪个出生点');
  eq(rz.dropped[1], { kind: 'enemy', type: 'jump_bird', x: 40, y: 40 }, 'dropped 里点名了是哪个敌人');
  eq(rz.map.enemies.length, 1, '图内的敌人留着');
  eq(Editor.resizeReportLines(rz.dropped).length, 2, '★ resizeReportLines 给出 2 行(给状态栏/弹窗用)');
  ok(Editor.resizeReportLines(rz.dropped)[0].indexOf('出生点') >= 0,
     '报告的措辞点名了"出生点"(用户要知道丢了什么)');

  const rz2 = Editor.resizeMap(mr, 99999, 99999);
  eq(rz2.size, { w: 400, h: 300 }, '★★ resizeMap 也走 clampMapSize(输 99999 变成 400×300,不卡死)');
  eq(rz2.dropped.length, 0, '放大不会丢任何东西');

  // ── 相位 ⑧ spawn 增删(A9:出生点/敌人也要进历史)──
  const ms = Core.createMap('t', 4, 3);
  const d1 = Editor.addSpawn(ms, 'player', 1, 1);
  eq(ms.players.length, 1, 'addSpawn: 放了一个出生点');
  eq(d1.kind, 'spawn', '★★ 差量是 spawn 类(审计 A9:出生点/敌人的增删必须在历史里)');
  eq(d1.before.players.length, 0, '差量里记着 before(0 个)');
  eq(d1.after.players.length, 1, '差量里记着 after(1 个)');
  eq(Editor.spawnIndexAt(ms, 1, 1), { kind: 'player', index: 0 }, 'spawnIndexAt: 命中');
  Editor.addSpawn(ms, 'enemy', 3, 2, 'fly_bird');
  eq(ms.enemies.length, 1, 'addSpawn(敌人)');
  eq(ms.enemies[0].type, 'fly_bird', '★ 敌人的 type 来自注册表(不是写死的)');
  const d3 = Editor.removeSpawn(ms, 'player', 0);
  eq(ms.players.length, 0, 'removeSpawn');
  ok(d3.before.players.length === 1 && d3.after.players.length === 0, 'removeSpawn 的差量也是整表前后');
  eq(Editor.spawnIndexAt(ms, 4, 2), null, '★ spawnIndexAt 用环面坐标判:(4,2) 与 (3,2) 不是同一个格');
  ok(Editor.spawnIndexAt(ms, 3 - 4, 2) !== null, '★ spawnIndexAt 折算环面:(−1,2) 与 (3,2) 是同一个格');

})();
