// render/92_install_edit.js —— 编辑/换图/视图操作簇:脏区记账、整片重建、平移与缩放。

function installEdit(S) {
  var s = S.s, canvas = S.canvas, thumbs = S.thumbs;
  var layerCv = S.layerCv, layerDirty = S.layerDirty, stat2 = S.stat2;
  function invalidateCells(L, list) {           // 编辑某几个格之后:重画它们的缩略图块(Uint32Array 的下标 → 格坐标)
    if (!s.map) return null;
    var rect = null;
    for (var i = 0; i < list.length; i++) {
      var r = { x: list[i].cx * SUB, y: list[i].cy * SUB, w: SUB, h: SUB };
      rect = rectUnion(rect, r);
    }
    if (!rect) return null;
    if (thumbs[L]) S.paintThumbRect(L, rect);
    return rect;
  }
  function invalidateAll() {
    if (!s.map) return Promise.resolve();
    // ★★ 先让缩略图的尺寸对齐当前图:本方法是一条公开入口,而它此前不经过 ensureThumbs —— 调用方完全可能在"改了 s.map 的尺寸"之后直接进来(撤销/重做一条 kind='whole' 的差量就是这么把 subCols/subRows 就地改掉的)。
    //    少了这一步,paintThumbRect 会往画布外写(被静默裁掉)、drawThumbPath 又会把那张旧画布拉伸到新尺寸的目标框里。只有本方法配得起这一步:它紧接着把整张重画一遍,不会留下半张空白。
    S.ensureThumbs(s.map);
    // ★★ ② 的离屏层同样是"按内容铺的位图":整张图变了(或是尺寸变了)之后它们一个像素都不再成立 ⇒ 与缩略图一起整片重建(丢弃 + 分帧重来)。
    //    只 render() 的话,≥8 px/子格 那条路上会继续显示改动前的内容(缩略图对了、放大之后不对 —— 而"放大才看得见"正是这条路径的常态)。
    for (var L = 0; L < RenderCore.LAYER_COUNT; L++) { layerCv[L] = null; layerDirty[L] = null; }
    S.viewChanged();
    return S.observed('invalidateAll', S.buildThumbs().then(function () {
      return (zoomPath(s.view.zoom) === 'layers') ? S.buildLayers() : null;
    }).then(S.render));
  }

  // ★★ 换图之后 ①② 的整片重来,在下一次 render() 里落地:② 的画布与 ① 的位图都直接丢掉(留着就会被当"这一层的画面"合成上去,而"新旧混着"比"空一会儿"难查得多),重画一律经 buildThumbs / buildLayers 走分帧器。
  function syncAtlas() {
    S.atlasSync = false;
    for (var L = 0; L < RenderCore.LAYER_COUNT; L++) {
      layerCv[L] = null; layerDirty[L] = null; thumbs[L] = null;
    }
    S.viewChanged();
    S.ensureThumbs(s.map);
    return S.observed('setAtlas', S.buildThumbs().then(function () {
      return (zoomPath(s.view.zoom) === 'layers') ? S.buildLayers() : null;
    }).then(S.render));
  }

  function setMap(map) {
    s.map = map;
    s.selection = null;
    S.ensureThumbs(map);
    S.cellCache = createCellCache({ maxCells: DEFAULT_CELL_MAX, build: S.buildCell });   // ★ 换图 = 内容全变:③ 必须整片重建(旧的格位图属于上一张图,连键都可能相同)
    attachCells(S.cellCache);
    for (var L = 0; L < RenderCore.LAYER_COUNT; L++) { layerCv[L] = null; layerDirty[L] = null; }   // ★ ② 同理:旧离屏层画的是上一张图,连尺寸都可能不同 ⇒ 丢掉重来
    S.viewChanged();                                  // 在飞的那一轮重建画的是上一张图 ⇒ 作废
    return S.observed('setMap', S.buildThumbs().then(function () {
      s.view.zoom = fitZoom(map.subCols, map.subRows, canvas.width, canvas.height, 24);
      s.view.x = -(canvas.width / s.view.zoom - map.subCols) / 2;
      s.view.y = -(canvas.height / s.view.zoom - map.subRows) / 2;
      // ★ 适配之后落在缩略图路径(< 8)时不建离屏层:大图一上来就白画一屏(它是分帧的,但那几帧白费);等真放大到 ≥8 时 setZoomAt 会建。③ 与 ① 不受影响。
      return (zoomPath(s.view.zoom) === 'layers') ? S.buildLayers() : null;
    }).then(S.render));
  }

  // 把脏矩形裁到主网格(单位 = 子格)。★ 这是守卫而不是必需:编辑永远落在 [0, 子格数) 里,越界的脏矩形(将来的调用方算错)不该让离屏层去画一片莫名其妙的东西。
  function clipped(r) {
    if (!r) return null;
    var x0 = Math.max(0, r.x), y0 = Math.max(0, r.y);
    var x1 = Math.min(s.map.subCols, r.x + r.w), y1 = Math.min(s.map.subRows, r.y + r.h);
    if (x1 <= x0 || y1 <= y0) return null;
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  }

  // ★★ 编辑之后的唯一入口:三件事一次做完(① ③ 的 touch ② ② 的脏矩形 ③ ① 的缩略图块),否则总有一层忘了作废。
  //    颜色层不进 ③(它的内容是 RGBA,不是 tile 引用),"内容版本号"就是地图数组本身,重画由脏矩形负责。
  var dirtySet = createDirtySet();
  function editCells(L, list) {
    if (!s.map || !list || !list.length) return;
    var colorLayer = layerIsColor(L);
    for (var i = 0; i < list.length; i++) {
      if (!colorLayer) S.cellCache.touch(L, list[i].cx, list[i].cy);
      dirtySet.addCell(L, list[i].cx, list[i].cy);
    }
    var box = dirtySet.rect();
    dirtySet.clear();
    if (!box) return;
    var inner = clipped(box);                     // ★ 脏矩形只对这一层有意义:③ 的版本号是每格一条,而"这一层要不要重画"只需要一个上界
    if (inner && layerArray(s.map, L)) layerDirty[L] = rectUnion(layerDirty[L], inner);
    invalidateCells(L, list);                       // ①(缩略图那块矩形)
    S.render();
  }

  // ★★ panBy 的单位是画布像素、方向是视图/世界的位移(view.x 增加 dxPx/zoom),而内容是反向搬移的(向右看 = 画面往左走)⇒ 自拷贝的偏移取负,与 panStrips 的"新露出来的边条"严格互补。
  function panBy(dxPx, dyPx) {
    if (!s.map) return;
    if (!isFinite(dxPx)) dxPx = 0;
    if (!isFinite(dyPx)) dyPx = 0;
    // ★★ 位移先量化到整像素:自拷贝是 drawImage,而插值关掉之后光栅器会把它的偏移吸附到整像素,s.view 却按精确值前进 ⇒ 每次平移最多差 0.5px 且会累积 —— 边条只补"新露出来的那一条",永远不纠正已攒下的偏差,内容是"慢慢从网格/覆盖层上漂走"。
    //    ★ view / panStrips / 自拷贝三者必须同源,故在这里一次量化;代价照实说:不足 1px 的平移被丢弃(0.4px 走十次 = 一步都不动),这是刻意的 —— 与闸 1 的口径一致(钳制,不报错、不回滚)。
    dxPx = Math.round(dxPx); dyPx = Math.round(dyPx);
    if (dxPx === 0 && dyPx === 0) return;
    var W = canvas.width, H = canvas.height;
    s.view.x += dxPx / s.view.zoom;
    s.view.y += dyPx / s.view.zoom;
    if (zoomPath(s.view.zoom) !== 'layers') { S.render(); return; }
    // ★★ 视图一动,在飞的那一轮重建(条带按旧视图算的)就不能再往这些画布上写 —— 而"自拷贝搬移"又要求整张图属于同一次视图 ⇒ 不干净时老实走整片重建(分帧)。
    if (!S.layersClean) return S.observed('panBy', S.buildLayers().then(S.render));
    if (Math.abs(dxPx) >= W || Math.abs(dyPx) >= H) { S.viewChanged(); return S.observed('panBy', S.buildLayers().then(S.render)); }   // ★ 位移大到整块都被换掉时,自拷贝已经没有意义
    var strips = panStrips(W, H, dxPx, dyPx);
    for (var L = 0; L < RenderCore.LAYER_COUNT; L++) {
      var cv = layerCv[L];
      if (!cv || cv.width !== W || cv.height !== H) continue;
      var c = cv.getContext('2d');
      c.globalCompositeOperation = 'copy';
      c.drawImage(cv, -dxPx, -dyPx);
      c.globalCompositeOperation = 'source-over';
      for (var i = 0; i < strips.length; i++) {
        var st = strips[i];
        var wx = s.view.x + st.x / s.view.zoom, wy = s.view.y + st.y / s.view.zoom;   // 边条对应的世界矩形:像素 → 子格(补画按新视图换算,与搬移后的像素对齐)
        S.paintLayerRect(L, { x: wx, y: wy, w: st.w / s.view.zoom, h: st.h / s.view.zoom });
      }
    }
    stat2.panCopies++;
    S.render();
  }

  // ★ 以光标为锚缩放(滚轮):缩放改变的是"每个子格多少像素" ⇒ 离屏层所有内容失效,只能整片重建(闸 2 分帧 —— 大图上是"慢慢画出来",不是"页面死掉")。
  function setZoomAt(px, py, factor) {
    var v = zoomAround(s.view, px, py, factor);
    s.view.x = v.x; s.view.y = v.y; s.view.zoom = v.zoom;
    S.viewChanged();
    if (!s.map || zoomPath(s.view.zoom) !== 'layers') { S.render(); return Promise.resolve(); }
    return S.observed('setZoomAt', S.buildLayers().then(S.render));
  }

  S.invalidateCells = invalidateCells;
  S.invalidateAll = invalidateAll;
  S.syncAtlas = syncAtlas;
  S.setMap = setMap;
  S.editCells = editCells;
  S.panBy = panBy;
  S.setZoomAt = setZoomAt;
}
