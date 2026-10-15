// ui/92_boot.js —— 启动:装载图集、库、默认图。


function boot() {
  app.canvas = $('map-canvas');
  if (!app.canvas) return;
  app.tileDefs = globalThis.TILE_DEFS || null;
  // ★ 闸 3 没有降级路径 ⇒ 缺 Worker 时的唯一正确行为是把话说清楚(而不是静默退回主线程)。
  if (!Io.workerAvailable()) {
    var b = $('boot-error');
    if (b) { b.hidden = false; b.textContent = '本环境没有 Web Worker —— 请用 serve.bat 起服务器后打开 http://127.0.0.1:8777/(file:// 下没有 Worker)。'; }
    return;
  }
  // ★★ onError 指到 ui 的 sink(渲染侧的失败与 guard 写同一条通道,不靠 render 自己去摸 Editor.status);
  //    ★ installInteraction 必须在 mount 之后 —— 它一进来就要用 app.r。
  app.r = Render.mount(app.canvas, { onError: reportError });
  installInteraction();
  var ro = new ResizeObserver(function () { guard('resize', function () { return app.r.resize(); }); });
  ro.observe(app.canvas.parentElement);
  var selftestBtn = $('btn-selftest');
  if (selftestBtn) {
    selftestBtn.addEventListener('click', runSelfTest);
  }
  var fitBtn = $('btn-fit');
  if (fitBtn) fitBtn.addEventListener('click', function () { guard('fit', function () { return app.r.fit(); }); });

  bootLoad();
}

// ★★ 面板必须建在打开之前:原先那条链是 loadAtlas → openFromUrl → buildPanels,而 .catch 只有一个 ⇒
//    openFromUrl() 一旦拒绝(HTTP 404 / .cyrm 解不开)整条链短路到 catch,buildPanels() 一行都没跑。
// ★★ 启动顺序:① installCrashFence 第一(后面任何一步抛出都要能被它接住);② 草稿盘要在打开地图之前就绪;
//    ③ 崩溃/草稿检查排在 openFromUrl 之后(恢复的那份必须压住文件里那份);④ applyUiState 在 setMap 之后。
function bootLoad() {
  installCrashFence();
  app.uist = readUiState(localStore());
  app.db = null;
  return openDraftStore().then(function (db) {
    app.db = db;
    if (!db) status('草稿盘不可用(私密模式?)—— 编辑器仍可用,但请及时 Ctrl+S 存盘');
  }).then(function () {
    return loadAtlas();
  }).then(function () {
    buildPanels();
    return openFromUrl();
  }).then(function () {
    return checkCrashSlot();
  }).then(function (recovered) {
    if (recovered) return false;
    return offerDraft();
  }).then(function () {
    applyUiState();
    installUiStateSave();
    return null;
  }).then(function () {
    if (new URLSearchParams(location.search).has('selftest')) return runSelfTest();
    return null;
  }).catch(function (e) {
    status('启动失败:' + msgOf(e));
  });
}
