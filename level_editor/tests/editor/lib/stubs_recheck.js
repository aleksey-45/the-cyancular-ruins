'use strict';
// 相位 ⑰ 系列的替身:记账的假 DOM(按 id 惰性建)/ 记账的 fetch / 记账的渲染器 /
// 会记账的 confirm(默认答"不要")/ 记下的库列表与三份字节。
// ★ 缓存单例 —— ⑰ 的两个分片共用同一份替身;后一片(82_recheck_lib_space)调
//   restoreStubs17() 收尾。
// ★ 名字带 17 后缀:分片是各自独立的 CJS 模块,相位体里裸名引用它们 ⇒ 必须挂在全局上。
const Core = globalThis.Core;
const Editor = globalThis.Editor;

let installed = false;
let saved = null;

function install() {
  installed = true;
  saved = { add: globalThis.addEventListener, doc: globalThis.document,
            r: Editor.app.r, map: Editor.app.map, canvas: Editor.app.canvas,
            name: Editor.app.name, st: Editor.app.st, tileDefs: Editor.app.tileDefs,
            fmt: Editor.app.sourceFormat, raw: Editor.app.raw, db: Editor.app.db,
            confirm: globalThis.confirm, fetch: globalThis.fetch,
            loc: globalThis.location, timer: globalThis.setTimeout };
  const realTimer17 = globalThis.setTimeout;
  const els17 = {}, handlers17 = {}, errs17 = [], calls17 = [], puts17 = [];
  const root17 = { parentNode: null, className: '', style: {}, classList: null,
                   insertBefore: function () {}, appendChild: function () {} };
  function mkEl17(id) {
    const el = {
      id: id, textContent: '', value: '', checked: false, hidden: false, className: '',
      style: {}, dataset: {}, children: [], _h: {},
      parentNode: root17, nextSibling: null,
      classList: { add: function () {}, remove: function () {}, toggle: function () {},
                   contains: function () { return false; } },
      addEventListener: function (t, fn) { el._h[t] = fn; },
      appendChild: function (c) { el.children.push(c); return c; },
      insertBefore: function (c) { el.children.push(c); return c; },
      removeChild: function () {}, querySelector: function () { return mkEl17(null); },
      click: function () {
        (el._h.click ? [el._h.click] : []).forEach(function (fn) {
          fn({ stopPropagation: function () {}, target: el });
        });
      },
    };
    return el;
  }
  const statusEl17 = mkEl17('status-msg');
  globalThis.status17 = '';
  Object.defineProperty(statusEl17, 'textContent',
    { set: function (v) { globalThis.status17 = String(v); }, get: function () { return globalThis.status17; } });
  function el17(id) {
    if (els17[id]) return els17[id];
    return (els17[id] = mkEl17(id));
  }
  const dom17 = {
    getElementById: function (id) { return id === 'status-msg' ? statusEl17 : el17(id); },
    querySelectorAll: function () { return []; },
    // ★ 只有这一条查询要真给东西:`openFromUrl` 的兜底是"打开列表**第一行**" ——
    //   那是"库里混进一行备份 ⇒ 开机就打开一份退路"唯一的可见面。
    querySelector: function (sel) {
      if (String(sel) === '#lib-list .lib-row') {
        return el17('lib-list').children.length ? el17('lib-list').children[0] : null;
      }
      return null;
    },
    createElement: function () { return mkEl17(null); },
  };
  globalThis.sel17 = null;
  globalThis.asked17 = 0;
  const libRows17 = [{ name: 'A.cyrm', size: 100, mtime: 1 },
                     { name: 'A_e3c115d7.v3.bak', size: 90, mtime: 2 },
                     { name: 'B_0123456789abcde.v3.bak', size: 80, mtime: 3 },
                     { name: 'C.cyrm', size: 70, mtime: 4 }];
  const A_TEXT17 = '# cyrm-v3\n001f001f001f\n001f001f001f\n';
  const aBytes17 = new TextEncoder().encode(A_TEXT17);
  // ★ B:magic 是 "CYRM"(所以 `detectFormat` 判成 v4)、但长度不足 ⇒ `Core.decodeMap`
  //   当场拒(服务器上那种被截断/写坏的 `.cyrm` 就是这样)。
  const bBytes17 = new Uint8Array([0x43, 0x59, 0x52, 0x4D, 4, 0]);
  const bodies17 = { 'A.cyrm': aBytes17, 'B.cyrm': bBytes17 };
  const draftRec17 = { key: 'A', name: 'A.cyrm', name2: 'A', bytes: aBytes17,
                       sourceFormat: 'v3', savedAt: 1, dirty: true };
  globalThis.addEventListener = function (t, fn) { handlers17[t] = fn; };
  globalThis.document = dom17;
  // ★ `openFromUrl` 读 `location.search`;而 **node 里根本没有 location**(⑭ 的替身也是
  //   自己补的)。空 search = 走"打开列表第一行"那条兜底。
  globalThis.location = { search: '' };
  globalThis.confirm = function () { globalThis.asked17++; return false; };
  globalThis.fetch = function (url, init) {
    const u = String(url);
    if (init && init.method === 'PUT') {
      puts17.push({ url: u, init: init });
      return Promise.resolve({ ok: true, status: 200,
        json: function () { return Promise.resolve({ name: 'x.cyrm', size: 1 }); } });
    }
    if (u.indexOf('/api/maps') === 0) {
      return Promise.resolve({ ok: true, status: 200,
        json: function () { return Promise.resolve({ maps: libRows17 }); } });
    }
    const q = u.indexOf('/api/map?p=');
    if (q >= 0) {
      const p = decodeURIComponent(u.slice(q + '/api/map?p='.length));
      const body = bodies17[p];
      if (!body) return Promise.resolve({ ok: false, status: 404 });
      return Promise.resolve({ ok: true, status: 200, arrayBuffer: function () {
        return Promise.resolve(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
      } });
    }
    return Promise.resolve({ ok: false, status: 404 });
  };
  Editor.app.tileDefs = globalThis.TILE_DEFS;
  Editor.setErrorSink(function (t) { errs17.push(String(t)); });
  Editor.app.canvas = {
    width: 80, height: 80,
    setPointerCapture: function () {},
    getBoundingClientRect: function () { return { left: 0, top: 0 }; },
    addEventListener: function (t, fn) { this['on' + t] = fn; },
  };
  Editor.app.r = {
    view: function () { return { x: 0, y: 0, zoom: 1 }; },
    layer: function () { return Core.LAYER_SCENE; },
    selection: function () { return globalThis.sel17; },
    setSelection: function (s) { globalThis.sel17 = s ? { x: s.x, y: s.y, w: s.w, h: s.h } : null; },
    setSelDrag: function () {}, setPreview: function () {}, setLayer: function () {},
    setGrid: function () {}, setSubGrid: function () {}, setTorus: function () {},
    setDimOthers: function () {}, setZoomAt: function () { return Promise.resolve(); },
    setMap: function () { calls17.push('setMap'); return Promise.resolve(); },
    screenToSub: function () { return { X: 0, Y: 0 }; },
    editCells: function () { calls17.push('editCells'); },
    render: function () { calls17.push('render'); },
    invalidateAll: function () { calls17.push('invalidateAll'); return Promise.resolve(); },
    panBy: function () { calls17.push('panBy'); return Promise.resolve(); },
    stats: function () { return { thumbsBuilt: 0 }; },
  };
  Object.assign(globalThis, { realTimer17: realTimer17, els17: els17, mkEl17: mkEl17,
    statusEl17: statusEl17, el17: el17, dom17: dom17, root17: root17, handlers17: handlers17,
    errs17: errs17, calls17: calls17, puts17: puts17, libRows17: libRows17,
    aBytes17: aBytes17, bBytes17: bBytes17, bodies17: bodies17, draftRec17: draftRec17,
    saved17: saved });
}

function restore() {
  if (!installed) return;
  installed = false;
  Editor.setErrorSink(null);
  globalThis.addEventListener = saved.add;
  globalThis.document = saved.doc;
  globalThis.confirm = saved.confirm;
  globalThis.fetch = saved.fetch;
  if (saved.loc === undefined) { try { delete globalThis.location; } catch (e) {} }
  else globalThis.location = saved.loc;
  Editor.app.r = saved.r; Editor.app.map = saved.map; Editor.app.canvas = saved.canvas;
  Editor.app.name = saved.name; Editor.app.st = saved.st; Editor.app.tileDefs = saved.tileDefs;
  Editor.app.sourceFormat = saved.fmt; Editor.app.raw = saved.raw; Editor.app.db = saved.db;
}

module.exports = {
  getStubs17: function () { if (!installed) install(); return module.exports; },
  restoreStubs17: restore,
};
