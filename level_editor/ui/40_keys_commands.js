// ui/40_keys_commands.js —— 热键表与命令分派。

// ── 热键表(规格 §4.8)──
// ★ 纯函数:输入事件对象的一个子集 → 命令字符串。★ Ctrl 与 Cmd 一视同仁(本机工具,Mac 上是
//   Cmd);表外的键一律返回 null —— 返回 null 才是"不拦浏览器自己的快捷键"。
var KEY_TOOLS = { b: 'brush', e: 'eraser', g: 'bucket', l: 'line', m: 'select', i: 'picker' };
// ★ 判据取 tagName 与 isContentEditable,不取 ev.target === document.activeElement:
//   合成事件 / 焦点在 body 时 target 就是 body,那样的判据会把"按在画布上"也判成输入(热键失灵)。
function isTypingTarget(el) {
  if (!el || typeof el !== 'object') return false;
  var t = String(el.tagName == null ? '' : el.tagName).toLowerCase();
  if (t === 'input' || t === 'textarea' || t === 'select') return true;
  return el.isContentEditable === true;
}
function commandFor(ev) {
  var e = ev || {};
  var k = String(e.key == null ? '' : e.key).toLowerCase();
  var mod = !!(e.ctrl || e.meta);
  if (mod) {
    if (k === 'z') return e.shift ? 'redo' : 'undo';
    if (k === 'y') return 'redo';
    if (k === 'c') return 'copy';
    if (k === 'x') return 'cut';
    if (k === 'v') return 'paste';
    if (k === 's') return e.shift ? 'save-as' : 'save';
    return null;
  }
  if (KEY_TOOLS[k]) return 'tool:' + KEY_TOOLS[k];
  // ★ 镜像键是自选的(规格 §4.8 的热键表里没有它):H 水平 / V 垂直 —— 助记,且两个键在今天
  //   的全部绑定里都没被占(B/E/G/L/M/I 是工具、[ ] 是画笔、0-9 是图层、方向键平移、Del/Esc 选区;
  //   V 只被 Ctrl+V 占,而带修饰键的分支上面就 return 了,两条路不会撞)。
  if (k === 'h') return 'mirror:h';
  if (k === 'v') return 'mirror:v';
  if (k === '[') return 'brush-smaller';
  if (k === ']') return 'brush-bigger';
  if (k >= '0' && k <= '9') return 'layer:' + k;
  if (k === 'delete' || k === 'backspace') return 'clear-selection';
  if (k === 'escape') return 'cancel-selection';
  if (k === 'arrowleft' || k === 'arrowright' || k === 'arrowup' || k === 'arrowdown') {
    return 'pan:' + k.slice(5);
  }
  return null;
}
function hasSelection(st) { return !!(st && st.selection); }

// ── 历史(差量撤销;闸 1:200 步 + 字节预算)──
// ★ 差量而不是整图快照:一张 125×75 的图是 2.4MB,200 份就是 480MB。
// ★ 改尺寸/换图这类 table 级操作没法差量,故留一条整图快照的通道(kind:'whole')并按字节记账
//   —— 字节预算才是真闸,步数只是廉价上界。
var MAX_UNDO = 200;
var MAX_UNDO_BYTES = 64 * 1024 * 1024;

function bytesOfEntry(e) {
  if (!e) return 0;
  if (e.kind === 'cells') return 12 + e.idx.length * 4 + e.before.length * 4 + e.after.length * 4;
  if (e.kind === 'spawn') {
    var n = (e.before ? e.before.players.length + e.before.enemies.length : 0) +
            (e.after ? e.after.players.length + e.after.enemies.length : 0);
    return 64 + 32 * n;
  }
  if (e.kind === 'whole') return 64 + (e.bytes || 0);
  return 64;
}

function createHistory(opts) {
  opts = opts || {};
  var maxSteps = opts.maxSteps === undefined ? MAX_UNDO : opts.maxSteps;
  var maxBytes = opts.maxBytes === undefined ? MAX_UNDO_BYTES : opts.maxBytes;
  var undos = [], redos = [], total = 0;
  function trim() {
    while (undos.length > maxSteps) { total -= bytesOfEntry(undos.shift()); }
    // ★ 至少留一条:一条都留不住时"撤销"这个功能就整体失效了(比多占几 MB 更糟)
    while (total > maxBytes && undos.length > 1) { total -= bytesOfEntry(undos.shift()); }
  }
  return {
    push: function (e) {
      if (!e) return false;                       // 空操作不进历史
      undos.push(e); total += bytesOfEntry(e);
      redos.length = 0;                           // ★ 新编辑之后重做链断掉(标准语义)
      trim();
      return true;
    },
    undo: function () {
      if (!undos.length) return null;
      var e = undos.pop(); total -= bytesOfEntry(e);
      redos.push(e);
      return e;
    },
    redo: function () {
      if (!redos.length) return null;
      var e = redos.pop(); total += bytesOfEntry(e);
      undos.push(e);
      return e;
    },
    depth: function () { return undos.length; },
    redoDepth: function () { return redos.length; },
    bytes: function () { return total; },
    clear: function () { undos.length = 0; redos.length = 0; total = 0; },
  };
}

// 整图快照(只给"改尺寸/换图"这类整图级操作用)
function snapshotMap(map) {
  var layers = [];
  for (var L = 0; L < Core.LAYER_COUNT; L++) {
    var lay = map.layers[L];
    if (!lay) { layers.push(null); continue; }
    layers.push(lay.kind === 'tex' ? { kind: 'tex', desc: new Uint32Array(lay.desc) }
                                   : { kind: 'color', rgba: new Uint32Array(lay.rgba) });
  }
  var sp = snapshotSpawns(map);
  return { subCols: map.subCols, subRows: map.subRows, layers: layers,
           players: sp.players, enemies: sp.enemies, comments: map.comments.slice() };
}
function bytesOfSnapshot(s) {
  var n = 0;
  for (var L = 0; L < s.layers.length; L++) {
    var lay = s.layers[L];
    if (!lay) continue;
    n += (lay.kind === 'tex' ? lay.desc.length : lay.rgba.length) * 4;
  }
  return n;
}
