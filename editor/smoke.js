'use strict';

// Node smoke test for Structure Editor of CyR.
// Extracts the <script> blocks from structure-editor.html, evaluates them in a
// DOM-free context, and exercises the pure functions exposed as globalThis.Core.
//
// Run: node smoke.js

const fs = require('fs');
const path = require('path');

const htmlPath = path.join(__dirname, 'structure-editor.html');
const html = fs.readFileSync(htmlPath, 'utf8');

const scripts = [];
const scriptRe = /<script\b[^>]*>([\s\S]*?)<\/script>/g;
let m;
while ((m = scriptRe.exec(html)) !== null) {
  if (!/src\s*=/.test(m[0])) scripts.push(m[1]);
}

// DOM-free shim: the UI script guards boot() on document existence, so it stays inert.
const fakeWindow = { document: null };
for (const src of scripts) {
  try {
    new Function('window', 'document', src)(fakeWindow, null);
  } catch (err) {
    console.error('脚本执行失败（可能是语法错误）:', err.message);
    process.exit(1);
  }
}

const Core = globalThis.Core;
if (!Core) {
  console.error('FAIL: 未从 HTML 中加载到 Core。请确认 structure-editor.html 内含 globalThis.Core = ...');
  process.exit(1);
}

let pass = 0;
let fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function throws(fn, msg) {
  let threw = false;
  try { fn(); } catch (e) { threw = true; }
  if (threw) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); }
}

// ---- Task 1: sanitizeName / validateGrid ----
eq(Core.sanitizeName('My Tower #1'), 'My_Tower_1', 'sanitizeName: 非法字符被清理');
eq(Core.sanitizeName('   spaced   name  '), 'spaced_name', 'sanitizeName: 空格合并为下划线');
eq(Core.sanitizeName('---'), 'structure', 'sanitizeName: 全非法回落默认名');
eq(Core.sanitizeName(''), 'structure', 'sanitizeName: 空名回落');
eq(Core.sanitizeName('-lead'), 'lead', 'sanitizeName: 去掉开头连字符');
eq(Core.sanitizeName('塔楼 #1'), '塔楼_1', 'sanitizeName: 保留中文');

eq(Core.validateGrid([[0, 1], [1, 9]]), { ok: true, error: '' }, 'validateGrid: 合法 0–9');
eq(Core.validateGrid([[0]]), { ok: true, error: '' }, 'validateGrid: 1×1 合法');
eq(Core.validateGrid([[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]]), { ok: true, error: '' }, 'validateGrid: 全部 0–9 值合法');
eq(Core.validateGrid([[0, 335]]), { ok: true, error: '' }, 'validateGrid: packed 0-335 合法');
eq(Core.validateGrid([[336]]).ok, false, 'validateGrid: packed >335 非法');
eq(Core.validateGrid([[0], [1, 2]]).ok, false, 'validateGrid: 宽度不一致');
eq(Core.validateGrid([[0, -1]]).ok, false, 'validateGrid: 负值非法');
eq(Core.validateGrid([['x']]).ok, false, 'validateGrid: 非数字非法');
eq(Core.validateGrid([]).ok, false, 'validateGrid: 空网格非法');

// ---- resizeGrid ----
eq(Core.resizeGrid([[1, 2], [3, 4]], 3, 2), [[1, 2, 0], [3, 4, 0]], 'resizeGrid: 加宽补 0');
eq(Core.resizeGrid([[1, 2, 3], [4, 5, 6]], 2, 1), [[1, 2]], 'resizeGrid: 裁剪');
eq(Core.resizeGrid([[1], [2]], 1, 3), [[1], [2], [0]], 'resizeGrid: 加高补 0');
eq(Core.resizeGrid([], 2, 2), [[0, 0], [0, 0]], 'resizeGrid: 从空网格扩展');

// ---- Task 3: rectFill / floodFill ----
eq(Core.rectFill([[0, 0, 0], [0, 0, 0], [0, 0, 0]], 1, 0, 1, 2, 5), [[0, 5, 0], [0, 5, 0], [0, 5, 0]], 'rectFill: 竖线');
eq(Core.rectFill([[0, 0, 0], [0, 0, 0], [0, 0, 0]], 2, 2, 0, 0, 9), [[9, 9, 9], [9, 9, 9], [9, 9, 9]], 'rectFill: 反向角矩形');
eq(Core.rectFill([[1, 1], [1, 1]], 0, 0, 1, 1, 0), [[0, 0], [0, 0]], 'rectFill: 擦除整块');

eq(Core.floodFill([[0, 0, 1], [0, 1, 1], [1, 1, 1]], 0, 0, 2), [[2, 2, 1], [2, 1, 1], [1, 1, 1]], 'floodFill: 填充连通区');
eq(Core.floodFill([[0, 0, 1], [0, 1, 1], [1, 1, 1]], 0, 0, 0), [[0, 0, 1], [0, 1, 1], [1, 1, 1]], 'floodFill: 同值不修改');
eq(Core.floodFill([[1, 1], [1, 0]], 0, 0, 9), [[9, 9], [9, 0]], 'floodFill: 从角落扩展');

// ---- Task: v3 整图格式 parseMap / serializeMap ----
const mapText = '# cyrm-v3\n# demo\n# player 12 34\n# enemy jump_bird 100 50\n0000001F0031\n';
const parsedMap = Core.parseMap(mapText);
eq(parsedMap.players, [{ x: 12, y: 34 }], 'parseMap v3: players');
eq(parsedMap.enemies, [{ type: 'jump_bird', x: 100, y: 50 }], 'parseMap v3: enemy');
eq(parsedMap.grid, [[0, 31, 49]], 'parseMap v3: 网格 0/31(全砖)/49(纹理3左上1/4)');
eq(parsedMap.comments, ['demo'], 'parseMap v3: 普通 # 注释保留(标记行不算注释)');
eq(Core.serializeMap(parsedMap), mapText, 'v3 parseMap→serializeMap round-trip');
throws(() => Core.parseMap('# cyrm-v3\n0000\n000x\n'), 'parseMap v3: 非法形状字符报错');
throws(() => Core.parseMap('# cyrm-v3\n0000\n00000000\n'), 'parseMap v3: 宽度不一致报错');
throws(() => Core.parseMap('# cyrm-v3\n0000\n00000\n'), 'parseMap v3: 字符数非 4 倍数报错');
// 旧格式自动转换(无标记,单字符):2×2 全实心 → 全砖 31,spawn ÷2
const oldParsed = Core.parseMap('# old\n# player 112 95\n11\n11\n');
eq(oldParsed.players, [{ x: 56, y: 47 }], 'parseMap old: players ÷2');
eq(oldParsed.grid, [[31]], 'parseMap old: 2×2 全实心 → 全砖 31');
eq(Core.serializeMap(oldParsed), '# cyrm-v3\n# old\n# player 56 47\n001F\n', '旧图转换后导出 v3');

// ---- Task: 敌人注册表(HTML 内嵌,来自 enemies.json)----
ok(Array.isArray(fakeWindow.ENEMY_REGISTRY) && fakeWindow.ENEMY_REGISTRY.length >= 2,
  'ENEMY_REGISTRY 已内嵌且含敌人');
var regIds = (fakeWindow.ENEMY_REGISTRY || []).map(function (e) { return e.id; });
ok(regIds.indexOf('jump_bird') >= 0 && regIds.indexOf('fly_bird') >= 0,
  'ENEMY_REGISTRY 含 jump_bird / fly_bird');
ok((fakeWindow.ENEMY_REGISTRY || []).every(function (e) {
  return e.id && e.name && e.scene && e.color;
}), 'ENEMY_REGISTRY 每项含 id/name/scene/color');

// ---- Final review: format-contract pins ----
eq(Core.validateGrid([null]).ok, false, 'validateGrid: 首行 null 报错');
eq(Core.validateGrid([42]).ok, false, 'validateGrid: 首行非数组报错');

// ---- brushOffsets: 画笔块偏移(偶数尺寸不缩小,回归 2026-08-22 修复)----
eq(Core.brushOffsets(1), { lo: 0, hi: 0 }, 'brushOffsets: 1 → 1×1');
eq(Core.brushOffsets(2), { lo: 0, hi: 1 }, 'brushOffsets: 2 → 2×2(偏下右)');
eq(Core.brushOffsets(3), { lo: 1, hi: 1 }, 'brushOffsets: 3 → 3×3');
eq(Core.brushOffsets(4), { lo: 1, hi: 2 }, 'brushOffsets: 4 → 4×4(偏下右)');
eq(Core.brushOffsets(5), { lo: 2, hi: 2 }, 'brushOffsets: 5 → 5×5');
eq(Core.brushOffsets(15), { lo: 7, hi: 7 }, 'brushOffsets: 15 → 15×15');
(function () {
  var bad = false;
  for (var s = 1; s <= 15; s++) {
    var o = Core.brushOffsets(s);
    if (!o || o.lo + o.hi + 1 !== s || o.lo < 0 || o.hi < o.lo) bad = true;
  }
  ok(!bad, 'brushOffsets: 1..15 全部满足 lo+1+hi===尺寸 且 lo≤hi');
})();

// ---- Task: lineCells / normRegion / moveRegion(直线 + 选框工具) ----
eq(Core.lineCells(0, 0, 4, 0), [[0,0],[1,0],[2,0],[3,0],[4,0]], 'lineCells: 水平线');
eq(Core.lineCells(2, 2, 2, 5), [[2,2],[2,3],[2,4],[2,5]], 'lineCells: 垂直线');
eq(Core.lineCells(0, 0, 2, 2), [[0,0],[1,1],[2,2]], 'lineCells: 对角线');
eq(Core.lineCells(4, 0, 0, 0), [[4,0],[3,0],[2,0],[1,0],[0,0]], 'lineCells: 反向水平');
eq(Core.lineCells(1, 1, 1, 1), [[1,1]], 'lineCells: 单点');
eq(Core.lineCells(0, 0, 4, 2), [[0,0],[1,0],[2,1],[3,1],[4,2]], 'lineCells: 缓坡 Bresenham 锚定');
(function () {
  var last = Core.lineCells(3, 5, 7, 9);
  ok(last[last.length - 1][0] === 7 && last[last.length - 1][1] === 9, 'lineCells: 终点含在内');
})();

eq(Core.normRegion(3, 2, 1, 5), { x: 1, y: 2, w: 3, h: 4 }, 'normRegion: 反向角归一化');
eq(Core.normRegion(1, 1, 1, 1), { x: 1, y: 1, w: 1, h: 1 }, 'normRegion: 单格');

eq(Core.moveRegion([[1,2,3],[4,5,6],[7,8,9]], {x:0,y:0,w:1,h:1}, 1, 1),
   [[0,2,3],[4,1,6],[7,8,9]], 'moveRegion: 单格平移,原处清 0');
eq(Core.moveRegion([[1,2,3],[4,5,6],[7,8,9]], {x:1,y:1,w:1,h:1}, 0, -1),
   [[1,5,3],[4,0,6],[7,8,9]], 'moveRegion: 上移一格,只清原格');
eq(Core.moveRegion([[1,1],[1,1]], {x:0,y:0,w:2,h:2}, -1, 0),
   [[1,0],[1,0]], 'moveRegion: 左移 1,右列保留其余裁剪');
eq(Core.moveRegion([[1,1],[1,1]], {x:0,y:0,w:2,h:2}, -2, 0),
   [[0,0],[0,0]], 'moveRegion: 整体移出左侧,裁剪为空');
eq(Core.moveRegion([[1,1,1],[1,1,1],[1,1,1]], {x:0,y:0,w:2,h:2}, 1, 1),
   [[0,0,1],[0,1,1],[1,1,1]], 'moveRegion: 重叠位移,快照内容不被清');
(function () {
  var g = [[1,1],[1,1]];
  Core.moveRegion(g, {x:0,y:0,w:2,h:2}, 1, 1);
  eq(g, [[1,1],[1,1]], 'moveRegion: 不修改入参');
})();

// ---- Task: 矩形工具回归(填 packed 值而非纹理号) ----
eq(Core.rectFill([[0,0],[0,0]], 0, 0, 1, 1, Core.packCell(1, 15)), [[31,31],[31,31]], 'rectFill: packed 全砖(矩形工具回归)');

// ---- Task: 统一结构的 JSON 库 / 单结构地图导出 ----
(function () {
  var lib = [
    { id: 1, name: 'demo_2', grid: [[0, 0, 1], [0, 1, 9]], player: { x: 0, y: 1 },
      enemies: [{ type: 'jump_bird', x: 2, y: 0 }] },
    { id: 2, name: 'tower', grid: [[1, 1], [1, 1]], player: null, enemies: [] }
  ];
  var json = Core.serializeLibraryJSON(lib);
  eq(JSON.parse(json).version, 1, 'serializeLibraryJSON: 带 version');
  var back = Core.parseLibraryJSON(json);
  eq(back.length, 2, 'parseLibraryJSON: 数量');
  eq(back[0].name, 'demo_2', 'parseLibraryJSON: 名字');
  eq(back[0].grid, [[0, 0, 1], [0, 1, 9]], 'parseLibraryJSON: 0-9 网格原样');
  eq(back[0].players, [{ x: 0, y: 1 }], 'parseLibraryJSON: players');
  eq(back[0].enemies, [{ type: 'jump_bird', x: 2, y: 0 }], 'parseLibraryJSON: enemies');
  eq(back[1].players, [], 'parseLibraryJSON: 无 player 为 []');
  throws(function () { Core.parseLibraryJSON('{bad json'); }, 'parseLibraryJSON: 坏 JSON 报错');
  throws(function () { Core.parseLibraryJSON('{}'); }, 'parseLibraryJSON: 缺 structures 报错');

  var ms = { id: 9, name: 'levels', grid: [[0, 31, 159, 175], [0, 0, 31, 31]],
    player: { x: 0, y: 0 }, enemies: [{ type: 'fly_bird', x: 3, y: 1 }] };
  var text = Core.serializeMapStructure(ms);
  eq(text.split('\n')[0], '# cyrm-v3', 'serializeMapStructure: v3 标记');
  eq(text.indexOf('# levels') >= 0, true, 'serializeMapStructure: 名字行');
  eq(text.indexOf('# player 0 0') >= 0, true, 'serializeMapStructure: player 行');
  eq(text.indexOf('# enemy fly_bird 3 1') >= 0, true, 'serializeMapStructure: enemy 行');
  eq(text.indexOf('0000001F009F010F\n00000000001F001F') >= 0, true, 'serializeMapStructure: packed 序列化 0/31/159/175');

  var es = Core.createEmptyStructure(3, 2);
  eq(es.grid, [[0, 0, 0], [0, 0, 0]], 'createEmptyStructure: 全 0');
  eq(es.players, [], 'createEmptyStructure: 无 player');
  eq(es.enemies.length, 0, 'createEmptyStructure: 无 enemies');
  eq(Core.serializeMapStructure({ id: 1, name: 'blank', grid: es.grid, player: es.player, enemies: es.enemies }),
    '# cyrm-v3\n# blank\n000000000000\n000000000000\n', 'createEmptyStructure→serializeMapStructure: 空图可导出(v3)');
})();

console.log('');
console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
