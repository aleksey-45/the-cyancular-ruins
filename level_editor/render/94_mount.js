// render/94_mount.js —— 画布挂载入口:建共享状态 + 按序装上六簇 + 交出公开面。

function mount(canvas, opts) {                // ★ opts.slicer 是注入缝(与 setAtlas 的 opts.backend / createSlicer 的 opts.now 同款):浏览器里不传,node 冒烟传一个确定的 nextFrame,否则那座分帧器在 node 里会去碰不存在的 requestAnimationFrame
  var S = createMountState(canvas, opts);
  installErrors(S); installThumbs(S); installLayerPath(S);
  installDraw(S); installDrag(S); installEdit(S);
  return {
    setMap: S.setMap, map: function () { return S.s.map; },
    // ★ 切层 = 拖动预览的烤点换了一层(偏移只烤在活动层上,见 dragSource / markDragDirty):旧层那批偏移像素要擦、新层要烤。数字键 1-4 在拖动途中照样按得下去。
    setLayer: function (L) { S.s.layer = L; S.markDragDirty(); S.render(); }, layer: function () { return S.s.layer; },
    setView: function (v) {
      S.s.view.x = v.x; S.s.view.y = v.y;
      S.s.view.zoom = clampZoom(v.zoom === undefined ? S.s.view.zoom : v.zoom);
      // ★ 换视图 = 离屏层整片失效;平移请走 panBy(它是像素级搬移,只补边条),本方法留给"跳到某个视图"这种整片换的场合。
      S.viewChanged();
      if (S.s.map && zoomPath(S.s.view.zoom) === 'layers') return S.observed('setView', S.buildLayers().then(S.render));
      S.render();
    },
    view: function () { return { x: S.s.view.x, y: S.s.view.y, zoom: S.s.view.zoom }; },
    setGrid: function (b) { S.s.grid = !!b; S.render(); },
    setSubGrid: function (b) { S.s.subGrid = !!b; S.render(); },
    setTorus: function (b) { S.s.torus = !!b; S.render(); },
    setDimOthers: function (b) { S.s.dimOthers = !!b; S.render(); },
    setLayerVisible: function (L, b) { S.s.layerVisible[L] = !!b; S.render(); },   // ★ 可见性只影响合成(离屏内容照旧保留)⇒ 开关是 4 次 drawImage 的事,不重画任何一层
    layerVisible: function (L) { return S.s.layerVisible[L]; },
    setLayerLocked: function (L, b) { S.s.layerLocked[L] = !!b; },
    layerLocked: function (L) { return S.s.layerLocked[L]; },
    // ★★ 选区一变也要去烤:Esc 取消选区时左键还按着(selDrag 还在)是合法状态。但这一句 markDragDirty() 单独并不足以让内容归位 ——
    //    它只负责把烤过的那几块重画一遍,重画画出来的是什么由 dragSource 决定:选区空掉之后 dragSource 的早退(判据里含 !s.selection)才让它一律读原格。两半合起来才是"选区为空 ⇒ 内容当场归位"。
    setSelection: function (sel) { S.s.selection = sel; S.markDragDirty(); S.render(); },
    selection: function () { return S.s.selection; },
    setSelDrag: S.setSelDrag, setPreview: S.setPreview,
    isDraggingSelection: function () { return !!S.s.selDrag; },
    render: S.render, resize: S.resize, fit: S.fit,
    invalidateCells: S.invalidateCells, invalidateAll: S.invalidateAll,
    editCells: S.editCells, panBy: S.panBy, setZoomAt: S.setZoomAt, buildLayers: S.buildLayers,
    cells: function () { return S.cellCache; },
    // ★ 报错通道是可换的:默认写页面状态栏(= ui.js 的 status() 那条通道),页面/探针可以换掉它做断言或接自己的日志。传非函数则回落默认。
    setErrorSink: function (fn) { S.errorSink = (typeof fn === 'function') ? fn : S.defaultErrorSink; },
    thumbCanvas: function (L) { return S.thumbs[L]; },
    thumbPx: function () { return S.thumbPx; },
    screenToSub: S.screenToSub, subToScreen: S.subToScreen,
    stats: function () {
      return { thumbMs: S.stat.thumbMs, renders: S.stat.renders, lastRenderMs: S.stat.lastRenderMs,
               thumbsBuilt: S.stat.thumbsBuilt, cellsHits: S.stat2.cellsHits, cellsMisses: S.stat2.cellsMisses,
               cellsSize: S.stat2.cellsSize, layerRebuilds: S.stat2.layerRebuilds,
               layerRebuildMs: S.stat2.layerRebuildMs, panCopies: S.stat2.panCopies };
    },
  };
}
