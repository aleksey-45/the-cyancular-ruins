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

// ★ 环面 3×3 只返回"与视口相交"的那些副本偏移(最多 9 份,通常 1 份):无脑铺 9 份是 9 倍开销,而屏幕上绝大多数时候只看得到一份。
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

// 屏幕 → 子格(折算回主网格)。★ 副本上落笔靠的就是这一步:无论点在哪个副本上,结果都落在 [0, subCols) 里。
function hitTest(view, px, py, subCols, subRows) {
  var X = Math.floor(view.x + px / view.zoom);
  var Y = Math.floor(view.y + py / view.zoom);
  return { X: wrapIdx(X, subCols), Y: wrapIdx(Y, subRows) };
}
