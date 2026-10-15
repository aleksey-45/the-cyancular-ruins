// ui/75_draft_store.js —— 草稿的读写、剪枝与恢复提示。

// 草稿以编码后的字节存(恢复走同一条解码路);★ force 越不过编码之后那道判据 —— 那是正确性,不是省活。
// ★★ 一条记录的两半(它是谁 / 它是什么内容)必须在同一个瞬间取:编码是异步的(400×300 的图 × 4 层 ≈ 30MB),
//    而这段时间里用户完全可能换一张图 —— 编码之后再读 key/name,写出来的就是 {key:'B', bytes:<A 的内容>}。
function saveDraft(force) {
  if (!app.map || !app.db) return Promise.resolve();
  var rev = draftRev;
  if (!force && rev <= draftSavedRev) return Promise.resolve();
  var mapAtEntry = app.map;
  var key = currentDraftKey();
  var name = app.name, name2 = app.map.name, fmt = app.sourceFormat;
  return encodeForWrite(mapAtEntry).then(function (bytes) {
    // ★★ 编码期间可能已经有了一次 Ctrl+S(这一版已进真文件、草稿已标干净),再写回一份 dirty 的草稿
    //    会让下次打开弹一次假的恢复提示;★ 另一半:编码期间 app.map 被换过 ⇒ 这条记录没有任何意义,
    //    唯一正确的动作是整笔放弃。
    if (rev <= draftSavedRev) return null;
    if (app.map !== mapAtEntry) return null;
    var rec = { key: key, name: name, name2: name2, bytes: bytes,
                sourceFormat: fmt, savedAt: Date.now(), dirty: true };
    return idbPut(app.db, DRAFT_STORE, rec).then(function () {
      draftSavedRev = rev;             // 能走到这里 ⇒ 上面那道判据刚过,故这一定是推进
      lastAutoSaveAt = rec.savedAt;
    });
  }).then(function () {
    renderSaveState();               // 状态栏那一格由草稿盘接管
    return pruneDrafts();
  }).catch(function (e) {
    status('草稿盘写入失败:' + msgOf(e) + '(作品仍在,请尽快 Ctrl+S 写盘)');
  });
}
// Ctrl+S 成功之后草稿标干净而不删(留着它既是"上次停在哪"的记录,也让 evictPlan 优先淘汰它);★ 与 dirty = false 同一条纪律:只有真的写成功了才调它。
function markDraftSaved(key) {
  if (!app.db) return Promise.resolve(false);
  draftSavedRev = draftRev;
  lastAutoSaveAt = 0;
  return loadDraft(key || currentDraftKey()).then(function (rec) {
    if (!rec) return false;
    rec.dirty = false;
    return idbPut(app.db, DRAFT_STORE, rec).then(function () { return true; });
  }).catch(function () { return false; });   // 标不干净不影响"已经存盘了"这个事实
}
// ★★ 先数条数再决定要不要读记录本体:getAll() 会把库里每一条都反序列化进主线程(每张草稿带着编码后的整张图)⇒
//    没到上限的常态路径只剩一次 count();到了上限走索引键序逐条(凑够就停)。
function pruneDrafts() {
  var didNotRun = '(这次的草稿已存下,但 ' + MAX_LIB + ' 条上限这次没生效)';
  return idbCount(app.db, DRAFT_STORE).then(function (n) {
    if (n === null) { status('草稿盘清理失败:读不到条目数 ' + didNotRun); return null; }
    if (n <= MAX_LIB) return null;                  // ★ 常态:只数一次,一条都不读
    var need = n - MAX_LIB;
    return idbWalkDraftVictims(app.db, need).then(function (walk) {
      if (walk === null) { status('草稿盘清理失败:读不到草稿列表 ' + didNotRun); return null; }
      // ★★ cap 取 entries.length - need:两种情形(恰好含 need 条干净的 / 走完全库)同一条公式,淘汰口径仍只有 evictPlan 一处。
      var plan = evictPlan(walk.entries, walk.entries.length - need);
      if (!plan.drop.length) return null;
      var tx;
      try { tx = app.db.transaction(DRAFT_STORE, 'readwrite'); }
      catch (e) { status('草稿盘清理失败:' + msgOf(e) + ' ' + didNotRun); return null; }
      plan.drop.forEach(function (k) { tx.objectStore(DRAFT_STORE).delete(k); });
      return new Promise(function (resolve) {
        tx.oncomplete = function () { status('草稿盘超过 ' + MAX_LIB + ' 条,已清掉 ' + plan.drop.length + ' 条最老的'); resolve(true); };
        tx.onerror = function () { status('草稿盘清理失败:删不掉那 ' + plan.drop.length + ' 条 ' + didNotRun); resolve(false); };
        tx.onabort = function () { status('草稿盘清理失败:删除事务被中止 ' + didNotRun); resolve(false); };
      });
    });
  }).catch(function (e) {
    // ★★ 两条失败路径都必须说出来(读不到条数 / 读不到列表 / 删除事务失败):清理不生效若是静默,
    //    用户只会看到草稿盘悄悄涨过 60 条;而"读失败"与"没到上限"在静默实现里长得一模一样。
    status('草稿盘清理失败:' + msgOf(e) + ' ' + didNotRun);
    return null;
  });
}
function loadDraft(key) {
  if (!app.db) return Promise.resolve(null);
  return new Promise(function (resolve) {
    var tx = app.db.transaction(DRAFT_STORE, 'readonly');
    var rq = tx.objectStore(DRAFT_STORE).get(key);
    rq.onsuccess = function () { resolve(rq.result || null); };
    rq.onerror = function () { resolve(null); };
  });
}
// ★★ 不静默恢复:画布上突然换成一份与真文件不同的图,用户接着一按 Ctrl+S 就把草稿盖回文件上
//    —— 那是这一层最坏的一种失败。故一律问一次(判据是记录自己的 dirty)。
function offerDraft() {
  if (!app.db || !app.map) return Promise.resolve(false);
  var key = currentDraftKey();
  return loadDraft(key).then(function (rec) {
    if (!rec || !rec.dirty || !rec.bytes) return false;
    // ★★ 再判一道(挡"假提示"):草稿那份与刚从真文件读进来的字节逐字节相同 ⇒ 那一版已经在文件里了。
    if (sameBytes(rec.bytes, app.raw)) return false;
    var yes = window.confirm('发现一份还没写盘的草稿(' +
                             new Date(rec.savedAt || 0).toLocaleString() + '),要恢复吗?');
    if (!yes) { status('草稿仍在草稿盘里(屏幕上的图没被动过)'); return false; }
    return Io.decodeMap(rec.bytes).then(function (map) {
      map.name = rec.name2 || map.name || '';
      app.map = map; app.sourceFormat = 'v4';
      if (rec.name) app.name = rec.name;
      dirty = true;                       // ★ 屏幕上这份 ≠ 磁盘上那份 ⇒ 必须说「未保存」
      guard('草稿恢复', function () { return app.r.setMap(map); });
      refreshStatus(); statusLine();
      status('已从草稿恢复:' + (rec.name2 || key));
      return true;
    });
  }).catch(function (e) { status('草稿恢复失败:' + msgOf(e)); return false; });
}
function sameBytes(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
