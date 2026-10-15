'use strict';
// 闸 4 的读侧(崩溃槽位比主槽位新 ⇒ 问一次并恢复)、启动那一路的代价形状、
// 读失败要说话、以及闸 1 的清理(先数后读 + 两条失败路径都要说话)。
// ★ 收尾要还回替身。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const stubs = require('./lib/stubs_draft.js');
stubs.getStubs15();

module.exports = (async function () {
  try {

    // ── 闸 4 的读侧:下次打开时"崩溃槽位比主槽位新" ⇒ 问一次并恢复 ──
    // ★ 这一段要造好几份崩溃快照,故抽成一个小助手(每次都是新字节)。
    let asked15 = 0, answer15 = true;
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
    // ★★★ 恢复成功 ⇒ 这条快照要被消费掉:不删的话每一次打开都会再弹一次
    //     「上次异常退出」(一次偶发页面异常 = 一个永久的开机弹窗,用户可见)。
    eq(tab15.crash.has('crash'), false,
       '★★★ 恢复成功后崩溃槽位被**消费掉**(否则每一次打开都再问一遍;实得还在:' +
       tab15.crash.has('crash') + ')');
    // ★★ 点"不要"那一支:记录留着(那是没写盘的活),但要把"问过、不要"记上。
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
    // 反向:崩溃槽位比主草稿旧 ⇒ 不提示(否则每次打开都弹一次无关的框)
    await putCrash15(1);
    el15('status-msg').textContent = '';
    asked15 = 0;
    eq(await Editor.checkCrashSlot(), false, '★ 崩溃槽位比主草稿旧 ⇒ 不提示');
    eq(asked15, 0, '★★ 那一次连确认框都没弹(不是"问了但没恢复")');

    // ── 启动这一路的代价形状:点读 + 索引键游标,不是整库读 ──
    // ★ 原来这里为了求"主草稿最新那个 `savedAt`"把草稿盘整库读进来(每张草稿带着整张图),而它要的只是一个时刻。
    await putCrash15(Date.now() + 40000);
    idbReads15.getAll = 0; idbReads15.cursor = 0; idbReads15.keys = 0;
    eq(await Editor.checkCrashSlot(), true, '⑪b 前提:这一份崩溃快照比主草稿新 ⇒ 恢复');
    eq([idbReads15.getAll, idbReads15.cursor], [0, 0],
       '★★★ 崩溃槽位这一路**一条记录本体都没读**(整库读 ' + idbReads15.getAll +
       ' 次 / 值游标 ' + idbReads15.cursor + ' 次):它只需要"主草稿最新那个时刻"');
    ok(idbReads15.keys >= 1,
       '★★ 那个时刻是**索引键游标**给的(只回一个数,' + idbReads15.keys + ' 次)');

    // ── 读失败要说出来,不许折成"没有崩溃快照" ──
    // ★ 折成"没有"的实现在行为上与"真没有"完全一样(都是静默 return false)⇒ 最后一次抢救就这么消失了。
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

    // ── 闸 1 的清理:代价形状(先数后读)+ 两条失败路径都要说话 ──
    // ★★ 为什么单立一相:① 代价形状 —— 清理跑在每一次防抖落盘之后,而库满时每张草稿
    //    带着编码后的整张图;"没到上限时一条都不反序列化"是代价不是行为,只能靠读数钉住;
    //    ② 两条失败路径(读不到 / 删不掉)都要在状态栏说出话,且不拒绝这次写入。
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
    // ★★ 判据是"三种读一次都没有":生产里已经没有整库读那条路了,索引游标也是读,一并钉住。
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
    // ★★ 判据是"到了上限只读够淘汰那几条":66 条里只有刚写的 draft_probe 是脏的,而它按
    //    savedAt 排在最后 ⇒ 走 6 条(old0..old5)就凑够 6 条干净的 ⇒ 恰好 6 条。
    ok(idbReads15.getAll === 0 && idbReads15.keys === 0 && idbReads15.cursor === 6,
       '★★★ 到了上限走**索引值游标**逐条挑牺牲者:只物化 ' + idbReads15.cursor +
       ' 条记录本体(= 要丢的那 6 条,够数就停),整库读 0 次 / 键游标 0 次。' +
       '★ 旧实现是 `getAll` 把 66 条(每条带着整张图的字节)一次读进主线程 —— ' +
       '而"库满着"是**常态**(写入顶过上限、清一条又回到上限)');
    ok(el15('status-msg').textContent.indexOf('已清掉 6 条最老的') >= 0,
       '★ 清掉了就说一句(实得 "' + el15('status-msg').textContent + '")');
    // ★★ 淘汰口径的关键一格:库里有一条比所有干净记录都老的脏记录(没写盘的活)——
    //    `evictPlan` 的口径是"干净优先、同龄最老优先" ⇒ 牺牲者必须还是干净的那条,
    //    脏的那一条一个都不能动。走索引键序逐条挑的实现很容易在这里错成"谁最老丢谁"。
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
    // ★ olddirty 留在库里(它是"没写盘的活"那一档,下面那条删除失败路径正好还要它占位)。
    // 失败路径之一:读不到条数(真环境里是事务打不开 / 配额被拒)
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
    // 失败路径之二:删除事务失败(删不掉 ⇒ 上限同样没生效,同样必须说话)——
    // ★ 先把库顶到超过上限:上面那次失败没清成,而库正好是 60 条(`<= MAX_LIB` 走不到删除那一支)。
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
    stubs.restoreStubs15();
  }
})();
