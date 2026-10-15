// ui/50_save.js —— 保存状态与分帧作业。

// ★★ 一个写入者:三种文案全在这里决定,别处只改 dirty / lastAutoSaveAt(两个写入者会互相打脸);
//    且只在"保存真的成功"与"打开真的成功"两处清零,绝不挂在 guard 的决议上(失败时它决议 undefined)。
var dirty = false;
function renderSaveState() {
  var el = $('st-save');
  if (!el) return;
  if (app.db && lastAutoSaveAt) {
    el.textContent = '已自动保存 ' + new Date(lastAutoSaveAt).toLocaleTimeString();
    return;
  }
  el.textContent = dirty ? '未保存' : '已保存';
}

// ★★ 唯一读压缩开关的地方,而且是真文件 / 草稿盘 / 崩溃槽位三处共用的一条路:前两处必须同值,否则
//    offerDraft 的 sameBytes(rec.bytes, app.raw) 会比出"不同" ⇒ 一次开机弹一次假的「没写盘的草稿」。
var DEFAULT_COMPRESS = true;         // 规格 §3.5:默认勾上
function optCompress() {
  var el = $('opt-compress');
  return el ? !!el.checked : DEFAULT_COMPRESS;   // 控件不在(启动早期/替身)⇒ 按默认
}
function encodeForWrite(map) {
  return Io.encodeMap(map, { compress: optCompress() });
}

function pushAndShow(diff) {
  if (!diff) return false;
  undoHistory.push(diff);
  markDirty();                      // ★ 落了笔 ⇒ 磁盘上那份已经不等于屏幕上这一份了(+ 排草稿)
  // ★ 两条路都要走:kind:'whole' 改的是尺寸本身,diffCells 对它是空数组 ⇒ 只 render() 的话整张图
  //   停在旧尺寸上(画面错了、一个字都不报);invalidateAll 会把缩略图与 ② 整片重建。
  if (diff.kind === 'whole') { Promise.resolve(app.r.invalidateAll()); statusLine(); return true; }
  var cells = diffCells(app.map, diff);
  if (cells.length) app.r.editCells(diff.layer, cells);
  else app.r.render();
  statusLine();
  return true;
}
function doUndo() {
  var e = undoHistory.undo();
  if (!e) { status('没有可撤销的操作'); return null; }
  applyEntry(app.map, e, -1);
  return afterStateChange(e);
}
function doRedo() {
  var e = undoHistory.redo();
  if (!e) { status('没有可重做的操作'); return null; }
  applyEntry(app.map, e, +1);
  return afterStateChange(e);
}
function afterStateChange(e) {
  var out = null;
  // ★ 撤销/重做也是一次改动:回到"保存时那一刻"的图上仍显示「未保存」是刻意的(要判"撤销回去了
  //   没有"得比整份字节);★ whole 分支不是 setMap(那个会重新 fit 并清掉选区),但要清装不下的选区,
  //   并把状态栏的 #st-size 与尺寸面板那两个框一起翻新(refreshStatus)。
  markDirty();
  if (e.kind === 'whole') {
    out = Promise.resolve(app.r.invalidateAll());
    if (dropStaleSelection()) status('选区超出新尺寸,已清掉');
    refreshStatus();
  } else if (e.kind === 'cells') {
    var cells = diffCells(app.map, e);
    if (cells.length) app.r.editCells(e.layer, cells); else app.r.render();
  } else app.r.render();
  statusLine();
  return out;
}
// ★★ 长作业(油漆桶 / 渐变)分帧的让出判据是时间预算(Render.createSlicer,默认 8ms/帧),不是固定
//    条数 —— 固定条数在慢机器上照样能把一帧撑爆,而那正是闸 2 要防的。
var JOB_QUANTUM = 2048;        // 一个量子的格数:小到慢机器上一帧也撑不爆(它是超调的上界)
var JOB_QUANTA = 4096;         // 一轮的量子额度。★ 取得故意大:一轮结束必须是因为预算到点,而不是因为"条数跑完了"。
function runJob(job, onApply, label) {
  var slicer = Render.createSlicer({});
  var done = false, total = 0;
  function quantum() {
    if (done) return;
    var r = job.runChunk(JOB_QUANTUM);
    total = r.total;
    if (r.done) { done = true; return; }
    status((label || '处理中') + ' … ' + total);
  }
  function pass() {
    if (done) return Promise.resolve();
    return slicer.run(new Array(JOB_QUANTA), quantum).then(pass);
  }
  return pass().then(function () { onApply(total); });
}
