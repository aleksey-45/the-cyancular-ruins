// ui/30_resize.js —— 画布尺寸变更与越界内容清理。

function resizeMap(map, w, h) {
  var out = createEmptyMap(map.name, w, h);          // ← 尺寸闸只在这一条路上
  var copyW = Math.min(map.subCols, out.subCols), copyH = Math.min(map.subRows, out.subRows);
  for (var L = 0; L < Core.LAYER_COUNT; L++) {
    var src = Render.layerArray(map, L), dst = Render.layerArray(out, L);
    if (!src) { out.layers[L] = null; continue; }    // 缺席层保持缺席(不是"补一层空的")
    for (var y = 0; y < copyH; y++) {
      for (var x = 0; x < copyW; x++) dst[y * out.subCols + x] = src[y * map.subCols + x];
    }
  }
  out.comments = map.comments.slice();
  var dropped = [];
  var cellsW = Core.cellsWOf(out), cellsH = Core.cellsHOf(out);
  var inRange = function (p) { return p.x >= 0 && p.y >= 0 && p.x < cellsW && p.y < cellsH; };
  var i;
  for (i = 0; i < map.players.length; i++) {
    if (inRange(map.players[i])) out.players.push({ x: map.players[i].x, y: map.players[i].y });
    else dropped.push({ kind: 'player', x: map.players[i].x, y: map.players[i].y });
  }
  for (i = 0; i < map.enemies.length; i++) {
    var e = map.enemies[i];
    if (inRange(e)) out.enemies.push({ type: e.type, x: e.x, y: e.y });
    else dropped.push({ kind: 'enemy', type: e.type, x: e.x, y: e.y });
  }
  return { map: out, dropped: dropped, size: { w: cellsW, h: cellsH } };
}
// ★★ 尺寸闸只此一条路:applySize → resizeMap → createEmptyMap → Core.clampMapSize。这里不再
//    写第二次 Core.createMap 这个调用(相位 ⑪ 数着那个调用点),第二个造图入口就是 A8 复发(输 99999 卡死)。
function resizeReportLines(dropped) {
  return (dropped || []).map(function (d) {
    return d.kind === 'enemy'
      ? ('敌人 ' + d.type + ' 落在图外 (' + d.x + ',' + d.y + '),已移除')
      : ('出生点落在图外 (' + d.x + ',' + d.y + '),已移除');
  });
}
// ★ 输入框回显只在这一个函数里写(DOM 与状态一致):输了 99999 而框里仍写着 99999、图却已是 400×300。
function sizeInputsSync() {
  if (!app.map) return;
  var w = $('size-w'), h = $('size-h');
  if (w) w.value = String(Core.cellsWOf(app.map));
  if (h) h.value = String(Core.cellsHOf(app.map));
}
// ★★ "这一格没有给一个数"的判据:parseInt 出来不是有限数(与 Core.clampMapSize 同一把尺子)。
//    空串会让它回落到 125×75(造新图的语义)⇒ 一次静默缩图:400×300 把宽那格删空就变成 125×300。
function sizeInputNum(el) {
  if (!el) return null;
  var n = parseInt(String(el.value == null ? '' : el.value), 10);
  return isFinite(n) ? n : null;
}
// ★★ 选区必须装得下当前尺寸才留得住:invalidateAll 不清选区(只有 setMap 清),留下的框画在图外,
//    而所有消费选区的工具都走 idxOf 的取模折算 ⇒ 静默把图外的格折回图里落笔,一个字都不报。
function dropStaleSelection() {
  if (!app.r || !app.map) return false;
  var sel = app.r.selection();
  if (!sel) return false;
  if (sel.x + sel.w <= app.map.subCols && sel.y + sel.h <= app.map.subRows) return false;
  app.r.setSelection(null);
  return true;
}
function applySize() {
  if (!app.map) { status('先打开一张地图'); return null; }
  var wEl = $('size-w'), hEl = $('size-h');
  var curW = Core.cellsWOf(app.map), curH = Core.cellsHOf(app.map);
  // ★ 闸 1:用户输入一律钳制,不报错回滚(NaN / 0 / 99999 都落到合法区间)
  var wNum = sizeInputNum(wEl), hNum = sizeInputNum(hEl);
  var c = Core.clampMapSize(wNum === null ? curW : wNum, hNum === null ? curH : hNum);
  var ig = [];
  if (wNum === null) ig.push('宽保留 ' + curW);
  if (hNum === null) ig.push('高保留 ' + curH);
  var igTxt = ig.length ? (';' + ig.join(',') + '(那一格是空的或不是数字 ⇒ 这一项不改)') : '';
  if (c.w === curW && c.h === curH) {
    sizeInputsSync();                     // ★ 钳制结果照样回显(输 99999 → 框里变 400)
    status('尺寸没变(' + c.w + '×' + c.h + '),没有改动地图' + igTxt);
    return null;
  }
  // ★★ before 快照必须取在改之前,而 wholeDiff 的 seal() 快照的是建它时抓的那个对象
  //    ⇒ 只能原地装进去(adoptMapInto);直接换 app.map 引用会 before === after,撤销/重做双双无效。
  var wd = wholeDiff(app.map, 'resize');
  var out = resizeMap(app.map, c.w, c.h);
  adoptMapInto(app.map, out.map);
  pushAndShow(wd.seal());
  // ★ 状态栏那一格与两个输入框都要跟着翻:pushAndShow 只调 statusLine(),不含尺寸也不碰输入框。
  refreshStatus();
  var selDropped = dropStaleSelection();
  // ★★ A10:越界项要报出来(resizeMap 只丢不钳 —— 钳一个出生点到边界是替用户做决定);静默清理
  //    等于"导出去游戏读到网格外坐标"。
  var lines = resizeReportLines(out.dropped);
  status('尺寸改为 ' + out.size.w + '×' + out.size.h + ' 格' +
         (lines.length ? (';A10 越界项已清理 ' + lines.length + ' 项:' + lines.join(';'))
                       : ';没有越界项') +
         igTxt +
         (selDropped ? ';选区超出新尺寸,已清掉' : ''));
  return null;
}
