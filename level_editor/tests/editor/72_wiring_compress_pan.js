'use strict';
// ⑯c + ⑯d:压缩开关(规格 §3.5 的那条退路)与空格拖拽平移(规格 §4.8)。
// ★★ 为什么要这一相:规格要求"造好了却没人能碰到" —— ③ 两处 encode 都写死 `compress:true`
//    ⇒ 那条"完整可用的退路"(compression=0)不可达(而浏览器 deflate 与 Godot
//    COMPRESSION_DEFLATE 的兼容性至今**没实测过**,这条退路是唯一的兜底);
//    ④ `pointerdown` 只认中键与 Alt ⇒ 空格拖拽不存在。
// ★ 判据一律取**副作用**(发出去的第 6 个字节是几 / panBy 被调了没),而不是"没抛"。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const stubs = require('./lib/stubs_wiring.js');
stubs.getStubs16();

module.exports = (async function () {
  try {

    Editor.app.map = Editor.createEmptyMap('p16', 4, 3);
    Editor.installInteraction();
    Editor.buildPanels();
    el16('opt-compress').checked = true;

    // ════ ⑯c 压缩开关 ════
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
      globalThis.setTimeout = realTimer16;
    }
    eq(Editor.uiStateDefaults().compress, true, '★ 默认值 = 勾上(老存档没有这个字段时也走它)');
    el16('opt-compress').checked = true;
    Editor.app.uist = Editor.readUiState(ls16);
    Editor.applyUiState();
    eq(el16('opt-compress').checked, false,
       '★★★ applyUiState 把它按回界面(勾选框与状态一致)');
    Editor.app.uist = null;
    el16('opt-compress').checked = true;         // 还原成默认,别把状态漂到后面的断言里

    // ════ ⑯d 空格拖拽平移 ════
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
    stubs.restoreStubs16();
  }
})();
