// ui/85_panels.js —— 右栏面板(工具/工具选项/图层/纹理/辅码/出生点)、画布尺寸与库列表装载。

// ★ 恢复成功 ⇒ 消费掉这条快照:留着的话每一次打开都会再弹一次「上次异常退出」(一次偶发页面异常
//    变成一个永久的开机弹窗)。清不掉不致命(下次会问,而那时用户点"不要"会被 declined 记住)。
function consumeCrashSlot() {
  return new Promise(function (resolve) {
    var tx;
    try { tx = app.db.transaction(CRASH_STORE, 'readwrite'); }
    catch (e) { resolve(false); return; }
    tx.objectStore(CRASH_STORE).delete('crash');
    tx.oncomplete = function () { resolve(true); };
    tx.onerror = function () { resolve(false); };
    tx.onabort = function () { resolve(false); };
  });
}

// 工具细分选项:只显示当前工具那一组(工具与它的参数必须相邻,反馈 ⑤)。
function syncToolOptions() {
  var opts = document.querySelectorAll('#tool-opts .opt');
  for (var i = 0; i < opts.length; i++) {
    var keys = String(opts[i].dataset.for || '').split(/\s+/);
    opts[i].style.display = (keys.indexOf(app.st.tool) >= 0) ? '' : 'none';
  }
}

// 纹理缩略图 = 4×4 个象限拼成 64×64(只画一个象限会让靠四角拼图案的砖看不出样子)。
// ★ 用**当前辅码**染色(Core.packDesc(tex, 当前四档)):按钮上看得见的是「基准纹理 + 你手上这套辅码」,
//   调档位当场能预览(旧实现恒用中性辅码,调色板对"调了档位"毫无反应)。
// ★ app.st 还没建好时(极早的启动路径 / node 冒烟)回落中性档 —— 缩略图只是表现,不许抛。
function paletteThumbURL(tex) {
  if (typeof document === 'undefined' || !document.createElement) return '';
  var cap = (typeof Render.atlasCapacity === 'function') ? Render.atlasCapacity() : 0;
  if (!(cap >= tex)) return '';                       // 图集还没装好/node 冒烟:回落成数字
  try {
    var k = Core.SUB_PER_CELL, px = 16, size = k * px;
    var cv = document.createElement('canvas');
    if (!cv || typeof cv.getContext !== 'function') return '';
    cv.width = size; cv.height = size;
    var g = cv.getContext('2d');
    if (!g) return '';
    var cur = (app && app.st && isFinite(app.st.desc)) ? app.st.desc : null;
    var desc = cur === null ? Core.neutralDesc(tex)
      : Core.packDesc(tex, Core.hueOf(cur), Core.brightOf(cur), Core.satOf(cur), Core.alphaOf(cur));
    for (var qy = 0; qy < k; qy++) {
      for (var qx = 0; qx < k; qx++) {
        var tile = Render.tileFor(desc, qx, qy);
        if (tile) g.drawImage(tile, qx * px, qy * px);
      }
    }
    return cv.toDataURL();
  } catch (e) { return ''; }                          // 缩略图只是表现,失败退回数字,不影响画布
}
// ★ 辅码四档变化时只重画调色板按钮的**背景**(不重建面板):按钮用 dataset.tex 记着自己的纹理号。
function refreshPaletteThumbs() {
  if (typeof document === 'undefined' || !document.querySelectorAll) return;
  var btns = document.querySelectorAll('#palette .sw');
  for (var i = 0; i < btns.length; i++) {
    var tex = parseInt(btns[i].dataset && btns[i].dataset.tex, 10);
    if (!isFinite(tex) || tex <= 0) continue;
    var url = paletteThumbURL(tex);
    if (url) btns[i].style.backgroundImage = 'url(' + url + ')';
  }
}

// ── 面板构建(★ 每个控件只挂一次监听 —— 审计 A16:旧实现同时挂了 22 个独立监听与一个容器委托)──
function buildPanels() {
  // 图层行:点击=切层;👁/🔒 各自的开关走 60_brush_layer 的两个具名入口(它们同时刷图标与状态栏)。
  document.querySelectorAll('#layers .layer-row').forEach(function (row) {
    var L = parseInt(row.dataset.layer, 10);
    row.addEventListener('click', function () { setLayer(L); });
    var vis = row.querySelector('.vis'), lock = row.querySelector('.lock');
    if (vis) vis.addEventListener('click', function (ev) { ev.stopPropagation(); toggleLayerVisible(L); });
    if (lock) lock.addEventListener('click', function (ev) { ev.stopPropagation(); toggleLayerLocked(L); });
  });
  // 纹理调色板:从 tile_defs 派生;纹理 22 不在其中(审计 A7)。
  var pal = texturePalette(app.tileDefs);
  var box = $('palette');
  pal.forEach(function (e) {
    var b = document.createElement('button');
    b.className = 'sw';
    b.dataset.tex = String(e.tex);              // ★ refreshPaletteThumbs 靠它找回每颗按钮的纹理号
    b.title = e.tex + ' ' + e.name + (e.type ? '(' + e.type + ')' : '');
    var url = paletteThumbURL(e.tex);
    if (url) b.style.backgroundImage = 'url(' + url + ')';
    b.textContent = String(e.tex);                   // 数字留在图上当角标(text-shadow 保证可读)
    b.addEventListener('click', function () {
      app.st.desc = Core.packDesc(e.tex, Core.hueOf(app.st.desc), Core.brightOf(app.st.desc),
                                  Core.satOf(app.st.desc), Core.alphaOf(app.st.desc));
      document.querySelectorAll('#palette .sw').forEach(function (x) { x.classList.remove('on'); });
      b.classList.add('on');
      statusLine();
    });
    box.appendChild(b);
  });
  if (DERIVED_TEXTURES.length) {
    var hint = document.createElement('div');
    hint.className = 'desc-row';
    // ★★ 给它一个 id:它是 #palette 的派生行,背景层上必须跟着一起藏(见 syncPanelForLayer)。
    hint.id = 'palette-hint';
    hint.textContent = '纹理 ' + DERIVED_TEXTURES.join('/') + ' 不进调色板:游戏侧由地形自动派生';
    box.parentNode.insertBefore(hint, box.nextSibling);
  }
  // 辅码四组档位
  [['desc-hue', 'hueOf'], ['desc-bri', 'brightOf'],
   ['desc-sat', 'satOf'], ['desc-alp', 'alphaOf']].forEach(function (spec) {
    var sel = $(spec[0]);
    if (!sel) return;
    for (var k = 0; k < Core.SUB_PER_CELL * 2; k++) {
      var o = document.createElement('option');
      o.value = String(k); o.textContent = String(k);
      sel.appendChild(o);
    }
    sel.value = String(Core[spec[1]](app.st.desc));
    sel.addEventListener('change', function () {
      app.st.desc = Core.packDesc(Core.texOf(app.st.desc), +$('desc-hue').value, +$('desc-bri').value,
                                  +$('desc-sat').value, +$('desc-alp').value);
      refreshPaletteThumbs();                  // ★ 缩略图按当前辅码染色:档位一变就重画按钮背景(不重建面板)
      statusLine();
    });
  });
  // ★★ 「只改辅码」的反馈(用户反馈 ⑧:勾上之后落笔可能是空操作、却一个字都不说):
  //    ① 勾/取消都刷状态栏;② 四档全中性时明说"这一笔不会产生可见变化"。
  var only = $('desc-only');
  if (only) only.addEventListener('change', function () {
    app.st.descOnly = only.checked;
    statusLine();
    if (only.checked && isNeutralDesc(app.st.desc)) {
      status('只改辅码:当前四档是中性档(4/4/4/7),落笔不会产生可见变化 —— 先调色相/亮度/饱和/透明');
    } else {
      status(only.checked ? '只改辅码:保留原纹理,只改四档辅码' : '已关闭「只改辅码」:落笔会同时写纹理');
    }
  });
  var bs = $('brush-size');
  if (bs) bs.addEventListener('change', function () { setBrush(parseFloat(bs.value) || 1); });
  // 工具选择(工具已挪到右栏 #tools)
  document.querySelectorAll('#tools .tool').forEach(function (b) {
    b.addEventListener('click', function () { app.st.tool = b.dataset.tool; selectToolButton(); });
  });
  // 工具细分选项:值本身在落笔时读(stNow/toolOption),这里只负责把状态栏刷成"现在会怎么落笔"。
  ['rect-mode', 'line-width'].forEach(function (id) {
    var el = $(id);
    if (el) el.addEventListener('change', function () { statusLine(); });
  });
  // 选区操作按钮(与 Ctrl+C/X/V、H/V、Delete 同一个实现 —— 以前只有热键,能力不可发现)
  [['sel-copy', function () { doCopySelection(); }],
   ['sel-cut', function () { doCutSelection(); }],
   ['sel-paste', function () { doPasteSelection(); }],
   ['sel-mirror-h', function () { guard('镜像', function () { return mirrorSelection('h'); }); }],
   ['sel-mirror-v', function () { guard('镜像', function () { return mirrorSelection('v'); }); }],
   ['sel-clear', function () { doClearSelection(); }]].forEach(function (pair) {
    var el = $(pair[0]);
    if (el) el.addEventListener('click', function () { guard(pair[0], pair[1]); });
  });
  // 撤销/重做:落盘与历史都在键盘上有,但按钮是用户能找到它们的前提。
  [['btn-undo', function () { return doUndo(); }],
   ['btn-redo', function () { return doRedo(); }]].forEach(function (pair) {
    var el = $(pair[0]);
    if (el) el.addEventListener('click', function () { guard(pair[0], pair[1]); });
  });
  $('tg-grid').addEventListener('click', function () {
    this.classList.toggle('on'); app.r.setGrid(this.classList.contains('on'));
  });
  $('tg-subgrid').addEventListener('click', function () {
    this.classList.toggle('on'); app.r.setSubGrid(this.classList.contains('on'));
  });
  $('tg-torus').addEventListener('click', function () {
    this.classList.toggle('on'); app.r.setTorus(this.classList.contains('on'));
  });
  var dim = $('dim-others');
  if (dim) dim.addEventListener('change', function () { app.r.setDimOthers(dim.checked); });
  // 出生点工具:敌人类型从页面注册表来(以前写死 types[0] ⇒ 永远放 jump_bird,用户反馈 ⑦ 的一半)
  var et = $('spawn-enemy-type');
  if (et) {
    var reg = importEnemyTypes();
    for (var i = 0; i < reg.length; i++) {
      var op = document.createElement('option');
      op.value = reg[i]; op.textContent = reg[i];
      et.appendChild(op);
    }
  }
  var p1 = $('spawn-p1'), p2 = $('spawn-p2'), en = $('spawn-enemy'), cl = $('spawn-clear');
  if (p1) p1.addEventListener('click', function () { spawnAt('player', 0); });
  if (p2) p2.addEventListener('click', function () { spawnAt('player', 1); });
  if (en) en.addEventListener('click', function () { spawnAt('enemy', 0); });
  // ★★ 与它三个兄弟(都走 spawnAt)对齐:没打开地图时说「先打开一张地图」,而不是把 clearSpawns(null)
  //    的 TypeError 抛进 click 处理器 —— 后者经 window.onerror 变成「页面异常:…」,同一个面板里四个
  //    按钮两种说法。
  if (cl) cl.addEventListener('click', function () {
    guard('清空出生点', function () {
      if (!app.map) { status('先打开一张地图'); return null; }
      return pushAndShow(clearSpawns(app.map));
    });
  });
  // ── 按侧复活点(`# respawn <1|2> <col> <row>`,游戏侧按半区读)──
  // ★ 见 25_spawn.js 的 addRespawn/sideOfCell:侧 1 = 左半、侧 2 = 右半。
  [['spawn-r1', function () { spawnRespawn(1); }],
   ['spawn-r2', function () { spawnRespawn(2); }],
   ['spawn-rdel', function () { deleteRespawnNear(); }],
   ['spawn-rclear1', function () { clearRespawnSide(1); }],
   ['spawn-rclear2', function () { clearRespawnSide(2); }]].forEach(function (pair) {
    var el = $(pair[0]);
    if (el) el.addEventListener('click', function () { guard(pair[0], pair[1]); });
  });
  // 辅助线(半区中线 + 3×3 桶)
  var tgG = $('tg-guides');
  if (tgG) tgG.addEventListener('click', function () {
    this.classList.toggle('on');
    var on = this.classList.contains('on');
    if (app.r && app.r.setGuides) app.r.setGuides(on);
    status(on ? '已显示标线:半区中线 + 3×3 桶(联机复活点均匀散布的对照)' : '已隐藏标线');
  });
  // ── 画布尺寸面板(规格 A10;★ resizeMap / wholeDiff / applyEntry 的 whole 分支在生产里的唯一入口)──
  // ★ 与上面四个出生点按钮同款:没打开地图时说一句话。★ 输入框里的回车也当"应用尺寸" ——
  //   两个数字框 + 一颗按钮的版式里,按回车什么都不发生是最容易被当成"坏了"的一种手感。
  var rsBtn = $('btn-resize');
  if (rsBtn) rsBtn.addEventListener('click', function () { guard('改尺寸', applySize); });
  ['size-w', 'size-h'].forEach(function (id) {
    var el = $(id);
    if (el) el.addEventListener('keydown', function (ev) {
      if (ev.key !== 'Enter') return;
      ev.preventDefault();
      guard('改尺寸', applySize);
    });
  });
  // ★ 压缩开关(规格 §3.5):值本身在用的时候读(optCompress),这里只负责说一句。
  var cpBox = $('opt-compress');
  if (cpBox) cpBox.addEventListener('change', function () {
    status(cpBox.checked ? '导出/保存:压缩(deflate)'
                         : '导出/保存:裸 body(compression=0;浏览器与 Godot 的 deflate 万一对不上,这条是退路)');
  });
  var libList = $('lib-list');
  if (libList) {
    libList.addEventListener('click', function (ev) {          // ★ 委托一次,不给每行挂监听
      var row = ev.target.closest ? ev.target.closest('.lib-row') : null;
      // ★★ openMap 的失败是常态(点到一个陈旧/写错的名字 ⇒ HTTP 404),必须经 guard 收口:丢掉这个
      //    promise 会让拒绝逃到全局围栏,围栏会 snapshot() ⇒ 一次普通的打开失败把当前这张图写进崩溃
      //    槽位,下次开机弹假的「上次异常退出」。guard 是终点:失败变成状态栏上一行,且一个字节都不进。
      if (row && row.dataset.name) {
        guard('打开地图', function () { return openMap(row.dataset.name); });
      }
    });
  }
  // ★★ 文件级动作(新建/打开文件/打开文件夹/保存/另存为/导出/复制/重命名/删除/校验)在 ui/86_fileops.js:
  //    它们各自都有"写盘/读盘"两半,与面板布局无关,分片放能把"面板"与"文件"分干净。
  if (typeof installFileOps === 'function') installFileOps();
  selectToolButton();
  syncPanelForLayer();
  syncToolOptions();
  syncLayerIcons();
  refreshRespawnCount();
  statusLine();
}

// 背景层时把"纹理调色板 + 辅码"换成"颜色选择器"(规格 §4.5)。★ 只切显示,不动任何数据。
function syncPanelForLayer() {
  var isBg = (app.r.layer() === Core.LAYER_BG);
  var show = function (id, on) { var el = $(id); if (el) el.style.display = on ? '' : 'none'; };
  // ★★ 藏的是整行,不是控件的直接父节点:四个档位 select 的父节点就是 .desc-row,而「只改辅码」那个
  //    input 外面还包着一层 label ⇒ 直接写 parentNode 的话后者只藏掉 label,那一行仍占着位置。
  var hideRow = function (id, on) {
    var el = $(id);
    if (!el) return;
    var row = el;
    while (row && !(row.classList && row.classList.contains('desc-row'))) row = row.parentNode;
    if (row) row.style.display = on ? '' : 'none';
  };
  show('palette', !isBg);
  show('palette-hint', !isBg);       // ★ 派生行跟着调色板走(见 buildPanels 里插它的那一段)
  show('bg-color-row', isBg);
  show('bg-color-row2', isBg);
  show('bg-color-title', isBg);
  ['desc-hue', 'desc-bri', 'desc-sat', 'desc-alp'].forEach(function (id) { hideRow(id, !isBg); });
  // ★ 「只改辅码」与四个档位是同一组(它管的就是那四档),故同显同藏。
  hideRow('desc-only', !isBg);
  var titles = document.querySelectorAll('#right h2');
  for (var i = 0; i < titles.length; i++) {
    if (titles[i].textContent === '辅码') titles[i].style.display = isBg ? 'none' : '';
  }
  // ★ 渐变只在背景层可用(纹理层没有颜色可插值);其余工具照旧。
  var g = document.querySelector('#tools .tool[data-tool="gradient"]');
  if (g) g.style.opacity = isBg ? '1' : '0.45';
}

// 中性档 = 完全按原图(不染色)。用它把"勾了只改辅码但没调档位 ⇒ 落笔没有任何可见变化"说清楚。
function isNeutralDesc(d) {
  return Core.hueOf(d) === 4 && Core.brightOf(d) === 4 && Core.satOf(d) === 4 && Core.alphaOf(d) === 7;
}

// 视图中心那一格(不猜鼠标位置:按下按钮时鼠标在按钮上)。出生点与复活点共用这一条口径。
function viewCenterCell() {
  var v = app.r.view();
  return {
    cx: Math.round((v.x + app.canvas.width / v.zoom / 2) / Core.SUB_PER_CELL),
    cy: Math.round((v.y + app.canvas.height / v.zoom / 2) / Core.SUB_PER_CELL),
  };
}
function spawnRespawn(side) {
  if (!app.map) { status('先打开一张地图'); return; }
  var c = viewCenterCell();
  var out = addRespawn(app.map, side, c.cx, c.cy);
  pushAndShow(out.diff);
  var cnt = respawnCounts(app.map);
  var own = sideOfCell(app.map, out.x) === side;
  status('侧 ' + side + ' 复活点放到 (' + out.x + ',' + out.y + ')' +
         (own ? '' : '(注意:这个点在另一半区 —— 游戏侧按半区读,校验会报出来)') +
         ';现在 侧1 ' + cnt[1] + ' 个 / 侧2 ' + cnt[2] + ' 个');
  statusLine();
}
function deleteRespawnNear() {
  if (!app.map) { status('先打开一张地图'); return; }
  var c = viewCenterCell();
  var side = sideOfCell(app.map, c.cx);
  var out = removeRespawnNear(app.map, side, c.cx, c.cy);
  if (!out) { status('侧 ' + side + ' 没有任何复活点可删'); return; }
  pushAndShow(out.diff);
  status('已删掉侧 ' + side + ' 离视图中心最近的复活点 (' + out.at.x + ',' + out.at.y + ')');
  statusLine();
}
function clearRespawnSide(side) {
  if (!app.map) { status('先打开一张地图'); return; }
  var diff = clearRespawns(app.map, side);
  if (!diff) { status('侧 ' + side + ' 本来就没有复活点'); return; }
  pushAndShow(diff);
  status('已清空侧 ' + side + ' 的复活点');
  statusLine();
}
// 面板上的计数(每侧与 "≥5" 的对照 —— 游戏侧联机要求每侧 ≥5)
function refreshRespawnCount() {
  var el = $('respawn-count');
  if (!el) return;
  if (!app.map) { el.textContent = '侧1 0 · 侧2 0'; return; }
  var c = respawnCounts(app.map);
  el.textContent = '侧1 ' + c[1] + ' · 侧2 ' + c[2] + '(联机建议每侧 ≥5)';
}

function spawnAt(kind, playerIndex) {
  if (!app.map) { status('先打开一张地图'); return; }
  var v = app.r.view();
  // ★ 视图中心那一格(不猜鼠标位置:按下按钮时鼠标在按钮上)
  var cx = Math.round((v.x + app.canvas.width / v.zoom / 2) / Core.SUB_PER_CELL);
  var cy = Math.round((v.y + app.canvas.height / v.zoom / 2) / Core.SUB_PER_CELL);
  var types = importEnemyTypes();
  if (kind === 'player') {
    // ★★ P1/P2 是位置语义、不是"第几条记录":游戏侧 map_format.gd 按顺序读 player / player2。
    //    故放 P1 = 写第 0 条,放 P2 = 写第 1 条;缺号一律显式拒绝并说明理由 —— 绝不 push 出一条
    //    位置不对的记录(在零出生点的图上放 P2 而 push 出去,磁盘上那条会被游戏读成 P1,一个字都不报)。
    if (app.map.players.length < playerIndex) {
      status('先放 P' + playerIndex + ':出生点按位置读(player / player2),P' + (playerIndex + 1) +
             ' 之前必须有 P' + playerIndex);
      return;
    }
    var before = snapshotSpawns(app.map);
    // ★★ 折算回本图范围:panBy 不钳视图(render.js)⇒ 环面模式下把视图拖到图外时,"视图中心那一格"
    //    算出来是越界的,磁盘上就多出一条 x/y 出圈的出生点(只有 Core.validateMap 看得见它)。
    var px = Render.wrapIdx(Math.floor(cx), Core.cellsWOf(app.map));
    var py = Render.wrapIdx(Math.floor(cy), Core.cellsHOf(app.map));
    if (app.map.players.length === playerIndex) app.map.players.push({ x: px, y: py });
    else app.map.players[playerIndex] = { x: px, y: py };
    pushAndShow(spawnDiff(before, snapshotSpawns(app.map)));
    status('P' + (playerIndex + 1) + ' 放到 (' + px + ',' + py + ')');
    return;
  }
  // ★ 类型取右栏下拉(以前写死 types[0],永远放 jump_bird);注册表空时回落旧行为。
  var etype = toolOption('spawn-enemy-type', types[0] || 'fly_bird');
  if (types.length && types.indexOf(etype) < 0) etype = types[0] || 'fly_bird';
  pushAndShow(addSpawn(app.map, 'enemy', cx, cy, etype));
  status('敌人(' + etype + ')放到 (' + cx + ',' + cy + ')');
}

// ── 图集(结构图一次装进来)──
function loadAtlas() {
  return new Promise(function (resolve, reject) {
    var img = new Image();
    img.onload = function () {
      var c = document.createElement('canvas');
      c.width = img.width; c.height = img.height;
      var g = c.getContext('2d', { willReadFrequently: true });
      g.drawImage(img, 0, 0);
      var d = g.getImageData(0, 0, img.width, img.height);
      Render.setAtlas(d.data, img.width, img.height);   // ★ 同时作废 ③ 与 ④
      resolve({ width: img.width, height: img.height });
    };
    img.onerror = function () { reject(new Error('structure.png 加载失败')); };
    // ★ 单文件版把图集内联成 data: URL 放在这里(file:// 下旁边没有 structure.png)。
    img.src = globalThis.__CYRM_ATLAS_URL__ || 'structure.png';
  });
}
