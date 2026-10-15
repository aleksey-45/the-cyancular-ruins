// ui/45_history.js —— 撤销差量:快照、选区搬运、剪贴板、历史环。

// 用法:var wd = wholeDiff(map, 'resize'); …做完改动…; wd.seal(); history.push(wd.entry);
function wholeDiff(map, tag) {
  var entry = { kind: 'whole', tag: tag || '', before: snapshotMap(map), bytes: 0 };
  entry.bytes = bytesOfSnapshot(entry.before);
  return {
    entry: entry,
    seal: function () {
      entry.after = snapshotMap(map);
      entry.bytes += bytesOfSnapshot(entry.after);
      return entry;
    },
  };
}
// ★★ 必须原地装字段、不能换引用:seal() 快照的是建它时抓的那个对象(闭包参数,不是"当时的
//    app.map"),中间换 app.map ⇒ after 拿到的仍是改前那份(before === after),撤销/重做双双
//    无效,而一个字都不报。★ 字段表与 applyEntry 的 whole 分支同一份(那边是防御性拷贝,
//    因为快照与地图长期共存;这里相反 —— out.map 只有本函数一个持有者,照搬完就该丢掉它)。
function adoptMapInto(dst, src) {
  dst.subCols = src.subCols; dst.subRows = src.subRows;
  dst.layers = src.layers;
  dst.players = src.players; dst.enemies = src.enemies;
  dst.comments = src.comments;
  return dst;
}
function applyEntry(map, e, dir) {
  if (!e) return;
  var i;
  if (e.kind === 'cells') {
    var arr = Render.layerArray(map, e.layer);
    if (!arr) return;
    var src = dir < 0 ? e.before : e.after;
    for (i = 0; i < e.idx.length; i++) arr[e.idx[i]] = src[i];
    return;
  }
  if (e.kind === 'spawn') {
    var v = dir < 0 ? e.before : e.after;
    map.players = v.players.map(function (p) { return { x: p.x, y: p.y }; });
    map.enemies = v.enemies.map(function (q) { return { type: q.type, x: q.x, y: q.y }; });
    return;
  }
  if (e.kind === 'whole') {
    var s = dir < 0 ? e.before : e.after;
    if (!s) {
      // ★ after 不存在时原先这里是静默 return,成因只有一种:wholeDiff 还没 seal() 就把 entry
      //   塞进了历史。症状是"撤销有反应、重做一点反应都没有"且不报错 ⇒ 如实上报。
      //   ★ 不抛异常:走到这里时历史栈已经动过了(undo 已把这条 pop 进 redo 栈),抛出会把历史
      //   留在半截状态 —— 这是"要看得见",不是"要炸掉"。
      reportError('重做无效:这条整图级历史没有 after 快照(wholeDiff 的 seal() 还没调用,条目就进了历史)');
      return;
    }
    map.subCols = s.subCols; map.subRows = s.subRows;
    // ★★ map.layers 必须防御性拷贝:直接 alias 快照数组的话,撤销之后地图与 entry.before 共用
    //    同一份 TypedArray —— 用户再落一笔就写进了历史条目里,下一次撤销恢复的是被污染的 before
    //    ("撤销没撤干净"且不报错;字节数也不变,字节闸发现不了)。
    map.layers = s.layers.map(function (lay) {
      if (!lay) return null;
      return lay.kind === 'tex' ? { kind: 'tex', desc: new Uint32Array(lay.desc) }
                                : { kind: 'color', rgba: new Uint32Array(lay.rgba) };
    });
    map.players = s.players.map(function (p) { return { x: p.x, y: p.y }; });
    map.enemies = s.enemies.map(function (q) { return { type: q.type, x: q.x, y: q.y }; });
    map.comments = s.comments.slice();
  }
}
// 差量 → 去重后的格坐标列表(交给 renderer.editCells 作废 ③ 与重画缩略图)
function diffCells(map, e) {
  if (!e || e.kind !== 'cells') return [];
  var seen = new Set(), out = [];
  for (var i = 0; i < e.idx.length; i++) {
    var X = e.idx[i] % map.subCols, Y = Math.floor(e.idx[i] / map.subCols);
    var cx = Math.floor(X / Core.SUB_PER_CELL), cy = Math.floor(Y / Core.SUB_PER_CELL);
    var k = cx + '/' + cy;
    if (seen.has(k)) continue;
    seen.add(k); out.push({ cx: cx, cy: cy });
  }
  return out;
}
function cellCountOf(map, L) {
  var a = Render.layerArray(map, L);
  if (!a) return 0;
  var n = 0;
  for (var i = 0; i < a.length; i++) if (a[i] !== 0) n++;
  return n;
}

// ── 剪贴板(跨图层粘贴只允许"纹理 ↔ 纹理")──
function copyRegion(map, L, sel) {
  if (!sel) return null;
  var arr = Render.layerArray(map, L);
  var n = sel.w * sel.h, x, y;
  if (L === Core.LAYER_BG) {
    var rgba = new Uint32Array(n);
    for (y = 0; y < sel.h; y++) {
      for (x = 0; x < sel.w; x++) rgba[y * sel.w + x] = arr ? arr[idxOf(map, sel.x + x, sel.y + y)] : 0;
    }
    return { kind: 'color', w: sel.w, h: sel.h, rgba: rgba };
  }
  var desc = new Uint32Array(n);
  for (y = 0; y < sel.h; y++) {
    for (x = 0; x < sel.w; x++) desc[y * sel.w + x] = arr ? arr[idxOf(map, sel.x + x, sel.y + y)] : 0;
  }
  return { kind: 'tex', w: sel.w, h: sel.h, desc: desc };
}
function clipSize(clip) { return clip ? { w: clip.w, h: clip.h } : { w: 0, h: 0 }; }
// ★ 决定 ④:两种数据类型不互相猜。拒绝时给出原因(状态栏要显示),不静默。
function pasteRegion(map, L, clip, X, Y) {
  if (!clip) return { ok: false, why: '剪贴板是空的' };
  var isColorLayer = (L === Core.LAYER_BG);
  if (isColorLayer && clip.kind !== 'color') {
    return { ok: false, why: '剪贴板是纹理层内容,不能粘到背景层(两种数据类型不互转)' };
  }
  if (!isColorLayer && clip.kind !== 'tex') {
    return { ok: false, why: '剪贴板是背景层的颜色,不能粘到纹理层' };
  }
  var targets = [], values = [], x, y;
  for (y = 0; y < clip.h; y++) {
    for (x = 0; x < clip.w; x++) {
      targets.push(idxOf(map, Math.floor(X) + x, Math.floor(Y) + y));
      values.push(clip.kind === 'tex' ? clip.desc[y * clip.w + x] : clip.rgba[y * clip.w + x]);
    }
  }
  var order = 0;
  var diff = paintCells(map, L, targets, function () { return values[order++]; });
  return { ok: true, diff: diff };
}

// ── 选区移动 ──
// ★ 新实现没有"裁剪"这一步:目标格 = 源格 + 偏移(两边都环面折算),源区里没被目标覆盖的格
//   被清空。于是"拖到图外"在环面上就是恒等位移(旧实现漏了 − 选区.x,会静默删掉被裁的列)。
function moveRegion(map, L, sel, dx, dy) {
  if (!sel) return null;
  var arr = Render.layerArray(map, L);
  if (!arr) return null;
  var from = new Map(), to = new Map();
  var x, y;
  for (y = 0; y < sel.h; y++) {
    for (x = 0; x < sel.w; x++) {
      var si = idxOf(map, sel.x + x, sel.y + y);
      var di = idxOf(map, sel.x + x + dx, sel.y + y + dy);
      from.set(si, true);
      to.set(di, arr[si]);                       // ★ 一次性算出目标值(基于旧数组读)
    }
  }
  var keys = new Set();
  to.forEach(function (_, k) { keys.add(k); });
  from.forEach(function (_, k) { keys.add(k); });   // 源区里没被覆盖的格 → 写空气
  var idx = [], before = [], after = [];
  keys.forEach(function (k) {
    var nv = to.has(k) ? to.get(k) : 0;
    if (arr[k] === nv) return;
    idx.push(k); before.push(arr[k]); after.push(nv);
  });
  for (var i = 0; i < idx.length; i++) arr[idx[i]] = after[i];
  if (!idx.length) return null;
  return { kind: 'cells', layer: L, idx: Int32Array.from(idx),
           before: Uint32Array.from(before), after: Uint32Array.from(after), tag: 'move' };
}

// ── 镜像(规格 §4.4 的选框:可移动 / 删除 / 复制粘贴 / 镜像)──
function mirrorRegion(map, L, sel, axis) {
  if (!sel) return null;
  // ★★ 非法 axis 必须当场说人话:靠"两个坐标算出来一样"退化成恒等再静默回 null,与"镜像了
  //    一圈、内容恰好没变"在返回值上完全同形,调用方分不出"轴写错了"和"这次镜像没改动任何格"。
  // ★ 处理方式同 createGradientJob 对非法图层:调用方的编程错误 ⇒ 抛一条带原因的中文错;回
  //    {ok:false, why} 会把本函数文档化的返回类型 diff|null 破成三种形状,上层 guard 接住即可。
  if (axis !== 'h' && axis !== 'v') {
    throw new Error('镜像轴非法(只能是 h 水平 / v 垂直):实得 ' + String(axis));
  }
  var arr = Render.layerArray(map, L);
  if (!arr) return null;
  var idx = [], before = [], after = [], x, y;
  for (y = 0; y < sel.h; y++) {
    for (x = 0; x < sel.w; x++) {
      var sx = (axis === 'h') ? (sel.w - 1 - x) : x;
      var sy = (axis === 'v') ? (sel.h - 1 - y) : y;
      var di = idxOf(map, sel.x + x, sel.y + y);
      var si = idxOf(map, sel.x + sx, sel.y + sy);
      if (arr[di] === arr[si]) continue;
      idx.push(di); before.push(arr[di]); after.push(arr[si]);
    }
  }
  for (var i = 0; i < idx.length; i++) arr[idx[i]] = after[i];
  if (!idx.length) return null;
  return { kind: 'cells', layer: L, idx: Int32Array.from(idx),
           before: Uint32Array.from(before), after: Uint32Array.from(after), tag: 'mirror' };
}
// 镜像当前选区(mirrorRegion 的生产入口:热键 H / V)。
// ★★ 三条纪律各挡一种"看不见的坏":① 非法轴抛出的错必须经 guard 落到状态栏,而下面那句
//    "if (out.threw) return;" 是承重的 —— 少了它,"没改动"文案会把刚写上去的错覆盖掉;
//    ② 抛出的错绝不许进历史(历史只收 diff|null);③ 什么都没变(单格或回文)不落历史。
function mirrorSelection(axis) {
  var sel = app.r.selection();
  if (!sel) { status('先框选一块,再按 H(水平)/ V(垂直)镜像'); return null; }
  var out = { diff: null, threw: false };
  guard('镜像', function () {
    try { out.diff = mirrorRegion(app.map, app.r.layer(), sel, axis); }
    catch (e) { out.threw = true; throw e; }        // 上报给 sink(见 ①),但要先记下来
    return null;
  });
  if (out.threw) return null;                       // ★★ 状态栏上那句话是错的说明,别覆盖它
  if (!out.diff) { status('镜像:选区内容没变(这条轴上是回文),没有改动地图'); return null; }
  pushAndShow(out.diff);
  status('已' + (axis === 'h' ? '水平' : '垂直') + '镜像选区(' +
         (sel.w / Core.SUB_PER_CELL) + '×' + (sel.h / Core.SUB_PER_CELL) + ' 格)');
  return out.diff;
}

// ── 交互(指针 / 滚轮 / 热键)──
// ★ 一切落笔都走同一条路:applyTool(只碰地图)→ 差量进历史 → renderer.editCells(只碰缓存与
//   像素)。把"改数据"与"作废缓存"分成两步是刻意的:漏了哪一半都能在断言里指名道姓。
var undoHistory = null;
var clipboard = null;
