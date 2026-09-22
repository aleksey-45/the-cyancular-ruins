'use strict';
// Node 冒烟 —— ui.js 的**纯半边**:工具内核 / 尺寸与纹理钳制 / 名字 / 热键 / 源码纪律。
// Run: cd level_editor && node editor_smoke.js
// 判据:文本 `EDITOR SMOKE OK` + 退出码 0。
// ★ 加载顺序:core → (tile_defs) → tint → render → io → ui。
// ★ `-s` 阶段与 autoload 无关(这是浏览器侧代码,不存在 Godot autoload)。

globalThis.window = globalThis;              // tile_defs.js 是 `window.TILE_DEFS = {…}`

// ★★ Worker 替身(node 里 `typeof Worker === 'undefined'`)。
//    为什么必须有:相位 ① 的 v4 二进制要走 `Editor.mapFromBytes` → `Io.decodeMap`,
//    而 io.js 的 defaultFactory 在没有 Worker 时**会抛**(闸 3 没有降级路径,这是对的)
//    ⇒ 整条冒烟在相位 ① 就死在一次拒绝上(F2),后面的相位一行都跑不到。
//    ★ 本文件**不写第二份协议**:worker.js 是经典脚本,只用 `importScripts` 与 `self`
//      两个全局(与 worker_io_smoke.js 同一个手法)——打桩这两个名字就能把**真的**
//      worker.js 装进来、用真的消息协议跑真的 core.js。替身只做"把 postMessage
//      转给 self.onmessage、把 self.postMessage 转回实例的 onmessage"这件事。
globalThis.importScripts = function () { /* core.js 已经加载过 */ };
const inProc = { onmessage: null, postMessage: null };
globalThis.self = inProc;
require('./worker.js');                      // ← 定义 inProc.onmessage
// ★ 一个 codec 只起一个 worker(io.js 的 sharedCodec),故"当前实例"是确定的。
let liveWorker = null;
globalThis.Worker = function () {
  const w = this;
  this.onmessage = null;
  this.onerror = null;
  this.terminate = function () { /* 无副作用 */ };
  this.postMessage = function (msg) {
    liveWorker = w;
    inProc.postMessage = function (reply) { if (w.onmessage) w.onmessage({ data: reply }); };
    inProc.onmessage({ data: msg });
  };
};

require('./core.js');
require('./tile_defs.js');
require('./tint.js');
require('./render.js');
require('./io.js');
require('./ui.js');
const fs = require('fs');
const path = require('path');
const Core = globalThis.Core;
const Render = globalThis.Render;
const Editor = globalThis.Editor;
const TILE_DEFS = globalThis.TILE_DEFS;

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function throws(fn, msg, expectSub) {
  let e = null;
  try { fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && String(e.message).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + e.message); return;
  }
  pass++; console.log('  ok  - ' + msg);
}
const SUB = Core.SUB_PER_CELL;
function stOf(map, L) {
  return { map: map, layer: L, desc: Core.neutralDesc(5), rgba: 0xFF00FFFF,
           brushSize: 1, selection: null, descOnly: false };
}
function filled(map, L, desc) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (let i = 0; i < a.length; i++) a[i] = desc;
  return map;
}
function countNonZero(map, L) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== 0) n++;
  return n;
}

(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 某个断言挂住了(多半是 lineCells 拿到非整数坐标)');
    process.exit(1);
  }, 120000);

  try {
    // ==== 相位 ① 名字与格式分派(账本必须带进 2b 的那条)====
    eq(Editor.nameFromFile('demo.cyrm'), 'demo', 'nameFromFile: 去掉 .cyrm 后缀');
    eq(Editor.nameFromFile('factory1v1.CYRM'), 'factory1v1', 'nameFromFile: 大小写不敏感');
    eq(Editor.nameFromFile('a.b.cyrm'), 'a.b', 'nameFromFile: 只去掉**结尾**那个后缀');
    eq(Editor.nameFromFile(''), '', 'nameFromFile: 空串仍是空串');

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

    eq(Editor.detectFormat(bytes), 'v4', 'detectFormat: 嗅 magic');
    const enc = new TextEncoder();
    eq(Editor.detectFormat(enc.encode('# cyrm-v3\n001f001f\n')), 'v3', 'detectFormat: 带标记 = v3 文本');
    eq(Editor.detectFormat(enc.encode('11\n11\n')), 'legacy', 'detectFormat: 无标记 = 旧字母格式');
    const o3 = await Editor.mapFromBytes('old.cyrm', enc.encode('# cyrm-v3\n001f001f\n'));
    eq(o3.sourceFormat, 'v3', 'mapFromBytes: v3 文本走迁移路径');
    eq(o3.map.name, 'old', 'v3 路径同样用文件名补 map.name');
    eq(o3.map.subCols, 8, 'v3: 2 格宽 → 8 子格');
    const o4 = await Editor.mapFromBytes('legacy.cyrm', enc.encode('11\n11\n'));
    eq(o4.sourceFormat, 'legacy', 'mapFromBytes: 旧字母格式(规格 §3.6 的第三种输入)');
    eq(o4.map.subCols, 4, 'legacy: 2×2 字符 → 1 格 = 4 子格');

    // ==== 相位 ② 尺寸/纹理钳制(闸 1:用户输入钳制,不报错回滚)====
    eq(Editor.createEmptyMap('x', 99999, 99999).subCols, 400 * SUB, '★★ createEmptyMap 走 clampMapSize:99999 → 400 格');
    eq(Editor.createEmptyMap('x', 99999, 99999).subRows, 300 * SUB, '★ 同上,高 → 300 格');
    eq(Editor.createEmptyMap('x', 0, -5).subCols, 4, 'createEmptyMap: 0/负数 → 至少 1 格');
    eq(Editor.createEmptyMap('x', NaN, NaN).subCols, 125 * SUB, 'createEmptyMap: NaN → 默认 125×75');
    eq(Editor.clampTexture(0, 100), 1, 'clampTexture: 0 → 1');
    eq(Editor.clampTexture(999, 100), 100, '★ clampTexture: 超过图集容量 → 钳到容量(Tint 对越界会抛)');
    eq(Editor.clampTexture(3, 100), 3, 'clampTexture: 正常值不动');
    eq(Editor.clampTexture(NaN, 100), 1, 'clampTexture: NaN → 1');
    eq(Editor.clampTexture(5, 0), 1, '★ clampTexture: 图集还没加载(cap 0)→ 1,绝不给 0(Tint 对 0 会抛)');
    // ★★ 上界**派生自图集**,不许硬编码(见相位 ⑪ 的同名扫描):容量缺席时自己问 Render。
    //    ★ 而"容量 < 1"这一档给 **1**,不给出格式上界 —— 后者会把 101..上界 全部放进
    //      tileFor 再当场抛(render.js 的 atlasCapacity 注释里点过这条路;负容量是它的
    //      具体形态:畸形图集高算出负数,再被当成"没信息"静默放宽)。
    eq(Editor.clampTexture(5, -3), 1, '★★ 容量是负数(畸形图集)→ 1,不当"没信息"放宽');
    eq(Editor.clampTexture(5, undefined), 1, '★ 容量缺省时问图集:node 里没装图集 ⇒ 容量 0 ⇒ 1');

    // ==== 相位 ③ 调色板从 tile_defs 派生(审计 A7:纹理 22 不可选)====
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

    // ==== 相位 ④ 画笔/直线/矩形:目标集合与**两种单位** ====
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

    // C12:选区激活时绘制被约束在选区内
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

    // ==== 相位 ⑤ 油漆桶:跨环面 + 分帧(闸 2)====
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

    // ==== 相位 ⑥ 渐变(仅背景层)====
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
    eq(Editor.lerpRGBA(0x00000000, 0xFFFFFFFF, 0.5), 0x80808080, 'lerpRGBA: 半程插值(每通道独立四舍五入)');
    eq(Editor.lerpRGBA(0x11223344, 0x11223344, 1), 0x11223344, 'lerpRGBA: t=1 → 终点色');
    throws(function () {
      Editor.createGradientJob(mg, { x: 0, y: 0 }, { x: 3, y: 0 }, 0, 0, { layer: Core.LAYER_SCENE });
    }, '★ 渐变用在纹理层 → 抛错(规格 §4.4:渐变**仅背景层**)', '背景层');

    // ==== 相位 ⑦ 改尺寸(A8/A10)====
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

    // ==== 相位 ⑧ spawn 增删(A9:出生点/敌人也要进历史)====
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

    // ==== 相位 ⑨ 热键表(规格 §4.8)====
    const k = function (key, mod) { return { key: key, ctrl: !!mod, meta: false, shift: false }; };
    eq(Editor.commandFor(k('b')), 'tool:brush', 'B → 画笔');
    eq(Editor.commandFor(k('e')), 'tool:eraser', 'E → 橡皮');
    eq(Editor.commandFor(k('g')), 'tool:bucket', 'G → 油漆桶');
    eq(Editor.commandFor(k('m')), 'tool:select', 'M → 选框');
    eq(Editor.commandFor(k('l')), 'tool:line', 'L → 直线');
    eq(Editor.commandFor(k('i')), 'tool:picker', 'I → 吸管');
    eq(Editor.commandFor(k('[')), 'brush-smaller', '[ → 画笔变小');
    eq(Editor.commandFor(k(']')), 'brush-bigger', '] → 画笔变大');
    eq(Editor.commandFor(k('2')), 'layer:2', '2 → 切到图层 2');
    eq(Editor.commandFor(k('z', true)), 'undo', 'Ctrl+Z → 撤销');
    eq(Editor.commandFor({ key: 'Z', ctrl: true, shift: true }), 'redo', 'Ctrl+Shift+Z → 重做');
    eq(Editor.commandFor(k('y', true)), 'redo', 'Ctrl+Y → 重做');
    eq(Editor.commandFor(k('c', true)), 'copy', 'Ctrl+C → 复制');
    eq(Editor.commandFor(k('x', true)), 'cut', 'Ctrl+X → 剪切');
    eq(Editor.commandFor(k('v', true)), 'paste', 'Ctrl+V → 粘贴');
    eq(Editor.commandFor(k('s', true)), 'save', 'Ctrl+S → 保存');
    eq(Editor.commandFor({ key: 'S', ctrl: true, shift: true }), 'save-as', 'Ctrl+Shift+S → 另存为');
    eq(Editor.commandFor(k('Delete')), 'clear-selection', 'Delete → 清空选区');
    eq(Editor.commandFor(k('Backspace')), 'clear-selection', 'Backspace → 清空选区');
    eq(Editor.commandFor(k('Escape')), 'cancel-selection', 'Esc → 取消选区');
    eq(Editor.commandFor(k('ArrowLeft')), 'pan:left', '← → 向左平移');
    eq(Editor.commandFor(k('ArrowDown')), 'pan:down', '↓ → 向下平移');
    eq(Editor.commandFor(k('F5')), null, '★ 表外的键一律返回 null(不拦浏览器自己的快捷键)');
    eq(Editor.commandFor({ key: 'p', ctrl: true }), null, '★ 表外的 Ctrl 组合也返回 null(打印留给浏览器)');

    // Shift 约束(规格 §4.8:直线约束 / 选区等比)
    // ★★ 下面三条的期望字面量**订正过**(计划原文的值不自洽,见每条的 ★★ 说明):
    //    · 两条 45° 的原文写的是**不按 Shift** 的结果(即 b 的 floor),与"锁成 45°"
    //      以及同段里 `{0,0}→{10,3}` 那条(它期望的是**锁过的** {10,10})互斥;
    //    · 选区那条原文写 {x:-6,y:1},而 |dx|=4、|dy|=3 ⇒ 等比只能是 {0,0}。
    //    一律按规格 §4.8 的字面("其余 → 锁成 45°(取两轴较大者)"/"选区等比")取实现那一侧。
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: 10, y: 2 }, true), { x: 10, y: 0 },
       '★ Shift 直线:近水平 → 锁成水平');
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: 2, y: 10 }, true), { x: 0, y: 10 },
       '★ Shift 直线:近垂直 → 锁成垂直');
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: 10, y: 8 }, true), { x: 10, y: 10 },
       '★ Shift 直线:其余 → 锁成 45°(取两轴较大者;★★ 订正:计划原文写 {x:10,y:8} —— 那是"不按 Shift"的结果)');
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: -10, y: 8 }, true), { x: -10, y: 10 },
       '★ 45° 也要带对方向(负方向不翻正;★★ 订正:原文写 {x:-10,y:8},理由同上一条)');
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: 7.9, y: 0.6 }, false), { x: 7, y: 0 },
       '★★ 不按 Shift:只 floor(NaN/小数会让 Core.lineCells 死循环挂住)');
    eq(Editor.constrainSquare({ x: 0, y: 0 }, { x: 10, y: 3 }, true), { x: 10, y: 10 },
       '★ Shift 选区:等比(取两轴较大者,变成正方形)');
    eq(Editor.constrainSquare({ x: 4, y: 4 }, { x: 0, y: 1 }, true), { x: 0, y: 0 },
       '★ Shift 选区:方向朝左上时同样等比(★★ 订正:原文写 {x:-6,y:1} —— |dx|=4、|dy|=3,等比只能是 {0,0})');

    // ==== 相位 ⑩ 校验清单(§4.7)====
    const mv = Core.createMap('t', 2, 1);
    const lines = Editor.validateLines(Core.validateMap(mv));
    ok(lines.length >= 2, '★ 空图的校验清单至少两条(没有出生点 / 四层全空),实得 ' + lines.length);
    ok(lines.some(function (l) { return l.indexOf('出生点') >= 0; }), '清单里点名了"出生点"');
    ok(lines.some(function (l) { return l.indexOf('空') >= 0; }), '清单里点名了"四层全空"');
    eq(Editor.validateLines({ errors: [], warnings: [] }), [], '没有问题时清单是空的');
    ok(Editor.validateLines({ errors: ['坏文件'], warnings: [] })[0].indexOf('坏') >= 0,
       'errors 也进清单(errors 是"导出去就是坏文件")');

    // ==== 相位 ⑪ 源码纪律(★ 这些断言从 server_smoke 的相位 ⑧ 搬来)====
    // ★ 为什么搬家:相位 ⑧ 扫的是**页面文本**,而 2b 之后这些纪律住在 ui.js / render.js
    //   的**源码**里;留在页面文本上会变成对着不存在代码的假绿(探针要教,不要删)。
    const ui = fs.readFileSync(path.join(__dirname, 'ui.js'), 'utf8');
    const rd = fs.readFileSync(path.join(__dirname, 'render.js'), 'utf8');
    ok(ui.indexOf('rgbToHsv') < 0 && ui.indexOf('hsvToRgb') < 0 &&
       rd.indexOf('rgbToHsv') < 0 && rd.indexOf('hsvToRgb') < 0,
       '★ ui.js / render.js 里没有第二份 HSV 数学(一律走 Tint.*)');

    // ★★ lineCells 的每个调用点都要先 Math.floor —— 非整数坐标会让它**死循环挂住标签页**
    let bad = 0, calls = 0;
    ui.split('\n').forEach(function (l) {
      if (l.indexOf('Core.lineCells(') < 0) return;
      calls++;
      if (l.indexOf('Math.floor') < 0) bad++;
    });
    ok(calls > 0 && bad === 0,
       '★★ Core.lineCells 的每个调用点都在同一行先 Math.floor(实得 ' + calls + ' 处,未 floor 的 ' + bad + ' 处)');

    // ★ createMap 只许经过一个闸(clampMapSize),否则就是 A8 原样复发
    // ★★ 2026-09-21 订正:初版断言"只出现 **1** 次",但 `ui.js` 里**确实有两处** ——
    //    `createEmptyMap`(经 `clampMapSize`,是唯一的造图入口)与 Task 3 的 `selfTest()`
    //    (写死的 4×3 测试图,**不是用户输入**)。数成 1 会让这条断言**不可能通过**。
    //    改成"逐处点名"的记账:恰好两处 —— 牙齿留在**钳制**那半边(下面那条 clampMapSize)。
    eq((ui.match(/Core\.createMap\(/g) || []).length, 2,
       '★★ ui.js 里 Core.createMap 恰好两处(createEmptyMap 与 selfTest 的写死测试图;多一处就是新开了造图入口)');
    ok(/function createEmptyMap[\s\S]{0,200}Core\.clampMapSize/.test(ui),
       '★★ createEmptyMap 走 clampMapSize(createMap 自己不判上限:输 99999 会分配巨图卡死)');

    // ★ 象限几何不许在 UI 层重算(subcellRender 对越界象限会抛,调用方必须先 posmod)
    ok(ui.indexOf('subcellRender') < 0 && rd.indexOf('subcellRender') < 0,
       '★ ui.js / render.js 不直接调 Core.subcellRender(象限几何在 tint.js 内部走 quadIndex;' +
       '直接调必须先 posmod,漏了就是越界抛错)');

    // ★ 上界必须**派生自图集**,不许硬编码 4095(或任何别的数字)
    //   ★ 为什么这条要扫源码:钳错了**不报错** —— 放 101..4095 进去,tint 的越界判据是
    //     "图集里有没有这一块",要到 tileFor 那一句才抛,而且每帧同一处抛一屏。
    ok(ui.indexOf('4095') < 0,
       '★★ ui.js 里没有硬编码的 4095(上界一律来自 Render.atlasCapacity() 的实参)');
    ok(/function clampTexture[\s\S]{0,700}Render\.atlasCapacity\(\)/.test(ui),
       '★★ clampTexture 的容量缺省时**自己问图集**(Render.atlasCapacity()),不写死数码');

    // ★ PUT 必须显式带 Content-Type(写端点只收 application/json;不带 = 415)
    ok(/method:\s*['"`]PUT['"`]/.test(ui), '★ ui.js 有 PUT 调用(写端点;GET 都是只读的)');
    ok(/['"`]Content-Type['"`]\s*:\s*['"`]application\/json['"`]/.test(ui),
       '★★ PUT 显式设 Content-Type: application/json(不设 = 浏览器给 Blob 的默认类型 ⇒ 415 ⇒ 用户看到"存不进去")');
    // ★★ 光扫字符串还不够:上面两条只证明"字面量在源码里",不证明"发出的请求带着它"。
    //    这里把 fetch 换成一个记账的桩,**真调一次**写端点,断言 init 里的三件事。
    //    (★ 写端点的编排属于 Task 8;Task 5 落的是**唯一发 PUT 的那个出口** —— 纪律
    //     在源码里、也在行为里,Task 8 的保存流程调它,不再自己拼 fetch。)
    const sent = [];
    const realFetch = globalThis.fetch;
    globalThis.fetch = function (url, init) {
      sent.push({ url: url, init: init });
      return Promise.resolve({ ok: true, status: 200, json: function () { return Promise.resolve({ name: 'x.cyrm', size: 12 }); } });
    };
    try {
      const wout = await Editor.putMapBytes('x.cyrm', new Uint8Array([1, 2, 3]));
      eq(sent.length, 1, '★ putMapBytes 真发了**一次**请求');
      ok(sent[0].url.indexOf('/api/map?p=x.cyrm') >= 0, '★ 写端点带上了文件名');
      eq(sent[0].init.method, 'PUT', '★★ 行为断言:请求方法就是 PUT(不只是源码里出现过这个词)');
      eq(sent[0].init.headers && sent[0].init.headers['Content-Type'], 'application/json',
         '★★ 行为断言:请求头真的带 Content-Type: application/json(少了它就是 415)');
      eq(wout, { name: 'x.cyrm', size: 12 }, 'putMapBytes: 交回服务器那份应答(调用方要报字节数)');
    } finally {
      globalThis.fetch = realFetch;
    }

    // ★★ 视图入口的每个调用点都必须**收口**(Task 4 之后它们返回分帧重建派生出来的
    //    promise:抛在任务回调里 = 一次拒绝,同步 try/catch 接不住)——
    //    要么落在同一行的 `guard(` 里,要么被 `await` / `Promise.resolve(...)` 接住。
    const VIEW_ENTRIES = ['resize', 'fit', 'setView', 'setZoomAt', 'panBy', 'setMap', 'invalidateAll'];
    let vcalls = 0, vbad = 0;
    ui.split('\n').forEach(function (l) {
      let hit = false;
      VIEW_ENTRIES.forEach(function (n) { if (l.indexOf('app.r.' + n + '(') >= 0) hit = true; });
      if (!hit) return;
      vcalls++;
      if (l.indexOf('guard(') < 0 && l.indexOf('await ') < 0 && l.indexOf('Promise.resolve(') < 0) vbad++;
    });
    ok(vcalls > 0 && vbad === 0,
       '★★ 视图入口的调用点全部收口(实得 ' + vcalls + ' 处,没收口的 ' + vbad + ' 处 —— 漏了就是"按了没反应")');

    // ==== 相位 ⑪b 错误可见性(★ 症状"按了没反应"的那条通道)====
    // ★★ 为什么这一条比别处都重要:面板与渲染里抛出的异常若只是被吞掉,用户看到的是
    //    "点了没反应";而 Task 4 之后 resize/fit/setView/setZoomAt/panBy 的失败发生在
    //    **分帧重建的任务回调里**,是一次 promise 拒绝 —— 旧的同步 try/catch 接不住,
    //    画布默默停在上一帧。故 guard 必须同时接住这两条,并报到**屏幕上的同一条通道**
    //    (可替换的 sink:默认状态栏,mount 的 onError 也指到它)。
    const seen = [];
    Editor.setErrorSink(function (text) { seen.push(String(text)); });
    ok(/Render\.mount\([^)]*onError:\s*reportError/.test(ui),
       '★★ mount 的 onError 指到同一个 sink(渲染侧的失败也走这条通道,不靠 render 自己去摸 Editor.status)');
    ok(/setErrorSink:\s*setErrorSink/.test(ui), '★ setErrorSink 在导出表里(可替换的报错通道)');

    eq(Editor.guard('工具', function () { throw new Error('画布炸了'); }), null,
       '★ guard:同步抛出时返回 null(调用方不必自己判异常)');
    ok(seen.length === 1 && seen[0].indexOf('画布炸了') >= 0 && seen[0].indexOf('工具') >= 0,
       '★★ 同步抛出**上报**给了 sink(不是被吞掉):' + JSON.stringify(seen));

    // 真实的落笔路径抛错(注入一个会抛的值函数)⇒ 一样必须可见,不许静默空面板
    const mp = Core.createMap('t', 2, 1);
    seen.length = 0;
    const painted = Editor.guard('落笔', function () {
      return Editor.paintCells(mp, Core.LAYER_SCENE, [0], function () { throw new Error('描述符非法'); });
    });
    eq(painted, null, '★ 抛错的落笔路径:guard 交回 null(调用方不必自己判)');
    ok(seen.length === 1 && seen[0].indexOf('描述符非法') >= 0,
       '★★ **抛错的落笔**产出一条可见消息(而不是静默空面板):' + JSON.stringify(seen));
    eq(countNonZero(mp, Core.LAYER_SCENE), 0, '★ 抛错的那一笔一个字都没写进地图(不留半截状态)');

    // 视图入口的 promise 拒绝(分帧重建在任务回调里抛)⇒ 同一通道 + 交回的 promise 已收口
    seen.length = 0;
    let settled = null;
    await Editor.guard('视图', function () { return Promise.reject(new Error('分帧里炸了')); })
      .then(function () { settled = 'resolved'; }, function () { settled = 'rejected'; });
    ok(settled === 'resolved' && seen.length === 1 && seen[0].indexOf('分帧里炸了') >= 0,
       '★★ 视图入口的**拒绝**同样上报这条通道,且交回的 promise 已收口(调用方忘了 await 也不会冒' +
       '"未处理的 promise 拒绝"):' + JSON.stringify(seen));
    Editor.setErrorSink(null);          // 还原默认通道(后面的断言不再借它)

    // ==== 相位 ⑫ 历史 / 剪贴板 / 选区移动(A1 的重写)====
    // 差量历史:200 步 + 字节预算(闸 1)
    const hist = Editor.createHistory({});
    eq(Editor.MAX_UNDO, 200, 'MAX_UNDO = 200(规格 §4.3 闸 1)');
    eq(hist.depth(), 0, '新历史是空的');
    const hm = Core.createMap('h', 2, 1);
    hist.push({ kind: 'cells', layer: Core.LAYER_SCENE, idx: Int32Array.from([0]),
                before: Uint32Array.from([0]), after: Uint32Array.from([Core.neutralDesc(1)]) });
    eq(hist.depth(), 1, 'push 之后深度 1');
    ok(hist.undo() !== null, 'undo 返回被撤销的那一条');
    eq(hist.depth(), 0, 'undo 之后深度 0');
    eq(hist.redoDepth(), 1, 'redo 栈里有 1 条');
    ok(hist.redo() !== null, 'redo 返回被重做的那一条');
    hist.push(null);
    eq(hist.depth(), 1, '★ push(null) 不记(空操作不进历史)');

    // 200 步上限:第 201 步起把最老的挤掉
    const h2 = Editor.createHistory({ maxSteps: 3 });
    [[0, 1], [0, 2], [0, 3], [0, 4]].forEach(function (pair) {
      h2.push({ kind: 'cells', layer: Core.LAYER_SCENE, idx: Int32Array.from([pair[0]]),
                before: Uint32Array.from([pair[1] - 1]), after: Uint32Array.from([pair[1]]) });
    });
    eq(h2.depth(), 3, '★ maxSteps 3:第 4 条挤掉最老的,深度守住 3');
    const hm2 = Core.createMap('h', 2, 1);
    hm2.layers[Core.LAYER_SCENE].desc[0] = 4;
    Editor.applyEntry(hm2, h2.undo(), -1);
    eq(hm2.layers[Core.LAYER_SCENE].desc[0], 3, '撤销写回 before');
    Editor.applyEntry(hm2, h2.undo(), -1);
    Editor.applyEntry(hm2, h2.undo(), -1);
    eq(h2.depth(), 0, '撤到底');
    eq(hm2.layers[Core.LAYER_SCENE].desc[0], 1, '★★ 只能撤到"最老的那条"为止(被挤掉的那步回不去)');
    eq(h2.undo(), null, '空历史 undo → null(不抛)');

    // 字节预算:超了就从最老的开始丢
    const h3 = Editor.createHistory({ maxSteps: 200, maxBytes: 800 });
    const mkDiff = function (n) {
      return { kind: 'cells', layer: Core.LAYER_SCENE, idx: new Int32Array(n),
               before: new Uint32Array(n), after: new Uint32Array(n) };
    };
    h3.push(mkDiff(20));                       // 12 + 20*4*3 = 252 字节
    h3.push(mkDiff(20));
    h3.push(mkDiff(20));
    eq(h3.depth(), 3, '★ 字节预算内:3 条都留着(756 ≤ 800)');
    h3.push(mkDiff(20));
    ok(h3.depth() === 3 && h3.bytes() <= 800, '★★ 超字节预算 → 丢最老的,且字节数回落到预算内(实得 ' +
       h3.depth() + ' 条 / ' + h3.bytes() + ' 字节)');
    ok(Editor.bytesOfEntry(mkDiff(20)) > 0, 'bytesOfEntry 给出正数(字节预算是按它算的)');

    // 整图级(改尺寸)也能撤
    const hw = Core.createMap('w', 2, 1);
    hw.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(4);
    const wd = Editor.wholeDiff(hw, 'resize');
    const resized = Editor.resizeMap(hw, 4, 3).map;
    hw.subCols = resized.subCols; hw.subRows = resized.subRows; hw.layers = resized.layers;
    wd.seal();
    ok(wd.entry.bytes > 0, '★ 整图级差量记了字节数(字节预算才管得住它)');
    Editor.applyEntry(hw, wd.entry, -1);
    eq(hw.subCols, 8, '★★ 撤销改尺寸:子格数回退');
    eq(hw.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4), '内容也回退');

    // spawn 差量能撤(审计 A9)
    const hsp = Core.createMap('s', 4, 3);
    const sd = Editor.addSpawn(hsp, 'player', 1, 1);
    eq(hsp.players.length, 1, '放了出生点');
    Editor.applyEntry(hsp, sd, -1);
    eq(hsp.players.length, 0, '★★ 撤销:出生点没了(A9 —— 出生点/敌人的增删必须在历史里)');
    Editor.applyEntry(hsp, sd, +1);
    eq(hsp.players.length, 1, '重做:出生点回来了');

    // 差量 → 格坐标列表(交给 renderer.editCells 作废 ③)
    const mdk = Core.createMap('k', 2, 1);          // 8×4 子格:下标 0/5/6 落在 (0,0) 与 (1,0)
    const dk = Editor.paintCells(mdk, Core.LAYER_SCENE, [0, 5, 6], function () { return Core.neutralDesc(2); });
    eq(Editor.diffCells(mdk, dk).length, 2, '★ diffCells:下标 0/5/6 → 2 个不同的格(0,0) 与 (1,0)');
    eq(Editor.diffCells(mdk, dk)[0], { cx: 0, cy: 0 }, 'diffCells 的第一个是 (0,0)');
    eq(Editor.diffCells(mdk, dk)[1], { cx: 1, cy: 0 }, 'diffCells 的第二个是 (1,0)');

    // ==== 剪贴板 ====
    await (async function () {
      const cm = Core.createMap('c', 2, 1);           // 8×4 子格
      cm.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(3);
      cm.layers[Core.LAYER_SCENE].desc[1] = Core.neutralDesc(4);
      const clip = Editor.copyRegion(cm, Core.LAYER_SCENE, { x: 6, y: 0, w: 4, h: 4 });
      eq(clip.w, 4, 'clip 的宽');
      eq(clip.kind, 'tex', '纹理层的剪贴板是描述符');
      // ★ 选区跨接缝:{6,7} + {0,1}:后两列必须是绕回来的那一侧
      eq(clip.desc[2], Core.neutralDesc(3), '★★ 复制跨环面:选区的第 3 列绕回 x=0');
      eq(clip.desc[3], Core.neutralDesc(4), '★★ 第 4 列绕回 x=1');
      eq(clip.desc[0], 0, '第 1 列(x=6)本来就是空的');

      const pm = Core.createMap('p', 3, 1);           // 12×4
      const out = Editor.pasteRegion(pm, Core.LAYER_SCENE, clip, 2, 2);
      ok(out.ok === true, '粘贴到纹理层成功');
      eq(pm.layers[Core.LAYER_SCENE].desc[2 * 12 + 4], Core.neutralDesc(3), '★ 粘贴落在目标位置');
      Editor.applyEntry(pm, out.diff, -1);
      eq(Editor.cellCountOf(pm, Core.LAYER_SCENE), 0, '撤销之后粘贴的内容没了');

      const bad = Editor.pasteRegion(pm, Core.LAYER_BG, clip, 0, 0);
      eq(bad.ok, false, '★★ 纹理层的剪贴板**不能**粘到背景层(决定 ④:两种数据类型不互转)');
      ok(bad.why && bad.why.length > 0, '拒绝时给出原因(给状态栏用,不静默)');

      const bm = Core.createMap('b', 2, 1);
      bm.layers[Core.LAYER_BG].rgba[0] = 0x11223344;
      const bclip = Editor.copyRegion(bm, Core.LAYER_BG, { x: 0, y: 0, w: 2, h: 2 });
      eq(bclip.kind, 'color', '背景层的剪贴板是 RGBA');
      const bout = Editor.pasteRegion(bm, Core.LAYER_BG, bclip, 4, 0);
      eq(bm.layers[Core.LAYER_BG].rgba[0], 0x11223344, '★ 背景层粘回背景层可以');
      ok(bout.diff !== null, '背景粘贴产出差量');
      const texToBg = Editor.pasteRegion(bm, Core.LAYER_BG, clip, 0, 0);
      eq(texToBg.ok, false, '反过来也一样:纹理剪贴板粘不进背景层');
    })();

    // ==== 选区移动(A1 的重写)====
    (function () {
      const mm = Core.createMap('m', 2, 2);            // 8×8 子格
      for (let y = 0; y < 8; y++) for (let x = 0; x < 4; x++) {
        mm.layers[Core.LAYER_SCENE].desc[y * 8 + x] = Core.neutralDesc(6);
      }
      const before = Editor.cellCountOf(mm, Core.LAYER_SCENE);
      eq(before, 32, '前置:左半边 32 个子格被填');
      const sel = { x: 0, y: 0, w: 4, h: 8 };
      const d = Editor.moveRegion(mm, Core.LAYER_SCENE, sel, 2, 0);
      eq(Editor.cellCountOf(mm, Core.LAYER_SCENE), 32,
         '★★ A1:移动之后**一个格子都没丢**(旧实现把被裁掉的列静默删掉)');
      eq(mm.layers[Core.LAYER_SCENE].desc[0], 0, '源区里没被目标覆盖的列被腾空');
      eq(mm.layers[Core.LAYER_SCENE].desc[2], Core.neutralDesc(6), '★ 目标列拿到了源列的内容');
      eq(mm.layers[Core.LAYER_SCENE].desc[5], Core.neutralDesc(6), '★ 目标列的最右一格也在');
      eq(mm.layers[Core.LAYER_SCENE].desc[6], 0, '★ A1 的原始病灶:map 宽 8,目标列到 5 为止,x=6/7 不该被动');

      const mm2 = Core.createMap('m', 2, 2);
      for (let y = 0; y < 8; y++) for (let x = 0; x < 4; x++) {
        mm2.layers[Core.LAYER_SCENE].desc[y * 8 + x] = Core.neutralDesc(6);
      }
      const snap = Array.from(mm2.layers[Core.LAYER_SCENE].desc);
      eq(Editor.moveRegion(mm2, Core.LAYER_SCENE, { x: 0, y: 0, w: 4, h: 8 }, 1000, 0), null,
         '★★ 拖动超出整幅地图:环面折算后是恒等位移 ⇒ 返回 null(旧实现会在这里把内容裁没)');
      eq(Array.from(mm2.layers[Core.LAYER_SCENE].desc).join(','), snap.join(','),
         '★★ 而且地图逐格没变(不是"返回 null 但偷偷改了")');

      // 镜像
      const mi = Core.createMap('i', 2, 2);
      mi.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(3);
      mi.layers[Core.LAYER_SCENE].desc[3] = Core.neutralDesc(4);
      const md = Editor.mirrorRegion(mi, Core.LAYER_SCENE, { x: 0, y: 0, w: 4, h: 4 }, 'h');
      eq(mi.layers[Core.LAYER_SCENE].desc[3], Core.neutralDesc(3), '★ 水平镜像:x=0 的内容到了 x=3');
      eq(mi.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4), '★ 水平镜像:x=3 的内容到了 x=0');
      ok(md !== null, '镜像产出差量');
    })();
  } catch (err) {
    console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
    console.error(err && err.stack ? err.stack : String(err));
    process.exit(1);
  }

  console.log('');
  console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
  if (fail === 0) console.log('EDITOR SMOKE OK');
  process.exit(fail === 0 ? 0 : 1);
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
