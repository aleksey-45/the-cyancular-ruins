// ui/20_tools.js —— 工具内核:调色板、画笔几何、工具分派。

// ── 工具集(规格 §4.4)──
var TOOLS = ['brush', 'rect', 'bucket', 'eraser', 'line', 'select', 'picker', 'gradient'];
var TOOL_LABELS = { brush: '画笔', rect: '矩形', bucket: '油漆桶', eraser: '橡皮',
                    line: '直线', select: '选框', picker: '吸管', gradient: '渐变' };
// ★ 纹理 22(水面)在游戏里是自动派生的(审计 A7):做成可点选调色板只会产出"编辑器里画的、
//   游戏里看到的"不一样的图(而且不报错),故排除,只在提示里点名。
var DERIVED_TEXTURES = [22];

// ── 尺寸与纹理的硬上限(闸 1:一律钳制,不报错回滚)──
// ★★ 唯一的造图入口:Core.createMap 不判 400×300 上限(只要求正整数),输入 99999 必须
//    在这里被 Core.clampMapSize 截住 —— 第二个造图入口就是 A8 原样复发(分配巨图卡死)。
function createEmptyMap(name, w, h) {
  var c = Core.clampMapSize(w, h);
  return Core.createMap(Core.sanitizeName(name), c.w, c.h);
}
// ★ 纹理号必须同时避开两个坑:0(空气,没有贴图)与超出图集容量(越界会抛)。
// ★★ 上界派生自图集(列 × 行,换图集就变):容量 < 1(= 图集还没加载 / 一块都放不下 /
//    畸形图集算出的负数)一律当"没有信息" ⇒ 只给 1 —— 放宽到描述符位宽等于把越界号
//    直接放进 tileFor(它抛,而且每帧同一处抛一屏)。
function clampTexture(tex, atlasCap) {
  var t = parseInt(tex, 10);
  if (!isFinite(t) || t < 1) t = 1;
  var cap = (atlasCap === undefined || atlasCap === null) ? Render.atlasCapacity()
                                                          : parseInt(atlasCap, 10);
  if (!isFinite(cap) || cap < 1) cap = 1;
  return Math.max(1, Math.min(cap, t));
}
function texturePalette(defs) {
  if (!defs || !defs.tiles) return [];
  var out = [];
  Object.keys(defs.tiles).forEach(function (k) {
    var tex = parseInt(k, 10);
    if (!isFinite(tex) || tex <= 0) return;
    if (DERIVED_TEXTURES.indexOf(tex) >= 0) return;
    var t = defs.tiles[k] || {};
    out.push({ tex: tex, name: t.name ? String(t.name) : ('纹理 ' + tex),
               type: t.type ? String(t.type) : '' });
  });
  out.sort(function (a, b) { return a.tex - b.tex; });
  return out;
}
// 校验清单(规格 §4.7):只报告,不阻止导出。
function validateLines(report) {
  var out = [];
  var r = report || { errors: [], warnings: [] };
  (r.errors || []).forEach(function (e) { out.push('✖ ' + e); });
  (r.warnings || []).forEach(function (w) { out.push('⚠ ' + w); });
  return out;
}

// ── 目标集合(单位换算 + 环面 + 选区约束)──
// ★★ 选区成员的判据本体只有一处:Render.inSel(拖动预览、这里、moveRegion 的 from 集合
//    转调的是同一个函数),所以"预览 / 落笔 / 框内落笔"三处不可能再分岔。
// ★★ 给了 W/H 就按环面折算(先各自折算到主网格、再比相对偏移);非折算的调用点语义与从前
//    逐字相同。这修掉的是"选区自己跨着接缝时,接缝另一侧的那半截静默画不进去、也不报错"。
function inRect(r, x, y, W, H) { return !r || Render.inSel(r, x, y, W, H); }
function idxOf(map, X, Y) {
  return Render.wrapIdx(Y, map.subRows) * map.subCols + Render.wrapIdx(X, map.subCols);
}
// ★ 两种单位(格 / 子格)的换算只此一处:region.unit === 'cell' ⇒ 每格 16 个子格。
function regionCells(map, region, clip) {
  var out = [], seen = new Set();
  function add(X, Y) {
    var wx = Render.wrapIdx(X, map.subCols), wy = Render.wrapIdx(Y, map.subRows);
    if (!inRect(clip, wx, wy, map.subCols, map.subRows)) return;   // ★ 选区约束绘制(环面)
    var i = wy * map.subCols + wx;
    if (seen.has(i)) return;                           // 环面下 3×3 会重复命中,去重
    seen.add(i); out.push(i);
  }
  var k = Core.SUB_PER_CELL;
  if (region.unit === 'cell') {
    for (var cy = region.y0; cy <= region.y1; cy++) {
      for (var cx = region.x0; cx <= region.x1; cx++) {
        for (var qy = 0; qy < k; qy++) {
          for (var qx = 0; qx < k; qx++) add(cx * k + qx, cy * k + qy);
        }
      }
    }
  } else {
    for (var y = region.y0; y <= region.y1; y++) {
      for (var x = region.x0; x <= region.x1; x++) add(x, y);
    }
  }
  return out;
}
// ★★ Core.lineCells 的坐标必须是整数:非整数或 NaN 会让它的 for(;;) 死循环、挂住整个
//    标签页。所有调用点都在这里 floor(★ 这条只剩行为侧一半:产物是整数;新加一个忘了 floor
//    的调用点今天抓不到 —— 零守卫登记在 docs/eng/debt/guard-strength-gaps.md)。
function strokePoints(from, to) {
  var pts = [];
  if (!to || (from.x === to.x && from.y === to.y)) { pts.push(from); return pts; }
  var cells = Core.lineCells(Math.floor(from.x), Math.floor(from.y),
                             Math.floor(to.x), Math.floor(to.y));
  for (var i = 0; i < cells.length; i++) pts.push({ kind: from.kind, x: cells[i][0], y: cells[i][1] });
  return pts;
}
function lineTargets(map, a, b, clip) {
  var pts = strokePoints({ kind: 'sub', x: a.x, y: a.y }, { kind: 'sub', x: b.x, y: b.y });
  var out = [], seen = new Set();
  for (var i = 0; i < pts.length; i++) {
    var wx = Render.wrapIdx(pts[i].x, map.subCols), wy = Render.wrapIdx(pts[i].y, map.subRows);
    if (!inRect(clip, wx, wy, map.subCols, map.subRows)) continue;
    var idx = wy * map.subCols + wx;
    if (seen.has(idx)) continue;
    seen.add(idx); out.push(idx);
  }
  return out;
}
function toSub(hit) {
  var k = Core.SUB_PER_CELL;
  return hit.kind === 'cell' ? { x: hit.x * k, y: hit.y * k } : { x: hit.x, y: hit.y };
}

// ── Shift 约束(规格 §4.8:直线约束 / 选区等比)──
// ★ 纯函数,而且是唯一一处做这个判断的地方:预览与落笔必须用同一个结果,否则预览画的是 A、
//   松手落下去的是 B。★ 返回值一律 floor:产物会直接喂给 lineCells —— 非整数 = 死循环。
function constrainLine(a, b, shift) {
  var bx = Math.floor(b.x), by = Math.floor(b.y);
  if (!shift) return { x: bx, y: by };
  var dx = b.x - a.x, dy = b.y - a.y;
  var adx = Math.abs(dx), ady = Math.abs(dy);
  if (adx >= 2 * ady) return { x: bx, y: Math.floor(a.y) };          // 近水平 → 锁水平
  if (ady >= 2 * adx) return { x: Math.floor(a.x), y: by };          // 近垂直 → 锁垂直
  var m = Math.max(adx, ady);                                        // 其余 → 45°
  return { x: Math.floor(a.x + (dx < 0 ? -m : m)), y: Math.floor(a.y + (dy < 0 ? -m : m)) };
}
function constrainSquare(a, b, shift) {
  var bx = Math.floor(b.x), by = Math.floor(b.y);
  if (!shift) return { x: bx, y: by };
  var dx = b.x - a.x, dy = b.y - a.y;
  var m = Math.max(Math.abs(dx), Math.abs(dy));
  return { x: Math.floor(a.x + (dx < 0 ? -m : m)), y: Math.floor(a.y + (dy < 0 ? -m : m)) };
}

// ── 落笔:先读旧值、再写、产出一条差量 ──
function paintCells(map, L, idx, valueOf) {
  var arr = Render.layerArray(map, L);
  if (!arr || !arr.length) return null;
  var changed = [], before = [], after = [], seen = new Set();
  for (var i = 0; i < idx.length; i++) {
    var k = idx[i];
    if (seen.has(k)) continue;
    seen.add(k);
    var oldV = arr[k], newV = valueOf(oldV) >>> 0;
    if (newV === oldV) continue;                        // 值没变就不进差量(撤销栈里不留空操作)
    changed.push(k); before.push(oldV); after.push(newV);
    arr[k] = newV;
  }
  if (!changed.length) return null;
  return { kind: 'cells', layer: L, idx: Int32Array.from(changed),
           before: Uint32Array.from(before), after: Uint32Array.from(after) };
}
function valueFor(st, L) {
  if (L === Core.LAYER_BG) return function () { return st.rgba >>> 0; };
  if (st.descOnly) {
    // ★ "只改辅码":空气仍是空气(不能凭空长出纹理),有纹理的保留原纹理、只换辅码 ——
    //   少了这一支,整片墙"变暗"的操作会把墙换成画笔当前选的那个纹理。
    return function (oldV) {
      if (oldV === 0 || Core.texOf(oldV) === 0) return oldV;
      return Core.packDesc(Core.texOf(oldV), Core.hueOf(st.desc), Core.brightOf(st.desc),
                           Core.satOf(st.desc), Core.alphaOf(st.desc));
    };
  }
  return function () { return st.desc >>> 0; };
}
function pickAt(map, L, X, Y) { return Render.descAt(map, L, X, Y); }

// 一次工具操作 → 一条差量(没有改动就返回 null)。bucket / gradient / select 不走这里。
function applyTool(st, tool, from, to) {
  var map = st.map, L = st.layer, clip = st.selection || null;
  var idx = null;
  if (tool === 'picker' || tool === 'select' || tool === 'bucket' || tool === 'gradient') return null;
  if (tool === 'brush' || tool === 'eraser') {
    var pts = strokePoints(from, to), seen = new Set();
    idx = [];
    for (var i = 0; i < pts.length; i++) {
      var reg = Render.brushRegion(pts[i], st.brushSize);
      var list = regionCells(map, reg, clip);
      for (var k2 = 0; k2 < list.length; k2++) {
        if (seen.has(list[k2])) continue;
        seen.add(list[k2]); idx.push(list[k2]);
      }
    }
    if (tool === 'eraser') {
      return paintCells(map, L, idx, function () { return 0; });   // 两层都置空气(色层 = 黑)
    }
  } else if (tool === 'rect') {
    idx = regionCells(map, {
      unit: from.kind,
      x0: Math.min(from.x, to.x), y0: Math.min(from.y, to.y),
      x1: Math.max(from.x, to.x), y1: Math.max(from.y, to.y),
    }, clip);
  } else if (tool === 'line') {
    idx = lineTargets(map, toSub(from), toSub(to), clip);
  }
  if (!idx) return null;
  return paintCells(map, L, idx, valueFor(st, L));
}

// ── 油漆桶:跨环面连通填充(A14)+ 可分帧驱动(闸 2)──
// 返回作业对象而不是一次性跑完:500×300 的地图跨环面时是 19.2 万格,同步跑完就是一次长阻塞。
function createBucketJob(map, L, X, Y, opts) {
  opts = opts || {};
  var arr = Render.layerArray(map, L);
  var cols = map.subCols, rows = map.subRows;
  var sx = Render.wrapIdx(Math.floor(X), cols), sy = Render.wrapIdx(Math.floor(Y), rows);
  var seedVal = arr ? arr[sy * cols + sx] : 0;
  var queue = [sy * cols + sx];
  var seen = new Set(queue);
  var out = [];
  var head = 0, done = false;
  function runChunk(maxSteps) {
    var n = 0;
    var lim = (maxSteps === undefined || maxSteps < 1) ? 1 : maxSteps;
    while (head < queue.length && n < lim) {
      var i = queue[head++];
      n++;
      out.push(i);
      var x = i % cols, y = Math.floor(i / cols);
      for (var k = 0; k < 4; k++) {
        var nx = Render.wrapIdx(x + (k === 0 ? 1 : k === 1 ? -1 : 0), cols);
        var ny = Render.wrapIdx(y + (k === 2 ? 1 : k === 3 ? -1 : 0), rows);
        var ni = ny * cols + nx;
        if (seen.has(ni)) continue;
        if (!inRect(opts.clip, nx, ny, cols, rows)) continue;   // 选区内外是两块互不连通的地
        if (arr && arr[ni] !== seedVal) continue;
        seen.add(ni); queue.push(ni);
      }
    }
    if (head >= queue.length) done = true;
    return { done: done, scanned: n, total: out.length };
  }
  return { runChunk: runChunk, result: function () { return out.slice(); } };
}

// ── 渐变(规格 §4.4:只在背景层)──
function lerpRGBA(v0, v1, t) {
  var a = v0 >>> 0, b = v1 >>> 0;
  var ch = function (shift) {
    var x = (a >>> shift) & 255, y = (b >>> shift) & 255;
    return Math.round(x + (y - x) * t) & 255;
  };
  return (((ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0)) >>> 0);
}
function createGradientJob(map, a, b, rgba0, rgba1, opts) {
  opts = opts || {};
  var L = (opts.layer === undefined) ? Core.LAYER_BG : opts.layer;
  if (L !== Core.LAYER_BG) {
    throw new Error('渐变只能用在背景层(规格 §4.4):实得图层 ' + L);
  }
  if (!Render.layerArray(map, L)) {
    throw new Error('这张图的背景层不存在(layer_flags 缺位),渐变无处可写');
  }
  var dx = Math.floor(b.x) - Math.floor(a.x), dy = Math.floor(b.y) - Math.floor(a.y);
  var ax = Math.floor(a.x), ay = Math.floor(a.y);
  var len2 = dx * dx + dy * dy;
  // ★★ 不预展开整张图:旧版在这里对全图调一次 regionCells(500×300 = 15 万条,外加一个
  //    同样大的 Set),作业还没开始分帧就先同步卡一帧。改成逐格推进,顺序仍是行主序
  //    (与"全图 regionCells"逐条相同 ⇒ result() 的次序不变),但第一块只算第一块。
  //    ★ 唯一的语义差异:scanned 数的是扫过的格(含被选区挡掉的),与油漆桶那边同口径。
  var cols = map.subCols, rows = map.subRows;
  var totalCells = cols * rows;
  var out = [];
  var head = 0, done = false;
  function runChunk(maxSteps) {
    var n = 0;
    var lim = (maxSteps === undefined || maxSteps < 1) ? 1 : maxSteps;
    while (head < totalCells && n < lim) {
      var X = head % cols, Y = (head - X) / cols;
      head++; n++;
      if (!inRect(opts.clip, X, Y, cols, rows)) continue;   // ★ 选区约束(与 regionCells 同一条判据)
      var t = len2 === 0 ? 0 : ((X - ax) * dx + (Y - ay) * dy) / len2;
      t = t < 0 ? 0 : (t > 1 ? 1 : t);
      out.push({ i: Y * cols + X, rgba: lerpRGBA(rgba0, rgba1, t) });
    }
    if (head >= totalCells) done = true;
    return { done: done, scanned: n, total: out.length };
  }
  return { runChunk: runChunk, result: function () { return out.slice(); } };
}
