// render/40_slicer.js —— 闸 2 单帧预算的时间切片器 createSlicer(分帧是"慢慢画出来",不是"页面死掉")。

function createSlicer(opts) {
  opts = opts || {};
  var raw = opts.budgetMs === undefined ? DEFAULT_BUDGET_MS : opts.budgetMs;
  // ★★ 预算必须是有限的数(now() - s0 >= NaN 恒为 false、负预算同理永远不成立 ⇒ while 一口气做完整批,而那正是闸 2 要防的,且不报错);「每帧至少做一项」也是必须的,否则 budgetMs = 0 时循环会一项不做就让出、让出之后又一项不做 —— 死循环(0 是合法的注入值,测试就在用它)。
  var budget = (typeof raw === 'number' && isFinite(raw)) ? Math.max(0, raw) : DEFAULT_BUDGET_MS;
  var now = opts.now || function () {
    return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
  };
  var nextFrame = opts.nextFrame || function () {
    return new Promise(function (r) { requestAnimationFrame(function () { r(); }); });
  };
  function run(items, fn) {
    var i = 0, frames = 0, maxStep = 0;
    return new Promise(function (resolve, reject) {
      // ★★ 抛错必须落到这个 promise 上:第 2 帧起 step 跑在 nextFrame().then(step) 这条没人观察的链上,裸抛会变成 unhandled rejection 而 run() 永远不 settle;
      //    第一帧抛却正常 reject(那时 step 还在 promise 执行器里同步跑)。两条路径症状不同,只测"第一帧抛"区分不了。
      function step() {
        try {
          var s0 = now();
          while (i < items.length) {
            fn(items[i], i); i++;
            if (now() - s0 >= budget) break;   // ★ 判在做完之后:预算是软的(到手一项就做完它),但一格都不许超
          }
          var d = now() - s0;
          if (d > maxStep) maxStep = d;
          if (i >= items.length) { resolve({ frames: frames, processed: i, maxStepMs: maxStep }); return; }
          frames++;                          // ★ 时间基准在让出之后重新取:让出一帧自己也花时间,把那段算进下一帧的预算会让"下一帧刚做一项就又超预算" —— 分帧退化成逐项让出
          // ★★ 第二个实参同样是承重的:它堵的是"让出的那一帧抛"(注入的 nextFrame() 交回 rejected promise)。只写 .then(step) 的话 step 一次都不会被调到,run() 的 promise 就悬在那里。
          nextFrame().then(step, reject);
        } catch (err) {
          reject(err);                           // ← 让第 2 帧起的抛错也 settle 掉 run()
        }
      }
      step();
    });
  }
  return { run: run, budgetMs: budget };
}
