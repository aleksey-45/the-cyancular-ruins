// render/90_install_drag.js —— 选区拖动簇:只记偏移的预览查询(纯读,松手才 moveRegion)与去烤(markDragDirty/repaintDrag)。

function installDrag(S) {
  var s = S.s, thumbs = S.thumbs, stat2 = S.stat2;
  function setSelDrag(sel, dx, dy) {
    s.selDrag = sel ? { sel: sel, dx: dx, dy: dy } : null;
    markDragDirty();                                // ★ 见下:偏移一变就去烤
    S.render();
  }
  function setPreview(rect) { s.preview = rect; S.render(); }
  // ★★ 三种目标格必须与"松手后 moveRegion 真正写出来的结果"逐格一致:① 源格在选区内 ⇒ 读源格(被搬过来的那部分);② 源格在外、目标在选区内 ⇒ 那是被腾空的源区 ⇒ hit:false(不画)。
  //    ③ 两边都在选区外 ⇒ 原样读它自己(没被动过的底)。★ 少了 ③ 的后果不是"少画一点":偏移一动,除选区外的整整一张图都判成腾空 ⇒ 拖动时地图整体消失、只剩一个框在飘。
  // ★★ 只有活动层读偏移(落笔 moveRegion 只搬 app.r.layer() 那一层;四层一起偏移会让另三层跟手走、松手又弹回去,代价还翻四倍);一律传 W/H 环面折算,否则接缝那一侧预览与落笔分岔。
  // ★★ 选区没了,偏移就不再生效 —— 判据里必须有 s.selection(不是只有 s.selDrag):Esc 取消选区时"左键还按着"是合法状态,而框没了就没有可搬的东西,照旧读偏移会让内容留在"被搬过去"的位置上。
  function dragSource(L, X, Y) {
    if (!s.selDrag || !s.selection || L !== s.layer) return { hit: true, X: X, Y: Y };
    var W = s.map ? s.map.subCols : 0, H = s.map ? s.map.subRows : 0;
    var sel = s.selDrag.sel, q = selectionSource(sel, s.selDrag.dx, s.selDrag.dy, X, Y, W, H);
    if (q.hit) return q;
    var vacated = inSel(sel, X, Y, W, H);
    return vacated ? { hit: false, X: X, Y: Y } : { hit: true, X: X, Y: Y };
  }

  // ★★ 去烤:② 的离屏层是烤进去的 —— 拖动中滚轮缩放(setZoomAt → viewChanged() + buildLayers())或任何整片重建,都会把 dragSource 的偏移结果画死在 ② 上,而 buildLayers 结尾还把 layersClean 抬成 true。
  //    此后用户拖到第二个偏移、松手 ⇒ 提交只按最终偏移结算(源 ∪ 目标)⇒ 在更早的偏移上被烤过、而最终偏移没碰到的那些格永远留着别人的内容(框回到正确位置 ⇒ "地图上凭空多了一块错的内容",没有报错)。
  var dragBake = null;                              // { L: 烤在哪一层, rects: [规范块] } 或 null;上一次那两块也要一起重画 —— 清除时 s.selDrag 已经没了,只有这里记得它烤在哪
  function markDragDirty() {                        // ★ 修法:偏移一变(以及清除时)把「源区 ∪ 目标区」重画一遍,烤痕的寿命就不长于这一次拖动;重画的是规范化后的两块(canonRects,与 dragSource 同一套折算)
    if (!s.map) return;
    var W = s.map.subCols, H = s.map.subRows, L = s.layer, now = [];
    var live = !!s.selDrag && !!s.selection;        // ★★ 判据与 dragSource 的早退逐字同源:选区被取消而 selDrag 还挂着时,没有任何格存着偏移内容
    if (live) {
      var sel = s.selDrag.sel;
      now = canonRects({ x: sel.x, y: sel.y, w: sel.w, h: sel.h }, W, H)
        .concat(canonRects({ x: sel.x + s.selDrag.dx, y: sel.y + s.selDrag.dy, w: sel.w, h: sel.h }, W, H));
    }
    var prev = dragBake;
    dragBake = live ? { L: L, rects: now } : null;
    // ★★ dedupRects:源块在 now 与 prev.rects 里各有一份(选区没变时必然如此)⇒ 不去重就会把它连画两遍;now 自己也要过一遍(dx=dy=0 时源与目标是同一个矩形)。
    repaintDrag(L, dedupRects((prev && prev.L === L) ? now.concat(prev.rects) : now));   // ★★ 逐块重画,不取包围盒(闸 2):跨接缝时这两块分居图的两头,包围盒是整行(甚至整幅图),而高倍 + 大选区下那是全屏 clearRect 加每层数千次 drawImage、每次 pointermove 都付,且去烤是同步路径(没有走 createSlicer)
    if (prev && prev.L !== L) repaintDrag(prev.L, prev.rects);   // ★★ 层变了:上一次那批烤在旧层上,旧层此刻读到的是"没拖过"的内容,那些像素必须擦掉
    if (!live) dragBakedThumb = false;              // ★ 这次拖动结束(松手 / 选区被取消):账结清,必须排在上面两次重画之后
  }

  var dragBakedThumb = false;                       // ★ 本次拖动是否往 ① 烤过偏移:拖动途中 invalidateAll(撤销/重做一条 kind='whole' 的差量)会走 buildThumbs,而 paintThumbRect 读的正是 dragSource ⇒ 整张缩略图被按当时的偏移烤一遍,只有换回 ① 那条路时才归位
  function repaintDrag(L, rects) {                  // 把一批规范块在当前那条路上重画:① 与 ② 是两份数据、成本形状恰好相反(低倍时 ② 那份活一个字都看不见,实测见 docs/eng/editor-render.md §8)
    if (!rects.length || !layerArray(s.map, L)) return;   // ★ 缺席层直接跳过:它一个像素都没有,不存在"偏移内容"可擦,而 flushDirty 对缺席层走的是整张画布 clearRect(拖动中每帧白付、且不计数)
    if (zoomPath(s.view.zoom) === 'layers') {
      for (var i = 0; i < rects.length; i++) S.paintLayerRect(L, rects[i]);
      stat2.layerRebuilds++;                        // ★ 与 flushDirty 记的是同一本账(该层 +1)
      if (!dragBakedThumb) return;                  // ★ 常态:① 上没有这次拖动的偏移像素
    } else {
      dragBakedThumb = true;                        // ★ 这一次拖动把偏移烤进了 ①
    }
    if (!thumbs[L]) return;                         // ① 还没建(没 setMap)⇒ 没什么可烤
    for (var j = 0; j < rects.length; j++) S.paintThumbRect(L, rects[j]);
  }

  S.setSelDrag = setSelDrag;
  S.setPreview = setPreview;
  S.dragSource = dragSource;
  S.markDragDirty = markDragDirty;
}
