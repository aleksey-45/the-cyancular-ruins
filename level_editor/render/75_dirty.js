// render/75_dirty.js —— 脏区纯逻辑:矩形并/空判、脏集、平移边条、以光标为锚缩放。

function rectUnion(a, b) {
  if (!a) return { x: b.x, y: b.y, w: b.w, h: b.h };
  if (!b) return { x: a.x, y: a.y, w: a.w, h: a.h };
  var x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  var x2 = Math.max(a.x + a.w, b.x + b.w), y2 = Math.max(a.y + a.h, b.y + b.h);
  return { x: x, y: y, w: x2 - x, h: y2 - y };
}
function rectIsEmpty(r) { return !r || r.w <= 0 || r.h <= 0; }

// ── ② 的脏区簿记(编辑 → 标脏;切层 → 只合成;平移 → 搬移 + 补边条)──
// ★ 跨层的脏矩形合成用一个包围盒就够:合成时按层拆是在 ② 的离屏层上做的,而"这一帧要不要重画"只需要一个上界(包围盒偏大只会多画一点,不会画错)。
// ★ 没有容量上限是因为它有界:只装调用方交上来的那几个格/矩形,用完即 clear,与"每帧累积的集合"不是一类东西。
function createDirtySet() {
  var box = null;
  function addRect(r) { box = rectUnion(box, r); }
  function addCell(L, cx, cy) { addRect({ x: cx * SUB, y: cy * SUB, w: SUB, h: SUB }); }   // 格坐标(64px 格)→ 子格矩形
  return { addRect: addRect, addCell: addCell,
           rect: function () { return box ? { x: box.x, y: box.y, w: box.w, h: box.h } : null; },
           clear: function () { box = null; } };
}

// ★ panStrips 的参数是视图/世界的位移方向(view.x 增加 dxPx/zoom):画面内容是反向走的,所以"向右看 10px"新露出来的是右边那 10px,调用方那里的自拷贝偏移是它的相反数。
function panStrips(w, h, dx, dy) {
  var out = [];
  if (dx === 0 && dy === 0) return out;
  if (Math.abs(dx) >= w || Math.abs(dy) >= h) return [{ x: 0, y: 0, w: w, h: h }];
  if (dx > 0) out.push({ x: w - dx, y: 0, w: dx, h: h });
  if (dx < 0) out.push({ x: 0, y: 0, w: -dx, h: h });
  if (dy > 0) out.push({ x: 0, y: h - dy, w: w, h: dy });
  if (dy < 0) out.push({ x: 0, y: 0, w: w, h: -dy });
  return out;
}

function zoomAround(view, px, py, factor) {   // 以光标为锚缩放:光标下那一子格在缩放前后停在原地
  var z = clampZoom(view.zoom * (isFinite(factor) && factor > 0 ? factor : 1));
  var wx = view.x + px / view.zoom, wy = view.y + py / view.zoom;
  return { x: wx - px / z, y: wy - py / z, zoom: z };
}
