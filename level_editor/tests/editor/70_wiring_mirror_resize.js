'use strict';
// ⑯a + ⑯b:镜像(规格 §4.4 的选框要有镜像)与改尺寸(审计 A10)。
// ★★ 为什么要这一相:内核写了、测试全绿、导出表也列了,而**生产里零调用点** ——
//    "函数写对 + 导出表列上"这两件事在冒烟里**看不出**"用户碰不到",因为断言一直在直接调
//    那个函数。① `mirrorRegion` 只有测试在调 ⇒ 热键那条路不存在;② `resizeMap` 只被
//    `btn-dup` 用(**尺寸不变**)⇒ 整条 `kind:'whole'` 历史分支在生产里是死的。
// ★ 判据一律取**副作用**(地图改了没 / 历史能不能撤 / 走的是哪条渲染入口),而不是"没抛"。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
require('./lib/stubs_wiring.js').getStubs16();

module.exports = (async function () {

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

  // ════ ⑯a 镜像(热键 H/V 是自选的,规格 §4.8 的表里没有镜像键)════
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
     '★★★ 撤销把镜像**撤回原样** —— 它真的进了历史(本相之前 `mirrorRegion` 零调用点,这条无从谈起)');
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
  ok(status16.indexOf('没变') >= 0, '★ 说了一句"没变"(不许静默;实得 "' + status16 + '")');
  eq(await Editor.doUndo(), null, '★★ 内容没变的那次也没进历史(空差量进历史 = 撤销按下去像没反应)');
  // ★ 上面那一次是**故意**触发的非法轴:清了它,末尾那条"一条错都没进过"才有牙齿
  errs16.length = 0;

  // ════ ⑯b 改尺寸(★ 这是 `resizeMap` / `wholeDiff` / `whole` 历史分支的生产入口)════
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
  // ★★★ whole 历史分支:撤销必须把**尺寸**退回去(这也是"整个分支真的在生产里跑起来了"的判据)
  calls16.length = 0;
  await Editor.doUndo();
  eq([Editor.app.map.subCols, Editor.app.map.subRows], [16, 12],
     '★★★ 撤销一次改尺寸:图回到 4×3 格(实得 ' + Editor.app.map.subCols + '×' +
     Editor.app.map.subRows + ')。★ 只把 `app.map` 换成新对象(而不是原地装)的实现会在这里红:' +
     'before === after ⇒ 撤销什么都不做');
  eq(Editor.app.map.players.length, 2, '★★ 出生点也跟着回来了(whole 快照里带着它们)');
  ok(calls16.indexOf('invalidateAll') >= 0, '★ 撤销 whole 也要重挂画布(不是 setMap:不重置视野与选区)');
  // ★★ 撤销一次改尺寸之后,那两个框也必须跟着翻 —— `applyEntry` 的 whole 分支调
  //    `refreshStatus()` 就是为这件事写的,而此前只断言了 `subCols/subRows` ⇒ **删掉那一句
  //    照样全绿**(框里留着 2×3,再按一次「应用尺寸」就把图又改回 2×3,而用户以为尺寸没变)。
  eq([el16('size-w').value, el16('size-h').value], ['4', '3'],
     '★★★ 撤销之后两个框回显的是**退回去**的尺寸(4×3)—— 只改渲染不碰面板的实现会在这里红' +
     '(实得 ' + JSON.stringify([el16('size-w').value, el16('size-h').value]) + ')');
  await Editor.doRedo();
  eq(Editor.app.map.subCols, 8, '★★ 重做又回到 2×3 格(差量两半都对)');
  eq([el16('size-w').value, el16('size-h').value], ['2', '3'],
     '★★ 重做之后框也跟着翻回去(两条路都接在 `refreshStatus()` 上)');
  // ── 闸 1:输入一律**钳制**,不报错回滚 ──
  el16('size-w').value = '99999';
  el16('size-h').value = '99999';
  el16('btn-resize').click();                  // ★ 不抛(抛的话经 window.onerror 变成「页面异常:…」)
  eq([Core.cellsWOf(Editor.app.map), Core.cellsHOf(Editor.app.map)], [400, 300],
     '★★ 输 99999 不抛:被 `Core.clampMapSize` 钳到上界 400×300' +
     '(尺寸闸只此一条路;实得 ' + Core.cellsWOf(Editor.app.map) + '×' +
     Core.cellsHOf(Editor.app.map) + ')');
  eq([el16('size-w').value, el16('size-h').value], ['400', '300'],
     '★ 钳制结果**回显**到框里(否则用户以为它接受了 99999)');
  ok(status16.indexOf('没有越界项') >= 0,
     '★ 放大不丢任何东西时也照实说(实得 "' + status16 + '")');
  // ── ★★★ "清空 / 垃圾"输入 = **这一项不改** ──
  // ★★ 旧行为:`Core.clampMapSize('')` 回落到 `DEFAULT_CELLS_W/H = 125×75` —— 那是**造新图**
  //    的语义。在"改尺寸"这条路上它是一次**静默缩图**:把宽那个框删空按「应用尺寸」,
  //    400 宽的图当场变成 125 宽,用户以为自己什么都没输。
  // ★ 先把历史清空:下面那条"不进历史"的断言只有在**本来就没有**待撤销条目时才有牙齿。
  await drain16();
  eq(await Editor.doUndo(), null, '⑯b 前提:历史已清空(下面"清空输入不进历史"才有牙齿)');
  eq([Core.cellsWOf(Editor.app.map), Core.cellsHOf(Editor.app.map)], [4, 3],
     '⑯b 前提:撤销到底之后图回到最初那张 4×3 格');
  el16('size-w').value = '';                   // 用户把宽删光了
  el16('size-h').value = 'bad';                // 垃圾(真浏览器里读回来同样是空串)
  el16('btn-resize').click();
  eq([Core.cellsWOf(Editor.app.map), Core.cellsHOf(Editor.app.map)], [4, 3],
     '★★★ 空着 / 不是数字的那一项**按原值处理**(图仍是 4×3;旧实现回落到默认 125×75 ⇒ ' +
     '这里会红,而画布上是一次**静默缩图**:400 宽的图被删空宽那一格就变成 125×300)');
  eq([el16('size-w').value, el16('size-h').value], ['4', '3'],
     '★★ 两个框**回显当前尺寸**(而不是留着那个被清空/垃圾的值 —— 与"DOM 必须与状态一致"同一条)');
  ok(status16.indexOf('尺寸没变(4×3),没有改动地图') >= 0 &&
     status16.indexOf('宽保留 4') >= 0 && status16.indexOf('高保留 3') >= 0,
     '★★★ 而且**说得出理由**(不许静默:状态栏逐项点名"哪一项没给数、按原值走了";实得 "' +
     status16 + '")');
  eq(await Editor.doUndo(), null,
     '★★ 清空输入的那一次**什么都没改** ⇒ 也不进历史(空条目进历史 = 撤销按下去像没反应)');
  // ── ★★ 一半给数、一半空着:给数的那一项照旧生效(闸 1 的"钳制不回滚"没被这次改动碰坏)──
  el16('size-w').value = '5';
  el16('size-h').value = '';
  el16('btn-resize').click();
  eq([Core.cellsWOf(Editor.app.map), Core.cellsHOf(Editor.app.map)], [5, 3],
     '★★ "宽给数、高空着"= 只改宽(空着那一项留住当前的 3;**不是**整条操作作废,' +
     '也不是拿 75 顶上去)');
  ok(status16.indexOf('尺寸改为 5×3 格') >= 0 && status16.indexOf('高保留 3') >= 0,
     '★★ 改成功了也照样点名那一项(实得 "' + status16 + '")');
  // ── 反向对照:尺寸没变 ⇒ 不进历史 ──
  await drain16();
  el16('btn-resize').click();                  // 框里与图同尺寸(`drain16` 撤销时 `refreshStatus` 已回显)
  ok(status16.indexOf('尺寸没变') >= 0, '★ 尺寸没变时说了一句(实得 "' + status16 + '")');
  eq(await Editor.doUndo(), null, '★★ 尺寸没变的那次**不进历史**(空条目进历史 = 撤销按下去像没反应)');

})();
