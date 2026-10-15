// ui/60_brush_layer.js —— 画笔档位、图层切换、v3 迁移确认。


var BRUSH_STEPS = [0.25, 0.5, 0.75, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
function bumpBrush(cur, dir) {
  var i = BRUSH_STEPS.indexOf(cur);
  if (i < 0) i = 3;
  return BRUSH_STEPS[Math.max(0, Math.min(BRUSH_STEPS.length - 1, i + dir))];
}
function setBrush(v) {
  app.st.brushSize = Math.max(0.25, Math.min(Render.MAX_BRUSH_CELLS, v));
  var el = $('brush-size');
  if (el) el.value = String(app.st.brushSize);
  statusLine();
}
function arrowPan(dir) {
  var step = 64;
  var d = { left: [-step, 0], right: [step, 0], up: [0, -step], down: [0, step] }[dir];
  if (!d) return null;
  return Promise.resolve(app.r.panBy(d[0], d[1]));      // ★ 视图入口:promise 交给 guard
}
function selectToolButton() {
  document.querySelectorAll('#toolbar .tool').forEach(function (b) {
    b.classList.toggle('on', b.dataset.tool === app.st.tool);
  });
  statusLine();
}
function setLayer(L) {
  if (!(L >= 0 && L < Core.LAYER_COUNT)) return;
  app.r.setLayer(L);
  document.querySelectorAll('#layers .layer-row').forEach(function (row) {
    row.classList.toggle('cur', parseInt(row.dataset.layer, 10) === L);
  });
  // ★ 规格 §4.5:选中的是背景层时,右侧的纹理调色板换成颜色选择器,工具条里只有「渐变」额外可用。
  if (typeof syncPanelForLayer === 'function') syncPanelForLayer();
  statusLine();
}

// ★★ v3 源首次保存要显式确认 + 一份原文备份:maps/*.cyrm 今天全是 v3 文本,而 Ctrl+S 写回原文件 ⇒ 一次 Ctrl+S 就把原文转成 v4,而迁移是单向的(规格 §3.6)。
var v3Confirmed = false;
function needsV3Confirm(srcFmt, confirmed) {
  if (!srcFmt) return false;
  return (srcFmt === 'v3' || srcFmt === 'legacy') && !confirmed;
}
// ★★ 确认与备份是两条独立的门:确认每会话一次(v3Confirmed),备份每个文件一次(v3BackedUp)——
//    共用同一个会话级标记时,保存第二张 v3 图的两半都不发生(静默转 v4),安全网只盖住第一张。
//    ★ 用 Set 而不是普通对象:__proto__.cyrm 这种键在普通对象上赋值会被静默忽略(读回来是 Object.prototype)。
var v3BackedUp = new Set();
function needsV3Backup(srcFmt, fileName, backed) {
  if (!srcFmt || !fileName) return false;
  if (!(srcFmt === 'v3' || srcFmt === 'legacy')) return false;
  return !backed.has(fileName);
}
function freshName(base) { return Core.sanitizeName(base) + '.cyrm'; }
// ★★ 备份名结尾不是 .cyrm ⇒ 游戏的 _random_cyrm 抽不到它,备份不会混进随机地图池。★ 名字里的哈希
//    是必需的:"收干净 + 截前 40 字"不是单射(图1.cyrm 与 1.cyrm 收完都是 1),撞名会静默覆盖退路。
var V3_BACKUP_SUFFIX = '.v3.bak';
var V3_BACKUP_STEM_MAX = 24;
function fnv1a32(str) {
  var h = 0x811c9dc5;
  for (var i = 0; i < str.length; i++) {
    h = h ^ str.charCodeAt(i);
    // ★ Math.imul 才是 32 位乘法:h * 16777619 在双精度里溢出,低位不可靠。
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}
function v3BackupName(name) {
  var full = String(name == null ? '' : name);
  // ★ 基名只许 [A-Za-z0-9_-](服务器的 MAP_NAME_RE 没有放宽):种子名可能来自 freshName(它放行汉字),
  //   不过滤的话备份会被 400 拒掉,而"备份写不进去就不写盘"会把保存整个卡死。
  var base = full.replace(/\.cyrm$/i, '').replace(/[^A-Za-z0-9_-]/g, '');
  if (!base) base = 'map';
  var hex = fnv1a32(full).toString(16);
  while (hex.length < 8) hex = '0' + hex;
  return base.slice(0, V3_BACKUP_STEM_MAX) + '_' + hex + V3_BACKUP_SUFFIX;
}
// ★ 备份不是地图:它的内容是这张图原文的最后一手退路,把它当保存目标就地覆盖 = 退路换成 v4 且名字漂掉。
function isBackupName(name) {
  var s = String(name == null ? '' : name);
  if (s.length <= V3_BACKUP_SUFFIX.length) return false;
  return s.slice(-V3_BACKUP_SUFFIX.length).toLowerCase() === V3_BACKUP_SUFFIX;
}
function saveTargetName(asNew) {
  if (!app.map) return null;
  return asNew ? freshName((app.map.name || 'map') + '_copy') : app.name;
}
