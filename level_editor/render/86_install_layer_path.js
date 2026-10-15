// render/86_install_layer_path.js —— ② 视口离屏层簇:脏区重画、整片分帧重建、3×3 合成。

function installLayerPath(S) {
  var s = S.s, canvas = S.canvas, ctx = S.ctx;
  var layerCv = S.layerCv, layerDirty = S.layerDirty, slicer = S.slicer, stat2 = S.stat2;
  var layerGen = 0;                             // ★ 视图/图集/尺寸的代际:在飞的那一轮重建靠它作废
  // ★★ 视图一动,在飞的那一轮重建整个作废:条带矩形是按旧视图算的,而 paintLayerRect 又按当前视图换算像素 ⇒ 剩下的条带画到了别处。
  //    更糟的是它会与"自拷贝搬移"混在一起(搬移的前提是整张图属于同一次视图的产物),而脏标记此刻已经清干净了 ⇒ 纪律:视图不干净时平移一律改走整片重建(见 panBy 的第一条判据)。
  function viewChanged() { layerGen++; S.layersClean = false; }

  function ensureLayerCanvas(L) {
    if (layerCv[L] && layerCv[L].width === canvas.width && layerCv[L].height === canvas.height) return layerCv[L];
    var c = document.createElement('canvas');
    c.width = canvas.width; c.height = canvas.height;
    c.getContext('2d').imageSmoothingEnabled = false;   // ★ 离屏也必须关插值,否则放大后砖块是糊的
    layerCv[L] = c;
    layerDirty[L] = null;
    return c;
  }

  // ③ 的 build 回调:把一格的 16 个子格解析成 16 个 tile 引用(空气 → null);像素只存在 ④ 里,故 ③ 的条目极小。
  // ★★ 只有纹理层会走到这里 —— 颜色层的 16 个子格是 RGBA,由 paintLayerRect 的颜色分支直接取色;两者长得一模一样、含义完全不同,判据一律取 layerIsColor。
  function buildCell(L, cx, cy) {
    var out = new Array(SUB * SUB);
    var bx = cx * SUB, by = cy * SUB;
    for (var qy = 0; qy < SUB; qy++) {
      for (var qx = 0; qx < SUB; qx++) {
        var raw = descAt(s.map, L, bx + qx, by + qy);
        out[qy * SUB + qx] = (raw === 0 || RenderCore.texOf(raw) === 0) ? null : tileFor(raw, qx, qy);
      }
    }
    return out;
  }

  // 重画某一层的离屏上的一块矩形(单位 = 子格;矩形允许越出画布与主网格,内部裁剪)。
  // ★ 越出主网格是常态:离屏层的像素系与屏幕同一套,视图越过接缝时那半边像素只有靠折算后的格才填得上(descAt 本来就环面折算);绝不许按主网格裁剪 —— 裁了就是视图拖过边界时的一整条空白,而 3×3 副本填不上它(理由见 buildLayers)。
  function paintLayerRect(L, rect) {
    var cv = ensureLayerCanvas(L);
    var c = cv.getContext('2d');
    var z = s.view.zoom;
    var px0 = Math.max(0, Math.floor((rect.x - s.view.x) * z));            // 世界子格 → 画布局部像素
    var py0 = Math.max(0, Math.floor((rect.y - s.view.y) * z));
    var px1 = Math.min(cv.width, Math.ceil((rect.x + rect.w - s.view.x) * z));
    var py1 = Math.min(cv.height, Math.ceil((rect.y + rect.h - s.view.y) * z));
    if (px1 <= px0 || py1 <= py0) return;
    c.clearRect(px0, py0, px1 - px0, py1 - py0);
    if (!layerArray(s.map, L)) return;                 // 缺席层 = 全空气(已清干净)
    var cell0x = Math.floor((s.view.x + px0 / z) / SUB), cell1x = Math.ceil((s.view.x + px1 / z) / SUB);
    var cell0y = Math.floor((s.view.y + py0 / z) / SUB), cell1y = Math.ceil((s.view.y + py1 / z) / SUB);
    var colorLayer = layerIsColor(L);           // ★★ 按层种类分派(判据取一次,不在逐格循环里重算)—— 这就是那道闸门
    var cw = RenderCore.cellsWOf(s.map), ch = RenderCore.cellsHOf(s.map);
    for (var cy = cell0y; cy < cell1y; cy++) {
      for (var cx = cell0x; cx < cell1x; cx++) {
        var bx = cx * SUB, by = cy * SUB;
        if (colorLayer) {
          // 颜色层:逐子格读 RGBA、直接填色。alpha = 0 = 这一格没有颜色(上面已 clearRect,这里什么都不画)。★ 这里不许出现 texOf(见 buildCell 的两条静默症状)。
          for (var kc = 0; kc < SUB * SUB; kc++) {
            var Xc = bx + (kc % SUB), Yc = by + Math.floor(kc / SUB);
            var qc = S.dragSource(L, Xc, Yc);              // ★ 拖动中:读源子格(纯读;只对活动层)
            var rawc = qc.hit ? descAt(s.map, L, qc.X, qc.Y) : 0;
            if (((rawc >>> 0) & 255) === 0) continue;
            c.fillStyle = S.cssOfRGBA(rawc);
            c.fillRect((Xc - s.view.x) * z, (Yc - s.view.y) * z, z, z);
          }
          continue;
        }
        // ★ ③ 的键必须是主网格上的格号:环面让同一格有多种写法(cx = -1 与 cx = cellsW-1),不折算的话同一格会缓存两条条目,而编辑只 touch 其中一条 ⇒ 接缝另一侧的副本继续显示陈旧内容(画面错了、一个字都不报)。
        // ★★ 拖动偏移从这里接:拖动中读的是源格(纯读,不改进数据),画的位置仍是目标格(bx/by)—— 只有"读"是偏移过的;传进去的子格坐标取缓存键前再折回格号。
        var gx = wrapIdx(cx, cw), gy = wrapIdx(cy, ch);
        var q = S.dragSource(L, gx * SUB, gy * SUB);
        if (!q.hit) continue;                            // 被腾空的源区 ⇒ 这一格不画
        var tilesOfCell = S.cellCache.get(L, wrapIdx(Math.floor(q.X / SUB), cw),
                                           wrapIdx(Math.floor(q.Y / SUB), ch));  // ★ ③:这一格的 16 个 tile
        for (var k = 0; k < tilesOfCell.length; k++) {
          var t = tilesOfCell[k];
          if (!t) continue;
          var X = bx + (k % SUB), Y = by + Math.floor(k / SUB);   // ★ 画在目标格的位置
          c.drawImage(t, (X - s.view.x) * z, (Y - s.view.y) * z, z, z);
        }
      }
    }
  }

  // 重建所有"脏"的离屏层(编辑之后只重画脏矩形 ⇒ 成本 O(脏区),不是 O(全屏))。★ 隐藏层也照画:离屏内容与可见性无关,反过来会让"隐藏 → 编辑 → 显示"看到一片旧内容。
  function flushDirty() {
    for (var L = 0; L < RenderCore.LAYER_COUNT; L++) {
      if (!layerDirty[L]) continue;
      var d = layerDirty[L];
      layerDirty[L] = null;
      if (!layerArray(s.map, L)) { ensureLayerCanvas(L).getContext('2d').clearRect(0, 0, canvas.width, canvas.height); continue; }
      paintLayerRect(L, d);
      stat2.layerRebuilds++;
    }
  }

  // ★★ 全屏重建:重画的世界范围就是可见范围本身(visibleSubRange),不裁到主网格 —— 离屏层的像素系与屏幕同一套,可见范围里落在主网格之外的像素(视图越过接缝时必然出现)必须用折算后的格去填;裁了会留一整条空白,而 3×3 的副本填不上:副本的贴图偏移是「副本世界偏移 × zoom」,视口 12.5 格宽、地图 500 格时隔壁副本被平移 −8000px、整个落在画布外。
  function buildLayers() {
    if (!s.map) return Promise.resolve();
    // ★★ 入口就把 layersClean 放下:++layerGen 只作废在飞的那一轮,管不到"这一轮还没落地",而"还没落地"这段时间里离屏层是半旧的;本方法是公开入口(见文件尾的导出表),调用方完全可能不先走 viewChanged() 就进来。
    S.layersClean = false;
    var myGen = ++layerGen;
    var r = visibleSubRange(s.view, canvas.width, canvas.height, s.map.subCols, s.map.subRows);
    var tasks = [];
    var bands = 16;
    var h = Math.max(1, Math.ceil((r.y1 - r.y0) / bands));
    for (var L = 0; L < RenderCore.LAYER_COUNT; L++) {
      layerDirty[L] = null;
      ensureLayerCanvas(L);
      for (var y = r.y0; y < r.y1; y += h) {
        tasks.push({ L: L, rect: { x: r.x0, y: y, w: r.x1 - r.x0, h: Math.min(h, r.y1 - y) } });
      }
    }
    var t0 = S.nowMs();
    return slicer.run(tasks, function (t) {
      if (myGen !== layerGen) return;              // ★ 过期的一轮:整条作废(视图/尺寸/图集已变)
      paintLayerRect(t.L, t.rect);
    }).then(function () {
      if (myGen !== layerGen) return;              // ★ 过期的一轮不许把 layersClean 抬起来
      stat2.layerRebuildMs = S.nowMs() - t0;
      S.layersClean = true;
    });
  }

  // ★★ 3×3 的合成:每份副本都是把同一张离屏层按「副本世界偏移 × zoom」平移后再画一次;偏移是 subCols/subRows 的整数倍,而 paintLayerRect 读格时本来就环面折算 ⇒ 每份副本在任意位置画出来的内容都等于该处应有的内容。
  // ★★ 但别把"多份副本"读成承重:离屏层的像素系 = 屏幕系,它上面已经按可见范围本身把每一处应有的内容都铺好了 —— 越出主网格的那些像素由 paintLayerRect 的环面折算补上。
  //    所以那几份副本画的是同一批像素、在当前坐标系下是冗余的;"屏幕每一处都有一份盖上去"这个保证来自 paintLayerRect 的折算,不是来自这里。留着它们的理由:环面 N×N 铺贴是刻意保留的交付面,且 setTorus 开关的可见行为就是它(render_smoke 相位 ⑩d 钉住的 [8,4]);真要省这几笔,把 offs 收成 [[0,0]] 即可(⑩d 的期望值要同改)—— 那是省冗余,不是拆保证。
  function drawLayerPath(W, H) {
    flushDirty();
    var offs = S.torusList(W, H);
    var z = s.view.zoom;
    for (var oi = 0; oi < DRAW_ORDER.length; oi++) {
      var L = DRAW_ORDER[oi];
      if (!s.layerVisible[L] || !layerCv[L]) continue;
      // ★ 尺寸对不上的离屏层(改窗口之后、重建还没跑到)一路都不许画:它的像素刻度属于上一块画布,画出去是"整层错位",而空白会被下一次重建补上(resize 已经把它丢掉)。
      if (layerCv[L].width !== W || layerCv[L].height !== H) continue;
      ctx.globalAlpha = (s.dimOthers && L !== s.layer && L !== RenderCore.LAYER_BG) ? 0.4 : 1;
      for (var i = 0; i < offs.length; i++) {
        ctx.drawImage(layerCv[L], offs[i][0] * z, offs[i][1] * z);
      }
    }
    ctx.globalAlpha = 1;                         // ★ 切层 ≠ 重画:压暗/可见性只在合成这一层做(4 次 drawImage),不碰任何一层的离屏内容
  }

  S.viewChanged = viewChanged;
  S.buildCell = buildCell;
  S.paintLayerRect = paintLayerRect;
  S.buildLayers = buildLayers;
  S.drawLayerPath = drawLayerPath;
}
