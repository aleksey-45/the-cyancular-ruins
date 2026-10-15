// ui/70_draft.js —— 草稿与崩溃栅栏:库结构、淘汰计划、防抖存盘。

// ── 持久化三层(规格 §4.6)+ 闸 4(崩溃前快照):真文件 maps/*.cyrm → IndexedDB 草稿盘 → localStorage
//    只存 UI 小状态;三层递进,"作品"的最高保真副本永远是真文件。
var DRAFT_DB = 'cyrm-editor';
var DRAFT_STORE = 'draft';
var CRASH_STORE = 'crash';
// ★ 库版本 2 = 给草稿盘加 savedAt 索引,换来两条不物化记录本体的查询(最新 savedAt / 按时间挑淘汰对象)。
var DRAFT_DB_VERSION = 2;
var DRAFT_TIME_INDEX = 'savedAt';
var UI_STATE_KEY = 'cyrm.ui.v1';       // ★ 带版本号:将来换字段可以让老的那份自然失效
var MAX_LIB = 60;                      // 库条目上限(规格 §4.3 闸 1)
var DRAFT_DEBOUNCE_MS = 1500;          // 最后一笔之后多久落盘(不是每笔都写)
var UI_SAVE_THROTTLE_MS = 500;         // localStorage 是同步写:每帧写会掉帧

// ★ 草稿盘的主键 = sanitizeName(文件名):库的身份就是文件名,另铸一套 id 必然与文件那一套漂。
function draftKey(name) { return Core.sanitizeName(nameFromFile(name)); }
// ★ "当前这张图"的键只有这一处:写进去的与读出来的必须是同一个键,否则症状是"草稿盘里明明
//   有一条,恢复时说什么都没有"(而且不报错)。
function currentDraftKey() {
  return draftKey(app.name || (app.map ? app.map.name : '') || '');
}

// ⚠ 已知局限:比的是"草稿盘里任意地图最新一份"的 savedAt(idbNewestSavedAt),所以用别的图刷新的草稿
//   会把崩溃提示压下去。★ declined = 这条快照已经问过、用户说不要 ⇒ 不再反复问:不记的话一次偶发页面
//   异常会把每一次打开都变成「上次异常退出」。★ 新的一次崩溃会重写这条记录(不带 declined)⇒ 照问。
function crashIsNewer(crashRec, mainRec) {
  if (!crashRec) return false;
  if (crashRec.declined) return false;
  if (!mainRec) return true;
  return (crashRec.savedAt || 0) > (mainRec.savedAt || 0);
}

// 库条目上限(闸 1:60)。★ 先丢"已保存且最老"的 —— 脏的那份是用户还没写盘的劳动。
function evictPlan(records, maxEntries) {
  var list = (records || []).slice();
  var cap = (maxEntries === undefined) ? MAX_LIB : maxEntries;
  if (list.length <= cap) return { keep: list.map(function (r) { return r.key; }), drop: [] };
  var sorted = list.slice().sort(function (a, b) {
    var ad = a.dirty ? 1 : 0, bd = b.dirty ? 1 : 0;
    if (ad !== bd) return ad - bd;                 // 干净的排前面(先被丢)
    return (a.savedAt || 0) - (b.savedAt || 0);     // 同样干净时,最老的先丢
  });
  var drop = sorted.slice(0, list.length - cap).map(function (r) { return r.key; });
  var keep = [];
  list.forEach(function (r) { if (drop.indexOf(r.key) < 0) keep.push(r.key); });
  return { keep: keep, drop: drop };
}

function uiStateDefaults() {
  return { layer: Core.LAYER_SCENE, zoom: 0, tool: 'brush', brushSize: 1,
           grid: true, subGrid: false, torus: true, dimOthers: true,
           compress: DEFAULT_COMPRESS,
           panelOpen: { lib: true, right: true },
           playerRef: { cx: 0, cy: 0, visible: false }, selectedTexture: 1 };
}
// ★★ 逐字段校验:一个坏字段不该把整份状态丢掉,也不该把坏值原样喂给渲染器。缩放那一处是钳
//    不是"回落默认":默认的 0 是"没存过缩放"的哨兵,而存过但坏了的 zoom:-1 必须钳到合法区间。
function readUiState(store) {
  var def = uiStateDefaults();
  var raw = null;
  try { raw = store ? store[UI_STATE_KEY] : null; } catch (e) { raw = null; }
  if (!raw) return def;
  var obj = null;
  try { obj = JSON.parse(raw); } catch (e) { return def; }
  if (!obj || typeof obj !== 'object') return def;
  var out = uiStateDefaults();
  if (obj.layer >= 0 && obj.layer < Core.LAYER_COUNT) out.layer = obj.layer | 0;
  if (isFinite(obj.zoom)) out.zoom = Render.clampZoom(obj.zoom);
  if (TOOLS.indexOf(obj.tool) >= 0) out.tool = obj.tool;
  if (isFinite(obj.brushSize) && obj.brushSize > 0) {
    out.brushSize = Math.max(0.25, Math.min(Render.MAX_BRUSH_CELLS, obj.brushSize));
  }
  ['grid', 'subGrid', 'torus', 'dimOthers', 'compress'].forEach(function (k) {
    if (typeof obj[k] === 'boolean') out[k] = obj[k];
  });
  if (obj.panelOpen && typeof obj.panelOpen === 'object') {
    if (typeof obj.panelOpen.lib === 'boolean') out.panelOpen.lib = obj.panelOpen.lib;
    if (typeof obj.panelOpen.right === 'boolean') out.panelOpen.right = obj.panelOpen.right;
  }
  if (obj.playerRef && typeof obj.playerRef === 'object') {
    var pr = obj.playerRef;
    out.playerRef = {
      cx: isFinite(pr.cx) ? Math.floor(pr.cx) : def.playerRef.cx,
      cy: isFinite(pr.cy) ? Math.floor(pr.cy) : def.playerRef.cy,
      visible: pr.visible === true,
    };
  }
  if (isFinite(obj.selectedTexture) && obj.selectedTexture > 0) {
    // ★★ selectedTexture 不许在这里用图集派生的上界钳:bootLoad 在图集存在之前就读它,而 setAtlas
    //    之前 atlasCapacity() 是 0 ⇒ clampTexture 把"cap < 1"当"没有信息"返回 1 ⇒ 存进去的 7 每次
    //    开机变 1、persistUi 再把 1 写回去(每次都静默毁掉)。★ 钳制挪到了 applyUiState(在图集之后)。
    out.selectedTexture = Math.floor(obj.selectedTexture);
  }
  return out;
}
function writeUiState(store, uist) {
  try { store.setItem(UI_STATE_KEY, JSON.stringify(uist)); }
  catch (e) { /* 私密模式/配额满:UI 小状态丢了不影响作品,静默 */ }
}
// ★ 取 localStorage 这件事本身在私密模式下就可能抛(不是只有 setItem 会),故收在一处。
function localStore() {
  try {
    return (typeof window !== 'undefined' && window.localStorage) ? window.localStorage : null;
  } catch (e) { return null; }
}

// ★ 草稿盘开不出来就不降级、不抛,但必须说一句 —— 否则用户以为"编辑器帮我存着呢"。
function openDraftStore() {
  return new Promise(function (resolve) {
    if (typeof indexedDB === 'undefined') { resolve(null); return; }
    var req;
    try { req = indexedDB.open(DRAFT_DB, DRAFT_DB_VERSION); } catch (e) { resolve(null); return; }
    req.onupgradeneeded = function () {
      var db = req.result;
      // ★★ onupgradeneeded 两条路都要把索引建出来:全新库走 createObjectStore,已在用的库升上来时
      //    store 已经在了(里面还有老记录),要经升级事务拿到它、补建索引 —— 只建一条路的话,老库
      //    升上来之后那两条查询读不到任何东西(游标永远 null),症状是"崩溃快照永远不提示"。
      var st = db.objectStoreNames.contains(DRAFT_STORE)
        ? req.transaction.objectStore(DRAFT_STORE)
        : db.createObjectStore(DRAFT_STORE, { keyPath: 'key' });
      if (st && st.indexNames && !st.indexNames.contains(DRAFT_TIME_INDEX)) {
        st.createIndex(DRAFT_TIME_INDEX, 'savedAt');
      }
      if (!db.objectStoreNames.contains(CRASH_STORE)) db.createObjectStore(CRASH_STORE, { keyPath: 'key' });
    };
    req.onsuccess = function () { resolve(req.result); };
    req.onerror = function () { resolve(null); };      // 配额/私密模式:草稿盘不可用也要能用编辑器
    // ★★ onblocked 必须接:另一个标签页还按版本 1 开着这张库 ⇒ 升级被阻塞(既不 success 也不 error),
    //    不接的话这条 promise 永远不 settle,而 bootLoad 正 await 着它 —— 症状是编辑器白屏。
    req.onblocked = function () { resolve(null); };
  });
}
function idbPut(db, store, rec) {
  return new Promise(function (resolve, reject) {
    var tx = db.transaction(store, 'readwrite');
    tx.objectStore(store).put(rec);
    tx.oncomplete = function () { resolve(true); };
    tx.onerror = function () { reject(tx.error || new Error('IndexedDB 写失败')); };
    tx.onabort = function () { reject(tx.error || new Error('IndexedDB 写被中止')); };
  });
}
// ★ 只用 count() 问条数 —— 记录本体(每张草稿带着编码后的整张图,每张 2.4MB)一个字节都不反序列化。
function idbCount(db, store) {
  return new Promise(function (resolve) {
    var tx, rq;
    try { tx = db.transaction(store, 'readonly'); rq = tx.objectStore(store).count(); }
    catch (e) { resolve(null); return; }
    rq.onsuccess = function () { resolve(typeof rq.result === 'number' ? rq.result : 0); };
    rq.onerror = function () { resolve(null); };    // ★ null = 读不到(不是"0 条")
  });
}
// ★★ 单条读:ok:false = 读不到(事务打不开 / 请求失败),rec:null = 读到了、那条不存在。两者必须
//    分得开:把"读失败"折成"没有这条记录"会让「上次异常退出」那一次抢救无声消失。
function idbGetOne(db, store, key) {
  return new Promise(function (resolve) {
    var tx, rq;
    try { tx = db.transaction(store, 'readonly'); rq = tx.objectStore(store).get(key); }
    catch (e) { resolve({ ok: false, rec: null }); return; }
    rq.onsuccess = function () { resolve({ ok: true, rec: rq.result || null }); };
    rq.onerror = function () { resolve({ ok: false, rec: null }); };
    if (tx) tx.onabort = function () { resolve({ ok: false, rec: null }); };
  });
}
// ★★ 最新一条的 savedAt 走索引键游标(openKeyCursor):交回的就是索引键本身,记录本体一个字节都不反序列化。
function idbNewestSavedAt(db) {
  return new Promise(function (resolve) {
    var tx, rq;
    try {
      tx = db.transaction(DRAFT_STORE, 'readonly');
      rq = tx.objectStore(DRAFT_STORE).index(DRAFT_TIME_INDEX).openKeyCursor(null, 'prev');
    } catch (e) { resolve({ ok: false, savedAt: null }); return; }
    rq.onsuccess = function () {
      var cur = rq.result;
      resolve({ ok: true, savedAt: (cur && typeof cur.key === 'number') ? cur.key : null });
    };
    rq.onerror = function () { resolve({ ok: false, savedAt: null }); };
    if (tx) tx.onabort = function () { resolve({ ok: false, savedAt: null }); };
  });
}
// ★★ 找牺牲者按 savedAt 升序逐条走,凑够"干净的"那几条就停 —— 不是把整库 getAll 进来
//    (满库是常态,那条路径上每次防抖落盘都要物化整库)。★ 淘汰口径仍只有一处:evictPlan。
function idbWalkDraftVictims(db, need) {
  return new Promise(function (resolve) {
    var tx, rq;
    try {
      tx = db.transaction(DRAFT_STORE, 'readonly');
      rq = tx.objectStore(DRAFT_STORE).index(DRAFT_TIME_INDEX).openCursor(null, 'next');
    } catch (e) { resolve(null); return; }
    var entries = [], clean = 0, done = false;
    var finish = function (out) { if (done) return; done = true; resolve(out); };
    rq.onsuccess = function () {
      if (done) return;
      var cur = rq.result;
      if (!cur) { finish({ entries: entries, clean: clean }); return; }   // 走完了
      var rec = cur.value || {};
      if (!rec.dirty) clean++;
      entries.push({ key: cur.primaryKey, savedAt: cur.key, dirty: !!rec.dirty });
      if (clean >= need) { finish({ entries: entries, clean: clean }); return; }
      cur['continue']();                            // ★ 不调它,游标就停在第一条上
    };
    rq.onerror = function () { finish(null); };
    if (tx) tx.onabort = function () { finish(null); };
  });
}
var draftTimer = null;
var draftRev = 0;              // 地图每次变动 +1(判"这一版写过没有")
var draftSavedRev = -1;        // 上一次草稿落盘时的 rev
var lastAutoSaveAt = 0;        // 状态栏那一格要显示的自动保存时刻(0 = 本局还没自动存过)

// ★★ 唯一一处"地图变了"的落笔:设脏标记 + 排一次防抖落盘。全项目五个改动点(落一笔 / 撤销重做 /
//    新建 / 复制 / 改名)都走这里 —— 散开写 dirty = true 的话,新加一个改动点只会忘掉草稿那一半。
function markDirty() {
  dirty = true;
  draftRev++;
  scheduleDraftSave();
}
// ★ 防抖:最后一笔之后 DRAFT_DEBOUNCE_MS 才落盘;return 是把落盘那条链交回去,让"防抖到点之后到底写成了没有"可以被 await。
function scheduleDraftSave() {
  if (!app.map || !app.db) return;             // 草稿盘不可用:连定时器都不排
  if (draftTimer) clearTimeout(draftTimer);
  draftTimer = setTimeout(function () { draftTimer = null; return saveDraft(false); }, DRAFT_DEBOUNCE_MS);
}
// ★ 离开页面/刷新前的补刀:判据用 dirty(磁盘那一侧)而不是 rev —— 刚 Ctrl+S 过的图不该因为一次刷新又被标成脏草稿。
function flushDraft() {
  if (draftTimer) { clearTimeout(draftTimer); draftTimer = null; }
  if (!dirty) return Promise.resolve();
  return saveDraft(true);                      // force:绕过节流(见 saveDraft)
}
