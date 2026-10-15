// render/65_selection.js —— 选区的环面成员判据、拖动偏移查询与规范块分解。

// ★★ selectionSource 的 W/H(= map.subCols/subRows)是可选的,给了就按环面折算(与 UI 的 idxOf / moveRegion 同一套 wrap)。
//    ★ 拖动查询必须给 —— 跨过接缝时目标格落在图的另一头(24 → 0),不折算的预览读到的是"目标格自己的内容",而松手 moveRegion 真搬过去的是源格的内容 ⇒ 预览 ≠ 落笔。
function selectionSource(sel, dx, dy, X, Y, W, H) {
  var sx = X - dx, sy = Y - dy;
  if (W > 0 && H > 0) { sx = wrapIdx(sx, W); sy = wrapIdx(sy, H); }   // 不给 = 不折算;5 实参的旧调用点都在主网格内,折算在那里是恒等
  if (inSel(sel, sx, sy, W, H)) return { hit: true, X: sx, Y: sy };
  return { hit: false, X: X, Y: Y };
}

// 选区在环面上的成员判据,而且是唯一一处 —— UI 的 inRect 直接转调它,故 regionCells 的 clip / 油漆桶 / 渐变 / 直线 / "按在选区里"五个调用点与这里的 moveRegion from 集合是同一条判据。
// ★ 公式:先各自折算到主网格再比相对偏移 —— 绝对比大小会在"选区自己跨着接缝"时静默漏掉绕过去的那半截(如 96 宽的图上 {x:93,w:6} 盖住 93..95 与 0..2)。
function inSel(sel, X, Y, W, H) {
  if (!sel) return false;
  if (!(W > 0 && H > 0)) {
    return X >= sel.x && X < sel.x + sel.w && Y >= sel.y && Y < sel.y + sel.h;
  }
  var ox = wrapIdx(wrapIdx(X, W) - wrapIdx(sel.x, W), W);
  var oy = wrapIdx(wrapIdx(Y, H) - wrapIdx(sel.y, H), H);
  return ox < sel.w && oy < sel.h;
}

function dedupRects(list) {                    // ★★ 必须有:去烤要把「当前偏移的源∪目标」与「上一次那两块」并起来重画,而选区没变时源块必然两组都有 ⇒ 不去重就把最大那块画两遍
  var out = [], seen = {};
  for (var i = 0; i < list.length; i++) {
    var r = list[i], key = r.x + ',' + r.y + ',' + r.w + ',' + r.h;   // 取四元组而非对象身份:两组矩形是各自 canonRects 算的,同一块在两边是两个不同对象
    if (seen[key]) continue;
    seen[key] = 1;
    out.push(r);
  }
  return out;
}

// ★ 一个矩形折算后至多 4 块:只取"左上角折算"会漏掉接缝另一头那半截(那半边的烤痕永远留着),取包围盒则会把整幅图都算进去。
function canonRects(r, W, H) {
  var out = [];
  if (!r || r.w <= 0 || r.h <= 0) return out;   // ★★ 只要求 w>0,不假设 x+w ≤ W:拖动会把折叠后的左上角与原始宽度一起存回来
  var x0 = wrapIdx(r.x, W), x1 = wrapIdx(r.x + r.w - 1, W);
  var y0 = wrapIdx(r.y, H), y1 = wrapIdx(r.y + r.h - 1, H);
  var xs = (x1 >= x0) ? [[x0, x1]] : [[x0, W - 1], [0, x1]];
  var ys = (y1 >= y0) ? [[y0, y1]] : [[y0, H - 1], [0, y1]];
  for (var i = 0; i < ys.length; i++) {
    for (var j = 0; j < xs.length; j++) {
      out.push({ x: xs[j][0], y: ys[i][0],
                 w: xs[j][1] - xs[j][0] + 1, h: ys[i][1] - ys[i][0] + 1 });
    }
  }
  return out;
}
