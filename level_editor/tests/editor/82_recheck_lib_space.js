'use strict';
// ⑰c + ⑰d:库列表里不许出现原文备份 / 备份**不是**保存目标;以及一个卡不住的**空格修饰键**。
// ★★ 两条都是"看起来没事、其实静默出错":库里混进一行备份 ⇒ 开机就把**退路**当地图打开;
//    空格 keyup 的早退排在**清位之前** ⇒ 此后**每一次左键拖拽都变平移**。
// ★ 判据取**副作用**(库列表里有没有那一行 / 这一次拖拽起的是平移还是落笔),而不是"没抛"。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const stubs = require('./lib/stubs_recheck.js');
stubs.getStubs17();

module.exports = (async function () {
  try {

    Editor.buildPanels();
    Editor.installInteraction();

    // ════ ⑰c 库列表里不许出现原文备份 ════
    // ★★ 服务器的 `listMaps` 照旧列出 `*.v3.bak`(那是它的既有语义),但客户端不能把它们
    //    当地图:`openFromUrl` 的兜底是"打开列表**第一行**" ⇒ 列表里混进备份之后,
    //    开机就可能**直接打开一份退路**。
    el17('lib-list').children.length = 0;
    await Editor.refreshLibrary();
    const rows17 = el17('lib-list').children.map(function (li) { return li.dataset.name; });
    eq(rows17, ['A.cyrm', 'C.cyrm'],
       '★★★ 两句 `*.v3.bak` 都被滤掉了(实得 ' + JSON.stringify(rows17) + ')');
    calls17.length = 0;
    // ★★ ② 空启动:不再自动打开库列表第一行 —— 开机替他开一张图是"替他做决定",而用户要真的文件动作。
    Editor.app.map = null; Editor.app.name = null;
    Editor.hideEmptyHint();
    await Editor.openFromUrl();
    eq(Editor.app.name, null,
       '★★★ 空启动**不再**自动打开库列表第一行(实得 app.name = ' + JSON.stringify(Editor.app.name) + ')');
    eq(Editor.emptyHintShown(), true,
       '★★ 而且显示空状态 #empty-hint(否则用户面对一片黑画布,不知道下一步做什么)');
    // ?p= 仍打开指定图(收藏夹/命令行那条入口没被这次改动砍掉)
    globalThis.location.search = '?p=A.cyrm';
    await Editor.openFromUrl();
    eq(Editor.app.name, 'A.cyrm',
       '★★ ?p= 直开那条路照旧可用(实得 ' + JSON.stringify(Editor.app.name) + ')');
    eq(Editor.emptyHintShown(), false, '★ 打开成功之后空状态要收起');
    // ── ⑰c② 备份**不是**保存目标(`?p=` 直开那条路列表过滤管不到)──
    Editor.app.name = 'A_e3c115d7.v3.bak';
    Editor.app.map = Editor.createEmptyMap('A', 2, 2);
    Editor.app.sourceFormat = 'v4';
    puts17.length = 0;
    status17 = '';
    await Editor.saveCurrent(false);            // Ctrl+S
    eq(puts17.length, 0,
       '★★★ 就地保存一份**备份**被拒了:一个 PUT 都没发(旧实现把 v4 写进 `A.v3.bak`, ' +
       '名字还漂成 `Av3bak.v3.bak` —— 退路就此换成 v4,而不报错)');
    ok(status17.indexOf('.v3.bak') >= 0 && status17.indexOf('另存为') >= 0,
       '★★ 拒绝要**说得出理由**(点名那个文件 + 指条明路;实得 "' + status17 + '")');
    puts17.length = 0;
    await Editor.saveCurrent(true);             // 另存为照旧可用
    ok(puts17.length === 1 && puts17[0].url.indexOf('.v3.bak') < 0,
       '★★ 而「另存为」照旧写得出去(拒的只是"就地覆盖退路";实得 ' +
       JSON.stringify(puts17.map(function (p) { return p.url; })) + ')');

    // ════ ⑰d 一个卡不住的空格修饰键 ════
    // ★★ 原先 keyup 的早退("焦点在输入控件里 ⇒ 不拦")排在**清位之前**,于是这条极普通的
    //    手顺能把平移修饰键**永久卡住**:按住空格 → 还按着时点进一个输入框 → 松手(keyup 的
    //    target 是那个输入框 ⇒ 早退)⇒ `spaceDown` 仍是 true ⇒ 此后**每一次左键拖拽都变平移**。
    const press17 = function (type, key, target) {
      const ev = { key: key, target: target, ctrl: false, meta: false, shift: false,
                   altKey: false, defaultPrevented: false };
      ev.preventDefault = function () { ev.defaultPrevented = true; };
      handlers17[type](ev);
      return ev;
    };
    const BODY17 = { tagName: 'BODY' }, INPUT17 = { tagName: 'INPUT' };
    press17('keydown', ' ', BODY17);            // 按住空格(焦点在 body)
    const evUpIn17 = press17('keyup', ' ', INPUT17);   // ← 还按着时点进输入框,然后松手
    ok(evUpIn17.defaultPrevented === false,
       '★★ 焦点在输入框里时 keyup **不** preventDefault(空格照旧是一个字符,' +
       '浏览器那半边的判据没被这次改动碰坏)');
    calls17.length = 0;
    Editor.app.canvas.onpointerdown({ button: 0, altKey: false, clientX: 10, clientY: 20, pointerId: 1 });
    ok(!Editor.app.st.panning,
       '★★★ 而 `spaceDown` **已经被清掉**了:这一拖不是平移(旧实现这里 panning 是被设上的 —— ' +
       '用户以为自己早松手了,而每一次拖拽都在平移画布)');
    Editor.app.st.stroke = null;                // 那一下起的是普通笔画,清掉
    Editor.app.canvas.onpointerup({ button: 0, clientX: 10, clientY: 20 });
    // ── 反向对照:焦点在 body 上时 keyup 照旧 preventDefault(那一半不许被这次改动碰坏)──
    press17('keydown', ' ', BODY17);
    const evUpBody17 = press17('keyup', ' ', BODY17);
    ok(evUpBody17.defaultPrevented === true,
       '★ (对照)焦点在 body 上时 keyup 照旧 preventDefault(浏览器会把空格当"按下当前' +
       '聚焦的按钮")');

    // ════ ① 库的真动作:重命名 / 删除 / 本地目录后端 ════
    // 改名:走 POST /api/map/rename;成功后 app.name 与 map.name 一起换(状态栏「名字 · 文件」才对得上)
    Editor.app.map = Editor.createEmptyMap('A', 2, 2);
    Editor.app.name = 'A.cyrm';
    Editor.app.sourceFormat = 'v4';
    globalThis.renameLog17.length = 0;
    globalThis.fileOpsAsk = function () { return Promise.resolve({ name: 'A2' }); };
    try { await Editor.renameMapFlow(); } finally { globalThis.fileOpsAsk = null; }
    eq(globalThis.renameLog17.length, 1, '★ 重命名发了一条 POST rename(实得 ' + renameLog17.length + ' 条)');
    ok(globalThis.renameLog17.length === 1 && renameLog17[0].from === 'A.cyrm' &&
       renameLog17[0].to === 'A2.cyrm',
       '★★ from/to 都是**真文件名**(裸名补 .cyrm;实得 ' + JSON.stringify(renameLog17) + ')');
    ok(globalThis.renameLog17.length === 1 && renameLog17[0].init &&
       renameLog17[0].init.headers && renameLog17[0].init.headers['Content-Type'] === 'application/json',
       '★★ 写端点必须带 Content-Type: application/json(少了它服务器就是 415)');
    eq(Editor.app.name, 'A2.cyrm', '★ 改名成功后 app.name 跟着换(实得 ' + Editor.app.name + ')');
    eq(Editor.app.map && Editor.app.map.name, 'A2', '★ 内存里这张图的 name 也跟着换');
    ok(status17.indexOf('已改名') >= 0, '★ 改名成功要说出来(实得 "' + status17 + '")');
    // 409 不覆盖:目标已存在是**拒绝**,而且错误里要带服务端原因(只抛 HTTP 409 看不出是被谁占了)
    globalThis.renameMode17 = '409';
    globalThis.fileOpsAsk = function () { return Promise.resolve({ name: 'A' }); };
    let renameErr17 = null;
    try { await Editor.renameMapFlow().catch(function (e) { renameErr17 = e; }); }
    finally { globalThis.fileOpsAsk = null; globalThis.renameMode17 = 'ok'; }
    ok(renameErr17 && errText(renameErr17).indexOf('409') >= 0 &&
       errText(renameErr17).indexOf('目标已存在') >= 0,
       '★★★ 目标已存在 ⇒ 抛出**带服务端原因**的错(实得 "' +
       (renameErr17 ? errText(renameErr17) : '(没有拒绝)') + '")');

    // 删除:confirm 之后 DELETE ?p=;删的是当前图 → 先 closeMap()(否则下一次 Ctrl+S 写回一个已删文件)
    Editor.app.map = Editor.createEmptyMap('A2', 2, 2);
    Editor.app.name = 'A2.cyrm';
    globalThis.confirm = function () { return true; };
    globalThis.deleteLog17.length = 0;
    await Editor.deleteMapFlow();
    eq(globalThis.deleteLog17.length, 1, '★ 删除发了一条 DELETE(实得 ' + deleteLog17.length + ' 条)');
    ok(globalThis.deleteLog17.length === 1 && deleteLog17[0].name === 'A2.cyrm',
       '★★ DELETE 带的是文件名(实得 ' + JSON.stringify(deleteLog17) + ')');
    eq(Editor.app.map, null, '★★ 删掉当前图之后画布回到空状态(app.map = null)');
    eq(Editor.app.name, null, '★★ app.name 也清了(留着它,下一次 Ctrl+S 会写回一个已删的文件)');
    eq(Editor.emptyHintShown(), true, '★ 而且显示空状态');
    ok(status17.indexOf('已删除') >= 0, '★ 删除成功要说出来(实得 "' + status17 + '")');
    // 取消删除:confirm 说不要 ⇒ 一个请求都不发
    Editor.app.map = Editor.createEmptyMap('A2', 2, 2);
    Editor.app.name = 'A2.cyrm';
    globalThis.confirm = function () { return false; };
    globalThis.deleteLog17.length = 0;
    await Editor.deleteMapFlow();
    eq(globalThis.deleteLog17.length, 0, '★★ 用户取消 ⇒ 一个 DELETE 都不发');
    globalThis.confirm = function () { globalThis.asked17++; return false; };

    // ── 本地目录后端(File System Access):列表 / 读 / 写 / 改名 / 删除全换到目录句柄上 ──
    // ★ 断言落到**目录句柄上的副作用**:只换列表不换写盘的实现在"写到这里"那条红。
    const dirFiles17 = new Map();
    dirFiles17.set('local1.cyrm', aBytes17);
    const fakeDir17 = {
      name: 'localtest',
      entries: function () {
        const names = Array.from(dirFiles17.keys());
        let i = 0;
        return { next: function () {
          if (i >= names.length) return Promise.resolve({ done: true });
          const n = names[i++];
          return Promise.resolve({ done: false, value: [n, {
            kind: 'file',
            getFile: function () {
              return Promise.resolve({ size: dirFiles17.get(n).length, lastModified: 1 });
            },
          }] });
        } };
      },
      getFileHandle: function (name, opts) {
        if (!dirFiles17.has(name) && !(opts && opts.create)) {
          return Promise.reject(Object.assign(new Error('NotFound'), { name: 'NotFoundError' }));
        }
        return Promise.resolve({
          getFile: function () {
            const b = dirFiles17.get(name);
            return Promise.resolve({ size: b ? b.length : 0, lastModified: 1,
              arrayBuffer: function () {
                return Promise.resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
              } });
          },
          createWritable: function () {
            return Promise.resolve({
              write: function (bytes) { dirFiles17.set(name, new Uint8Array(bytes)); return Promise.resolve(); },
              close: function () { return Promise.resolve(); },
            });
          },
        });
      },
      removeEntry: function (name) { dirFiles17.delete(name); return Promise.resolve(); },
    };
    Editor.setFileOpsBackend(Editor.FILEOPS_BACKEND_DIR, fakeDir17);
    eq(Editor.fileOpsBackendKind(), 'dir', '★ 切到本地目录后端(同一时刻只有一个后端)');
    ok(Editor.fileOpsBackendLabel() === '本地目录:localtest',
       '★★ #lib-backend 那一行要说出当前库是哪:实得 ' + JSON.stringify(Editor.fileOpsBackendLabel()));
    el17('lib-list').children.length = 0;
    await Editor.refreshLibrary();
    const dirRows17 = el17('lib-list').children.map(function (li) { return li.dataset.name; });
    eq(dirRows17, ['local1.cyrm'], '★★ 库列表改成从**目录**列(实得 ' + JSON.stringify(dirRows17) + ')');
    await Editor.putMapBytes('local2.cyrm', new Uint8Array([1, 2, 3]));
    ok(dirFiles17.has('local2.cyrm') && dirFiles17.get('local2.cyrm').length === 3,
       '★★★ 保存**写到目录句柄上**(只换列表不换写盘的实现在这里红:写的还是服务器)');
    const readBack17 = await Editor.readMapBytes('local2.cyrm');
    eq(Array.from(readBack17), [1, 2, 3], '★ 读也走目录句柄(写进去的字节读得回来)');
    await Editor.renameMapFile('local1.cyrm', 'local3.cyrm');
    ok(dirFiles17.has('local3.cyrm') && !dirFiles17.has('local1.cyrm'),
       '★★ 目录里的改名 = 读旧 → 写新 → 删旧(FSA 没有 rename)');
    await Editor.deleteMapFile('local3.cyrm');
    ok(!dirFiles17.has('local3.cyrm'), '★ 目录里的删除真删掉了');
    await Editor.useServerBackendFlow();
    eq(Editor.fileOpsBackendKind(), 'server', '★ 能切回服务器库(只给一条路进去、不给路出来 = 用户被锁在目录里)');

    eq(errs17.length, 0,
       '★★ 整个相位里**一条错误都没进过 sink**(替身少一个方法就会变成一条被吞掉的异常;实得 ' +
       JSON.stringify(errs17) + ')');

  } finally {
    stubs.restoreStubs17();
  }
})();
