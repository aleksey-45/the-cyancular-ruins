'use strict';
// 相位 ⑯ 系列的替身:window.addEventListener(抓处理器)/ 按 id 惰性建的假 DOM /
// 记账的渲染器 / 记账的 fetch,备好 keydown·keyup·blur·pointerdown 的驱动器。
// ★ 缓存单例 —— ⑯ 的两个分片共用同一份替身(等价于原单文件里那个大括号块);
//   后一片(72_wiring_compress_pan)调 restoreStubs16() 收尾。
// ★ 名字带 16 后缀:分片是各自独立的 CJS 模块,相位体里裸名引用它们 ⇒ 必须挂在全局上。
const Core = globalThis.Core;
const Editor = globalThis.Editor;

let installed = false;
let saved = null;

function install() {
  installed = true;
  saved = { add: globalThis.addEventListener, doc: globalThis.document,
            r: Editor.app.r, map: Editor.app.map, canvas: Editor.app.canvas,
            name: Editor.app.name, st: Editor.app.st, tileDefs: Editor.app.tileDefs,
            fmt: Editor.app.sourceFormat, raw: Editor.app.raw,
            ls: globalThis.localStorage, timer: globalThis.setTimeout,
            fetch: globalThis.fetch, confirm: globalThis.confirm };
  const realTimer16 = globalThis.setTimeout;
  const handlers16 = {}, errs16 = [], calls16 = [];
  const els16 = {}, made16 = [];
  // ★ `#palette` 的派生提示行走 `box.parentNode.insertBefore(...)` ⇒ 每个假元素都要有一个
  //   **能 insertBefore 的**父节点,否则建面板那一步当场抛。
  const root16 = { parentNode: null, className: '', style: {}, classList: null,
                   insertBefore: function () {}, appendChild: function () {} };
  function mkEl16(id) {
    const el = {
      id: id, textContent: '', value: '', checked: false, hidden: false, className: '',
      style: {}, dataset: {}, children: [], _h: {},
      parentNode: root16, nextSibling: null,
      classList: { add: function () {}, remove: function () {}, toggle: function () {},
                   contains: function () { return false; } },
      addEventListener: function (t, fn) { (el._h[t] = el._h[t] || []).push(fn); },
      appendChild: function (c) { el.children.push(c); return c; },
      insertBefore: function (c) { el.children.push(c); return c; },
      removeChild: function () {}, querySelector: function () { return mkEl16(null); },
      click: function () {
        (el._h.click || []).forEach(function (fn) { fn({ stopPropagation: function () {}, target: el }); });
      },
    };
    return el;
  }
  const statusEl16 = mkEl16('status-msg');
  globalThis.status16 = '';
  Object.defineProperty(statusEl16, 'textContent',
    { set: function (v) { globalThis.status16 = String(v); }, get: function () { return globalThis.status16; } });
  function el16(id) {
    if (els16[id]) return els16[id];
    for (let i = 0; i < made16.length; i++) if (made16[i].id === id) return (els16[id] = made16[i]);
    return (els16[id] = mkEl16(id));
  }
  const layerRows16 = [1, 2, 3, 4].map(function (L) {
    const r = mkEl16(null); r.dataset = { layer: String(L) }; return r;
  });
  const toolBtns16 = Editor.TOOLS.map(function (t) {
    const b = mkEl16(null); b.dataset = { tool: t }; return b;
  });
  const gradBtn16 = mkEl16(null);
  const dom16 = {
    getElementById: function (id) { return id === 'status-msg' ? statusEl16 : el16(id); },
    querySelectorAll: function (sel) {
      if (sel === '#layers .layer-row') return layerRows16;
      if (sel === '#toolbar .tool') return toolBtns16;
      return [];
    },
    querySelector: function (sel) {
      return String(sel).indexOf('gradient') >= 0 ? gradBtn16 : null;
    },
    createElement: function () { const e = mkEl16(null); made16.push(e); return e; },
  };
  // ★ 记两个账:渲染入口("走的是哪条路")与"平移被叫过没有"
  Editor.app.canvas = {
    width: 80, height: 80,
    setPointerCapture: function () {},
    getBoundingClientRect: function () { return { left: 0, top: 0 }; },
    addEventListener: function (t, fn) { this['on' + t] = fn; },
  };
  globalThis.sel16 = null;
  Editor.app.r = {
    view: function () { return { x: 0, y: 0, zoom: 1 }; },
    layer: function () { return Core.LAYER_SCENE; },
    selection: function () { return globalThis.sel16; },
    setSelection: function (s) { globalThis.sel16 = s ? { x: s.x, y: s.y, w: s.w, h: s.h } : null; },
    setSelDrag: function () {}, setPreview: function () {}, setLayer: function () {},
    setGrid: function () {}, setSubGrid: function () {}, setTorus: function () {},
    setDimOthers: function () {}, setZoomAt: function () { return Promise.resolve(); },
    setMap: function () { return Promise.resolve(); },
    screenToSub: function () { return { X: 0, Y: 0 }; },
    editCells: function () { calls16.push('editCells'); },
    render: function () { calls16.push('render'); },
    invalidateAll: function () { calls16.push('invalidateAll'); return Promise.resolve(); },
    panBy: function () { calls16.push('panBy'); return Promise.resolve(); },
  };
  globalThis.addEventListener = function (t, fn) { handlers16[t] = fn; };
  globalThis.document = dom16;
  Editor.app.tileDefs = globalThis.TILE_DEFS;
  // ★ 报错通道:记下来(处理器全在 guard 里跑,替身少一个方法就会变成一条被吞掉的异常,
  //   最后那条"一条错都没进过 sink"就是防这个的)。
  Editor.setErrorSink(function (t) { errs16.push(String(t)); });

  const press16 = function (k, target, extra) {
    const ev = { key: k, target: target, ctrl: false, meta: false, shift: false, altKey: false,
                 button: 0, clientX: 0, clientY: 0, pointerId: 1 };
    if (extra) Object.keys(extra).forEach(function (kk) { ev[kk] = extra[kk]; });
    ev.defaultPrevented = false;
    ev.preventDefault = function () { ev.defaultPrevented = true; };
    handlers16.keydown(ev);
    return ev;
  };
  const release16 = function (k, target) {
    const ev = { key: k, target: target, ctrl: false, meta: false, shift: false, altKey: false };
    ev.defaultPrevented = false;
    ev.preventDefault = function () { ev.defaultPrevented = true; };
    handlers16.keyup(ev);
    return ev;
  };
  // 把撤销栈清空。★ 判据必须是 `=== null`(历史空了的**唯一**信号):cells / spawn 类条目
  //   交回的是 `undefined`(falsy)—— 拿真假值当循环条件会在第一条 spawn 条目上**提前退出**,
  //   于是"历史已空"那条前置断言是假的(后面"没进历史"那几条就都成了假绿)。
  const drain16 = async function () {
    let n = 0;
    while (true) {
      const r = Editor.doUndo();
      if (r === null) break;
      await r;
      if (++n > 400) break;
    }
  };
  Object.assign(globalThis, { realTimer16: realTimer16, handlers16: handlers16, errs16: errs16,
    calls16: calls16, els16: els16, made16: made16, root16: root16, mkEl16: mkEl16, el16: el16,
    statusEl16: statusEl16, layerRows16: layerRows16, toolBtns16: toolBtns16, gradBtn16: gradBtn16,
    dom16: dom16, press16: press16, release16: release16, drain16: drain16 });
}

function restore() {
  if (!installed) return;
  installed = false;
  Editor.setErrorSink(null);
  globalThis.addEventListener = saved.add;
  globalThis.document = saved.doc;
  globalThis.localStorage = saved.ls;
  globalThis.setTimeout = saved.timer;
  globalThis.fetch = saved.fetch;
  globalThis.confirm = saved.confirm;
  Editor.app.r = saved.r; Editor.app.map = saved.map; Editor.app.canvas = saved.canvas;
  Editor.app.name = saved.name; Editor.app.st = saved.st; Editor.app.tileDefs = saved.tileDefs;
  Editor.app.sourceFormat = saved.fmt; Editor.app.raw = saved.raw;
  if (saved.ls === undefined) { try { delete globalThis.localStorage; } catch (e) {} }
}

module.exports = {
  getStubs16: function () { if (!installed) install(); return module.exports; },
  restoreStubs16: restore,
};
