'use strict';
// 草稿盘的写侧 —— 落一笔→防抖→落盘、flushDraft、
// 保存标干净、与"保存/换图/改名"赛跑的那次落盘、换图时两笔账一起归位。
// ★ 陷阱:`saveDraft` / `loadDraft` 写对且列在导出表上,照样可能是一个不存在的草稿盘(`DRAFT_DEBOUNCE_MS` 是死值)。
// ★ 替身(假 IndexedDB / 记账的假 setTimeout / 假 DOM)在 lib/stubs_draft.js。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
require('./lib/stubs_draft.js').getStubs15();

module.exports = (async function () {

  // ── 环境里没有 indexedDB ⇒ 草稿盘是 null(而不是抛)──
  delete globalThis.indexedDB;
  eq((typeof indexedDB === 'undefined'), true, '⑮b 前提:这个进程里本来就没有 indexedDB');
  eq(await Editor.openDraftStore(), null,
     '★★ 没有 indexedDB 时 openDraftStore 交回 null(**不抛**)—— 编辑器少了草稿盘照样要能开');

  // ── 装上假 indexedDB:草稿盘能开出来 ──
  // ★ 走的是真的升级回调(onupgradeneeded → 生产在那儿建 store 与 `savedAt` 索引)。
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

  // ── 接线之一:落一笔 → 防抖 → 草稿盘里出现记录 ──
  const map15 = Editor.createEmptyMap('draft_probe', 4, 4);
  Editor.app.map = map15;
  Editor.app.name = 'draft_probe.cyrm';
  Editor.app.sourceFormat = 'v4';
  Editor.spawnAt('enemy', 0);                     // ← 生产里真实的一笔(与 ⑭c 同一个入口)
  eq(Editor.app.map.enemies.length, 1, '⑮b 前提:那一笔真的落进了地图');
  eq(pending15().length, 1, '★★★ 落一笔就排了一次草稿落盘(实得 ' + pending15().length + ' 次)');
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
     '★★ #st-save 由草稿盘接管(不然它与 Task 8 的「未保存/已保存」两个写入者互打;实得 "' +
     el15('st-save').textContent + '")');
  const back15 = rec15 ? await globalThis.Io.decodeMap(rec15.bytes) : null;
  ok(!!back15, '★ 存进去的字节能**解回同一张图**(恢复那条路走的就是它)');
  if (back15) {
    eq(back15.enemies.length, Editor.app.map.enemies.length, '★ 解回来的张数与原图一致');
  }

  // ── 离开页面前那一刀(flushDraft):不等防抖,但只在真脏时补 ──
  Editor.markDirty();                             // 又画了一笔 ⇒ 定时器在飞
  eq(pending15().length, 1, '⑮b 前提:又排上一次防抖');
  await Editor.flushDraft();                      // flushDraft 交回落盘那条链的 promise
  const rec15b = tab15.draft.get('draft_probe');
  eq(pending15().length, 0, '★★ flushDraft 把那个还在飞的防抖**撤了**(不留两个写入者)');
  eq(rec15b && rec15b.dirty, true, '★ 补的这一份仍是脏的(屏幕上那份确实还没进真文件)');

  // ── Ctrl+S 成功 ⇒ 那条草稿标干净;而"保存前遗留的那个定时器"到点不许把它写脏 ──
  globalThis.fetch = function (url) {
    const u = String(url);
    if (u.indexOf('/api/maps') === 0) {
      return Promise.resolve({ ok: true, status: 200,
                               json: function () { return Promise.resolve({ maps: [] }); } });
    }
    return Promise.resolve({ ok: true, status: 200,
                             json: function () { return Promise.resolve({ name: 'draft_probe.cyrm', size: 12 }); } });
  };
  Editor.markDirty();                             // ← 这一笔的防抖定时器留着不跑(模拟"保存先到")
  const stale15 = pending15()[0];
  await Editor.saveCurrent(false);                // 真走 saveCurrent(写盘出口 + 标干净)
  const recD15 = function () { return tab15.draft.get('draft_probe') || null; };
  ok(await until15(function () { return !!recD15() && recD15().dirty === false; }),
     '★★ 保存成功后草稿那条**标干净**(下次打开不该再问一次;等不到 = 标干净那条链断了)');
  eq(el15('st-save').textContent, '已保存',
     '★★ (交接点)存盘之后 #st-save 交回 Task 8 那对文案 —— 磁盘上那份就是屏幕上这份了,' +
     '再显示「已自动保存 12:34」是**误导**(实得 "' + el15('st-save').textContent + '")');
  if (stale15) await fire15(stale15);             // 保存之前排的那个定时器现在到点
  eq(recD15() && recD15().dirty, false,
     '★★★ 保存前遗留的那个防抖定时器到点后**不会**把干净的草稿重新写脏' +
     '(否则下次打开弹一次**假**的恢复提示 —— 那是这层最容易出的错,而且不报错)');

  // ── 与"保存"赛跑的那次落盘(不是先后,是同时)──
  // ★ 上一条钉的是"保存完了定时器才到点"(顺序)。这一条钉的是交错:一次草稿落盘
  //   已经开工(编码在飞),Ctrl+S 的收尾在这中间落地 —— 那次落盘落地时必须放弃。
  await Editor.markDraftSaved();                       // 先把草稿标干净(起跑状态)
  await until15(function () { return recD15() && recD15().dirty === false; });
  const racing15 = Editor.saveDraft(true);             // 这次落盘不等它(它在飞)
  const savedMark15 = Editor.markDraftSaved();         // 保存的收尾插进来(同步推 rev)
  await racing15;
  await savedMark15;
  eq(recD15() && recD15().dirty, false,
     '★★★ 与"保存"赛跑的那次落盘落地之后,草稿**仍然是干净的**' +
     '(编码完成后再看一眼 rev:这一版已经进真文件了 ⇒ 这次落盘必须放弃)');

  // ── 与"换图/改名"赛跑的那次落盘(一次静默的内容掉包)──
  // ★ 症状链:编码在飞时用户点了另一张图 —— `openMap` 把 `app.map`/`app.name` 换成 B,而编码
  //   交回的是 A 的字节 ⇒ 记录写成 `{key:'B', bytes:<A 的地形>}`;下次打开 B 弹一次恢复,
  //   用户按下它 ⇒ 一次 Ctrl+S 就把 A 的地形写进 maps/B.cyrm。
  // ★★ 两个独立的一半:① 记录的两半(它是谁 / 它是什么内容)必须在同一个瞬间取;② 编码期间换过图 ⇒ 整笔放弃。
  const savedMap15c = Editor.app.map, savedName15c = Editor.app.name;
  const savedFmt15c = Editor.app.sourceFormat;
  try {
    // ── 编码期间换图 ──
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

    // ── 编码期间改名(app.map 对象没换)──
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
    // ★ 借用了"当前图"这个全局状态 ⇒ 用完必须还回下一相需要的那张。
    Editor.app.map = savedMap15c; Editor.app.name = savedName15c;
    Editor.app.sourceFormat = savedFmt15c;
  }
  await Editor.flushDraft();                      // 把这一相留下的防抖定时器结清(别留给 ⑥)
  tab15.draft.delete('switch_a');
  tab15.draft.delete('ren_a');

  // ── 打开一张图 ⇒ 那两笔账一起归位 ──
  // ★ 症状一:`lastAutoSaveAt` 是上一张图那一局的时刻,换图之后状态栏那一格仍写着「已自动保存 12:34」。
  // ★ 症状二:不推 `draftSavedRev` 的话,上一张图留下的防抖定时器到点会给新图写一条 `dirty:true` 的草稿。
  Editor.app.map = Editor.createEmptyMap('minor1_a', 4, 4);
  Editor.app.name = 'minor1_a.cyrm'; Editor.app.sourceFormat = 'v4';
  Editor.markDirty();
  await Editor.flushDraft();
  ok(el15('st-save').textContent.indexOf('已自动保存') === 0,
     '⑤d 前提:状态栏那一格此刻是「已自动保存 …」(实得 "' + el15('st-save').textContent + '")');
  Editor.markDirty();                             // ★ 给 minor1_a 排一次防抖,留着不跑
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
  // ★ 同前:借用了"当前图"这个全局状态 ⇒ 用完还回下一相需要的那张。
  Editor.app.map = savedMap15c; Editor.app.name = savedName15c;
  Editor.app.sourceFormat = savedFmt15c;

})();
