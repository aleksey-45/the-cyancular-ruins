'use strict';
// 出生点的位置语义 / 导出校验 / #st-save 徽标的三态 / 保存流程真的把字节交给写盘出口。
// ★ 替身(假 DOM / 记账的 fetch / 记账的渲染器)在 lib/stubs_save.js;收尾在 54。
const fs = require('fs');
const path = require('path');
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const Render = globalThis.Render;
require('./lib/stubs_save.js').getStubs14();

module.exports = (async function () {

  // ── 敌人类型来自页面里的 ENEMY_REGISTRY:真跑一遍那段标记块,不抄写死的清单。
  const html = fs.readFileSync(path.join(__dirname, '..', '..', 'editor.html'), 'utf8');
  const regBlock = /\/\*__ENEMY_REGISTRY_BEGIN__\*\/([\s\S]*?)\/\*__ENEMY_REGISTRY_END__\*\//
                   .exec(html);
  ok(!!regBlock,
     '★ editor.html 里有 ENEMY_REGISTRY 的标记块(自检夹具的唯一来源;找不到 = 后面两条是假绿)');
  delete globalThis.ENEMY_REGISTRY;   // ★ 装夹具之前先断言它读不出任何东西(证明没有一份写死的清单)
  eq(Editor.importEnemyTypes(), [],
     '★★ 页面注册表缺席时 importEnemyTypes 返回 [](它不是写死的清单 —— 写死的那版这里会非空)');
  if (regBlock) new Function(regBlock[1])();   // 块体就是 `window.ENEMY_REGISTRY = [ … ];`
  ok(Editor.importEnemyTypes().length > 0, '★ 敌人类型来自页面里的 ENEMY_REGISTRY(不是写死的清单)');
  ok(Editor.importEnemyTypes().indexOf('fly_bird') >= 0, '注册表里有 fly_bird');

  // ── 出生点的位置语义 ──
  // ★★ 游戏侧 `map_format.gd` 按顺序读 player / player2 ⇒ "放 P2"必须写第 1 条(push 出 index 0 会被游戏读成 P1)。
  // 零出生点的图上放 P2:必须拒绝,而不是 push 出一条会被读成 P1 的记录
  Editor.spawnAt('player', 1);
  eq(Editor.app.map.players.length, 0,
     '★★ 零出生点的图上「放 P2」**不许**写盘:players 必须仍是 0 条(brief 原码在这里 push 出 ' +
     '1 条 index 0 的记录 = 游戏侧读成 **P1**,而状态栏说着"P2 放到 …";实得 ' +
     Editor.app.map.players.length + ' 条)');
  ok(status14.indexOf('先放 P1') >= 0,
     '★★ 拒绝要**说得出理由**(不许静默无反应;实得状态栏 "' + status14 + '")');

  // 放 P1 → 放 P2:P2 落在第 1 条(位置语义)
  Editor.spawnAt('player', 0);
  eq(Editor.app.map.players.length, 1, '★ 放 P1(空图)= 第 0 条');
  const p1at = { x: Editor.app.map.players[0].x, y: Editor.app.map.players[0].y };
  view14 = { x: 0, y: 4, zoom: 1 };                    // 挪一格 ⇒ P2 与 P1 的坐标可辨
  Editor.spawnAt('player', 1);
  eq(Editor.app.map.players.length, 2, '★ 放 P2 = 写第 **1** 条(不是又多一条)');
  ok(Editor.app.map.players[1].x !== p1at.x || Editor.app.map.players[1].y !== p1at.y,
     '★ P2 是**这一次**的坐标(与 P1 不同,故能看出写的是哪一条)');

  // 图上只有 P1 时再放一次 P1:必须原位覆盖、不许长出第 2 条 —— 多出来的那条 index 1 就是 P2。
  Editor.app.map.players.length = 1;
  view14 = { x: 8, y: 8, zoom: 1 };                    // 视图中心格 = 12,12 —— 越界,见下条
  Editor.spawnAt('player', 0);
  eq(Editor.app.map.players.length, 1,
     '★★ 只有 P1 时再放 P1:原位覆盖,**不许**长出第 2 条(= P2 被悄悄换掉;实得 ' +
     Editor.app.map.players.length + ' 条)');
  // ★ 8 格宽的图上视图中心算出来的格 12 是越界的;与 addSpawn/spawnIndexAt 同量纲:`wrapIdx(12, 8) = 4`。
  eq([Editor.app.map.players[0].x, Editor.app.map.players[0].y], [4, 4],
     '★ P1 原位覆盖面写的是**这一次**的坐标(**折算回本图范围**之后:8 格宽的图上,视图中心格 12 ⇒ 4)');
  // ★★ 视图拖到图外(`panBy` 不钳视图)时记录的坐标必须仍在 `[0, 格数)`:修好之前它写进磁盘的是 −90,−90。
  const w8 = Core.cellsWOf(Editor.app.map), h8 = Core.cellsHOf(Editor.app.map);
  view14 = { x: -400, y: -400, zoom: 1 };
  Editor.spawnAt('player', 0);
  const p = Editor.app.map.players[0];
  ok(p.x >= 0 && p.x < w8 && p.y >= 0 && p.y < h8 && p.x === Render.wrapIdx(-90, w8) &&
     p.y === Render.wrapIdx(-90, h8),
     '★★ 视图拖到图外(panBy 不钳视图)时记录的 P1 必须在 [0,' + w8 + ') 内且是**折算后**的值' +
     '(实得 ' + p.x + ',' + p.y + ';修复前会原样写下 −90,−90)');

  // P1+P2 都在时再放 P1:仍是原位覆盖,P2 一个字都不许动
  view14 = { x: 0, y: 4, zoom: 1 };
  Editor.spawnAt('player', 1);
  const p2at = { x: Editor.app.map.players[1].x, y: Editor.app.map.players[1].y };
  view14 = { x: 8, y: 8, zoom: 1 };
  Editor.spawnAt('player', 0);
  eq(Editor.app.map.players.length, 2,
     '★★ 已有一对出生点时再放 P1 **不许**长出第 3 条(实得 ' + Editor.app.map.players.length + ' 条)');
  ok(Editor.app.map.players[1].x === p2at.x && Editor.app.map.players[1].y === p2at.y,
     '★★ P2 原位不动(位置语义的正面判据)');

  // 敌人仍是追加(它们没有位置语义,顺序无关)
  Editor.spawnAt('enemy', 0);
  Editor.spawnAt('enemy', 0);
  eq(Editor.app.map.enemies.length, 2, '★ 敌人是追加语义(与出生点刻意不同)');
  // ★ 不写死 'fly_bird':期望值取自同一个注册表(写死的话注册表一改顺序这条就红)。
  eq(Editor.app.map.enemies[0].type, Editor.importEnemyTypes()[0],
     '★ 敌人类型取自注册表的第一项(实得 ' + Editor.app.map.enemies[0].type + ')');

  // ── 导出校验(规格 §4.7:只报告,不阻止导出)──
  const rep = Editor.exportReport();
  eq(rep.ok, true, '★ 干净的小图:ok = true(errors 为空 ⇒ encodeMap 不会拒绝)');
  ok(rep.lines.join('\n').indexOf('出生点 2') >= 0 &&
     rep.lines.join('\n').indexOf('敌人 2') >= 0,
     '★ 报告里有出生点/敌人条数(实得 ' + JSON.stringify(rep.lines) + ')');
  Editor.app.map.players.push({ x: 1, y: 1 });          // 第 3 个出生点
  // ★ 判逐字那一行:`Core.validateMap` 自己那条警告里也有"第 3 个及以后"六个字,用子串判的话删掉那行照样绿。
  ok(Editor.exportReport().lines.indexOf(
       '⚠ 第 3 个及以后的出生点游戏侧读不到(map_format.gd 只认 player/player2)') >= 0,
     '★★ >2 个出生点要有一行**自己的**明确警告(map_format.gd 只认 player/player2)');
  Editor.app.map = null;
  eq(Editor.exportReport(), { lines: ['还没打开地图'], ok: false },
     '★ 没打开地图时报告说的是人话(不是空面板)');

  // ── #st-save 的三种转变 ──
  // ★★ 状态栏右侧并排的是两件事:`#st-save` 说"磁盘上那份是不是这一份",`#status-msg` 说"刚刚发生了什么"。
  // ★★ 最重要的是第三条:保存失败时它必须仍是「未保存」(把清零链在 `guard(...)` 上就是那个陷阱)。
  Editor.app.map = Editor.createEmptyMap('dirty', 4, 4);
  Editor.app.name = 'before.cyrm';
  Editor.app.sourceFormat = null;                      // 无源格式 ⇒ needsV3Confirm 不问
  Editor.app.raw = null;
  const badge14 = function () { return elOf14('st-save').textContent; };
  view14 = { x: 0, y: 0, zoom: 1 };
  Editor.spawnAt('enemy', 0);                          // ① 落一笔(真差量、进真历史)
  eq(badge14(), '未保存', '★★ ①落一笔之后 #st-save 说「未保存」(实得 "' + badge14() + '")');
  putMode14 = 'ok';
  await Editor.saveCurrent(true);                      // ② 保存成功
  eq(badge14(), '已保存', '★★ ②保存成功后 #st-save 翻成「已保存」(实得 "' + badge14() + '")');
  ok(status14.indexOf('已保存') >= 0,
     '★ 同一刻 #status-msg 说的也是「已保存 …」(两格说的是同一件事;实得 "' + status14 + '")');
  view14 = { x: 0, y: 0, zoom: 1 };
  Editor.spawnAt('enemy', 0);                          // ③ 先弄脏(否则是上一次的残留)
  eq(badge14(), '未保存', '⑭c 前提:再落一笔之后回到「未保存」');
  putMode14 = 'fail';
  await Editor.saveCurrent(true);                      // ★ 保存失败
  ok(status14.indexOf('保存失败') >= 0,
     '★★ 保存失败要**说出来**(#status-msg 里有「保存失败」;实得 "' + status14 + '")');
  eq(badge14(), '未保存',
     '★★★ ③保存**失败**之后 #st-save 仍是「未保存」(磁盘上那份一个字都没变;实得 "' +
     badge14() + '")。★ 把 `dirty = false` / 徽标重画链在 `guard(...)` 的决议上,' +
     '`guard` 失败时决议的 `undefined` 会让这一格翻成「已保存」—— 本条就是那个陷阱的守卫');

  // ── 保存流程真的把字节交给了写盘出口,也真的更新了 app.name / sourceFormat ──
  // ★ 必须另立一条:把 `saveCurrent` 改成一行早退时,上面只有「保存成功」那条会红,而它的判据是徽标文案 —— "只翻徽标、不写盘"照样能过。
  putMode14 = 'ok';
  Editor.app.name = 'before.cyrm';                     // 与保存后的名字可辨
  Editor.app.sourceFormat = null;                      // 同上:改了才看得出来
  Editor.app.raw = null;
  putLog14.length = 0;
  await Editor.saveCurrent(true);
  eq(putLog14.length, 1,
     '★★ 一次 saveCurrent = **恰好一次**写盘请求(早退的实现这里是 0;实得 ' + putLog14.length + ' 次)');
  // ★ 后两条先判有没有那一次再取字段:空数组上取 `[0].url` 会抛出去中断整条冒烟。
  const put = putLog14.length ? putLog14[0] : null;
  ok(!!put && put.url.indexOf('/api/map?p=dirty_copy.cyrm') >= 0,
     '★ 写的是 saveTargetName 算出来的那个名字(实得 "' + (put ? put.url : '(没有请求)') + '")');
  ok(!!put && put.init && put.init.method === 'PUT',
     '★ 走的还是那个唯一的 PUT 出口(实得 ' + (put && put.init ? put.init.method : '(没有请求)') + ')');
  ok(Editor.app.raw && Editor.app.raw.length > 0,
     '★ app.raw 换成了这一份新编码出来的字节(实得 ' +
     (Editor.app.raw ? Editor.app.raw.length + ' 字节' : String(Editor.app.raw)) + ')');
  eq(Editor.app.name, 'dirty_copy.cyrm',
     '★★ app.name 更新成真正落盘的那个名字(实得 ' + Editor.app.name + ')');
  eq(Editor.app.sourceFormat, 'v4',
     '★★ app.sourceFormat 更新成 v4(落盘的就是 v4 二进制;实得 ' + Editor.app.sourceFormat + ')');

})();
