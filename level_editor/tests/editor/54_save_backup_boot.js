'use strict';
// v3 源首次保存(确认框说出决定性事实 + 原文备份先落盘)以及启动链路 —— 打开的成败不决定面板建不建。
// ★ 收尾要还回替身(含"再装一遍 installInteraction"把真历史清空)。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const stubs = require('./lib/stubs_save.js');
stubs.getStubs14();

module.exports = (async function () {
  try {

    // ── v3 源首次保存 ──
    // ★ 为什么必须另立一条:确认框原先只说「不可逆」,而决定性的事实是"游戏今天读不了 v4"
    //   —— 用户以为只是换了个格式,实际是把一张能玩的图换成游戏打不开的。
    // ★★ 断言口径:①确认文案里那三件事都在;②备份真的从唯一那个写盘出口出去了、字节 == 打开时那份原文。
    await (async function () {
      const savedConfirm = globalThis.confirm;
      let asked = 0, askText = '';
      globalThis.confirm = function (t) { asked++; askText = String(t); return true; };
      try {
        const v3text = '# cyrm-v3\n001f001f\n001f001f\n';
        const orig = new TextEncoder().encode(v3text);
        Editor.app.map = Editor.createEmptyMap('demo_v3src', 4, 4);
        Editor.app.name = 'demo_v3src.cyrm';
        Editor.app.sourceFormat = 'v3';              // ← 本次会话第一次转换保存
        Editor.app.raw = orig;                       // 磁盘上那份的原文(openMap 留下的)
        putLog14.length = 0;
        await Editor.saveCurrent(false);
        eq(asked, 1, '⑭d2 前提:首次转换保存**问了一次**(实得 ' + asked + ' 次)');
        // ★ 三件事一件都不能少:转成 v4 二进制 / 不可逆 / 游戏现在读不了 v4
        ok(askText.indexOf('v4 二进制') >= 0 && askText.indexOf('不可逆') >= 0,
           '★★ 确认框说了"保存会把它转成 v4 二进制、不可逆"(实得 ' + JSON.stringify(askText) + ')');
        ok(askText.indexOf('读不了') >= 0 && askText.indexOf('map_format.gd') >= 0,
           '★★★ 确认框说了**决定性的那件事**:游戏现在读不了 v4,要等期 E 迁移 map_format.gd' +
           '(旧文案只说「不可逆」—— 用户不知道自己换来的是一张游戏打不开的图;实得 ' +
           JSON.stringify(askText) + ')');
        // ★ 文案里那个名字必须与下面真写出去的那个同源(两处各写一份字面量 = "说的与做的不是一回事")。
        ok(askText.indexOf(Editor.v3BackupName('demo_v3src.cyrm')) >= 0,
           '★★ 确认框**点名**了备份文件(用户得知道退路落在哪个名字上;实得 ' +
           JSON.stringify(askText) + ')');
        // 两条 PUT:备份在前、真保存在后,走的是同一个出口
        eq(putLog14.length, 2,
           '★★★ 首次转换保存 = **两条** PUT(原文备份 + 真保存;实得 ' + putLog14.length + ' 条)');
        const b = putLog14.length === 2 ? putLog14[0] : null;
        const s = putLog14.length === 2 ? putLog14[1] : null;
        ok(!!b && b.url.indexOf('/api/map?p=' + Editor.v3BackupName('demo_v3src.cyrm')) >= 0,
           '★★★ 第一条 PUT 就是**原文备份**,名字是确认框**点名过**的那一个' +
           '(`<基名>_<哈希>.v3.bak`;实得 "' + (b ? b.url : '(没有请求)') + '")');
        ok(!!s && s.url.indexOf('/api/map?p=demo_v3src.cyrm') >= 0,
           '★★★ 第二条 PUT 才是真保存(实得 "' + (s ? s.url : '(没有请求)') + '")');
        ok(!!b && !!b.init && b.init.method === 'PUT' && !!b.init.body,
           '★ 备份走的也是那个唯一的 PUT 出口(带上了 body)');
        const bBytes = b && b.init && b.init.body
          ? Array.from(new Uint8Array(await b.init.body.arrayBuffer())) : null;
        eq(bBytes, Array.from(orig),
           '★★★ 备份里是**原文那些字节**(逐字节比;不是编码后的 v4 —— 退路必须是原文)');
        // ③ 第二次保存同一个文件:确认框不再问,备份也不再写 —— 但理由是"这个文件
        //    本会话已经备份过了"(`v3BackedUp` 是逐文件的表)。
        Editor.app.sourceFormat = 'v3';              // ★ 刻意退回 v3:证明门是那张表、不是源格式
        putLog14.length = 0;
        await Editor.saveCurrent(false);
        eq(asked, 1, '★★ 第二次保存不再问(问的次数仍是 ' + asked + ')');
        eq(putLog14.length, 1,
           '★★★ 第二次保存**只有一条** PUT —— 备份不重写(否则每存一次都在 maps/ 里多一份;实得 ' +
           putLog14.length + ' 条)');
        ok(putLog14.length === 1 && putLog14[0].url.indexOf('.v3.bak') < 0,
           '★ 那一条是真保存,不是备份(实得 "' +
           (putLog14.length ? putLog14[0].url : '(没有请求)') + '")');

        // ── 逐文件备份:同一会话里保存第二张 v3 图,必须有它自己的一份 ──
        // ★ 为什么必须另立一条:上一轮备份与确认框共用同一个会话级标记(`v3Confirmed`)
        //   ⇒ 同一会话里保存第二张 v3 图时两半都不发生:既不问、也不备,那次单向转换是
        //   静默的 —— 用户手里那张能玩的 v3 图被换成一张游戏打不开的 v4,退路一份都没有。
        const v3textC = '# cyrm-v3\n001f001f\n001f001f\n001f001f\n';
        const origC = new TextEncoder().encode(v3textC);
        ok(Array.from(origC).join(',') !== Array.from(orig).join(','),
           '⑭d2c 前提:第二张图的原文与第一张**不同字节**(否则下面那条逐字节比什么都证明不了)');
        Editor.app.map = Editor.createEmptyMap('demo_v3src2', 4, 4);
        Editor.app.name = 'demo_v3src2.cyrm';
        Editor.app.sourceFormat = 'v3';              // ← 打开第二张 v3 图之后的状态
        Editor.app.raw = origC;                      // 第二张图在磁盘上的原文
        putLog14.length = 0;
        await Editor.saveCurrent(false);
        eq(asked, 1, '★★★ 第二张图**不再问**(确认仍是每会话一次;问的次数仍是 ' + asked + ')');
        eq(putLog14.length, 2,
           '★★★ 但第二张 v3 图**照样有自己的备份** = 两条 PUT(会话级门的实现在这里只有 1 条;' +
           '实得 ' + putLog14.length + ' 条)');
        const bC = putLog14.length === 2 ? putLog14[0] : null;
        const sC = putLog14.length === 2 ? putLog14[1] : null;
        ok(!!bC && bC.url.indexOf('/api/map?p=' + Editor.v3BackupName('demo_v3src2.cyrm')) >= 0,
           '★★★ 第二张图的备份落在**它自己的**备份名上(逐文件,不是共用第一张的名字;实得 "' +
           (bC ? bC.url : '(没有请求)') + '")');
        ok(!!sC && sC.url.indexOf('/api/map?p=demo_v3src2.cyrm') >= 0,
           '★★ 第二条才是第二张图的真保存(实得 "' + (sC ? sC.url : '(没有请求)') + '")');
        ok(Editor.v3BackupName('demo_v3src.cyrm') !== Editor.v3BackupName('demo_v3src2.cyrm'),
           '★★ 两张图的备份名是**两个**名字(一个恒定名会让上面两条"各自落到自己的名字上"' +
           '同时通过,而两份退路互相覆盖)');
        const bCBytes = bC && bC.init && bC.init.body
          ? Array.from(new Uint8Array(await bC.init.body.arrayBuffer())) : null;
        eq(bCBytes, Array.from(origC),
           '★★★ 第二张图的备份里是**它自己那份原文**(逐字节比;写成第一张的字节也会红)');
        // 同一张第二图再存一次:仍只有一条 —— 逐文件去重的另一半
        Editor.app.sourceFormat = 'v3';
        putLog14.length = 0;
        await Editor.saveCurrent(false);
        eq(putLog14.length, 1,
           '★★ 第二张图再存一次也只有**一条** PUT(每个文件只备一次;实得 ' + putLog14.length + ' 条)');
        ok(putLog14.length === 1 && putLog14[0].url.indexOf('.v3.bak') < 0,
           '★ 那一条同样是真保存,不是备份(实得 "' +
           (putLog14.length ? putLog14[0].url : '(没有请求)') + '")');
      } finally {
        globalThis.confirm = savedConfirm;
      }
    })();

    // ── 启动链路:打开的成败不决定面板建不建 ──
    // ★★ 陷阱:`loadAtlas → openFromUrl → buildPanels` 只有一个 `.catch`,`openFromUrl()` 一旦拒绝
    //    (`?p=` 陈旧/写错 → 404;`.cyrm` 解不开)整条链短路到 catch,`buildPanels()` 一行都没跑 ——
    //    工具条/图层行/调色板/出生点按钮一个监听都没装上,而且没有重建路径,屏幕上只有「启动失败:…」。
    // ★ 判据是真驱动(点一下按钮看副作用),不是"没抛":后者拦不住"buildPanels 跑了但按钮没接上"。
    Editor.app.map = null;                               // 打开失败后就是这状态
    Editor.app.tileDefs = globalThis.TILE_DEFS;
    mapGetMode14 = 'fail';                               // ?p=stale_name.cyrm → HTTP 404
    await Editor.bootLoad();
    ok(status14.indexOf('启动失败') >= 0,
       '⑭e 前提:这次打开**真的**失败了(#status-msg 里有「启动失败」;实得 "' + status14 + '")');
    ok(elOf14('palette').children.length > 0,
       '★★★ 打开失败之后调色板**仍然建出来了**(实得 ' + elOf14('palette').children.length +
       ' 个格子)—— 面板建在打开之后的话这里是 0');
    // ★ 先把工具挪开再点:42_boot_ui_state.js 已经把 st.tool 置成 'line' 了,直接点「直线」是**幂等**的 ——
    //   工具条根本没接线时这条会打印 "line → line" 而照样通过(实测)。挪开之后它才真的在判"点击生效"。
    Editor.app.st.tool = 'brush';
    const toolBefore = Editor.app.st.tool;
    toolBtns14.forEach(function (b) { if (b.dataset.tool === 'line') b.click(); });
    eq(Editor.app.st.tool, 'line',
       '★★★ 打开失败之后工具条按钮**仍然接上了**(点「直线」真换工具:' + toolBefore +
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
    // ★ 背景层:派生提示行与「只改辅码」那一行都要跟着调色板一起藏。
    const rows = { 'desc-hue': mkRow14(), 'desc-bri': mkRow14(), 'desc-sat': mkRow14(),
                   'desc-alp': mkRow14(), 'desc-only': mkRow14() };
    Object.keys(rows).forEach(function (id) { elOf14(id).parentNode = rows[id]; });
    Editor.app.r.layer = function () { return Core.LAYER_BG; };
    Editor.syncPanelForLayer();
    ok(elOf14('palette-hint').style.display === 'none',
       '★★ 切到背景层时**派生提示行**(「纹理 22 不进调色板…」)跟着 #palette 一起藏' +
       '(它是 palette 的派生行,留着就是浮在空面板底下;实得 "' +
       elOf14('palette-hint').style.display + '")');
    ok(rows['desc-only'].style.display === 'none',
       '★★ 「只改辅码」那一行也藏了(它管的正是那四个已经藏掉的档位;隐藏要落到**整行**' +
       '上 —— 它的 input 外面还包着一层 label;实得 "' + rows['desc-only'].style.display + '")');
    ok(rows['desc-hue'].style.display === 'none',
       '★ (对照)四个档位那一行照旧藏(没有为了修上面两条把它弄丢)');
    eq(elOf14('bg-color-row').style.display, '',
       '★ (对照)背景层自己的两个色槽是**显示**出来的');
    Editor.app.r.layer = function () { return Core.LAYER_SCENE; };
    Editor.syncPanelForLayer();
    eq(elOf14('palette-hint').style.display, '',
       '★ 切回纹理层时派生提示行要**回来**(藏了不还原 = 提示永久消失)');
    eq(rows['desc-only'].style.display, '',
       '★ 切回纹理层时「只改辅码」那一行也回来');

  } finally {
    stubs.restoreStubs14();
  }
})();
