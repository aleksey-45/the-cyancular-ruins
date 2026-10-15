// render/99_exports.js —— 公开 API 表。改这里等于改公开接口。


globalThis.Render = {
  MIN_ZOOM: MIN_ZOOM, MAX_ZOOM: MAX_ZOOM, ZOOM_THRESHOLD: ZOOM_THRESHOLD,
  THUMB_PX: THUMB_PX, THUMB_MAX_BYTES: THUMB_MAX_BYTES,
  DEFAULT_BUDGET_MS: DEFAULT_BUDGET_MS, DEFAULT_CELL_MAX: DEFAULT_CELL_MAX,
  wrapIdx: wrapIdx, quadOf: quadOf,
  layerArray: layerArray, descAt: descAt, rgbaAt: rgbaAt,
  setAtlas: setAtlas, atlasInfo: atlasInfo, atlasCapacity: atlasCapacity, tileCache: tileCache,
  attachCells: attachCells, cellCache: cellCache, attachViewInvalidator: attachViewInvalidator,
  tileFor: tileFor,
  createCellCache: createCellCache,
  createSlicer: createSlicer,
  zoomPath: zoomPath, clampZoom: clampZoom, fitZoom: fitZoom, thumbScale: thumbScale,
  visibleSubRange: visibleSubRange, torusOffsets: torusOffsets, hitTest: hitTest,
  MAX_BRUSH_CELLS: MAX_BRUSH_CELLS, brushSpan: brushSpan, brushRegion: brushRegion, snapHit: snapHit,
  selectionSource: selectionSource, inSel: inSel,
  rectUnion: rectUnion, rectIsEmpty: rectIsEmpty,
  createDirtySet: createDirtySet, panStrips: panStrips, zoomAround: zoomAround,
  DRAW_ORDER: DRAW_ORDER, mount: mount,
};
