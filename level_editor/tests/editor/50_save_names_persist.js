'use strict';
// 纯逻辑半边(保存目标名 / v3 确认门 / 备份名)+ 草稿槽位与 UI 小状态的纯逻辑。
// ★ 需要 DOM 的那半边在 52/54(替身见 lib/stubs_save.js);这里一律不碰 DOM。
const Core = globalThis.Core;
const Editor = globalThis.Editor;

eq(Editor.saveTargetName(false), null, 'saveTargetName(false): 未打开任何地图 → null(调用方提示先打开)');
tableEq('needsV3Confirm:只有 v3/legacy 源的**首次**保存要确认', [
  ['v4 源(无损,不问)', Editor.needsV3Confirm('v4', false), false],
  ['v3 文本源首次(会转 v4 二进制,不可逆)', Editor.needsV3Confirm('v3', false), true],
  ['旧字母格式源首次', Editor.needsV3Confirm('legacy', false), true],
  ['已确认过的会话不再问', Editor.needsV3Confirm('v3', true), false],
  ['没打开地图时不问', Editor.needsV3Confirm(null, false), false],
]);

// ── 备份的逐文件门 ──
// ★ 为什么单独立这几条:确认框每会话一次是故意的(决定 ⑤),但备份不能跟着它一起变成每会话一次。
const backed14 = new Set();
const nb = [];
nb.push(['本会话还没备份过的 v3 文件 → 要备(哪怕确认框不再问)', Editor.needsV3Backup('v3', 'a.cyrm', backed14), true]);
backed14.add('a.cyrm');
nb.push(['同一文件已备过 → 不再备(不在 maps/ 里堆副本)', Editor.needsV3Backup('v3', 'a.cyrm', backed14), false]);
nb.push(['★★★ 逐文件:同会话里**另一个** v3 文件照样要备(会话级标记的实现在这里红)',
         Editor.needsV3Backup('v3', 'b.cyrm', backed14), true]);
nb.push(['旧字母格式源同样要备', Editor.needsV3Backup('legacy', 'c.cyrm', backed14), true]);
nb.push(['v4 源:没有要转换的原文,不备', Editor.needsV3Backup('v4', 'd.cyrm', backed14), false]);
nb.push(['没打开地图时不备', Editor.needsV3Backup(null, 'e.cyrm', backed14), false]);
nb.push(['还没落过盘的新图(没有文件名)不备', Editor.needsV3Backup('v3', null, backed14), false]);
tableEq('备份门逐文件(确认框每会话一次是故意的,备份不能跟着它也是)', nb);

// ── 备份名 = `<基名>_<8 位十六进制>.v3.bak`(结尾不是 .cyrm;用户裁定的名字)──
// ★★ 起多了一段哈希,于是这几条从"名字长什么样"升级成"名字单射":
//    金值钉住方案本身不漂,后面两组钉住"两个不同的文件名不许落到同一格"。
// ★ 三个金值一次比(换哈希 / 换截断长度 / 换成"只去 .cyrm"都会在这里点名到具体那一行)。
tableEq('v3BackupName 金值 = `<基名>_<FNV-1a 32 位十六进制>.v3.bak`', [
  ['普通名', Editor.v3BackupName('demo.cyrm'), 'demo_c9869709.v3.bak'],
  ['汉字被收掉(服务器只收 `[A-Za-z0-9_-]`,不然备份被 400 拒 ⇒ 保存卡死)', Editor.v3BackupName('图 1.cyrm'), '1_a67de2f9.v3.bak'],
  ['收完一个字符不剩 → 兜底名 `map`', Editor.v3BackupName('.cyrm'), 'map_3744a8d0.v3.bak'],
]);
// ★ 与上表不同类(判的是**后缀**而不是名字的值),单独留。
eq(Editor.v3BackupName('demo.cyrm').toLowerCase().endsWith('.cyrm'), false,
   '★★★ 备份名**不以 `.cyrm` 结尾** —— 游戏 `_random_cyrm` 的 `.ends_with(".cyrm")` 抽不到它');
ok(/^[A-Za-z0-9_-]+\.v3\.bak$/.test(Editor.v3BackupName('x'.repeat(80) + '.cyrm')) &&
   Editor.v3BackupName('x'.repeat(80) + '.cyrm').length <= 64,
   '★ 备份名的基名字符集合法、且不超过服务器的 MAX_MAP_NAME_LEN=64' +
   '(基名截 24 + `_` + 8 位哈希 + 后缀 = 40;实得 ' +
   Editor.v3BackupName('x'.repeat(80) + '.cyrm').length + ')');
// ★★★ 撞名:旧方案(收干净 + 截前 40)这两对各自落到同一个备份名上 ——
//     而它们的两份原文不是同一份 ⇒ 第二张图的保存会把第一张的退路静默覆盖。
ok(Editor.v3BackupName('图1.cyrm') !== Editor.v3BackupName('1.cyrm') &&
   Editor.v3BackupName('图甲.cyrm') !== Editor.v3BackupName('图乙.cyrm'),
   '★★★ 被"收干净"收成同一个基名(`1` / `map`)的两个**不同**文件名 ⇒ 备份名必须不同' +
   '(`图1.cyrm` 与 `1.cyrm` 旧方案都是 `1.v3.bak`;`图甲.cyrm` 与 `图乙.cyrm` 都是 `map.v3.bak`)');
ok(Editor.v3BackupName('a'.repeat(40) + 'X.cyrm') !==
   Editor.v3BackupName('a'.repeat(40) + 'Y.cyrm'),
   '★★★ 截断也撞不上:前 40 字完全相同的两个长名字,备份名**不同**(旧方案截到同一个前缀)');
// ★★★ 而服务器真的还认这些名字:拿生成出来的名字去问服务器自己的校验
//      (不是"看起来像"—— 那正是"备份被 400 拒 ⇒ 保存整个卡死"这条路的入口)。
const srvName = require('../../editor_server.js');
ok(srvName.isValidMapName(Editor.v3BackupName('demo.cyrm')) === true &&
   srvName.isValidMapName(Editor.v3BackupName('图 1.cyrm')) === true &&
   srvName.isValidMapName(Editor.v3BackupName('x'.repeat(80) + '.cyrm')) === true &&
   srvName.isValidMapName('.v3.bak') === false &&
   srvName.isValidMapName(Editor.v3BackupName('demo.cyrm') + 'x') === false,
   '★★★ 服务器自己的 `isValidMapName` **收下**这些备份名,而裸 `.v3.bak` 与"后缀后面再多一个字符"' +
   '照旧拒(放宽的只有那**一个后缀**,不是整套校验)');
ok(Editor.isBackupName('demo_c9869709.v3.bak') === true &&
   Editor.isBackupName('DEMO.V3.BAK') === true &&
   Editor.isBackupName('demo.cyrm') === false && Editor.isBackupName('.v3.bak') === false &&
   Editor.isBackupName('') === false && Editor.isBackupName(null) === false,
   '★★ `isBackupName` 认得出备份(大小写不敏感)—— 而地图名、裸后缀、空串都不算');
eq(Editor.freshName('my map!'), 'my_map.cyrm', '★ freshName 走 sanitizeName(服务器只收裸文件名)');

// ── 持久化的纯逻辑(需要 DOM 的那半边由人眼验收)──
tableEq('draftKey 由 sanitizeName 派生(不另铸一套 id)', [
  ['普通名', Editor.draftKey('demo.cyrm'), 'demo'],
  ['连字符保留', Editor.draftKey('my-map.cyrm'), 'my-map'],
  ['空名回落(与 Core.sanitizeName 同源)', Editor.draftKey(''), 'structure'],
]);
eq(Editor.MAX_LIB, 60, 'MAX_LIB = 60(规格 §4.3 闸 1)');
ok(Editor.DRAFT_DEBOUNCE_MS >= 500, '草稿落盘有防抖(不是每笔都写盘)');
eq(Editor.DRAFT_DB, 'cyrm-editor', 'DRAFT_DB 名字固定(换名 = 老草稿全丢)');
eq(Editor.UI_STATE_KEY, 'cyrm.ui.v1', 'UI_STATE_KEY 带版本号');

tableEq('crashIsNewer:只有"崩溃快照比主草稿新"才提示恢复', [
  ['崩溃(200) 比主草稿(100) 新 → 提示', Editor.crashIsNewer({ savedAt: 200 }, { savedAt: 100 }), true],
  ['主草稿更新 → 不提示', Editor.crashIsNewer({ savedAt: 100 }, { savedAt: 200 }), false],
  ['没有主草稿 → 有崩溃快照就提示', Editor.crashIsNewer({ savedAt: 100 }, null), true],
  ['没有崩溃快照 → 不提示', Editor.crashIsNewer(null, { savedAt: 1 }), false],
  ['两个都没有 → 不提示', Editor.crashIsNewer(null, null), false],
]);
// ★★ 问过、用户说"不要"的那一条不再问(不记的话一次偶发页面异常会把每一次打开都变成
//    "上次异常退出" —— 那是个永久弹窗,直到用户碰巧 Ctrl+S 把草稿写新)。
eq(Editor.crashIsNewer({ savedAt: 200, declined: true }, { savedAt: 100 }), false,
   '★ 已拒绝过的崩溃快照不再提示(与它比主草稿新不新无关)');
eq(Editor.crashIsNewer({ savedAt: 200, declined: false }, { savedAt: 100 }), true,
   '★ (对照)`declined:false` 照常提示(挡的是"一刀切成不提示")');

(function () {
  const recs = [];
  for (let i = 0; i < 65; i++) recs.push({ key: 'k' + i, savedAt: 1000 + i, dirty: i % 2 === 0 });
  const plan = Editor.evictPlan(recs, 60);
  eq(plan.keep.length + plan.drop.length, 65, '★ 不丢条目:keep + drop = 全部');
  eq(plan.keep.length, 60, '★ 上限 60:留下 60 条');
  const dropped = recs.filter(function (r) { return plan.drop.indexOf(r.key) >= 0; });
  ok(dropped.every(function (r) { return !r.dirty; }),
     '★★ 先丢**已保存**的(脏的那份是用户还没写盘的劳动,不许丢)');
  // ★★★ 判身份(不是"丢够 5 条就算"):65 条里脏的是偶数号,故要丢的正是最老的那 5 条
  //    干净记录 k1/k3/k5/k7/k9。★ 条数由身份蕴含,故"丢 5 条"不再单列一条断言。
  eq(plan.drop.slice().sort(), ['k1', 'k3', 'k5', 'k7', 'k9'],
     '★★★ 同条件时丢**最老的那几条干净记录**(不是"丢够 5 条就算";实得 ' + plan.drop.join(',') + ')');
  const allDirty = recs.map(function (r) { return { key: r.key, savedAt: r.savedAt, dirty: true }; });
  const plan2 = Editor.evictPlan(allDirty, 60);
  eq(plan2.drop.length, 5, '全是脏的时也得丢够(否则上限失效)');
  ok(plan2.drop.indexOf('k0') >= 0 && plan2.drop.indexOf('k1') >= 0, '全靠 savedAt 时丢最老的');
  eq(Editor.evictPlan([], 60), { keep: [], drop: [] }, '空库 → 空计划(不抛)');
})();

// localStorage 的 UI 小状态:读到损坏值一律回落默认(尤其"玩家参考图按格坐标存")
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
