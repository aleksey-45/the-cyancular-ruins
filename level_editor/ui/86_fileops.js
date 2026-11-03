// ui/86_fileops.js —— 文件级动作:新建 / 打开文件 / 打开文件夹 / 保存 / 另存为 / 导出 / 复制 / 重命名 / 删除 / 校验。
// ★ 顶层只放声明,一个 DOM 都不碰(node 冒烟会加载本分片);所有绑定发生在 installFileOps()。
// ★ 对话框一律页内生成(createElement 挂 body):window.prompt/alert 在自动化下会被自动取消或卡住页面,
//   而用户要的是"真的",不是"看起来像真的"。

// 名字口径必须与服务器同一套(browser 里不能 require servers 的文件):server/map_names.js 的 MAP_NAME_RE。
var FILEOPS_MAX_MAP_NAME_LEN = 64;
var FILEOPS_MAP_NAME_RE = /^[A-Za-z0-9_\-]+(?:\.cyrm|\.v3\.bak)$/;

function isValidMapName(name) {
  if (typeof name !== 'string') return false;
  if (name.length === 0 || name.length > FILEOPS_MAX_MAP_NAME_LEN) return false;
  if (name.indexOf('\0') >= 0) return false;
  return FILEOPS_MAP_NAME_RE.test(name);
}
function mapNameProblem(name) {
  if (name === null || name === undefined || name === '') return '名字是空的';
  if (typeof name !== 'string') return '名字必须是字符串';
  if (name.length > FILEOPS_MAX_MAP_NAME_LEN) return '名字太长(上限 ' + FILEOPS_MAX_MAP_NAME_LEN + ' 字符)';
  if (!isValidMapName(name)) return '只接受裸文件名,形如 ' + FILEOPS_MAP_NAME_RE.source + '(不带目录、不带其它后缀)';
  return '';
}
// 用户在对话框里输的是"名字",不是文件名:没后缀就补 .cyrm,绝不把用户输入直接当路径。
function normalizeMapFileName(raw) {
  var s = String(raw == null ? '' : raw).trim();
  if (!s) return '';
  if (/\.v3\.bak$/i.test(s) || /\.cyrm$/i.test(s)) return s;
  return Core.sanitizeName(s) + '.cyrm';
}

// ── 可注入的 UI 面 ──
// 测试替身靠这几个钩子驱动真流程,不必造一套真 DOM(与 render 的 backend 注入同一手法)。
var fileOpsAsk = null;          // function(spec) -> Promise<obj|null>
var fileOpsPick = null;         // function() -> Promise<{name, bytes}|null>
var fileOpsReportSink = null;   // function(title, lines, ok) -> any

function askForm(spec) {
  if (typeof fileOpsAsk === 'function') return fileOpsAsk(spec);
  return defaultAskDialog(spec);
}
function pickFile() {
  if (typeof fileOpsPick === 'function') return fileOpsPick();
  return pickFileByInput();
}
function showReport(title, lines, ok) {
  if (typeof fileOpsReportSink === 'function') return fileOpsReportSink(title, lines, ok);
  return defaultReportDialog(title, lines, ok);
}

// ── 页内对话框(真 DOM)──
function dialogParts() {
  if (typeof document === 'undefined' || !document || typeof document.createElement !== 'function') return null;
  var host = document.body || document.documentElement;
  if (!host || typeof host.appendChild !== 'function') return null;
  return { doc: document, host: host };
}
function fileOpsEl(tag, cls) {
  var el = document.createElement(tag);
  if (cls) el.className = cls;
  return el;
}
function defaultAskDialog(spec) {
  var d = dialogParts();
  if (!d) return Promise.resolve(null);
  spec = spec || {};
  return new Promise(function (resolve) {
    var overlay = fileOpsEl('div');
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;z-index:9999';
    var card = fileOpsEl('div');
    card.style.cssText = 'min-width:340px;max-width:560px;background:#1f2329;color:#d7dde5;border:1px solid #343b45;border-radius:6px;padding:14px 16px;font-size:13px;box-shadow:0 8px 30px rgba(0,0,0,.5)';
    var head = fileOpsEl('div');
    head.textContent = spec.title || '输入';
    head.style.cssText = 'font-weight:bold;margin-bottom:10px;color:#54a0ff';
    card.appendChild(head);
    var inputs = [];
    (spec.fields || []).forEach(function (f) {
      var row = fileOpsEl('label');
      row.style.cssText = 'display:flex;gap:8px;align-items:center;margin:6px 0';
      var lab = fileOpsEl('span');
      lab.textContent = f.label || f.name;
      lab.style.cssText = 'width:130px;color:#8b94a1';
      var inp = fileOpsEl('input');
      inp.type = f.type || 'text';
      inp.value = f.value === undefined || f.value === null ? '' : String(f.value);
      if (f.min !== undefined) inp.min = String(f.min);
      if (f.max !== undefined) inp.max = String(f.max);
      inp.style.cssText = 'flex:1;background:#262b32;color:#d7dde5;border:1px solid #343b45;border-radius:4px;padding:4px 6px';
      row.appendChild(lab); row.appendChild(inp); card.appendChild(row);
      inputs.push({ name: f.name, el: inp });
    });
    if (spec.hint) {
      var hint = fileOpsEl('div');
      hint.textContent = spec.hint;
      hint.style.cssText = 'color:#8b94a1;margin:8px 0 2px;line-height:1.6';
      card.appendChild(hint);
    }
    var btns = fileOpsEl('div');
    btns.style.cssText = 'display:flex;gap:8px;justify-content:flex-end;margin-top:12px';
    var cancel = fileOpsEl('button');
    cancel.textContent = spec.cancelText || '取消';
    var okBtn = fileOpsEl('button');
    okBtn.textContent = spec.okText || '确定';
    okBtn.style.cssText = 'border-color:#54a0ff;background:#243040';
    btns.appendChild(cancel); btns.appendChild(okBtn); card.appendChild(btns);
    overlay.appendChild(card);
    d.host.appendChild(overlay);
    var settled = false;
    function close(val) {
      if (settled) return;
      settled = true;
      if (overlay.remove) overlay.remove();
      else if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
      resolve(val);
    }
    function submit() {
      var out = {};
      inputs.forEach(function (it) { out[it.name] = it.el.value; });
      close(out);
    }
    cancel.addEventListener('click', function () { close(null); });
    okBtn.addEventListener('click', submit);
    overlay.addEventListener('click', function (ev) { if (ev.target === overlay) close(null); });
    overlay.addEventListener('keydown', function (ev) {
      if (ev.key === 'Escape') { ev.preventDefault(); close(null); }
      else if (ev.key === 'Enter') { ev.preventDefault(); submit(); }
    });
    if (inputs.length && inputs[0].el.focus) inputs[0].el.focus();
  });
}
function defaultReportDialog(title, lines, ok) {
  var d = dialogParts();
  var text = String(title || '报告') + '\n\n' + (lines || []).join('\n');
  if (!d) {
    if (typeof console !== 'undefined') console.log(text);
    return null;
  }
  var overlay = fileOpsEl('div');
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;z-index:9999';
  var card = fileOpsEl('div');
  card.style.cssText = 'min-width:360px;max-width:640px;max-height:70vh;overflow:auto;background:#1f2329;color:#d7dde5;border:1px solid #343b45;border-radius:6px;padding:14px 16px;font-size:13px';
  var head = fileOpsEl('div');
  head.textContent = String(title || '报告') + (ok === false ? ' —— 有 error' : '');
  head.style.cssText = 'font-weight:bold;margin-bottom:10px;color:' + (ok === false ? '#e06a5a' : '#54a0ff');
  var pre = fileOpsEl('pre');
  pre.textContent = (lines || []).join('\n');
  pre.style.cssText = 'white-space:pre-wrap;line-height:1.6;margin:0 0 12px;color:#d7dde5';
  var closeBtn = fileOpsEl('button');
  closeBtn.textContent = '关闭';
  closeBtn.addEventListener('click', function () {
    if (overlay.remove) overlay.remove(); else if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
  });
  card.appendChild(head); card.appendChild(pre); card.appendChild(closeBtn);
  overlay.appendChild(card);
  d.host.appendChild(overlay);
  return null;
}

// ── 空状态 ──
function clearCanvasPixels() {
  var cv = app.canvas;
  if (!cv || typeof cv.width !== 'number') return;
  try { cv.width = cv.width; } catch (e) { /* 只清屏:失败不影响状态归位 */ }
}
function setEmptyStatusText() {
  var set = function (id, txt) { var el = $(id); if (el) el.textContent = txt; };
  set('st-name', '(未打开)'); set('st-size', ''); set('st-valid', '');
  set('st-sel', ''); set('st-undo', ''); set('st-save', '');
}
// ★★ `hidden` 属性管不住它:editor.html 的 `#empty-hint` 带 `display:flex`(id 选择器优先级高于 UA 的
//    `[hidden]{display:none}`)⇒ 只设 hidden 的话空状态永远挂在画布上(实测:打开地图后提示还浮着)。
//    显示器上就两条路:显式 `style.display`。
function showEmptyState(keepStatus) {
  var hint = $('empty-hint');
  if (hint) {
    hint.hidden = false;
    hint.style.display = 'flex';
    hint.style.pointerEvents = 'auto';   // 没图时挡住画布,别让点击落到 null map 上
  }
  clearCanvasPixels();
  setEmptyStatusText();
  if (keepStatus !== true) status('还没有打开地图 —— 顶部「新建」/「打开文件…」/「打开文件夹…」');
}
function hideEmptyHint() {
  var hint = $('empty-hint');
  if (hint) {
    hint.hidden = true;
    hint.style.display = 'none';
    hint.style.pointerEvents = 'none';
  }
}
function emptyHintShown() {
  var hint = $('empty-hint');
  return !!(hint && hint.style && hint.style.display !== 'none');
}

// ── 库/后端显示条 ──
function refreshBackendLabel() {
  var el = $('lib-backend');
  if (!el) return;
  el.textContent = fileOpsStandalone() ? '单文件版:本地文件由垫片管理' : fileOpsBackendLabel();
  if (fileOpsStandalone() || fileOpsBackendKind() !== FILEOPS_BACKEND_DIR) return;
  if (typeof document === 'undefined' || !document || typeof document.createElement !== 'function') return;
  var back = document.createElement('button');
  back.className = 'lib-backend-reset';
  back.textContent = '切回服务器 maps/';
  back.style.cssText = 'margin-left:8px;padding:1px 6px;font-size:12px';
  back.addEventListener('click', function () { guard('切回服务器库', useServerBackendFlow); });
  if (el.appendChild) el.appendChild(back);
}
// 目录后端 → 服务器库:列表/读/写一起换回来(只换列表不换写盘 = 下一次保存写到看不见的地方)。
function useServerBackendFlow() {
  setFileOpsBackend(FILEOPS_BACKEND_SERVER, null);
  refreshBackendLabel();
  status('已切回服务器 maps/ —— 库列表与保存都读写它');
  return refreshLibrary();
}

// ── 文件动作 ──
function uniqueCopyName(rows, base) {
  var has = {};
  (rows || []).forEach(function (r) { has[r.name] = true; });
  var stem = Core.sanitizeName(base) + '_copy';
  var name = stem + '.cyrm', n = 2;
  while (has[name]) { name = stem + n + '.cyrm'; n++; if (n > 999) break; }
  return name;
}

function newMapFlow() {
  var wDef = parseInt(($('size-w') || {}).value, 10) || 125;
  var hDef = parseInt(($('size-h') || {}).value, 10) || 75;
  return askForm({
    title: '新建地图', okText: '创建并写盘',
    hint: '名字只接受 [A-Za-z0-9_-];创建后立即写进当前库(' + fileOpsBackendLabel() + ')。',
    fields: [
      { name: 'name', label: '名字(不含 .cyrm)', value: 'new_map' },
      { name: 'w', label: '宽(格)', type: 'number', value: String(wDef), min: 1, max: 400 },
      { name: 'h', label: '高(格)', type: 'number', value: String(hDef), min: 1, max: 300 },
    ],
  }).then(function (ans) {
    if (!ans) return null;
    var full = normalizeMapFileName(ans.name);
    var bad = mapNameProblem(full);
    if (bad) { status('名字不能用:' + bad); return null; }
    if (isBackupName(full)) { status('不能新建叫「' + full + '」的地图(那是原文备份的名字)'); return null; }
    var w = parseInt(ans.w, 10), h = parseInt(ans.h, 10);
    if (!isFinite(w) || !isFinite(h)) { status('宽高必须是数字(实得 ' + ans.w + ' × ' + ans.h + ')'); return null; }
    return listLibraryMaps().then(function (rows) {
      var dup = (rows || []).some(function (r) { return r.name === full; });
      if (dup) { status('同名地图已存在:' + full + ' —— 换一个名字,或用「打开文件…」'); return null; }
      var map = createEmptyMap(nameFromFile(full), w, h);
      var cw = Core.cellsWOf(map), ch = Core.cellsHOf(map);
      return encodeForWrite(map).then(function (bytes) {
        return putMapBytes(full, bytes).then(function () {
          return setMapFromBytes(full, bytes, 'v4').then(function () {
            return refreshLibrary().then(function () {
              status('已新建并写盘 ' + full + '(' + cw + '×' + ch + ' 格)');
            });
          });
        });
      });
    });
  });
}

// 「打开文件…」= 读本地 .cyrm 进来;★ 不伪装成"已在库里":它还没写进任何库,Ctrl+S 才会写。
function openFileFlow() {
  return Promise.resolve(pickFile()).then(function (picked) {
    if (!picked || !picked.bytes) return null;
    var bytes = picked.bytes;
    return setMapFromBytes(picked.name, bytes, null, { dirty: true }).then(function (out) {
      return listLibraryMaps().then(function (rows) {
        var same = (rows || []).some(function (r) { return r.name === picked.name; });
        status('已读入 ' + picked.name + '(' + out.sourceFormat + ')' +
               (same ? ' —— 当前库里已有同名文件,保存会覆盖同名文件'
                     : ' —— 还没写进任何库,Ctrl+S 会写进' + fileOpsBackendLabel()));
        return out;
      });
    }).catch(function (e) {
      status('读入失败:' + msgOf(e) + '(文件可能不是 .cyrm / 已损坏)');
      return null;
    });
  });
}
function pickFileByInput() {
  var d = dialogParts();
  if (!d) return Promise.resolve(null);
  return new Promise(function (resolve) {
    var inp = d.doc.createElement('input');
    inp.type = 'file';
    inp.accept = '.cyrm,application/octet-stream';
    inp.style.display = 'none';
    d.host.appendChild(inp);
    var done = false;
    function finish(v) {
      if (done) return;
      done = true;
      if (inp.remove) inp.remove(); else if (inp.parentNode) inp.parentNode.removeChild(inp);
      resolve(v);
    }
    inp.addEventListener('change', function () {
      var f = inp.files && inp.files[0];
      if (!f) return finish(null);
      f.arrayBuffer().then(function (buf) {
        finish({ name: f.name, bytes: new Uint8Array(buf) });
      }, function () { finish(null); });
    });
    inp.click();
  });
}

function openFolderFlow() {
  if (fileOpsStandalone()) {
    status('单文件版:本地目录由垫片管理,请用左侧「本地目录…」');
    return Promise.resolve(null);
  }
  if (typeof window === 'undefined' || !window || typeof window.showDirectoryPicker !== 'function') {
    status('这个浏览器没有目录访问能力(File System Access)—— 请用「打开文件…」;保存会写到' + fileOpsBackendLabel());
    return Promise.resolve(null);
  }
  return Promise.resolve(window.showDirectoryPicker({ mode: 'readwrite' })).then(function (handle) {
    setFileOpsBackend(FILEOPS_BACKEND_DIR, handle);
    refreshBackendLabel();
    status('已切到本地目录:' + handle.name + ' —— 库列表与保存都读写这个目录');
    return refreshLibrary();
  }).catch(function (e) {
    var name = (e && e.name) ? String(e.name) : '';
    if (name === 'AbortError' || name === 'NotAllowedError') { status('已取消(库没换)'); return null; }
    status('打开目录失败:' + msgOf(e) + ' —— 可以用「打开文件…」');
    return null;
  });
}

function duplicateMapFlow() {
  if (!app.map) { status('先打开一张地图'); return Promise.resolve(null); }
  var base = app.map.name || nameFromFile(app.name) || 'map';
  return listLibraryMaps().then(function (rows) {
    var name = uniqueCopyName(rows, base);
    return encodeForWrite(app.map).then(function (bytes) {
      return putMapBytes(name, bytes).then(function () {
        return setMapFromBytes(name, bytes, 'v4').then(function () {
          return refreshLibrary().then(function () { status('已复制为 ' + name); });
        });
      });
    });
  });
}

function renameMapFlow() {
  if (!app.map || !app.name) { status('先打开一张地图'); return Promise.resolve(null); }
  var oldName = app.name;
  return askForm({
    title: '重命名 ' + oldName, okText: '改名',
    hint: '改的是磁盘上的文件名(库的身份)。目标已存在会被拒(409),不覆盖。',
    fields: [{ name: 'name', label: '新名字(不含 .cyrm)', value: nameFromFile(oldName) }],
  }).then(function (ans) {
    if (!ans) return null;
    var next = normalizeMapFileName(ans.name);
    var bad = mapNameProblem(next);
    if (bad) { status('名字不能用:' + bad); return null; }
    if (isBackupName(next)) { status('不能改成备份名的形式(' + next + ')'); return null; }
    if (next === oldName) { status('名字没变'); return null; }
    return renameMapFile(oldName, next).then(function () {
      app.name = next;
      if (app.map) app.map.name = nameFromFile(next);
      return refreshLibrary().then(function () {
        refreshStatus();
        status('已改名为 ' + next);
      });
    });
  });
}

function deleteMapFlow() {
  if (!app.map || !app.name) { status('先打开一张地图'); return Promise.resolve(null); }
  var name = app.name;
  var msg = '删除 ' + name + '?不可恢复' +
            (fileOpsBackendKind() === FILEOPS_BACKEND_DIR ? '(本地目录里的文件)' : '(maps/ 在 git 里,可用 git restore 找回)');
  var ok = (typeof window !== 'undefined' && typeof window.confirm === 'function') ? window.confirm(msg) : false;
  if (!ok) { status('已取消删除'); return Promise.resolve(null); }
  return deleteMapFile(name).then(function () {
    return closeMap().then(function () {
      return refreshLibrary().then(function () { status('已删除 ' + name); });
    });
  });
}

function saveAsFlow() {
  if (!app.map) { status('先打开一张地图'); return Promise.resolve(null); }
  return askForm({
    title: '另存为', okText: '保存',
    fields: [{ name: 'name', label: '新名字(不含 .cyrm)',
               value: nameFromFile(app.name || app.map.name || 'map') }],
  }).then(function (ans) {
    if (!ans) return null;
    var next = normalizeMapFileName(ans.name);
    var bad = mapNameProblem(next);
    if (bad) { status('名字不能用:' + bad); return null; }
    return saveCurrent(true, next);
  });
}

function exportDownloadFlow() {
  if (!app.map) { status('先打开一张地图'); return Promise.resolve(null); }
  var name = normalizeMapFileName(app.name || app.map.name || 'map');
  return encodeForWrite(app.map).then(function (bytes) {
    if (typeof document === 'undefined' || !document || typeof URL === 'undefined' || !URL.createObjectURL) {
      status('当前环境不能下载(已编码 ' + bytes.length + ' 字节)');
      return null;
    }
    var a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([bytes], { type: 'application/octet-stream' }));
    a.download = name;
    (document.body || document.documentElement).appendChild(a);
    a.click();
    if (a.remove) a.remove();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 0);
    status('已导出下载 ' + name + '(' + bytes.length + ' 字节;没有写磁盘)');
    return { name: name, size: bytes.length };
  });
}

// 校验:只报告,不阻止保存(规格 §4.7)。★ 真的跑一遍 encodeForWrite —— 只过 validateMap 证明不了"能编码"。
function checkMapFlow() {
  if (!app.map) { status('先打开一张地图'); return Promise.resolve(null); }
  var rep = Core.validateMap(app.map);
  var lines = validateLines(rep);
  if (!lines.length) lines = ['校验通过:没有发现问题'];
  var ok = rep.errors.length === 0;
  var np = mapNameProblem(app.name || '');
  lines.push(np ? ('✖ 文件名不能用:' + np) : ('文件名:' + app.name + ' ✓'));
  if (np) ok = false;
  return encodeForWrite(app.map).then(function (bytes) {
    lines.push('编码通过:' + bytes.length + ' 字节' +
               (bytes[0] === 0x43 && bytes[1] === 0x59 ? '(CYRM v' + bytes[4] + ')' : '(魔数异常!)'));
    return { lines: lines, ok: ok };
  }, function (e) {
    lines.push('✖ 编码失败(保存/导出会被拒):' + msgOf(e));
    return { lines: lines, ok: false };
  }).then(function (out) {
    out.lines.push('尺寸 ' + Core.cellsWOf(app.map) + '×' + Core.cellsHOf(app.map) + ' 格 · 出生点 ' +
                   app.map.players.length + ' · 敌人 ' + app.map.enemies.length +
                   ' · 库 ' + fileOpsBackendLabel());
    showReport('校验 ' + (app.name || '(没名字)'), out.lines, out.ok);
    status(out.ok ? '校验:没有 error' : '校验:有 error(保存/导出会被拒)');
    return out;
  });
}

// ── 绑定 ──
// ★ 每个元素只绑一次(buildPanels 在测试里会被跑多遍;真 DOM 上重复绑 = 一次点击发两遍请求)。
function fileOpsBind(id, label, fn) {
  var el = $(id);
  if (!el || typeof el.addEventListener !== 'function') return null;
  if (el.__fileOpsBound) return el;
  el.__fileOpsBound = true;
  el.addEventListener('click', function () { guard(label, fn); });
  return el;
}
function installFileOps() {
  fileOpsBind('btn-new', '新建地图', newMapFlow);
  fileOpsBind('btn-open-folder', '打开文件夹', openFolderFlow);
  fileOpsBind('btn-open-file', '打开文件', openFileFlow);
  fileOpsBind('btn-save', '保存', function () { return saveCurrent(false); });
  fileOpsBind('btn-save-as', '另存为', saveAsFlow);
  fileOpsBind('btn-export', '导出', exportDownloadFlow);
  fileOpsBind('btn-check', '校验', checkMapFlow);
  fileOpsBind('btn-dup', '复制地图', duplicateMapFlow);
  fileOpsBind('btn-rename', '重命名', renameMapFlow);
  fileOpsBind('btn-del', '删除地图', deleteMapFlow);
  refreshBackendLabel();
  if (app.map) hideEmptyHint();
  return true;
}
