'use strict';
// ⑰a + ⑰b:一次**失败**的打开不许污染 `app.raw`;缩小地图之后**装不下**的选区必须清掉。
// ★★ 这两条各自都是**不报错**的坏:代价分别是**丢掉一份原文**与**把改动写到接缝另一边**。
// ★ 判据取**副作用**(PUT 的 body 字节 / 选区还在不在 / 一格都没改),而不是"没抛"。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
require('./lib/stubs_recheck.js').getStubs17();

module.exports = (async function () {

  Editor.buildPanels();                        // ← 真建一遍面板(尺寸按钮 / 库列表委托都得真接上)
  Editor.installInteraction();                 // ← 真装一遍(空格修饰键那一对处理器)

  // ════ ⑰a 一次**失败**的打开不许污染 `app.raw` ════
  // ★★ 复现的就是评审跑出来的那条路:打开 A.cyrm(v3 文本,`app.raw` = A 的原文)→ 库列表里
  //    点一个**损坏**的 B.cyrm(解码拒绝)→ 不重新打开任何东西,直接 Ctrl+S。旧实现里
  //    `app.raw` 在**解码之前**就被赋成了 B 的字节,于是:① 原文备份写的是 `A.v3.bak`
  //    (名字取自 `app.name`),**内容是 B 的字节**;② `A.cyrm` 被写成 v4 ⇒ **A 的 v3 原文消失**。
  await Editor.openMap('A.cyrm');
  eq([Editor.app.name, Editor.app.sourceFormat], ['A.cyrm', 'v3'],
     '⑰a 前提:A 打开成功且是 v3 文本(sourceFormat = v3 是"要写原文备份"的判据)');
  eq(Array.from(Editor.app.raw), Array.from(aBytes17),
     '⑰a 前提:`app.raw` = A 在磁盘上的原文(`# cyrm-v3…`)');
  let openBThrew17 = false;
  await Editor.openMap('B.cyrm').then(function () { return null; },
                                      function () { openBThrew17 = true; return null; });
  ok(openBThrew17,
     '⑰a 前提:B **真的**打不开(截断的 .cyrm ⇒ `Io.decodeMap` 拒绝;不拒绝的话下面几条无从谈起)');
  eq(Editor.app.name, 'A.cyrm', '★ 打开失败**不改** `app.name`(屏幕上那张图没动过)');
  eq(Editor.app.sourceFormat, 'v3', '★ 同上:`sourceFormat`(要写备份的判据也不许被挪)');
  eq(Editor.app.map && Editor.app.map.name, 'A',
     '★ 同上:`app.map` 仍是 A 那张(`decodeMap` 返回的 name 是空串,由 `mapFromBytes` 补文件名)');
  ok(Editor.app.raw && Array.from(Editor.app.raw)[0] === 35 &&
     Array.from(Editor.app.raw)[1] === 32,
     '★★★ `app.raw` **仍是 A 的字节**(首字节 35,32 = "# ";旧实现这里是 B 的 ' +
     '67,89,82,77,4,0 —— 而 `app.map`/`app.name` 全还是 A ⇒ 一个字段与它描述的文件错位)');
  // 同一根因的另一半:`offerDraft` 那道字节闸("草稿与磁盘上那份逐字节相同 ⇒ 不必问")。
  // 比错文件之后它等于不存在:一次普通的打开失败就换来一次**假**的恢复提示。
  Editor.app.db = {
    transaction: function () {
      return { objectStore: function () {
        return { get: function () {
          const rq = { result: draftRec17, onsuccess: null, onerror: null };
          realTimer17(function () { if (rq.onsuccess) rq.onsuccess({ target: rq }); }, 0);
          return rq;
        } };
      } };
    },
  };
  asked17 = 0;
  eq(await Editor.offerDraft(), false,
     '★★★ 草稿与**当前这张图在磁盘上的字节**逐字节相同 ⇒ 不恢复(那道字节闸真的在比 A)');
  eq(asked17, 0,
     '★★★ 而且一次确认框都没弹 —— 旧实现 `app.raw` 是 B 的字节,比出"不同"就弹一次' +
     '**假**的恢复提示(实得 ' + asked17 + ' 次)');
  // ── 真保存:备份里必须是 A 的字节 ──
  globalThis.confirm = function () { asked17++; return true; };
  Editor.app.db = saved17.db;
  asked17 = 0;
  puts17.length = 0;
  // ★ 这里**不断言**"又问了一次确认"(那是会话级的,前面的分片早就确认过了)⇒ 要钉的是**备份那半边**。
  await Editor.saveCurrent(false);
  eq(puts17.length, 2, '⑰a 前提:一条备份 + 一条真保存(实得 ' + puts17.length + ' 条)');
  const bakPut17 = puts17.length === 2 ? puts17[0] : null;
  const savePut17 = puts17.length === 2 ? puts17[1] : null;
  ok(!!bakPut17 && bakPut17.url.indexOf('.v3.bak') >= 0 &&
     bakPut17.url.indexOf('/api/map?p=' + Editor.v3BackupName('A.cyrm')) >= 0,
     '★ 第一条 PUT 是 A 的原文备份,**名字取自 A**(实得 "' +
     (bakPut17 ? bakPut17.url : '(没有请求)') + '")');
  const bakBytes17 = bakPut17 && bakPut17.init && bakPut17.init.body
    ? Array.from(new Uint8Array(await bakPut17.init.body.arrayBuffer())) : null;
  eq(bakBytes17, Array.from(aBytes17),
     '★★★ A 的备份里是 **A 的**原文(旧实现写进去的是 B 的 67,89,82,77,4,0 —— ' +
     '而 A.cyrm 紧接着被写成 v4 ⇒ **A 的 v3 原文就此消失**,磁盘上那份备份还是' +
     '"看着对"的;实得 ' + JSON.stringify(bakBytes17 && bakBytes17.slice(0, 6)) + ')');
  ok(!!savePut17 && savePut17.url.indexOf('/api/map?p=A.cyrm') >= 0,
     '★ 第二条才是 A 自己的真保存(实得 "' + (savePut17 ? savePut17.url : '(没有请求)') + '")');

  // ════ ⑰b 缩小地图之后**装不下**的选区必须清掉 ════
  // ★★ `invalidateAll` **不清选区**(只有 `setMap` 清),而 `idxOf` 对越界坐标**取模** ——
  //    留下来的那个框有两个症状:① 框画在**图外**;② 凡是消费选区的工具都把落在图外的格
  //    **折回图里**落笔:镜像线不在框画的那条线上,接缝附近凭空多出一片改动。
  // ★ 场景:16×16 格的图在右边缘框 {x:40,w:8}(装得下),再缩成 8×16 格(32 子格宽)⇒ 装不下了。
  const m17 = Editor.createEmptyMap('s17', 16, 16);
  const arr17 = m17.layers[Core.LAYER_SCENE].desc;
  for (let y = 0; y < m17.subRows; y++) {
    for (let x = 0; x < m17.subCols; x++) arr17[y * m17.subCols + x] = Core.neutralDesc(1 + (x % 8));
  }
  Editor.app.map = m17;
  Editor.app.name = 's17.cyrm';
  Editor.app.sourceFormat = 'v4';
  sel17 = { x: 40, y: 0, w: 8, h: 4 };
  eq([m17.subCols, m17.subRows], [64, 64], '⑰b 前提:图是 16×16 格 = 64×64 子格');
  ok(sel17.x + sel17.w <= m17.subCols, '⑰b 前提:这个框**此刻装得下**(48 ≤ 64)');
  el17('size-w').value = '8';
  el17('size-h').value = '16';
  el17('btn-resize').click();                 // ← 走**生产**的点击处理器
  eq([Core.cellsWOf(Editor.app.map), Core.cellsHOf(Editor.app.map)], [8, 16],
     '⑰b 前提:图真的缩成了 8×16 格(32 子格宽)');
  eq(sel17, null,
     '★★★ 装不下的选区被**清掉**了(旧实现把 {x:40,y:0,w:8,h:4} 原样留着 ⇒ 下面那条镜像' +
     '会把 40..47 折成图内的格落笔;实得 ' + JSON.stringify(sel17) + ')');
  ok(status17.indexOf('选区超出新尺寸') >= 0,
     '★★ 而且**说得出理由**(清掉是看得见的,但"为什么"要写在状态栏上;实得 "' + status17 + '")');
  const before17 = Array.from(arr17);
  status17 = '';
  eq(Editor.mirrorSelection('h'), null,
     '★★★ 没有选区 ⇒ 镜像什么都不做(旧实现这里会返回一条差量并**静默改掉**折回图内那批格)');
  ok(status17.indexOf('先框选一块') >= 0,
     '★ 说了"先框选一块"(实得 "' + status17 + '")');
  eq(Array.from(arr17), before17,
     '★★★ 一格都没改 —— 这就是"镜像线不在框画的那条线上"那件事的**代价**');
  // ── ⑰b② 撤销/重做那条**whole** 支路同样要判(它走的是 `afterStateChange`):先撤销,再框一块装不下的选区,再重做。
  await Editor.doUndo();
  eq([Core.cellsWOf(Editor.app.map), Core.cellsHOf(Editor.app.map)], [16, 16],
     '⑰b② 前提:撤销把尺寸退回 16×16');
  sel17 = { x: 40, y: 0, w: 8, h: 4 };        // 又框了一块(这次是在 16×16 的图上)
  status17 = '';
  await Editor.doRedo();                      // ← 重做那次缩小:框又装不下了
  eq([Core.cellsWOf(Editor.app.map), Core.cellsHOf(Editor.app.map)], [8, 16],
     '⑰b② 前提:重做又把图缩成 8×16');
  eq(sel17, null,
     '★★★ 撤销/重做那条 whole 支路也清(只修 `applySize` 的实现在这里会红 —— ' +
     '而用户从改尺寸起就一路按 Ctrl+Z / Ctrl+Y 是很普通的操作)');
  ok(status17.indexOf('选区超出新尺寸') >= 0, '★ 同样说了理由(实得 "' + status17 + '")');
  // ── 反向对照:装得下的选区**不许**被清(否则"别无条件重置选区"那条纪律就废了)──
  sel17 = { x: 0, y: 0, w: 8, h: 4 };
  eq(Editor.dropStaleSelection(), false,
     '★ (反向对照)装得下的选区原样留着(清它是"每次改尺寸都把用户的框扔了")');
  eq(sel17, { x: 0, y: 0, w: 8, h: 4 }, '★ 而且没被改过');

})();
