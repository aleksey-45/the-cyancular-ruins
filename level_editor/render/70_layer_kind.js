// render/70_layer_kind.js —— 图层绘制顺序与层种类:前景(0)是"从外到内"的第一层 ⇒ 最后画(盖在最上面),
// 背景 25%(6)最先画。顺序 = 层号倒序,长度从 Core.LAYER_COUNT 派生(7 层:3 纹理 + 4 景深背景)。
function buildDrawOrder() {
  var a = [];
  for (var L = RenderCore.LAYER_COUNT - 1; L >= 0; L--) a.push(L);
  return a;
}
var DRAW_ORDER = buildDrawOrder();

function layerIsColor(L) { return RenderCore.LAYER_KINDS[L] === 'color'; }   // ★★ 纹理层是描述符(走 Core.texOf / Tint),背景层是 RGBA 0xRRGGBBAA(走 cssOfRGBA / fillRect):两者都是 32 位无符号数、长得一模一样,把 RGBA 喂给 texOf 不抛只是结论无意义(#FF0000FF 的纹理位是 0 ⇒ 整层当空气 ⇒ 看不见;#00FFFFFF 的纹理位是 4095 ⇒ 当场抛 Tint 越界)。判据取 core 的单一来源 LAYER_KINDS,别在渲染层再抄一份(权威见 docs/eng/editor-render.md §6)
