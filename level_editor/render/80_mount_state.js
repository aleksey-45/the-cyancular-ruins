// render/80_mount_state.js —— mount 的共享状态 S:安装器之间唯一的共享通道,安装期只登记不互调;换图时 ①② 的作废也由这里登记一个只记账的作废器。

// ★★ 契约:会被重新赋值的标量(thumbPx / atlasSync / errorSink / cellCache / layersClean)一律挂在这里、跨簇读写只能走 S.xxx,不许把它们当安装器的参数传 —— 函数在安装那一刻就捕获了一份旧值,之后别的簇重赋值它,读到的还是旧的。对象/数组(ctx / s / thumbs / layerCv / stat / stat2)的引用本身不会换,故各安装器开头就地取别名即可。
// ★★ ② 的像素坐标系定义(整个 ② 靠它):离屏层像素 (px,py) ↔ 世界子格 (view.x + px/zoom, view.y + py/zoom) —— 与屏幕同一套。
//    于是平移 = 像素级自拷贝搬移 + 只补新露出的边条,3×3 副本 = 把同一张图按「副本世界偏移 × zoom」平移后再画一次。★ 绝不建全图离屏:500×300 子格按 16px 是 8000×4800 = 153MB,浏览器会直接拒绝。
function createMountState(canvas, opts) {
  opts = opts || {};
  var ctx = canvas.getContext('2d');
  ctx.imageSmoothingEnabled = false;      // ★ 主 ctx 不关插值 ⇒ 放大后砖块是糊的(离屏层同此)
  var S = {
    canvas: canvas, opts: opts, ctx: ctx,
    s: {
      map: null, layer: RenderCore.LAYER_SCENE,
      view: { x: 0, y: 0, zoom: 8 },
      grid: true, subGrid: false, torus: true, dimOthers: true,
      layerVisible: [true, true, true, true],
      layerLocked: [false, false, false, false],
      selection: null,
      preview: null,       // 拖矩形/直线时的预览框(子格单位)
      selDrag: null,       // {sel, dx, dy}:选区拖动中(拖动只记偏移,松手才提交)
    },
    thumbs: [null, null, null, null],
    thumbPx: THUMB_PX,
    slicer: createSlicer(opts.slicer || {}),
    stat: { thumbMs: 0, renders: 0, lastRenderMs: 0, thumbsBuilt: 0 },
    atlasSync: false,                  // 换图之后 ①② 需要整片重来
    errorSink: null,                   // 由 installErrors 装上(默认 = defaultErrorSink)
    layerCv: [null, null, null, null],
    layerDirty: [null, null, null, null],      // 每层一个子格矩形(null = 干净)
    cellCache: null,                            // ③
    layersClean: false,                         // 四张离屏层是否与当前视图一致
    stat2: { cellsHits: 0, cellsMisses: 0, cellsSize: 0,
             layerRebuilds: 0, layerRebuildMs: 0, panCopies: 0 },   // ★ layerRebuilds = 脏区重画次数(块);layerRebuildMs = 一次整片 buildLayers 的耗时(毫秒)—— 名字相近,量的不是一件事
  };

  // ★★ 换图必须把 ①② 也一起作废:它们的 state 全住在这个闭包里(与 setMap 里 attachCells 完全同一个先例)⇒ 这里登记一个只记账的作废器,真正的丢弃与重画排在下一次 render()(见 syncAtlas);当场同步重画就等于把闸 2 取消了。
  attachViewInvalidator(function () { S.atlasSync = !!S.s.map; return null; });
  return S;
}
