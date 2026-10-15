// render/82_install_errors.js —— 视图入口的报错通道:拒绝必须看得见,且不许吞掉返回的 promise。

function installErrors(S) {
  var opts = S.opts;
  // ★★ 视图入口(resize/fit/setView/setZoomAt/panBy/setMap/invalidateAll)返回的是由分帧器派生出来的 promise,而 ≥8 那条路上的抛错(tileFor 的"图集里没有纹理 N")发生在任务回调里
  //    ⇒ 它变成 run() 的拒绝,不再是 render() 里那次同步抛出:页面侧唯一的消费者(ui.js 的 guard)是同步 try/catch、接不住,而 render() 这一帧根本没执行 ⇒ 画布默默停在上一帧。这正是本仓最防的"按了没反应"。
  // ★★ 两条契约同时成立、缺一不可:① 想 await / 自己 catch 的调用方照样拿到那次拒绝(这里只挂观察者,不改、不吞、也不替换返回的 promise);② 完全不管返回值的调用方也能在屏幕上的同一条通道里看到原因。副作用正是要的:它把这条拒绝从全局 unhandledrejection 那张网里摘了出来。
  function msgOf(e) {                          // ★ 与 ui.js 的 msgOf 是同源重复(加载顺序让它没法共享):两处都只做"取出人能读的那句",改一处要同改另一处
    if (!e) return '未知错误';
    var m = (e.message !== undefined) ? String(e.message) : String(e);
    if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
    return m === '' ? String(e) : m;
  }
  function defaultErrorSink(text, err) {
    // ★ 走页面已经在用的那条通道:ui.js 的 status()(= 状态栏 #status-msg),运行时查找 —— 依赖顺序是 core → tint → render → io → ui,加载期顶层引 ui.js 会让 node 冒烟当场炸。
    var shown = false;
    try {
      var E = globalThis.Editor;
      if (E && typeof E.status === 'function') { E.status(text); shown = true; }
    } catch (e1) { shown = false; }
    if (!shown) {
      try {
        var el = (typeof document !== 'undefined' && document.getElementById)
          ? document.getElementById('status-msg') : null;
        if (el) { el.textContent = String(text); shown = true; }
      } catch (e2) { shown = false; }
    }
    if (typeof console !== 'undefined' && console.error) console.error(text, err);
  }
  S.errorSink = (typeof opts.onError === 'function') ? opts.onError : defaultErrorSink;
  function reportViewError(label, err) {
    var text = '出错了(' + label + '):' + msgOf(err);
    try { S.errorSink(text, err); }
    catch (e) {                                // ★ 报错通道自己坏了也不许把异常扔回调用方(那就成了第二处"看得见才怪")
      if (typeof console !== 'undefined' && console.error) console.error(text, e);
    }
  }
  function observed(label, p) {                // 给"会拒绝的入口"挂观察者,并原样返回那个 promise(见上面两条契约)
    if (p && typeof p.then === 'function') {
      p.then(null, function (e) { reportViewError(label, e); });
    }
    return p;
  }

  S.defaultErrorSink = defaultErrorSink;
  S.observed = observed;
}
