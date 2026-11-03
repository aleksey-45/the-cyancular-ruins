// render/50_view.js —— 缩放/适配、可见区裁剪、环面 3×3 偏移与屏幕→子格命中。

function zoomPath(pxPerSub) { return pxPerSub < ZOOM_THRESHOLD ? 'thumb' : 'layers'; }
function clampZoom(z) {
  if (!isFinite(z) || z <= 0) return MIN_ZOOM;   // 用户输入钳制,不报错回滚
  return Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, z));
}
function fitZoom(subCols, subRows, viewW, viewH, pad) {
  var p = pad === undefined ? 8 : pad;
  var zx = (viewW - 2 * p) / subCols, zy = (viewH - 2 * p) / subRows;
  return clampZoom(Math.min(zx, zy));
}
function thumbScale(subCols, subRows) {
  var bytes = subCols * THUMB_PX * subRows * THUMB_PX * 4;
  return bytes > THUMB_MAX_BYTES ? 1 : THUMB_PX;
}

// ★ visibleSubRange 返回的是未折算的坐标(3×3 副本要的正是它):调用方按格自己 wrapIdx。
function visibleSubRange(view, viewW, viewH, subCols, subRows) {
  var x0 = Math.floor(view.x), y0 = Math.floor(view.y);
  var x1 = Math.ceil(view.x + viewW / view.zoom), y1 = Math.ceil(view.y + viewH / view.zoom);
  return { x0: x0, y0: y0, x1: x1, y1: y1 };
}

// ★ 环面偏移的"相交过滤"版(公开面,测试与几何断言用)。★ 合成侧**不再**用它:88 的 torusList 固定 2×2
//   (只铺右/下两份),理由见那里的注释 —— 这条留着是因为 torusOffsets 是 99_exports 的公开 API。
function intersects(a0, a1, b0, b1) { return a1 > b0 && a0 < b1; }
function torusOffsets(view, viewW, viewH, mapW, mapH) {
  var r = visibleSubRange(view, viewW, viewH, mapW, mapH);
  var out = [];
  for (var ky = -1; ky <= 1; ky++) {
    var lo = ky * mapH, hi = lo + mapH;
    if (!intersects(r.y0, r.y1, lo, hi)) continue;
    for (var kx = -1; kx <= 1; kx++) {
      var lox = kx * mapW, hix = lox + mapW;
      if (!intersects(r.x0, r.x1, lox, hix)) continue;
      out.push([lox, lo]);
    }
  }
  return out;
}

// ⑩ 的配套:视图钳制(只在 panBy 里用)。2×2(定义 A)只有右/下两份副本 ⇒ "有内容的世界矩形" =
// [0, 2W] × [0, 2H](环面关掉时 [0, W] × [0, H])。判据:画布中心必须落在该矩形内 ——
// 比"至少一份副本与画布相交"更强(中心永远有内容),而 fit/默认视图离边界很远,不会被钳到。
// ★ 棘轮:视图已经在界外时(setView 直接给定 / 刚关掉环面 / 缩放过)只允许往界内走 —— 否则下一次 1px 的
//   拖拽会把它瞬移到边界上:画面跳一下,而脏区那套还得为这次瞬移付一次整片重建。
function clampPanAxis(cur, next, lo, hi) {
  if (cur < lo) return Math.max(next, cur);
  if (cur > hi) return Math.min(next, cur);
  return Math.max(lo, Math.min(hi, next));
}
function clampPanView(view, x, y, viewW, viewH, subCols, subRows, torusOn) {
  var vw = viewW / view.zoom, vh = viewH / view.zoom;
  var right = (torusOn ? 2 : 1) * subCols, bottom = (torusOn ? 2 : 1) * subRows;
  return { x: clampPanAxis(view.x, x, -vw / 2, right - vw / 2),
           y: clampPanAxis(view.y, y, -vh / 2, bottom - vh / 2) };
}

// 屏幕 → 子格(折算回主网格)。★ 副本上落笔靠的就是这一步:无论点在哪个副本上,结果都落在 [0, subCols) 里。
function hitTest(view, px, py, subCols, subRows) {
  var X = Math.floor(view.x + px / view.zoom);
  var Y = Math.floor(view.y + py / view.zoom);
  return { X: wrapIdx(X, subCols), Y: wrapIdx(Y, subRows) };
}
