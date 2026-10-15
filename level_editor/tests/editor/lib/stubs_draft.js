'use strict';
// 相位 ⑮b 系列的替身:假 IndexedDB(两张表 + 计价读数)/ 记账的假 setTimeout /
// 按 id 惰性建的假 DOM / 记账的渲染器。
// ★ 缓存单例 —— ⑮b 的子相位**共用同一份 tab15 与同一本账**(草稿盘的状态跨子相位流动:
//   ③ 写的那条草稿 ⑥ 要读回来)。最后一片(66_draft_crash_evict)调 restoreStubs15() 收尾。
// ★ 名字带 15 后缀:分片是各自独立的 CJS 模块,相位体里裸名引用它们 ⇒ 必须挂在全局上。
const Core = globalThis.Core;
const Editor = globalThis.Editor;

let installed = false;
let saved = null;

function install() {
  installed = true;
  const realSetTimeout15 = globalThis.setTimeout;
  saved = { doc: globalThis.document, confirm: globalThis.confirm,
            setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout,
            indexedDB: globalThis.indexedDB, fetch: globalThis.fetch,
            r: Editor.app.r, map: Editor.app.map, name: Editor.app.name,
            fmt: Editor.app.sourceFormat, db: Editor.app.db, canvas: Editor.app.canvas,
            uist: Editor.app.uist, st: Editor.app.st, raw: Editor.app.raw };

  // ── 假 IndexedDB(两张表:草稿盘、崩溃槽位)──
  const tab15 = { draft: new Map(), crash: new Map() };
  // ★ 三个开关 + 一本读数账:
  //   · `count`    —— count() 的请求失败(读不到条数);
  //   · `get`      —— **单条读**的请求失败(启动路径上"崩溃槽位读不到"那条失败面);
  //   · `deleteTx` —— 含 delete 的那个事务失败(真 IDB 出错时事务不提交 ⇒ 一条 later 都不跑);
  //   · `getAll` / `cursor` / `keys` —— 三种读各记一笔:"常态一条都不读 / 到上限只读够淘汰
  //     那几条"是**代价**不是行为,断不了对错,只能靠计数钉住。
  const fail15 = { count: false, deleteTx: false, get: false };
  const idbReads15 = { count: 0, getAll: 0, cursor: 0, keys: 0 };
  function fakeDb15() {
    function txOf(store, mode) {
      const tx = { error: null, oncomplete: null, onerror: null, onabort: null };
      const later = [];
      let hasDelete = false;
      tx.objectStore = function () {
        return {
          // ★ 写与删都**在事务提交那一刻**才落到表里(真 IndexedDB 就是这样):替身若当场改表,
          //   "记录已存在"就不再等价于"这次落盘走完了"。
          put: function (rec) { later.push(function () { tab15[store].set(rec.key, rec); }); },
          delete: function (k) {
            hasDelete = true;
            later.push(function () { tab15[store].delete(k); });
          },
          get: function (k) {
            const rq = { result: null, onsuccess: null, onerror: null };
            later.push(function () {
              if (fail15.get) { if (rq.onerror) rq.onerror({ target: rq }); return; }
              rq.result = tab15[store].get(k) || null;
              if (rq.onsuccess) rq.onsuccess({ target: rq });
            });
            return rq;
          },
          // ★ count() 只回一个数:**记录本体一个字节都不反序列化**。
          count: function () {
            idbReads15.count++;
            const rq = { result: 0, onsuccess: null, onerror: null };
            later.push(function () {
              if (fail15.count) { if (rq.onerror) rq.onerror({ target: rq }); return; }
              rq.result = tab15[store].size;
              if (rq.onsuccess) rq.onsuccess({ target: rq });
            });
            return rq;
          },
          getAll: function () {
            idbReads15.getAll++;
            const rq = { result: [], onsuccess: null, onerror: null };
            later.push(function () {
              rq.result = Array.from(tab15[store].values());
              if (rq.onsuccess) rq.onsuccess({ target: rq });
            });
            return rq;
          },
          // ★★ 索引(库版本 2 加的 `savedAt`):生产只用它做两条查询 ——「最新一条的 savedAt」
          //   (键游标,降序)与「按时间升序逐条挑淘汰对象」(值游标)。替身按**同一个语义**
          //   实现:索引是**稀疏**的(真 IDB 里 savedAt 不是数的记录根本不进索引)。
          index: function () {
            const recsIn = function (dir) {
              const list = Array.from(tab15[store].values()).filter(function (r) {
                return typeof r.savedAt === 'number';
              });
              list.sort(function (a, b) {
                return dir === 'prev' ? b.savedAt - a.savedAt : a.savedAt - b.savedAt;
              });
              return list;
            };
            return {
              openCursor: function (range, dir) {
                const rq = { result: null, onsuccess: null, onerror: null };
                later.push(function () {
                  const recs = recsIn(dir);
                  let i = 0;
                  const step = function () {
                    if (i >= recs.length) {
                      rq.result = null;
                      if (rq.onsuccess) rq.onsuccess({ target: rq });   // 真 IDB:走完交回 null
                      return;
                    }
                    const rec = recs[i++];
                    idbReads15.cursor++;              // ★ 物化一条**记录本体**
                    rq.result = { key: rec.savedAt, primaryKey: rec.key, value: rec,
                                  continue: function () { realSetTimeout15(step, 0); } };
                    if (rq.onsuccess) rq.onsuccess({ target: rq });
                  };
                  step();
                });
                return rq;
              },
              openKeyCursor: function (range, dir) {
                const rq = { result: null, onsuccess: null, onerror: null };
                later.push(function () {
                  const recs = recsIn(dir);
                  idbReads15.keys++;
                  // ★ 只给**索引键**(一个数)与主键,**不给记录本体** —— 这正是它便宜的原因
                  rq.result = recs.length ? { key: recs[0].savedAt, primaryKey: recs[0].key } : null;
                  if (rq.onsuccess) rq.onsuccess({ target: rq });
                });
                return rq;
              },
            };
          },
        };
      };
      realSetTimeout15(function () {
        if (fail15.deleteTx && mode === 'readwrite' && hasDelete) {
          if (tx.onerror) tx.onerror({ target: tx });    // ★ 失败的事务不提交
          return;
        }
        later.forEach(function (f) { f(); });
        if (tx.oncomplete) tx.oncomplete({ target: tx });
      }, 0);
      return tx;
    }
    return { objectStoreNames: { contains: function () { return true; } },
             createObjectStore: function () { return {}; }, transaction: txOf };
  }
  // ★★ 升级请求上的 `transaction`(真 IDB 把它挂在 `req.transaction` 上):生产在
  //    `onupgradeneeded` 里要经它拿到**已经在用的**那个 store 补建 `savedAt` 索引
  //    (版本 1 → 2 升级路径)。不给的话那一步会抛 —— 而抛在 `onupgradeneeded` 里
  //    是**整套草稿盘开不出来**,症状是"草稿盘没了"。
  function upgradeReq15(db) {
    return { result: db, transaction: {
      objectStore: function () {
        return { indexNames: { contains: function () { return false; } },
                 createIndex: function () {} };
      },
    }, onupgradeneeded: null, onsuccess: null, onerror: null };
  }
  // ── 记账的假 setTimeout(只给 ui.js 用;替身自己用 realSetTimeout15)──
  // ★ 三种状态要分清:**待跑**(排上了还没到点)、**被撤**(clearTimeout)、**已跑**。
  //   混在一起就会把"上一次已经跑完的那个"也算成在飞。
  const timers15 = [], killed15 = [];
  let timerSeq15 = 0;
  globalThis.setTimeout = function (fn, ms) { timerSeq15++; timers15.push({ id: timerSeq15, fn: fn, ms: ms, ran: false }); return timerSeq15; };
  globalThis.clearTimeout = function (id) { killed15.push(id); };
  const pending15 = function () {
    return timers15.filter(function (t) { return !t.ran && killed15.indexOf(t.id) < 0; });
  };
  const fire15 = function (t) { t.ran = true; return t.fn(); };
  async function tick15() {                      // 走一次**真**的宏任务:把微任务链全放干净
    await new Promise(function (res) { realSetTimeout15(res, 0); });
  }
  // ★ 有界地等一个**异步副作用**落地(上界 200 拍,超了按失败算 —— 不许悄悄放行)。
  //   ★★ 只有一处需要它:`saveCurrent` **刻意不** await 草稿盘那一步,所以"标干净"是在它
  //      交回之后才落地的。
  async function until15(cond) {
    for (let i = 0; i < 200; i++) { if (cond()) return true; await tick15(); }
    return false;
  }
  // ── 只认几个 id 的 document + 会记账的 app.r ──
  const calls15 = [];
  const els15 = {};
  function el15(id) {
    if (els15[id]) return els15[id];
    const on = {};
    const el = { id: id, textContent: '', value: '', checked: false, hidden: false,
                 style: {}, dataset: {}, children: [], className: '',
                 // ★ parentNode 也要"够真":`syncPanelForLayer` 会顺着 parentNode 一路往上
                 //   找 `.desc-row` —— 给个裸对象会在那里抛,而那是**替身**的缺口。
                 parentNode: { style: {}, insertBefore: function () {}, appendChild: function () {} },
                 nextSibling: null,
                 classList: { toggle: function (c, v) { on[c] = !!v; },
                              add: function () {}, remove: function () {},
                              contains: function (c) { return !!on[c]; } },
                 // ★★ 记账(而不是空实现):⑩b 要驱动**生产真的挂上去**的那个点击处理器
                 //    (`#lib-list` 的委托那一只)。一个事件可以挂多个处理器,故存**数组**。
                 _h: {},
                 addEventListener: function (t, fn) { (el._h[t] = el._h[t] || []).push(fn); },
                 appendChild: function (c) { el.children.push(c); return c; },
                 insertBefore: function (c) { el.children.push(c); return c; },
                 removeChild: function () {}, querySelector: function () { return null; } };
    els15[id] = el;
    return el;
  }
  let made15 = 0;
  // ★★ 四个图层行替身(与 editor.html 的 `.layer-row` 同形):`setLayer`(ui 那一层)要按
  //     `dataset.layer` 把 `.cur` 挪到对应行上。初始 `.cur` 照 editor.html 写死在「场景」
  //     (data-layer=1)上:这样"只改渲染层"的实现会露馅。
  const rows15 = [Core.LAYER_FRONT, Core.LAYER_SCENE, Core.LAYER_BACK,
                  Core.LAYER_BG].map(function (L) {
    const on = { cur: (L === Core.LAYER_SCENE) };
    const row = el15('layer-row-' + L);
    row.dataset = { layer: String(L) };
    row.classList = { toggle: function (c, v) { on[c] = !!v; },
                      add: function (c) { on[c] = true; }, remove: function (c) { on[c] = false; },
                      contains: function (c) { return !!on[c]; } };
    row.querySelector = function () { return { addEventListener: function () {}, style: {} }; };
    return row;
  });
  const curRow15 = function () {
    let out = -1;
    rows15.forEach(function (r) { if (r.classList.contains('cur')) out = parseInt(r.dataset.layer, 10); });
    return out;
  };
  globalThis.document = {
    getElementById: function (id) { return el15(id); },
    querySelectorAll: function (sel) { return sel === '#layers .layer-row' ? rows15 : []; },
    querySelector: function () { return null; },
    createElement: function (tag) {
      if (tag === 'canvas') {
        return { width: 0, height: 0, getContext: function () {
          return { drawImage: function () {},
                   getImageData: function (x, y, w, h) { return { data: new Uint8ClampedArray(w * h * 4) }; } };
        } };
      }
      made15++;
      return el15('made' + made15);
    },
  };
  Editor.app.canvas = { width: 80, height: 80 };
  // ★ `layer()` / `setLayer()` 这一对要**写成状态**(不是两个常量):`syncPanelForLayer`
  //   的判据就是 `app.r.layer()`。
  let renderLayer15 = Core.LAYER_SCENE;
  Editor.app.r = {
    view: function () { return { x: 0, y: 0, zoom: 1 }; },
    layer: function () { return renderLayer15; },
    selection: function () { return null; },
    setMap: function () { calls15.push('setMap'); return Promise.resolve(); },
    setLayer: function (L) { renderLayer15 = L; calls15.push('setLayer:' + L); },
    setGrid: function (b) { calls15.push('setGrid:' + b); },
    setSubGrid: function (b) { calls15.push('setSubGrid:' + b); },
    setTorus: function (b) { calls15.push('setTorus:' + b); },
    setDimOthers: function (b) { calls15.push('setDimOthers:' + b); },
    setZoomAt: function () { calls15.push('setZoomAt'); return Promise.resolve(); },
    editCells: function () { calls15.push('editCells'); },
    render: function () { calls15.push('render'); },
    invalidateAll: function () { calls15.push('invalidateAll'); return Promise.resolve(); },
  };
  Editor.app.map = null; Editor.app.db = null;

  Object.assign(globalThis, { realSetTimeout15: realSetTimeout15, tab15: tab15, fail15: fail15,
    idbReads15: idbReads15, killed15: killed15, pending15: pending15, fire15: fire15,
    until15: until15, calls15: calls15, els15: els15, el15: el15, curRow15: curRow15,
    upgradeReq15: upgradeReq15, fakeDb15: fakeDb15 });
}

function restore() {
  if (!installed) return;
  installed = false;
  globalThis.document = saved.doc; globalThis.confirm = saved.confirm;
  globalThis.setTimeout = saved.setTimeout; globalThis.clearTimeout = saved.clearTimeout;
  globalThis.fetch = saved.fetch;
  if (saved.indexedDB === undefined) delete globalThis.indexedDB;
  else globalThis.indexedDB = saved.indexedDB;
  Editor.app.r = saved.r; Editor.app.map = saved.map; Editor.app.name = saved.name;
  Editor.app.sourceFormat = saved.fmt; Editor.app.db = saved.db;
  Editor.app.canvas = saved.canvas; Editor.app.uist = saved.uist;
  Editor.app.st = saved.st; Editor.app.raw = saved.raw;
}

module.exports = {
  getStubs15: function () { if (!installed) install(); return module.exports; },
  restoreStubs15: restore,
};
