// ui/85_panels.js —— 右侧面板与图集装载。

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

// ── 面板构建(★ 每个控件只挂一次监听 —— 审计 A16:旧实现同时挂了 22 个独立监听与一个容器委托)──
function buildPanels() {
  document.querySelectorAll('#layers .layer-row').forEach(function (row) {
    var L = parseInt(row.dataset.layer, 10);
    row.addEventListener('click', function () { setLayer(L); });
    row.querySelector('.vis').addEventListener('click', function (ev) {
      ev.stopPropagation();
      var on = !app.r.layerVisible(L);
      app.r.setLayerVisible(L, on);
      this.style.opacity = on ? '1' : '0.35';
    });
    row.querySelector('.lock').addEventListener('click', function (ev) {
      ev.stopPropagation();
      var on = !app.r.layerLocked(L);
      app.r.setLayerLocked(L, on);
      this.style.opacity = on ? '0.35' : '1';
    });
  });
  // 纹理调色板:从 tile_defs 派生;纹理 22 不在其中(审计 A7)。
  var pal = texturePalette(app.tileDefs);
  var box = $('palette');
  pal.forEach(function (e) {
    var b = document.createElement('button');
    b.className = 'sw';
    b.title = e.tex + ' ' + e.name + (e.type ? '(' + e.type + ')' : '');
    b.textContent = String(e.tex);
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
      statusLine();
    });
  });
  var only = $('desc-only');
  if (only) only.addEventListener('change', function () { app.st.descOnly = only.checked; });
  var bs = $('brush-size');
  if (bs) {
    bs.addEventListener('change', function () { setBrush(parseFloat(bs.value) || 1); });
  }
  document.querySelectorAll('#toolbar .tool').forEach(function (b) {
    b.addEventListener('click', function () { app.st.tool = b.dataset.tool; selectToolButton(); });
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
  var bn = $('btn-new'), bd = $('btn-dup'), br = $('btn-rename'), bx = $('btn-del');
  if (bn) bn.addEventListener('click', function () {
    var name = window.prompt('新地图名字(不含 .cyrm)', 'new_map');
    if (!name) return;
    var m = createEmptyMap(name, 125, 75);       // ★ 尺寸只经这一个闸
    app.map = m; app.name = freshName(name);
    app.sourceFormat = 'v4';
    undoHistory = createHistory({});
    markDirty();                    // ★ 新建只活在内存里(还没写盘)⇒ 磁盘状态是「未保存」
    // ★ setMap 返回的是分帧重建派生出来的 promise ⇒ 必须收口:抛在任务回调里同步 try/catch 接不住。
    guard('新建地图', function () { return app.r.setMap(m); });
    status('新建 ' + app.name + '(还没写盘 —— Ctrl+S 才落盘)');
    refreshStatus(); statusLine();
  });
  if (bd) bd.addEventListener('click', function () {
    if (!app.map) { status('先打开一张地图'); return; }
    var copy = resizeMap(app.map, Core.cellsWOf(app.map), Core.cellsHOf(app.map)).map;
    copy.name = (app.map.name || 'map') + '_copy';
    app.map = copy;
    app.name = freshName(copy.name);
    app.sourceFormat = 'v4';
    undoHistory = createHistory({});
    markDirty();                    // ★ 同上:副本也只活在内存里(还没写盘)
    guard('复制地图', function () { return app.r.setMap(copy); });   // ★ 同上:分帧重建的 promise
    status('已复制为 ' + app.name + '(还没写盘)');
    refreshStatus();
  });
  if (br) br.addEventListener('click', function () {
    if (!app.map) { status('先打开一张地图'); return; }
    var n = window.prompt('新的名字(不含 .cyrm)', app.map.name);
    if (!n) return;
    app.map.name = Core.sanitizeName(n);
    app.name = app.map.name + '.cyrm';
    markDirty();                    // ★ 改名只改内存里那份(磁盘上还是旧名字,要 Ctrl+S 才落盘)
    status('改名为 ' + app.name + '(还要 Ctrl+S 才写盘)');
    refreshStatus();
  });
  if (bx) bx.addEventListener('click', function () {
    status('删除地图请直接在磁盘上删 maps/ 下的文件(编辑器不做删除动作 —— 这是故意的)');
  });
  var exp = $('btn-export');
  if (exp) exp.addEventListener('click', showExportReport);
  // ★★ 背景层的两个颜色槽(规格 §4.4/§4.5):①起点 ②终点 —— 两个槽是渐变的全部,只接一个的话
  //    "渐变"永远退化成一个纯色(两端同色),而且看不出来。背景层是不透明的真彩(alpha 走辅码那一路)。
  [['bg-color', 'rgba'], ['bg-color2', 'rgba2']].forEach(function (spec) {
    var inp = $(spec[0]), lab = $(spec[0] + '-val');
    if (!inp) return;
    var m0 = /^#([0-9a-f]{6})$/i.exec(inp.value);
    if (m0) app.st[spec[1]] = (parseInt(m0[1], 16) * 256 + 255) >>> 0;
    inp.addEventListener('input', function () {
      var m = /^#([0-9a-f]{6})$/i.exec(inp.value);
      if (!m) return;
      app.st[spec[1]] = (parseInt(m[1], 16) * 256 + 255) >>> 0;
      if (lab) lab.textContent = inp.value;
      statusLine();
    });
  });
  selectToolButton();
  syncPanelForLayer();
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
  var g = document.querySelector('#toolbar .tool[data-tool="gradient"]');
  if (g) g.style.opacity = isBg ? '1' : '0.45';
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
  pushAndShow(addSpawn(app.map, 'enemy', cx, cy, types[0] || 'fly_bird'));
  status('敌人放到 (' + cx + ',' + cy + ')');
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
