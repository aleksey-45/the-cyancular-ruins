'use strict';
// 相位 ⑭ 系列的替身:按 id 惰性建的假 DOM / 记账的渲染器 / 记账的 fetch / 假 Image。
// ★ 缓存单例 —— ⑭ 的子相位共用同一份替身与同一本账(等价于原单文件里那个大括号块);
//   最后一个子相位(54_save_backup_boot)调 restoreStubs14() 收尾。
// ★ 名字带 14 后缀:分片是各自独立的 CJS 模块,相位体里裸名引用它们 ⇒ 必须挂在全局上。
const Core = globalThis.Core;
const Editor = globalThis.Editor;

let installed = false;
let saved = null;

function install() {
  installed = true;
  saved = { doc: globalThis.document, r: Editor.app.r, map: Editor.app.map,
            canvas: Editor.app.canvas, name: Editor.app.name,
            image: globalThis.Image, loc: globalThis.location, fetch: globalThis.fetch };

  const els = {}, made = [];
  function mkRow14() {                                  // 一个"看起来像 .desc-row"的假行
    return { className: 'desc-row', style: {}, parentNode: null, textContent: '',
             classList: { contains: function (c) { return c === 'desc-row'; },
                          add: function () {}, remove: function () {}, toggle: function () {} } };
  }
  const root14 = { parentNode: null, className: '', style: {}, classList: null,
                   insertBefore: function () {}, appendChild: function () {} };
  function mkEl14(id) {
    const el = {
      id: id, textContent: '', value: '', checked: false, hidden: false, className: '',
      style: {}, dataset: {}, children: [], _h: {},
      parentNode: root14, nextSibling: null,
      classList: { add: function () {}, remove: function () {}, toggle: function () {},
                   contains: function () { return false; } },
      addEventListener: function (type, fn) { el._h[type] = fn; },
      appendChild: function (c) { el.children.push(c); return c; },
      insertBefore: function (c) { el.children.push(c); return c; },
      removeChild: function () {}, querySelector: function () { return mkEl14(null); },
      click: function () { if (el._h.click) el._h.click({ stopPropagation: function () {}, target: el }); },
    };
    return el;
  }
  // ★ `createElement` 造出来的元素也进册:真 DOM 里 getElementById 找得到的正是它们
  //   (buildPanels 给派生提示行设的 id 就是这么被 syncPanelForLayer 看见的)。
  function elOf14(id) {
    if (els[id]) return els[id];
    for (let i = 0; i < made.length; i++) if (made[i].id === id) return (els[id] = made[i]);
    return (els[id] = mkEl14(id));
  }
  // ★ `#status-msg` 单独一件:**它的文本要能被读**(refusal 的"理由"那句话就是它),
  //   故不走惰性建那一套,而是绑到全局的 status14 上。
  const statusEl14 = { id: 'status-msg', style: {}, dataset: {}, children: [],
                       addEventListener: function () {}, appendChild: function () {},
                       classList: { add: function () {}, remove: function () {}, toggle: function () {},
                                    contains: function () { return false; } } };
  globalThis.status14 = '';
  Object.defineProperty(statusEl14, 'textContent',
    { set: function (v) { globalThis.status14 = String(v); }, get: function () { return globalThis.status14; } });
  const layerRows14 = [1, 2, 3, 4].map(function (L) {
    const r = mkEl14(null); r.dataset = { layer: String(L) }; return r;
  });
  const toolBtns14 = Editor.TOOLS.map(function (t) { const b = mkEl14(null); b.dataset = { tool: t }; return b; });
  const gradBtn14 = mkEl14(null);
  const dom14 = {
    // ★ 文件动作的页内对话框要挂 body(`fileOpsAsk` 注入之外的那条真路);替身给一个可挂的宿主。
    body: { appendChild: function () {}, removeChild: function () {} },
    documentElement: { appendChild: function () {} },
    getElementById: function (id) { return id === 'status-msg' ? statusEl14 : elOf14(id); },
    querySelectorAll: function (sel) {
      if (sel === '#layers .layer-row') return layerRows14;
      if (sel === '#tools .tool' || sel === '#toolbar .tool' || sel === '.tool') return toolBtns14;
      return [];
    },
    querySelector: function (sel) {
      return String(sel).indexOf('gradient') >= 0 ? gradBtn14 : null;
    },
    createElement: function (tag) {
      if (tag === 'canvas') {                          // loadAtlas 要一块能读像素的画布
        return { width: 0, height: 0, getContext: function () {
          return { drawImage: function () {},
                   getImageData: function (x, y, w, h) { return { data: new Uint8ClampedArray(w * h * 4) }; } };
        }, toDataURL: function () { return 'data:image/png;base64,'; } };
      }
      const e = mkEl14(null); made.push(e); return e;
    },
  };
  // ★ 图集替身:512×640(16×20 块,与真 structure.png 同形状),onload 立刻回调。
  globalThis.Image = function () {
    const img = this;
    img.width = 512; img.height = 640; img.onload = null; img.onerror = null;
    Object.defineProperty(img, 'src', {
      get: function () { return 'structure.png'; },
      set: function () { if (img.onload) img.onload(); },
    });
  };
  // ★ 记账的 fetch 替身(**只**在内存里演;测试不许往真 maps/ 写):PUT / DELETE / POST rename 三个写端点
  //   都能切成功/失败,失败时带 `text()`(客户端必须把服务端那句人话带出来);库列表与读字节也在替身里摆。
  globalThis.putLog14 = [];
  globalThis.deleteLog14 = [];
  globalThis.renameLog14 = [];
  globalThis.putMode14 = 'ok';
  globalThis.deleteMode14 = 'ok';        // 'ok' | 数字(404/409/500…)
  globalThis.renameMode14 = 'ok';
  globalThis.libRows14 = [];             // GET /api/maps 的内容(测试自己摆)
  globalThis.mapGetMode14 = 'ok';
  globalThis.mapBytes14 = {};            // name → Uint8Array(GET /api/map?p=)
  function errResponse14(status, text) {
    return { ok: false, status: status, text: function () { return Promise.resolve(String(text)); } };
  }
  function queryName14(u, key) {
    const m = new RegExp('[?&]' + key + '=([^&]*)').exec(u);
    return m ? decodeURIComponent(m[1]) : '';
  }
  globalThis.fetch14 = function (url, init) {
    const u = String(url);
    const method = (init && init.method) || 'GET';
    if (u.indexOf('/api/map/rename') === 0) {
      const from = queryName14(u, 'from'), to = queryName14(u, 'to');
      globalThis.renameLog14.push({ url: u, from: from, to: to, init: init });
      if (globalThis.renameMode14 !== 'ok') {
        return Promise.resolve(globalThis.renameMode14 === '409'
          ? errResponse14(409, '目标已存在,拒绝覆盖:' + to)
          : errResponse14(Number(globalThis.renameMode14) || 500, '改名失败'));
      }
      globalThis.libRows14 = globalThis.libRows14.map(function (r) {
        return r.name === from ? { name: to, size: r.size, mtime: r.mtime } : r;
      });
      return Promise.resolve({ ok: true, status: 200,
        json: function () { return Promise.resolve({ ok: true, name: to }); } });
    }
    if (method === 'PUT') {
      globalThis.putLog14.push({ url: u, init: init });
      if (globalThis.putMode14 !== 'ok') return Promise.resolve(errResponse14(500, '磁盘写满'));
      const name = queryName14(u, 'p');
      return Promise.resolve({ ok: true, status: 200,
        json: function () { return Promise.resolve({ name: name, size: 42 }); } });
    }
    if (method === 'DELETE') {
      const name = queryName14(u, 'p');
      globalThis.deleteLog14.push({ url: u, name: name, init: init });
      if (globalThis.deleteMode14 !== 'ok') {
        return Promise.resolve(errResponse14(Number(globalThis.deleteMode14) || 500, '删不掉'));
      }
      globalThis.libRows14 = globalThis.libRows14.filter(function (r) { return r.name !== name; });
      return Promise.resolve({ ok: true, status: 200,
        json: function () { return Promise.resolve({ ok: true, deleted: name }); } });
    }
    if (u.indexOf('/api/maps') === 0) {
      return Promise.resolve({ ok: true, status: 200,
        json: function () { return Promise.resolve({ maps: globalThis.libRows14.slice() }); } });
    }
    if (globalThis.mapGetMode14 !== 'ok') return Promise.resolve(errResponse14(404, '找不到地图'));
    const name = queryName14(u, 'p');
    const body = globalThis.mapBytes14[name];
    if (!body) return Promise.resolve(errResponse14(404, '找不到地图 ' + name));
    return Promise.resolve({ ok: true, status: 200, arrayBuffer: function () {
      return Promise.resolve(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
    } });
  };
  globalThis.view14 = { x: 0, y: 0, zoom: 1 };

  globalThis.document = dom14;
  globalThis.location = { search: '?p=stale_name.cyrm' };
  globalThis.fetch = globalThis.fetch14;
  Editor.app.canvas = { width: 80, height: 80 };
  const calls14 = [];
  Editor.app.r = {
    view: function () { return globalThis.view14; },
    layer: function () { return Core.LAYER_SCENE; },
    selection: function () { return null; },
    setSelection: function () {}, setSelDrag: function () {}, setPreview: function () {},
    setMap: function () { calls14.push('setMap'); return Promise.resolve(); },
    setLayer: function () {}, setGrid: function () {}, setSubGrid: function () {},
    setTorus: function () {}, setDimOthers: function () {},
    layerVisible: function () { return true; }, layerLocked: function () { return false; },
    editCells: function () { calls14.push('editCells'); },
    render: function () { calls14.push('render'); },
    invalidateAll: function () { calls14.push('invalidateAll'); return Promise.resolve(); },
  };
  Editor.app.map = Editor.createEmptyMap('t', 8, 8);     // 32×32 子格
  Editor.app.name = null;

  Object.assign(globalThis, { mkRow14: mkRow14, root14: root14, mkEl14: mkEl14, elOf14: elOf14,
    statusEl14: statusEl14, layerRows14: layerRows14, toolBtns14: toolBtns14, gradBtn14: gradBtn14,
    dom14: dom14, els14: els });
}

function restore() {
  if (!installed) return;
  installed = false;
  globalThis.document = saved.doc;
  Editor.app.r = saved.r; Editor.app.map = saved.map;
  Editor.app.canvas = saved.canvas; Editor.app.name = saved.name;
  globalThis.Image = saved.image; globalThis.location = saved.loc;
  globalThis.fetch = saved.fetch;
  // ★★ 历史与敌人注册表也要还:⑭a 的 spawnAt 走的是**真** pushAndShow —— 它们真的进了
  //    ⑬ 装出来的那本**真**历史。还法就是**再装一遍** installInteraction():它建的正是
  //    生产初始状态(历史清空 + `app.st` 回初值)。它只碰 `app.canvas` 与 `window`。
  const savedAdd = globalThis.addEventListener, savedCv = Editor.app.canvas;
  globalThis.addEventListener = function () {};
  Editor.app.canvas = { addEventListener: function () {} };
  Editor.installInteraction();
  globalThis.addEventListener = savedAdd; Editor.app.canvas = savedCv;
  delete globalThis.ENEMY_REGISTRY;
}

module.exports = {
  getStubs14: function () { if (!installed) install(); return module.exports; },
  restoreStubs14: restore,
};
