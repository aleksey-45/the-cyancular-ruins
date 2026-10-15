// render/60_brush.js —— 画笔几何:size → 格/子格跨度、region 与 snapHit 吸附。

var MAX_BRUSH_CELLS = 15;
function brushSpan(size) {
  var s = (typeof size === 'number' && isFinite(size)) ? size : 1;
  if (s <= 0) s = 1;
  if (Math.floor(s) === s) return { unit: 'cell', n: Math.max(1, Math.min(MAX_BRUSH_CELLS, s)) };
  var n = Math.round(s * SUB);                 // 0.25→1、0.5→2、0.75→3、2.5→10
  return { unit: 'sub', n: Math.max(1, Math.min(MAX_BRUSH_CELLS * SUB, n)) };
}
function brushRegion(hit, size) {
  var sp = brushSpan(size);
  var c = (typeof hit === 'object' && hit) ? hit : {};
  var x = Math.floor(isFinite(c.x) ? c.x : 0);
  var y = Math.floor(isFinite(c.y) ? c.y : 0);
  var lo = Math.floor((sp.n - 1) / 2), hi = Math.ceil((sp.n - 1) / 2);
  var unit = (c.kind === 'cell' || c.kind === 'sub') ? c.kind : sp.unit;   // ★★ unit 必须描述 x0..x1 所在的坐标空间(它们就是 hit 的空间,不是 size 那一侧):按 size 标注会让 regionCells 把子格坐标当成格号去 ×4
  return { unit: unit, x0: x - lo, y0: y - lo, x1: x + hi, y1: y + hi };
}
// ★★ 吸附 = 换算坐标空间,不只是贴个 kind 标签:hitTest 交出来的 X/Y 一直是子格号(与 kind 无关),所以 kind 'cell' 的命中必须 floor(X / SUB) 换成格号(与 UI 的 hitOf 同一条式子)。
//    两个分支只差一个标签的话,格空间的命中会把子格号当格号传下去,而下游(brushRegion 的 unit、regionCells)正是按 kind 决定要不要 ×4 —— 于是整支画笔偏到别处。
function snapHit(h) {
  if (h.kind === 'sub') return { kind: 'sub', x: Math.floor(h.X), y: Math.floor(h.Y) };
  return { kind: 'cell', x: Math.floor(h.X / SUB), y: Math.floor(h.Y / SUB) };
}
