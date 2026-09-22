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

    // ==== 相位 ⑬d ★★★ 开机的 UI 小状态:图集**还没装**时读、装上之后再按回界面 ====
    // ★★★ 为什么必须在这里(⑭ 之前):`bootLoad` 的真实顺序是 `readUiState` **在前**、
    //    `loadAtlas()` **在后**(`setAtlas` 之前 `atlasCapacity()` 是 **0**)。而 ⑭ 会把一张
    //    512×640 的图集装进来 ⇒ **⑭ 之后**再测这条就测不到了(那时容量是 320,坏实现也能过)。
    //    故本相位钉在"图集还没装"这一刻,并**明文断言这个前提**(红了就知道是排序漂了)。
    // ★★ 老断言为什么看不见这个 bug:`editor_smoke` 当年**直接注入 `app.uist`**(绕过
    //    `readUiState`)—— 一个**不可能失败**的守卫。本相位走**真序列**:
    //    `readUiState → setAtlas → applyUiState`。
    await (async function () {
      const savedDoc13d = globalThis.document;
      const savedR13d = Editor.app.r, savedMap13d = Editor.app.map;
      const savedUist13d = Editor.app.uist, savedDesc13d = Editor.app.st.desc;
      try {
        // ★ 工具条替身(形状照 editor.html 第 58~66 行:`.tool` + `data-tool`,
        //   高亮是 `classList` 的 `on`)。`selectToolButton()` 就是按这两个字段画的。
        const toolBtns13d = ['brush', 'rect', 'bucket', 'eraser', 'line', 'select',
                             'picker', 'gradient'].map(function (t) {
          const on = { on: t === 'brush' };              // 生产初始态:buildPanels 末尾按 tool=brush 画的
          return { dataset: { tool: t },
                   classList: { toggle: function (c, v) { on[c] = !!v; },
                                contains: function (c) { return !!on[c]; } },
                   _on: on };
        });
        globalThis.document = {
          getElementById: function () { return null; },
          querySelector: function () { return null; },
          querySelectorAll: function (sel) { return sel === '#toolbar .tool' ? toolBtns13d : []; },
        };
        const calls13d = [];
        Editor.app.r = {
          view: function () { return { x: 0, y: 0, zoom: 1 }; },
          layer: function () { return Core.LAYER_SCENE; },
          selection: function () { return null; },       // statusLine 会读它
          setLayer: function (L) { calls13d.push('setLayer:' + L); },
          setGrid: function () {}, setSubGrid: function () {}, setTorus: function () {},
          setDimOthers: function () {}, setZoomAt: function () { return Promise.resolve(); },
        };
        Editor.app.map = Editor.createEmptyMap('uist_probe', 4, 4);

        eq(Render.atlasCapacity(), 0,
           '★★★ 前提:此刻图集**还没装**(容量 0)—— 这正是 `bootLoad` 读 UI 状态那一刻的真实条件' +
           '(实得 ' + Render.atlasCapacity() + ';不为 0 说明本相位的排序漂到 ⑭ 之后了)');
        // ★★ 存进去的是 7,而"图集还没装"时 `clampTexture` 对 cap<1 给的是 **1**
        //    ⇒ 用图集上界钳的实现会把 7 变成 1,并让下一次 `persistUi` 把 1 写回 localStorage。
        const store13d = {};
        store13d[Editor.UI_STATE_KEY] = JSON.stringify({ selectedTexture: 7, tool: 'line' });
        const u13d = Editor.readUiState(store13d);
        eq(u13d.selectedTexture, 7,
           '★★★ `readUiState` **不得**用图集派生的上界钳:图集还没装时存下来的纹理位必须原样留着' +
           '(实得 ' + u13d.selectedTexture + ' —— 为 1 就是"每次开机静默毁掉用户选中的纹理")');
        // ── 开机那条路的后半段:图集装上之后才 applyUiState ──
        Render.setAtlas(new Uint8ClampedArray(512 * 640 * 4), 512, 640);
        ok(Render.atlasCapacity() >= 7, '⑬d 前提:图集装好了(容量 ' + Render.atlasCapacity() + ')');
        Editor.app.uist = u13d;
        Editor.app.st.desc = Core.neutralDesc(1);
        Editor.applyUiState();
        eq(Core.texOf(Editor.app.st.desc), 7,
           '★★★ 存下来的纹理位**活到了界面上**(`applyUiState` 在 `setAtlas` 之后跑,钳制该在那里做;' +
           '实得 ' + Core.texOf(Editor.app.st.desc) + ')。★ 钳制没被删掉,只是挪到了它该在的时机' +
           '(此刻容量是 ' + Render.atlasCapacity() + ')');
        // ── 同一条链的另一半:**工具条高亮**也要跟着状态走(与 `setLayer` 同一个模式)──
        const on13d = function (t) { return toolBtns13d.filter(function (b) { return b.dataset.tool === t; })[0]._on.on; };
        ok(on13d('line') && !on13d('brush'),
           '★★★ `applyUiState` 必须把**工具条高亮**也搬过去:存的是「直线」⇒ 高亮在直线那一颗上、' +
           '画笔那颗要灭(实得 line=' + on13d('line') + ' brush=' + on13d('brush') + ')。' +
           '★ 少了 `selectToolButton()` 就是"高亮钉在 editor.html 写死的画笔上、实际生效的是直线"' +
           ' —— 用户看到的与正在发生的不是一回事,而且一个字都不报');
        eq(Editor.app.st.tool, 'line', '(对照)工具状态本身照旧按回去了');
      } finally {
        globalThis.document = savedDoc13d;
        Editor.app.r = savedR13d; Editor.app.map = savedMap13d;
        Editor.app.uist = savedUist13d;
        if (Editor.app.st) Editor.app.st.desc = savedDesc13d;
      }
    })();

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
    // ── ⑭ ★★ 备份的**逐文件**门(2026-09-22)──
    // ★ 为什么单独立这几条:确认框每会话一次是**故意的**(决定 ⑤),但备份**不能**跟着它
    //   一起变成每会话一次 —— 那样同一会话里第二张 v3 图既不被问、也不被备份,**静默**转成 v4。
    const backed14 = new Set();
    eq(Editor.needsV3Backup('v3', 'a.cyrm', backed14), true,
       '★★ 备份门:本会话还没备份过的 v3 文件 → 要备(哪怕确认框不会再问)');
    backed14.add('a.cyrm');
    eq(Editor.needsV3Backup('v3', 'a.cyrm', backed14), false,
       '★★ 同一个文件已经备份过 → 不再备(重复保存不在 maps/ 里堆副本)');
    eq(Editor.needsV3Backup('v3', 'b.cyrm', backed14), true,
       '★★★ **逐文件**:同一会话里另一个 v3 文件**照样要备**(上一轮两半共用会话级标记 ⇒ 这里会红)');
    eq(Editor.needsV3Backup('legacy', 'c.cyrm', backed14), true, '★ 旧字母格式源同样要备');
    eq(Editor.needsV3Backup('v4', 'd.cyrm', backed14), false, '★ v4 源:没有要转换的原文,不备');
    eq(Editor.needsV3Backup(null, 'e.cyrm', backed14), false, '没打开地图时不备');
    eq(Editor.needsV3Backup('v3', null, backed14), false, '还没有落过盘的新图(没有文件名)不备');
    // ── ⑭ ★★ 备份名 = `<名>.v3.bak`(结尾不是 .cyrm;用户 2026-09-22 裁定的名字)──
    eq(Editor.v3BackupName('demo.cyrm'), 'demo.v3.bak',
       '★★ 备份名 = `<名>.v3.bak`(基名去 `.cyrm` 后再接后缀)');
    eq(Editor.v3BackupName('demo.cyrm').toLowerCase().endsWith('.cyrm'), false,
       '★★★ 备份名**不以 `.cyrm` 结尾** —— 游戏 `_random_cyrm` 的 `.ends_with(".cyrm")` 抽不到它');
    eq(Editor.v3BackupName('图 1.cyrm'), '1.v3.bak',
       '★ 服务器仍只收 `[A-Za-z0-9_-]` 的基名:汉字被收掉(不然备份被 400 拒 ⇒ 保存整个卡死)');
    eq(Editor.v3BackupName('.cyrm'), 'map.v3.bak', '★ 收完一个字符都不剩 → 兜底名 `map`');
    ok(Editor.v3BackupName('x'.repeat(80) + '.cyrm').length <= 64,
       '★ 备份名不超过服务器的 MAX_MAP_NAME_LEN=64(基名截 40 + 后缀)');
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

      // ── ⑭d2 ★★★ v3 源首次保存:**确认框说出决定性事实** + **原文备份先落盘**(用户裁定 2026-09-22)──
      // ★ 为什么必须另立一条:确认框原先只说「不可逆」,而**决定性的事实**是"游戏今天读不了 v4"
      //   (实测 v4 → `map_size (3,0)`、0 行)——用户以为自己只是换了个格式,实际上是**把一张能玩的
      //   图换成游戏打不开的**。备份那一半同理:仓库里两张真图今天都是 v3,而本分支把退休页的
      //   `<a download>` 出口也拆了 ⇒ 一次 Ctrl+S 之后原文**只剩 git 里那份**。
      // ★★ 断言口径:①确认文案里那三件事都在;②备份**真的**从**唯一**那个写盘出口出去了、
      //   字节 == 打开时那份原文(逐字节);③备份**排在真保存之前**(两条 PUT 的先后);
      //   ④第二次保存不再写备份(同一会话只写一次 —— 与确认框同一个一次性条件)。
      await (async function () {
        const savedConfirm14 = globalThis.confirm;
        let asked14 = 0, askText14 = '';
        globalThis.confirm = function (t) { asked14++; askText14 = String(t); return true; };
        try {
          const v3text = '# cyrm-v3\n001f001f\n001f001f\n';
          const orig14 = new TextEncoder().encode(v3text);
          Editor.app.map = Editor.createEmptyMap('demo_v3src', 4, 4);
          Editor.app.name = 'demo_v3src.cyrm';
          Editor.app.sourceFormat = 'v3';              // ← 本次会话**第一次**转换保存
          Editor.app.raw = orig14;                     // 磁盘上那份的原文(openMap 留下的)
          putLog14.length = 0;
          await Editor.saveCurrent(false);
          eq(asked14, 1, '⑭d2 前提:首次转换保存**问了一次**(实得 ' + asked14 + ' 次)');
          // ★ 三件事一件都不能少:转成 v4 二进制 / 不可逆 / **游戏现在读不了 v4**(以及期 E 才迁移)
          ok(askText14.indexOf('v4 二进制') >= 0 && askText14.indexOf('不可逆') >= 0,
             '★★ 确认框说了"保存会把它转成 v4 二进制、不可逆"(实得 ' + JSON.stringify(askText14) + ')');
          ok(askText14.indexOf('读不了') >= 0 && askText14.indexOf('map_format.gd') >= 0,
             '★★★ 确认框说了**决定性的那件事**:游戏现在读不了 v4,要等期 E 迁移 map_format.gd' +
             '(旧文案只说「不可逆」—— 用户不知道自己换来的是一张游戏打不开的图;实得 ' +
             JSON.stringify(askText14) + ')');
          ok(askText14.indexOf('demo_v3src.v3.bak') >= 0,
             '★★ 确认框**点名**了备份文件(用户得知道退路落在哪个名字上;实得 ' +
             JSON.stringify(askText14) + ')');
          // ② 两条 PUT:备份在前、真保存在后,走的是**同一个**出口
          eq(putLog14.length, 2,
             '★★★ 首次转换保存 = **两条** PUT(原文备份 + 真保存;实得 ' + putLog14.length + ' 条)');
          const b14 = putLog14.length === 2 ? putLog14[0] : null;
          const s14 = putLog14.length === 2 ? putLog14[1] : null;
          ok(!!b14 && b14.url.indexOf('/api/map?p=demo_v3src.v3.bak') >= 0,
             '★★★ 第一条 PUT 就是**原文备份**,名字是 `<名>.v3.bak`(2026-09-22 用户裁定的那个名字;' +
             '实得 "' + (b14 ? b14.url : '(没有请求)') + '")');
          ok(!!s14 && s14.url.indexOf('/api/map?p=demo_v3src.cyrm') >= 0,
             '★★★ 第二条 PUT 才是真保存(实得 "' + (s14 ? s14.url : '(没有请求)') + '")');
          ok(!!b14 && !!b14.init && b14.init.method === 'PUT' && !!b14.init.body,
             '★ 备份走的也是那个唯一的 PUT 出口(带上了 body)');
          const bBytes14 = b14 && b14.init && b14.init.body
            ? Array.from(new Uint8Array(await b14.init.body.arrayBuffer())) : null;
          eq(bBytes14, Array.from(orig14),
             '★★★ 备份里是**原文那些字节**(逐字节比;不是编码后的 v4 —— 退路必须是原文)');
          // ③ 第二次保存**同一个文件**:确认框不再问,备份也不再写 —— 但现在的理由是
          //    "**这个文件**本会话已经备份过了"(`v3BackedUp` 是**逐文件**的表),
          //    而不是上一轮那句"会话只备一次"(那正是下面 ⑭d2c 要打掉的缺陷)。
          Editor.app.sourceFormat = 'v3';              // ★ 刻意**退回** v3:证明门是那张表、不是源格式
          putLog14.length = 0;
          await Editor.saveCurrent(false);
          eq(asked14, 1, '★★ 第二次保存不再问(问的次数仍是 ' + asked14 + ')');
          eq(putLog14.length, 1,
             '★★★ 第二次保存**只有一条** PUT —— 备份不重写(否则每存一次都在 maps/ 里多一份;实得 ' +
             putLog14.length + ' 条)');
          ok(putLog14.length === 1 && putLog14[0].url.indexOf('.v3.bak') < 0,
             '★ 那一条是真保存,不是备份(实得 "' +
             (putLog14.length ? putLog14[0].url : '(没有请求)') + '")');

          // ── ⑭d2c ★★★ **逐文件**备份:同一会话里保存**第二张** v3 图,必须有它自己的一份 ──
          // ★ 为什么必须另立一条(2026-09-22):上一轮备份与确认框共用**同一个会话级**标记
          //   (`v3Confirmed`)⇒ 同一会话里保存第二张 v3 图时两半都不发生:既不问、也不备,
          //   那次**单向**转换是**静默**的 —— 用户手里那张能玩的 v3 图被换成一张游戏打不开的
          //   v4,而退路一份都没有。安全网只盖住了会话里第一张图。
          // ★ 这里复现的正是那个场景:`v3Confirmed` 此时已经是 true(上一张已经确认过),
          //   故确认**不该**再问(决定 ⑤ 保持),而备份**必须**照写。
          const v3textC = '# cyrm-v3\n001f001f\n001f001f\n001f001f\n';
          const origC = new TextEncoder().encode(v3textC);
          ok(Array.from(origC).join(',') !== Array.from(orig14).join(','),
             '⑭d2c 前提:第二张图的原文与第一张**不同字节**(否则下面那条逐字节比什么都证明不了)');
          Editor.app.map = Editor.createEmptyMap('demo_v3src2', 4, 4);
          Editor.app.name = 'demo_v3src2.cyrm';
          Editor.app.sourceFormat = 'v3';              // ← 打开**第二张** v3 图之后的状态
          Editor.app.raw = origC;                      // 第二张图在磁盘上的原文
          putLog14.length = 0;
          await Editor.saveCurrent(false);
          eq(asked14, 1, '★★★ 第二张图**不再问**(确认仍是每会话一次;问的次数仍是 ' + asked14 + ')');
          eq(putLog14.length, 2,
             '★★★ 但第二张 v3 图**照样有自己的备份** = 两条 PUT(会话级门的实现在这里只有 1 条;' +
             '实得 ' + putLog14.length + ' 条)');
          const bC = putLog14.length === 2 ? putLog14[0] : null;
          const sC = putLog14.length === 2 ? putLog14[1] : null;
          ok(!!bC && bC.url.indexOf('/api/map?p=demo_v3src2.v3.bak') >= 0,
             '★★★ 第二张图的备份落在**它自己的** `<名>.v3.bak` 上(逐文件,不是共用第一张的名字;实得 "' +
             (bC ? bC.url : '(没有请求)') + '")');
          ok(!!sC && sC.url.indexOf('/api/map?p=demo_v3src2.cyrm') >= 0,
             '★★ 第二条才是第二张图的真保存(实得 "' + (sC ? sC.url : '(没有请求)') + '")');
          const bCBytes = bC && bC.init && bC.init.body
            ? Array.from(new Uint8Array(await bC.init.body.arrayBuffer())) : null;
          eq(bCBytes, Array.from(origC),
             '★★★ 第二张图的备份里是**它自己那份原文**(逐字节比;写成第一张的字节也会红)');
          // ④ 同一张第二图再存一次:仍只有一条 —— 逐文件去重的另一半(别退化成"每次保存都备")
          Editor.app.sourceFormat = 'v3';
          putLog14.length = 0;
          await Editor.saveCurrent(false);
          eq(putLog14.length, 1,
             '★★ 第二张图再存一次也只有**一条** PUT(每个文件只备一次;实得 ' + putLog14.length + ' 条)');
          ok(putLog14.length === 1 && putLog14[0].url.indexOf('.v3.bak') < 0,
             '★ 那一条同样是真保存,不是备份(实得 "' +
             (putLog14.length ? putLog14[0].url : '(没有请求)') + '")');
        } finally {
          globalThis.confirm = savedConfirm14;
        }
      })();

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

  // ==== 相位 ⑮ 持久化的纯逻辑(★ 需要 DOM 的那半边由人眼验收)====
  // ★ 编号:brief 写的是「相位 ⑭」,但 Task 8 已经占用了 ⑭(保存路径与面板工作流)——
  //   同一份文件里两个 ⑭ 会让"第几个相位红了"这件事失去指代,故顺延为 ⑮。
  eq(Editor.draftKey('demo.cyrm'), 'demo', '★ draftKey 由 sanitizeName 派生(不另铸一套 id)');
  eq(Editor.draftKey('my-map.cyrm'), 'my-map', 'draftKey: 连字符保留');
  eq(Editor.draftKey(''), 'structure', 'draftKey: 空名回落(与 Core.sanitizeName 同源)');
  eq(Editor.MAX_LIB, 60, 'MAX_LIB = 60(规格 §4.3 闸 1)');
  ok(Editor.DRAFT_DEBOUNCE_MS >= 500, '草稿落盘有防抖(不是每笔都写盘)');
  eq(Editor.DRAFT_DB, 'cyrm-editor', 'DRAFT_DB 名字固定(换名 = 老草稿全丢)');
  eq(Editor.UI_STATE_KEY, 'cyrm.ui.v1', 'UI_STATE_KEY 带版本号');

  // 崩溃槽位比主槽位新 → 提示恢复
  eq(Editor.crashIsNewer({ savedAt: 200 }, { savedAt: 100 }), true, '★ 崩溃快照比主草稿新 → 提示恢复');
  eq(Editor.crashIsNewer({ savedAt: 100 }, { savedAt: 200 }), false, '主草稿更新 → 不提示');
  eq(Editor.crashIsNewer({ savedAt: 100 }, null), true, '没有主草稿 → 有崩溃快照就提示');
  eq(Editor.crashIsNewer(null, { savedAt: 1 }), false, '没有崩溃快照 → 不提示');
  eq(Editor.crashIsNewer(null, null), false, '两个都没有 → 不提示');
  // ★★ 问过、用户说"不要"的那一条**不再问**(不记的话一次偶发页面异常会把每一次打开都变成
  //    "上次异常退出" —— 那是个永久弹窗,直到用户碰巧 Ctrl+S 把草稿写新)
  eq(Editor.crashIsNewer({ savedAt: 200, declined: true }, { savedAt: 100 }), false,
     '★ 已拒绝过的崩溃快照不再提示(与它比主草稿新不新无关)');
  eq(Editor.crashIsNewer({ savedAt: 200, declined: false }, { savedAt: 100 }), true,
     '★ (对照)`declined:false` 照常提示(挡的是"一刀切成不提示"))');

  // 库条目 60 上限:先丢"已保存且最老"的
  (function () {
    const recs = [];
    for (let i = 0; i < 65; i++) recs.push({ key: 'k' + i, savedAt: 1000 + i, dirty: i % 2 === 0 });
    const plan = Editor.evictPlan(recs, 60);
    eq(plan.keep.length + plan.drop.length, 65, '★ 不丢条目:keep + drop = 全部');
    eq(plan.keep.length, 60, '★ 上限 60:留下 60 条');
    eq(plan.drop.length, 5, '★ 丢 5 条');
    const dropped = recs.filter(function (r) { return plan.drop.indexOf(r.key) >= 0; });
    ok(dropped.every(function (r) { return !r.dirty; }),
       '★★ 先丢**已保存**的(脏的那份是用户还没写盘的劳动,不许丢)');
    // ★★★ 上一版这里写的是 `plan.drop.length === 5` —— 那与上面那条 eq 是同一条断言(数两遍),
    //    **同条件时的取舍(丢哪几条)从没被钉过**(只有"全是脏的"那一支钉了 k0/k1)。这里改成
    //    判**身份**:65 条里脏的是偶数号(savedAt 更大的是后面的),故要丢的正是最老的那 5 条
    //    **干净**记录 k1/k3/k5/k7/k9。★ 条数由身份蕴含,故没有丢掉任何东西。
    eq(plan.drop.slice().sort(), ['k1', 'k3', 'k5', 'k7', 'k9'],
       '★★★ 同条件时丢**最老的那几条干净记录**(不是"丢够 5 条就算";实得 ' + plan.drop.join(',') + ')');
    const allDirty = recs.map(function (r) { return { key: r.key, savedAt: r.savedAt, dirty: true }; });
    const plan2 = Editor.evictPlan(allDirty, 60);
    eq(plan2.drop.length, 5, '全是脏的时也得丢够(否则上限失效)');
    ok(plan2.drop.indexOf('k0') >= 0 && plan2.drop.indexOf('k1') >= 0, '全靠 savedAt 时丢最老的');
    eq(Editor.evictPlan([], 60), { keep: [], drop: [] }, '空库 → 空计划(不抛)');
  })();

  // localStorage 的 UI 小状态:读到损坏值一律回落默认(★ 尤其"玩家参考图按格坐标存")
  (function () {
    const def = Editor.uiStateDefaults();
    ok(def.playerRef && typeof def.playerRef.cx === 'number' && typeof def.playerRef.cy === 'number',
       '★★ 玩家参考图位置按**格坐标**存(cx/cy),不是屏幕像素(A13)');
    ok(def.layer >= 0 && def.layer < 4, '默认图层合法');
    const store = {};
    eq(Editor.readUiState(store), def, '空的 storage → 全集默认值');
    store[Editor.UI_STATE_KEY] = '{ 这不是 JSON';
    eq(Editor.readUiState(store), def, '★ 坏 JSON → 回落默认(不抛,编辑器还能开)');
    store[Editor.UI_STATE_KEY] = JSON.stringify({ layer: 99, zoom: -1, tool: 'nope', brushSize: 1e9 });
    const fixed = Editor.readUiState(store);
    eq(fixed.layer, def.layer, '★ 越界图层 → 回落默认(而不是让渲染器拿到 99)');
    ok(fixed.zoom > 0, '★ 负 zoom → 钳到合法值(clampZoom 不返回 0)');
    ok(Editor.TOOLS.indexOf(fixed.tool) >= 0, '★ 表外的工具名 → 回落默认(否则状态栏显示 undefined)');
    ok(fixed.brushSize <= 15, '★ 天大的画笔 → 钳到 15');
    store[Editor.UI_STATE_KEY] = JSON.stringify({ panelOpen: { lib: false } });
    const keep = Editor.readUiState(store);
    eq(keep.panelOpen.lib, false, '★ 合法字段原样保留(只回落坏字段)');
    eq(keep.playerRef, def.playerRef, '★ 缺的字段补默认(不是整份丢掉)');
  })();

  // ==== 相位 ⑮b ★★★ 接线:**行为**层面(草稿盘真的挂在"落笔"与"启动"两条路上)====
  // ★★ 为什么必须另立一相(handoff 3 / 用户裁定 D2):计划里 `saveDraft` / `loadDraft`
  //    **零调用点** —— 函数写对 + 导出表列上,照样是一个**不存在的草稿盘**:`DRAFT_DEBOUNCE_MS`
  //    是死值,而人眼清单那条「等 2 秒 → F12 → IndexedDB → 应有记录」永远观察不到任何东西。
  //    故这一相不测"函数返回什么"(那是 ⑮ 的事),而是**把生产那两条路真跑一遍**:
  //      ① 落一笔(`spawnAt` → `pushAndShow` → `markDirty`)→ 防抖到点 → 假 IndexedDB 里出现记录;
  //      ② 启动那一侧(`offerDraft` → `loadDraft`)→ 真把草稿那份恢复出来。
  // ★ 替身口径与 ⑬/⑭ 同款,但有两处**必须**这样写:
  //    · 假 IndexedDB 的回调走**真** setTimeout(异步)—— 真 IDB 就是异步的,同步替身会把
  //      "写盘还没落完就去读"这类时序错**抹平**(那正是"先清后灌"那类 bug 的藏身处);
  //    · 给 ui.js 的 `setTimeout` 换成**记账**的假表:能直接看到"防抖排了没有、延时多少、
  //      第二笔有没有重排",而不用真等 1.5 秒(等真实时间会让这条断言变成"看运气")。
  {
    const realSetTimeout15 = globalThis.setTimeout;
    const savedDoc15 = globalThis.document, savedConfirm15 = globalThis.confirm;
    const savedSetTimeout15 = globalThis.setTimeout, savedClearTimeout15 = globalThis.clearTimeout;
    const savedIndexedDb15 = globalThis.indexedDB, savedFetch15 = globalThis.fetch;
    const savedR15 = Editor.app.r, savedMap15 = Editor.app.map, savedName15 = Editor.app.name;
    const savedFmt15 = Editor.app.sourceFormat, savedDb15 = Editor.app.db;
    const savedCv15 = Editor.app.canvas, savedUist15 = Editor.app.uist;
    const savedSt15 = Editor.app.st, savedRaw15 = Editor.app.raw;
    try {
      // ── 假 IndexedDB(两张表:草稿盘、崩溃槽位)──
      const tab15 = { draft: new Map(), crash: new Map() };
      // ★ 两个开关 + 一本读数账,专给相位 ⑫(闸 1 的**代价形状**与两条失败路径):
      //   · `count`     —— 让 `count()` 的请求失败(读不到条数);
      //   · `get`       —— 让**单条读**的请求失败(启动路径上"崩溃槽位读不到"那条失败面,
      //                    真环境里是事务打不开 / 配额被拒);
      //   · `deleteTx`  —— 让**含 delete 的**那个事务失败(真 IDB 出错时事务不提交 ⇒
      //                    一条 `later` 都不跑);只认含 delete 的事务,否则连这次写入
      //                    自己都会失败,那测的就不是"清理失败"了;
      //   · `getAll` / `cursor` / `keys` —— 三种读各记一笔:**整库读**(`getAll`)、
      //                    索引值游标**物化了几条记录本体**(`cursor`)、索引键游标用了几次
      //                    (`keys`,只给一个数、不物化任何记录)。"常态一条都不读 / 到上限
      //                    只读够淘汰那几条"这两条不变量只能靠计数钉住:它们是**代价**不是
      //                    行为,断不了对错。
      const fail15 = { count: false, deleteTx: false, get: false };
      const idbReads15 = { count: 0, getAll: 0, cursor: 0, keys: 0 };
      function fakeDb15() {
        function txOf(store, mode) {
          const tx = { error: null, oncomplete: null, onerror: null, onabort: null };
          const later = [];
          let hasDelete = false;
          tx.objectStore = function () {
            return {
              // ★ 写与删都**在事务提交那一刻**才落到表里(真 IndexedDB 就是这样:
              //   `put()` 只是把操作排进事务)。替身若当场改表,"记录已存在"就不再等价于
              //   "这次落盘走完了" —— 那正是本相位头几版把时序判错的地方。
              put: function (rec) { later.push(function () { tab15[store].set(rec.key, rec); }); },
              delete: function (k) {
                hasDelete = true;
                later.push(function () { tab15[store].delete(k); });
              },
              get: function (k) {
                const rq = { result: null, onsuccess: null, onerror: null };
                later.push(function () {
                  if (fail15.get) { if (rq.onerror) rq.onerror({ target: rq }); return; }
                  rq.result = tab15[store].get(k) || null;
                  if (rq.onsuccess) rq.onsuccess({ target: rq });
                });
                return rq;
              },
              // ★ `count()` 只回一个数:**记录本体一个字节都不反序列化**(上游的"先数后读"
              //   就是靠它把常态路径变成"不物化任何 bytes")。
              count: function () {
                idbReads15.count++;
                const rq = { result: 0, onsuccess: null, onerror: null };
                later.push(function () {
                  if (fail15.count) { if (rq.onerror) rq.onerror({ target: rq }); return; }
                  rq.result = tab15[store].size;
                  if (rq.onsuccess) rq.onsuccess({ target: rq });
                });
                return rq;
              },
              getAll: function () {
                idbReads15.getAll++;
                const rq = { result: [], onsuccess: null, onerror: null };
                later.push(function () {
                  rq.result = Array.from(tab15[store].values());
                  if (rq.onsuccess) rq.onsuccess({ target: rq });
                });
                return rq;
              },
              // ★★ 索引(库版本 2 加的 `savedAt`):生产只用它做两条查询 ——
              //   「最新一条的 savedAt」(键游标,降序)与「按时间升序逐条挑淘汰对象」(值游标)。
              //   ★ 替身按**同一个语义**实现:索引是**稀疏**的(真 IDB 里 savedAt 不是数的记录
              //     根本不进索引),升/降序按 savedAt 排。
              //   ★ 两种游标各记一本账:`values` 数**记录本体被物化了几条**(值游标),
              //     `keys` 数键游标用了几次 —— 生产那两条查询的成本形状全在这两个数上。
              index: function () {
                const recsIn = function (dir) {
                  const list = Array.from(tab15[store].values()).filter(function (r) {
                    return typeof r.savedAt === 'number';
                  });
                  list.sort(function (a, b) {
                    return dir === 'prev' ? b.savedAt - a.savedAt : a.savedAt - b.savedAt;
                  });
                  return list;
                };
                return {
                  openCursor: function (range, dir) {
                    const rq = { result: null, onsuccess: null, onerror: null };
                    later.push(function () {
                      const recs = recsIn(dir);
                      let i = 0;
                      const step = function () {
                        if (i >= recs.length) {
                          rq.result = null;
                          if (rq.onsuccess) rq.onsuccess({ target: rq });   // 真 IDB:走完交回 null
                          return;
                        }
                        const rec = recs[i++];
                        idbReads15.cursor++;              // ★ 物化一条**记录本体**
                        rq.result = { key: rec.savedAt, primaryKey: rec.key, value: rec,
                                      continue: function () { realSetTimeout15(step, 0); } };
                        if (rq.onsuccess) rq.onsuccess({ target: rq });
                      };
                      step();
                    });
                    return rq;
                  },
                  openKeyCursor: function (range, dir) {
                    const rq = { result: null, onsuccess: null, onerror: null };
                    later.push(function () {
                      const recs = recsIn(dir);
                      idbReads15.keys++;
                      // ★ 只给**索引键**(一个数)与主键,**不给记录本体** —— 这正是它便宜的原因
                      rq.result = recs.length ? { key: recs[0].savedAt, primaryKey: recs[0].key } : null;
                      if (rq.onsuccess) rq.onsuccess({ target: rq });
                    });
                    return rq;
                  },
                };
              },
            };
          };
          realSetTimeout15(function () {
            if (fail15.deleteTx && mode === 'readwrite' && hasDelete) {
              if (tx.onerror) tx.onerror({ target: tx });    // ★ 失败的事务不提交
              return;
            }
            later.forEach(function (f) { f(); });
            if (tx.oncomplete) tx.oncomplete({ target: tx });
          }, 0);
          return tx;
        }
        return { objectStoreNames: { contains: function () { return true; } },
                 createObjectStore: function () { return {}; }, transaction: txOf };
      }
      // ★★ 升级请求上的 `transaction`(真 IDB 把它挂在 `req.transaction` 上):生产在
      //    `onupgradeneeded` 里要经它拿到**已经在用的**那个 store 补建 `savedAt` 索引
      //    (版本 1 → 2 升级路径)。不给的话那一步会抛 —— 而抛在 `onupgradeneeded` 里
      //    是**整套草稿盘开不出来**(openDraftStore 走 onerror → null),症状是"草稿盘没了"。
      function upgradeReq15(db) {
        return { result: db, transaction: {
          objectStore: function () {
            return { indexNames: { contains: function () { return false; } },
                     createIndex: function () {} };
          },
        }, onupgradeneeded: null, onsuccess: null, onerror: null };
      }
      // ── 记账的假 setTimeout(只给 ui.js 用;替身自己用 realSetTimeout15)──
      // ★ 三种状态要分清:**待跑**(排上了还没到点)、**被撤**(clearTimeout)、**已跑**
      //   (防抖到点/我手动跑过)。混在一起就会把"上一次已经跑完的那个"也算成在飞 ——
      //   本相位的头两版就是这么红的(测试自己的账目错,不是生产错)。
      const timers15 = [], killed15 = [];
      let timerSeq15 = 0;
      globalThis.setTimeout = function (fn, ms) { timerSeq15++; timers15.push({ id: timerSeq15, fn: fn, ms: ms, ran: false }); return timerSeq15; };
      globalThis.clearTimeout = function (id) { killed15.push(id); };
      const pending15 = function () {
        return timers15.filter(function (t) { return !t.ran && killed15.indexOf(t.id) < 0; });
      };
      const fire15 = function (t) { t.ran = true; return t.fn(); };
      async function tick15() {                      // 走一次**真**的宏任务:把微任务链全放干净
        await new Promise(function (res) { realSetTimeout15(res, 0); });
      }
      // ★ 有界地等一个**异步副作用**落地(上界 200 拍,超了按失败算 —— 不许悄悄放行)。
      //   ★★ 只有一处需要它:`saveCurrent` **刻意不** await 草稿盘那一步(见那里的注释:
      //      真文件那条路不该依赖草稿盘),所以"标干净"是在它交回之后才落地的。
      //      其余几处都直接 await 生产交回的那条链(`fire15` / `flushDraft` / `saveCurrent`)。
      async function until15(cond) {
        for (let i = 0; i < 200; i++) { if (cond()) return true; await tick15(); }
        return false;
      }
      // ── 只认几个 id 的 document + 会记账的 app.r ──
      const calls15 = [];
      const els15 = {};
      function el15(id) {
        if (els15[id]) return els15[id];
        const on = {};
        const el = { id: id, textContent: '', value: '', checked: false, hidden: false,
                     style: {}, dataset: {}, children: [], className: '',
                     // ★ parentNode 也要"够真":`syncPanelForLayer` 会顺着 parentNode 一路往上
                     //   找 `.desc-row`(找不到就停在某个对象上写 `style.display`)—— 给个裸对象
                     //   会在那里抛,而那是**替身**的缺口,不是生产的错。
                     parentNode: { style: {}, insertBefore: function () {}, appendChild: function () {} },
                     nextSibling: null,
                     classList: { toggle: function (c, v) { on[c] = !!v; },
                                  add: function () {}, remove: function () {},
                                  contains: function (c) { return !!on[c]; } },
                     // ★★ 记账(而不是空实现):相位 ⑩b 要驱动**生产真的挂上去**的那个点击
                     //    处理器(`#lib-list` 的委托那一只)—— "直接调 openMap"对"入口把
                     //    promise 丢掉"这个改动完全不敏感,只有真处理器才判得出来。
                     //    一个事件可以挂多个处理器(buildPanels 跑过几次就是几个),故存**数组**。
                     _h: {},
                     addEventListener: function (t, fn) { (el._h[t] = el._h[t] || []).push(fn); },
                     appendChild: function (c) { el.children.push(c); return c; },
                     insertBefore: function (c) { el.children.push(c); return c; },
                     removeChild: function () {}, querySelector: function () { return null; } };
        els15[id] = el;
        return el;
      }
      let made15 = 0;
      // ★★ 四个图层行替身(前景/场景/后景/背景,与 editor.html 的 `.layer-row` 同形):
      //     `setLayer`(ui 那一层)要按 `dataset.layer` 把 `.cur` 挪到对应行上。不给行替身的话
      //     "恢复的是哪一层"只剩 `#palette` 一个证据 —— 而那是**同一件事的另一个证据**,
      //     两个都想要。初始 `.cur` 照 editor.html 写死在「场景」(data-layer=1)上:这样
      //     "只改渲染层"的实现会露馅(渲染层变了、`.cur` 还钉在 1)。
      const rows15 = [Core.LAYER_FRONT, Core.LAYER_SCENE, Core.LAYER_BACK,
                      Core.LAYER_BG].map(function (L) {
        const on = { cur: (L === Core.LAYER_SCENE) };
        const row = el15('layer-row-' + L);
        row.dataset = { layer: String(L) };
        row.classList = { toggle: function (c, v) { on[c] = !!v; },
                          add: function (c) { on[c] = true; }, remove: function (c) { on[c] = false; },
                          contains: function (c) { return !!on[c]; } };
        // buildPanels 会给 .vis / .lock 各挂一个监听 ⇒ 它们也得是能 addEventListener 的对象。
        row.querySelector = function () { return { addEventListener: function () {}, style: {} }; };
        return row;
      });
      const curRow15 = function () {
        let out = -1;
        rows15.forEach(function (r) { if (r.classList.contains('cur')) out = parseInt(r.dataset.layer, 10); });
        return out;
      };
      globalThis.document = {
        // ★ 任何 id 都给一个假元素(不是只给 st-save / status-msg):⑨ 要真跑一遍
        //   `bootLoad` → `buildPanels`(它摸十几个 id、还要 appendChild/insertBefore)。
        getElementById: function (id) { return el15(id); },
        querySelectorAll: function (sel) { return sel === '#layers .layer-row' ? rows15 : []; },
        querySelector: function () { return null; },
        createElement: function (tag) {
          if (tag === 'canvas') {
            return { width: 0, height: 0, getContext: function () {
              return { drawImage: function () {},
                       getImageData: function (x, y, w, h) { return { data: new Uint8ClampedArray(w * h * 4) }; } };
            } };
          }
          made15++;
          return el15('made' + made15);
        },
      };
      Editor.app.canvas = { width: 80, height: 80 };
      // ★ `layer()` / `setLayer()` 这一对要**写成状态**(不是两个常量):`syncPanelForLayer`
      //   的判据就是 `app.r.layer()` —— 两个都返回常量的替身会把"渲染层真的换了吗"这件事
      //   从判据里抹掉(`setLayer` 只是记一笔、`layer()` 永远回 LAYER_SCENE)。
      let renderLayer15 = Core.LAYER_SCENE;
      Editor.app.r = {
        view: function () { return { x: 0, y: 0, zoom: 1 }; },
        layer: function () { return renderLayer15; },
        selection: function () { return null; },
        setMap: function () { calls15.push('setMap'); return Promise.resolve(); },
        setLayer: function (L) { renderLayer15 = L; calls15.push('setLayer:' + L); },
        setGrid: function (b) { calls15.push('setGrid:' + b); },
        setSubGrid: function (b) { calls15.push('setSubGrid:' + b); },
        setTorus: function (b) { calls15.push('setTorus:' + b); },
        setDimOthers: function (b) { calls15.push('setDimOthers:' + b); },
        setZoomAt: function () { calls15.push('setZoomAt'); return Promise.resolve(); },
        editCells: function () { calls15.push('editCells'); },
        render: function () { calls15.push('render'); },
        invalidateAll: function () { calls15.push('invalidateAll'); return Promise.resolve(); },
      };
      Editor.app.map = null; Editor.app.db = null;

      // ── ① 环境里**没有** indexedDB ⇒ 草稿盘是 null(而不是抛)──
      delete globalThis.indexedDB;
      eq((typeof indexedDB === 'undefined'), true, '⑮b 前提:这个进程里本来就没有 indexedDB');
      eq(await Editor.openDraftStore(), null,
         '★★ 没有 indexedDB 时 openDraftStore 交回 null(**不抛**)—— 编辑器少了草稿盘照样要能开');

      // ── ② 装上假 indexedDB:草稿盘能开出来 ──
      // ★ 走的是**真**的升级回调(onupgradeneeded → 生产在那儿建 store 与 `savedAt` 索引):
      //   替身这边要照真 IDB 的形状给 `req.transaction`(生产用它给"已经在用的库"补建索引),
      //   少了它那一步会抛 —— 而抛在升级回调里等于"整套草稿盘开不出来"。
      globalThis.indexedDB = { open: function () {
        const req = upgradeReq15(fakeDb15());
        realSetTimeout15(function () {
          if (req.onupgradeneeded) req.onupgradeneeded({ target: req });
          if (req.onsuccess) req.onsuccess({ target: req });
        }, 0);
        return req;
      } };
      const db15 = await Editor.openDraftStore();
      ok(!!db15, '★ openDraftStore 从真有一张 indexedDB 的环境里开出了库');
      Editor.app.db = db15;

      // ── ③ 接线之一:落一笔 → 防抖 → 草稿盘里出现记录 ──
      const map15 = Editor.createEmptyMap('draft_probe', 4, 4);
      Editor.app.map = map15;
      Editor.app.name = 'draft_probe.cyrm';
      Editor.app.sourceFormat = 'v4';
      Editor.spawnAt('enemy', 0);                     // ← 生产里真实的一笔(与 ⑭c 同一个入口)
      eq(Editor.app.map.enemies.length, 1, '⑮b 前提:那一笔真的落进了地图');
      eq(pending15().length, 1, '★★★ 落一笔就排了一次草稿落盘(实得 ' + pending15().length + ' 次)');
      // ★ 下面几处取字段前**先判有没有那个对象**:这一相是"接线断了"的守卫,而接线断了
      //   时那些对象就是 undefined —— 直接取字段会**抛出去中断整条冒烟**(后面的断言一行
      //   都不跑,看着像"探针挂了"),而这里要的是**一条条红**。
      const t15 = pending15()[0];
      eq(t15 && t15.ms, Editor.DRAFT_DEBOUNCE_MS,
         '★★ 那个定时器的延时**就是** DRAFT_DEBOUNCE_MS(1500)—— 换个数就是另一个防抖口径');
      eq(tab15.draft.size, 0, '★★ 防抖没到点之前**一个字节都没写**(草稿盘不是每笔都写)');
      Editor.spawnAt('enemy', 0);                     // 1.5 秒内的第二笔
      eq(pending15().length, 1, '★★ 第二笔是**重排**(clearTimeout + 再排一次),不是排队');
      eq(killed15.length, 1, '★ 重排真的把上那个定时器清掉了(否则会写两份)');

      // 到点:跑那个定时器(`fire15` 交回的就是生产那条链的 promise ⇒ 直接 await)
      const t15b = pending15()[0];
      ok(!!t15b, '⑮b 前提:到点的那个定时器还排着(没有它就没得跑,下面几条按接线断了算)');
      if (t15b) await fire15(t15b);
      const rec15 = tab15.draft.get('draft_probe');
      ok(!!rec15,
         '★★★ 防抖到点之后草稿盘里**真的**有一条记录(键 = 文件名去后缀)—— ' +
         '"落笔 → 防抖 → 落盘"这条线是活的,而不是两个没人调的纯函数');
      eq(rec15 && rec15.key, 'draft_probe', '★ 键 = sanitizeName(文件名去后缀)');
      eq(rec15 && rec15.name, 'draft_probe.cyrm', '★ 记录里带着真文件名(重建时要用它写回同一张图)');
      ok(!!(rec15 && rec15.bytes && rec15.bytes.length), '★ 存的是**编码后的字节**(不是内存里的对象)');
      eq(rec15 && rec15.dirty, true, '★ 还没写盘 ⇒ dirty(启动时"要不要问"的判据就是它)');
      eq(typeof (rec15 && rec15.savedAt), 'number', '★ 记了 savedAt(崩溃槽位与它比新旧)');
      ok(el15('st-save').textContent.indexOf('已自动保存') === 0,
         '★★ #st-save 由草稿盘接管(handoff 2:不然它与 Task 8 的「未保存/已保存」两个写入者互打;实得 "' +
         el15('st-save').textContent + '")');
      const back15 = rec15 ? await globalThis.Io.decodeMap(rec15.bytes) : null;
      ok(!!back15, '★ 存进去的字节能**解回同一张图**(恢复那条路走的就是它)');
      if (back15) {
        eq(back15.enemies.length, Editor.app.map.enemies.length, '★ 解回来的张数与原图一致');
      }

      // ── ④ 离开页面前那一刀(flushDraft):不等防抖,但只在真脏时补 ──
      const before15 = (tab15.draft.get('draft_probe') || {}).savedAt;
      Editor.markDirty();                             // 又画了一笔 ⇒ 定时器在飞
      eq(pending15().length, 1, '⑮b 前提:又排上一次防抖');
      await Editor.flushDraft();                      // flushDraft 交回落盘那条链的 promise
      const rec15b = tab15.draft.get('draft_probe');
      eq(pending15().length, 0, '★★ flushDraft 把那个还在飞的防抖**撤了**(不留两个写入者)');
      ok(!!rec15b && rec15b.savedAt >= before15, '★★ 离开前那一刀把草稿补到了最新(savedAt 前移)');
      eq(rec15b && rec15b.dirty, true, '★ 补的这一份仍是脏的(屏幕上那份确实还没进真文件)');

      // ── ⑤ Ctrl+S **成功** ⇒ 那条草稿标干净;而"保存前遗留的那个定时器"到点不许把它写脏 ──
      globalThis.fetch = function (url) {
        const u = String(url);
        if (u.indexOf('/api/maps') === 0) {
          return Promise.resolve({ ok: true, status: 200,
                                   json: function () { return Promise.resolve({ maps: [] }); } });
        }
        return Promise.resolve({ ok: true, status: 200,
                                 json: function () { return Promise.resolve({ name: 'draft_probe.cyrm', size: 12 }); } });
      };
      Editor.markDirty();                             // ← 这一笔的防抖定时器**留着不跑**(模拟"保存先到")
      const stale15 = pending15()[0];
      await Editor.saveCurrent(false);                // 真走 saveCurrent(写盘出口 + 标干净)
      const recD15 = function () { return tab15.draft.get('draft_probe') || null; };
      ok(await until15(function () { return !!recD15() && recD15().dirty === false; }),
         '★★ 保存成功后草稿那条**标干净**(下次打开不该再问一次;等不到 = 标干净那条链断了)');
      eq(el15('st-save').textContent, '已保存',
         '★★ (交接点)存盘之后 #st-save 交回 Task 8 那对文案 —— 磁盘上那份就是屏幕上这份了,' +
         '再显示「已自动保存 12:34」是**误导**(实得 "' + el15('st-save').textContent + '")');
      if (stale15) await fire15(stale15);             // 保存**之前**排的那个定时器现在到点
      eq(recD15() && recD15().dirty, false,
         '★★★ 保存前遗留的那个防抖定时器到点后**不会**把干净的草稿重新写脏' +
         '(否则下次打开弹一次**假**的恢复提示 —— 那是这层最容易出的错,而且不报错)');

      // ── ⑤b ★★★ 与"保存"**赛跑**的那次落盘(不是先后,是同时)──
      // ★ 上一条钉的是"保存完了定时器才到点"(顺序)。这一条钉的是**交错**:一次草稿落盘
      //   已经开工(编码在飞),Ctrl+S 的收尾在这中间落地 —— 那次落盘落地时必须**放弃**
      //   (它编码的那一版已经在真文件里了),否则草稿被重新写脏,下次打开弹**假**的恢复提示。
      // ★ 构造法:`saveDraft` 编码期间会 await 一次,而 `markDraftSaved` 把"这一版已进真文件"
      //   这件事**同步**记下(它的首行)—— 于是"保存先落地"这件事可以在同一个 tick 里造出来。
      await Editor.markDraftSaved();                       // 先把草稿标干净(起跑状态)
      await until15(function () { return recD15() && recD15().dirty === false; });
      const racing15 = Editor.saveDraft(true);             // 这次落盘**不等它**(它在飞)
      const savedMark15 = Editor.markDraftSaved();         // 保存的收尾插进来(同步推 rev)
      await racing15;
      await savedMark15;
      eq(recD15() && recD15().dirty, false,
         '★★★ 与"保存"赛跑的那次落盘落地之后,草稿**仍然是干净的**' +
         '(编码完成后再看一眼 rev:这一版已经进真文件了 ⇒ 这次落盘必须放弃)');

      // ── ⑤c ★★★ 与"**换图**/**改名**"赛跑的那次落盘(终审 C1:一次静默的内容掉包)──
      // ★ 症状链(评审发现 Critical 1):编码在飞时用户点了库里的**另一张图** —— `openMap`
      //   把 `app.map`/`app.name` 换成 B,而编码交回的是 **A 的字节**;记录于是写成
      //   `{key:'B', name:'B.cyrm', bytes:<A 的地形>, dirty:true}`。下次打开 B:字节比不过
      //   B 的文件 ⇒ 弹一次恢复 ⇒ 用户按下它 ⇒ 屏幕上是 **A 的地形而文件名写着 B.cyrm**
      //   ⇒ 一次 Ctrl+S 就把 **A 的地形写进 maps/B.cyrm**。字节相等那道闸让这件事**更糟**:
      //   它把"一次假提示"换成了"静默掉包"。
      // ★ 构造法:`Io.encodeMap` 交回的是 worker 的**异步**应答 ⇒ `saveDraft()` 同步跑完
      //   (编码已经在飞)之后、`.then` 落地**之前**,同一 tick 里把 app 的状态换掉 ——
      //   与 ⑤b 用的是**同一个**交错手法(那次换的是 rev,这次换的是图)。
      // ★★ 两个**独立**的一半,缺一不可(下面 A/B 两相各让一半承重):
      //   ① 记录的两半(它**是谁** / 它是**什么内容**)必须在**同一个瞬间**取;
      //   ② 编码期间换过图 ⇒ 这次落盘**整笔放弃**(身份判据 `app.map !== mapAtEntry`)。
      //   A 相(换图)由 ② 承重,而 ① 被 ② 挡住(所以单看 A 相杀不掉"只改一半");B 相(**改名**
      //   —— app.map **对象没换**,只换了名字)判据只看身份 ⇒ 这时 ① 独自承重:记录必须落在
      //   **取字节那一刻**的那张身份上,而不是写盘那一刻的名字。
      const savedMap15c = Editor.app.map, savedName15c = Editor.app.name;
      const savedFmt15c = Editor.app.sourceFormat;
      try {
        // ── A 相:编码期间**换图** ──
        const mapA15 = Editor.createEmptyMap('switch_a', 4, 4);
        Editor.app.map = mapA15; Editor.app.name = 'switch_a.cyrm'; Editor.app.sourceFormat = 'v4';
        Editor.markDirty();
        await Editor.flushDraft();                    // 把 A 那份脏草稿落下来(起跑状态)
        const recA15 = tab15.draft.get('switch_a') || null;
        ok(!!recA15 && recA15.dirty === true, '⑤cA 前提:A 有一份没写盘的草稿');
        Editor.spawnAt('enemy', 0);                   // 又画一笔 ⇒ A 的那份草稿要更新
        const inFlightA15 = Editor.saveDraft(true);   // ← 不等它:编码在飞
        const mapB15 = Editor.createEmptyMap('switch_b', 4, 4);
        Editor.app.map = mapB15; Editor.app.name = 'switch_b.cyrm';   // ← openMap 的收尾就是这个形状
        await inFlightA15;
        eq(tab15.draft.has('switch_b'), false,
           '★★★ 编码期间换了图 ⇒ 这次落盘**整笔放弃**(草稿盘里不许出现 switch_b 那条记录):' +
           '写下去就是"新 key + 旧字节",下次打开 B 会弹恢复、一按 Ctrl+S 就把 A 的地形写进 B');
        const recA15b = tab15.draft.get('switch_a') || null;
        ok(recA15b === recA15,
           '★★★ 而 A 那条记录**一个字都没被动过**(同一条记录对象、还是脏的;实得 ' +
           JSON.stringify(recA15b && recA15b.key) + ')');

        // ── B 相:编码期间**改名**(app.map 对象没换)──
        const mapR15 = Editor.createEmptyMap('ren_a', 4, 4);
        Editor.app.map = mapR15; Editor.app.name = 'ren_a.cyrm';
        Editor.markDirty();
        await Editor.flushDraft();                    // 起跑:ren_a 有一份脏草稿
        ok(!!tab15.draft.get('ren_a'), '⑤cB 前提:ren_a 有一份草稿');
        Editor.spawnAt('enemy', 0);
        const inFlightR15 = Editor.saveDraft(true);   // ← 编码在飞
        mapR15.name = 'ren_b'; Editor.app.name = 'ren_b.cyrm';        // ← 生产里「改名」按钮的形状
        await inFlightR15;
        eq(tab15.draft.has('ren_b'), false,
           '★★★ 编码期间改名 ⇒ 那条记录**不许**落到新名字下(它带着的是改名**之前**的字节,' +
           '而"下次打开 ren_b"读到的会是一份对不上的草稿)');
        const recR15 = tab15.draft.get('ren_a') || null;
        ok(!!recR15 && recR15.name === 'ren_a.cyrm' && recR15.name2 === 'ren_a',
           '★★★ 记录落在**取字节那一刻**的名字上(key/name/name2 三处都是;实得 ' +
           JSON.stringify([recR15 && recR15.key, recR15 && recR15.name, recR15 && recR15.name2]) + ')');
      } finally {
        // ★ 这一相借用了"当前图"这个全局状态 ⇒ 用完必须还回 ⑥ 需要的那张(它按
        //   "草稿那份现在共 3 个敌人"接着往下跑)。
        Editor.app.map = savedMap15c; Editor.app.name = savedName15c;
        Editor.app.sourceFormat = savedFmt15c;
      }
      await Editor.flushDraft();                      // 把这一相留下的防抖定时器结清(别留给 ⑥)
      tab15.draft.delete('switch_a');
      tab15.draft.delete('ren_a');

      // ── ⑤d ★★★ 打开一张图 ⇒ 那两笔账**一起归位**(终审 Minor 1 + 评审说的"兄弟 bug")──
      // ★ 症状一(Minor 1):`lastAutoSaveAt` 是**上一张图**那一局的时刻,换图之后状态栏那一格
      //   仍写着「已自动保存 12:34」—— 用户读到的是"这张图存过了"(而它这一局一次都没自动存过)。
      // ★ 症状二(同一个函数里的另一半):`openMap` 不推 `draftSavedRev` 的话,**上一张图**留下的
      //   那个还在飞的防抖定时器到点会给这张"刚打开、一笔都没画过"的图写出一条 `dirty:true`
      //   的草稿 ⇒ 下次开机打开它弹一次**假**的恢复提示。
      // ★ 两笔都落在 openMap 的同一个 `.then` 里(与 `dirty = false` 同一处、同一条纪律)。
      Editor.app.map = Editor.createEmptyMap('minor1_a', 4, 4);
      Editor.app.name = 'minor1_a.cyrm'; Editor.app.sourceFormat = 'v4';
      Editor.markDirty();
      await Editor.flushDraft();
      ok(el15('st-save').textContent.indexOf('已自动保存') === 0,
         '⑤d 前提:状态栏那一格此刻是「已自动保存 …」(实得 "' + el15('st-save').textContent + '")');
      Editor.markDirty();                             // ★ 给 minor1_a 排一次防抖,**留着不跑**
      const staleMinor15 = pending15()[0];
      const otherBytes15 = await globalThis.Io.encodeMap(Editor.createEmptyMap('minor1_b', 4, 4),
                                                         { compress: true });
      globalThis.fetch = function (url) {
        const u = String(url);
        if (u.indexOf('/api/maps') === 0) {
          return Promise.resolve({ ok: true, status: 200,
                                   json: function () { return Promise.resolve({ maps: [] }); } });
        }
        return Promise.resolve({ ok: true, status: 200,
                                 arrayBuffer: function () { return Promise.resolve(
                                   otherBytes15.buffer.slice(otherBytes15.byteOffset,
                                                             otherBytes15.byteOffset + otherBytes15.byteLength)); } });
      };
      await Editor.openMap('minor1_b.cyrm');           // ← 生产那条路(真 fetch → 真解码 → 真 setMap)
      eq(Editor.app.name, 'minor1_b.cyrm', '⑤d 前提:真把另一张图打开了');
      eq(el15('st-save').textContent, '已保存',
         '★★★ 换图之后状态栏那一格**归零**:显示的是这张图自己的磁盘状态,而不是**上一张图**的' +
         '自动保存时刻(实得 "' + el15('st-save').textContent + '")');
      if (staleMinor15) await fire15(staleMinor15);     // ← 上一张图那个定时器现在到点
      eq(tab15.draft.has('minor1_b'), false,
         '★★★ 它到点时**不许**给"刚打开、一笔都没画过"的新图写草稿:写下去就是一条 `dirty:true`, ' +
         '下次开机打开这张图会弹一次**假**的恢复提示(实得 ' + tab15.draft.has('minor1_b') + ')');
      tab15.draft.delete('minor1_a');
      // ★ 与 ⑤c 一样:这一相借用了"当前图"这个全局状态 ⇒ 用完还回 ⑥ 需要的那张。
      Editor.app.map = savedMap15c; Editor.app.name = savedName15c;
      Editor.app.sourceFormat = savedFmt15c;

      // ── ⑥ 接线之二:启动时 offerDraft → loadDraft → 恢复(问一次,不静默覆盖)──
      Editor.spawnAt('enemy', 0);                     // 再画一笔(草稿那份现在共 3 个敌人)
      const dirtyMap15 = Editor.app.map;
      eq(dirtyMap15.enemies.length, 3, '⑮b 前提:草稿那份现在是 3 个敌人');
      await Editor.flushDraft();
      eq(recD15() && recD15().dirty, true, '⑮b 前提:又变成"没写盘的活"');

      // 模拟"关掉页面、重新打开这张图":屏幕上先是从**真文件**打开的那份(内容不同)
      let asked15 = 0, answer15 = true;
      globalThis.confirm = function () { asked15++; return answer15; };
      Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);   // 文件里那份:空的
      Editor.app.name = 'draft_probe.cyrm';
      const restored15 = await Editor.offerDraft();
      eq(asked15, 1, '★★ 有一份没写盘的草稿 ⇒ 启动时**问一次**(不静默)');
      eq(restored15, true, '★★★ offerDraft 真的用 loadDraft 读回了草稿并恢复(handoff 3 的接线)');
      eq(Editor.app.map.enemies.length, 3, '★★ 恢复的是**草稿那份**内容(而不是文件里那份空的)');
      ok(calls15.indexOf('setMap') >= 0, '★ 恢复走 app.r.setMap(画面真的换了,不是只改了内存)');
      ok(el15('status-msg').textContent.indexOf('已从草稿恢复') >= 0,
         '★★ 恢复要**说一句**(用户得知道屏幕上是草稿、不是文件;实得 "' +
         el15('status-msg').textContent + '")');

      // 点"取消":屏幕上的图一个字都不动(问过但不覆盖)
      Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);
      answer15 = false;
      eq(await Editor.offerDraft(), false, '★ 用户点取消 ⇒ 不恢复');
      eq(Editor.app.map.enemies.length, 0, '★★ 点取消时**屏幕上那份没被碰过**(不是"恢复了又撤销")');
      eq(asked15, 2, '★ (对照)取消那次也是真问了');

      // 干净的草稿(存过盘):连问都不问
      if (recD15()) recD15().dirty = false;
      Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);
      eq(await Editor.offerDraft(), false, '★ 存过盘的草稿不再问(否则每次都弹一次)');
      eq(asked15, 2, '★★ 那一次**没有**弹确认框(asked 没涨)');

      // 没有地图可打开时:不问、不抛
      Editor.app.map = null;
      globalThis.confirm = function () { asked15++; return true; };
      eq(await Editor.offerDraft(), false, '★ 一张图都没打开时 offerDraft 直接交回 false');

      // ★★ "假提示"那一类:草稿那份与**真文件里**那份逐字节相同 ⇒ 不该问。
      //   现实里的成因是"Ctrl+S 成功、但标干净那一步没落地就刷新了页面"(或走了另存为)——
      //   文件里明明已经是最新的,再弹一次"要不要恢复草稿"是**假**的,而用户按下去会把
      //   同一份图再解一遍(更糟的是它看着像"有东西没保存")。
      Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);
      if (recD15()) recD15().dirty = true;
      Editor.app.raw = recD15() ? recD15().bytes : null;       // 文件里那份 = 草稿那份(逐字节)
      asked15 = 0;
      eq(await Editor.offerDraft(), false, '★★★ 草稿与刚打开的文件**逐字节相同** ⇒ 不恢复');
      eq(asked15, 0, '★★ 那一次连确认框都没弹(假提示那一类的正面守卫)');
      Editor.app.raw = new Uint8Array([1, 2, 3]);              // 文件里那份**不同** ⇒ 照问
      globalThis.confirm = function () { asked15++; return false; };
      eq(await Editor.offerDraft(), false, '★ (对照)字节不同时仍然问(用户这次点了取消)');
      eq(asked15, 1, '★ (对照)这一次真弹了确认框');

      // ── ⑦ 第 3 层:applyUiState 把 UI 小状态真的按回界面(含"缩放只在 setMap 之后")──
      Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);
      calls15.length = 0;
      // ★ 图集此刻的容量:⑭ 的替身(512×640)留下的是 320。**这一条前提不写死** —— 见下面
      //   纹理那条断言的说明。
      const cap15 = Render.atlasCapacity();
      const pre15 = Editor.app.st.desc;            // 恢复**之前**的那份描述符(四个辅码档位)
      Editor.app.uist = { layer: Core.LAYER_BG, zoom: 0, tool: 'line', brushSize: 3,
                          grid: false, subGrid: true, torus: false, dimOthers: false,
                          panelOpen: { lib: true, right: true },
                          playerRef: { cx: 7, cy: 9, visible: true }, selectedTexture: 5 };
      Editor.applyUiState();
      eq(Editor.app.st.tool, 'line', '★★ applyUiState 把图层/工具按回界面(tool=line)');
      eq(Editor.app.st.brushSize, 3, '★ 画笔大小也按回去了');
      ok(calls15.indexOf('setLayer:3') >= 0, '★ setLayer 收到的是存下来的那一层(3=背景)');
      ok(calls15.indexOf('setGrid:false') >= 0 && calls15.indexOf('setTorus:false') >= 0,
         '★ 两个开关也按回去了(setGrid/setTorus 收到 false)');
      eq(el15('tg-grid').classList.contains('on'), false,
         '★★ DOM 与状态**一致**(开关显示关着 —— 否则"页面显示的"与"实际用的"是两回事)');
      // ★★★ 上面那条只证明"渲染层收到了 3"。**面板与图层行是另一回事**(它们由 ui 那一层的
      //     `setLayer` 管):只调 `app.r.setLayer` 的话,屏幕右侧仍摆着纹理调色板、`.cur` 仍钉在
      //    「场景」行上,而刷子已经画到背景层了 —— 用户看到的与正在发生的不是一回事,且不报错。
      //    故这里把**面板**与**行**两个证据都钉住(变异:换回 `app.r.setLayer` ⇒ 这两条红)。
      eq(el15('palette').style.display, 'none',
         '★★★ 存下来的是背景层 ⇒ 纹理调色板必须**藏起来**(背景层用颜色选择器,规格 §4.5);' +
         '实得 ' + JSON.stringify(el15('palette').style.display));
      eq(curRow15(), Core.LAYER_BG,
         '★★★ 图层行的 `.cur` 在**存下来的那一层**上(不是永远钉在 editor.html 写死的「场景」行上);' +
         '实得 ' + curRow15());
      eq(calls15.indexOf('setZoomAt'), -1,
         '★ 存下来的 zoom=0 是"没存过缩放"的哨兵 ⇒ **不碰** setMap 自己 fit 出来的缩放');
      Editor.app.uist.zoom = 2.5;
      calls15.length = 0;
      Editor.applyUiState();
      ok(calls15.indexOf('setZoomAt') >= 0, '★ 真存过缩放时要恢复它(setZoomAt 被调了)');
      // ★★ 纹理那条断言**不能写死 5**:`clampTexture` 对"容量 < 1(没有信息)"给的是 **1**
      //    (不是放宽到描述符位宽那个上界 —— 见 ui.js 里那段说明),而图集状态是**上一个相位
      //    留下的**(⑭ 的 finally 不还原 atlas,它留的是 512×640 ⇒ cap 320)。写死 5 的话,
      //    哪天 ⑭ 改成空图集,这条会**因为环境**而红(而且看不出是环境问题)。故判据取
      //    `clampTexture(5, cap)`(= 生产那条钳制本身)。
      // ★★ 但"与图集无关"的另一面是:容量 < 5 时 5 会被钳成 cap,而 cap 可能**恰好等于**
      //    恢复前那份的纹理位(空图集下两者都是 1)⇒ 那条就**不再证明**"纹理位真的被按回去了",
      //    只剩"不越界"。故把前提**明文断言出来**(红了就知道是环境,而不是功能坏)——
      //    本相位假设 ⑭ 留下的 atlas 还在;要脱离这个前提,本相位得自己 `Render.setAtlas(…)`。
      ok(cap15 >= 5,
         '★★ 前提:图集容量 ≥ 5(实得 ' + cap15 + ')—— 本相位假设 ⑭ 留下的图集还在' +
         '(512×640 ⇒ 320)。★ 容量 < 5 时下面那条只剩"不越界"这一半(5 被钳成 cap,' +
         '而 cap 与恢复前那份的纹理位可能相等),不是功能红');
      eq(Editor.app.st.desc === Core.packDesc(Editor.clampTexture(5, cap15),
                                              Core.hueOf(pre15), Core.brightOf(pre15),
                                              Core.satOf(pre15), Core.alphaOf(pre15)), true,
         '★ 选中的纹理也按回去了(只换纹理位,四个辅码档位**不动** —— 与恢复**之前**那份逐位比;' +
         '纹理位按 clampTexture(5, ' + cap15 + ') 判,故与图集状态无关;' +
         '恢复前那份的纹理位 = ' + Core.texOf(pre15) + ')');

      // ── ⑧ 源码级:那两个函数**确实**被生产代码调用(导出表列着 ≠ 有人调)──
      const uiSrc15 = fs.readFileSync(path.join(__dirname, 'ui.js'), 'utf8');
      ok(/function markDirty[\s\S]{0,200}scheduleDraftSave\(\)/.test(uiSrc15),
         '★★ 生产里的落笔那一处(markDirty)排了草稿落盘');
      ok((uiSrc15.match(/markDirty\(\);/g) || []).length >= 5,
         '★★ 五个改动点(落一笔/撤销重做/新建/复制/改名)全走 markDirty —— 散开写会**静默**丢掉草稿那一半');
      ok(/function pushAndShow[\s\S]{0,400}markDirty\(\)/.test(uiSrc15),
         '★★ "落一笔"那条路(pushAndShow)走的是 markDirty');
      ok(/function offerDraft[\s\S]{0,900}loadDraft\(/.test(uiSrc15),
         '★★ offerDraft 走 loadDraft(不是另写一条读法)');
      ok(/function bootLoad[\s\S]{0,1200}offerDraft\(\)/.test(uiSrc15),
         '★★★ 启动那条链(bootLoad)里**调了** offerDraft —— 这是 D2 那个缺陷的正面守卫');
      ok(/function bootLoad[\s\S]{0,900}checkCrashSlot\(\)/.test(uiSrc15),
         '★★ 闸 4 的检查也在启动链里');
      // ★★ 判据按**事件名**数,不按助手函数的拼法:写成 `onWin('error', …)` 还是
      //    `window.addEventListener('error', …)`,对"同一事件挂了几个写入者"是同一件事。
      //    (前一版数的是 `onWin('error'` —— 于是在别处**原生拼法**再挂一对时它照样全绿,
      //     变异验证当场咬到。)
      eq((uiSrc15.match(/(?:addEventListener|onWin)\(\s*['"](?:error|unhandledrejection)['"]/g) || []).length, 2,
         '★★ ui.js 里"页面异常 / 未处理的拒绝"的监听**一共就两处**(= 闸 4 的那一对):多一处就是' +
         '同一次异常有第二个写入者(状态栏写两遍,而快照只挂在其中一个上)');
      ok(/function installCrashFence[\s\S]{0,900}onWin\('error'/.test(uiSrc15),
         '★ 那一对就在 installCrashFence 里(不是散在别处的第二份实现)');
      // ★★ 顺序本身是契约(计划 Step 3 的那段 boot 链把两个恢复都排在打开**之前**):反了的话
      //    用户点了"确定"、屏幕上却是刚从文件打开的那张 —— 而且**一个字都不报**。
      //    取 bootLoad 的函数体,量三处调用的**先后**(⑨ 从行为上验的是同一条)。
      const bl15 = uiSrc15.slice(uiSrc15.indexOf('function bootLoad()'));
      const blCut15 = bl15.indexOf('\n  function ', 10);
      const blBody15 = blCut15 > 0 ? bl15.slice(0, blCut15) : bl15;
      ok(blBody15.indexOf('openFromUrl()') > 0 &&
         blBody15.indexOf('openFromUrl()') < blBody15.indexOf('checkCrashSlot()') &&
         blBody15.indexOf('openFromUrl()') < blBody15.indexOf('offerDraft()'),
         '★★★ 启动链里两个恢复都排在 openFromUrl() **之后**(反了 = 恢复被文件里那份盖掉,且不报错)');
      ok(blBody15.indexOf('buildPanels()') < blBody15.indexOf('openFromUrl()'),
         '★ 面板仍建在打开**之前**(Task 8 修复轮 1:打开失败也必须有面板)');

      // ── ⑨ ★★★ 真跑一遍 `bootLoad()`:启动那条链**行为上**确实去问了一次草稿 ──
      // ★★ 为什么源码级那条(上面 `bootLoad … offerDraft()`)不够:它只证明"函数名出现在
      //    函数体附近",一个把它删掉、却在紧邻的注释里写回这个名字的实现**照样全绿**
      //    (本相位就是这么被咬过一次的 —— 变异验证时上一版 0 红)。故这一步真的把
      //    `bootLoad()` 跑完:真文件里是**空**的那张图,草稿盘里是**3 个敌人**的那一份,
      //    `confirm` 答"要" —— 跑完之后 `app.map` 必须是**草稿那份**,而且状态栏说了话。
      const savedImage15 = globalThis.Image, savedLoc15 = globalThis.location;
      globalThis.Image = function () {
        const img = this;
        img.width = 512; img.height = 640; img.onload = null; img.onerror = null;
        Object.defineProperty(img, 'src', {
          get: function () { return 'structure.png'; },
          set: function () { if (img.onload) img.onload(); },
        });
      };
      globalThis.location = { search: '?p=boot_probe.cyrm' };

      const draftMap15 = Editor.createEmptyMap('boot_probe', 4, 4);
      draftMap15.enemies.push({ x: 1, y: 1, type: 'fly_bird' },
                              { x: 2, y: 2, type: 'fly_bird' },
                              { x: 3, y: 3, type: 'fly_bird' });
      const fileMap15 = Editor.createEmptyMap('boot_probe', 4, 4);      // 真文件里那份:空的
      tab15.draft.set('boot_probe', {
        key: 'boot_probe', name: 'boot_probe.cyrm', name2: 'boot_probe',
        bytes: await globalThis.Io.encodeMap(draftMap15, { compress: true }),
        sourceFormat: 'v4', savedAt: Date.now(), dirty: true,
      });
      const fileBytes15 = await globalThis.Io.encodeMap(fileMap15, { compress: true });
      globalThis.fetch = function (url) {
        const u = String(url);
        if (u.indexOf('/api/maps') === 0) {
          return Promise.resolve({ ok: true, status: 200,
                                   json: function () { return Promise.resolve({ maps: [] }); } });
        }
        return Promise.resolve({ ok: true, status: 200,
                                 arrayBuffer: function () { return Promise.resolve(
                                   fileBytes15.buffer.slice(fileBytes15.byteOffset,
                                                            fileBytes15.byteOffset + fileBytes15.byteLength)); } });
      };
      asked15 = 0; answer15 = true;
      globalThis.confirm = function () { asked15++; return answer15; };
      Editor.app.tileDefs = globalThis.TILE_DEFS;
      Editor.app.map = null; Editor.app.name = null; Editor.app.raw = null;
      await Editor.bootLoad();
      eq(asked15, 1,
         '★★★ `bootLoad()` 真的问了一次"要不要恢复草稿"(实得问 ' + asked15 + ' 次)—— ' +
         'D2 那个缺陷的**行为**守卫:零调用点的实现这里必然问 0 次');
      ok(el15('status-msg').textContent.indexOf('启动失败') < 0,
         '⑮b 前提:启动链没有半路失败(实得 "' + el15('status-msg').textContent + '")');
      eq(Editor.app.map && Editor.app.map.enemies.length, 3,
         '★★★ 启动完之后画布上是**草稿那份**(3 个敌人),不是真文件里那份(空的)' +
         ' —— 恢复必须排在 openFromUrl() **之后**才压得住');
      ok(el15('status-msg').textContent.indexOf('已从草稿恢复') >= 0,
         '★★ 状态栏说了这件事(实得 "' + el15('status-msg').textContent + '")');
      globalThis.Image = savedImage15; globalThis.location = savedLoc15;

      // ── ⑩ 闸 4 的**写**侧:页面异常 ⇒ 当场把当前图写进崩溃槽位 ──
      // ★ 这条是这一层存在的全部理由("最坏只丢最后一笔"),而它只在**页面真的抛**的时候跑 ——
      //   node 里没有真 window.onerror,所以这里按 ⑬ 的老办法:给 `addEventListener` 一个
      //   记账替身,把生产挂上去的处理函数**拿出来直接调**(而不是"源码里出现过就过")。
      const hooked15 = {};
      const savedAdd15 = globalThis.addEventListener;
      globalThis.addEventListener = function (evt, fn) { hooked15[evt] = fn; };
      try {
        Editor.app.map = Editor.createEmptyMap('crash_probe', 4, 4);
        Editor.app.name = 'crash_probe.cyrm';
        Editor.installCrashFence();
        ok(typeof hooked15.error === 'function' && typeof hooked15.unhandledrejection === 'function',
           '★★ 闸 4 挂了**页面异常**与**未处理的拒绝**两条(两条缺一,那半边就静默没有快照)');
        tab15.crash.clear();
        el15('status-msg').textContent = '';
        hooked15.error({ message: '手工制造一次崩溃' });
        await until15(function () { return tab15.crash.has('crash'); });
        const crash15 = tab15.crash.get('crash');
        ok(!!crash15,
           '★★★ 页面异常当场把**当前这张图**写进了崩溃槽位(键 crash;等不到 = 崩溃围栏是空的)');
        eq(crash15 && crash15.key, 'crash', '★ 崩溃槽位的键固定是 crash');
        eq(crash15 && crash15.name, 'crash_probe.cyrm', '★ 记着真文件名(恢复时要写回同一张图)');
        ok(!!(crash15 && crash15.bytes && crash15.bytes.length), '★ 存的是编码后的字节');
        ok(!!crash15 && String(crash15.why).indexOf('手工制造一次崩溃') >= 0,
           '★ 记下了异常文本(事后能知道崩在哪;实得 ' + JSON.stringify(crash15 && crash15.why) + ')');
        ok(el15('status-msg').textContent.indexOf('页面异常') >= 0,
           '★★ 异常在状态栏**说出来**了(不是静默;实得 "' + el15('status-msg').textContent + '")');
        tab15.crash.clear();
        hooked15.unhandledrejection({ reason: new Error('拒绝也要兜住') });
        await until15(function () { return tab15.crash.has('crash'); });
        eq(tab15.crash.get('crash') && tab15.crash.get('crash').why, 'unhandledrejection',
           '★ 未处理的拒绝同样落一份(两条路都兜)');
      } finally {
        globalThis.addEventListener = savedAdd15;
      }

      // ── ⑩b ★★★ 两处 async 入口必须**收口**:普通的失败不许换来一个**假的**崩溃提示 ──
      // ★ 机制(症状链):入口把 promise **丢掉** ⇒ 拒绝逃到全局围栏 ⇒ **围栏会 `snapshot()`**
      //   ⇒ 一次普通的打开失败(点到一个陈旧/写错的名字 = HTTP 404)会把**当前这张图**
      //   写进崩溃槽位 ⇒ 下次开机弹一个**假的**「上次异常退出,要恢复吗?」。
      //   这正是账本已经打过两次的那类假提示,而它离"用户数据被覆盖"只差一次点击。
      // ★★ node 里 `window` 没有真的 unhandledrejection 事件,故这里架一座**桥**:
      //   `process.on('unhandledRejection')`(node 对"没人接的拒绝"的**真**事件)→ 交给
      //   生产挂上去的那个处理器。★ 桥先被**反证**一次(手工造一个裸拒绝:必须真的逃进来、
      //   真的落一份快照)—— 否则下面"没逃、没快照"两条就是**空转断言**(一个不可能失败的守卫)。
      // ★ 报错通道换成"转发给状态栏"(= 生产无自定义 sink 时 `reportError` 的 `else status(text)`
      //   那一条):既能断言"用户看得见",又不往 stderr 写一个字(默认通道会 `console.error`)。
      {
        const hooked15b = {};
        const savedAdd15b = globalThis.addEventListener;
        const savedSink15b = null;                  // 生产默认通道 = 无自定义 sink
        const escaped15 = [];
        const onUnhandled15 = function (reason) {
          escaped15.push(reason);
          if (typeof hooked15b.unhandledrejection === 'function') {
            hooked15b.unhandledrejection({ reason: reason });
          }
        };
        globalThis.addEventListener = function (evt, fn) { hooked15b[evt] = fn; };
        process.on('unhandledRejection', onUnhandled15);
        try {
          Editor.setErrorSink(function (t) { Editor.status(String(t)); });
          Editor.installCrashFence();
          Editor.app.map = Editor.createEmptyMap('open_fail_probe', 4, 4);
          Editor.app.name = 'open_fail_probe.cyrm';
          Editor.app.sourceFormat = 'v4';

          // ── 反证:桥真的通(裸拒绝会逃进来 + 真的落到崩溃槽位)──
          tab15.crash.clear();
          escaped15.length = 0;
          Promise.reject(new Error('裸拒绝(证明这座桥真的通)'));
          ok(await until15(function () { return escaped15.length > 0; }),
             '★★ ⑩b 前提(反证):一个**裸拒绝**真的会逃到全局围栏(等不到 ⇒ 下面两条"没逃"是空转)');
          ok(await until15(function () { return tab15.crash.has('crash'); }),
             '★★ ⑩b 前提(反证):而围栏**真的**会把当前这张图写进崩溃槽位 —— 这就是"假提示"的来路');

          // ── ① 库列表点击 → 打开地图(HTTP 404)──
          // ★★ 驱动的是**真的那个点击处理器**(buildPanels 挂在 `#lib-list` 上的委托那一只),
          //    不是"直接调 openMap" —— 后者对"入口把 promise 丢掉"这个改动**完全不敏感**。
          globalThis.fetch = function (url) {
            const u = String(url);
            if (u.indexOf('/api/maps') === 0) {
              return Promise.resolve({ ok: true, status: 200,
                                       json: function () { return Promise.resolve({ maps: [] }); } });
            }
            return Promise.resolve({ ok: false, status: 404 });
          };
          tab15.crash.clear();
          escaped15.length = 0;
          el15('status-msg').textContent = '';
          const libHandlers15b = (els15['lib-list'] && els15['lib-list']._h &&
                                  els15['lib-list']._h.click) || [];
          ok(libHandlers15b.length > 0,
             '★★ ⑩b 前提:`#lib-list` 上真的挂着生产那个点击处理器(实得 ' +
             libHandlers15b.length + ' 个)');
          libHandlers15b.forEach(function (h) {
            h({ target: { closest: function () { return { dataset: { name: 'ghost.cyrm' } }; } } });
          });
          ok(await until15(function () {
               return el15('status-msg').textContent.indexOf('打开地图') >= 0;
             }),
             '★★★ 打开失败在状态栏上**说出来**了(「出错了(打开地图):…」;实得 "' +
             el15('status-msg').textContent + '")');
          ok(el15('status-msg').textContent.indexOf('404') >= 0,
             '★ 那句话里带着原因(HTTP 404 —— 不是一句没有线索的"出错了")');
          // ★ 反向断言给足时间:拒绝事件是**异步**投递的,只 tick 一次就判"没逃"是假绿。
          //   预算与上面那条反证**同一个**(until15 的 200 次 tick),故红的形态可比。
          await until15(function () { return false; });
          eq(escaped15.length, 0,
             '★★★ 那一次失败**没有**逃到全局围栏(逃了就说明入口又变成裸调用了;实得 ' +
             escaped15.length + ' 次)');
          eq(tab15.crash.size, 0,
             '★★★ 崩溃槽位里**什么都没有**(这就是"下次开机弹假提示"的全部内容;实得 ' +
             tab15.crash.size + ' 条)');

          // ── ② 长作业(`runJob`)的两个入口:油漆桶 / 渐变 ──
          // ★★ 判据同款:`runJob` 交回的是一整条**分帧链**的 promise,丢掉它 = 一次普通的
          //    落笔失败(编辑/渲染入口抛)换来一个假的崩溃提示。
          const savedCanvas15b = Editor.app.canvas, savedSt15b = Editor.app.st;
          const savedEdit15b = Editor.app.r.editCells, savedScreen15b = Editor.app.r.screenToSub;
          const savedPreview15b = Editor.app.r.setPreview;   // pointerup 的渐变分支会调它
          const canvasH15b = {};
          Editor.app.canvas = {
            width: 80, height: 80,
            setPointerCapture: function () {},
            getBoundingClientRect: function () { return { left: 0, top: 0 }; },
            addEventListener: function (t, fn) { canvasH15b[t] = fn; },
          };
          Editor.app.r.screenToSub = function () { return { X: 0, Y: 0 }; };   // 落格 (0,0)
          Editor.app.r.setPreview = function () {};
          Editor.app.r.editCells = function () { throw new Error('测试:批量落笔失败'); };
          // ★★ rAF 桩(只为这一小段装、收尾还回去):`runJob` 的分帧器要的 `nextFrame`
          //    默认走 `requestAnimationFrame`(render.js),而 node 里**没有**这个全局
          //    ⇒ 只要那条链需要**第二帧**,它就会以"requestAnimationFrame is not defined"
          //    拒掉 —— 那是**测试环境**的产物,会把这条断言想看的那个错(**注进去的落笔失败**)
          //    整个盖掉(实测:没有这个桩时,渐变那条读到的是这句 rAF 报错)。
          //    ★ 桩用真宏任务(与 `until15` 同一个 `realSetTimeout15`),于是分帧链真能跑完。
          const savedRaf15b = globalThis.requestAnimationFrame;
          globalThis.requestAnimationFrame = function (cb) { realSetTimeout15(cb, 0); };
          Editor.installInteraction();                 // 真装一遍(它建的处理器才是生产那一份)
          try {
            ok(typeof canvasH15b.pointerdown === 'function' &&
               typeof canvasH15b.pointerup === 'function',
               '⑩b 前提:画布上挂着 pointerdown/up');
            // 油漆桶
            Editor.app.st.tool = 'bucket';
            tab15.crash.clear(); escaped15.length = 0;
            el15('status-msg').textContent = '';
            canvasH15b.pointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
            ok(await until15(function () {
                 return el15('status-msg').textContent.indexOf('油漆桶填充') >= 0;
               }),
               '★★★ 油漆桶那条链失败也**说出来**了(「出错了(油漆桶填充):…」;实得 "' +
               el15('status-msg').textContent + '")');
            await until15(function () { return false; });
            eq(escaped15.length, 0,
               '★★★ 油漆桶失败**没有**逃到全局围栏(裸 `runJob(...)` 的实现这里 ≥1)');
            eq(tab15.crash.size, 0, '★★★ 也没有写崩溃槽位');
            // 渐变(pointerdown 起终点、pointerup 才真跑那条分帧链)
            Editor.setLayer(Core.LAYER_BG);            // 规格 §4.4:渐变仅背景层
            Editor.app.st.tool = 'gradient';
            tab15.crash.clear(); escaped15.length = 0;
            el15('status-msg').textContent = '';
            canvasH15b.pointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
            ok(!!Editor.app.st.gradStart, '⑩b 前提:pointerdown 起了渐变起点');
            canvasH15b.pointerup({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
            ok(await until15(function () {
                 return el15('status-msg').textContent.indexOf('渐变') >= 0;
               }),
               '★★★ 渐变那条链失败也**说出来**了(「出错了(渐变):…」;实得 "' +
               el15('status-msg').textContent + '")');
            await until15(function () { return false; });
            eq(escaped15.length, 0, '★★★ 渐变失败**没有**逃到全局围栏');
            eq(tab15.crash.size, 0, '★★★ 也没有写崩溃槽位');
          } finally {
            Editor.app.r.editCells = savedEdit15b;
            Editor.app.r.screenToSub = savedScreen15b;
            globalThis.requestAnimationFrame = savedRaf15b;
            Editor.app.r.setPreview = savedPreview15b;
            Editor.app.canvas = savedCanvas15b;
            Editor.app.st = savedSt15b;
          }
        } finally {
          process.removeListener('unhandledRejection', onUnhandled15);
          globalThis.addEventListener = savedAdd15b;
          Editor.setErrorSink(savedSink15b);
        }
      }

      // ── ⑪ 闸 4 的**读**侧:下次打开时"崩溃槽位比主槽位新" ⇒ 问一次并恢复 ──
      // ★ 这一段要造好几份崩溃快照,故抽成一个"往槽位里放一份"的小助手(每次都是新字节)。
      const putCrash15 = async function (savedAt, extra) {
        const m = Editor.createEmptyMap('crash_probe', 4, 4);
        m.enemies.push({ x: 1, y: 1, type: 'fly_bird' }, { x: 2, y: 2, type: 'fly_bird' });
        const rec = { key: 'crash', name: 'crash_probe.cyrm', name2: 'crash_probe',
                      bytes: await globalThis.Io.encodeMap(m, { compress: true }),
                      savedAt: savedAt, why: '测试造的崩溃' };
        Object.keys(extra || {}).forEach(function (k) { rec[k] = extra[k]; });
        tab15.crash.set('crash', rec);
        Editor.app.map = Editor.createEmptyMap('crash_probe', 4, 4);
        Editor.app.name = 'crash_probe.cyrm';
        asked15 = 0; answer15 = true;
        globalThis.confirm = function () { asked15++; return answer15; };
      };
      await putCrash15(Date.now() + 10000);
      eq(await Editor.checkCrashSlot(), true,
         '★★★ 崩溃槽位比主草稿新 ⇒ checkCrashSlot 交回 true 并恢复(闸 4 的另一半)');
      eq(asked15, 1, '★★ 恢复前**问了**一次(不静默把画布换掉)');
      eq(Editor.app.map.enemies.length, 2, '★★ 恢复的是崩溃前那张(2 个敌人),不是屏幕上那份');
      ok(el15('status-msg').textContent.indexOf('已从崩溃前快照恢复') >= 0,
         '★★ 恢复要**说一句**(实得 "' + el15('status-msg').textContent + '")');
      // ★★★ 恢复成功 ⇒ 这条快照要被**消费掉**:不删的话**每一次**打开都会再弹一次
      //     「上次异常退出」(一次偶发页面异常 = 一个永久的开机弹窗,用户可见)。
      eq(tab15.crash.has('crash'), false,
         '★★★ 恢复成功后崩溃槽位被**消费掉**(否则每一次打开都再问一遍;实得还在:' +
         tab15.crash.has('crash') + ')');
      // ★★ 点"不要"那一支:记录**留着**(那是没写盘的活),但要把"问过、不要"记上 ——
      //    于是同一条快照不再反复问;而新的一次崩溃(不带 declined)照问。
      await putCrash15(Date.now() + 20000);
      answer15 = false;
      eq(await Editor.checkCrashSlot(), false, '★ 用户点"不要" ⇒ 不恢复');
      eq(asked15, 1, '★ 那一支真问了');
      ok(tab15.crash.has('crash'),
         '★★ 点"不要"时崩溃快照**留着**(那是没写盘的活,不能因为点了一次就删)');
      eq(tab15.crash.get('crash') && tab15.crash.get('crash').declined, true,
         '★★ 记下了"问过、不要"(不然下一次打开又弹同一个框)');
      ok(el15('status-msg').textContent.indexOf('崩溃快照仍在崩溃槽位里') >= 0,
         '★★ 说了一句"没有打开它"(实得 "' + el15('status-msg').textContent + '")');
      eq(await Editor.checkCrashSlot(), false, '★★ 同一条崩溃快照**不再问第二次**');
      eq(asked15, 1, '★★★ 那一次连确认框都没弹(一次偶发异常不该变成每次打开都弹)');
      answer15 = true;
      await putCrash15(Date.now() + 30000);            // 新的一次崩溃:记录被重写
      eq(await Editor.checkCrashSlot(), true,
         '★★ (对照)新的一次崩溃(记录被重写、不带 declined)照问照恢复');
      eq(asked15, 1, '★ (对照)那次也真问了');
      // 反向:崩溃槽位比主草稿**旧** ⇒ 不提示(否则每次打开都弹一次无关的框)
      await putCrash15(1);
      el15('status-msg').textContent = '';
      asked15 = 0;
      eq(await Editor.checkCrashSlot(), false, '★ 崩溃槽位比主草稿旧 ⇒ 不提示');
      eq(asked15, 0, '★★ 那一次连确认框都没弹(不是"问了但没恢复")');

      // ── ⑪b ★★★ 启动这一路的**代价形状**:点读 + 索引键游标,不是整库读(终审评审 I3)──
      // ★ 原来这里为了求"主草稿最新那个 `savedAt`"把**草稿盘整库**读进来(每张草稿带着编码后
      //   的整张图,规格 §4.3:每张 2.4MB),而它要的只是一个时刻。判据是**读数**:整库读 0 次、
      //   值游标(会物化记录本体)0 次、键游标 ≥ 1 次(只回一个数)。
      await putCrash15(Date.now() + 40000);
      idbReads15.getAll = 0; idbReads15.cursor = 0; idbReads15.keys = 0;
      eq(await Editor.checkCrashSlot(), true, '⑪b 前提:这一份崩溃快照比主草稿新 ⇒ 恢复');
      eq([idbReads15.getAll, idbReads15.cursor], [0, 0],
         '★★★ 崩溃槽位这一路**一条记录本体都没读**(整库读 ' + idbReads15.getAll +
         ' 次 / 值游标 ' + idbReads15.cursor + ' 次):它只需要"主草稿最新那个时刻"');
      ok(idbReads15.keys >= 1,
         '★★ 那个时刻是**索引键游标**给的(只回一个数,' + idbReads15.keys + ' 次)');

      // ── ⑪c ★★★ 读失败要**说出来**,不许折成"没有崩溃快照"(终审评审 I3)──
      // ★ 折成"没有"的实现在行为上与"真没有"**完全一样**(都是静默 return false)⇒ 这一层
      //   最后一次抢救就这么消失了,而用户以为自己只是没触发过它。
      await putCrash15(Date.now() + 50000);
      asked15 = 0;
      el15('status-msg').textContent = '';
      fail15.get = true;                              // ← 单条读失败(真环境:事务打不开 / 配额)
      eq(await Editor.checkCrashSlot(), false, '⑪c 读不到时不恢复(不知道有没有,就不动屏幕)');
      fail15.get = false;
      ok(el15('status-msg').textContent.indexOf('崩溃槽位读取失败') >= 0 &&
         el15('status-msg').textContent.indexOf('读不到') >= 0,
         '★★★ 而且**说了出来**(实得 "' + el15('status-msg').textContent + '")—— ' +
         '静默折叠成"没有崩溃快照"是这一层最不能有的失败面(作品丢了而没人知道)');
      eq(asked15, 0, '★ 读不到时不弹确认框(不拿一份可能不存在的快照去问)');
      ok(tab15.crash.has('crash'), '★ 读失败**不许**碰崩溃槽位里那条记录');
      tab15.crash.clear();

      // ── ⑮b ⑫ 闸 1 的清理:代价形状(先数后读)+ 两条失败路径都要说话 ──
      // ★★ 编号:这是 ⑮b 的**子相位** ⑫(与文件前面那个顶层「相位 ⑫ 历史/剪贴板/选区移动」
      //    不是一件事)—— 子相位的编号在自己的括号里连续排,而消息里一律带 `⑮b⑫` 前缀,
      //    免得"红的是第几相"变成指代不清(⑮ 当初顺延就是因为同一份文件里两个 ⑭)。
      // ★★ 为什么单立一相:
      //    ① **代价形状**——清理跑在**每一次**防抖落盘之后,而库满时每张草稿带着编码后的整张
      //       图(规格 §4.3 的闸 1 表:每张 2.4MB)。"没到上限时一条都不反序列化"是**代价**而
      //       不是行为,断不了对错,只能靠"`getAll` 被调了几次"这个读数钉住(变异见报告)。
      //    ② **两条失败路径**(读不到 / 删不掉)都要在状态栏**说出话** —— 静默的话"闸 1 不
      //       生效"与"没到上限"长得一模一样,用户只会看到草稿盘悄悄涨过 60 条。
      //    ★ 同时钉住"失败**不拒绝这次写入**":最新那份劳动必须留下。
      tab15.draft.clear();
      Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);
      Editor.app.name = 'draft_probe.cyrm';
      Editor.app.sourceFormat = 'v4';
      idbReads15.count = 0; idbReads15.getAll = 0; idbReads15.cursor = 0; idbReads15.keys = 0;
      el15('status-msg').textContent = '';
      Editor.markDirty();
      await Editor.saveDraft(false);                  // ← 生产那条链:编码 → 落盘 → 清理
      eq(tab15.draft.size, 1, '⑮b⑫ 前提:这一笔真落进了草稿盘');
      ok(idbReads15.count >= 1, '★ 清理闸门先问**条数**(count)—— 它是"要不要读记录本体"的唯一判据');
      // ★★ 判据从"`getAll` 一次都不调"**加严**成"三种读一次都没有":生产里已经没有整库读
      //    那条路了(`idbReadAll`/`idbGetAll` 整套删掉),索引游标也是读,一并钉住。
      //    旧口径:eq(idbReads15.getAll, 0, '… getAll 一次都不调 …')
      eq([idbReads15.getAll, idbReads15.cursor, idbReads15.keys], [0, 0, 0],
         '★★★ 库**没到**上限时**一条记录都不读**(实得 整库读 ' + idbReads15.getAll +
         ' / 索引值游标 ' + idbReads15.cursor + ' / 键游标 ' + idbReads15.keys + ' 次):' +
         '常态路径只物化一个整数,而不是把库里每张草稿(每张带着整张图的字节)读进主线程');
      // 灌到超过上限:65 条"已保存且更老"的 + 刚写的那一条 ⇒ 必须丢掉最老的 6 条
      for (let i = 0; i < 65; i++) {
        tab15.draft.set('old' + i, { key: 'old' + i, name: 'old' + i + '.cyrm', name2: 'old' + i,
                                     bytes: new Uint8Array([i]), sourceFormat: 'v4',
                                     savedAt: 1000 + i, dirty: false });
      }
      idbReads15.count = 0; idbReads15.getAll = 0; idbReads15.cursor = 0; idbReads15.keys = 0;
      el15('status-msg').textContent = '';
      Editor.markDirty();
      await Editor.saveDraft(false);
      eq(tab15.draft.size, Editor.MAX_LIB,
         '★★ 清理真的把总数压回上限之内(实得 ' + tab15.draft.size + ')');
      ok(!tab15.draft.has('old0') && !tab15.draft.has('old5'),
         '★★ 丢的是**最老的**那几条(old0/old5 都已不在)');
      ok(tab15.draft.has('draft_probe'),
         '★★ 刚写的那一条**没被丢**(清理不许动最新的活 —— 脏记录本来就排在队尾)');
      // ★★ 判据从"到了上限**读**了记录本体"改成"到了上限**只读够淘汰那几条**" —— 更强:
      //    旧的 `ok(idbReads15.getAll >= 1)` 只要求"读过",一个把整库 getAll 进来的实现
      //    照样满足它(而那正是要防的代价);这条要求**上界**。
      //    ★ 这里 66 条里只有刚写的 draft_probe 是脏的,而它按 savedAt 排在最后 ⇒ 走 6 条
      //      (old0..old5)就凑够 6 条干净的 ⇒ 恰好 6 条。
      ok(idbReads15.getAll === 0 && idbReads15.keys === 0 && idbReads15.cursor === 6,
         '★★★ 到了上限走**索引值游标**逐条挑牺牲者:只物化 ' + idbReads15.cursor +
         ' 条记录本体(= 要丢的那 6 条,够数就停),整库读 0 次 / 键游标 0 次。' +
         '★ 旧实现是 `getAll` 把 66 条(每条带着整张图的字节)一次读进主线程 —— ' +
         '而"库满着"是**常态**(写入顶过上限、清一条又回到上限)');
      ok(el15('status-msg').textContent.indexOf('已清掉 6 条最老的') >= 0,
         '★ 清掉了就说一句(实得 "' + el15('status-msg').textContent + '")');
      // ★★ 淘汰口径的**关键一格**:库里有一条**比所有干净记录都老**的脏记录(没写盘的活)——
      //    `evictPlan` 的口径是"干净优先、同龄最老优先" ⇒ 牺牲者必须还是**干净的**那条,
      //    脏的那一条一个都不能动。走索引键序逐条挑的实现很容易在这里错成"谁最老丢谁",
      //    而那会**静默丢掉用户还没写盘的劳动**(正是这一层的存在理由)。
      tab15.draft.set('olddirty', { key: 'olddirty', name: 'olddirty.cyrm', name2: 'olddirty',
                                    bytes: new Uint8Array([7]), sourceFormat: 'v4',
                                    savedAt: 1, dirty: true });        // ← 比谁都老、但是脏的
      idbReads15.count = 0; idbReads15.getAll = 0; idbReads15.cursor = 0; idbReads15.keys = 0;
      el15('status-msg').textContent = '';
      Editor.markDirty();
      await Editor.saveDraft(false);
      ok(tab15.draft.has('olddirty'),
         '★★★ 最老的那条**是脏的**(没写盘的活)⇒ 它**不许**被丢(丢它 = 静默丢掉用户的作品)');
      ok(!tab15.draft.has('old6'),
         '★★★ 而丢的仍是**干净且最老**的那条(old6):走的顺序里先遇到 olddirty(跳过)、再遇到' +
         'old6(凑够 1 条干净的就停)');
      eq(idbReads15.cursor, 2,
         '★★ 走的过程恰好读了 2 条(1 条被跳过的脏 + 1 条干净的牺牲者;实得 ' + idbReads15.cursor +
         ')—— 早退发生在**凑够干净的**那一刻,而不是走完整库 61 条');
      eq(tab15.draft.size, Editor.MAX_LIB, '★ 总数仍压回上限(实得 ' + tab15.draft.size + ')');
      // ★ olddirty **留在库里**(它是"没写盘的活"的那一档,下面那条删除失败路径正好还要它
      //   占着一个位置 —— 库在那一相之前必须正好等于上限)。
      // 失败路径之一:**读不到条数**(真环境里是事务打不开 / 配额被拒)
      fail15.count = true;
      idbReads15.count = 0; idbReads15.getAll = 0; idbReads15.cursor = 0; idbReads15.keys = 0;
      el15('status-msg').textContent = '';
      Editor.markDirty();
      await Editor.saveDraft(false);
      ok(tab15.draft.has('draft_probe'),
         '★★★ 数不到条数时**这次写入照样留下**(上限不生效的代价由用户承担,但作品必须保住)');
      ok(el15('status-msg').textContent.indexOf('草稿盘清理失败') >= 0 &&
         el15('status-msg').textContent.indexOf('读不到条目数') >= 0,
         '★★★ 读失败**说出来**了(实得 "' + el15('status-msg').textContent + '")—— ' +
         '静默折叠成"没到上限"是这一层的失败面里最不该有的那种');
      eq([idbReads15.getAll, idbReads15.cursor, idbReads15.keys], [0, 0, 0],
         '★ 数不到条数就**一条记录都不读**(读也没意义,白物化一遍)');
      ok(el15('st-save').textContent.indexOf('已自动保存') === 0,
         '★ 报的是**状态栏那一行**,没去顶 `#st-save`(自动保存时刻要留住;实得 "' +
         el15('st-save').textContent + '")');
      fail15.count = false;
      // 失败路径之二:**删除事务失败**(删不掉 ⇒ 上限同样没生效,同样必须说话)
      // ★ 先补一条干净记录把库顶到**超过**上限:上面那次失败没清成,但库正好是 60 条
      //   (`<= MAX_LIB` 就走不到删除那一支)—— 补到 61 条才踩得到这条路径。
      tab15.draft.set('extra', { key: 'extra', name: 'extra.cyrm', name2: 'extra',
                                 bytes: new Uint8Array([9]), sourceFormat: 'v4',
                                 savedAt: 1, dirty: false });
      fail15.deleteTx = true;
      el15('status-msg').textContent = '';
      Editor.markDirty();
      await Editor.saveDraft(false);
      ok(el15('status-msg').textContent.indexOf('草稿盘清理失败') >= 0 &&
         el15('status-msg').textContent.indexOf('删不掉') >= 0,
         '★★★ 删除事务失败也说出来了(实得 "' + el15('status-msg').textContent + '")');
      ok(tab15.draft.size > Editor.MAX_LIB,
         '⑮b⑫ 前提:那一次确实没清成(实得 ' + tab15.draft.size + ' 条)—— 否则这条测不到删除失败');
      ok(tab15.draft.has('draft_probe'), '★ 删除失败也**不影响这次写入**');
      fail15.deleteTx = false;
    } finally {
      globalThis.document = savedDoc15; globalThis.confirm = savedConfirm15;
      globalThis.setTimeout = savedSetTimeout15; globalThis.clearTimeout = savedClearTimeout15;
      globalThis.fetch = savedFetch15;
      if (savedIndexedDb15 === undefined) delete globalThis.indexedDB;
      else globalThis.indexedDB = savedIndexedDb15;
      Editor.app.r = savedR15; Editor.app.map = savedMap15; Editor.app.name = savedName15;
      Editor.app.sourceFormat = savedFmt15; Editor.app.db = savedDb15;
      Editor.app.canvas = savedCv15; Editor.app.uist = savedUist15;
      Editor.app.st = savedSt15; Editor.app.raw = savedRaw15;
    }
  }

  // ==== 相位 ⑯ ★★★ 四条规格要求"造好了却没人能碰到"的功能:把线接上 ====
  // ★★ 为什么必须另立一相(整支终审查出来的四条遗漏):内核写了、测试全绿、导出表也列了,
  //    而**生产里零调用点** —— "函数写对 + 导出表列上"这两件事在冒烟里**看不出**"用户碰不到",
  //    因为断言一直在直接调那个函数。四条各自的死法:
  //      ① 镜像(规格 §4.4 的选框):`mirrorRegion` 只有测试在调 ⇒ 热键那条路不存在;
  //      ② 改尺寸(审计 A10):`resizeMap` 只被 `btn-dup` 用(**尺寸不变**)⇒ 整条 `kind:'whole'`
  //         历史分支在生产里是死的(Task 6 修的那个别名 bug、`applyEntry` 的 whole 分支、
  //         `pushAndShow` 的 `whole ⇒ invalidateAll` 分派,全都只有测试在跑);
  //      ③ 压缩(规格 §3.5):两处 encode 都写死 `compress:true` ⇒ 那条"完整可用的退路"
  //         (compression=0)不可达 —— 而浏览器 deflate 与 Godot COMPRESSION_DEFLATE 的
  //         兼容性至今**没实测过**,这条退路是唯一的兜底;
  //      ④ 空格拖拽(规格 §4.8):`pointerdown` 只认中键与 Alt。
  // ★ 判据一律取**副作用**(地图改了没 / 历史能不能撤 / 走的是哪条渲染入口 / 发出去的第 6 个
  //   字节是几),而不是"没抛"。替身:window.addEventListener(抓处理器)、按 id 惰性建的假 DOM、
  //   记账的渲染器、记账的 fetch、记账的 Io.encodeMap。
  {
    const s16 = { add: globalThis.addEventListener, doc: globalThis.document,
                  r: Editor.app.r, map: Editor.app.map, canvas: Editor.app.canvas,
                  name: Editor.app.name, st: Editor.app.st, tileDefs: Editor.app.tileDefs,
                  fmt: Editor.app.sourceFormat, raw: Editor.app.raw,
                  ls: globalThis.localStorage, timer: globalThis.setTimeout,
                  fetch: globalThis.fetch, confirm: globalThis.confirm };
    const realTimer16 = globalThis.setTimeout;
    const handlers16 = {}, errs16 = [], calls16 = [];
    let status16 = '', sel16 = null;
    // ── 假 DOM(照相位 ⑭ 的手法:按 id 惰性建、记住挂上来的监听器;`_h[type]` 存**数组**,
    //    因为同一个事件可能有多个处理器)──
    const els16 = {}, made16 = [];
    // ★ `#palette` 的派生提示行走 `box.parentNode.insertBefore(...)`(见 buildPanels)⇒ 每个假
    //   元素都要有一个**能 insertBefore 的**父节点,否则建面板那一步当场抛。
    const root16 = { parentNode: null, className: '', style: {}, classList: null,
                     insertBefore: function () {}, appendChild: function () {} };
    function mkEl16(id) {
      const el = {
        id: id, textContent: '', value: '', checked: false, hidden: false, className: '',
        style: {}, dataset: {}, children: [], _h: {},
        parentNode: root16, nextSibling: null,
        classList: { add: function () {}, remove: function () {}, toggle: function () {},
                     contains: function () { return false; } },
        addEventListener: function (t, fn) { (el._h[t] = el._h[t] || []).push(fn); },
        appendChild: function (c) { el.children.push(c); return c; },
        insertBefore: function (c) { el.children.push(c); return c; },
        removeChild: function () {}, querySelector: function () { return mkEl16(null); },
        click: function () {
          (el._h.click || []).forEach(function (fn) { fn({ stopPropagation: function () {}, target: el }); });
        },
      };
      return el;
    }
    const statusEl16 = mkEl16('status-msg');
    Object.defineProperty(statusEl16, 'textContent',
      { set: function (v) { status16 = String(v); }, get: function () { return status16; } });
    function el16(id) {
      if (els16[id]) return els16[id];
      for (let i = 0; i < made16.length; i++) if (made16[i].id === id) return (els16[id] = made16[i]);
      return (els16[id] = mkEl16(id));
    }
    const layerRows16 = [1, 2, 3, 4].map(function (L) {
      const r = mkEl16(null); r.dataset = { layer: String(L) }; return r;
    });
    const toolBtns16 = Editor.TOOLS.map(function (t) {
      const b = mkEl16(null); b.dataset = { tool: t }; return b;
    });
    const gradBtn16 = mkEl16(null);
    const dom16 = {
      getElementById: function (id) { return id === 'status-msg' ? statusEl16 : el16(id); },
      querySelectorAll: function (sel) {
        if (sel === '#layers .layer-row') return layerRows16;
        if (sel === '#toolbar .tool') return toolBtns16;
        return [];
      },
      querySelector: function (sel) {
        return String(sel).indexOf('gradient') >= 0 ? gradBtn16 : null;
      },
      createElement: function () { const e = mkEl16(null); made16.push(e); return e; },
    };
    // ★ 记两个账:渲染入口("走的是哪条路")与"平移被叫过没有"
    Editor.app.canvas = {
      width: 80, height: 80,
      setPointerCapture: function () {},
      getBoundingClientRect: function () { return { left: 0, top: 0 }; },
      addEventListener: function (t, fn) { this['on' + t] = fn; },
    };
    Editor.app.r = {
      view: function () { return { x: 0, y: 0, zoom: 1 }; },
      layer: function () { return Core.LAYER_SCENE; },
      selection: function () { return sel16; },
      setSelection: function (s) { sel16 = s ? { x: s.x, y: s.y, w: s.w, h: s.h } : null; },
      setSelDrag: function () {}, setPreview: function () {}, setLayer: function () {},
      setGrid: function () {}, setSubGrid: function () {}, setTorus: function () {},
      setDimOthers: function () {}, setZoomAt: function () { return Promise.resolve(); },
      setMap: function () { return Promise.resolve(); },
      screenToSub: function () { return { X: 0, Y: 0 }; },
      editCells: function () { calls16.push('editCells'); },
      render: function () { calls16.push('render'); },
      invalidateAll: function () { calls16.push('invalidateAll'); return Promise.resolve(); },
      panBy: function () { calls16.push('panBy'); return Promise.resolve(); },
    };
    globalThis.addEventListener = function (t, fn) { handlers16[t] = fn; };
    globalThis.document = dom16;
    Editor.app.tileDefs = globalThis.TILE_DEFS;
    // ★ 报错通道:记下来(相位 ⑬/⑭ 同款 —— 处理器全在 guard 里跑,替身少一个方法就会变成
    //   一条被吞掉的异常,最后那条"一条错都没进过 sink"就是防这个的)。
    Editor.setErrorSink(function (t) { errs16.push(String(t)); });
    const press16 = function (k, target, extra) {
      const ev = { key: k, target: target, ctrl: false, meta: false, shift: false, altKey: false,
                   button: 0, clientX: 0, clientY: 0, pointerId: 1 };
      if (extra) Object.keys(extra).forEach(function (kk) { ev[kk] = extra[kk]; });
      ev.defaultPrevented = false;
      ev.preventDefault = function () { ev.defaultPrevented = true; };
      handlers16.keydown(ev);
      return ev;
    };
    const release16 = function (k, target) {
      const ev = { key: k, target: target, ctrl: false, meta: false, shift: false, altKey: false };
      ev.defaultPrevented = false;
      ev.preventDefault = function () { ev.defaultPrevented = true; };
      handlers16.keyup(ev);
      return ev;
    };
    // 把撤销栈清空。★ 判据必须是 `=== null`(历史空了的**唯一**信号):cells / spawn 类条目
    //   交回的是 `undefined`(falsy)—— 拿真假值当循环条件会在第一条 spawn 条目上**提前退出**,
    //   于是"历史已空"那条前置断言是假的(后面"没进历史"那几条就都成了假绿)。
    const drain16 = async function () {
      let n = 0;
      while (true) {
        const r = Editor.doUndo();
        if (r === null) break;
        await r;
        if (++n > 400) break;
      }
    };
    try {
      Editor.app.map = Editor.createEmptyMap('p16', 4, 3);
      Editor.installInteraction();               // ← 真装一遍(handler 与**生产状态对象**都来自这里)
      ok(typeof handlers16.keydown === 'function' && typeof handlers16.keyup === 'function' &&
         typeof handlers16.blur === 'function' && typeof Editor.app.canvas.onpointerdown === 'function',
         '⑯ 前提:installInteraction 挂上了 keydown / keyup / blur / pointerdown(实得 keydown=' +
         typeof handlers16.keydown + ' keyup=' + typeof handlers16.keyup + ' blur=' +
         typeof handlers16.blur + ')');
      Editor.buildPanels();                      // ← 真建一遍面板(尺寸那颗按钮必须真的接上)
      // ★ 照 `editor.html` 里那个 `checked` 属性:假元素默认 `checked=false`,不补这一行的话
      //   "没存过状态时的默认"那条断言量的是**替身**的默认,而不是页面的默认。
      el16('opt-compress').checked = true;

      // ════ ⑯a 镜像(规格 §4.4;热键 H/V 是自选的,规格 §4.8 的表里没有镜像键)════
      eq(Editor.commandFor({ key: 'h' }), 'mirror:h', '★★ H → 水平镜像(规格 §4.4 的选框要有镜像)');
      eq(Editor.commandFor({ key: 'H' }), 'mirror:h', '★ 大写 H 同样(判据一律小写化)');
      eq(Editor.commandFor({ key: 'v' }), 'mirror:v', '★★ V → 垂直镜像');
      eq(Editor.commandFor({ key: 'v', ctrl: true }), 'paste',
         '★★ Ctrl+V 仍是粘贴 —— 带修饰键的分支在上面就 return 了,`v` 这一条与它不撞');
      eq(Editor.commandFor({ key: 'h', ctrl: true }), null,
         '★ Ctrl+H 表外 → null(不拦浏览器自己的快捷键)');
      // 一张 3×1 格的图:格 0/1/2 分别填 A/B/C(各 4 个子格宽、4 行高)
      const A16 = Core.neutralDesc(3), B16 = Core.neutralDesc(5), C16 = Core.neutralDesc(7);
      const mm16 = Core.createMap('m16', 3, 1);
      const arr16 = mm16.layers[Core.LAYER_SCENE].desc;
      for (let y = 0; y < 4; y++) {
        for (let x = 0; x < 4; x++) {
          arr16[y * 12 + x] = A16; arr16[y * 12 + 4 + x] = B16; arr16[y * 12 + 8 + x] = C16;
        }
      }
      Editor.app.map = mm16;
      sel16 = { x: 0, y: 0, w: 12, h: 1 };        // 只框第一**行**子格 ⇒ 垂直镜像什么都不变
      const evMir16 = press16('h', { tagName: 'BODY' });
      ok(evMir16.defaultPrevented === true, '★ 镜像热键被拦下(preventDefault)');
      eq(arr16[0], C16,
         '★★★ H 水平镜像:格 0 现在装的是**原来的格 2**(实得 tex ' + Core.texOf(arr16[0]) +
         ' —— 热键根本不接的话这里还是 tex ' + Core.texOf(A16) + ')');
      eq(arr16[4], B16, '★ 中轴那一格不动(镜像不是"整体搬走")');
      eq(arr16[8], A16, '★★ 格 2 现在装的是原来的格 0');
      ok(calls16.indexOf('editCells') >= 0,
         '★ 落笔走的是 editCells(与别的差量同一条路;实得 ' + JSON.stringify(calls16) + ')');
      await Editor.doUndo();
      eq([Core.texOf(arr16[0]), Core.texOf(arr16[4]), Core.texOf(arr16[8])],
         [Core.texOf(A16), Core.texOf(B16), Core.texOf(C16)],
         '★★★ 撤销把镜像**撤回原样** —— 它真的进了历史(相位 ⑯ 之前 `mirrorRegion` 零调用点,这条无从谈起)');
      await Editor.doRedo();
      eq([Core.texOf(arr16[0]), Core.texOf(arr16[8])], [Core.texOf(C16), Core.texOf(A16)],
         '★★ 重做又把镜像做回来(差量两半都对)');
      // 同一张图换 V:框**整块**(3 格宽 × 1 行高时垂直镜像仍然是空的)⇒ 先把内容做成上下可辨
      arr16[0] = A16; arr16[4] = B16; arr16[8] = C16;      // 先还原成一行三色
      for (let x = 0; x < 4; x++) arr16[3 * 12 + x] = 0;    // 清掉第 2 行
      sel16 = { x: 0, y: 0, w: 4, h: 4 };                   // 只框格 0 的 4×4 子格
      press16('v', { tagName: 'BODY' });
      eq(arr16[3 * 12], A16,
         '★★ V 垂直镜像:格 0 的最后一行拿到了第一行那份(实得 tex ' + Core.texOf(arr16[3 * 12]) + ')');
      eq(arr16[0], 0, '★ 而第一行被换成了原来的最后一行(空)');
      // ── ⑯a② 非法轴:抛错 → 进同一条报错通道 → **历史一个条目都不许进** ──
      await drain16();
      eq(await Editor.doUndo(), null, '⑯ 前提:历史已经清空(撤销到底了)');
      const before16 = Array.from(arr16);
      errs16.length = 0;
      eq(Editor.mirrorSelection('x'), null,
         '★★★ 非法轴:交回 null(`mirrorRegion` 抛出的中文错**不许**被当成差量交给历史)');
      ok(errs16.length === 1 && errs16[0].indexOf('镜像轴非法') >= 0,
         '★★★ 非法轴的错经 `guard` 落到**同一条报错通道**(用户看得见;实得 ' + JSON.stringify(errs16) + ')');
      eq(Array.from(arr16), before16, '★★ 非法轴一格都没改(不是"镜像了一半")');
      eq(await Editor.doUndo(), null,
         '★★★ 非法轴**没有**往历史里塞条目:撤销栈仍是空的(塞进去的话这一步会返回一个什么都不做的条目,' +
         '"撤销"按下去像没反应)');
      // 反向对照:合法轴但**内容没变**(1×1 格:这条轴上就是回文)同样不塞条目
      sel16 = { x: 0, y: 0, w: 4, h: 4 };
      eq(Editor.mirrorSelection('h'), null, '★ (对照)内容没变的镜像交回 null');
      ok(status16.indexOf('没变') >= 0,
         '★ 说了一句"没变"(不许静默;实得 "' + status16 + '")');
      eq(await Editor.doUndo(), null, '★★ 内容没变的那次也没进历史(空差量进历史 = 撤销按下去像没反应)');
      errs16.length = 0;      // ★ 上面那一次是**故意**触发的非法轴:清了它,末尾那条"一条错都没进过"才有牙齿

      // ════ ⑯b 改尺寸(审计 A10;★ 这是 `resizeMap` / `wholeDiff` / `whole` 历史分支的
      //      生产入口)════
      const mz16 = Editor.createEmptyMap('z16', 4, 3);
      const dz16 = mz16.layers[Core.LAYER_SCENE].desc;
      for (let i = 0; i < 4; i++) dz16[i] = Core.neutralDesc(6);      // 格(0,0) 有内容
      mz16.players = [{ x: 1, y: 0 }, { x: 9, y: 9 }];                 // 第二条越界
      mz16.enemies = [{ type: 'fly_bird', x: 0, y: 0 }, { type: 'jump_bird', x: 40, y: 40 }];
      Editor.app.map = mz16;
      Editor.app.name = 'z16.cyrm';
      Editor.app.sourceFormat = 'v4';
      calls16.length = 0;
      el16('size-w').value = '2';
      el16('size-h').value = '3';
      el16('btn-resize').click();                  // ← 走**生产**的点击处理器
      eq([Editor.app.map.subCols, Editor.app.map.subRows], [8, 12],
         '★★★ 应用尺寸真的改了图(2×3 格 = 8×12 子格;实得 ' + Editor.app.map.subCols + '×' +
         Editor.app.map.subRows + ')。★ 这条同时钉住"按钮真的接上了" —— 只写函数不接按钮时这里是原尺寸');
      eq(Editor.app.map.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(6),
         '★ 重叠区的内容被保留');
      eq(Editor.app.map.players.length, 1,
         '★★ 越界的出生点被丢掉(留在图外 = 游戏读到网格外坐标,A10 说的正是这件事)');
      eq(Editor.app.map.enemies.length, 1, '★ 图内的敌人留着');
      ok(status16.indexOf('A10') >= 0 && status16.indexOf('出生点') >= 0 &&
         status16.indexOf('(9,9)') >= 0,
         '★★★ A10 的**提示**在状态栏上:点名了丢掉的那一项(不许静默清理;实得 "' + status16 + '")');
      ok(calls16.indexOf('invalidateAll') >= 0 && calls16.indexOf('editCells') < 0 &&
         calls16.indexOf('render') < 0,
         '★★ 画布按新尺寸**重新挂**:走的是 `invalidateAll`(`diffCells` 对 whole 是空数组 ⇒ ' +
         '只 render() 的话整张图停在旧尺寸上;实得 ' + JSON.stringify(calls16) + ')');
      eq([el16('size-w').value, el16('size-h').value], ['2', '3'],
         '★ 两个框回显的是**改后**的尺寸');
      // ★★★ whole 历史分支:撤销必须把**尺寸**退回去(这也是"整个分支真的在生产里跑起来了"的唯一判据)
      calls16.length = 0;
      await Editor.doUndo();
      eq([Editor.app.map.subCols, Editor.app.map.subRows], [16, 12],
         '★★★ 撤销一次改尺寸:图回到 4×3 格(实得 ' + Editor.app.map.subCols + '×' +
         Editor.app.map.subRows + ')。★ 只把 `app.map` 换成新对象(而不是原地装)的实现会在这里红:' +
         'before === after ⇒ 撤销什么都不做');
      eq(Editor.app.map.players.length, 2, '★★ 出生点也跟着回来了(whole 快照里带着它们)');
      ok(calls16.indexOf('invalidateAll') >= 0, '★ 撤销 whole 也要重挂画布(不是 setMap:不重置视野与选区)');
      await Editor.doRedo();
      eq(Editor.app.map.subCols, 8, '★★ 重做又回到 2×3 格(差量两半都对)');
      // ── 闸 1:输入一律**钳制**,不报错回滚 ──
      el16('size-w').value = '99999';
      el16('size-h').value = 'bad';
      el16('btn-resize').click();                  // ★ 不抛(抛的话经 window.onerror 变成「页面异常:…」)
      eq([Core.cellsWOf(Editor.app.map), Core.cellsHOf(Editor.app.map)], [400, 75],
         '★★ 输 99999 / 非数字都不抛:超大数被 `Core.clampMapSize` 钳到 400,非数字回落到默认高 75' +
         '(尺寸闸只此一条路;实得 ' + Core.cellsWOf(Editor.app.map) + '×' +
         Core.cellsHOf(Editor.app.map) + ')');
      eq([el16('size-w').value, el16('size-h').value], ['400', '75'],
         '★ 钳制结果**回显**到框里(否则用户以为它接受了 99999)');
      ok(status16.indexOf('没有越界项') >= 0,
         '★ 放大不丢任何东西时也照实说(实得 "' + status16 + '")');
      // ── 反向对照:尺寸没变 ⇒ 不进历史 ──
      await drain16();
      el16('btn-resize').click();                  // 框里与图同尺寸(400×75)
      ok(status16.indexOf('尺寸没变') >= 0, '★ 尺寸没变时说了一句(实得 "' + status16 + '")');
      eq(await Editor.doUndo(), null, '★★ 尺寸没变的那次**不进历史**(空条目进历史 = 撤销按下去像没反应)');

      // ════ ⑯c 压缩开关(规格 §3.5)════
      ok(!!Editor.encodeForWrite && Editor.DEFAULT_COMPRESS === true,
         '★ 默认**勾上**(规格 §3.5:导出面板上的「压缩」默认勾上)');
      eq(Editor.optCompress(), true, '★ 控件不在/没改过时按默认走');
      const seenOpts16 = [];
      const realEncode16 = globalThis.Io.encodeMap;
      globalThis.Io.encodeMap = function (map, o) {
        seenOpts16.push(o);
        return realEncode16.call(globalThis.Io, map, o);
      };
      try {
        el16('opt-compress').checked = false;
        const rawBytes16 = await Editor.encodeForWrite(Editor.app.map);
        el16('opt-compress').checked = true;
        const zipBytes16 = await Editor.encodeForWrite(Editor.app.map);
        eq([rawBytes16[5], zipBytes16[5]], [0, 1],
           '★★★ 开关真的走到了 `encodeMap`:取消勾选 = compression=0(裸 body)、勾上 = 1。' +
           '★ 这条比"实参对不对"更强 —— 它是**真 codec** 产出的第 6 个字节(实得 ' +
           rawBytes16[5] + '/' + zipBytes16[5] + ')');
        eq(seenOpts16, [{ compress: false }, { compress: true }],
           '★★ 两条路都可达,而且走的是**同一个**助手(`encodeForWrite`)');
      } finally {
        globalThis.Io.encodeMap = realEncode16;
      }
      // ★★ 端到端:真保存那条路写出去的文件,头里那一位也要跟着开关走 ——
      //    "开关接上了"与"写盘真的用它"是两件事(中间隔着一个 `saveCurrent`)。
      const put16 = [];
      globalThis.fetch = function (url, init) {
        if (init && init.method === 'PUT') {
          put16.push({ url: String(url), init: init });
          return Promise.resolve({ ok: true, status: 200,
            json: function () { return Promise.resolve({ name: 'w16.cyrm', size: 9 }); } });
        }
        return Promise.resolve({ ok: true, status: 200,
          json: function () { return Promise.resolve({ maps: [] }); } });
      };
      Editor.app.map = Editor.createEmptyMap('w16', 2, 1);
      Editor.app.name = 'w16.cyrm';
      Editor.app.sourceFormat = 'v4';
      el16('opt-compress').checked = false;
      await Editor.saveCurrent(false);
      const putRaw16 = put16.length ? new Uint8Array(await put16[0].init.body.arrayBuffer()) : null;
      eq(putRaw16 ? putRaw16[5] : null, 0,
         '★★★ 取消勾选之后 **Ctrl+S 写出去的那份 .cyrm** 是裸 body(compression=0)' +
         '(实得 ' + (putRaw16 ? putRaw16[5] : '(没有请求)') + ')—— 这就是规格 §3.5 的那条退路,' +
         '此前两处 encode 都写死 compress:true,用户碰不到它');
      el16('opt-compress').checked = true;
      put16.length = 0;
      await Editor.saveCurrent(false);
      const putZip16 = put16.length ? new Uint8Array(await put16[0].init.body.arrayBuffer()) : null;
      eq(putZip16 ? putZip16[5] : null, 1, '★ 勾上之后同一个出口写的是压缩路径(compression=1)');
      // ── ⑯c② 持久化(与别的小状态同一层、同一条路)──
      const ls16 = {};
      globalThis.localStorage = {
        getItem: function (k) { return (k in ls16) ? ls16[k] : null; },
        setItem: function (k, v) { ls16[k] = String(v); },
        removeItem: function (k) { delete ls16[k]; },
      };
      // ★ 只把"延迟"改成 0(不是"立刻同步跑"):立刻跑会让 io.js 自己的超时定时器在**应答
      //   之前**触发(那个 codec 在 node 里是同步替身,但定时器是真的)。
      globalThis.setTimeout = function (fn) { return realTimer16(fn, 0); };
      try {
        el16('opt-compress').checked = false;
        Editor.persistUi();
        await new Promise(function (r) { realTimer16(r, 0); });
        await new Promise(function (r) { realTimer16(r, 0); });
        const saved16 = JSON.parse(ls16[Editor.UI_STATE_KEY] || '{}');
        eq(saved16.compress, false, '★★ 取消勾选之后那份小状态里 `compress:false`');
        eq(Editor.readUiState(ls16).compress, false, '★★ 读回来还是 false(不是"存了不读")');
      } finally {
        globalThis.setTimeout = s16.timer;
      }
      eq(Editor.uiStateDefaults().compress, true, '★ 默认值 = 勾上(老存档没有这个字段时也走它)');
      el16('opt-compress').checked = true;
      Editor.app.uist = Editor.readUiState(ls16);
      Editor.applyUiState();
      eq(el16('opt-compress').checked, false,
         '★★★ applyUiState 把它按回界面(勾选框与状态一致)');
      Editor.app.uist = null;
      el16('opt-compress').checked = true;         // 还原成默认,别把状态漂到后面的断言里

      // ════ ⑯d 空格拖拽平移(规格 §4.8)════
      // ★★ "不许滚页面"这一条的判据只能是 `preventDefault`:空格是浏览器的向下翻页键,
      //    node 里没有真的滚动可观测 —— 拦下默认行为就是"不滚"的**全部**内容。
      const evSpace16 = press16(' ', { tagName: 'BODY' });
      ok(evSpace16.defaultPrevented === true,
         '★★★ 页面上按下空格被**认领**并拦下默认行为(不拦 = 按空格准备拖拽时右边栏先滚一屏)');
      calls16.length = 0;
      Editor.app.canvas.onpointerdown({ button: 0, altKey: false, clientX: 10, clientY: 20, pointerId: 1 });
      ok(!!Editor.app.st.panning,
         '★★★ 空格 + 左键拖拽 = 平移(实得 panning=' + JSON.stringify(Editor.app.st.panning) + ')');
      ok(!Editor.app.st.stroke, '★ 而且没有顺手起一笔(平移与落笔是两条路)');
      Editor.app.canvas.onpointermove({ clientX: 30, clientY: 45 });
      ok(calls16.indexOf('panBy') >= 0,
         '★★ 拖动真的平移了画布(实得 ' + JSON.stringify(calls16) + ')');
      Editor.app.canvas.onpointerup({ button: 0, clientX: 30, clientY: 45 });
      ok(!Editor.app.st.panning, '★ 松手结束平移');
      // ── ⑯d② 松开空格之后左键**不是**平移(反向对照)──
      release16(' ', { tagName: 'BODY' });
      Editor.app.canvas.onpointerdown({ button: 0, altKey: false, clientX: 10, clientY: 20, pointerId: 1 });
      ok(!Editor.app.st.panning, '★★ (反向对照)松开空格之后左键不再是平移');
      Editor.app.st.stroke = null;                 // 那一下起的是普通笔画,清掉
      Editor.app.canvas.onpointerup({ button: 0, clientX: 10, clientY: 20 });
      // ── ⑯d③ 焦点在**输入框**里:空格一个都不许拦(用户是在敲空格)──
      const evSpaceIn16 = press16(' ', { tagName: 'INPUT' });
      ok(evSpaceIn16.defaultPrevented === false,
         '★★★ 焦点在输入框里时空格**不**被认领、也不 preventDefault(敲得进空格)');
      Editor.app.canvas.onpointerdown({ button: 0, altKey: false, clientX: 10, clientY: 20, pointerId: 1 });
      ok(!Editor.app.st.panning, '★★ 输入框里按的空格也不该让画布进入平移');
      Editor.app.st.stroke = null;
      Editor.app.canvas.onpointerup({ button: 0, clientX: 10, clientY: 20 });
      // ── ⑯d④ 按住空格时窗口失焦(Alt+Tab):keyup 到不了这个页面 ⇒ blur 必须清位 ──
      press16(' ', { tagName: 'BODY' });
      handlers16.blur();
      Editor.app.canvas.onpointerdown({ button: 0, altKey: false, clientX: 10, clientY: 20, pointerId: 1 });
      ok(!Editor.app.st.panning,
         '★★★ 失焦之后空格状态被清掉(不清的话回来一拖就莫名其妙地平移,而用户以为自己早松手了)');
      Editor.app.st.stroke = null;
      Editor.app.canvas.onpointerup({ button: 0, clientX: 10, clientY: 20 });
      // ── ⑯d⑤ 中键 / Alt 那两条老路不许被这次改动碰坏(评审的"改一处忘一处"方向)──
      Editor.app.canvas.onpointerdown({ button: 1, altKey: false, clientX: 1, clientY: 2, pointerId: 1 });
      ok(!!Editor.app.st.panning, '★ (对照)中键拖拽照旧平移');
      Editor.app.canvas.onpointerup({ button: 1, clientX: 1, clientY: 2 });
      Editor.app.canvas.onpointerdown({ button: 0, altKey: true, clientX: 1, clientY: 2, pointerId: 1 });
      ok(!!Editor.app.st.panning, '★ (对照)Alt + 左键照旧平移');
      Editor.app.canvas.onpointerup({ button: 0, clientX: 1, clientY: 2 });

      eq(errs16.length, 0,
         '★★ 整个相位里**一条错误都没进过 sink**(⑯a 那一条是故意触发并已断言的那次;' +
         '替身少一个方法就会变成一条被吞掉的异常;实得 ' + JSON.stringify(errs16) + ')');
    } finally {
      Editor.setErrorSink(null);
      globalThis.addEventListener = s16.add;
      globalThis.document = s16.doc;
      globalThis.localStorage = s16.ls;
      globalThis.setTimeout = s16.timer;
      globalThis.fetch = s16.fetch;
      globalThis.confirm = s16.confirm;
      Editor.app.r = s16.r; Editor.app.map = s16.map; Editor.app.canvas = s16.canvas;
      Editor.app.name = s16.name; Editor.app.st = s16.st; Editor.app.tileDefs = s16.tileDefs;
      Editor.app.sourceFormat = s16.fmt; Editor.app.raw = s16.raw;
      if (s16.ls === undefined) { try { delete globalThis.localStorage; } catch (e) {} }
    }
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
