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
  document.querySelectorAll('#tools .tool').forEach(function (b) {
    b.classList.toggle('on', b.dataset.tool === app.st.tool);
  });
  // 工具细分选项跟着换组(函数在 85_panels.js;启动早期可能还没定义 ⇒ 守卫)
  if (typeof syncToolOptions === 'function') syncToolOptions();
  statusLine();
}

// ── 图层"可编辑目标"三态:不存在(null) / 锁定 / 隐藏 ──
// ★★ 用户反馈 ⑥「图层有严重 bug」的真正落点:实盘图的 layer_flags 只有场景层(0b0010)⇒ 另外
//    三层在内存里是 null,点进去画什么都不发生且零提示;而 🔒 以前是纯装饰(没有任何落笔路径读它)。
//    这两件事的收口就是这一个函数 —— 所有落笔/粘贴/镜像/选区搬运都必须先问它。
var hiddenWarned = {};                 // "这一层隐藏"每次切换只提示一次,免得每一笔都刷状态栏
function layerExists(L) {
  return !!(app.map && Render.layerArray(app.map, L));
}
function existingLayerNames() {
  if (!app.map) return '(没有地图)';
  var out = [];
  for (var L = 0; L < Core.LAYER_COUNT; L++) if (layerExists(L)) out.push(Core.LAYER_NAMES[L]);
  return out.length ? out.join('/') : '(没有图层)';
}
// ★ map 参数:落笔函数自己拿到的那张图(测试会传独立造的图,此时不能拿 app.map 当判据)。
//   锁定/可见只在"正在编辑的就是当前打开的那张图"时才是拦截理由;别的 map 只判层存在性。
function canEditLayer(L, map) {
  var m = map || app.map;
  if (!m) { status('先打开一张地图'); return false; }
  if (!Render.layerArray(m, L)) {
    status('「' + Core.LAYER_NAMES[L] + '」这一层在这张图里不存在(layer_flags 缺位):本图只有 ' +
           existingLayerNames() + '。要四层齐全请用顶部「新建」。');
    return false;
  }
  if (m !== app.map || !app.r) return true;
  if (app.r.layerLocked && app.r.layerLocked(L)) {
    status('「' + Core.LAYER_NAMES[L] + '」已锁定 —— 先在图层行解锁再画');
    return false;
  }
  if (app.r.layerVisible && !app.r.layerVisible(L) && !hiddenWarned[L]) {
    hiddenWarned[L] = true;
    status('提示:「' + Core.LAYER_NAMES[L] + '」当前隐藏 —— 笔迹会写进数据,但屏幕上看不到');
  }
  return true;
}
// 图层行的图标必须**从状态反推**(而不是只靠点击时改一次):🔒/🔓 用字形表达锁定,
// 👁 用明暗表达可见;缺席层在行内标「本图无此层」,用户才不会把"空的"当成"坏的"。
function syncLayerIcons() {
  var rows = document.querySelectorAll('#layers .layer-row');
  // ★ 空启动(没有地图)时不该把四行都标成「本图无此层」—— 那不是"缺层",是"没有图"。
  //   这一态整块淡出,交给画布中央的 #empty-hint 说话。
  if (!app.map) {
    for (var r0 = 0; r0 < rows.length; r0++) {
      rows[r0].style.opacity = '0.45';
      if (rows[r0]._goneEl && rows[r0]._goneEl.parentNode &&
          typeof rows[r0]._goneEl.parentNode.removeChild === 'function') {
        rows[r0]._goneEl.parentNode.removeChild(rows[r0]._goneEl);
      }
      rows[r0]._goneEl = null;
    }
    return;
  }
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i], L = parseInt(row.dataset.layer, 10);
    if (!(L >= 0 && L < Core.LAYER_COUNT)) continue;
    row.style.opacity = '';
    var vis = row.querySelector('.vis'), lock = row.querySelector('.lock');
    var nameEl = row.querySelector('.name');
    var exists = layerExists(L);
    if (vis) {
      var v = app.r && app.r.layerVisible ? app.r.layerVisible(L) : true;
      vis.style.opacity = (v && exists) ? '1' : '0.35';
      vis.title = v ? '隐藏这一层' : '显示这一层';
    }
    if (lock) {
      var lk = app.r && app.r.layerLocked ? app.r.layerLocked(L) : false;
      lock.textContent = lk ? '🔒' : '🔓';
      lock.style.opacity = exists ? (lk ? '1' : '0.7') : '0.3';
      lock.title = lk ? '已锁定(落笔会被拒绝)' : '未锁定(点击锁定)';
    }
    // ★ 缺席层的"本图无此层"标记自己记账(row._goneEl),不靠 querySelector 回查 —— 假 DOM
    //   (node 冒烟)的 querySelector 每次都造一个新对象,回查会得到"永远存在"的假象。
    var gone = row._goneEl || null;
    if (!exists) {
      if (!gone && nameEl) {
        gone = document.createElement('span');
        gone.className = 'gone';
        gone.textContent = '本图无此层';
        if (nameEl.parentNode) nameEl.parentNode.insertBefore(gone, nameEl.nextSibling);
        row._goneEl = gone;
      }
    } else if (gone) {
      if (gone.parentNode && typeof gone.parentNode.removeChild === 'function') {
        gone.parentNode.removeChild(gone);
      }
      row._goneEl = null;
    }
  }
}
function toggleLayerVisible(L) {
  if (!app.r || !app.r.setLayerVisible) return;
  app.r.setLayerVisible(L, !app.r.layerVisible(L));
  if (L !== app.r.layer()) hiddenWarned[L] = false;
  syncLayerIcons();
  status('「' + Core.LAYER_NAMES[L] + '」' + (app.r.layerVisible(L) ? '已显示' : '已隐藏'));
}
function toggleLayerLocked(L) {
  if (!app.r || !app.r.setLayerLocked) return;
  app.r.setLayerLocked(L, !app.r.layerLocked(L));
  syncLayerIcons();
  status('「' + Core.LAYER_NAMES[L] + '」' + (app.r.layerLocked(L) ? '已锁定(落笔会被拒绝)' : '已解锁'));
}

function setLayer(L) {
  if (!(L >= 0 && L < Core.LAYER_COUNT)) return;
  app.r.setLayer(L);
  document.querySelectorAll('#layers .layer-row').forEach(function (row) {
    row.classList.toggle('cur', parseInt(row.dataset.layer, 10) === L);
  });
  // ★ 规格 §4.5:选中的是背景层时,右侧的纹理调色板换成颜色选择器,工具条里只有「渐变」额外可用。
  if (typeof syncPanelForLayer === 'function') syncPanelForLayer();
  syncLayerIcons();
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
