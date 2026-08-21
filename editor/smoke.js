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
eq(Core.validateGrid([[0], [1, 2]]).ok, false, 'validateGrid: 宽度不一致');
eq(Core.validateGrid([[0, -1]]).ok, false, 'validateGrid: 负值非法');
eq(Core.validateGrid([['x']]).ok, false, 'validateGrid: 非数字非法');
eq(Core.validateGrid([]).ok, false, 'validateGrid: 空网格非法');

// ---- Task 2: serializeLibrary / parseLibrary / resizeGrid ----
const sample = [
  { name: 'tower_01', grid: [[0, 0, 1], [0, 1, 0], [1, 1, 1]] }
];
const text = Core.serializeLibrary(sample);
eq(text, '# tower_01\n001\n010\n111\n', 'serializeLibrary: 基本输出');
eq(Core.parseLibrary(text), sample, 'parseLibrary: round-trip');

eq(Core.parseLibrary('# a\n00\n11\n\n# b\n0\n1\n'), [
  { name: 'a', grid: [[0, 0], [1, 1]] },
  { name: 'b', grid: [[0], [1]] }
], 'parseLibrary: 多结构 + 空行');

eq(Core.parseLibrary('# x\n# 内联注释\n00\n'), [
  { name: 'x', grid: [[0, 0]] }
], 'parseLibrary: 裸注释行不打断结构');

eq(Core.parseLibrary('# 塔楼\n00\n')[0].name, '塔楼', 'parseLibrary: 中文名保留');
eq(Core.parseLibrary('# a\n'), [], 'parseLibrary: 只有名字没有数据则忽略');

throws(() => Core.parseLibrary('# a\n0a\n'), 'parseLibrary: 非法字符报错');
throws(() => Core.parseLibrary('00\n'), 'parseLibrary: 结构名之前的数据报错');
throws(() => Core.parseLibrary('# a\n00\n111\n'), 'parseLibrary: 宽度不一致报错');
throws(() => Core.serializeLibrary([{ name: 'bad', grid: [[0], [1, 2]] }]), 'serializeLibrary: 非法网格报错');

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

// ---- Task: 整图格式 parseMap / serializeMap ----
const mapText = '# demo\n# player 12 34\n# enemy jump_bird 100 50\n001\n010\n111\n';
const parsedMap = Core.parseMap(mapText);
eq(parsedMap.player, { x: 12, y: 34 }, 'parseMap: player');
eq(parsedMap.enemies, [{ type: 'jump_bird', x: 100, y: 50 }], 'parseMap: enemy');
eq(parsedMap.grid, [[0, 0, 1], [0, 1, 0], [1, 1, 1]], 'parseMap: 网格 0/1');
eq(parsedMap.comments, ['demo'], 'parseMap: 普通 # 注释保留');
eq(Core.serializeMap(parsedMap), mapText, 'parseMap→serializeMap round-trip');
throws(() => Core.parseMap('00\n0x\n'), 'parseMap: 网格含非 0/1 字符报错');
throws(() => Core.parseMap('00\n000\n'), 'parseMap: 宽度不一致报错');

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
const multiSample = [
  { name: 'a', grid: [[0, 1]] },
  { name: 'b', grid: [[2, 3], [4, 5]] }
];
eq(Core.parseLibrary(Core.serializeLibrary(multiSample)), multiSample, '多结构 serialize→parse 往返一致');
eq(Core.parseLibrary('# My Tower\n00\n')[0].name, 'My_Tower', 'parseLibrary: 结构名读取时净化');
eq(Core.parseLibrary('# x\n#\n00\n'), [{ name: 'x', grid: [[0, 0]] }], 'parseLibrary: 裸 # 注释行不打断结构');
eq(Core.validateGrid([null]).ok, false, 'validateGrid: 首行 null 报错');
eq(Core.validateGrid([42]).ok, false, 'validateGrid: 首行非数组报错');

console.log('');
console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
