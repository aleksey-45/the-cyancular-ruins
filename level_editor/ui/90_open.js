// ui/90_open.js —— 打开地图、库列表、传输后端(服务器 maps/ / 本地目录)、保存出口。

// ── 传输后端 ──
// 同一时刻只有一个后端:server(/api/*,库 = 服务器的 maps/)/ dir(File System Access 目录句柄)。
// 切换入口只有 setFileOpsBackend(86_fileops.js 的「打开文件夹…」);列表、读、写、删、改名都问它 ——
// 否则"列表来自 A、保存写到 B"是静默的,而用户以为自己在改同一个库。
var FILEOPS_BACKEND_SERVER = 'server';
var FILEOPS_BACKEND_DIR = 'dir';
var fileOpsBackend = { kind: FILEOPS_BACKEND_SERVER, handle: null, label: '服务器 maps/' };

function fileOpsBackendKind() { return fileOpsBackend.kind; }
function fileOpsDirHandle() { return fileOpsBackend.handle; }
function fileOpsBackendLabel() { return fileOpsBackend.label; }
// 纯状态切换(不碰 DOM):#lib-backend 的文案由 86_fileops 的 refreshBackendLabel 写。
function setFileOpsBackend(kind, handle) {
  if (kind !== FILEOPS_BACKEND_SERVER && kind !== FILEOPS_BACKEND_DIR) {
    throw new Error('未知的传输后端:' + JSON.stringify(kind));
  }
  if (kind === FILEOPS_BACKEND_DIR && !handle) throw new Error('本地目录后端必须给目录句柄');
  fileOpsBackend = {
    kind: kind, handle: handle || null,
    label: kind === FILEOPS_BACKEND_DIR
      ? ('本地目录:' + String((handle && handle.name) || '(未命名)'))
      : '服务器 maps/',
  };
  return fileOpsBackend;
}
// 单文件版(dist/cyrm-editor.html)的文件后端由 standalone_shim.js 接管:这里让位,不写第二套。
function fileOpsStandalone() { return globalThis.__CYRM_STANDALONE__ === true; }

// ── HTTP 失败要带原因 ──
// 服务器失败时 body 是**人话**(api.js / map_ops.js 都 sendText 一段原因)。只抛 `HTTP 400` 的话,
// 用户以为是名字写错,实际可能是 409 目标已存在 / 415 内容类型 / 404 服务端还没实现。
function readErrorBody(r) {
  if (!r || typeof r.text !== 'function') return Promise.resolve('');
  return r.text().then(function (t) { return String(t == null ? '' : t).trim(); },
                       function () { return ''; });
}
function httpError(status, body) {
  return new Error('HTTP ' + status + (body ? ':' + body : ''));
}
function jsonOkOrThrow(r, what) {
  if (r && r.ok) return (typeof r.json === 'function') ? r.json() : Promise.resolve({});
  return readErrorBody(r).then(function (body) { throw new Error(what + '失败:' + msgOf(httpError(r ? r.status : 0, body))); });
}

// ── 服务器后端(/api/*)──
function serverListMaps() {
  return fetch('/api/maps').then(function (r) { return jsonOkOrThrow(r, '列库'); })
    .then(function (data) { return (data && data.maps) || []; });
}
function serverReadMapBytes(name) {
  return fetch('/api/map?p=' + encodeURIComponent(name)).then(function (r) {
    if (r.ok) return r.arrayBuffer();
    return readErrorBody(r).then(function (body) { throw httpError(r.status, body); });
  }).then(function (buf) { return new Uint8Array(buf); });
}
// ★★ PUT 必须显式带 Content-Type: application/json(服务器的写闸只收这一个类型,别的 415);
//    不写时浏览器按 Blob 的类型推,推出来的是 application/octet-stream。
function serverPutMapBytes(name, bytes) {
  return fetch('/api/map?p=' + encodeURIComponent(name), {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: new Blob([bytes]),
  }).then(function (r) { return jsonOkOrThrow(r, '写盘'); });
}
function serverDeleteMapFile(name) {
  return fetch('/api/map?p=' + encodeURIComponent(name), {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
  }).then(function (r) { return jsonOkOrThrow(r, '删除'); });
}
function serverRenameMapFile(from, to) {
  return fetch('/api/map/rename?from=' + encodeURIComponent(from) + '&to=' + encodeURIComponent(to), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: '{}',
  }).then(function (r) { return jsonOkOrThrow(r, '重命名'); });
}

// ── 本地目录后端(File System Access 目录句柄)──
// ★ 入口/迭代器都是 promise 形态(不用 async generator):还要兼容不支持 for await 的环境。
function dirListMaps(dir) {
  var rows = [];
  if (!dir || typeof dir.entries !== 'function') return Promise.resolve(rows);
  var it = dir.entries();
  function step() {
    return it.next().then(function (r) {
      if (r.done) {
        rows.sort(function (a, b) { return a.name < b.name ? -1 : 1; });
        return rows;
      }
      var entry = r.value;
      if (entry[1].kind !== 'file' || !/\.cyrm$/i.test(entry[0])) return step();
      return entry[1].getFile().then(function (f) {
        rows.push({ name: entry[0], size: f.size, mtime: f.lastModified });
        return step();
      }, function () { return step(); });
    });
  }
  return step();
}
function dirReadMapBytes(dir, name) {
  return dir.getFileHandle(name).then(function (h) { return h.getFile(); },
                                      function () { throw new Error('本地目录里没有 ' + name); })
    .then(function (f) { return f.arrayBuffer(); })
    .then(function (buf) { return new Uint8Array(buf); });
}
function dirPutMapBytes(dir, name, bytes) {
  return dir.getFileHandle(name, { create: true })
    .then(function (h) { return h.createWritable(); })
    .then(function (w) { return w.write(bytes).then(function () { return w.close(); }); })
    .then(function () { return { name: name, size: bytes.length }; });
}
function dirDeleteMapFile(dir, name) {
  return Promise.resolve(dir.removeEntry(name)).then(function () { return { ok: true, deleted: name }; });
}
// FSA 没有 rename:同目录下"读旧 → 写新 → 删旧"。★ 两步之间失败会留下两份(新已写、旧未删),
// 所以删旧失败要把"新名字已经存在"说出来 —— 不能假装整件事没发生。
function dirRenameMapFile(dir, from, to) {
  return dirReadMapBytes(dir, from).then(function (bytes) {
    return dirPutMapBytes(dir, to, bytes).then(function (out) {
      return dirDeleteMapFile(dir, from).then(function () { return { ok: true, name: out.name }; },
        function (e) {
          throw new Error('已写成 ' + to + ',但删不掉旧文件 ' + from + '(' + msgOf(e) +
                          ') —— 现在目录里有两份,请手动删掉旧的');
        });
    });
  });
}

// ── 统一的库/读写/删/改名出口(按当前后端分派)──
function listLibraryMaps() {
  return fileOpsBackend.kind === FILEOPS_BACKEND_DIR
    ? dirListMaps(fileOpsBackend.handle) : serverListMaps();
}
function readMapBytes(name) {
  return fileOpsBackend.kind === FILEOPS_BACKEND_DIR
    ? dirReadMapBytes(fileOpsBackend.handle, name) : serverReadMapBytes(name);
}
function putMapBytes(name, bytes) {
  return fileOpsBackend.kind === FILEOPS_BACKEND_DIR
    ? dirPutMapBytes(fileOpsBackend.handle, name, bytes) : serverPutMapBytes(name, bytes);
}
function deleteMapFile(name) {
  return fileOpsBackend.kind === FILEOPS_BACKEND_DIR
    ? dirDeleteMapFile(fileOpsBackend.handle, name) : serverDeleteMapFile(name);
}
function renameMapFile(from, to) {
  return fileOpsBackend.kind === FILEOPS_BACKEND_DIR
    ? dirRenameMapFile(fileOpsBackend.handle, from, to) : serverRenameMapFile(from, to);
}

// ── 打开 ──
function openMap(name) {
  status('打开 ' + name + ' …');
  return readMapBytes(name).then(function (bytes) {
    return mapFromBytes(name, bytes).then(function (out) { return { out: out, bytes: bytes }; });
  }).then(function (got) {
    var out = got.out;
    // ★★★ app.raw 只能在这里认领(此刻解码已经成功):写在"拿到字节"那一步的话,一次失败的打开
    //    会把失败文件的字节留在 app.raw,而 app.map/app.name 仍是上一张图 ⇒ 原文备份、草稿字节闸全错位。
    app.raw = got.bytes;
    app.map = out.map; app.name = name; app.sourceFormat = out.sourceFormat;
    dirty = false;                 // 打开 = 屏幕上这份与磁盘上那份同源
    draftSavedRev = draftRev;
    lastAutoSaveAt = 0;
    if (typeof hideEmptyHint === 'function') hideEmptyHint();
    return Promise.resolve(app.r.setMap(app.map)).then(function () {
      refreshStatus();
      status('已打开 ' + name + '(' + out.sourceFormat + ')');
    });
  });
}

// 「所有换图路都走这里」:新建 / 复制 / 打开文件 / ?p= 都归它 —— 解码 → 认领 → setMap → refreshStatus。
// ★ sourceFormatOverride 只在**与解码判据一致**时采用:v3 文件被当成 v4 会让「保存前备份原文」那道门失效。
// ★ opts.dirty = true:这份图还没写进任何库(打开文件只是读入),状态栏要如实说「未保存」。
function setMapFromBytes(name, bytes, sourceFormatOverride, opts) {
  opts = opts || {};
  return mapFromBytes(name, bytes).then(function (out) {
    var fmt = out.sourceFormat;
    if (sourceFormatOverride && sourceFormatOverride === out.sourceFormat) fmt = sourceFormatOverride;
    app.raw = bytes;
    app.map = out.map; app.name = name; app.sourceFormat = fmt;
    draftSavedRev = draftRev;
    lastAutoSaveAt = 0;
    if (opts.dirty) { dirty = true; } else { dirty = false; }
    if (typeof hideEmptyHint === 'function') hideEmptyHint();
    return Promise.resolve(app.r.setMap(app.map)).then(function () {
      refreshStatus();
      if (typeof statusLine === 'function') statusLine();
      if (opts.dirty) markDirty();          // 排一次草稿:读入的文件还没写进任何库
      return { map: app.map, sourceFormat: fmt };
    });
  });
}

// 关掉当前图,回到空状态:文件动作(删除当前图 / 打开失败)用它把界面与内存一起归位。
function closeMap() {
  app.map = null; app.name = null; app.raw = null; app.sourceFormat = null;
  if (typeof refreshRespawnCount === 'function') refreshRespawnCount();
  undoHistory = createHistory({});
  app.st.selDrag = null;
  if (app.r) {
    if (app.r.setSelection) app.r.setSelection(null);
    if (app.r.setSelDrag) app.r.setSelDrag(null, 0, 0);
    if (app.r.setPreview) app.r.setPreview(null);
  }
  dirty = false;
  draftSavedRev = draftRev;
  lastAutoSaveAt = 0;
  if (typeof showEmptyState === 'function') showEmptyState();
  return Promise.resolve(true);
}

function refreshStatus() {
  var m = app.map;
  if (!m) return;
  var set = function (id, txt) { var el = $(id); if (el) el.textContent = txt; };
  set('st-name', (m.name || '(无名)') + (app.name ? ' · ' + app.name : ''));
  set('st-size', Core.cellsWOf(m) + '×' + Core.cellsHOf(m) + ' 格');
  // ★★ 尺寸面板的两个框也要跟着走(DOM 必须与状态一致):refreshStatus 是打开/新建/复制/改尺寸/草稿恢复的公共收口。
  sizeInputsSync();
  var rep = Core.validateMap(m);
  set('st-valid', rep.errors.length ? ('error ' + rep.errors.length)
                                    : (rep.warnings.length ? ('⚠ ' + rep.warnings.length) : '校验 OK'));
  renderSaveState();
  // ★★ 图层行图标(本图无此层 / 🔒 / 👁 明暗)必须从真实状态反推:这里是换图的公共收口,只有它能保证跟着刷新。
  if (typeof syncLayerIcons === 'function') syncLayerIcons();
  if (typeof refreshRespawnCount === 'function') refreshRespawnCount();
}

var lastLibraryRows = [];
function refreshLibrary() {
  return listLibraryMaps().then(function (rows) {
    lastLibraryRows = (rows || []).slice();
    if (typeof refreshBackendLabel === 'function') refreshBackendLabel();
    var ul = $('lib-list');
    if (!ul) return;
    ul.innerHTML = '';
    // ★ 原文备份不进库列表(库的身份是地图):只过滤显示这一侧;?p= 直接打开那条路它管不到。
    var shown = lastLibraryRows.filter(function (mm) { return !isBackupName(mm.name); });
    if (!shown.length) {
      ul.textContent = fileOpsBackend.kind === FILEOPS_BACKEND_DIR
        ? '这个目录下没有 .cyrm' : 'maps/ 下没有 .cyrm';
      return;
    }
    shown.forEach(function (mm) {
      var li = document.createElement('li');
      li.className = 'lib-row';
      li.dataset.name = mm.name;
      li.textContent = mm.name + '  ' + Math.round(mm.size / 1024) + 'KB';
      li.title = new Date(mm.mtime).toLocaleString();
      ul.appendChild(li);
    });
  });
}

// ② 空启动:不再自动打开库列表第一行(用户要的是"真的文件操作",替他随机开一张等于替他做决定)。
// ?p= 仍打开指定图;失败照旧**向上抛** —— 启动链该在"打开失败"这一站停下,由 bootLoad 的 catch 说原因。
function openFromUrl() {
  var search = (typeof location !== 'undefined' && location && location.search) ? location.search : '';
  var p = new URLSearchParams(search).get('p');
  if (p) return openMap(p);
  return refreshLibrary().then(function () {
    if (!app.map && typeof showEmptyState === 'function') showEmptyState();
  });
}
