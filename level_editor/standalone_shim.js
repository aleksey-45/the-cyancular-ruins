// standalone_shim.js —— 单文件版(dist/cyrm-editor.html)的运行时垫片。
// 只在打包页里加载:它把"没有服务器"这件事补上,编辑器源码一行都不用改。
//   ① 没有 Worker:用页面里真实存在的 worker.js 源码 + 假的 self 造一个同页实例;
//   ② 没有 /api/*:拦 fetch,把 maps 列表 / 读 / 写三件事接到本地文件上;
//   ③ 没有库列表:右栏注入"本地目录…"与"打开文件…"两个入口。
// 写路径两级:File System Access(选了目录就直接读写 maps/*.cyrm)/ 退化成下载 + 打开文件。
// ★ 不做:目录浏览之外的任何文件访问、多标签页同步、把整块磁盘暴露给页面。
'use strict';

(function () {
  if (!window.__CYRM_STANDALONE__) return;

  // ── ① 同页 Worker ──
  // 单文件版旁边**没有** worker.js:真 Worker 即使存在也只会 404,所以这里**无条件**换成
  // 同页实例(用打包进来的 worker.js 源码,协议一份都不重复)。代价是编解码跑在主线程:
  // 一张 125×75 的图是毫秒级,能接受;换来的是双击就能用。
  var workerSrc = window.__CYRM_WORKER_SRC__;
  if (workerSrc) {
    var fakeSelf = { onmessage: null, postMessage: null };
    // importScripts 空转:core 分片就在同一页,worker.js 里的 Core 直接解析到全局。
    new Function('self', 'importScripts', workerSrc)(fakeSelf, function () {});
    window.Worker = function () {
      var w = this;
      this.onmessage = null;
      this.onerror = null;
      this.terminate = function () { w.onmessage = null; };
      this.postMessage = function (msg) {
        fakeSelf.postMessage = function (reply) { if (w.onmessage) w.onmessage({ data: reply }); };
        try { fakeSelf.onmessage({ data: msg }); }
        catch (e) { if (w.onerror) w.onerror({ message: String(e && e.message ? e.message : e) }); }
      };
    };
  }

  // ── ② 本地文件后端 ──
  var picked = new Map();        // 名字 → Uint8Array(没有目录句柄时的退路:本会话打开过的文件)
  var dirHandle = null;          // File System Access 目录句柄(选了目录才有)
  var LAST_DIR_KEY = 'cyrm.editor.lastDir';

  function hasFsa() { return typeof window.showDirectoryPicker === 'function'; }

  function dirNames() {
    if (!dirHandle) return Promise.resolve([]);
    var out = [];
    var it = dirHandle.entries();
    function step() {
      return it.next().then(function (r) {
        if (r.done) return out;
        var entry = r.value;
        if (entry[1].kind === 'file' && /\.cyrm$/i.test(entry[0])) {
          out.push(entry[1].getFile().then(function (f) {
            return { name: entry[0], size: f.size, mtime: f.lastModified };
          }));
        }
        return step();
      });
    }
    return step().then(function (rows) {
      return Promise.all(rows).then(function (list) {
        return list.sort(function (a, b) { return a.name < b.name ? -1 : 1; });
      });
    });
  }
  function nameRows() {
    var out = [];
    picked.forEach(function (bytes, name) {
      if (/\.cyrm$/i.test(name)) out.push({ name: name, size: bytes.length, mtime: Date.now() });
    });
    return out;
  }
  function listRows() {
    return dirNames().then(function (rows) {
      var seen = {};
      rows.forEach(function (r) { seen[r.name] = true; });
      return rows.concat(nameRows().filter(function (r) { return !seen[r.name]; }));
    });
  }
  function readBytes(name) {
    if (dirHandle) {
      return dirHandle.getFileHandle(name).then(function (h) { return h.getFile(); })
        .then(function (f) { return f.arrayBuffer(); })
        .then(function (b) { return new Uint8Array(b); })
        .catch(function () { return picked.get(name) || null; });
    }
    return Promise.resolve(picked.get(name) || null);
  }
  function writeBytes(name, bytes) {
    if (dirHandle) {
      return dirHandle.getFileHandle(name, { create: true })
        .then(function (h) { return h.createWritable(); })
        .then(function (wst) { return wst.write(bytes).then(function () { return wst.close(); }); })
        .then(function () { return { name: name, size: bytes.length, to: 'dir' }; });
    }
    // 退路:下载一份,并在本会话里记着(库列表能再点开它)。
    picked.set(name, bytes);
    var a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([bytes], { type: 'application/octet-stream' }));
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    return Promise.resolve({ name: name, size: bytes.length, to: 'download' });
  }
  function json(body, status) {
    return new Response(JSON.stringify(body), {
      status: status || 200, headers: { 'Content-Type': 'application/json' },
    });
  }

  var origFetch = window.fetch.bind(window);
  window.fetch = function (input, init) {
    var url = String(input && input.url ? input.url : input);
    var method = (init && init.method) || 'GET';
    if (url.indexOf('/api/maps') === 0) {
      return listRows().then(function (maps) { return json({ maps: maps }); });
    }
    if (url.indexOf('/api/map?p=') === 0) {
      var name = decodeURIComponent(url.slice(url.indexOf('p=') + 2).split('&')[0]);
      if (method === 'GET' || method === 'HEAD') {
        return readBytes(name).then(function (bytes) {
          return bytes ? new Response(bytes, { status: 200 }) : json({ error: 'not found' }, 404);
        });
      }
      if (method === 'PUT') {
        var body = init && init.body;
        return Promise.resolve(body && body.arrayBuffer ? body.arrayBuffer() : body)
          .then(function (buf) { return writeBytes(name, new Uint8Array(buf)); })
          .then(function (out) { return json(out); });
      }
    }
    return origFetch(input, init);
  };

  // ── ③ 入口:右栏两个按钮 + 空库时给一张空白图 ──
  var libSettled = false;
  function hint(text) {
    var el = document.getElementById('lib-list');
    if (el) el.textContent = text;
  }
  function refresh() {
    var E = window.Editor;
    if (E && E.refreshLibrary) return E.refreshLibrary();
    return Promise.resolve();
  }
  // ★ 库是空的(没选目录、也没打开文件)时开机给一张空白图:否则双击进来是一片黑画布 +
  //   一句"加载中…",用户得自己想到去点「新建」。★ 只在这一种状态下动 prompt(新建要问名字,
  //   自动路径用默认名),点完立刻还原 —— 不许把人家的重命名提示也吞掉。
  function autoNewIfEmpty() {
    var E = window.Editor;
    if (!E || !E.app || !E.app.r) return;
    if (E.app.map) return;
    var btn = document.getElementById('btn-new');
    if (!btn) return;
    var orig = window.prompt;
    window.prompt = function () { return 'new_map'; };
    try { btn.click(); } finally { window.prompt = orig; }
    if (E.status) E.status('单文件版:库是空的,先给一张 125×75 的空白图 —— Ctrl+S 会写 new_map.cyrm');
  }
  function pickDir() {
    if (!hasFsa()) { hint('此浏览器没有目录访问能力,请用「打开文件…」'); return Promise.resolve(); }
    return window.showDirectoryPicker({ mode: 'readwrite' }).then(function (h) {
      dirHandle = h;
      try { localStorage.setItem(LAST_DIR_KEY, h.name); } catch (e) { /* 隐私模式:忽略 */ }
      return refresh();
    }).catch(function () { /* 用户取消:不是错误 */ });
  }
  function pickFiles() {
    var inp = document.createElement('input');
    inp.type = 'file';
    inp.accept = '.cyrm,application/octet-stream';
    inp.multiple = true;
    inp.addEventListener('change', function () {
      var files = Array.prototype.slice.call(inp.files || []);
      Promise.all(files.map(function (f) {
        return f.arrayBuffer().then(function (b) { picked.set(f.name, new Uint8Array(b)); });
      })).then(refresh);
    });
    inp.click();
  }
  function init() {
    var box = document.getElementById('lib-btns');
    if (box) {
      var b1 = document.createElement('button');
      b1.textContent = '本地目录…';
      b1.title = '选一个装有 .cyrm 的目录(如仓库的 maps/),之后库列表与 Ctrl+S 都直接读写它';
      b1.addEventListener('click', function () { pickDir(); });
      var b2 = document.createElement('button');
      b2.textContent = '打开文件…';
      b2.title = '没有目录访问能力时的退路:选若干 .cyrm,保存改为下载';
      b2.addEventListener('click', function () { pickFiles(); });
      box.appendChild(b1);
      box.appendChild(b2);
      try {
        var last = localStorage.getItem(LAST_DIR_KEY);
        if (last) b1.title = '上次用的目录:' + last + ' —— ' + b1.title;
      } catch (e) { /* 同上 */ }
      hint(hasFsa() ? '先选「本地目录…」或「打开文件…」' : '本浏览器无目录访问能力;用「打开文件…」,保存即下载');
    }
    // 等 boot 的链走完(库列过一次 + 渲染器挂上)再看要不要给空白图:早于它就会与 openFromUrl 抢。
    var tries = 0;
    var timer = setInterval(function () {
      var E = window.Editor;
      tries++;
      if (E && E.app && E.app.r && E.app.db !== undefined && libSettled) {
        clearInterval(timer);
        setTimeout(autoNewIfEmpty, 600);
      } else if (tries > 80) {
        clearInterval(timer);
      }
    }, 250);
    refresh().then(function () { libSettled = true; }, function () { libSettled = true; });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
