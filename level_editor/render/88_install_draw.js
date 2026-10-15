// render/88_install_draw.js —— 坐标换算、① 的合成路径、网格/覆盖层、唯一渲染入口与 resize/fit。
// ★ ② 那一簇(drawLayerPath / paintLayerRect / buildLayers)住在 86_install_layer_path.js。

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

  // ★★ torusList 由本簇产出、被 86 的 drawLayerPath 经 S.torusList 晚绑定取用(首轮漏了它,render_smoke 当场红)。关掉环面时只画一份:副本本来就是冗余的,保证来自 paintLayerRect 的折算而不是它们。
  function torusList(W, H) {
    if (!s.torus) return [[0, 0]];
    return torusOffsets(s.view, W, H, s.map.subCols, s.map.subRows);
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

  // ★ 子格线只在 zoom ≥ 4 时画:阈值 4 是本文件自己的选择(4 px/子格时一个子格还有 4 个屏幕像素、线还分得开,再稀就只是给画面加噪点),不是规格里的数字。只画可见区(不裁剪 = 每次重画整张图的线)。
  function drawGrid(W, H) {
    var r = visibleSubRange(s.view, W, H, s.map.subCols, s.map.subRows);
    var z = s.view.zoom;
    ctx.lineWidth = 1;
    ctx.strokeStyle = 'rgba(255,255,255,0.16)';
    ctx.beginPath();
    if (s.subGrid && z >= 4) {
      for (var X = Math.floor(r.x0 / 1); X <= r.x1; X++) {
        var sx = Math.round((X - s.view.x) * z) + 0.5;
        if (sx < -1 || sx > W + 1) continue;
        ctx.moveTo(sx, 0); ctx.lineTo(sx, H);
      }
      for (var Y = r.y0; Y <= r.y1; Y++) {
        var sy = Math.round((Y - s.view.y) * z) + 0.5;
        if (sy < -1 || sy > H + 1) continue;
        ctx.moveTo(0, sy); ctx.lineTo(W, sy);
      }
    }
    ctx.stroke();
    ctx.strokeStyle = 'rgba(255,255,255,0.30)';   // 格线(64px = 4 个子格)
    ctx.beginPath();
    for (var X2 = Math.floor(r.x0 / SUB) * SUB; X2 <= r.x1; X2 += SUB) {
      var sx2 = Math.round((X2 - s.view.x) * z) + 0.5;
      if (sx2 < -1 || sx2 > W + 1) continue;
      ctx.moveTo(sx2, 0); ctx.lineTo(sx2, H);
    }
    for (var Y2 = Math.floor(r.y0 / SUB) * SUB; Y2 <= r.y1; Y2 += SUB) {
      var sy2 = Math.round((Y2 - s.view.y) * z) + 0.5;
      if (sy2 < -1 || sy2 > H + 1) continue;
      ctx.moveTo(0, sy2); ctx.lineTo(W, sy2);
    }
    ctx.stroke();
  }

  // spawn 标记 + 选区框。★ 字体/对齐设一次(每标记重设 font 是排版最贵的一项)。
  function drawOverlay(W, H) {
    if (!s.map) return;
    ctx.save();
    ctx.font = '12px Consolas, monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    var offs = torusList(W, H);
    var mark = function (cellX, cellY, color, label) {
      for (var i = 0; i < offs.length; i++) {
        var X = cellX * SUB - offs[i][0], Y = cellY * SUB - offs[i][1];
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
      mark(s.map.players[i].x, s.map.players[i].y, '#54a0ff', 'P' + (i + 1));
    }
    for (var j = 0; j < s.map.enemies.length; j++) {
      mark(s.map.enemies[j].x, s.map.enemies[j].y, '#c96fb0', 'E');
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
  // ★★ 三条路径按 zoom 分工:① 缩略图(< 8)、② 视口离屏层(≥ 8);而合成那一步(层可见性/压暗/3×3 副本)两条路都走 ⇒ "切层"只是重新合成,永远不重画任何一层。
  // ★★ 换图之后的唯一收口也在这里:①② 的像素全是按旧图集算出来的,而它们只可能被这一条路合成到屏幕上 ⇒ 在唯一入口上作废既不会漏、也不会白付。★ 本帧不画:上一次的画面留在屏幕上,重建落地后由它自己的 .then(render) 画。
  function render() {
    if (!s.map) return;
    if (S.atlasSync) { S.syncAtlas(); return; }
    var W = canvas.width, H = canvas.height;
    var t0 = S.nowMs();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.fillStyle = '#0e1013';
    ctx.fillRect(0, 0, W, H);
    if (zoomPath(s.view.zoom) === 'thumb') drawThumbPath(W, H); else S.drawLayerPath(W, H);
    if (s.grid) drawGrid(W, H);
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
