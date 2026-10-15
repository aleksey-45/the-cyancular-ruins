// ui/80_ui_state.js —— 界面状态持久化与上次异常退出的检查。


function applyUiState() {
  var u = app.uist;
  if (!u) return;
  // ★ 缩放必须在地图打开之后恢复:setMap 自己会 fit();u.zoom === 0 是"没存过缩放"的哨兵。
  var cur = app.r.view().zoom;
  if (u.zoom > 0 && cur > 0 && Math.abs(u.zoom - cur) > 1e-6) {
    // ★★ 视图入口必须走 guard 收口(guard( 与那次调用写在一起,读的人一眼看得出收口点在哪)——
    //    漏了它就是"按了没反应"那条通道。
    guard('恢复缩放', function () { return app.r.setZoomAt(app.canvas.width / 2, app.canvas.height / 2, u.zoom / cur); });
  }
  // ★★ 这一处必须走本文件的 setLayer(它内部再调 app.r.setLayer):直接调 app.r.setLayer 只换渲染层,
  //    而面板与图层行不会跟着动 ⇒ 用户看到的与正在发生的是两回事(右侧摆着纹理调色板,刷子却画在背景层上)。
  setLayer(u.layer);
  app.r.setGrid(u.grid); app.r.setSubGrid(u.subGrid);
  app.r.setTorus(u.torus); app.r.setDimOthers(u.dimOthers);
  app.st.tool = u.tool;
  app.st.brushSize = u.brushSize;
  // ★★ 与上面那条 setLayer 同一个模式:app.st.tool 只是状态,工具条那一排按钮的高亮由
  //    selectToolButton() 画 —— 少了它,重载之后高亮钉在 editor.html 写死的画笔上。
  selectToolButton();
  if (u.selectedTexture > 0) {
    app.st.desc = Core.packDesc(clampTexture(u.selectedTexture, Render.atlasCapacity()),
                                Core.hueOf(app.st.desc), Core.brightOf(app.st.desc),
                                Core.satOf(app.st.desc), Core.alphaOf(app.st.desc));
  }
  [['tg-grid', u.grid], ['tg-subgrid', u.subGrid], ['tg-torus', u.torus]].forEach(function (pair) {
    var el = $(pair[0]);
    if (el) el.classList.toggle('on', !!pair[1]);
  });
  var dim = $('dim-others');
  if (dim) dim.checked = !!u.dimOthers;
  // ★★ 压缩开关只在存过这个字段时才动它:老存档(cyrm.ui.v1)里没有 compress,照 !!u.compress 写会把
  //    框取消勾选,于是"没存过"被读成"用户不要压缩" —— 一次静默的文件格式变更。
  var cp = $('opt-compress');
  if (cp && typeof u.compress === 'boolean') cp.checked = u.compress;
  var bsEl = $('brush-size');
  if (bsEl) bsEl.value = String(app.st.brushSize);
}
var uiSaveTimer = null;
// ★ 节流(不是逐帧):localStorage 是同步写,每帧写会掉帧;挂在几个明确的变更点上。
function persistUi() {
  if (uiSaveTimer || !app.map || !app.st) return;
  uiSaveTimer = setTimeout(function () {
    uiSaveTimer = null;
    var prev = app.uist || uiStateDefaults();
    app.uist = {
      layer: app.r.layer(), zoom: app.r.view().zoom, tool: app.st.tool,
      brushSize: app.st.brushSize,
      grid: $('tg-grid') ? $('tg-grid').classList.contains('on') : true,
      subGrid: $('tg-subgrid') ? $('tg-subgrid').classList.contains('on') : false,
      torus: $('tg-torus') ? $('tg-torus').classList.contains('on') : true,
      dimOthers: $('dim-others') ? !!$('dim-others').checked : true,
      compress: optCompress(),
      panelOpen: prev.panelOpen, playerRef: prev.playerRef,
      selectedTexture: Core.texOf(app.st.desc),
    };
    writeUiState(localStore(), app.uist);
  }, UI_SAVE_THROTTLE_MS);
}
// ★ 绑定一律经 onWin:node 冒烟里 window 是 globalThis 而 globalThis 没有 addEventListener(Node 24 实测),裸 window.addEventListener(...) 会在 bootLoad() 第一行就抛。
function onWin(evt, fn, opts) {
  if (typeof window === 'undefined' || typeof window.addEventListener !== 'function') return;
  window.addEventListener(evt, fn, opts);
}
function installUiStateSave() {
  ['click', 'change', 'wheel', 'keyup', 'pointerup'].forEach(function (evt) {
    onWin(evt, persistUi, { passive: true });
  });
  onWin('pagehide', function () { persistUi(); flushDraft(); });
}

// ★★ 兜底:就算前面三道闸哪里漏了,作品也不会丢,最坏只丢最后一笔。★ 这里不再挂第二对 error /
//    unhandledrejection 监听(两对同事件 = 一次异常把状态栏写两遍,而快照只挂在其中一对上) ——
//    装它的地方只剩 bootLoad() 一处。
function installCrashFence() {
  function snapshot(why) {
    if (!app.map || !app.db) return;
    encodeForWrite(app.map).then(function (bytes) {
      return idbPut(app.db, CRASH_STORE, {
        key: 'crash', name: app.name, name2: app.map.name, bytes: bytes,
        savedAt: Date.now(), why: String(why || '').slice(0, 200),
      });
    }).catch(function () { /* 崩溃路径上什么都不该再抛 */ });
  }
  onWin('error', function (ev) {
    status('页面异常:' + (ev && ev.message ? ev.message : '未知'));
    snapshot(ev && ev.message);
  });
  onWin('unhandledrejection', function (ev) {
    status('未处理的 promise 拒绝:' + msgOf(ev && ev.reason));
    snapshot('unhandledrejection');
  });
}
// ★ 它排在 openFromUrl() 之后(bootLoad 的顺序):恢复出来的图要压住文件里那份。
// ★★ 两处读取都是点读,不是整库 getAll;读失败不许折成"没有崩溃快照"—— 那是这一层最后一次兜底,
//    静默消失 = 作品丢了而没人知道。
function checkCrashSlot() {
  if (!app.db) return Promise.resolve(false);
  return Promise.all([idbGetOne(app.db, CRASH_STORE, 'crash'),
                      idbNewestSavedAt(app.db)]).then(function (both) {
    var cre = both[0], newest = both[1];
    if (!cre.ok || !newest.ok) {
      status('崩溃槽位读取失败:草稿盘读不到(这一次的「上次异常退出」没有检查到)');
      return false;
    }
    var crash = cre.rec;
    var main = (newest.savedAt === null) ? null : { savedAt: newest.savedAt };
    if (!crashIsNewer(crash, main)) return false;
    var yes = window.confirm('上次异常退出,已恢复到崩溃前(草稿:' + (crash.name2 || crash.name || '?') +
                             ')。要打开它吗?');
    if (!yes) {
      // ★ 记下"问过、用户不要"(crashIsNewer 读这个字段);★ 记录本身留着 —— 那是没写盘的活。
      crash.declined = true;
      return idbPut(app.db, CRASH_STORE, crash).then(function () { return false; })
               .catch(function () { return false; })      // 记不住只是下次再问一次
               .then(function () {
                 status('崩溃快照仍在崩溃槽位里(屏幕上的图没被动过)');
                 return false;
               });
    }
    return Io.decodeMap(crash.bytes).then(function (map) {
      map.name = crash.name2 || '';
      app.map = map; app.name = crash.name; app.sourceFormat = 'v4';
      dirty = true;                  // ★ 屏幕上这份 ≠ 磁盘上那份(不回血:该 Ctrl+S 了)
      guard('崩溃恢复', function () { return app.r.setMap(map); });
      refreshStatus(); statusLine();
      status('已从崩溃前快照恢复:' + (crash.name || ''));
      return consumeCrashSlot().then(function () { return true; });
    }).catch(function (e) { status('崩溃快照解码失败:' + msgOf(e)); return false; });
  }).catch(function (e) { status('崩溃槽位读取失败:' + msgOf(e)); return false; });
}
