// ui/65_save_current.js —— 存盘主流程与导出报告。

function saveCurrent(asNew) {
  if (!app.map) { status('先打开一张地图'); return Promise.resolve(); }
  // ★★ 备份不是保存目标:.v3.bak 装的是这张图原文的最后一手退路,就地覆盖它 = 把退路换成 v4(名字还会漂成 <名>v3bak.v3.bak);★ 库列表只管点击,故 ?p= 那条 URL 直接打开的路要靠这道闸。
  if (!asNew && isBackupName(app.name)) {
    status('这是一份原文备份(' + app.name + '),不是地图 —— 不能就地覆盖它。请用「另存为」另起一个名字');
    return Promise.resolve();
  }
  // ★★ 确认与备份是两条独立的门:确认每会话一次,备份每个文件一次(v3BackedUp)—— 两半共用一个会话级
  //    标记时,同一会话里保存第二张 v3 图是静默的单向转换,安全网只盖住第一张。
  var backupName = null, backupBytes = null, backupKey = null;
  if (needsV3Backup(app.sourceFormat, app.name, v3BackedUp)) {
    backupBytes = app.raw || null;                 // 磁盘上那份的原文(打开时留下的)
    backupName = backupBytes ? v3BackupName(app.name) : null;
    backupKey = backupName ? app.name : null;
  }
  if (needsV3Confirm(app.sourceFormat, v3Confirmed)) {
    var okGo = window.confirm(
      '原文件是 v3 文本,保存会把它转成 v4 二进制(不可逆)。\n' +
      '★ 游戏现在**读不了** v4 —— 在期 E 把 map_format.gd 迁移过去之前,这个文件在游戏里会失效。\n' +
      (backupName ? ('保存前会先把原文备份到 ' + backupName + '。\n') : '') +
      '(本次会话不再询问)');
    if (!okGo) { status('已取消保存(磁盘上那份没有被碰过)'); return Promise.resolve(); }
    v3Confirmed = true;
  }
  var name = saveTargetName(asNew);
  if (!name) return Promise.resolve();
  status('保存 ' + name + ' …');
  // ★★ 草稿盘那条记录挂在存盘前那个键上:另存为会换名字,存完再问键就找不到了 —— 于是旧名字下那条
  //    脏草稿会留着,下次打开那张旧图时弹一次假的恢复提示。
  var draftAt = currentDraftKey();
  // ★★ 写盘只走 putMapBytes 这一个出口(页面上唯一发 PUT 的地方):PUT 的 Content-Type: application/json
  //    与"body 是裸字节"两条纪律都钉在那里(不设头 = 浏览器按 Blob 推类型 ⇒ 服务器 415 ⇒ "点了保存、磁盘上那份没变")。
  return encodeForWrite(app.map).then(function (bytes) {
    // ★★ 备份排在真保存之前,走同一个 putMapBytes 出口;备份写不进去就不写盘 —— 这次转换是单向的,
    //    备份是唯一的退路,先写盘再发现备份失败 = 原文与退路一起没了。
    var pre = backupName
      ? putMapBytes(backupName, backupBytes).then(function () {
          // ★★ 记账只能在备份真的落盘之后:写失败时保存整个中止、sourceFormat 仍是 v3 ⇒ 用户重试那一次
          //    必须再写一遍备份;提前记账会让重试跳过备份、直接把 v4 写下去。
          v3BackedUp.add(backupKey);
        }, function (e) {
          throw new Error('原文备份写不进去(' + backupName + '):' + msgOf(e) +
                          ' —— 没有动磁盘上那一份');
        })
      : Promise.resolve();
    return pre.then(function () { return putMapBytes(name, bytes); })
              .then(function (out) {
      app.name = name;
      app.raw = bytes;
      app.sourceFormat = 'v4';
      dirty = false;                 // ★★ 只有真的写成功了才清(见 dirty 那段的纪律)
      markDraftSaved(draftAt);
      refreshStatus();
      statusLine();
      // ★★ 库列表刷新排在说结果之前:那条 GET 失败时 guard 会往同一条状态栏写错误,先写「已保存」再被它盖掉 = 用户以为保存失败。
      return Promise.resolve(guard('库列表刷新', function () { return refreshLibrary(); }))
             .then(function () {
               status('已保存 ' + out.name + '(' + out.size + ' 字节)' +
                      (backupName ? ',原文备份 ' + backupName : ''));
             });
    });
  }).catch(function (e) {
    status('保存失败:' + msgOf(e));
  });
}

function importEnemyTypes() {
  var reg = globalThis.ENEMY_REGISTRY;
  if (!reg || !reg.length) return [];
  return reg.map(function (e) { return String(e.id); });
}

function exportReport() {
  if (!app.map) return { lines: ['还没打开地图'], ok: false };
  var rep = Core.validateMap(app.map);
  var lines = validateLines(rep);
  if (!lines.length) lines = ['校验通过:没有发现问题'];
  lines.push('尺寸 ' + Core.cellsWOf(app.map) + '×' + Core.cellsHOf(app.map) + ' 格 · 出生点 ' +
             app.map.players.length + ' · 敌人 ' + app.map.enemies.length);
  if (app.map.players.length > 2) {
    lines.push('⚠ 第 3 个及以后的出生点游戏侧读不到(map_format.gd 只认 player/player2)');
  }
  return { lines: lines, ok: rep.errors.length === 0 };
}
function showExportReport() {
  var rep = exportReport();
  window.alert(rep.lines.join('\n'));
  status(rep.ok ? '导出校验:没有 error' : '导出校验:有 error(encodeMap 会拒绝导出)');
}
