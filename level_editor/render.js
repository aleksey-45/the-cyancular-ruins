globalThis.Render = (function () {
  'use strict';

  var Core = globalThis.Core, Tint = globalThis.Tint;
  if (!Core) throw new Error('render.js: 必须先加载 core.js');
  if (!Tint) throw new Error('render.js: 必须先加载 tint.js');

  var SUB = Core.SUB_PER_CELL;

  var MIN_ZOOM = 1, MAX_ZOOM = 64;              // px / 子格
  var ZOOM_THRESHOLD = 8;
  var THUMB_PX = 2;
  var THUMB_MAX_BYTES = 24 * 1024 * 1024;       // 超过就降到 1px/子格(400×300 格 @2px = 30MB,偏大)
  var DEFAULT_BUDGET_MS = 8;                    // 闸 2 的单帧 CPU 预算
  // 单元格缓存条目上限（每条存储 16 个瓦片引用）
  var DEFAULT_CELL_MAX = 8192;
  var VIEW_DEFAULTS = Object.freeze({ grid: true, subGrid: false, torus: true, dimOthers: true, guides: false });

  // ── 环面折算 ──
  // 坐标折算：规范化处理负数取模
  function wrapIdx(v, n) { return v - Math.floor(v / n) * n; }
  function quadOf(v) { return wrapIdx(v, SUB); }
  const layerArray = Core.layerArray;
  function descAt(map, L, X, Y) {
    var a = layerArray(map, L);
    if (!a) return 0;
    return a[wrapIdx(Y, map.subRows) * map.subCols + wrapIdx(X, map.subCols)];
  }
  function rgbaAt(map, X, Y) {
    var a = layerArray(map, Core.LAYER_BG);
    if (!a) return 0;
    return a[wrapIdx(Y, map.subRows) * map.subCols + wrapIdx(X, map.subCols)];
  }

  // ── 贴图源与缓存管理（更换图集时统一重置）──
  var atlasW = 0, atlasH = 0, atlasVersion = 0, tiles = null, cells = null;
  var atlasInvalidators = new Set();

  function tileCache() { if (!tiles) tiles = Tint.createTileCache(); return tiles; }

  function attachCells(cache) { cells = cache; return cache; }
  function attachViewInvalidator(fn) {
    if (typeof fn === 'function') atlasInvalidators.add(fn);
    return fn;
  }

  function setAtlas(pixels, w, h, opts) {
    var next = opts && opts.backend ? Tint.createTileCache({ backend: opts.backend }) : (tiles || Tint.createTileCache());
    next.setSource(pixels, w);
    tiles = next;
    atlasW = w; atlasH = h;
    atlasVersion++;
    if (cells) cells.setSource();
    for (var notify of atlasInvalidators) notify();
  }
  function atlasInfo() { return atlasW ? { width: atlasW, height: atlasH } : null; }

  function atlasCapacity() {
    return atlasW > 0 ? Math.max(0, Math.floor(atlasW / Tint.BLOCK_PX) * Math.floor(atlasH / Tint.BLOCK_PX)) : 0;
  }

  function tileFor(desc, qx, qy) {
    if (desc === 0) return null;
    var tex = Core.texOf(desc);
    if (tex === 0) return null;                  // 畸形描述符(辅码非 0、纹理 0)= 空气
    return tileCache().get(tex, quadOf(qx), quadOf(qy), desc);
  }

  function createCellCache(opts) {
    opts = opts || {};
    var maxCells = opts.maxCells === undefined ? DEFAULT_CELL_MAX : opts.maxCells;
    var build = opts.build;
    if (typeof build !== 'function') throw new Error('createCellCache: 缺 build 回调');
    var ver = new Map();                         // 内容版本号
    var entries = new Map();                     // 键 -> {v, gen, tile}
    var gen = 0, hits = 0, misses = 0, evictions = 0;

    function key(L, cx, cy) { return L + '/' + cx + '/' + cy; }
    function version(L, cx, cy) { var v = ver.get(key(L, cx, cy)); return v === undefined ? 0 : v; }
    function touch(L, cx, cy) { ver.set(key(L, cx, cy), version(L, cx, cy) + 1); }
    function setSource() { gen++; }
    function get(L, cx, cy) {
      var k = key(L, cx, cy);
      var v = version(L, cx, cy);
      var e = entries.get(k);
      if (e !== undefined && e.v === v && e.gen === gen) {
        hits++;
        entries.delete(k); entries.set(k, e);    // 命中提到最近端(Map 的插入序 = LRU 序)
        return e.tile;
      }
      misses++;
      var tile = build(L, cx, cy);
      entries.delete(k);
      entries.set(k, { v: v, gen: gen, tile: tile });
      while (entries.size > maxCells) { entries.delete(entries.keys().next().value); evictions++; }
      return tile;
    }
    function clear() { entries.clear(); }
    function stats() {
      return { hits: hits, misses: misses, evictions: evictions,
               size: entries.size, maxCells: maxCells, generation: gen };
    }
    return { version: version, touch: touch, setSource: setSource,
             get: get, clear: clear, stats: stats };
  }

  function nowMs() { return globalThis.performance?.now?.() ?? Date.now(); }

  function createSlicer(options) {
    const opts = options || {};
    const budget = Number.isFinite(opts.budgetMs) ? Math.max(0, opts.budgetMs) : DEFAULT_BUDGET_MS;
    const now = opts.now || nowMs;
    const nextFrame = opts.nextFrame || (() => new Promise(resolve => requestAnimationFrame(resolve)));

    async function runWhile(step, more = true) {
      let frames = 0, processed = 0, maxStepMs = 0;
      for (;;) {
        const start = now();
        while (more) {
          more = step();
          processed++;
          if (now() - start >= budget) break;
        }
        maxStepMs = Math.max(maxStepMs, now() - start);
        if (!more) return {frames, processed, maxStepMs};
        frames++;
        await nextFrame();
      }
    }

    function run(items, visit) {
      let i = 0;
      return runWhile(() => {
        visit(items[i], i);
        i++;
        return i < items.length;
      }, items.length > 0);
    }
    return {run, runWhile, budgetMs: budget};
  }

  // ── 缩放与适配 ──
  function zoomPath(pxPerSub) { return pxPerSub < ZOOM_THRESHOLD ? 'thumb' : 'layers'; }
  function clampZoom(z) {
    if (!isFinite(z) || z <= 0) return MIN_ZOOM;   // 用户输入钳制,不报错回滚
    return Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, z));
  }
  function fitZoom(subCols, subRows, viewW, viewH, pad) {
    var p = pad === undefined ? 8 : pad;
    var zx = (viewW - 2 * p) / subCols, zy = (viewH - 2 * p) / subRows;
    return clampZoom(Math.min(zx, zy));
  }
  function thumbScale(subCols, subRows) {
    var bytes = subCols * THUMB_PX * subRows * THUMB_PX * 4;
    return bytes > THUMB_MAX_BYTES ? 1 : THUMB_PX;
  }

  // ── 可见区裁剪 ──
  // 可见区域使用连续的世界坐标，采样地图时折算回主网格。
  function visibleSubRange(view, viewW, viewH, subCols, subRows) {
    var x0 = Math.floor(view.x), y0 = Math.floor(view.y);
    var x1 = Math.ceil(view.x + viewW / view.zoom), y1 = Math.ceil(view.y + viewH / view.zoom);
    return { x0: x0, y0: y0, x1: x1, y1: y1 };
  }

  function intersects(a0, a1, b0, b1) { return a1 > b0 && a0 < b1; }
  function torusOffsets(view, viewW, viewH, mapW, mapH) {
    var r = visibleSubRange(view, viewW, viewH, mapW, mapH);
    var out = [];
    for (var ky = 0; ky < 2; ky++) {
      var lo = ky * mapH, hi = lo + mapH;
      if (!intersects(r.y0, r.y1, lo, hi)) continue;
      for (var kx = 0; kx < 2; kx++) {
        var lox = kx * mapW, hix = lox + mapW;
        if (!intersects(r.x0, r.x1, lox, hix)) continue;
        out.push([lox, lo]);
      }
    }
    return out;
  }

  // 屏幕 → 子格(折算回主网格)。副本上落笔靠的就是这一步:无论点在哪个副本上,
  // 结果都落在 [0, subCols) 里。
  function hitTest(view, px, py, subCols, subRows) {
    var X = Math.floor(view.x + px / view.zoom);
    var Y = Math.floor(view.y + py / view.zoom);
    return { X: wrapIdx(X, subCols), Y: wrapIdx(Y, subRows) };
  }

  var MAX_BRUSH_CELLS = 15;
  function brushSpan(size) {
    var s = (typeof size === 'number' && isFinite(size)) ? size : 1;
    if (s <= 0) s = 1;
    if (Math.floor(s) === s) return { unit: 'cell', n: Math.max(1, Math.min(MAX_BRUSH_CELLS, s)) };
    var n = Math.round(s * SUB);                 // 0.25→1、0.5→2、0.75→3、2.5→10
    return { unit: 'sub', n: Math.max(1, Math.min(MAX_BRUSH_CELLS * SUB, n)) };
  }
  function brushRegion(hit, size) {
    var sp = brushSpan(size);
    var c = (typeof hit === 'object' && hit) ? hit : {};
    var x = Math.floor(isFinite(c.x) ? c.x : 0);
    var y = Math.floor(isFinite(c.y) ? c.y : 0);
    var lo = Math.floor((sp.n - 1) / 2), hi = Math.ceil((sp.n - 1) / 2);
    var unit = (c.kind === 'cell' || c.kind === 'sub') ? c.kind : sp.unit;
    return { unit: unit, x0: x - lo, y0: y - lo, x1: x + hi, y1: y + hi };
  }
  function snapHit(h) {
    if (h.kind === 'sub') return { kind: 'sub', x: Math.floor(h.X), y: Math.floor(h.Y) };
    return { kind: 'cell', x: Math.floor(h.X / SUB), y: Math.floor(h.Y / SUB) };
  }

  function selectionSource(sel, dx, dy, X, Y, W, H) {
    var sx = X - dx, sy = Y - dy;
    if (W > 0 && H > 0) { sx = wrapIdx(sx, W); sy = wrapIdx(sy, H); }
    if (inSel(sel, sx, sy, W, H)) return { hit: true, X: sx, Y: sy };
    return { hit: false, X: X, Y: Y };
  }

  // 选区在环面上的成员判据,而且它是唯一一处 —— UI 的 inRect 直接转调它
  // (ui.js:inRect),故 regionCells 的 clip / 油漆桶 / 渐变 / 直线 / "按在选区里"五个
  // 调用点与这里的 moveRegion from 集合是同一条判据。
  // 公式:先各自折算到主网格,再比相对偏移 —— 于是"选区自己跨着接缝"(先前的拖动把
  //   选区挪到了接缝另一侧,如 96 宽的图上 {x:93,w:6} 盖住 93..95 与 0..2)也算得对;
  //   绝对比大小(x >= sel.x && x < sel.x + sel.w)会在那种选区上静默漏掉绕过去的那半截。
  // 不给 W/H 时退回线性区间(旧口径),给了一律折算。
  function inSel(sel, X, Y, W, H) {
    if (!sel) return false;
    if (!(W > 0 && H > 0)) {
      return X >= sel.x && X < sel.x + sel.w && Y >= sel.y && Y < sel.y + sel.h;
    }
    var ox = wrapIdx(wrapIdx(X, W) - wrapIdx(sel.x, W), W);
    var oy = wrapIdx(wrapIdx(Y, H) - wrapIdx(sel.y, H), H);
    return ox < sel.w && oy < sel.h;
  }

  function dedupRects(list) {
    var out = [], seen = {};
    for (var i = 0; i < list.length; i++) {
      var r = list[i], key = r.x + ',' + r.y + ',' + r.w + ',' + r.h;
      if (seen[key]) continue;
      seen[key] = 1;
      out.push(r);
    }
    return out;
  }

  // 一个矩形在环面上折算后的规范分解(至多 4 块):拖动预览要重画的区域必须落在这些块里。
  // 只取"左上角折算"是不够的:矩形自己跨过接缝时(x1 < x0),折算后是两段区间 ——
  //   取并集会漏掉另一头那半截(那半边的烤痕永远留着)；取"包围盒"则会把整幅图都算进去。
  //   本函数不依赖 w ≤ W:"矩形自己跨接缝"这条分支就是为 w 大于一整行时准备的
  //   (本文件的 canonRects 不变量写成"w>0"即可)—— 而 UI 的选区确实可以是
  //   {x:93,w:6}(96 宽):先前的拖动把选区挪过接缝时,pointerup 存回的是折算后的
  //   左上角,宽度原样带过来 ⇒ x+w 可以越过 W。故这里只要求 w>0,不假设 x+w ≤ W。
  function canonRects(r, W, H) {
    var out = [];
    if (!r || r.w <= 0 || r.h <= 0) return out;
    var x0 = wrapIdx(r.x, W), x1 = wrapIdx(r.x + r.w - 1, W);
    var y0 = wrapIdx(r.y, H), y1 = wrapIdx(r.y + r.h - 1, H);
    var xs = (x1 >= x0) ? [[x0, x1]] : [[x0, W - 1], [0, x1]];
    var ys = (y1 >= y0) ? [[y0, y1]] : [[y0, H - 1], [0, y1]];
    for (var i = 0; i < ys.length; i++) {
      for (var j = 0; j < xs.length; j++) {
        out.push({ x: xs[j][0], y: ys[i][0],
                   w: xs[j][1] - xs[j][0] + 1, h: ys[i][1] - ys[i][0] + 1 });
      }
    }
    return out;
  }

  // ── 图层绘制顺序 ──
  // 前景(0)是"从外到内"的第一层 ⇒ 最后画(盖在最上面);背景(3)最先画。
  var DRAW_ORDER = [3, 2, 1, 0];
  var SKY_COLOR = '#b0e5f6';

  // ── 层的种类:决定那一格怎么读 ──
  // 纹理层是描述符(走 Core.texOf / Tint),背景层是 RGBA 0xRRGGBBAA
  //    (走 cssOfRGBA / fillRect)。两者都是 32 位无符号数,长得一模一样、含义完全不同 ——
  //    把 RGBA 喂给 Core.texOf 不抛,只是结论毫无意义,而两种颜色各有一种静默症状:
  //      · 不透明红 #FF0000FF(背景色输入框里随手就有):(0xFF0000FF >>> 12) & 0xFFF = 0
  //        ⇒ 被当成空气 ⇒ 整层看不见;
  //      · 不透明青 #00FFFFFF(输入框的默认值):texOf = 4095 = "图集里没有的那块砖"
  //        ⇒ 任何一处漏掉"先判层、再判纹理"的地方都当场抛 Tint 的越界错(闸门越少越容易漏)。
  //    判据取 core.js 的单一来源(LAYER_KINDS),别在渲染层再抄一份 [0,0,0,1] ——
  //    那就是第二份实现,而两份实现迟早漂、且漂了不报错。
  function layerIsColor(L) { return Core.LAYER_KINDS[L] === 'color'; }

  function mount(canvas) {
    var ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;
    var viewOptions = { ...VIEW_DEFAULTS };
    var s = {
      map: null, layer: Core.LAYER_SCENE,
      view: { x: 0, y: 0, zoom: 8 },
      layerVisible: [true, true, true, true],
      layerLocked: [false, false, false, false],
      selection: null,
      preview: null,       // 拖矩形/直线时的预览框(子格单位)
      selDrag: null,       // {sel, dx, dy}:选区拖动中(拖动只记偏移,松手才提交)
    };
    var thumbs = [null, null, null, null];
    var thumbPx = THUMB_PX;
    var thumbWork = 0;
    var slicer = createSlicer();
    var stat = { thumbMs: 0, renders: 0, lastRenderMs: 0, thumbsBuilt: 0 };

    var drawnAtlas = atlasVersion;

    function ensureThumbs(map) {
      var px = thumbScale(map.subCols, map.subRows);
      // 复用条件必须逐轴判(宽 与 高),只判宽度是不够的:
      //    thumbScale 只看总字节数,所以"同宽更高"的两张图可以拿到同一个刻度
      //    (如 demo 的 500×300 子格 → 1000×600,与 500×400 子格 → 1000×800,刻度都是 2)。
      //    这时宽度那条对得上 ⇒ 复用了那张矮画布,而 drawThumbPath 用五实参 drawImage
      //    把它整张缩进 subRows*px*scale 的目标框里 ⇒ 画面纵向被拉伸/截断(默认视图
      //    fitZoom 之后 zoom < 8,走的正是缩略图这条路,所以默认视图就是错的)。
      if (thumbs[0] && thumbPx === px &&
          thumbs[0].width === map.subCols * px && thumbs[0].height === map.subRows * px) {
        // 复用尺寸相同的旧缩略图之前,先把新图里缺席的层清掉:缺席层不进 thumbTasks
        //    (省一次全图扫描),于是它不会被重画 —— 留着旧像素的话,换到一张少层的图
        //    之后那一层会继续显示上一张图的内容(而缩略图路径会把它当"这一层的画面"贴出去)。
        //    只判"尺寸变了没"是抓不住的(尺寸一样 ⇒ 走的就是这条路)。
        for (var Lc = 0; Lc < Core.LAYER_COUNT; Lc++) {
          if (thumbs[Lc] && !layerArray(map, Lc)) {
            thumbs[Lc].getContext('2d').clearRect(0, 0, thumbs[Lc].width, thumbs[Lc].height);
          }
        }
        return false;
      }
      thumbPx = px;
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        thumbs[L] = document.createElement('canvas');
        thumbs[L].width = map.subCols * px;
        thumbs[L].height = map.subRows * px;
        var c = thumbs[L].getContext('2d');
        c.imageSmoothingEnabled = false;
      }
      return true;
    }

    // 画缩略图的一块矩形(单位 = 子格;rect 由调用方保证在图内)
    // 逐子格 drawImage / fillRect 是这里唯一的成本(默认图 15 万次),所以缩略图总是
    //   经分帧器建(闸 2):大图上是"慢慢画出来",不是"页面死掉"。
    // 先按层种类分派、再谈内容:RGBA 永远走不到 Core.texOf / Tint 那条路上
    //    (见 layerIsColor —— 这一句就是那个缺陷的闸门,不是装饰)。
    function paintThumbRect(L, rect) {
      var tc = thumbs[L].getContext('2d'), px = thumbPx;
      tc.clearRect(rect.x * px, rect.y * px, rect.w * px, rect.h * px);
      var colorLayer = layerIsColor(L);
      for (var y = rect.y; y < rect.y + rect.h; y++) {
        for (var x = rect.x; x < rect.x + rect.w; x++) {
          var q = dragSource(L, x, y, thumbDrag);
          if (!q.hit) continue;
          var raw = descAt(s.map, L, q.X, q.Y);
          if (colorLayer) {
            if (!(raw & 255)) continue;
            tc.fillStyle = cssOfRGBA(raw);
            tc.fillRect(x * px, y * px, px, px);
          } else {
            var tile = tileFor(raw, x, y);
            if (tile) tc.drawImage(tile, x * px, y * px, px, px);
          }
        }
      }
    }

    function paintThumbRegions(L, rects) {
      for (var rect of rects) paintThumbRect(L, rect);
    }

    // 把一整层的缩略图切成"每 8 行一组"的任务交给分帧器
    function thumbTasks(map) {
      var tasks = [], rows = 8;
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        if (!layerArray(map, L)) continue;             // 缺席层不画(全空气)
        for (var y = 0; y < map.subRows; y += rows) {
          tasks.push({ L: L, rect: { x: 0, y: y, w: map.subCols, h: Math.min(rows, map.subRows - y) } });
        }
      }
      return tasks;
    }

    function buildThumbs() {
      if (!s.map) return Promise.resolve();
      var t0 = nowMs();
      var tasks = thumbTasks(s.map);
      var work = ++thumbWork;
      stat.thumbsBuilt++;
      return slicer.run(tasks, function (t) { if (work === thumbWork) paintThumbRect(t.L, t.rect); }).then(function () {
        stat.thumbMs = nowMs() - t0;
      });
    }

    function cssOfRGBA(v) {
      var u = v >>> 0;
      return 'rgba(' + ((u >>> 24) & 255) + ',' + ((u >>> 16) & 255) + ',' +
             ((u >>> 8) & 255) + ',' + ((u & 255) / 255) + ')';
    }
    // 用鼠标坐标算世界坐标的两个方向:命中(C15 子格级)与反算(画 spawn 标记)
    function screenToSub(px, py) {
      // 还没打开地图时返回中性值(闸 1:用户输入钳制,不报错回滚)——
      //   指针事件比 setMap 早到是完全可能的,而这里抛错只会表现为"点了没反应"。
      if (!s.map) return { X: 0, Y: 0 };
      return hitTest(s.view, px, py, s.map.subCols, s.map.subRows);
    }
    function subToScreen(X, Y) {
      return { x: (X - s.view.x) * s.view.zoom, y: (Y - s.view.y) * s.view.zoom };
    }

    function copies() { return viewOptions.torus ? 2 : 1; }

    function containsPoint(px, py) {
      if (!s.map) return false;
      var x = s.view.x + px / s.view.zoom, y = s.view.y + py / s.view.zoom;
      return x >= 0 && y >= 0 && x < s.map.subCols * copies() && y < s.map.subRows * copies();
    }

    function limitView(view) {
      if (!s.map) return view;
      var halfX = canvas.width / (2 * view.zoom), halfY = canvas.height / (2 * view.zoom);
      return {
        x: Math.max(-halfX, Math.min(s.map.subCols * copies() - halfX, view.x)),
        y: Math.max(-halfY, Math.min(s.map.subRows * copies() - halfY, view.y)),
        zoom: view.zoom,
      };
    }

    function torusList(W, H) {
      if (!viewOptions.torus) return [[0, 0]];
      return torusOffsets(s.view, W, H, s.map.subCols, s.map.subRows);
    }

    function drawThumbPath(W, H) {
      if (thumbDrag !== drag) {
        var previous = thumbDrag;
        thumbDrag = drag;
        redrawDrag(previous, drag, paintThumbRegions);
      }
      var px = thumbPx;
      var scale = s.view.zoom / px;                  // 缩略图像素 → 屏幕像素
      var offs = torusList(W, H), i, L;
      for (i = 0; i < offs.length; i++) {
        for (var oi = 0; oi < DRAW_ORDER.length; oi++) {
          L = DRAW_ORDER[oi];
          if (!s.layerVisible[L] || !thumbs[L]) continue;
          ctx.globalAlpha = (viewOptions.dimOthers && L !== s.layer && L !== Core.LAYER_BG) ? 0.4 : 1;
          ctx.drawImage(thumbs[L],
                        (offs[i][0] - s.view.x) * s.view.zoom,
                        (offs[i][1] - s.view.y) * s.view.zoom,
                        s.map.subCols * px * scale, s.map.subRows * px * scale);
        }
      }
      ctx.globalAlpha = 1;
    }

    // 每层缓存当前视口的像素。平移沿用整数像素，保留小数缩放的采样位置。
    var layerCv = [null, null, null, null], cellCache = null;
    var layerGen = 0, layersClean = false;
    var stat2 = { layerRebuilds: 0, layerRebuildMs: 0, panCopies: 0 };

    // 缩放或换图会使正在分帧绘制的旧视口过期。
    function viewChanged() { layerGen++; layersClean = false; }

    function ensureLayerCanvas(L) {
      if (layerCv[L] && layerCv[L].width === canvas.width && layerCv[L].height === canvas.height) return layerCv[L];
      var c = document.createElement('canvas');
      c.width = canvas.width; c.height = canvas.height;
      c.getContext('2d').imageSmoothingEnabled = false;   // 离屏也必须关插值(A5)
      layerCv[L] = c;
      return c;
    }

    // 一个宏格缓存 16 个瓦片引用。像素由共享的染色瓦片缓存持有。
    function buildCell(L, cx, cy) {
      var out = new Array(SUB * SUB);
      var bx = cx * SUB, by = cy * SUB;
      for (var qy = 0; qy < SUB; qy++) {
        for (var qx = 0; qx < SUB; qx++) {
          var raw = descAt(s.map, L, bx + qx, by + qy);
          out[qy * SUB + qx] = tileFor(raw, qx, qy);
        }
      }
      return out;
    }

    // 重画某一层的离屏上的一块矩形(单位 = 子格;矩形允许越出画布与主网格,内部裁剪)
    // 越出主网格是常态:离屏层的像素系与屏幕同一套,视图越过接缝时那半边像素只有
    //   靠折算后的格才填得上(descAt 本来就环面折算)。绝不许按"主网格"裁剪 —— 裁了就是
    //   视图经过接缝时的两侧内容。
    function paintLayerRect(L, rect) {
      var cv = ensureLayerCanvas(L);
      var c = cv.getContext('2d');
      var z = s.view.zoom;
      // 世界子格 → 画布局部像素
      var px0 = Math.max(0, Math.floor((rect.x - s.view.x) * z));
      var py0 = Math.max(0, Math.floor((rect.y - s.view.y) * z));
      var px1 = Math.min(cv.width, Math.ceil((rect.x + rect.w - s.view.x) * z));
      var py1 = Math.min(cv.height, Math.ceil((rect.y + rect.h - s.view.y) * z));
      if (px1 <= px0 || py1 <= py0) return;
      c.clearRect(px0, py0, px1 - px0, py1 - py0);
      if (!layerArray(s.map, L)) return;                 // 缺席层 = 全空气(已清干净)
      c.save();
      c.beginPath();
      c.rect(px0, py0, px1 - px0, py1 - py0);
      c.clip();
      var cell0x = Math.floor((s.view.x + px0 / z) / SUB), cell1x = Math.ceil((s.view.x + px1 / z) / SUB);
      var cell0y = Math.floor((s.view.y + py0 / z) / SUB), cell1y = Math.ceil((s.view.y + py1 / z) / SUB);
      // 按层种类分派(判据取一次,不在逐格循环里重算)—— 这就是 F1 那道闸门。
      var colorLayer = layerIsColor(L);
      var cw = Core.cellsWOf(s.map), ch = Core.cellsHOf(s.map);
      for (var cy = cell0y; cy < cell1y; cy++) {
        for (var cx = cell0x; cx < cell1x; cx++) {
          var bx = cx * SUB, by = cy * SUB;
          if (colorLayer) {
            // 颜色层:逐子格读 RGBA、直接填色。alpha = 0 = 这一格没有颜色(上面已 clearRect,
            // 这里什么都不画)。这里不许出现 texOf(见 buildCell 的两条静默症状)。
            for (var kc = 0; kc < SUB * SUB; kc++) {
              var Xc = bx + (kc % SUB), Yc = by + Math.floor(kc / SUB);
              var qc = dragSource(L, Xc, Yc, drag);              // 拖动中:读源子格(纯读;只对活动层)
              var rawc = qc.hit ? descAt(s.map, L, qc.X, qc.Y) : 0;
              if (((rawc >>> 0) & 255) === 0) continue;
              c.fillStyle = cssOfRGBA(rawc);
              c.fillRect((Xc - s.view.x) * z, (Yc - s.view.y) * z, z, z);
            }
            continue;
          }
          // ③ 的键必须是主网格上的格号:环面让同一格有多种写法(cx = -1 与 cx = cellsW-1),
          //   不折算的话同一格会缓存两条条目,而编辑只 touch 其中一条 ⇒ 接缝另一侧的副本
          //   继续显示陈旧内容(画面错了、一个字都不报)。
          // 拖动偏移从这里接:拖动中读的是源格(纯读,不改进数据),画的位置仍是
          //   目标格(bx/by,见循环体最后一行)—— 只有"读"是偏移过的。
          //   传进去的是子格坐标(选区与偏移都是子格单位),取缓存键前再折回格号:
          //     偏移是格对齐时(整数画笔 + 整格选区)这一步是恒等;偏移落在子格上时按格取整
          //     —— 只见于小数画笔的选区,是拖动途中的子格级近似,松手后由 moveRegion 归位。
          var gx = wrapIdx(cx, cw), gy = wrapIdx(cy, ch);
          var q = dragSource(L, gx * SUB, gy * SUB, drag);
          if (!q.hit) continue;                            // 被腾空的源区 ⇒ 这一格不画
          var tilesOfCell = cellCache.get(L, wrapIdx(Math.floor(q.X / SUB), cw),
                                             wrapIdx(Math.floor(q.Y / SUB), ch));  // ③:这一格的 16 个 tile
          for (var k = 0; k < tilesOfCell.length; k++) {
            var t = tilesOfCell[k];
            if (!t) continue;
            var X = bx + (k % SUB), Y = by + Math.floor(k / SUB);   // 画在目标格的位置
            c.drawImage(t, (X - s.view.x) * z, (Y - s.view.y) * z, z, z);
          }
        }
      }
      c.restore();
    }

    function paintLayerRegions(L, rects) {
      var offsets = torusOffsets(s.view, canvas.width, canvas.height, s.map.subCols, s.map.subRows);
      for (var rect of rects) {
        for (var [x, y] of offsets) {
          paintLayerRect(L, { x: rect.x + x, y: rect.y + y, w: rect.w, h: rect.h });
        }
      }
      stat2.layerRebuilds += rects.length;
    }

    function buildLayers() {
      if (!s.map) return Promise.resolve();
      layersClean = false;
      var myGen = ++layerGen;
      var r = visibleSubRange(s.view, canvas.width, canvas.height, s.map.subCols, s.map.subRows);
      var tasks = [];
      var bands = 16;
      var h = Math.max(1, Math.ceil((r.y1 - r.y0) / bands));
      for (var L = 0; L < Core.LAYER_COUNT; L++) {

        ensureLayerCanvas(L);
        for (var y = r.y0; y < r.y1; y += h) {
          tasks.push({ L: L, rect: { x: r.x0, y: y, w: r.x1 - r.x0, h: Math.min(h, r.y1 - y) } });
        }
      }
      var t0 = nowMs();
      return slicer.run(tasks, function (t) {
        if (myGen !== layerGen) return;              // 过期的一轮:整条作废(视图/尺寸/图集已变)
        paintLayerRect(t.L, t.rect);
      }).then(function () {
        if (myGen !== layerGen) return;              // 过期的一轮不许把 layersClean 抬起来
        stat2.layerRebuildMs = nowMs() - t0;
        layersClean = true;
      });
    }

    // 离屏层已经按环面坐标铺满视口，合成时裁到预览区域。
    function drawLayerPath(W, H) {
      var origin = subToScreen(0, 0), z = s.view.zoom;
      ctx.save();
      ctx.beginPath();
      ctx.rect(origin.x, origin.y, s.map.subCols * z * copies(), s.map.subRows * z * copies());
      ctx.clip();
      for (var L of DRAW_ORDER) {
        var layer = layerCv[L];
        if (!s.layerVisible[L] || !layer || layer.width !== W || layer.height !== H) continue;
        ctx.globalAlpha = viewOptions.dimOthers && L !== s.layer && L !== Core.LAYER_BG ? 0.4 : 1;
        ctx.drawImage(layer, 0, 0);
      }
      ctx.restore();
    }

    var quadrant = new Uint16Array(4);
    function quadrantTexture(arr, start, stride) {
      quadrant[0] = Core.texOf(arr[start]);
      quadrant[1] = Core.texOf(arr[start + 1]);
      quadrant[2] = Core.texOf(arr[start + stride]);
      quadrant[3] = Core.texOf(arr[start + stride + 1]);
      var best = 0, count = 0;
      for (var tex of quadrant) {
        if (!tex) continue;
        var matches = 0;
        for (var other of quadrant) if (other === tex) matches++;
        if (matches > count || (matches === count && tex < best)) { best = tex; count = matches; }
      }
      return best;
    }

    function splitCell(arr, x, y, stride) {
      var start = y * stride + x;
      var first = quadrantTexture(arr, start, stride);
      return first !== quadrantTexture(arr, start + 2, stride) ||
             first !== quadrantTexture(arr, start + 2 * stride, stride) ||
             first !== quadrantTexture(arr, start + 2 * stride + 2, stride);
    }

    function drawGrid(W, H) {
      var z = s.view.zoom, cols = s.map.subCols, rows = s.map.subRows;
      var range = visibleSubRange(s.view, W, H, cols, rows);
      var x0 = Math.max(0, range.x0), x1 = Math.min(cols, range.x1);
      var y0 = Math.max(0, range.y0), y1 = Math.min(rows, range.y1);
      if (x1 <= x0 || y1 <= y0) return;
      var left = subToScreen(x0, y0), right = subToScreen(x1, y1);
      var origin = subToScreen(0, 0);
      function vertical(x, a, b) {
        var sx = Math.round(origin.x + x * z) + 0.5;
        ctx.moveTo(sx, a); ctx.lineTo(sx, b);
      }
      function horizontal(y, a, b) {
        var sy = Math.round(origin.y + y * z) + 0.5;
        ctx.moveTo(a, sy); ctx.lineTo(b, sy);
      }
      ctx.lineWidth = 1;
      var arr = viewOptions.subGrid && z >= 4 && !layerIsColor(s.layer) ? layerArray(s.map, s.layer) : null;
      if (arr) {
        ctx.strokeStyle = 'rgba(0,0,0,.14)';
        ctx.beginPath();
        for (var y = Math.floor(y0 / SUB) * SUB; y < y1; y += SUB) {
          for (var x = Math.floor(x0 / SUB) * SUB; x < x1; x += SUB) {
            if (!splitCell(arr, x, y, cols)) continue;
            for (var i = 1; i < SUB; i++) {
              vertical(x + i, origin.y + y * z, origin.y + (y + SUB) * z);
              horizontal(y + i, origin.x + x * z, origin.x + (x + SUB) * z);
            }
          }
        }
        ctx.stroke();
      }
      ctx.strokeStyle = 'rgba(0,0,0,.26)';
      ctx.beginPath();
      for (var x = Math.ceil(x0 / SUB) * SUB; x <= x1; x += SUB) vertical(x, left.y, right.y);
      for (var y = Math.ceil(y0 / SUB) * SUB; y <= y1; y += SUB) horizontal(y, left.x, right.x);
      ctx.stroke();
    }

    function drawMapFrames(W, H) {
      var z = s.view.zoom, w = s.map.subCols * z, h = s.map.subRows * z;
      ctx.save();
      for (var [ox, oy] of torusList(W, H)) {
        var {x, y} = subToScreen(ox, oy), primary = ox === 0 && oy === 0;
        ctx.lineWidth = primary ? 2 : 1;
        ctx.strokeStyle = primary ? 'rgba(84,160,255,.9)' : 'rgba(84,160,255,.55)';
        ctx.strokeRect(Math.round(x), Math.round(y), Math.round(w), Math.round(h));
        if (!viewOptions.guides) continue;
        ctx.lineWidth = 1;
        ctx.strokeStyle = 'rgba(0,0,0,.22)';
        ctx.setLineDash([4, 4]);
        ctx.beginPath();
        var sections = Core.RESPAWN_GUIDE_DIVISIONS;
        for (var j = 1; j < sections * 2; j++) {
          if (j === sections) continue;
          var px = x + w * j / (sections * 2);
          ctx.moveTo(px, y); ctx.lineTo(px, y + h);
        }
        for (var j = 1; j < sections; j++) {
          var py = y + h * j / sections;
          ctx.moveTo(x, py); ctx.lineTo(x + w, py);
        }
        ctx.stroke();
        ctx.setLineDash([]);
        ctx.lineWidth = 2;
        ctx.strokeStyle = 'rgba(0,0,0,.45)';
        ctx.beginPath();
        ctx.moveTo(x + w / 2, y); ctx.lineTo(x + w / 2, y + h);
        ctx.stroke();
      }
      ctx.restore();
    }
    // spawn 标记与选区框共用字体和对齐设置。
    function drawOverlay(W, H) {
      if (!s.map) return;
      ctx.save();
      ctx.font = '12px Consolas, monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      var offs = torusList(W, H);
      var mark = function (cellX, cellY, color, label, outline) {
        for (var i = 0; i < offs.length; i++) {
          var X = cellX * SUB + offs[i][0], Y = cellY * SUB + offs[i][1];
          var p = subToScreen(X, Y);
          if (p.x < -64 || p.y < -64 || p.x > W + 64 || p.y > H + 64) continue;
          var size = SUB * s.view.zoom;
          if (outline) {
            ctx.strokeStyle = color;
            ctx.lineWidth = 2;
            ctx.strokeRect(p.x, p.y, size, size);
            ctx.fillStyle = color;
            ctx.fillText(label, p.x + size / 2, p.y - 7);
          } else {
            ctx.fillStyle = color;
            ctx.globalAlpha = 0.75;
            ctx.fillRect(p.x, p.y, size, size);
            ctx.globalAlpha = 1;
            ctx.fillStyle = '#fff';
            ctx.fillText(label, p.x + size / 2, p.y + size / 2);
          }
        }
      };
      for (var i = 0; i < s.map.players.length; i++) {
        mark(s.map.players[i].x, s.map.players[i].y, '#1f6feb', 'P' + s.map.players[i].slot);
      }
      for (var j = 0; j < s.map.enemies.length; j++) {
        mark(s.map.enemies[j].x, s.map.enemies[j].y, '#8a2f6b', 'E');
      }
      for (var r of s.map.respawns) {
        mark(r.x, r.y, r.side === 1 ? '#1a7f37' : '#b45309', 'R' + r.side, true);
      }
      function drawOutline(rect) {
        for (var [x, y] of offs) {
          var p = subToScreen(rect.x + x, rect.y + y);
          ctx.strokeRect(p.x, p.y, rect.w * s.view.zoom, rect.h * s.view.zoom);
        }
      }
      if (s.preview) {
        ctx.setLineDash([6, 4]);
        ctx.strokeStyle = '#54a0ff';
        ctx.lineWidth = 1;
        drawOutline(s.preview);
        ctx.setLineDash([]);
      }
      if (s.selection) {
        var base = s.selection || (s.selDrag ? s.selDrag.sel : null);
        var sel = (base && s.selDrag)
          ? { x: base.x + s.selDrag.dx, y: base.y + s.selDrag.dy, w: base.w, h: base.h }
          : base;
        if (sel) {
          ctx.strokeStyle = '#e0b34a';
          ctx.lineWidth = 2;
          drawOutline(sel);
        }
      }
      ctx.restore();
    }

    function render() {
      if (!s.map) return;
      if (drawnAtlas !== atlasVersion) return syncAtlas();
      var W = canvas.width, H = canvas.height;
      var t0 = nowMs();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalAlpha = 1;
      ctx.fillStyle = SKY_COLOR;
      ctx.fillRect(0, 0, W, H);
      if (zoomPath(s.view.zoom) === 'thumb') drawThumbPath(W, H); else drawLayerPath(W, H);
      if (viewOptions.grid) drawGrid(W, H);
      drawMapFrames(W, H);
      drawOverlay(W, H);
      stat.renders++;
      stat.lastRenderMs = nowMs() - t0;
    }

    // ResizeObserver 统一触发尺寸重建。
    function resize() {
      var wrap = canvas.parentElement;
      var w = Math.max(1, wrap ? wrap.clientWidth : canvas.width);
      var h = Math.max(1, wrap ? wrap.clientHeight : canvas.height);
      if (canvas.width === w && canvas.height === h) return;
      canvas.width = w; canvas.height = h;
      s.view = limitView(s.view);
      ctx.imageSmoothingEnabled = false;            // 改尺寸会重置 ctx 状态,必须重设
      clearLayers();
      return drawView();
    }

    function fitViewToMap() {
      s.view.zoom = fitZoom(s.map.subCols, s.map.subRows, canvas.width, canvas.height, 24);
      s.view.x = -(canvas.width / s.view.zoom - s.map.subCols) / 2;
      s.view.y = -(canvas.height / s.view.zoom - s.map.subRows) / 2;
      viewChanged();
    }

    function drawView() {
      if (s.map && zoomPath(s.view.zoom) === 'layers') return buildLayers().then(render);
      return Promise.resolve(render());
    }

    function fit() {
      if (!s.map) return;
      fitViewToMap();
      return drawView();
    }

    // 拖动时只保存预览偏移，松手后由 moveRegion 提交地图变化。
    var drag = null, thumbDrag = null;

    function setSelDrag(sel, dx, dy) {
      s.selDrag = sel ? { sel, dx, dy } : null;
      updateDrag();
      render();
    }
    function setPreview(rect) { s.preview = rect; render(); }

    function dragSource(L, x, y, preview) {
      if (!preview || L !== preview.layer) return { hit: true, X: x, Y: y };
      var W = s.map.subCols, H = s.map.subRows;
      var moved = selectionSource(preview.sel, preview.dx, preview.dy, x, y, W, H);
      if (moved.hit) return moved;
      return { hit: !inSel(preview.sel, x, y, W, H), X: x, Y: y };
    }

    function redrawDrag(previous, next, paint) {
      if (previous && next && previous.layer === next.layer) {
        paint(next.layer, dedupRects(previous.rects.concat(next.rects)));
      } else {
        if (previous) paint(previous.layer, previous.rects);
        if (next) paint(next.layer, next.rects);
      }
    }

    function updateDrag() {
      var previous = drag;
      drag = null;
      if (s.map && s.selection && s.selDrag) {
        var { sel, dx, dy } = s.selDrag, W = s.map.subCols, H = s.map.subRows;
        var dest = { x: sel.x + dx, y: sel.y + dy, w: sel.w, h: sel.h };
        drag = { sel, dx, dy, layer: s.layer, rects: canonRects(sel, W, H).concat(canonRects(dest, W, H)) };
      }
      if (zoomPath(s.view.zoom) === 'layers') redrawDrag(previous, drag, paintLayerRegions);
    }

    function clearLayers() {
      layerCv.fill(null);
      viewChanged();
    }

    function rebuildMap(fitFirst = false) {
      ensureThumbs(s.map);
      var rebuilding = buildThumbs(), version = thumbWork;
      return rebuilding.then(function () {
        if (version !== thumbWork) return;
        if (fitFirst) fitViewToMap();
        return drawView();
      });
    }

    function invalidateAll() {
      if (!s.map) return Promise.resolve();
      cellCache.setSource();
      clearLayers();
      return rebuildMap();
    }

    function syncAtlas() {
      drawnAtlas = atlasVersion;
      cellCache.clear();
      thumbs.fill(null);
      clearLayers();
      return rebuildMap();
    }

    function setMap(map) {
      s.map = map;
      s.selection = s.preview = s.selDrag = null;
      drag = thumbDrag = null;
      drawnAtlas = atlasVersion;
      cellCache = attachCells(createCellCache({ maxCells: DEFAULT_CELL_MAX, build: buildCell }));
      clearLayers();
      if (!map) {
        thumbWork++;
        thumbs.fill(null);
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        return Promise.resolve();
      }
      return rebuildMap(true);
    }

    function editCells(L, indices) {
      if (!s.map || !indices.length) return;
      var cols = s.map.subCols, cellsWide = cols / SUB, changed = new Set();
      for (var i of indices) {
        var cx = Math.floor((i % cols) / SUB), cy = Math.floor(i / (cols * SUB));
        changed.add(cy * cellsWide + cx);
      }
      // 同一宏格只刷新一次。连续的宏格按行合并，跨接缝的两端各自刷新。
      var rects = [];
      for (var key of Array.from(changed).sort((a, b) => a - b)) {
        var x = key % cellsWide, y = Math.floor(key / cellsWide);
        if (!layerIsColor(L)) cellCache.touch(L, x, y);
        var last = rects[rects.length - 1];
        if (last && last.y === y * SUB && last.x + last.w === x * SUB) last.w += SUB;
        else rects.push({ x: x * SUB, y: y * SUB, w: SUB, h: SUB });
      }
      paintThumbRegions(L, rects);
      if (zoomPath(s.view.zoom) === 'layers') paintLayerRegions(L, rects);
      return render();
    }

    function panBy(dxPx, dyPx) {
      if (!s.map) return;
      var z = s.view.zoom, W = canvas.width, H = canvas.height;
      var next = limitView({ x: s.view.x + (isFinite(dxPx) ? dxPx / z : 0),
                             y: s.view.y + (isFinite(dyPx) ? dyPx / z : 0), zoom: z });
      var dx = Math.round((next.x - s.view.x) * z), dy = Math.round((next.y - s.view.y) * z);
      if (!dx && !dy) return;
      s.view.x += dx / z;
      s.view.y += dy / z;
      if (zoomPath(z) === 'thumb') return render();
      if (!layersClean || Math.abs(dx) >= W || Math.abs(dy) >= H) return drawView();
      var strips = panStrips(W, H, dx, dy);
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        var cv = layerCv[L], c = cv.getContext('2d');
        c.globalCompositeOperation = 'copy';
        c.drawImage(cv, -dx, -dy);
        c.globalCompositeOperation = 'source-over';
        // 边条和全幅绘制共用子格投影，覆盖小数倍率下贴边的半个像素。
        for (var r of strips) {
          paintLayerRect(L, { x: s.view.x + r.x / z, y: s.view.y + r.y / z, w: r.w / z, h: r.h / z });
        }
      }
      stat2.panCopies++;
      return render();
    }

    function setView(view) {
      s.view = limitView({ x: view.x, y: view.y, zoom: clampZoom(view.zoom ?? s.view.zoom) });
      viewChanged();
      return drawView();
    }

    function setZoomAt(px, py, factor) { return setView(zoomAround(s.view, px, py, factor)); }
    function setViewOption(key, on) {
      viewOptions[key] = on;
      if (key === 'torus') {
        var v = limitView(s.view);
        if (v.x !== s.view.x || v.y !== s.view.y) return setView(v);
      }
      return render();
    }

    return {
      setMap: setMap, map: function () { return s.map; },
      setLayer: function (L) { s.layer = L; updateDrag(); render(); }, layer: function () { return s.layer; },
      setView: setView,
      view: function () { return { x: s.view.x, y: s.view.y, zoom: s.view.zoom }; },
      setViewOption: setViewOption, viewOptions: () => ({ ...viewOptions }),
      containsPoint: containsPoint,
      // 可见性只影响合成(离屏内容照旧保留)⇒ 开关是 4 次 drawImage 的事,不重画任何一层。
      setLayerVisible: function (L, b) { s.layerVisible[L] = !!b; render(); },
      layerVisible: function (L) { return s.layerVisible[L]; },
      setLayerLocked: function (L, b) { s.layerLocked[L] = !!b; },
      layerLocked: function (L) { return s.layerLocked[L]; },
      setSelection: function (sel) { s.selection = sel; updateDrag(); render(); },
      selection: function () { return s.selection; },
      setSelDrag: setSelDrag, setPreview: setPreview,
      isDraggingSelection: function () { return !!s.selDrag; },
      render: render, resize: resize, fit: fit,
      invalidateAll: invalidateAll,
      editCells: editCells, panBy: panBy, setZoomAt: setZoomAt, buildLayers: buildLayers,
      cells: function () { return cellCache; },
      thumbCanvas: function (L) { return thumbs[L]; },
      thumbPx: function () { return thumbPx; },
      screenToSub: screenToSub, subToScreen: subToScreen,
      stats: function () {
        var cached = cellCache ? cellCache.stats() : { hits: 0, misses: 0, size: 0 };
        return { thumbMs: stat.thumbMs, renders: stat.renders, lastRenderMs: stat.lastRenderMs,
                 thumbsBuilt: stat.thumbsBuilt, cellsHits: cached.hits, cellsMisses: cached.misses,
                 cellsSize: cached.size, layerRebuilds: stat2.layerRebuilds,
                 layerRebuildMs: stat2.layerRebuildMs, panCopies: stat2.panCopies };
      },
    };
  }

  // ── 脏区 ──
  function rectUnion(a, b) {
    if (!a) return { x: b.x, y: b.y, w: b.w, h: b.h };
    if (!b) return { x: a.x, y: a.y, w: a.w, h: a.h };
    var x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
    var x2 = Math.max(a.x + a.w, b.x + b.w), y2 = Math.max(a.y + a.h, b.y + b.h);
    return { x: x, y: y, w: x2 - x, h: y2 - y };
  }
  function rectIsEmpty(r) { return !r || r.w <= 0 || r.h <= 0; }

  // 画布自拷贝之后"新露出来"的那一条(单位 = 画布像素)。位移超过画布尺寸 = 整块重画。
  // 参数是视图/世界的位移方向(view.x 增加 dxPx/zoom):画面内容是反向走的,
  //   所以"向右看 10px"新露出来的是右边那 10px。调用方那里的自拷贝偏移是它的相反数。
  function panStrips(w, h, dx, dy) {
    var out = [];
    if (dx === 0 && dy === 0) return out;
    if (Math.abs(dx) >= w || Math.abs(dy) >= h) return [{ x: 0, y: 0, w: w, h: h }];
    if (dx > 0) out.push({ x: w - dx, y: 0, w: dx, h: h });
    if (dx < 0) out.push({ x: 0, y: 0, w: -dx, h: h });
    if (dy > 0) out.push({ x: 0, y: h - dy, w: w, h: dy });
    if (dy < 0) out.push({ x: 0, y: 0, w: w, h: -dy });
    return out;
  }

  // 以光标为锚缩放:光标下的那一子格在缩放前后停在原地。
  function zoomAround(view, px, py, factor) {
    var z = clampZoom(view.zoom * (isFinite(factor) && factor > 0 ? factor : 1));
    var wx = view.x + px / view.zoom, wy = view.y + py / view.zoom;
    return { x: wx - px / z, y: wy - py / z, zoom: z };
  }

  return {
    MIN_ZOOM: MIN_ZOOM, MAX_ZOOM: MAX_ZOOM, ZOOM_THRESHOLD: ZOOM_THRESHOLD,
    THUMB_PX: THUMB_PX, THUMB_MAX_BYTES: THUMB_MAX_BYTES,
    DEFAULT_BUDGET_MS: DEFAULT_BUDGET_MS, DEFAULT_CELL_MAX: DEFAULT_CELL_MAX,
    wrapIdx: wrapIdx, quadOf: quadOf,
    layerArray: layerArray, descAt: descAt, rgbaAt: rgbaAt,
    setAtlas: setAtlas, atlasInfo: atlasInfo, atlasCapacity: atlasCapacity, tileCache: tileCache,
    attachCells, cellCache: () => cells, attachViewInvalidator,
    tileFor: tileFor,
    createCellCache: createCellCache,
    createSlicer: createSlicer,
    zoomPath: zoomPath, clampZoom: clampZoom, fitZoom: fitZoom, thumbScale: thumbScale,
    visibleSubRange: visibleSubRange, torusOffsets: torusOffsets, hitTest: hitTest,
    MAX_BRUSH_CELLS: MAX_BRUSH_CELLS, brushSpan: brushSpan, brushRegion: brushRegion, snapHit: snapHit,
    selectionSource: selectionSource, inSel: inSel,
    rectUnion: rectUnion, rectIsEmpty: rectIsEmpty,
    panStrips: panStrips, zoomAround: zoomAround, VIEW_DEFAULTS: VIEW_DEFAULTS,
    DRAW_ORDER: DRAW_ORDER, mount: mount,
  };
})();
