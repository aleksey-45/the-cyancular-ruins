'use strict';
// 相位 ⑬d:开机的 UI 小状态 —— 图集**还没装**时读、装上之后再按回界面。
// ★★★ 为什么必须钉在"图集还没装"这一刻:`bootLoad` 的真实顺序是 `readUiState` **在前**、
//    `loadAtlas()` **在后**(`setAtlas` 之前 `atlasCapacity()` 是 **0**);而 ⑭ 会把一张
//    512×640 的图集装进来 ⇒ ⑭ 之后再测就测不到了(那时坏实现也能过)。
// ★★ 老断言为什么看不见这个 bug:当年**直接注入 `app.uist`**(绕过 `readUiState`)——
//    一个**不可能失败**的守卫。本相位走**真序列**:readUiState → setAtlas → applyUiState。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const Render = globalThis.Render;

module.exports = (async function () {

  const savedDoc = globalThis.document;
  const savedR = Editor.app.r, savedMap = Editor.app.map;
  const savedUist = Editor.app.uist, savedDesc = Editor.app.st.desc;
  try {
    // ★ 工具条替身(形状照 editor.html:`.tool` + `data-tool`,高亮是 classList 的 `on`)。
    const toolBtns = ['brush', 'rect', 'bucket', 'eraser', 'line', 'select',
                      'picker', 'gradient'].map(function (t) {
      const on = { on: t === 'brush' };              // 生产初始态:buildPanels 末尾按 tool=brush 画的
      return { dataset: { tool: t },
               classList: { toggle: function (c, v) { on[c] = !!v; },
                            contains: function (c) { return !!on[c]; } },
               _on: on };
    });
    globalThis.document = {
      getElementById: function () { return null; },
      querySelector: function () { return null; },
      querySelectorAll: function (sel) { return sel === '#toolbar .tool' ? toolBtns : []; },
    };
    const calls = [];
    Editor.app.r = {
      view: function () { return { x: 0, y: 0, zoom: 1 }; },
      layer: function () { return Core.LAYER_SCENE; },
      selection: function () { return null; },       // statusLine 会读它
      setLayer: function (L) { calls.push('setLayer:' + L); },
      setGrid: function () {}, setSubGrid: function () {}, setTorus: function () {},
      setDimOthers: function () {}, setZoomAt: function () { return Promise.resolve(); },
    };
    Editor.app.map = Editor.createEmptyMap('uist_probe', 4, 4);

    eq(Render.atlasCapacity(), 0,
       '★★★ 前提:此刻图集**还没装**(容量 0)—— 这正是 `bootLoad` 读 UI 状态那一刻的真实条件' +
       '(实得 ' + Render.atlasCapacity() + ';不为 0 说明本相位的排序漂到 ⑭ 之后了)');
    // ★★ 存进去的是 7,而"图集还没装"时 `clampTexture` 对 cap<1 给的是 **1**
    //    ⇒ 用图集上界钳的实现会把 7 变成 1,并让下一次 `persistUi` 把 1 写回 localStorage。
    const store = {};
    store[Editor.UI_STATE_KEY] = JSON.stringify({ selectedTexture: 7, tool: 'line' });
    const uist = Editor.readUiState(store);
    eq(uist.selectedTexture, 7,
       '★★★ `readUiState` **不得**用图集派生的上界钳:图集还没装时存下来的纹理位必须原样留着' +
       '(实得 ' + uist.selectedTexture + ' —— 为 1 就是"每次开机静默毁掉用户选中的纹理")');
    // ── 开机那条路的后半段:图集装上之后才 applyUiState ──
    Render.setAtlas(new Uint8ClampedArray(512 * 640 * 4), 512, 640);
    ok(Render.atlasCapacity() >= 7, '⑬d 前提:图集装好了(容量 ' + Render.atlasCapacity() + ')');
    Editor.app.uist = uist;
    Editor.app.st.desc = Core.neutralDesc(1);
    Editor.applyUiState();
    eq(Core.texOf(Editor.app.st.desc), 7,
       '★★★ 存下来的纹理位**活到了界面上**(`applyUiState` 在 `setAtlas` 之后跑,钳制该在那里做;' +
       '实得 ' + Core.texOf(Editor.app.st.desc) + ')。★ 钳制没被删掉,只是挪到了它该在的时机' +
       '(此刻容量是 ' + Render.atlasCapacity() + ')');
    // ── 同一条链的另一半:**工具条高亮**也要跟着状态走(与 `setLayer` 同一个模式)──
    const on = function (t) { return toolBtns.filter(function (b) { return b.dataset.tool === t; })[0]._on.on; };
    ok(on('line') && !on('brush'),
       '★★★ `applyUiState` 必须把**工具条高亮**也搬过去:存的是「直线」⇒ 高亮在直线那一颗上、' +
       '画笔那颗要灭(实得 line=' + on('line') + ' brush=' + on('brush') + ')。' +
       '★ 少了 `selectToolButton()` 就是"高亮钉在 editor.html 写死的画笔上、实际生效的是直线"' +
       ' —— 用户看到的与正在发生的不是一回事,而且一个字都不报');
    eq(Editor.app.st.tool, 'line', '(对照)工具状态本身照旧按回去了');
  } finally {
    globalThis.document = savedDoc;
    Editor.app.r = savedR; Editor.app.map = savedMap;
    Editor.app.uist = savedUist;
    if (Editor.app.st) Editor.app.st.desc = savedDesc;
  }

})();
