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
    ok(el17('lib-list').textContent.indexOf('.v3.bak') < 0,
       '★ 连兜底文案里也不出现备份名(列表为空时那句也一样)');
    calls17.length = 0;
    await Editor.openFromUrl();                 // location.search 为空 ⇒ 走"打开第一行"那条兜底
    eq(Editor.app.name, 'A.cyrm',
       '★★★ 兜底打开的是**第一张真地图**(旧实现列表里第一行就可能是一份 `.v3.bak` ⇒ ' +
       '开机直接把退路当地图打开)');
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

    eq(errs17.length, 0,
       '★★ 整个相位里**一条错误都没进过 sink**(替身少一个方法就会变成一条被吞掉的异常;实得 ' +
       JSON.stringify(errs17) + ')');

  } finally {
    stubs.restoreStubs17();
  }
})();
