// render/88_install_draw.js —— 坐标换算、① 的合成路径、网格/覆盖层/画布边框、唯一渲染入口与 resize/fit。
// ★ ② 那一簇(drawLayerPath / paintLayerRect / buildLayers)住在 86_install_layer_path.js。

// ⑫ 画布底色 = 游戏侧的「空气 / 清屏色」(#b0e5f6 = TerrainAtlas.SKY_COLOR,见 docs/eng/render.md)。
// "图外的空白"与"图内的空气格"必须同色,才谈得上所见即所得。★ 网格线必须同时改深色:浅底上白线看不见。
var CANVAS_BG = '#b0e5f6';
var GRID_SUB_LINE = 'rgba(0,0,0,0.14)';        // 子格线(16px)
var GRID_CELL_LINE = 'rgba(0,0,0,0.26)';       // 格线(64px)
var MAP_EDGE_LINE = 'rgba(84,160,255,0.55)';   // ⑪ 地图矩形边框(副本);与选区框 #e0b34a 刻意不同色
var MAP_EDGE_CUR = 'rgba(84,160,255,0.9)';     // 当前图([0,0] 那份)更亮:它才是"正在编辑的画布"

function installDraw(S) {
  var s = S.s, canvas = S.canvas, ctx = S.ctx, thumbs = S.thumbs;
  var stat = S.stat, stat2 = S.stat2, layerCv = S.layerCv, layerDirty = S.layerDirty;
  function screenToSub(px, py) {
    // ★ 还没打开地图时返回中性值(闸 1:用户输入钳制,不报错回滚)—— 指针事件比 setMap 早到是完全可能的,而这里抛错只会表现为"点了没反应"。
    if (!s.map) return { X: 0, Y: 0 };
    return hitTest(s.view, px, py, s.map.subCols, s.map.subRows);
  }
  function subToScreen(X, Y) {
    return { x: (X - s.view.x) * s.view.zoom, y: (Y - s.view.y) * s.view.zoom };
  }

  // ★★ torusList 由本簇产出、被 86 的 drawLayerPath 经 S.torusList 晚绑定取用(首轮漏了它,render_smoke 当场红)。
  // ★★ 固定 2×2(定义 A):当前图 + 右邻 + 下邻 + 右下邻。副本本身是冗余的(离屏层已按可见范围折叠,保证来自
  //    paintLayerRect 的环面折算),留它们只为"环面铺贴"这个交付面;而 ±1 的 3×3 在 fit 视图下**必然**铺 9 份
  //    (fit 取 min 缩放 ⇒ 两轴的世界范围恒大于地图),画布被副本盖满 ⇒ 画布边界彻底看不见(⑩/⑪)。
  function torusList(W, H) {
    if (!s.torus || !s.map) return [[0, 0]];
    var w = s.map.subCols, h = s.map.subRows;
    return [[0, 0], [w, 0], [0, h], [w, h]];
  }

  // 路径一:< 8 px/子格 走缩略图合成 —— 一次 drawImage 顶掉几十万次。
  function drawThumbPath(W, H) {
    var px = S.thumbPx;
    var scale = s.view.zoom / px;                  // 缩略图像素 → 屏幕像素
    var offs = torusList(W, H), i, L;
    for (i = 0; i < offs.length; i++) {
      for (var oi = 0; oi < DRAW_ORDER.length; oi++) {
        L = DRAW_ORDER[oi];
        if (!s.layerVisible[L] || !thumbs[L]) continue;
        ctx.globalAlpha = (s.dimOthers && L !== s.layer && L !== RenderCore.LAYER_BG) ? 0.4 : 1;
        ctx.drawImage(thumbs[L],
                      (offs[i][0] - s.view.x) * s.view.zoom,
                      (offs[i][1] - s.view.y) * s.view.zoom,
                      s.map.subCols * px * scale, s.map.subRows * px * scale);
      }
    }
    ctx.globalAlpha = 1;
  }

  // ④ 一格 = 2×2 个 32px 象限、每象限 2×2 子格。返回该象限的"多数纹理"(0 = 该象限全空;平票取小 id)——
  //    这就是游戏侧 flatten_scene 保留的那点信息(多数纹理 + 2×2 象限掩码),故象限之间"有没有内容 / 多数纹理不同"
  //    才是游戏里看得见的差异;同一象限内部 16px 或辅码的差异会被压掉,不算拆分。
  function quadMajorTex(arr, cols, bx, by, qx, qy) {
    var t = [0, 0, 0, 0], k, m, n, best = 0, bestN = 0;
    for (k = 0; k < 4; k++) {
      t[k] = (arr[(by + qy * 2 + (k >> 1)) * cols + bx + qx * 2 + (k & 1)] >>> 12) & 0xFFF;
    }
    for (k = 0; k < 4; k++) {
      if (t[k] === 0) continue;
      n = 0;
      for (m = 0; m < 4; m++) if (t[m] === t[k]) n++;
      if (n > bestN || (n === bestN && t[k] < best)) { best = t[k]; bestN = n; }
    }
    return best;
  }
  function cellIsSplit(arr, cols, cx, cy) {
    var bx = cx * SUB, by = cy * SUB, t0 = quadMajorTex(arr, cols, bx, by, 0, 0), qx, qy;
    for (qy = 0; qy < 2; qy++) {
      for (qx = 0; qx < 2; qx++) {
        if (qx === 0 && qy === 0) continue;
        if (quadMajorTex(arr, cols, bx, by, qx, qy) !== t0) return true;
      }
    }
    return false;
  }
  // 按格的缓存:内容版本号(③ 的 touch,编辑某格 +1)当失效键 —— 每帧对可见的几千格重算 16 次查表太贵。
  // ★ 缓存**按格**分配(cellsW × cellsH,不是子格数):400×300 格是 120KB,按子格数会是 1.9MB。
  // ★ 缓存同时钉住"层 / 层数组对象 / 格宽 / 格高":换图与 whole 差量会换掉 layers[L](防御性拷贝),那时一律重建;
  //   只判宽不判高会让"同宽更高"的图沿用短数组,Uint8Array 的越界写**不抛**(静默丢),子格线就不再出现。
  var splitL = -1, splitArr = null, splitW = 0, splitH = 0, splitFlags = null, splitVer = null;
  function cachedSplit(L, arr, cx, cy) {
    var cols = s.map.subCols, cw = cols / SUB, ch = s.map.subRows / SUB, i, v;
    if (splitL !== L || splitArr !== arr || splitW !== cw || splitH !== ch) {
      splitL = L; splitArr = arr; splitW = cw; splitH = ch;
      splitFlags = new Uint8Array(cw * ch);
      splitVer = new Int32Array(cw * ch);
    }
    i = cy * cw + cx;
    v = S.cellCache ? S.cellCache.version(L, cx, cy) : 0;
    if (splitFlags[i] !== 0 && splitVer[i] === v) return splitFlags[i] === 1;
    splitFlags[i] = cellIsSplit(arr, cols, cx, cy) ? 1 : 2;
    splitVer[i] = v;
    return splitFlags[i] === 1;
  }

  // ★ 子格线:阈值 zoom ≥ 4 是本文件自己的选择(4 px/子格时线还分得开,再稀只是噪点);判据从"整屏铺满"改成
  //   "只画被拆分的格"(④),且只看当前层 —— 背景层是逐子格 RGBA 渐变,没有"纹理拆分",一律不画。
  // ★ 网格线与地图矩形求交后再画:图外属于画布之外,一根线都不该有(⑪ 之前它一直画到画布边缘,
  //   于是"网格停在哪 = 图到哪"这条最廉价的线索也一起丢了)。
  function drawGrid(W, H) {
    var z = s.view.zoom, cols = s.map.subCols, rows = s.map.subRows;
    var r = visibleSubRange(s.view, W, H, cols, rows);
    var x0 = Math.max(r.x0, 0), x1 = Math.min(r.x1, cols);
    var y0 = Math.max(r.y0, 0), y1 = Math.min(r.y1, rows);
    if (x1 <= x0 || y1 <= y0) return;                        // 可见区完全在图外
    var sxL = (x0 - s.view.x) * z, sxR = (x1 - s.view.x) * z;
    var syT = (y0 - s.view.y) * z, syB = (y1 - s.view.y) * z;
    ctx.lineWidth = 1;
    var arr = s.subGrid && z >= 4 && !layerIsColor(s.layer) ? layerArray(s.map, s.layer) : null;
    if (arr) {
      ctx.strokeStyle = GRID_SUB_LINE;
      ctx.beginPath();
      for (var cy = Math.floor(y0 / SUB); cy * SUB < y1; cy++) {
        for (var cx = Math.floor(x0 / SUB); cx * SUB < x1; cx++) {
          if (!cachedSplit(s.layer, arr, cx, cy)) continue;
          var cxs = cx * SUB, cys = cy * SUB;
          var vy0 = (Math.max(cys, y0) - s.view.y) * z, vy1 = (Math.min(cys + SUB, y1) - s.view.y) * z;
          var hx0 = (Math.max(cxs, x0) - s.view.x) * z, hx1 = (Math.min(cxs + SUB, x1) - s.view.x) * z;
          for (var k = 1; k < SUB; k++) {
            if (cxs + k > x0 && cxs + k < x1) {
              var sxk = Math.round((cxs + k - s.view.x) * z) + 0.5;
              ctx.moveTo(sxk, vy0); ctx.lineTo(sxk, vy1);
            }
            if (cys + k > y0 && cys + k < y1) {
              var syk = Math.round((cys + k - s.view.y) * z) + 0.5;
              ctx.moveTo(hx0, syk); ctx.lineTo(hx1, syk);
            }
          }
        }
      }
      ctx.stroke();
    }
    ctx.strokeStyle = GRID_CELL_LINE;                       // 格线(64px = 4 个子格)
    ctx.beginPath();
    for (var X2 = Math.ceil(x0 / SUB) * SUB; X2 <= x1; X2 += SUB) {
      var sx2 = Math.round((X2 - s.view.x) * z) + 0.5;
      ctx.moveTo(sx2, syT); ctx.lineTo(sx2, syB);
    }
    for (var Y2 = Math.ceil(y0 / SUB) * SUB; Y2 <= y1; Y2 += SUB) {
      var sy2 = Math.round((Y2 - s.view.y) * z) + 0.5;
      ctx.moveTo(sxL, sy2); ctx.lineTo(sxR, sy2);
    }
    ctx.stroke();
  }

  // ⑪ 画布范围:按 torusList 的每份副本给地图矩形画 1~2px 边框。环面开着时屏幕每一处都是地图内容
  //    (副本 + 离屏层的折算),没有任何像素属于"图外" ⇒ 边框是唯一能说出"画布到哪结束"的东西。
  function drawMapBounds(W, H) {
    if (!s.map) return;
    var offs = torusList(W, H), z = s.view.zoom;
    var wpx = Math.round(s.map.subCols * z), hpx = Math.round(s.map.subRows * z);
    for (var i = 0; i < offs.length; i++) {
      var p = subToScreen(offs[i][0], offs[i][1]);
      if (p.x > W || p.y > H || p.x + wpx < 0 || p.y + hpx < 0) continue;
      ctx.strokeStyle = (i === 0) ? MAP_EDGE_CUR : MAP_EDGE_LINE;
      ctx.lineWidth = (i === 0) ? 2 : 1;
      ctx.strokeRect(Math.round(p.x), Math.round(p.y), wpx, hpx);
    }
    ctx.lineWidth = 1;
  }

  // 半区中线 + 3×3 桶网格:游戏侧"均匀散布"判据的对照物(侧 1 = 左半、侧 2 = 右半,每半 3 列 × 3 行)。
  // ★ 只在 guides 打开时画 —— 它是辅助线,不是地图内容。
  function drawGuides(W, H) {
    if (!s.map || !s.guides) return;
    var z = s.view.zoom;
    var cols = s.map.subCols / SUB, rows = s.map.subRows / SUB;
    var offs = torusList(W, H);
    ctx.save();
    ctx.lineWidth = 1;
    for (var i = 0; i < offs.length; i++) {
      var ox = offs[i][0] / SUB, oy = offs[i][1] / SUB;   // 副本偏移换成"格"
      // 3×3 桶(每半区 3 列 × 3 行)
      ctx.strokeStyle = 'rgba(0,0,0,0.18)';
      ctx.setLineDash([4, 4]);
      ctx.beginPath();
      for (var b = 1; b < 3; b++) {
        var xl = subToScreen((ox + cols / 2 / 3 * b) * SUB, 0);
        var xr = subToScreen((ox + cols / 2 + cols / 2 / 3 * b) * SUB, 0);
        if (xl.x > -1 && xl.x < W + 1) { ctx.moveTo(xl.x, 0); ctx.lineTo(xl.x, H); }
        if (xr.x > -1 && xr.x < W + 1) { ctx.moveTo(xr.x, 0); ctx.lineTo(xr.x, H); }
        var yb = subToScreen(0, (oy + rows / 3 * b) * SUB);
        if (yb.y > -1 && yb.y < H + 1) { ctx.moveTo(0, yb.y); ctx.lineTo(W, yb.y); }
      }
      ctx.stroke();
      ctx.setLineDash([]);
      // 半区中线(更实、更暗)
      var mid = subToScreen((ox + cols / 2) * SUB, 0);
      ctx.strokeStyle = 'rgba(0,0,0,0.45)';
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(mid.x, 0); ctx.lineTo(mid.x, H);
      ctx.stroke();
      ctx.lineWidth = 1;
    }
    ctx.restore();
  }

  // spawn / 复活点标记 + 选区框。★ 字体/对齐设一次(每标记重设 font 是排版最贵的一项)。
  function drawOverlay(W, H) {
    if (!s.map) return;
    ctx.save();
    ctx.font = '12px Consolas, monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    var offs = torusList(W, H);
    var mark = function (cellX, cellY, color, label) {
      for (var i = 0; i < offs.length; i++) {
        // ★ offs 是"副本的世界偏移"(2×2 全是非负),所以标记要 **加** 上去;减号是 3×3 时代的写法(那时偏移是 -1/0/+1),留着会让标记往反方向漂到空地上。
        var X = cellX * SUB + offs[i][0], Y = cellY * SUB + offs[i][1];
        var p = subToScreen(X, Y);
        if (p.x < -64 || p.y < -64 || p.x > W + 64 || p.y > H + 64) continue;
        ctx.fillStyle = color;
        ctx.globalAlpha = 0.75;
        ctx.fillRect(p.x, p.y, 4 * s.view.zoom, 4 * s.view.zoom);
        ctx.globalAlpha = 1;
        ctx.fillStyle = '#000';
        ctx.fillText(label, p.x + 2 * s.view.zoom, p.y + 2 * s.view.zoom);
      }
    };
    for (var i = 0; i < s.map.players.length; i++) {
      mark(s.map.players[i].x, s.map.players[i].y, '#1f6feb', 'P' + (i + 1));
    }
    for (var j = 0; j < s.map.enemies.length; j++) {
      mark(s.map.enemies[j].x, s.map.enemies[j].y, '#8a2f6b', 'E');
    }
    // ★ 按侧复活点(侧 1 深绿 / 侧 2 深橙;浅底上要够暗才看得见)
    var rs = s.map.respawns || [];
    for (var ri = 0; ri < rs.length; ri++) {
      mark(rs[ri].x, rs[ri].y, rs[ri].side === 1 ? '#1a7f37' : '#b45309', 'R' + rs[ri].side);
    }
    if (s.preview) {
      var pv = subToScreen(s.preview.x, s.preview.y);
      ctx.setLineDash([6, 4]);
      ctx.strokeStyle = '#54a0ff';
      ctx.lineWidth = 1;
      ctx.strokeRect(pv.x, pv.y, s.preview.w * s.view.zoom, s.preview.h * s.view.zoom);
      ctx.setLineDash([]);
    }
    if (s.selection) {
      // ★ 拖动中框按偏移后的位置画(数据还没动 —— 松手才 moveRegion);这是拖动过程中唯一看得见的反馈,setSelDrag 只调 render()。
      // ★★ 末尾那句 || (s.selDrag ? s.selDrag.sel : null) 是防御性、今天不可达(外层判据就在上一行):放松外层会让选区为空时画出一个框,正是 render_smoke 相位 ⑬h 那条"选区为空时不画框"要禁止的,故它不是一条活路径。
      var base = s.selection || (s.selDrag ? s.selDrag.sel : null);
      var sel = (base && s.selDrag)
        ? { x: base.x + s.selDrag.dx, y: base.y + s.selDrag.dy, w: base.w, h: base.h }
        : base;
      if (sel) {
        var a = subToScreen(sel.x, sel.y);
        ctx.strokeStyle = '#e0b34a';
        ctx.lineWidth = 2;
        ctx.strokeRect(a.x, a.y, sel.w * s.view.zoom, sel.h * s.view.zoom);
      }
    }
    ctx.restore();
  }

  // ★ 唯一渲染入口:同一帧只许画一次画布。
  // ★★ 三条路径按 zoom 分工:① 缩略图(< 8)、② 视口离屏层(≥ 8);而合成那一步(层可见性/压暗/2×2 副本)两条路都走 ⇒ "切层"只是重新合成,永远不重画任何一层。
  // ★★ 换图之后的唯一收口也在这里:①② 的像素全是按旧图集算出来的,而它们只可能被这一条路合成到屏幕上 ⇒ 在唯一入口上作废既不会漏、也不会白付。★ 本帧不画:上一次的画面留在屏幕上,重建落地后由它自己的 .then(render) 画。
  function render() {
    if (!s.map) return;
    if (S.atlasSync) { S.syncAtlas(); return; }
    var W = canvas.width, H = canvas.height;
    var t0 = S.nowMs();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.fillStyle = CANVAS_BG;
    ctx.fillRect(0, 0, W, H);
    if (zoomPath(s.view.zoom) === 'thumb') drawThumbPath(W, H); else S.drawLayerPath(W, H);
    if (s.grid) drawGrid(W, H);
    drawMapBounds(W, H);                         // ★ 画布范围画在网格之上、标记/选区之下(选区框要压住边框)
    drawGuides(W, H);                            // 半区中线 + 3×3 桶(guides 关着时直接 return)
    drawOverlay(W, H);
    stat.renders++;
    stat.lastRenderMs = S.nowMs() - t0;
    stat2.cellsHits = S.cellCache ? S.cellCache.stats().hits : 0;        // ★ ③ 的记账随 render 同步一份(状态栏/自检读 stats(),不必自己去问 ③)
    stat2.cellsMisses = S.cellCache ? S.cellCache.stats().misses : 0;
    stat2.cellsSize = S.cellCache ? S.cellCache.stats().size : 0;
  }

  // ★ 尺寸变化只有一个机制(ResizeObserver 与 window.resize 同时挂 = 每次 resize 建两遍)
  function resize() {
    var wrap = canvas.parentElement;
    var w = Math.max(1, wrap ? wrap.clientWidth : canvas.width);
    var h = Math.max(1, wrap ? wrap.clientHeight : canvas.height);
    if (canvas.width === w && canvas.height === h) return;
    canvas.width = w; canvas.height = h;
    ctx.imageSmoothingEnabled = false;            // ★ 改尺寸会重置 ctx 状态,必须重设
    // ★★ 离屏层的像素是按旧画布尺寸铺的 ⇒ 尺寸一改整片失效,旧画布必须丢掉:留着的话 drawLayerPath 会把它按新目标框画出去(整层错位),而"只标脏"也不行(脏矩形只补一小块、其余留白)。丢掉之后由 buildLayers 分帧重来。
    for (var L = 0; L < RenderCore.LAYER_COUNT; L++) { layerCv[L] = null; layerDirty[L] = null; }
    S.viewChanged();
    if (s.map && zoomPath(s.view.zoom) === 'layers') return S.observed('resize', S.buildLayers().then(render));
    render();
  }

  function fit() {
    if (!s.map) return;
    s.view.zoom = fitZoom(s.map.subCols, s.map.subRows, canvas.width, canvas.height, 24);
    s.view.x = -(canvas.width / s.view.zoom - s.map.subCols) / 2;
    s.view.y = -(canvas.height / s.view.zoom - s.map.subRows) / 2;
    S.viewChanged();                             // ★ 适配改的是 zoom ⇒ 每个子格多少像素都变了,离屏层整片失效(全屏重建,闸 2 分帧)
    if (zoomPath(s.view.zoom) === 'layers') return S.observed('fit', S.buildLayers().then(render));
    render();
  }

  S.screenToSub = screenToSub;
  S.subToScreen = subToScreen;
  S.torusList = torusList;
  S.render = render;
  S.resize = resize;
  S.fit = fit;
}
