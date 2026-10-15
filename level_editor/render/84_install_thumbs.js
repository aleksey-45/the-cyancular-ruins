// render/84_install_thumbs.js —— ① 缩略图簇:每层一张、按脏矩形更新、经分帧器建。

function installThumbs(S) {
  var s = S.s, thumbs = S.thumbs, stat = S.stat, slicer = S.slicer;
  function ensureThumbs(map) {
    var px = thumbScale(map.subCols, map.subRows);
    // ★★ 复用条件必须逐轴判(宽与高),只判宽度不够:thumbScale 只看总字节数,所以"同宽更高"的两张图可以拿到同一个刻度(500×300 与 500×400 子格都是 1000×600 与 1000×800,都是 2px),
    //    这时宽度那条对得上 ⇒ 复用了那张矮画布,而 drawThumbPath 用五实参 drawImage 把它整张缩进 subRows*px*scale 的目标框里 ⇒ 纵向被拉伸/截断。默认视图 fitZoom 之后 zoom < 8,走的正是这条路。
    if (thumbs[0] && S.thumbPx === px &&
        thumbs[0].width === map.subCols * px && thumbs[0].height === map.subRows * px) {
      // ★★ 复用尺寸相同的旧缩略图之前,先把新图里缺席的层清掉:缺席层不进 thumbTasks(省一次全图扫描)⇒ 它不会被重画,留着旧像素的话,
      //    换到一张少层的图之后那一层会继续显示上一张图的内容。只判"尺寸变了没"是抓不住的(尺寸一样 ⇒ 走的就是这条路)。
      for (var Lc = 0; Lc < RenderCore.LAYER_COUNT; Lc++) {
        if (thumbs[Lc] && !layerArray(map, Lc)) {
          thumbs[Lc].getContext('2d').clearRect(0, 0, thumbs[Lc].width, thumbs[Lc].height);
        }
      }
      return false;
    }
    S.thumbPx = px;
    for (var L = 0; L < RenderCore.LAYER_COUNT; L++) {
      thumbs[L] = document.createElement('canvas');
      thumbs[L].width = map.subCols * px;
      thumbs[L].height = map.subRows * px;
      var c = thumbs[L].getContext('2d');
      c.imageSmoothingEnabled = false;
    }
    return true;
  }

  // 画缩略图的一块矩形(单位 = 子格;rect 由调用方保证在图内)。逐子格 drawImage / fillRect 是这里唯一的成本(默认图 15 万次)⇒ 缩略图总是经分帧器建(闸 2)。
  // ★★ 先按层种类分派、再谈内容:RGBA 永远走不到 Core.texOf / Tint 那条路上(见 layerIsColor —— 这一句就是那个缺陷的闸门,不是装饰)。
  function paintThumbRect(L, rect) {
    var tc = thumbs[L] && thumbs[L].getContext('2d');
    if (!tc) return;
    var px = S.thumbPx;
    var colorLayer = layerIsColor(L);              // 判据取一次,不在逐格循环里重算
    for (var Y = rect.y; Y < rect.y + rect.h; Y++) {
      for (var X = rect.x; X < rect.x + rect.w; X++) {
        var q = S.dragSource(L, X, Y);                 // ★ 拖动中:读源子格(纯读;只对活动层)
        var raw = q.hit ? descAt(s.map, L, q.X, q.Y) : 0;
        if (colorLayer) {
          // ★ 这里不许出现 texOf:红色 #FF0000FF 的纹理位恰好是 0,拿 texOf 当"空气"判会把整层判没。alpha = 0(createMap 的初值)才是"这一格没有颜色"。
          if (((raw >>> 0) & 255) === 0) { tc.clearRect(X * px, Y * px, px, px); continue; }
          tc.fillStyle = cssOfRGBA(raw);
          tc.fillRect(X * px, Y * px, px, px);
          continue;
        }
        if (raw === 0 || RenderCore.texOf(raw) === 0) { tc.clearRect(X * px, Y * px, px, px); continue; }
        var t = tileFor(raw, X, Y);
        if (t) tc.drawImage(t, X * px, Y * px, px, px);
      }
    }
  }

  function thumbTasks(map) {                     // 把一整层的缩略图切成"每 8 行一组"的任务交给分帧器;缺席层不画(全空气)
    var tasks = [], rows = 8;
    for (var L = 0; L < RenderCore.LAYER_COUNT; L++) {
      if (!layerArray(map, L)) continue;
      for (var y = 0; y < map.subRows; y += rows) {
        tasks.push({ L: L, rect: { x: 0, y: y, w: map.subCols, h: Math.min(rows, map.subRows - y) } });
      }
    }
    return tasks;
  }

  function buildThumbs() {
    if (!s.map) return Promise.resolve();
    var t0 = (typeof performance !== 'undefined' ? performance.now() : Date.now());
    var tasks = thumbTasks(s.map);
    stat.thumbsBuilt++;
    return slicer.run(tasks, function (t) { paintThumbRect(t.L, t.rect); }).then(function () {
      stat.thumbMs = (typeof performance !== 'undefined' ? performance.now() : Date.now()) - t0;
    });
  }

  function cssOfRGBA(v) {
    var u = v >>> 0;
    return 'rgba(' + ((u >>> 24) & 255) + ',' + ((u >>> 16) & 255) + ',' +
           ((u >>> 8) & 255) + ',' + ((u & 255) / 255) + ')';
  }
  function nowMs() {
    return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
  }

  S.ensureThumbs = ensureThumbs;
  S.paintThumbRect = paintThumbRect;
  S.buildThumbs = buildThumbs;
  S.cssOfRGBA = cssOfRGBA;
  S.nowMs = nowMs;
}
