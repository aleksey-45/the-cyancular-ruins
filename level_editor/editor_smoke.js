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
    // ★★ 2026-09-22(Task 8)订正:原来是"源码里出现过 PUT 就算过"的存在性断言。Task 8 的
    //    保存流程接进来之后,真正的失败面是**保存流程自己又拼了一份 fetch** —— 那一份多半
    //    漏掉 Content-Type(⇒ 415 ⇒ "点了保存、磁盘上那份没变,只有一行红字"),而存在性
    //    断言**照样是绿的**。故改成**计数**,与同一文件里 `Core.createMap(` 那条同款口径:
    //    写盘出口**只有** `putMapBytes` 一个。
    eq((ui.match(/method:\s*['"`]PUT['"`]/g) || []).length, 1,
       '★★ ui.js 里 PUT **恰好一处**(唯一的写出口 putMapBytes;多一处 = 保存流程自己拼了第二份 fetch)');
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
      // ★★ body 必须是**裸字节**:写端点(editor_server.js)把这个 buffer **原样落盘**,
      //    头里的 application/json 是**跨域闸(CSRF)**、不是编码声明。改成 JSON 编码
      //    (= `JSON.stringify`)会把一份坏文件写进去,而"PUT 只有一处 + 头也对"两条
      //    **都还是绿的** —— 所以这条得单独钉。
      const putBlob14 = sent[0].init.body;
      // ★ 先判类型再取内容:body 不是 Blob 时 `.arrayBuffer` 直接不存在 ⇒ 抛出去会**中断整个
      //   冒烟**(后面的断言一行都不跑,看着像"探针挂了")。判据要的是**失败**,不是抛出。
      const putBody14 = (putBlob14 && typeof putBlob14.arrayBuffer === 'function')
                        ? Array.from(new Uint8Array(await putBlob14.arrayBuffer())) : null;
      eq(putBody14, [1, 2, 3],
         '★★ body 是**裸字节**(不是 JSON 编码;写端点把 buffer 原样落盘,JSON 化会写出一份坏文件。' +
         '实得 ' + JSON.stringify(putBody14) + ')');
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
    // ★ 钉住字节预算的默认值:它才是**真闸**(步数只是廉价上界),值写错正是它要防的那件事
    // ★ 出处订正:64MB **不在规格里** —— 规格 §4.3 的"闸 1"表只列了「撤销步数 200(差量)」一条,
    //   字节预算是**计划**加的(值本身是对的,原先那句"规格 §4.3"是把计划写成了规格)。
    eq(Editor.MAX_UNDO_BYTES, 64 * 1024 * 1024,
       'MAX_UNDO_BYTES = 64MB(★ 出自**计划**,规格 §4.3 闸 1 只有「撤销步数 200(差量)」,无此项;' +
       '默认预算的行为面见下面"不给 maxBytes"那条)');
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

    // ★★ 默认**步数**(不给 opts.maxSteps)必须真的在生效 —— 上面那条走的是显式传 maxSteps:3
    //    的历史,默认那一支一次都没跑到(它只有被**显式**传值时才被验过)。默认值漏掉那个三元
    //    (写成 `opts.maxSteps`)时 `undos.length > undefined` 恒 false ⇒ **完全没有上限**,
    //    而整个冒烟照样全绿 —— 这条是那个洞的唯一守卫(与上面"默认字节预算"同款的镜像)。
    //    ★ 每条 mkDiff(1) 只 12 + 1*4*3 = 24 字节,201 条共 4824 字节,远在字节预算内,
    //      所以这里红就只能是步数闸的问题。
    const hdefSteps = Editor.createHistory({});
    for (let i = 0; i < 201; i++) hdefSteps.push(mkDiff(1));
    eq(hdefSteps.depth(), 200,
       '★★ 默认步数上限在生效:推 201 条(**不给 maxSteps**)后深度停在 200(实得 ' +
       hdefSteps.depth() + ' 条 / ' + hdefSteps.bytes() + ' 字节)');

    // ★★ 默认预算(不给 opts.maxBytes)必须**真的在生效** —— 上面那条走的是显式传
    //    maxBytes 的历史,碰不到默认那一支;默认值退化成 Infinity / 漏掉那支三元,这里才红。
    //    ★ 用**合成的** whole 条目(bytes 字段直接写字节数)而不是真分配 64MB:
    //      bytesOfEntry(whole) 本来就只读 `e.bytes` —— 这正是变异 M4 要钉的那一行。
    const hdef = Editor.createHistory({});          // 不给 maxBytes ⇒ 应走 MAX_UNDO_BYTES
    // ★ 用**真的**快照(而不是 before/after: null):将来谁把 bytesOfEntry(whole) 改成"从快照
    //   现算字节",null 会在 push 里炸成一次**未捕获异常**(后面的断言一行都跑不到、只留下一行
    //   FAIL: 未捕获异常),而真快照下它会退化成一条**具名 FAIL**(那条 whole 不再超预算 ⇒
    //   深度 3 ≠ 2)。测试要在重构下"红得可读",不是在重构下崩掉。
    const hdry = Core.createMap('hd', 2, 1);
    hdef.push({ kind: 'whole', tag: 'fake', bytes: Editor.MAX_UNDO_BYTES,
                before: Editor.snapshotMap(hdry), after: Editor.snapshotMap(hdry) });
    hdef.push(mkDiff(20));
    hdef.push(mkDiff(20));
    eq(hdef.depth(), 2, '★★ 默认字节预算在生效:超预算的 whole 条目被挤掉,只剩后两条(实得 ' +
       hdef.depth() + ' 条 / ' + hdef.bytes() + ' 字节)');

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

    // ★★ 整图级撤销之后,地图必须与 entry 里的快照**解耦**(旧实现 `desc: lay.desc` 是
    //    alias:撤销后再落一笔就写进了历史条目,下一次撤销恢复的是被污染的 before ——
    //    "撤销没撤干净"且一个字都不报;字节数不变,字节闸也发现不了)。
    const hz = Core.createMap('z', 2, 1);
    hz.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(4);
    const zd = Editor.wholeDiff(hz, 'resize');
    const zsz = Editor.resizeMap(hz, 4, 3).map;
    hz.subCols = zsz.subCols; hz.subRows = zsz.subRows; hz.layers = zsz.layers;
    zd.seal();
    Editor.applyEntry(hz, zd.entry, -1);
    eq(hz.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4), '撤销改尺寸后内容回到 before');
    const zp = Editor.paintCells(hz, Core.LAYER_SCENE, [0], function () { return Core.neutralDesc(9); });
    ok(zp !== null, '撤销之后落笔产出差量(下面两条才有意义)');
    eq(zd.entry.before.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4),
       '★★ 落笔**没写进历史条目的 before 快照**(alias 实现下这里会变成 9)');
    Editor.applyEntry(hz, zd.entry, -1);
    eq(hz.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4),
       '★★ 撤销改尺寸 → 落一笔 → 再撤销:地图回到**原始**状态,不是被污染的 before');

    // ★★ 快照拷贝的**另一半**:`seal()` 定格之后继续在地图上落笔,`entry.after` 快照不得
    //    跟着变。上面那条钉的是 before(撤销之后落笔),**after 那一侧此前一条断言都没有** ——
    //    于是 `snapshotMap` 退回 `desc: lay.desc` 时整个相位 ⑫ 照样全绿(既有的 hz 组在
    //    seal 与 undo 之间夹了一次 resize,活数组当场被换掉,alias 照不出来),同一个退化
    //    可以无声无息地回来。这条是它的守卫。
    //    ★ 这里刻意**不夹 undo**:`applyEntry` 会把 map.layers 换成防御性拷贝,一旦换了,
    //      活数组与快照就脱钩了 —— 必须在"seal 完、还没撤销"这个窗口里落笔才测得准。
    const hq = Core.createMap('q', 2, 1);
    hq.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(4);
    const qd = Editor.wholeDiff(hq, 'resize');
    qd.seal();                                     // 快照在这一刻定格
    const qp = Editor.paintCells(hq, Core.LAYER_SCENE, [0], function () { return Core.neutralDesc(9); });
    ok(qp !== null, '★ seal() 之后仍能在地图上落笔(下面那条才有意义)');
    eq(qd.entry.after.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4),
       '★★ seal() 之后落笔**没写进历史条目的 after 快照**(alias 实现下这里会变成 9 —— ' +
       '重做会拿一份被污染的 after 恢复地图)');

    // ★★ 「字节预算管得住整图级操作」不能只靠"记了个正数"(把 bytesOfEntry 的 whole 分支
    //    退化成 `return 64`,上面那条 `> 0` 照样绿 —— 变异 M4 实测 0 红)。两条:
    //    ① 数值面:一条 whole 条目至少要把 before 那份快照算进总账
    ok(Editor.bytesOfEntry(wd.entry) >= Editor.bytesOfSnapshot(wd.entry.before),
       '★★ bytesOfEntry(whole) ≥ before 快照的字节量(实得 ' + Editor.bytesOfEntry(wd.entry) +
       ' ≥ ' + Editor.bytesOfSnapshot(wd.entry.before) + ')—— 记常数过不了这条');
    //    ② 行为面:预算 1000 装不下这条 whole 条目 —— `wd` 是 **2×1 格建图、改成 4×3 格之后**
    //       才 seal 的,所以两份快照**不一样大**:
    //         before = 2×1 格 = 8×4 子格 ×4 层 ×4 字节 = 512
    //         after  = 4×3 格 = 16×12 子格 ×4 层 ×4 字节 = 3072
    //         bytesOfEntry = 64 + 512 + 3072 = **3648**
    //       ⇒ 字节闸真的在管整图级。
    //       ★ 1088(= 64+512+512)是**下面 wd2**(没改过尺寸的 2×1 图)那条的数字 ——
    //         原先这里错把它写在本条上(断言不受影响:它们打印的是实得值,3648 > 1000
    //         反倒让"至少超预算"这条 guard 更结实;错的只是注释)。
    const hwb = Editor.createHistory({ maxBytes: 1000 });
    hwb.push(wd.entry);
    eq(hwb.depth(), 1, '★ 单条 whole 条目就超预算 ⇒ 只丢到"至少留一条"为止(实得 ' + hwb.depth() + ' 条)');
    ok(hwb.bytes() >= Editor.bytesOfSnapshot(wd.entry.before),
       '★★ 那一条在总账里按快照字节数记着(实得 ' + hwb.bytes() + ' 字节,至少要 ' +
       Editor.bytesOfSnapshot(wd.entry.before) + ')');
    const wd2 = Editor.wholeDiff(Core.createMap('w2', 2, 1), 'resize');
    wd2.seal();
    hwb.push(wd2.entry);
    eq(hwb.depth(), 1, '★★ 再来一条 whole 就把最老的挤掉(whole 的字节数真的参与闸门)');

    // ★★ 错误用法必须**看得见**:`wholeDiff` 没 `seal()` 就把 entry 推进历史时,`after` 快照
    //    不存在 ⇒ 撤销照常(有 before)、**重做一个字都不做**(静默 no-op)。这条走全局报错
    //    通道(node 侧换成自定义 sink 接住,stderr 因此仍保持 0 字节 —— 与相位 ⑪ 同款手法)。
    const hbad = Core.createMap('bad', 2, 1);
    const badwd = Editor.wholeDiff(hbad, 'resize');     // ★ 故意不 seal()
    const wseen = [];
    Editor.setErrorSink(function (text) { wseen.push(String(text)); });
    Editor.applyEntry(hbad, badwd.entry, +1);           // 重做 —— after 快照不存在
    Editor.setErrorSink(null);
    ok(wseen.length === 1 && wseen[0].indexOf('重做无效') >= 0,
       '★★ seal() 之前就进历史的 whole 条目:重做时**上报**而不是静默 no-op(实得 ' +
       JSON.stringify(wseen) + ')');

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
      // ★★ 非法 axis 必须**当场拒绝并给出原因** —— 旧实现里没有任何一支命中 ⇒ `di === si` ⇒
      //    退化成恒等 ⇒ 静默返回 null,与"镜像了一圈、内容恰好没变"**完全同形**(调用方分不出
      //    轴写错和这次镜像没改动任何格)。抛出的是带原因的中文错,而不是哑 null。
      throws(function () {
        Editor.mirrorRegion(mi, Core.LAYER_SCENE, { x: 0, y: 0, w: 4, h: 4 }, 'x');
      }, '★★ 非法镜像轴:当场拒绝并给出原因(旧实现退化成恒等、静默回 null)', '镜像轴非法');
    })();

    // ==== 相位 ⑬ 画布交互接线:真装一遍 installInteraction,按**副作用**判 ====
    // ★ Task 7 的 399 行接线(指针 / 热键 / 选区拖动)此前一条断言都没有。本相位把
    //   `installInteraction()` 真装一遍(它只碰 `app.canvas` 与 `window`,两处都在这里替身掉),
    //   然后**直接调它挂上去的处理器** —— 处理器本体、命令分派、落笔路径全是生产代码,
    //   断言读的是它们真做出来的副作用(工具换了没 / 地图改了没 / 哪条渲染入口被调了)。
    // ★ 三个替身,别的都不碰:window.addEventListener(抓注册的处理器)、document(只
    //   getElementById / querySelectorAll 两个入口,一律回空)、一个**记账**的渲染器(app.r)。
    //   ★ 收尾时把 app 的四样还原 + 断言**一条错误都没进过 sink**(处理器是在 `guard` 里跑的,
    //     替身少了哪个方法都会变成一条被吞掉的异常 —— 那条断言就是防这个的)。
    const savedAdd = globalThis.addEventListener;
    const savedDoc13 = globalThis.document;
    const savedR13 = Editor.app.r, savedMap13 = Editor.app.map, savedCv13 = Editor.app.canvas;
    // ★★ `app.st` 也必须存/还 —— 而且必须是**字段快照**,不是只存引用:
    //    ① `installInteraction()`(紧接着那一步)会把 `app.st` **整个换成**一个新对象
    //       (它就是**生产状态对象**的来源,见 ui.js 的初始化;在那之前 `app.st` 根本不存在
    //       —— `var app = {…}` 里没有 `st` 这个字段);
    //    ② 本相位后续各步又在那**同一个对象**上**原地改字段**(⑬b4/⑬b5 的 `tool='select'`、
    //       `brushSize=1`)。
    //    ⇒ 只还引用 = 那些字段的改动跟着对象一起"还"回去(等于没还):后面追加的相位会**继承
    //      一个别人的画笔**(工具/笔刷大小/颜色全变),而那种漂移不报错、只让它们"按错的初始
    //      条件"跑。故快照取在 `installInteraction()` **之后**(下方),收尾时逐字段还回去。
    let savedSt13 = null, savedStFields13 = null;
    // ★ 命中坐标按需可变(默认恒落格 (1,1)):跨接缝那几条要把指针放到指定的子格上。
    let sub13 = { X: 5, Y: 5 };
    const handlers = {};
    const errs13 = [];
    globalThis.addEventListener = function (type, fn) { handlers[type] = fn; };
    globalThis.document = { getElementById: function () { return null; },
                            querySelectorAll: function () { return []; } };
    Editor.setErrorSink(function (t) { errs13.push(String(t)); });
    const calls13 = [];
    // ★ 渲染侧 `setSelDrag` 的**实参**账(修复轮 3 新增的观测面):原来的记账只记"被调过",
    //   而 Esc 取消拖动那条路的重点恰恰是**传的是 null**(= 要求撤掉偏移 ⇒ 去烤)。
    //   分不出实参就判不了"到底有没有把偏移撤掉"。
    const selDragArgs13 = [];
    let sel13 = null;
    Editor.app.canvas = {
      setPointerCapture: function () {},
      getBoundingClientRect: function () { return { left: 0, top: 0 }; },
      addEventListener: function (type, fn) { this['on' + type] = fn; },
    };
    // ★ 记账型渲染器:只记"哪条路被调了" + 一份可读写的选区(地图仍是**真** core 的地图,
    //   故落笔/搬动是真改数据 —— 断言能落到像素以外的东西上)。
    Editor.app.r = {
      selection: function () { return sel13; },
      setSelection: function (s) {
        calls13.push('setSelection');
        sel13 = s ? { x: s.x, y: s.y, w: s.w, h: s.h } : null;
      },
      setSelDrag: function (s, dx, dy) {
        calls13.push('setSelDrag');
        selDragArgs13.push(s ? { x: s.x, y: s.y, dx: dx, dy: dy } : null);
      },
      setPreview: function () { calls13.push('setPreview'); },
      layer: function () { return Core.LAYER_SCENE; },
      setLayer: function () { calls13.push('setLayer'); },
      screenToSub: function () { return { X: sub13.X, Y: sub13.Y }; },   // 默认恒落格 (1,1)
      editCells: function () { calls13.push('editCells'); },
      render: function () { calls13.push('render'); },
      invalidateAll: function () { calls13.push('invalidateAll'); return Promise.resolve(); },
    };
    try {
      Editor.installInteraction();
      // ★ 生产状态对象的**字段快照**取在这里(见相位头那条注释:installInteraction 之前
      //   `app.st` 是 undefined,取在那里等于没取)。
      savedSt13 = Editor.app.st;
      savedStFields13 = savedSt13 ? Object.assign({}, savedSt13) : null;
      ok(!!savedSt13 && savedSt13.tool === 'brush' && savedSt13.brushSize === 1,
         '⑬ 前提:生产状态对象建出来了且是初始值(tool=brush / brushSize=1)—— ' +
         '收尾那条"逐字段还回去"断言比的正是这两个字段');
      ok(typeof handlers.keydown === 'function' && typeof Editor.app.canvas.onpointerdown === 'function' &&
         typeof Editor.app.canvas.onpointerup === 'function',
         '⑬ 前提:installInteraction 在 window 上挂了 keydown、在画布上挂了 pointerdown/up' +
         '(keydown=' + typeof handlers.keydown + ')');

      // ── ⑬a ★★ 热键不许劫持输入框(评审发现 4)──
      const pressKey = function (k, target) {
        const ev = { key: k, target: target, ctrl: false, meta: false, shift: false, altKey: false };
        ev.defaultPrevented = false;
        ev.preventDefault = function () { ev.defaultPrevented = true; };
        handlers.keydown(ev);
        return ev;
      };
      ok(Editor.isTypingTarget({ tagName: 'INPUT' }) && Editor.isTypingTarget({ tagName: 'TEXTAREA' }) &&
         Editor.isTypingTarget({ tagName: 'SELECT' }) && Editor.isTypingTarget({ isContentEditable: true }) &&
         !Editor.isTypingTarget({ tagName: 'BODY' }) && !Editor.isTypingTarget(null) && !Editor.isTypingTarget({}),
         '★ isTypingTarget:input/textarea/select/contenteditable 四种都算,body/null/空对象都不算');
      Editor.app.st.tool = 'brush';
      const evBody = pressKey('l', { tagName: 'BODY' });
      ok(evBody.defaultPrevented === true && Editor.app.st.tool === 'line',
         '★★ (阳性对照)焦点在页面上时 L 键照旧:拦下浏览器默认行为并切到直线工具' +
         '(实得 preventDefault=' + evBody.defaultPrevented + ' tool=' + Editor.app.st.tool + ')');
      Editor.app.st.tool = 'brush';
      const evIn = pressKey('l', { tagName: 'INPUT' });
      ok(evIn.defaultPrevented === false && Editor.app.st.tool === 'brush',
         '★★★ 焦点在**输入框**里时同一个键一个都不拦:L 键不换工具、也不 preventDefault' +
         '(实得 preventDefault=' + evIn.defaultPrevented + ' tool=' + Editor.app.st.tool + ')');
      Editor.app.st.tool = 'brush';
      const evDigit = pressKey('2', { tagName: 'INPUT' });
      ok(evDigit.defaultPrevented === false && calls13.indexOf('setLayer') < 0,
         '★★ 输入框里按数字键不切图层(用户是在打字:数字键 1-4 是切层的热键)');
      // ★★ 破坏性那条:Backspace 在输入框里必须**既**不 preventDefault(数字删得掉)
      //    **又**不去 erase 掉整个选区。
      const mK = filled(Core.createMap('k', 4, 4), Core.LAYER_SCENE, Core.neutralDesc(3));
      Editor.app.map = mK;
      Editor.app.st.tool = 'brush';
      sel13 = { x: 0, y: 0, w: 8, h: 8 };
      calls13.length = 0;
      const evBs = pressKey('Backspace', { tagName: 'INPUT' });
      ok(evBs.defaultPrevented === false && calls13.indexOf('editCells') < 0 &&
         mK.layers[Core.LAYER_SCENE].desc[0] === Core.neutralDesc(3),
         '★★★ 输入框里按 Backspace:不拦(字符删得掉)、**也不清空选区**(实得 preventDefault=' +
         evBs.defaultPrevented + ' / 落笔 ' + (calls13.indexOf('editCells') >= 0 ? '发生了' : '没发生') + ')');
      calls13.length = 0;
      pressKey('Backspace', { tagName: 'BODY' });
      ok(calls13.indexOf('editCells') >= 0 && mK.layers[Core.LAYER_SCENE].desc[0] === 0,
         '★★ (阳性对照)同一个 Backspace 在页面焦点下**确实**清空选区(上一条不是"这个键根本没接上")');

      // ── ⑬b ★★ 跨接缝拖动之后选区必须存回**折算后**的坐标(评审发现 3)──
      const mB = filled(Core.createMap('b', 6, 3), Core.LAYER_SCENE, Core.neutralDesc(4));   // 24×12 子格
      Editor.app.map = mB;
      Editor.app.st.tool = 'select';
      sel13 = { x: 22, y: 4, w: 4, h: 4 };                     // 选区跨着接缝(子格 22..25)
      Editor.app.st.selDrag = { from: { kind: 'sub', x: 22, y: 4 }, dx: 8, dy: 0 };
      calls13.length = 0;
      Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
      eq(sel13, { x: 6, y: 4, w: 4, h: 4 },
         '★★★ 拖动跨过接缝(22..25 右移 8 ⇒ 落下位置 30)之后,选区存的是**折算后**的 6:' +
         '存 30 会让 regionCells 的 inRect(clip) 一格都筛不进来(实得 ' + JSON.stringify(sel13) + ')');
      // ★ 后果断言 —— "框内落笔有没有目标"才是用户能感觉到的那个面(0 个 = 在框里画、
      //   什么都没发生、**连状态栏都不说**:paintCells 回 null ⇒ pushAndShow 回 false)。
      const inBox = Editor.regionCells(mB, { unit: 'sub', x0: 6, y0: 4, x1: 6, y1: 4 }, sel13);
      eq(inBox.length, 1,
         '★★ 拖动之后"在框内落笔"有目标(实得 ' + inBox.length + ' 个 —— 0 个就是' +
         '"用户在框里画、什么都没发生、状态栏也不说")');
      // ── ⑬b3 ★★★ 接缝的**三个口径**必须合一(Important 2)──
      // ★ 病灶:"选区"在本仓里此前是**三种**判据 ——
      //   ① `regionCells` 的 clip:`inRect(clip, wx, wy)`(**非**折算的线性区间);
      //   ② `pointerdown` 的"按在选区里":同一个非折算 inRect;
      //   ③ `moveRegion` 的 from 集合 / 拖动预览:`Render.inSel`(**环面**折算)。
      //   三者在接缝那一侧给出不同答案 ⇒ 最刺眼的一种是"框里画:一半画得进去、另一半
      //   静默什么都没发生(状态栏也不说)"。
      // ★ 现在三处都转调 `Render.inSel`(ui.js 的 `inRect` 就是它),下面按**行为**逐条钉。
      const mS = filled(Core.createMap('s', 24, 3), Core.LAYER_SCENE, Core.neutralDesc(4));  // 96×12 子格
      Editor.app.map = mS;
      const WRAP_SEL = { x: 93, y: 4, w: 6, h: 4 };          // 盖住子格 93,94,95,**0,1,2**
      const at = function (x, y) {
        return Editor.regionCells(mS, { unit: 'sub', x0: x, y0: y, x1: x, y1: y }, WRAP_SEL).length;
      };
      eq([at(93, 4), at(94, 4), at(95, 4), at(0, 4), at(1, 4), at(2, 4), at(3, 4), at(4, 4)],
         [1, 1, 1, 1, 1, 1, 0, 0],
         '★★★ 一个**自己跨着接缝**的选区({x:93,w:6} 盖住 93..95 与 0..2)在框内落笔时, ' +
         '绕过去的那半截也算数:93/94/95/0/1/2 六个都有目标、3/4 没有。旧实现用**非折算**的 ' +
         'inRect ⇒ 0/1/2 三个**静默拿不到**(用户在框里画,一半画得进去、一半什么都没发生)');
      eq(Editor.regionCells(mS, { unit: 'sub', x0: 0, y0: 4, x1: 0, y1: 4 }, WRAP_SEL).length,
         Render.inSel(WRAP_SEL, 0, 4, mS.subCols, mS.subRows) ? 1 : 0,
         '★★★ 并且它与**落笔那一侧**的判据(`Render.inSel`,即 moveRegion 的 from 集合)' +
         '逐格一致:子格 0 在一侧是 ' + Render.inSel(WRAP_SEL, 0, 4, mS.subCols, mS.subRows) +
         '、在另一侧是 ' + Editor.regionCells(mS, { unit: 'sub', x0: 0, y0: 4, x1: 0, y1: 4 }, WRAP_SEL).length +
         '(两者必须相等 —— 这就是"三个口径合一"的可判形式)');
      eq(Editor.regionCells(mB, { unit: 'sub', x0: 6, y0: 4, x1: 6, y1: 4 }, { x: 30, y: 4, w: 4, h: 4 }).length, 1,
         '★★ 连带:选区落在 [0, subCols) **之外**(24 宽的图上 x=30、宽 4 ⇒ 折算后就是 6..9)' +
         '时不再"一格都筛不进来" —— 环面判据下 30 与 6 是同一个选区(与 idxOf 对每一格的处理同源)。' +
         '★ 旧断言在这里期望 **0**,钉的是"未折算的 clip 静默失效"这条**症状**;本轮修掉之后 ' +
         '那条症状已不可能出现,故改钉"折算后等价"这条更强的(期望 0 现在只可能来自' +
         '"判据又退回非折算"——即回归)');

      // ── ⑬b4 ★★ 跨接缝的**框选**(Reachable A):子格 23 一格 → 拖过右边缘绕回格 0 ──
      // ★ 这条**照实记录当前的语义**,不是"要它变成什么样"。命中坐标在 `hitTest`/`screenToSub`
      //   里就已经折算回 [0, subCols),`subRectOf` 只对两个端点取 min/max ⇒ 绕过去的那一段
      //   被读成"0 到 92 的线性区间",结果是**整整一行**(w = 96 子格 = 24 格)。
      //   用户想要的是**两个格**(格 23 与格 0)= 子格 `{x:92,w:8}`(92..95 折回 0..3)
      //   —— 存值的单位一律是**子格**,与下面断言的期望值同量纲。
      //   ★ 修复轮 3 订正:此处曾写作 `{x:23,w:2}`(格),与断言消息里的子格值**不同量纲**,
      //     两者无法对读;消息里那个 `w:5` 也是错的(8 才对,见 `subRectOf` 的 k=4 那条路)。
      // ★ 详见报告:改成**环面区间**要动的东西不在本轮范围内(命中在 subRectOf 看到之前
      //   就已经折算过 ⇒ 方向信息已丢失),这里先把今天的语义钉住 —— 以免"没修"被读成"没这事"。
      Editor.app.map = mS;
      Editor.app.st.tool = 'select';
      Editor.app.st.brushSize = 1;                     // 整数画笔 ⇒ 命中是**格**号
      Editor.app.st.selStart = null; Editor.app.st.selDrag = null;
      sel13 = null;
      sub13 = { X: 92, Y: 4 };                         // 按下:格 23 的左上子格
      Editor.app.canvas.onpointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
      ok(!!Editor.app.st.selStart, '⑬ 前提:pointerdown 起了框选(选区为空 ⇒ 走的不是"拖选区")');
      sub13 = { X: 0, Y: 4 };                          // 拖过右边缘 ⇒ 折算回子格 0
      Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
      eq(sel13, { x: 0, y: 4, w: 96, h: 4 },
         '★★ 跨接缝框选(格 23 → 绕过右边缘回到格 0)存下来的是**整整一行**(实得 ' +
         JSON.stringify(sel13) + ';用户想要的是子格 {x:92,w:8}(= 格 23 与格 0))—— ' +
         '两个端点在命中那一步就已经' +
         '折算回 [0, subCols),方向信息丢失,subRectOf 只能取 min/max。' +
         '★ 这条钉的是**今天的语义**:它同时是"删除键会抹掉一整行"那条已知缺陷的证据');
      eq(Editor.regionCells(mS, { unit: 'cell', x0: 0, y0: 1, x1: 23, y1: 1 }, sel13).length, 24 * SUB * SUB,
         '★ 连带:那一整行的 24 格(384 个子格)**全在**框内(旧口径与新口径在这里一致 ——' +
         '一行本来就没有"绕过去的那半截"可言)。这条是上一条的**后果**面:用户的删除会命中' +
         '24 格而不是他框的 2 格');

      // ── ⑬b5 ★★★ "按在选区里"必须用**同一个**判据(三个口径里的第 ② 处)──
      sel13 = WRAP_SEL;                                // 盖住 93..95 与 0..2
      Editor.app.st.tool = 'select';
      Editor.app.st.selStart = null; Editor.app.st.selDrag = null;
      // ★ 单位换算:整数画笔(brushSize=1)下 `hitOf` 给的是**格**号,由 `toSub` 折成子格 ——
      //   `X:1` ⇒ 格 0 ⇒ **子格 0**(不是"子格 1";修复轮 3 订正,见 ⑬b5 下面那条同款)。
      sub13 = { X: 1, Y: 4 };                          // 按在**绕过去的那半截**里(格 0 = 子格 0)
      Editor.app.canvas.onpointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
      ok(!!Editor.app.st.selDrag && !Editor.app.st.selStart,
         '★★★ 按在**绕过去的那半截**(格 0 = 子格 0,属于 {x:93,w:6})里 = 拖动它,而不是重新框选' +
         '(实得 selDrag=' + !!Editor.app.st.selDrag + ' / selStart=' + !!Editor.app.st.selStart + ';' +
         '旧实现用非折算的 inRect ⇒ 判成"没按在选区里" ⇒ 一拖就是在重新框选,选区永远拖不动)');
      Editor.app.st.selStart = null; Editor.app.st.selDrag = null;
      // ★ 同上:`X:6` ⇒ 格 1 ⇒ **子格 4**(那条"子格 6"的旧注释把命中单位当成了子格)。
      //   判据不变:格 1(子格 4..7)整格都在 {x:93,w:6} 折算后的区间**之外**。
      sub13 = { X: 6, Y: 4 };                          // 按在选区**之外**(格 1 = 子格 4)
      Editor.app.canvas.onpointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
      ok(!Editor.app.st.selDrag && !!Editor.app.st.selStart,
         '★ (对照)按在选区**之外**(格 1 = 子格 4)仍然起框选 —— 上一条不是"永远走拖动那条路"');
      Editor.app.st.selStart = null; Editor.app.st.selDrag = null;
      sub13 = { X: 5, Y: 5 };                          // 还原恒落格 (1,1)
      ok(calls13.indexOf('editCells') >= 0 && calls13.indexOf('setSelection') >= 0,
         '★ 这一步真的走了"搬动 + 存回选区"两条路(实得 ' + JSON.stringify(calls13) + ')');

      // ── ⑬c ★ 单击(按下与松开之间没有 pointermove)也要落一次笔(评审发现 7)──
      const mC = Core.createMap('c', 4, 4);
      Editor.app.map = mC;
      sel13 = null;
      Editor.app.st = { tool: 'brush', brushSize: 1, desc: Core.neutralDesc(7), rgba: 0xFF00FFFF,
                        rgba2: 0x101820FF, descOnly: false, selStart: null, stroke: null,
                        panning: null, selDrag: null, gradStart: null };
      calls13.length = 0;
      Editor.app.canvas.onpointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
      ok(!!Editor.app.st.stroke && Editor.app.st.stroke.painted === false,
         '⑬ 前提:pointerdown 起了笔画且标记未落笔(实得 ' + JSON.stringify(Editor.app.st.stroke) + ')');
      Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
      eq(countNonZero(mC, Core.LAYER_SCENE), Core.SUB_PER_CELL * Core.SUB_PER_CELL,
         '★★ 单击画笔落了一次笔(格 (1,1) 的 16 个子格都写上了纹理 7):旧实现只在 pointermove 里' +
         '落笔 ⇒ 单击一个字都不改、也不报错(矩形/直线是松手才落笔的,所以只有画笔/橡皮会这样)');

      // ── ⑬b2 ★★ Esc 取消选区、左键还按着时松手(评审发现 6 的**真身**在 ui.js 这一侧)──
      // 拖动分支此前**无条件**读 `cur.x`,而 cancel-selection 把选区置 null ⇒ 在 guard 里抛
      // TypeError(用户看到一条错,而且这次拖动**什么都没做**,连"松开"这个动作都没收尾)。
      // 判据两条:① 没有错误进 sink;② 没有可搬的东西就**不动地图**。
      const mE = filled(Core.createMap('e', 6, 3), Core.LAYER_SCENE, Core.neutralDesc(4));
      Editor.app.map = mE;
      const nE = countNonZero(mE, Core.LAYER_SCENE);
      Editor.app.st.tool = 'select';
      sel13 = null;                                   // ← Esc 已经把选区清掉了
      Editor.app.st.selDrag = { from: { kind: 'sub', x: 22, y: 4 }, dx: 8, dy: 0 };
      calls13.length = 0; errs13.length = 0;
      Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
      ok(errs13.length === 0 && calls13.indexOf('editCells') < 0 &&
         countNonZero(mE, Core.LAYER_SCENE) === nE,
         '★★ 选区已被 Esc 取消之后松手:不抛(没有错误进 sink)、也不改地图(实得 errs=' +
         JSON.stringify(errs13) + ' calls=' + JSON.stringify(calls13) + ')');

      // ── ⑬b2b ★★★ Esc 在**拖动途中**按下去(走**真入口**:keydown → cancel-selection)──
      // ★ ⑬b2 手工摆出"选区已经没了"这个**状态**;这一条走用户真会走的那条路(按 Esc),
      //   把三件事一起钉住 —— 它们缺一不可,少了任何一件都只是"看着像取消":
      //   ① 视觉取消:渲染侧必须被要求**撤掉偏移**(`setSelDrag(null)`;它内部会去烤,
      //      内容当场归位 —— 渲染侧那一半的像素判据在 render_smoke 的 ⑬h③);
      //   ② 松手**不提交**:在飞的拖动记录已被清掉 ⇒ pointerup 的拖动分支根本不进;
      //   ③ 记录不在时 pointerup 也不许去读它的字段(guard 里抛 = 静默一条错)。
      const mE2 = filled(Core.createMap('e2', 6, 3), Core.LAYER_SCENE, Core.neutralDesc(4));
      Editor.app.map = mE2;
      const nE2 = countNonZero(mE2, Core.LAYER_SCENE);
      Editor.app.st.tool = 'select';
      sel13 = { x: 4, y: 4, w: 4, h: 4 };
      Editor.app.st.selDrag = { from: { kind: 'sub', x: 4, y: 4 }, dx: 4, dy: 0 };   // ← 拖动在飞
      calls13.length = 0; selDragArgs13.length = 0; errs13.length = 0;
      pressKey('Escape', { tagName: 'BODY' });
      ok(Editor.app.st.selDrag === null && sel13 === null &&
         selDragArgs13.length === 1 && selDragArgs13[0] === null,
         '★★★ Esc 在**拖动途中**按下:在飞的拖动记录与选区一起清掉,并且**当场**要求渲染侧' +
         '撤掉偏移(setSelDrag 的实参必须是 null;实得实参 ' + JSON.stringify(selDragArgs13) +
         ' / 记录还在=' + !!Editor.app.st.selDrag + ' / 选区=' + JSON.stringify(sel13) + ')。' +
         '★ 少了清记录这一半,"取消"与"别的什么把选区清掉了"就分不开 —— 松手时提交与否' +
         '只剩"选区还在不在"一条判据');
      calls13.length = 0; errs13.length = 0;
      Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
      ok(errs13.length === 0 && calls13.indexOf('editCells') < 0 &&
         countNonZero(mE2, Core.LAYER_SCENE) === nE2,
         '★★★ 取消之后松手:**不抛、一个格都不搬**(实得 errs=' + JSON.stringify(errs13) +
         ' / editCells=' + (calls13.indexOf('editCells') >= 0) + ' / 改动格数=' +
         (countNonZero(mE2, Core.LAYER_SCENE) - nE2) + ')。★ 视觉上已经取消、数据却动了是最坏' +
         '那种不一致,而它只在"Esc 之后松手"这条路上现形');
      // ★ 单独隔离"没有在飞记录"这一支(判据必须先于读 `sd` 的字段):记录不在、**而选区在**
      //   —— 这正是"先读 sd 再看选区"的写法会去读 null 的那一帧(pointerup 里抛 TypeError
      //   = 落笔路径整个断掉,而且只在取消之后松手时现形)。
      sel13 = { x: 4, y: 4, w: 4, h: 4 };
      Editor.app.st.selDrag = null;
      Editor.app.st.selStart = null; Editor.app.st.stroke = null; Editor.app.st.gradStart = null;
      calls13.length = 0; errs13.length = 0;
      Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
      ok(errs13.length === 0 && calls13.indexOf('editCells') < 0 &&
         calls13.indexOf('setSelection') < 0,
         '★★ 没有在飞的拖动记录时(选区还在)pointerup 既不抛也不提交(实得 errs=' +
         JSON.stringify(errs13) + ' calls=' + JSON.stringify(calls13) + ')');

      // ── ⑬d ★★ pushAndShow 的 whole ⇒ invalidateAll 分派(评审发现 5 的 ui 半边)──
      const mW = Core.createMap('w', 2, 1);
      Editor.app.map = mW;
      calls13.length = 0;
      eq(Editor.pushAndShow(Editor.wholeDiff(mW, 'resize').seal()), true, '⑬ 前提:whole 差量被接受');
      ok(calls13.indexOf('invalidateAll') >= 0 && calls13.indexOf('editCells') < 0 &&
         calls13.indexOf('render') < 0,
         '★★ kind=whole 走 **invalidateAll**(diffCells 对它是空数组 ⇒ 只 render() 的话整张图' +
         '停在旧尺寸/旧内容上;实得 ' + JSON.stringify(calls13) + ')');
      calls13.length = 0;
      const mN = Core.createMap('n', 2, 1);
      const nd = Editor.applyTool(stOf(mN, Core.LAYER_SCENE), 'brush',
                                  { kind: 'cell', x: 0, y: 0 }, { kind: 'cell', x: 0, y: 0 });
      Editor.app.map = mN;
      ok(Editor.pushAndShow(nd) === true && calls13.indexOf('editCells') >= 0 &&
         calls13.indexOf('invalidateAll') < 0,
         '★ (对照)普通差量走 editCells(不是"两条路都掉进 invalidateAll"也能过;实得 ' +
         JSON.stringify(calls13) + ')');

      eq(errs13.length, 0,
         '★★ 整个相位里**一条错误都没进过 sink**:处理器全在 guard 里跑,替身少一个方法就会' +
         '变成一条被吞掉的异常(实得 ' + JSON.stringify(errs13) + ')');
    } finally {
      Editor.setErrorSink(null);
      globalThis.addEventListener = savedAdd;
      globalThis.document = savedDoc13;
      Editor.app.r = savedR13; Editor.app.map = savedMap13; Editor.app.canvas = savedCv13;
      // ★ 先把字段**逐个**还回原对象,再把引用还回去 —— 两半缺一不可:只还引用时,
      //   ⑬b4/⑬b5 原地改过的 `tool`(='select')仍在那个对象上(见相位头那条注释)。
      if (savedSt13 && savedStFields13) {
        for (const k13 in savedStFields13) savedSt13[k13] = savedStFields13[k13];
      }
      if (savedSt13) Editor.app.st = savedSt13;
    }

    // ── ⑬ 收尾 ★★ `app.st` 必须**逐字段**还成生产初始状态(相位头那条注释的可判形式)──
    // ★ 判据取**字段值**(tool / brushSize / 无在飞状态)而不是"还是同一个对象":对象身份
    //   两种实现完全一样(都是同一个引用),漂出去的恰恰是**字段**;而 `tool` 的初始值是
    //   'brush'(ui.js 建状态对象那一行),⑬b4/⑬b5 把它原地改成了 'select'。
    // ★ 它同时钉住"还的是**生产**对象"这件事:漏掉整段还原时这里会读到 undefined。
    ok(!!Editor.app.st && Editor.app.st.tool === 'brush' && Editor.app.st.brushSize === 1 &&
       !Editor.app.st.selDrag && !Editor.app.st.selStart && !Editor.app.st.stroke,
       '★★ 相位收尾:app.st 被**逐字段**还成生产初始状态(tool=brush / brushSize=1 / 无在飞状态;' +
       '实得 tool=' + (Editor.app.st && Editor.app.st.tool) + ' brushSize=' +
       (Editor.app.st && Editor.app.st.brushSize) + ' selDrag=' + !!(Editor.app.st && Editor.app.st.selDrag) +
       ')。★ 只还引用的话,⑬b4/⑬b5 **原地**改过的 tool 会以 \'select\' 漂到后面追加的相位里' +
       '(不报错,只让它们按错的初始条件跑)');

    // ==== 相位 ⑭ 保存路径与面板工作流的纯逻辑(Task 8)====
    // ★ 编号:brief 写的是「相位 ⑬」,但 Task 7 已经占用了 ⑬(画布交互接线),故顺延为 ⑭
    //   —— 位置仍在 ⑫ 的镜像段之后(与 brief 的意图一致:接在历史/剪贴板那段后面)。
    eq(Editor.saveTargetName(false), null, 'saveTargetName(false): 未打开任何地图 → null(调用方提示先打开)');
    eq(Editor.needsV3Confirm('v4', false), false, '★★ v4 源:直接保存,不问(v4 → v4 是无损的)');
    eq(Editor.needsV3Confirm('v3', false), true,
       '★★ v3 文本源:首次保存要确认(保存会把它转成 v4 二进制,不可逆 —— 规格 §3.6)');
    eq(Editor.needsV3Confirm('legacy', false), true, '★ 旧字母格式源:同样要确认');
    eq(Editor.needsV3Confirm('v3', true), false, '★ 已经确认过一次的会话不再问第二次');
    eq(Editor.needsV3Confirm(null, false), false, '没打开地图时不问');
    eq(Editor.freshName('my map!'), 'my_map.cyrm', '★ freshName 走 sanitizeName(服务器只收裸文件名)');

    // ★★ 敌人类型来自**页面里的** ENEMY_REGISTRY —— 它只定义在 `editor.html` 里,node 侧
    //    `globalThis.ENEMY_REGISTRY` 是 undefined。故这里把那段**标记块**从 editor.html 里
    //    读出来真跑一遍;**不是**抄一份写死的清单(那正是这个注册表要防的漂移)。
    const html14 = fs.readFileSync(path.join(__dirname, 'editor.html'), 'utf8');
    const regBlock14 = /\/\*__ENEMY_REGISTRY_BEGIN__\*\/([\s\S]*?)\/\*__ENEMY_REGISTRY_END__\*\//
                       .exec(html14);
    ok(!!regBlock14,
       '★ editor.html 里有 ENEMY_REGISTRY 的标记块(自检夹具的唯一来源;找不到 = 后面两条是假绿)');
    // ★ 装夹具**之前**先断言它读不出任何东西:证明 importEnemyTypes 里没有一份写死的清单
    delete globalThis.ENEMY_REGISTRY;
    eq(Editor.importEnemyTypes(), [],
       '★★ 页面注册表缺席时 importEnemyTypes 返回 [](它不是写死的清单 —— 写死的那版这里会非空)');
    if (regBlock14) new Function(regBlock14[1])();   // 块体就是 `window.ENEMY_REGISTRY = [ … ];`
    ok(Editor.importEnemyTypes().length > 0, '★ 敌人类型来自页面里的 ENEMY_REGISTRY(不是写死的清单)');
    ok(Editor.importEnemyTypes().indexOf('fly_bird') >= 0, '注册表里有 fly_bird');

    // ── ⑭a 出生点的**位置**语义(handoff 13:brief 原码把"条数"当成了"下标")──
    // ★★ 游戏侧 `map_format.gd` 按**顺序**读 player / player2 ⇒ "放 P2"必须写第 **1** 条。
    //    brief 原码 `players.length <= playerIndex → push` 在**零出生点**的图上放 P2 会 push
    //    出 index 0 的记录(游戏读成 P1);"放 P1"走 addSpawn 的 push,连点两次会把 P2
    //    **悄悄换成**新的那条。两条都只在数据里现形,状态栏还说着"P2 放到 …"。
    const savedDoc14 = globalThis.document;
    const savedR14 = Editor.app.r, savedMap14 = Editor.app.map;
    const savedCv14 = Editor.app.canvas, savedName14 = Editor.app.name;
    let view14 = { x: 0, y: 0, zoom: 1 };
    let status14 = '';
    // ★★ 修复轮 1:这一版替身"够真"到能装下面三个新子相位 —— ⑭c/⑭d 要**驱动真的
    //    click 处理器**(判据是它的副作用,而不是"没抛"),⑭e 还要真跑一遍 `buildPanels()`
    //    (它摸十几个 id、一次 createElement、两处 querySelectorAll,还要查挂上来的监听器)。
    //    故:按 id 惰性建假元素、记住挂上去的监听器、给一个 `click()` 把处理器真跑一遍。
    //    ★ `createElement` 造出来的元素也进册:真 DOM 里 `getElementById` 找得到的正是它们
    //      (buildPanels 给派生提示行设的 `id='palette-hint'` 就是这么被 syncPanelForLayer
    //      看见的) —— 只按 id 惰性建的话,生产代码设的那个 id 与替身里那个会**是两个对象**。
    const els14 = {};
    const made14 = [];
    function mkRow14() {                                  // 一个"看起来像 .desc-row"的假行
      return { className: 'desc-row', style: {}, parentNode: null, textContent: '',
               classList: { contains: function (c) { return c === 'desc-row'; },
                            add: function () {}, remove: function () {}, toggle: function () {} } };
    }
    const root14 = { parentNode: null, className: '', style: {}, classList: null,
                     insertBefore: function () {}, appendChild: function () {} };
    function mkEl14(id) {
      const el = {
        id: id, textContent: '', value: '', checked: false, hidden: false, className: '',
        style: {}, dataset: {}, children: [], _h: {},
        parentNode: root14, nextSibling: null,
        classList: { add: function () {}, remove: function () {}, toggle: function () {},
                     contains: function () { return false; } },
        addEventListener: function (type, fn) { el._h[type] = fn; },
        appendChild: function (c) { el.children.push(c); return c; },
        insertBefore: function (c) { el.children.push(c); return c; },
        removeChild: function () {}, querySelector: function () { return mkEl14(null); },
        click: function () { if (el._h.click) el._h.click({ stopPropagation: function () {}, target: el }); },
      };
      return el;
    }
    function elOf14(id) {
      if (els14[id]) return els14[id];
      for (let i = 0; i < made14.length; i++) if (made14[i].id === id) return (els14[id] = made14[i]);
      return (els14[id] = mkEl14(id));
    }
    // ★ `#status-msg` 单独一件:**它的文本要能被读**(下面那些 refusal 断言读的就是"理由"
    //   那句话),故不走惰性建那一套,而是绑到 `status14` 这个记账变量上。
    const statusEl14 = { id: 'status-msg', style: {}, dataset: {}, children: [],
                         addEventListener: function () {}, appendChild: function () {},
                         classList: { add: function () {}, remove: function () {}, toggle: function () {},
                                      contains: function () { return false; } } };
    Object.defineProperty(statusEl14, 'textContent',
      { set: function (v) { status14 = String(v); }, get: function () { return status14; } });
    // 图层 4 行 / 工具条 8 个按钮:真给(phase ⑭e 要拿它们证明监听器装上了),渐变按钮单给。
    const layerRows14 = [1, 2, 3, 4].map(function (L) {
      const r = mkEl14(null); r.dataset = { layer: String(L) }; return r;
    });
    const toolBtns14 = Editor.TOOLS.map(function (t) { const b = mkEl14(null); b.dataset = { tool: t }; return b; });
    const gradBtn14 = mkEl14(null);
    const dom14 = {
      getElementById: function (id) { return id === 'status-msg' ? statusEl14 : elOf14(id); },
      querySelectorAll: function (sel) {
        if (sel === '#layers .layer-row') return layerRows14;
        if (sel === '#toolbar .tool') return toolBtns14;
        return [];
      },
      querySelector: function (sel) {
        return String(sel).indexOf('gradient') >= 0 ? gradBtn14 : null;
      },
      createElement: function (tag) {
        if (tag === 'canvas') {                          // loadAtlas 要一块能读像素的画布
          return { width: 0, height: 0, getContext: function () {
            return { drawImage: function () {},
                     getImageData: function (x, y, w, h) { return { data: new Uint8ClampedArray(w * h * 4) }; } };
          } };
        }
        const e = mkEl14(null); made14.push(e); return e;
      },
    };
    const savedImage14 = globalThis.Image, savedLoc14 = globalThis.location,
          savedFetch14 = globalThis.fetch;
    // ★ 图集替身:512×640(16×20 块,与真 structure.png 同形状),onload 立刻回调。
    globalThis.Image = function () {
      const img = this;
      img.width = 512; img.height = 640; img.onload = null; img.onerror = null;
      Object.defineProperty(img, 'src', {
        get: function () { return 'structure.png'; },
        set: function () { if (img.onload) img.onload(); },
      });
    };
    // ★ 记账的 fetch 替身(**只**在内存里演;测试不许往真 maps/ 写):PUT 可切 ok/500,
    //   `GET /api/map?p=` 可切 404,`GET /api/maps` 恒空库。
    const putLog14 = [];
    let putMode14 = 'ok', mapGetMode14 = 'ok';
    const fetch14 = function (url, init) {
      const u = String(url);
      if (init && init.method === 'PUT') {
        putLog14.push({ url: u, init: init });
        if (putMode14 !== 'ok') return Promise.resolve({ ok: false, status: 500 });
        return Promise.resolve({ ok: true, status: 200,
          json: function () { return Promise.resolve({ name: 'dirty_copy.cyrm', size: 42 }); } });
      }
      if (u.indexOf('/api/maps') === 0) {
        return Promise.resolve({ ok: true, status: 200,
          json: function () { return Promise.resolve({ maps: [] }); } });
      }
      if (mapGetMode14 !== 'ok') return Promise.resolve({ ok: false, status: 404 });
      return Promise.resolve({ ok: true, status: 200,
        arrayBuffer: function () { return Promise.resolve(new ArrayBuffer(0)); } });
    };
    try {
      // ★ 状态栏那个替身会**记账**(refusal 的"理由"是它唯一的可见面,不记就没法断言)。
      globalThis.document = dom14;
      globalThis.location = { search: '?p=stale_name.cyrm' };
      globalThis.fetch = fetch14;
      const calls14 = [];
      Editor.app.canvas = { width: 80, height: 80 };
      Editor.app.r = {
        view: function () { return view14; },
        layer: function () { return Core.LAYER_SCENE; },
        selection: function () { return null; },
        setSelection: function () {}, setSelDrag: function () {}, setPreview: function () {},
        editCells: function () { calls14.push('editCells'); },
        render: function () { calls14.push('render'); },
        invalidateAll: function () { calls14.push('invalidateAll'); return Promise.resolve(); },
      };
      Editor.app.map = Editor.createEmptyMap('t', 8, 8);     // 32×32 子格
      Editor.app.name = null;

      // ① 零出生点的图上放 P2:必须**拒绝**,而不是 push 出一条会被读成 P1 的记录
      Editor.spawnAt('player', 1);
      eq(Editor.app.map.players.length, 0,
         '★★ 零出生点的图上「放 P2」**不许**写盘:players 必须仍是 0 条(brief 原码在这里 push 出 ' +
         '1 条 index 0 的记录 = 游戏侧读成 **P1**,而状态栏说着"P2 放到 …";实得 ' +
         Editor.app.map.players.length + ' 条)');
      ok(status14.indexOf('先放 P1') >= 0,
         '★★ 拒绝要**说得出理由**(不许静默无反应;实得状态栏 "' + status14 + '")');

      // ② 放 P1 → 放 P2:P2 落在**第 1 条**(位置语义)
      Editor.spawnAt('player', 0);
      eq(Editor.app.map.players.length, 1, '★ 放 P1(空图)= 第 0 条');
      const p1at14 = { x: Editor.app.map.players[0].x, y: Editor.app.map.players[0].y };
      view14 = { x: 0, y: 4, zoom: 1 };                    // 挪一格 ⇒ P2 与 P1 的坐标可辨
      Editor.spawnAt('player', 1);
      eq(Editor.app.map.players.length, 2, '★ 放 P2 = 写第 **1** 条(不是又多一条)');
      ok(Editor.app.map.players[1].x !== p1at14.x || Editor.app.map.players[1].y !== p1at14.y,
         '★ P2 是**这一次**的坐标(与 P1 不同,故能看出写的是哪一条)');

      // ③ 图上**只有 P1** 时再放一次 P1:必须**原位覆盖**、不许长出第 2 条 ——
      //    多出来的那条位置恰好是 index 1 = **P2**(brief 原码走 addSpawn 的 push 就是这样
      //    把 P2 悄悄换掉的;而且只有 P1 时它不会报越界,纯静默)。
      Editor.app.map.players.length = 1;
      view14 = { x: 8, y: 8, zoom: 1 };                    // 视图中心格 = 12,12 —— **越界**,见下条
      Editor.spawnAt('player', 0);
      eq(Editor.app.map.players.length, 1,
         '★★ 只有 P1 时再放 P1:原位覆盖,**不许**长出第 2 条(= P2 被悄悄换掉;实得 ' +
         Editor.app.map.players.length + ' 条)');
      // ★★ 2026-09-22(修复轮 1)订正期望值 12,12 → 4,4:这张图只有 **8 格宽**,视图中心
      //    算出来的格 12 是**越界**的。修复前那条路把越界值原样写进数据(只有
      //    `Core.validateMap` 看得见),而这条断言当时恰恰把那个**错值**钉成了"正确答案"
      //    (测试与代码同错 ⇒ 全绿)。修复后与 `addSpawn`/`spawnIndexAt` 同量纲:
      //    `wrapIdx(12, 8) = 4`。判据没变(仍是"写的是**这一次**的坐标"),只是这一次的
      //    坐标现在必须是**折算后**的。
      eq([Editor.app.map.players[0].x, Editor.app.map.players[0].y], [4, 4],
         '★ P1 原位覆盖面写的是**这一次**的坐标(**折算回本图范围**之后:8 格宽的图上,视图中心格 12 ⇒ 4)');
      // ★★ 视图拖到图外(`panBy` **不钳**视图,render.js)时,记录的坐标必须仍在 `[0, 格数)`:
      //    这是"panned-off-map 的视图"那条真实路径 —— 修好之前它写进磁盘的就是 −90,−90。
      const w8 = Core.cellsWOf(Editor.app.map), h8 = Core.cellsHOf(Editor.app.map);
      view14 = { x: -400, y: -400, zoom: 1 };
      Editor.spawnAt('player', 0);
      const p14 = Editor.app.map.players[0];
      ok(p14.x >= 0 && p14.x < w8 && p14.y >= 0 && p14.y < h8 && p14.x === Render.wrapIdx(-90, w8) &&
         p14.y === Render.wrapIdx(-90, h8),
         '★★ 视图拖到图外(panBy 不钳视图)时记录的 P1 必须在 [0,' + w8 + ') 内且是**折算后**的值' +
         '(实得 ' + p14.x + ',' + p14.y + ';修复前会原样写下 −90,−90)');

      // ④ P1+P2 都在时再放 P1:仍是原位覆盖,P2 一个字都不许动
      view14 = { x: 0, y: 4, zoom: 1 };
      Editor.spawnAt('player', 1);
      const p2at14 = { x: Editor.app.map.players[1].x, y: Editor.app.map.players[1].y };
      view14 = { x: 8, y: 8, zoom: 1 };
      Editor.spawnAt('player', 0);
      eq(Editor.app.map.players.length, 2,
         '★★ 已有一对出生点时再放 P1 **不许**长出第 3 条(实得 ' + Editor.app.map.players.length + ' 条)');
      ok(Editor.app.map.players[1].x === p2at14.x && Editor.app.map.players[1].y === p2at14.y,
         '★★ P2 原位不动(位置语义的正面判据)');

      // ④ 敌人仍是**追加**(它们没有位置语义,顺序无关)
      Editor.spawnAt('enemy', 0);
      Editor.spawnAt('enemy', 0);
      eq(Editor.app.map.enemies.length, 2, '★ 敌人是追加语义(与出生点刻意不同)');
      // ★ 不写死 'fly_bird':期望值取自**同一个注册表**(写死的话注册表一改顺序这条就红,
      //   而且它是"敌人类型确实来自页面注册表"这条链的末端证据)。
      eq(Editor.app.map.enemies[0].type, Editor.importEnemyTypes()[0],
         '★ 敌人类型取自注册表的第一项(实得 ' + Editor.app.map.enemies[0].type + ')');

      // ── ⑭b 导出校验(规格 §4.7:只报告,不阻止导出)──
      const rep14 = Editor.exportReport();
      eq(rep14.ok, true, '★ 干净的小图:ok = true(errors 为空 ⇒ encodeMap 不会拒绝)');
      ok(rep14.lines.join('\n').indexOf('出生点 2') >= 0 &&
         rep14.lines.join('\n').indexOf('敌人 2') >= 0,
         '★ 报告里有出生点/敌人条数(实得 ' + JSON.stringify(rep14.lines) + ')');
      Editor.app.map.players.push({ x: 1, y: 1 });          // 第 3 个出生点
      // ★ 判**逐字那一行**,不是"文本里含『第 3 个及以后』":`Core.validateMap` 自己那条
      //   警告里也有同样六个字("…(第 3 个及以后在 map_format.gd 里读不到)"),用子串判
      //   的话把 exportReport 那行**删掉**这条照样绿。
      ok(Editor.exportReport().lines.indexOf(
           '⚠ 第 3 个及以后的出生点游戏侧读不到(map_format.gd 只认 player/player2)') >= 0,
         '★★ >2 个出生点要有一行**自己的**明确警告(map_format.gd 只认 player/player2)');
      Editor.app.map = null;
      eq(Editor.exportReport(), { lines: ['还没打开地图'], ok: false },
         '★ 没打开地图时报告说的是人话(不是空面板)');

      // ── ⑭c ★★★ `#st-save` 的三种转变(修复轮 1 / 评审 Important 1)──
      // ★★ 状态栏右侧并排的是**两件事**:`#st-save` 说"磁盘上那份是不是这一份",`#status-msg`
      //    说"刚刚发生了什么"。`#st-save` 原先是**没有任何写入者**的静态文案(editor.html
      //    写死「未保存」)⇒ Ctrl+S 成功那一刻同一条状态栏上会同时出现
      //    「未保存 | 已保存 demo_copy.cyrm(1234 字节)」—— 两个相邻的 span 当场互相打脸。
      // ★★ 三条里最重要的是**第三条**:保存**失败**时它必须仍是「未保存」。把清零链在
      //    `guard(...)` 的决议上(那是这个功能最自然的写法)`guard` 失败时决议的是
      //    `undefined`,于是**失败**会被标成「已保存」,而磁盘上那份一个字都没变。
      Editor.app.map = Editor.createEmptyMap('dirty', 4, 4);
      Editor.app.name = 'before.cyrm';
      Editor.app.sourceFormat = null;                      // 无源格式 ⇒ needsV3Confirm 不问
      Editor.app.raw = null;
      const badge14 = function () { return elOf14('st-save').textContent; };
      view14 = { x: 0, y: 0, zoom: 1 };
      Editor.spawnAt('enemy', 0);                          // ① 落一笔(真差量、进真历史)
      eq(badge14(), '未保存',
         '★★ ①落一笔之后 #st-save 说「未保存」(实得 "' + badge14() + '")');
      putMode14 = 'ok';
      await Editor.saveCurrent(true);                      // ② 保存成功
      eq(badge14(), '已保存',
         '★★ ②保存成功后 #st-save 翻成「已保存」(实得 "' + badge14() + '")');
      ok(status14.indexOf('已保存') >= 0,
         '★ 同一刻 #status-msg 说的也是「已保存 …」(两格说的是同一件事;实得 "' + status14 + '")');
      view14 = { x: 0, y: 0, zoom: 1 };
      Editor.spawnAt('enemy', 0);                          // ③ 先弄脏(否则是上一次的残留)
      eq(badge14(), '未保存', '⑭c 前提:再落一笔之后回到「未保存」');
      putMode14 = 'fail';
      await Editor.saveCurrent(true);                      // ★ 保存**失败**
      ok(status14.indexOf('保存失败') >= 0,
         '★★ 保存失败要**说出来**(#status-msg 里有「保存失败」;实得 "' + status14 + '")');
      eq(badge14(), '未保存',
         '★★★ ③保存**失败**之后 #st-save 仍是「未保存」(磁盘上那份一个字都没变;实得 "' +
         badge14() + '")。★ 把 `dirty = false` / 徽标重画链在 `guard(...)` 的决议上,' +
         '`guard` 失败时决议的 `undefined` 会让这一格翻成「已保存」—— 本条就是那个陷阱的守卫');

      // ── ⑭d ★★ 保存流程真的把字节交给了**写盘出口**,也真的更新了 app.name / sourceFormat
      //    (评审 Important 1 的 bonus:此前一条断言都没有)──
      // ★ 为什么必须另立一条:把 `saveCurrent` 改成一行早退(`return Promise.resolve();`)
      //   时,⑭c 里只有 ② 会红,而 ② 的判据是**徽标文案** —— "只翻徽标、不写盘"的实现
      //   照样能过。这条直接钉住"字节确实从那个唯一的出口出去了"。
      putMode14 = 'ok';
      Editor.app.name = 'before.cyrm';                     // 与保存后的名字**可辨**
      Editor.app.sourceFormat = null;                      // 同上:改了才看得出来
      Editor.app.raw = null;
      putLog14.length = 0;
      await Editor.saveCurrent(true);
      eq(putLog14.length, 1,
         '★★ 一次 saveCurrent = **恰好一次**写盘请求(早退的实现这里是 0;实得 ' + putLog14.length + ' 次)');
      // ★ 后两条**先判有没有那一次**再取字段:空数组上取 `[0].url` 会抛出去**中断整条冒烟**
      //   (后面的断言一行都不跑,看着像"探针挂了"),而这里要的是**失败**。
      const put14 = putLog14.length ? putLog14[0] : null;
      ok(!!put14 && put14.url.indexOf('/api/map?p=dirty_copy.cyrm') >= 0,
         '★ 写的是 saveTargetName 算出来的那个名字(实得 "' + (put14 ? put14.url : '(没有请求)') + '")');
      ok(!!put14 && put14.init && put14.init.method === 'PUT',
         '★ 走的还是那个唯一的 PUT 出口(实得 ' + (put14 && put14.init ? put14.init.method : '(没有请求)') + ')');
      ok(Editor.app.raw && Editor.app.raw.length > 0,
         '★ app.raw 换成了这一份新编码出来的字节(实得 ' +
         (Editor.app.raw ? Editor.app.raw.length + ' 字节' : String(Editor.app.raw)) + ')');
      eq(Editor.app.name, 'dirty_copy.cyrm',
         '★★ app.name 更新成真正落盘的那个名字(实得 ' + Editor.app.name + ')');
      eq(Editor.app.sourceFormat, 'v4',
         '★★ app.sourceFormat 更新成 v4(落盘的就是 v4 二进制;实得 ' + Editor.app.sourceFormat + ')');

      // ── ⑭e ★★★ 启动链路:打开的成败**不决定**面板建不建(评审 Important 2)──
      // ★★ 原先那条链是 `loadAtlas → openFromUrl → buildPanels`,而 `.catch` 只有一个 ⇒
      //    `openFromUrl()` 一旦拒绝(`?p=` 是个陈旧/写错的名字 → `openMap` 抛 HTTP 404;
      //    `.cyrm` 解不开;structure.png 拿不到),整条链**短路到 catch**,`buildPanels()`
      //    一行都没跑:工具条、图层行、调色板、出生点四个按钮**一个监听都没装上**,而且
      //    **没有重建路径** —— 屏幕上只有一行「启动失败:…」。用户会以为编辑器坏了,
      //    而不是"这张图打不开"。★ 计划 Step 3 原写的是"排在 openFromUrl() 之后"。
      // ★ 判据是**真驱动**(点一下按钮看它的副作用),不是"没抛":后者拦不住
      //    "buildPanels 跑了但那只按钮没接上"。
      Editor.app.map = null;                               // 打开失败后就是这状态
      Editor.app.tileDefs = globalThis.TILE_DEFS;
      mapGetMode14 = 'fail';                               // ?p=stale_name.cyrm → HTTP 404
      await Editor.bootLoad();
      ok(status14.indexOf('启动失败') >= 0,
         '⑭e 前提:这次打开**真的**失败了(#status-msg 里有「启动失败」;实得 "' + status14 + '")');
      ok(elOf14('palette').children.length > 0,
         '★★★ 打开失败之后调色板**仍然建出来了**(实得 ' + elOf14('palette').children.length +
         ' 个格子)—— 面板建在打开之后的话这里是 0');
      const toolBefore14 = Editor.app.st.tool;
      toolBtns14.forEach(function (b) { if (b.dataset.tool === 'line') b.click(); });
      eq(Editor.app.st.tool, 'line',
         '★★★ 打开失败之后工具条按钮**仍然接上了**(点「直线」真换工具:' + toolBefore14 +
         ' → ' + Editor.app.st.tool + ')');
      status14 = '';
      elOf14('spawn-clear').click();
      eq(status14, '先打开一张地图',
         '★★ 打开失败之后「清空出生点」说的是三个兄弟按钮那一句人话(不是「页面异常:…」;实得 "' +
         status14 + '")');
      status14 = '';
      elOf14('btn-del').click();
      ok(status14.indexOf('删除地图') >= 0,
         '★ 面板上的其它按钮也接上了(「删除」按钮给出了它的说明;实得 "' + status14 + '")');
      // ★ 背景层:派生提示行与「只改辅码」那一行都要跟着调色板一起藏(修复轮 1 / Minor 3)。
      const rows14 = { 'desc-hue': mkRow14(), 'desc-bri': mkRow14(), 'desc-sat': mkRow14(),
                       'desc-alp': mkRow14(), 'desc-only': mkRow14() };
      Object.keys(rows14).forEach(function (id) { elOf14(id).parentNode = rows14[id]; });
      Editor.app.r.layer = function () { return Core.LAYER_BG; };
      Editor.syncPanelForLayer();
      ok(elOf14('palette-hint').style.display === 'none',
         '★★ 切到背景层时**派生提示行**(「纹理 22 不进调色板…」)跟着 #palette 一起藏' +
         '(它是 palette 的派生行,留着就是浮在空面板底下;实得 "' +
         elOf14('palette-hint').style.display + '")');
      ok(rows14['desc-only'].style.display === 'none',
         '★★ 「只改辅码」那一行也藏了(它管的正是那四个已经藏掉的档位;隐藏要落到**整行**' +
         '上 —— 它的 input 外面还包着一层 label;实得 "' + rows14['desc-only'].style.display + '")');
      ok(rows14['desc-hue'].style.display === 'none',
         '★ (对照)四个档位那一行照旧藏(没有为了修上面两条把它弄丢)');
      eq(elOf14('bg-color-row').style.display, '',
         '★ (对照)背景层自己的两个色槽是**显示**出来的');
      Editor.app.r.layer = function () { return Core.LAYER_SCENE; };
      Editor.syncPanelForLayer();
      eq(elOf14('palette-hint').style.display, '',
         '★ 切回纹理层时派生提示行要**回来**(藏了不还原 = 提示永久消失)');
      eq(rows14['desc-only'].style.display, '',
         '★ 切回纹理层时「只改辅码」那一行也回来');
    } finally {
      globalThis.document = savedDoc14;
      Editor.app.r = savedR14; Editor.app.map = savedMap14;
      Editor.app.canvas = savedCv14; Editor.app.name = savedName14;
      globalThis.Image = savedImage14; globalThis.location = savedLoc14;
      globalThis.fetch = savedFetch14;
      // ★★ 历史与敌人注册表也要还(修复轮 1)。⑭a 的 6 次 `spawnAt` 走的是**真**
      //    `pushAndShow` —— 它们真的进了 ⑬ 装出来的那本**真**历史;`ENEMY_REGISTRY` 是
      //    ⑭ 从 editor.html 的标记块里读出来装上的。只还前面那五样引用的话,后面追加的
      //    相位会**带着别人的 6 条差量**起跑(撤销一次撤掉的是 ⑭ 的出生点,而它以为撤的是
      //    自己那笔),而那种漂移**不报错**、只让它们按错的初始条件跑。
      // ★ 还法就是**再装一遍** `installInteraction()`:它建的正是生产初始状态(历史清空 +
      //    `app.st` 回初值)。它只碰 `app.canvas` 与 `window`,故这两处给空替身。
      const savedAdd14 = globalThis.addEventListener, savedCv14b = Editor.app.canvas;
      globalThis.addEventListener = function () {};
      Editor.app.canvas = { addEventListener: function () {} };
      Editor.installInteraction();
      globalThis.addEventListener = savedAdd14; Editor.app.canvas = savedCv14b;
      delete globalThis.ENEMY_REGISTRY;
    }
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
