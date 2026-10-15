// ui/90_open.js —— 打开地图、库列表、写回服务端。

function openMap(name) {
  status('打开 ' + name + ' …');
  return fetch('/api/map?p=' + encodeURIComponent(name))
    .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); })
    .then(function (buf) {
      var bytes = new Uint8Array(buf);
      return mapFromBytes(name, bytes).then(function (out) {
        return { out: out, bytes: bytes };
      });
    })
    .then(function (got) {
      var out = got.out;
      // ★★★ app.raw 只能在这里认领(此刻解码已经成功):写在上一步("拿到字节"就写)的话,一次失败的打开
      //    会把那个失败文件的字节留在 app.raw 里,而 app.map / app.name / app.sourceFormat 仍是上一张图的 ⇒
      //    ① saveCurrent 的原文备份取的就是 app.raw(A.v3.bak 里装的是 B 的字节);② offerDraft 的 sameBytes
      //    拿草稿与另一个文件比字节,那道闸等于不存在。两个读者当场就错,而两处都不报错。
      app.raw = got.bytes;
      app.map = out.map; app.name = name; app.sourceFormat = out.sourceFormat;
      dirty = false;                 // ★★ 打开 = 屏幕上这份与磁盘上那份同源(见 dirty 那段)
      // ★★ 另两笔账也要一起归位:draftSavedRev 推到当前 rev(否则上一张图留下的防抖定时器会给这张一笔都没画过的图写出一条脏草稿),lastAutoSaveAt 归零。
      draftSavedRev = draftRev;
      lastAutoSaveAt = 0;
      return Promise.resolve(app.r.setMap(app.map)).then(function () {
        refreshStatus();
        status('已打开 ' + name + '(' + out.sourceFormat + ')');
      });
    });
}

// ★★ PUT 必须显式带 Content-Type: application/json(页面上唯一会改磁盘的那个调用):服务器的写端点
//    只收这一个类型,别的类型一律 415 —— 不写 headers 时浏览器按 body 的类型推,new Blob([bytes]) 推出来的是 application/octet-stream。
function putMapBytes(name, bytes) {
  return fetch('/api/map?p=' + encodeURIComponent(name), {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: new Blob([bytes]),
  }).then(function (r) {
    if (!r.ok) throw new Error('HTTP ' + r.status + (r.status === 415 ? '(内容类型不对)' : ''));
    return r.json();
  });
}

function refreshStatus() {
  var m = app.map;
  if (!m) return;
  var set = function (id, txt) { var el = $(id); if (el) el.textContent = txt; };
  set('st-name', (m.name || '(无名)') + (app.name ? ' · ' + app.name : ''));
  set('st-size', Core.cellsWOf(m) + '×' + Core.cellsHOf(m) + ' 格');
  // ★★ 尺寸面板的两个框也要跟着走(DOM 必须与状态一致):refreshStatus 是打开/新建/复制/改尺寸/草稿恢复
  //    这几条换图路的公共收口,漏一处就是"框里写着上一张图的尺寸,一按应用尺寸把当前这张改了"。
  sizeInputsSync();
  var rep = Core.validateMap(m);
  set('st-valid', rep.errors.length ? ('error ' + rep.errors.length)
                                    : (rep.warnings.length ? ('⚠ ' + rep.warnings.length) : '校验 OK'));
  renderSaveState();                // ★ 打开/新建/复制/改名/保存后都要跟着翻
}

function refreshLibrary() {
  return fetch('/api/maps').then(function (r) {
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return r.json();
  }).then(function (data) {
    var ul = $('lib-list');
    if (!ul) return;
    ul.innerHTML = '';
    // ★★ 原文备份不进库列表:openFromUrl 的兜底是"打开列表第一行",列表里混进备份之后开机就可能直接
    //    打开一份退路;★ 但只过滤显示这一侧 —— ?p= 直接打开那条路它管不到,故 saveCurrent 那道闸不可省。
    var rows = (data.maps || []).filter(function (mm) { return !isBackupName(mm.name); });
    if (!rows.length) { ul.textContent = 'maps/ 下没有 .cyrm'; return; }
    rows.forEach(function (mm) {
      var li = document.createElement('li');
      li.className = 'lib-row';
      li.dataset.name = mm.name;
      li.textContent = mm.name + '  ' + Math.round(mm.size / 1024) + 'KB';
      li.title = new Date(mm.mtime).toLocaleString();
      ul.appendChild(li);
    });
  });
}

function openFromUrl() {
  var p = new URLSearchParams(location.search).get('p');
  if (p) return openMap(p);
  return refreshLibrary().then(function () {
    var first = document.querySelector('#lib-list .lib-row');
    return first ? openMap(first.dataset.name) : null;
  });
}
