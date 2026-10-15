// ui/96_selftest.js —— 页面内自检(浏览器侧唯一能跑的判据)。


// ── 浏览器自检(★ node 到不了的那半边):判据是文本 SELFTEST OK,失败逐条列出,人在浏览器里点「自检」按钮。
// ★★ 自检是页面上的异步入口之一,必须经 guard 收口:它现在会拒绝(selfTest 消费 Io.ping / Io.encodeMap /
//    Io.decodeMap,io.js 那个 30s 超时是新的拒绝源,此外它自己也会把 indexedDB / localStorage 当成可能失败来探)。
//    丢掉那条 promise 就是一次未处理的拒绝:闸 4 的围栏会写一份崩溃快照 ⇒ 下次开机弹一个假的「上次异常退出」。
// ★ 抽成具名函数是为了让它可被 node 驱动:判"有没有护栏"必须是行为断言,而不是源码里 grep 一个 guard(。
function runSelfTest() {
  return guard('自检', function () {
    return selfTest().then(function (line) { status(line); return line; });
  });
}

// ★ localStorage:写 → 读 → 删。隐私模式或被策略禁用时 setItem 会抛 —— 这是纯浏览器的失败面。
function probeLocalStorage() {
  try {
    var k = 'cyrm.selftest', v = String(nowMs());
    localStorage.setItem(k, v);
    var same = localStorage.getItem(k) === v;
    localStorage.removeItem(k);
    return same;
  } catch (e) { return false; }
}
// ★ IndexedDB:真开一次库(只看 typeof 是查不出"被策略拦/隐私模式"的)。★ 超时也必须收口:open 被
//    拦时可能一个回调都不来,那时自检那一行永远不出现 —— 所以 2 秒没有回调就判失败并把原因写出来。
function probeIndexedDb() {
  return new Promise(function (resolve) {
    var done = false;
    var finish = function (okv, why) {
      if (done) return;
      done = true;
      resolve({ ok: okv, why: why || '' });
    };
    if (typeof indexedDB === 'undefined' || !indexedDB) { finish(false, '本环境没有 indexedDB'); return; }
    var timer = setTimeout(function () { finish(false, '2 秒内没有任何回调(被拦?)'); }, 2000);
    var req;
    try { req = indexedDB.open('cyrm.selftest', 1); }
    catch (e) { clearTimeout(timer); finish(false, msgOf(e)); return; }
    req.onupgradeneeded = function () { /* 建库,不需要任何表 */ };
    req.onerror = function () { clearTimeout(timer); finish(false, 'open 失败'); };
    req.onblocked = function () { clearTimeout(timer); finish(false, 'open 被阻塞'); };
    req.onsuccess = function () {
      clearTimeout(timer);
      var db = req.result;
      try { db.close(); } catch (e) { /* 关不上不影响判据 */ }
      try { indexedDB.deleteDatabase('cyrm.selftest'); } catch (e) { /* 同上 */ }
      finish(true, '');
    };
  });
}

function selfTest() {
  var lines = [];
  var fails = 0;
  var check = function (name, cond, extra) {
    if (cond) { lines.push('  ok  - ' + name); }
    else { fails++; lines.push('  FAIL - ' + name + (extra ? '(' + extra + ')' : '')); }
  };
  return Promise.resolve().then(function () {
    check('Worker 可用', Io.workerAvailable());
    check('图集已加载', Render.atlasInfo() !== null,
          Render.atlasInfo() ? '' : 'structure.png 没加载成功');
    check('图集容量 > 0', Render.atlasCapacity() > 0, '实得 ' + Render.atlasCapacity());
    // ★ 工具内核:它的产物是差量、不碰 DOM,所以能在这里拿一张一次性小图真落一笔 —— 验的是"装进浏览器
    //    之后它们还活着"(脚本没加载全 / 被 CSP 拦这类失败只有浏览器里看得见)。
    check('工具内核就绪(8 个工具)', TOOLS.length === 8 && typeof applyTool === 'function');
    try {
      var tm = createEmptyMap('selftest-tools', 2, 1);
      var td = applyTool({ map: tm, layer: Core.LAYER_SCENE, desc: Core.neutralDesc(1),
                           rgba: 0xFF00FFFF, brushSize: 1, selection: null, descOnly: false },
                         'brush', { kind: 'cell', x: 0, y: 0 }, null);
      check('落笔产出差量(整格 16 个子格)', !!td && td.idx.length === 16,
            td ? ('实得 ' + td.idx.length) : '没有产出差量');
    } catch (eTool) { check('落笔产出差量(整格 16 个子格)', false, msgOf(eTool)); }
    // ★★ 探完必须把调用方那个 sink 还原(不是置 null):自检交回的那条 promise 之后还会走 guard 的失败
    //    分支,那时 sink 若已被置 null,reportError 就走默认那条(status + console.error)。node 冒烟里
    //    那是 stderr 上的一行,而"stderr 有字节 = 有东西红了"正是整份冒烟赖以成立的那个信号。
    var savedSinkST = errorSinkFn;
    var sinkGot = null;
    setErrorSink(function (t) { sinkGot = t; });
    guard('自检', function () { throw new Error('自检用的假错'); });
    setErrorSink(savedSinkST);
    check('guard 的失败上报到 sink(可见)', !!sinkGot && sinkGot.indexOf('自检用的假错') >= 0,
          sinkGot || '没有上报 —— 那就成了"按了没反应"');
    check('地图已打开', app.map !== null);
    check('画布有尺寸', app.canvas.width > 1 && app.canvas.height > 1,
          app.canvas.width + '×' + app.canvas.height);
    check('localStorage 可读写', probeLocalStorage());
    if (app.map) {
      check('map.name 来自文件名', app.map.name === nameFromFile(app.name),
            'name=' + app.map.name + ' / 文件 ' + app.name);
      check('缩略图已建', app.r.stats().thumbsBuilt > 0);
    }
    return probeIndexedDb().then(function (idb) {
      check('IndexedDB 可打开', idb.ok, idb.why);
      // ★ 与上一条不是同一件事:上面那条开的是自检自己那个临时库(证明"能开"),这一条说的是草稿盘这个
      //    库有没有真开出来 —— 它打不开时编辑器照常能用,只是自动存那一层静默缺席。
      check('草稿盘已打开(app.db)', app.db !== null && app.db !== undefined,
            app.db ? '' : '草稿盘打不开:自动存不会发生,只能靠 Ctrl+S');
      return Io.ping().then(function (p) {
        check('Worker ping 有应答', p && p.pong === true);
        var m = Core.createMap('selftest', 4, 3);
        for (var i = 0; i < m.layers[Core.LAYER_SCENE].desc.length; i++) {
          m.layers[Core.LAYER_SCENE].desc[i] = Core.neutralDesc(1);
        }
        return Io.encodeMap(m).then(function (bytes) {
          check('浏览器里 encodeMap 产出 "CYRM"', bytes[0] === 0x43 && bytes[1] === 0x59);
          check('压缩路径(compression=1)', bytes[5] === 1);
          return Io.decodeMap(bytes).then(function (back) {
            var a = back.layers[Core.LAYER_SCENE].desc;
            var same = a.length === m.layers[Core.LAYER_SCENE].desc.length;
            for (var k = 0; same && k < a.length; k++) if (a[k] !== m.layers[Core.LAYER_SCENE].desc[k]) same = false;
            check('经 Worker 往返逐格一致', same);
          });
        });
      });
    });
  }).then(function () {
    var head = fails === 0 ? 'SELFTEST OK' : ('SELFTEST FAIL: ' + fails + ' 条');
    if (typeof console !== 'undefined') console.log(head + '\n' + lines.join('\n'));
    return head + ' · 共 ' + lines.length + ' 条检查';
  });
}
