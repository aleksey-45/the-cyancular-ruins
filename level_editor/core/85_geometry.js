// core/85_geometry.js —— 名字净化与画笔几何。


function sanitizeName(name) {
  var n = String(name == null ? '' : name).trim();
  n = n.replace(/\s+/g, '_');
  n = n.replace(/[^A-Za-z0-9_一-龥-]/g, '');
  n = n.replace(/^-+/, '');
  if (n.length > 32) n = n.slice(0, 32);
  return n === '' ? 'structure' : n;
}

// 画笔块偏移:以指针格为中心向上下/左右扩展,保证 lo+1+hi===size;奇数对称,偶数偏下右(否则偶数会缩水一格)。
function brushOffsets(size) {
  return { lo: Math.floor((size - 1) / 2), hi: Math.ceil((size - 1) / 2) };
}

// Bresenham 直线路径格坐标(含两端)。
function lineCells(x0, y0, x1, y1) {
  var cells = [];
  var dx = Math.abs(x1 - x0), dy = Math.abs(y1 - y0);
  var sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
  var err = dx - dy;
  var x = x0, y = y0;
  for (;;) {
    cells.push([x, y]);
    if (x === x1 && y === y1) break;
    var e2 = 2 * err;
    if (e2 > -dy) { err -= dy; x += sx; }
    if (e2 < dx) { err += dx; y += sy; }
  }
  return cells;
}

// 矩形区域归一化:任意两角点 → {x, y, w, h}(含两端)。
function normRegion(x0, y0, x1, y1) {
  return { x: Math.min(x0, x1), y: Math.min(y0, y1),
           w: Math.abs(x1 - x0) + 1, h: Math.abs(y1 - y0) + 1 };
}
