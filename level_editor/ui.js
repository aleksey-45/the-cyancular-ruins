// ui.js —— 编辑器界面(规格 §4.4–§4.8)。
//
// ★★ 顶层一行都不碰 DOM:DOM 只在 boot() 与它装上的回调里取。于是 node 能把
//    "错了也不报错、只在屏幕上看出来"的那几层(工具内核 / 撤销差量 / 名字 / 尺寸钳制)
//    逐条断言 —— 见 editor_smoke.js。
// ★ 页面里不许有第二份数学:像素走 Tint.*,编解码与迁移走 Core.*,几何走 Render.*。
// ★ 依赖顺序:core.js → tile_defs.js → tint.js → render.js → io.js → ui.js。
// ★ 本文件是 T3 的**启动最小版**:图集 / 库列表 / 打开地图 / 挂载渲染 / 状态栏 / 自检。
//   工具、撤销、面板交互、持久化分别在 Task 5~9 落地。
globalThis.Editor = (function () {
  'use strict';

  var Core = globalThis.Core, Render = globalThis.Render, Io = globalThis.Io;
  if (!Core) throw new Error('ui.js: 必须先加载 core.js');
  if (!Render) throw new Error('ui.js: 必须先加载 render.js');
  if (!Io) throw new Error('ui.js: 必须先加载 io.js');

  var UI_STATE_KEY = 'cyrm.ui.v1';
  var DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;

  // 运行时状态(页面用;node 冒烟不碰它)
  // ★ 计划 2b 的接口表把 raw/name/sourceFormat 写成 `Editor.rawBytes()/rawName()/sourceFormat()`
  //   —— 那三个**函数不存在**,真身是下面这个 `app` 对象上的三个字段(`Editor.app.raw` /
  //   `Editor.app.name` / `Editor.app.sourceFormat`,经导出表的 `app: app` 暴露);
  //   Task 8/9 消费的正是 `app.*` 那形式,故无下游断裂,是**接口表那份文本错了**。
  var app = {
    r: null, canvas: null, map: null, name: null,
    raw: null, sourceFormat: null, tileDefs: null,
  };

  function $(id) { return document.getElementById(id); }
  function nowMs() {
    return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
  }
  function msgOf(e) {
    if (!e) return '未知错误';
    var m = (e.message !== undefined) ? String(e.message) : String(e);
    if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
    return String(m);
  }

  function status(msg) { var el = $('status-msg'); if (el) el.textContent = String(msg); }

  // ★ 面板与渲染里抛出的异常必须**可见**:症状"按了没反应"最难查,而静默捕获更糟。
  function guard(label, fn) {
    try { return fn(); }
    catch (e) { status('出错了(' + label + '):' + msgOf(e)); if (typeof console !== 'undefined') console.error(label, e); return null; }
  }

  // ── 纯函数(editor_smoke.js 直接断言)──
  // ★★ 库的身份就是**文件名**(计划 2a 的裁决 ②),而 v4 的 body 里**没有** name 字段
  //    (decodeMap 返回 name:'')⇒ 导入方必须自己用文件名补 map.name,否则
  //    sanitizeName 会把它回落成 'structure'(地图名字全体变成 structure)。
  function nameFromFile(fileName) {
    return String(fileName == null ? '' : fileName).replace(/\.cyrm$/i, '');
  }
  // 三种输入(规格 §3.6):v4 二进制 / 带 `# cyrm-v3` 标记的 v3 文本 / 旧字母格式。
  // ★ 判据只此一处:先嗅 v4 的 magic(4 字节),否则当文本看 —— 有没有 v3 标记由
  //   Core.isV3Text 判,没有标记就是旧字母格式(parseV3Text 自己会走 2×2 折叠那条路)。
  function detectFormat(bytes) {
    var b = (bytes && bytes.length !== undefined) ? bytes : null;
    if (b && b.length >= 4 && b[0] === 0x43 && b[1] === 0x59 && b[2] === 0x52 && b[3] === 0x4D) return 'v4';
    var text = new TextDecoder('utf-8', { fatal: false }).decode(b ? b.subarray(0, 4096) : new Uint8Array(0));
    return Core.isV3Text(text) ? 'v3' : 'legacy';
  }
  function mapFromBytes(fileName, bytes) {
    var fmt = detectFormat(bytes);
    if (fmt === 'v4') {
      return Io.decodeMap(bytes).then(function (map) {
        map.name = nameFromFile(fileName);          // ★★ 见 nameFromFile 的说明
        return { map: map, sourceFormat: 'v4' };
      });
    }
    var text = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
    var map = Core.migrateV3(Core.parseV3Text(text));
    map.name = nameFromFile(fileName);
    return Promise.resolve({ map: map, sourceFormat: fmt });
  }

  // ── 图集(Task 3:结构图 一次装进来;换图由 Task 8 的"重载贴图"按钮触发)──
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
      img.src = 'structure.png';
    });
  }

  // ── 打开地图(拉字节 → 迁移/解码 → 挂到渲染器)──
  function openMap(name) {
    status('打开 ' + name + ' …');
    return fetch('/api/map?p=' + encodeURIComponent(name))
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); })
      .then(function (buf) {
        app.raw = new Uint8Array(buf);
        return mapFromBytes(name, app.raw);
      })
      .then(function (out) {
        app.map = out.map; app.name = name; app.sourceFormat = out.sourceFormat;
        return Promise.resolve(app.r.setMap(app.map)).then(function () {
          refreshStatus();
          status('已打开 ' + name + '(' + out.sourceFormat + ')');
        });
      });
  }

  function refreshStatus() {
    var m = app.map;
    if (!m) return;
    var set = function (id, txt) { var el = $(id); if (el) el.textContent = txt; };
    set('st-name', (m.name || '(无名)') + (app.name ? ' · ' + app.name : ''));
    set('st-size', Core.cellsWOf(m) + '×' + Core.cellsHOf(m) + ' 格');
    var rep = Core.validateMap(m);
    set('st-valid', rep.errors.length ? ('error ' + rep.errors.length)
                                      : (rep.warnings.length ? ('⚠ ' + rep.warnings.length) : '校验 OK'));
  }

  // ── 库列表 ──
  function refreshLibrary() {
    return fetch('/api/maps').then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (data) {
      var ul = $('lib-list');
      if (!ul) return;
      ul.innerHTML = '';
      if (!data.maps.length) { ul.textContent = 'maps/ 下没有 .cyrm'; return; }
      data.maps.forEach(function (mm) {
        var li = document.createElement('li');
        li.className = 'lib-row';
        li.dataset.name = mm.name;
        li.textContent = mm.name + '  ' + Math.round(mm.size / 1024) + 'KB';
        li.title = new Date(mm.mtime).toLocaleString();
        ul.appendChild(li);
      });
    });
  }

  // ── 启动 ──
  function openFromUrl() {
    var p = new URLSearchParams(location.search).get('p');
    if (p) return openMap(p);
    return refreshLibrary().then(function () {
      var first = document.querySelector('#lib-list .lib-row');
      return first ? openMap(first.dataset.name) : null;
    });
  }

  function boot() {
    app.canvas = $('map-canvas');
    if (!app.canvas) return;
    app.tileDefs = globalThis.TILE_DEFS || null;
    // ★ 闸 3 没有降级路径 ⇒ 缺 Worker 时的**唯一**正确行为是把话说清楚(而不是静默退回主线程)
    if (!Io.workerAvailable()) {
      var b = $('boot-error');
      if (b) { b.hidden = false; b.textContent = '本环境没有 Web Worker —— 请用 serve.bat 起服务器后打开 http://127.0.0.1:8777/(file:// 下没有 Worker)。'; }
      return;
    }
    app.r = Render.mount(app.canvas, {});
    var ro = new ResizeObserver(function () { guard('resize', function () { app.r.resize(); }); });
    ro.observe(app.canvas.parentElement);
    window.addEventListener('error', function (ev) {
      status('页面异常:' + (ev && ev.message ? ev.message : '未知'));
    });
    window.addEventListener('unhandledrejection', function (ev) {
      status('未处理的 promise 拒绝:' + msgOf(ev && ev.reason));
    });
    var selftestBtn = $('btn-selftest');
    if (selftestBtn) {
      selftestBtn.addEventListener('click', function () {
        selfTest().then(function (line) { status(line); });
      });
    }
    var fitBtn = $('btn-fit');
    if (fitBtn) fitBtn.addEventListener('click', function () { guard('fit', function () { app.r.fit(); }); });

    // ★ 图集必须先就位(渲染第一帧就要它);失败要说出来,而不是画一片黑。
    loadAtlas().then(function () {
      return openFromUrl();
    }).then(function () {
      if (new URLSearchParams(location.search).has('selftest')) {
        return selfTest().then(function (line) { status(line); });
      }
      return null;
    }).catch(function (e) {
      status('启动失败:' + msgOf(e));
    });
  }

  // ── 浏览器自检(★ node 到不了的那半边 —— 人眼验收就靠它打印的那一行)──
  // 判据:文本 `SELFTEST OK`;失败逐条列出。人在浏览器里点「自检」按钮,把那行贴回报告。

  // ★ localStorage:写 → 读 → 删。隐私模式或被策略禁用时 setItem **会抛** ——
  //   这是纯浏览器的失败面,node 侧一条断言都拦不住(持久化在 Task 9 落地在那上面)。
  function probeLocalStorage() {
    try {
      var k = 'cyrm.selftest', v = String(nowMs());
      localStorage.setItem(k, v);
      var same = localStorage.getItem(k) === v;
      localStorage.removeItem(k);
      return same;
    } catch (e) { return false; }
  }
  // ★ IndexedDB:真**开一次库**(只看 typeof 是查不出"被策略拦/隐私模式"的)。
  //   ★ 超时也必须收口:open 被拦时**可能一个回调都不来**,那时自检那一行永远不出现,
  //     看着像按钮坏了 —— 所以 2 秒没有回调就判失败并把原因写出来。
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
        // ★ 顺手删掉自检建的库:不在用户机器上留垃圾(删不掉同样不影响判据)。
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
      check('地图已打开', app.map !== null);
      check('画布有尺寸', app.canvas.width > 1 && app.canvas.height > 1,
            app.canvas.width + '×' + app.canvas.height);
      // ★ 持久化的两个 API(Task 9 才落地)现在就探一遍:它们**只在浏览器里**会失败
      //   (隐私模式 / 被策略禁用),而那时症状是"设置存不住" —— 最难查的一类。
      check('localStorage 可读写', probeLocalStorage());
      if (app.map) {
        // ★ 真正的性质是"map.name 等于文件名去掉后缀"(v4 body 里没有 name 字段)
        check('map.name 来自文件名', app.map.name === nameFromFile(app.name),
              'name=' + app.map.name + ' / 文件 ' + app.name);
        check('缩略图已建', app.r.stats().thumbsBuilt > 0);
      }
      return probeIndexedDb().then(function (idb) {
        check('IndexedDB 可打开', idb.ok, idb.why);
        return Io.ping().then(function (p) {
          check('Worker ping 有应答', p && p.pong === true);
          // 端到端:真浏览器里的 Worker + CompressionStream 往返一次
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

  return {
    boot: boot, guard: guard, status: status, msgOf: msgOf,
    nameFromFile: nameFromFile, detectFormat: detectFormat, mapFromBytes: mapFromBytes,
    openMap: openMap, openFromUrl: openFromUrl, refreshLibrary: refreshLibrary,
    selfTest: selfTest, refreshStatus: refreshStatus,
    app: app,
  };
})();
