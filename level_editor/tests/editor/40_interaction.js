'use strict';
// ★ 替身只有三个:window.addEventListener / document(两个入口,一律回空)/ 一个**记账**的
//   渲染器(app.r)。收尾还回四样,并断言**一条错误都没进过 sink**(处理器在 guard 里跑,
//   替身少一个方法就是一条被吞掉的异常)。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const Render = globalThis.Render;

module.exports = (async function () {

  const savedAdd = globalThis.addEventListener;
  const savedDoc = globalThis.document;
  const savedR = Editor.app.r, savedMap = Editor.app.map, savedCv = Editor.app.canvas;
  // ★★ `app.st` 必须存/还,而且必须是**字段快照**,不是只存引用:
  //    ① installInteraction() 会把 `app.st` **整个换成**一个新对象(它就是生产状态对象的
  //       来源;在那之前 `app.st` 根本不存在);② 本相位后续各步又在那**同一个对象**上
  //       **原地改字段**。⇒ 只还引用 = 那些改动跟着对象一起"还"回去(等于没还)。
  let savedSt = null, savedStFields = null;
  let sub = { X: 5, Y: 5 };                       // 命中坐标(默认恒落格 (1,1))
  const handlers = {};
  const errs = [];
  const calls = [];
  const selDragArgs = [];                         // ★ 记 setSelDrag 的**实参**(Esc 那条路要判 null)
  let sel = null;
  globalThis.addEventListener = function (type, fn) { handlers[type] = fn; };
  globalThis.document = { getElementById: function () { return null; },
                          querySelectorAll: function () { return []; } };
  Editor.setErrorSink(function (t) { errs.push(String(t)); });
  Editor.app.canvas = {
    setPointerCapture: function () {},
    getBoundingClientRect: function () { return { left: 0, top: 0 }; },
    addEventListener: function (type, fn) { this['on' + type] = fn; },
  };
  // ★ 记账型渲染器:只记"哪条路被调了" + 一份可读写的选区(地图仍是**真** core 的地图)。
  Editor.app.r = {
    selection: function () { return sel; },
    setSelection: function (s) {
      calls.push('setSelection');
      sel = s ? { x: s.x, y: s.y, w: s.w, h: s.h } : null;
    },
    setSelDrag: function (s, dx, dy) {
      calls.push('setSelDrag');
      selDragArgs.push(s ? { x: s.x, y: s.y, dx: dx, dy: dy } : null);
    },
    setPreview: function () { calls.push('setPreview'); },
    layer: function () { return Core.LAYER_SCENE; },
    setLayer: function () { calls.push('setLayer'); },
    screenToSub: function () { return { X: sub.X, Y: sub.Y }; },
    editCells: function () { calls.push('editCells'); },
    render: function () { calls.push('render'); },
    invalidateAll: function () { calls.push('invalidateAll'); return Promise.resolve(); },
  };
  try {
    Editor.installInteraction();
    savedSt = Editor.app.st;
    savedStFields = savedSt ? Object.assign({}, savedSt) : null;
    ok(!!savedSt && savedSt.tool === 'brush' && savedSt.brushSize === 1,
       '⑬ 前提:生产状态对象建出来了且是初始值(tool=brush / brushSize=1)');
    ok(typeof handlers.keydown === 'function' && typeof Editor.app.canvas.onpointerdown === 'function' &&
       typeof Editor.app.canvas.onpointerup === 'function',
       '⑬ 前提:installInteraction 在 window 上挂了 keydown、在画布上挂了 pointerdown/up' +
       '(keydown=' + typeof handlers.keydown + ')');

    // ── ⑬a 热键不许劫持输入框 ──
    const pressKey = function (k, target) {
      const ev = { key: k, target: target, ctrl: false, meta: false, shift: false, altKey: false };
      ev.defaultPrevented = false;
      ev.preventDefault = function () { ev.defaultPrevented = true; };
      handlers.keydown(ev);
      return ev;
    };
    ok(Editor.isTypingTarget({ tagName: 'INPUT' }) && Editor.isTypingTarget({ tagName: 'TEXTAREA' }) &&
       Editor.isTypingTarget({ tagName: 'SELECT' }) && Editor.isTypingTarget({ isContentEditable: true }) &&
       !Editor.isTypingTarget({ tagName: 'BODY' }) && !Editor.isTypingTarget(null) && !Editor.isTypingTarget({}),
       '★ isTypingTarget:input/textarea/select/contenteditable 四种都算,body/null/空对象都不算');
    Editor.app.st.tool = 'brush';
    const evBody = pressKey('l', { tagName: 'BODY' });
    ok(evBody.defaultPrevented === true && Editor.app.st.tool === 'line',
       '★★ (阳性对照)焦点在页面上时 L 键照旧:拦下浏览器默认行为并切到直线工具' +
       '(实得 preventDefault=' + evBody.defaultPrevented + ' tool=' + Editor.app.st.tool + ')');
    Editor.app.st.tool = 'brush';
    const evIn = pressKey('l', { tagName: 'INPUT' });
    ok(evIn.defaultPrevented === false && Editor.app.st.tool === 'brush',
       '★★★ 焦点在**输入框**里时同一个键一个都不拦:L 键不换工具、也不 preventDefault' +
       '(实得 preventDefault=' + evIn.defaultPrevented + ' tool=' + Editor.app.st.tool + ')');
    Editor.app.st.tool = 'brush';
    const evDigit = pressKey('2', { tagName: 'INPUT' });
    ok(evDigit.defaultPrevented === false && calls.indexOf('setLayer') < 0,
       '★★ 输入框里按数字键不切图层(用户是在打字:数字键 1-4 是切层的热键)');
    // ★★ 破坏性那条:Backspace 在输入框里必须**既**不 preventDefault **又**不清空选区。
    const mK = filled(Core.createMap('k', 4, 4), Core.LAYER_SCENE, Core.neutralDesc(3));
    Editor.app.map = mK;
    Editor.app.st.tool = 'brush';
    sel = { x: 0, y: 0, w: 8, h: 8 };
    calls.length = 0;
    const evBs = pressKey('Backspace', { tagName: 'INPUT' });
    ok(evBs.defaultPrevented === false && calls.indexOf('editCells') < 0 &&
       mK.layers[Core.LAYER_SCENE].desc[0] === Core.neutralDesc(3),
       '★★★ 输入框里按 Backspace:不拦(字符删得掉)、**也不清空选区**(实得 preventDefault=' +
       evBs.defaultPrevented + ' / 落笔 ' + (calls.indexOf('editCells') >= 0 ? '发生了' : '没发生') + ')');
    calls.length = 0;
    pressKey('Backspace', { tagName: 'BODY' });
    ok(calls.indexOf('editCells') >= 0 && mK.layers[Core.LAYER_SCENE].desc[0] === 0,
       '★★ (阳性对照)同一个 Backspace 在页面焦点下**确实**清空选区(上一条不是"这个键根本没接上")');

    // ── ⑬b 跨接缝拖动之后选区必须存回**折算后**的坐标 ──
    const mB = filled(Core.createMap('b', 6, 3), Core.LAYER_SCENE, Core.neutralDesc(4));   // 24×12 子格
    Editor.app.map = mB;
    Editor.app.st.tool = 'select';
    sel = { x: 22, y: 4, w: 4, h: 4 };                     // 选区跨着接缝(子格 22..25)
    Editor.app.st.selDrag = { from: { kind: 'sub', x: 22, y: 4 }, dx: 8, dy: 0 };
    calls.length = 0;
    Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
    eq(sel, { x: 6, y: 4, w: 4, h: 4 },
       '★★★ 拖动跨过接缝(22..25 右移 8 ⇒ 落下位置 30)之后,选区存的是**折算后**的 6:' +
       '存 30 会让 regionCells 的 inRect(clip) 一格都筛不进来(实得 ' + JSON.stringify(sel) + ')');
    // ★ 后果断言 —— "框内落笔有没有目标"才是用户能感觉到的那个面(0 个 = 在框里画、什么都没发生)。
    const inBox = Editor.regionCells(mB, { unit: 'sub', x0: 6, y0: 4, x1: 6, y1: 4 }, sel);
    eq(inBox.length, 1,
       '★★ 拖动之后"在框内落笔"有目标(实得 ' + inBox.length + ' 个 —— 0 个就是' +
       '"用户在框里画、什么都没发生、状态栏也不说")');
    // ── ⑬b3 接缝的**三个口径**必须合一:病灶是"选区"此前有三种判据 —— regionCells 的
    //   clip(非折算)、pointerdown 的"按在选区里"(非折算 inRect)、moveRegion 的 from
    //   集合(Render.inSel,环面折算)⇒ 接缝那一侧答案不同:"框里画一半画得进去、一半静默"。
    const mS = filled(Core.createMap('s', 24, 3), Core.LAYER_SCENE, Core.neutralDesc(4));  // 96×12 子格
    Editor.app.map = mS;
    const WRAP_SEL = { x: 93, y: 4, w: 6, h: 4 };          // 盖住子格 93,94,95,**0,1,2**
    const at = function (x, y) {
      return Editor.regionCells(mS, { unit: 'sub', x0: x, y0: y, x1: x, y1: y }, WRAP_SEL).length;
    };
    eq([at(93, 4), at(94, 4), at(95, 4), at(0, 4), at(1, 4), at(2, 4), at(3, 4), at(4, 4)],
       [1, 1, 1, 1, 1, 1, 0, 0],
       '★★★ 一个**自己跨着接缝**的选区({x:93,w:6} 盖住 93..95 与 0..2)在框内落笔时, ' +
       '绕过去的那半截也算数:93/94/95/0/1/2 六个都有目标、3/4 没有。旧实现用**非折算**的 ' +
       'inRect ⇒ 0/1/2 三个**静默拿不到**(用户在框里画,一半画得进去、一半什么都没发生)');
    eq(Editor.regionCells(mS, { unit: 'sub', x0: 0, y0: 4, x1: 0, y1: 4 }, WRAP_SEL).length,
       Render.inSel(WRAP_SEL, 0, 4, mS.subCols, mS.subRows) ? 1 : 0,
       '★★★ 并且它与**落笔那一侧**的判据(`Render.inSel`,即 moveRegion 的 from 集合)' +
       '逐格一致:子格 0 在一侧是 ' + Render.inSel(WRAP_SEL, 0, 4, mS.subCols, mS.subRows) +
       '、在另一侧是 ' + Editor.regionCells(mS, { unit: 'sub', x0: 0, y0: 4, x1: 0, y1: 4 }, WRAP_SEL).length +
       '(两者必须相等 —— 这就是"三个口径合一"的可判形式)');
    eq(Editor.regionCells(mB, { unit: 'sub', x0: 6, y0: 4, x1: 6, y1: 4 }, { x: 30, y: 4, w: 4, h: 4 }).length, 1,
       '★★ 连带:选区落在 [0, subCols) **之外**(24 宽的图上 x=30、宽 4 ⇒ 折算后就是 6..9)' +
       '时不再"一格都筛不进来" —— 环面判据下 30 与 6 是同一个选区。' +
       '★ 期望 0 现在只可能来自"判据又退回非折算",即回归');

    // ── ⑬b4 跨接缝的**框选**:子格 23 一格 → 拖过右边缘绕回格 0 ──
    // ★ 这条照实记录**当前的语义**:命中坐标在 hitTest/screenToSub 里就已经折算回 [0, subCols),
    //   `subRectOf` 只对两个端点取 min/max ⇒ 绕过去的那一段被读成"整整一行"(w = 96 子格)。
    Editor.app.map = mS;
    Editor.app.st.tool = 'select';
    Editor.app.st.brushSize = 1;                     // 整数画笔 ⇒ 命中是**格**号
    Editor.app.st.selStart = null; Editor.app.st.selDrag = null;
    sel = null;
    sub = { X: 92, Y: 4 };                           // 按下:格 23 的左上子格
    Editor.app.canvas.onpointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
    ok(!!Editor.app.st.selStart, '⑬ 前提:pointerdown 起了框选(选区为空 ⇒ 走的不是"拖选区")');
    sub = { X: 0, Y: 4 };                            // 拖过右边缘 ⇒ 折算回子格 0
    Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
    eq(sel, { x: 0, y: 4, w: 96, h: 4 },
       '★★ 跨接缝框选(格 23 → 绕过右边缘回到格 0)存下来的是**整整一行**(实得 ' +
       JSON.stringify(sel) + ';用户想要的是子格 {x:92,w:8}(= 格 23 与格 0))—— ' +
       '两个端点在命中那一步就已经折算回 [0, subCols),方向信息丢失,subRectOf 只能取 min/max。' +
       '★ 这条钉的是**今天的语义**:它同时是"删除键会抹掉一整行"那条已知缺陷的证据');
    eq(Editor.regionCells(mS, { unit: 'cell', x0: 0, y0: 1, x1: 23, y1: 1 }, sel).length, 24 * SUB * SUB,
       '★ 连带:那一整行的 24 格(384 个子格)**全在**框内。这条是上一条的**后果**面:' +
       '用户的删除会命中 24 格而不是他框的 2 格');

    // ── ⑬b5 "按在选区里"必须用**同一个**判据(三个口径里的第 ② 处)──
    sel = WRAP_SEL;                                  // 盖住 93..95 与 0..2
    Editor.app.st.tool = 'select';
    Editor.app.st.selStart = null; Editor.app.st.selDrag = null;
    // ★ 单位换算:整数画笔下 `hitOf` 给的是**格**号,由 `toSub` 折成子格 ⇒ `X:1` = 格 0 = 子格 0。
    sub = { X: 1, Y: 4 };                            // 按在**绕过去的那半截**里(格 0 = 子格 0)
    Editor.app.canvas.onpointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
    ok(!!Editor.app.st.selDrag && !Editor.app.st.selStart,
       '★★★ 按在**绕过去的那半截**(格 0 = 子格 0,属于 {x:93,w:6})里 = 拖动它,而不是重新框选' +
       '(实得 selDrag=' + !!Editor.app.st.selDrag + ' / selStart=' + !!Editor.app.st.selStart + ';' +
       '旧实现用非折算的 inRect ⇒ 判成"没按在选区里" ⇒ 一拖就是在重新框选,选区永远拖不动)');
    Editor.app.st.selStart = null; Editor.app.st.selDrag = null;
    sub = { X: 6, Y: 4 };                            // `X:6` ⇒ 格 1 ⇒ 子格 4,整格在折算区间**之外**
    Editor.app.canvas.onpointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
    ok(!Editor.app.st.selDrag && !!Editor.app.st.selStart,
       '★ (对照)按在选区**之外**(格 1 = 子格 4)仍然起框选 —— 上一条不是"永远走拖动那条路"');
    Editor.app.st.selStart = null; Editor.app.st.selDrag = null;
    sub = { X: 5, Y: 5 };                            // 还原恒落格 (1,1)
    ok(calls.indexOf('editCells') >= 0 && calls.indexOf('setSelection') >= 0,
       '★ 这一步真的走了"搬动 + 存回选区"两条路(实得 ' + JSON.stringify(calls) + ')');

    // ── ⑬c 单击(按下与松开之间没有 pointermove)也要落一次笔 ──
    const mC = Core.createMap('c', 4, 4);
    Editor.app.map = mC;
    sel = null;
    Editor.app.st = { tool: 'brush', brushSize: 1, desc: Core.neutralDesc(7), rgba: 0xFF00FFFF,
                      rgba2: 0x101820FF, descOnly: false, selStart: null, stroke: null,
                      panning: null, selDrag: null, gradStart: null };
    calls.length = 0;
    Editor.app.canvas.onpointerdown({ button: 0, clientX: 0, clientY: 0, pointerId: 1 });
    ok(!!Editor.app.st.stroke && Editor.app.st.stroke.painted === false,
       '⑬ 前提:pointerdown 起了笔画且标记未落笔(实得 ' + JSON.stringify(Editor.app.st.stroke) + ')');
    Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
    eq(countNonZero(mC, Core.LAYER_SCENE), SUB * SUB,
       '★★ 单击画笔落了一次笔(格 (1,1) 的 16 个子格都写上了纹理 7):旧实现只在 pointermove 里' +
       '落笔 ⇒ 单击一个字都不改、也不报错(矩形/直线是松手才落笔的,所以只有画笔/橡皮会这样)');

    // ── ⑬b2 Esc 取消选区、左键还按着时松手 ──
    // 拖动分支此前**无条件**读 `cur.x`,而 cancel-selection 把选区置 null ⇒ 在 guard 里抛 TypeError。
    const mE = filled(Core.createMap('e', 6, 3), Core.LAYER_SCENE, Core.neutralDesc(4));
    Editor.app.map = mE;
    const nE = countNonZero(mE, Core.LAYER_SCENE);
    Editor.app.st.tool = 'select';
    sel = null;                                   // ← Esc 已经把选区清掉了
    Editor.app.st.selDrag = { from: { kind: 'sub', x: 22, y: 4 }, dx: 8, dy: 0 };
    calls.length = 0; errs.length = 0;
    Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
    ok(errs.length === 0 && calls.indexOf('editCells') < 0 &&
       countNonZero(mE, Core.LAYER_SCENE) === nE,
       '★★ 选区已被 Esc 取消之后松手:不抛(没有错误进 sink)、也不改地图(实得 errs=' +
       JSON.stringify(errs) + ' calls=' + JSON.stringify(calls) + ')');

    // ── ⑬b2b Esc 在**拖动途中**按下去(走**真入口**:keydown → cancel-selection)──
    // 三件事缺一不可:① 要求渲染侧**撤掉偏移**;② 松手**不提交**;③ 记录不在时不许读它的字段。
    const mE2 = filled(Core.createMap('e2', 6, 3), Core.LAYER_SCENE, Core.neutralDesc(4));
    Editor.app.map = mE2;
    const nE2 = countNonZero(mE2, Core.LAYER_SCENE);
    Editor.app.st.tool = 'select';
    sel = { x: 4, y: 4, w: 4, h: 4 };
    Editor.app.st.selDrag = { from: { kind: 'sub', x: 4, y: 4 }, dx: 4, dy: 0 };   // ← 拖动在飞
    calls.length = 0; selDragArgs.length = 0; errs.length = 0;
    pressKey('Escape', { tagName: 'BODY' });
    ok(Editor.app.st.selDrag === null && sel === null &&
       selDragArgs.length === 1 && selDragArgs[0] === null,
       '★★★ Esc 在**拖动途中**按下:在飞的拖动记录与选区一起清掉,并且**当场**要求渲染侧' +
       '撤掉偏移(setSelDrag 的实参必须是 null;实得实参 ' + JSON.stringify(selDragArgs) +
       ' / 记录还在=' + !!Editor.app.st.selDrag + ' / 选区=' + JSON.stringify(sel) + ')。' +
       '★ 少了清记录这一半,"取消"与"别的什么把选区清掉了"就分不开');
    calls.length = 0; errs.length = 0;
    Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
    ok(errs.length === 0 && calls.indexOf('editCells') < 0 &&
       countNonZero(mE2, Core.LAYER_SCENE) === nE2,
       '★★★ 取消之后松手:**不抛、一个格都不搬**(实得 errs=' + JSON.stringify(errs) +
       ' / editCells=' + (calls.indexOf('editCells') >= 0) + ' / 改动格数=' +
       (countNonZero(mE2, Core.LAYER_SCENE) - nE2) + ')。★ 视觉上已经取消、数据却动了是最坏' +
       '那种不一致,而它只在"Esc 之后松手"这条路上现形');
    // ★ 单独隔离"没有在飞记录"这一支(判据必须先于读 `sd` 的字段)。
    sel = { x: 4, y: 4, w: 4, h: 4 };
    Editor.app.st.selDrag = null;
    Editor.app.st.selStart = null; Editor.app.st.stroke = null; Editor.app.st.gradStart = null;
    calls.length = 0; errs.length = 0;
    Editor.app.canvas.onpointerup({ button: 0, clientX: 0, clientY: 0 });
    ok(errs.length === 0 && calls.indexOf('editCells') < 0 &&
       calls.indexOf('setSelection') < 0,
       '★★ 没有在飞的拖动记录时(选区还在)pointerup 既不抛也不提交(实得 errs=' +
       JSON.stringify(errs) + ' calls=' + JSON.stringify(calls) + ')');

    // ── ⑬d pushAndShow 的 whole ⇒ invalidateAll 分派 ──
    const mW = Core.createMap('w', 2, 1);
    Editor.app.map = mW;
    calls.length = 0;
    eq(Editor.pushAndShow(Editor.wholeDiff(mW, 'resize').seal()), true, '⑬ 前提:whole 差量被接受');
    ok(calls.indexOf('invalidateAll') >= 0 && calls.indexOf('editCells') < 0 &&
       calls.indexOf('render') < 0,
       '★★ kind=whole 走 **invalidateAll**(diffCells 对它是空数组 ⇒ 只 render() 的话整张图' +
       '停在旧尺寸/旧内容上;实得 ' + JSON.stringify(calls) + ')');
    calls.length = 0;
    const mN = Core.createMap('n', 2, 1);
    const nd = Editor.applyTool(stOf(mN, Core.LAYER_SCENE), 'brush',
                                { kind: 'cell', x: 0, y: 0 }, { kind: 'cell', x: 0, y: 0 });
    Editor.app.map = mN;
    ok(Editor.pushAndShow(nd) === true && calls.indexOf('editCells') >= 0 &&
       calls.indexOf('invalidateAll') < 0,
       '★ (对照)普通差量走 editCells(不是"两条路都掉进 invalidateAll"也能过;实得 ' +
       JSON.stringify(calls) + ')');

    eq(errs.length, 0,
       '★★ 整个相位里**一条错误都没进过 sink**:处理器全在 guard 里跑,替身少一个方法就会' +
       '变成一条被吞掉的异常(实得 ' + JSON.stringify(errs) + ')');
  } finally {
    Editor.setErrorSink(null);
    globalThis.addEventListener = savedAdd;
    globalThis.document = savedDoc;
    Editor.app.r = savedR; Editor.app.map = savedMap; Editor.app.canvas = savedCv;
    // ★ 先把字段**逐个**还回原对象,再把引用还回去 —— 两半缺一不可(见相位头那条注释)。
    if (savedSt && savedStFields) {
      for (const kk in savedStFields) savedSt[kk] = savedStFields[kk];
    }
    if (savedSt) Editor.app.st = savedSt;
  }

  // ── 收尾:`app.st` 必须**逐字段**还成生产初始状态 ──
  // ★ 判据取**字段值**(tool / brushSize / 无在飞状态)而不是"还是同一个对象":对象身份两种实现完全一样。
  ok(!!Editor.app.st && Editor.app.st.tool === 'brush' && Editor.app.st.brushSize === 1 &&
     !Editor.app.st.selDrag && !Editor.app.st.selStart && !Editor.app.st.stroke,
     '★★ 相位收尾:app.st 被**逐字段**还成生产初始状态(tool=brush / brushSize=1 / 无在飞状态;' +
     '实得 tool=' + (Editor.app.st && Editor.app.st.tool) + ' brushSize=' +
     (Editor.app.st && Editor.app.st.brushSize) + ' selDrag=' + !!(Editor.app.st && Editor.app.st.selDrag) +
     ')。★ 只还引用的话,⑬b4/⑬b5 **原地**改过的 tool 会以 \'select\' 漂到后面追加的分片里');

})();
