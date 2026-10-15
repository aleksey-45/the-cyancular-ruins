// ui/10_util.js —— DOM/时间/错误通道等基础设施。

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

// ★ 错误可见性:面板与渲染里抛的异常必须当场说人话 —— 症状"按了没反应"最难查,静默捕获更糟。
// ★★ 这条通道要同时接两件事:guard 的同步 try/catch,以及视图入口(resize/fit/setMap/panBy/…)
//    返回的分帧 promise 的拒绝 —— 抛在任务回调里同步 try/catch 接不住,画布默默停在上一帧。
// ★ 默认 sink 写状态栏;有自定义 sink 时不再 console.error —— 否则 stderr 恒有字节,
//    "stderr 有字节 = 有东西红了"这个信号就废了。
var errorSinkFn = null;
function setErrorSink(fn) { errorSinkFn = (typeof fn === 'function') ? fn : null; }
function reportError(text, err) {
  var custom = errorSinkFn;
  try {
    if (custom) custom(String(text), err);
    else status(text);
  } catch (e) {
    if (typeof console !== 'undefined') console.error(text, e);
  }
  if (!custom && typeof console !== 'undefined') console.error(text, err);
}

function guard(label, fn) {
  var out;
  try { out = fn(); }
  catch (e) { reportError('出错了(' + label + '):' + msgOf(e), e); return null; }
  if (out && typeof out.then === 'function') {
    return out.then(null, function (e) {
      reportError('出错了(' + label + '):' + msgOf(e), e);
    });
  }
  return out;
}

// ★★ 库的身份就是文件名,而 v4 的 body 里没有 name 字段(decodeMap 返回 name:'')
//    ⇒ 导入方必须自己用文件名补 map.name,否则 sanitizeName 会把它回落成 'structure'。
function nameFromFile(fileName) {
  return String(fileName == null ? '' : fileName).replace(/\.cyrm$/i, '');
}
// ★ 格式判据只此一处:先嗅 v4 的 magic(4 字节),否则交给 Core.isV3Text 分 v3 / 旧字母格式。
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
      map.name = nameFromFile(fileName);          // ★★ 见 nameFromFile
      return { map: map, sourceFormat: 'v4' };
    });
  }
  var text = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
  var map = Core.migrateV3(Core.parseV3Text(text));
  map.name = nameFromFile(fileName);
  return Promise.resolve({ map: map, sourceFormat: fmt });
}
