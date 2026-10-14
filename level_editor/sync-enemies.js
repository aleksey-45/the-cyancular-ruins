'use strict';
// 从 data/enemies.json 重新生成 editor.html 内嵌的敌人注册表
// (/*__ENEMY_REGISTRY_BEGIN__*/ ... /*__ENEMY_REGISTRY_END__*/ 之间)。
// 用法:node level_editor/sync-enemies.js [--check]
//   --check: 仅校验不写入。若与 data/enemies.json 不一致则退出码为 1。
const fs = require('fs');
const path = require('path');

const dir = __dirname;
const jsonPath = path.join(dir, '..', 'data', 'enemies.json');
const htmlPath = path.join(dir, 'editor.html');

const json = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const enemies = (json.enemies || []).map(function (e) {
  return {
    id: String(e.id),
    name: String(e.name),
    scene: String(e.scene),
    color: String(e.color || '#999999')
  };
});
const block = '/*__ENEMY_REGISTRY_BEGIN__*/\nwindow.ENEMY_REGISTRY = ' +
  JSON.stringify(enemies, null, 2) + ';\n/*__ENEMY_REGISTRY_END__*/';

// 字段覆盖校验：确保 enemies.json 中的字段均映射至注册表
const NOT_IN_EDITOR = [];   // 暂无忽略字段: enemies.json 的 4 个字段全部进入注册表
const generatedKeys = {};
enemies.forEach(function (e) { Object.keys(e).forEach(function (k) { generatedKeys[k] = true; }); });
const dropped = {};
(json.enemies || []).forEach(function (e) {
  Object.keys(e).forEach(function (k) {
    if (!generatedKeys[k] && NOT_IN_EDITOR.indexOf(k) < 0) dropped[k] = true;
  });
});
if (Object.keys(dropped).length) {
  console.error('FAIL: data/enemies.json 里有字段没被抄进注册表: ' + Object.keys(dropped).join(', '));
  console.error('      要么在 map 里带上它,要么加进 NOT_IN_EDITOR 并写明理由。');
  process.exit(1);
}

let html = fs.readFileSync(htmlPath, 'utf8');
const re = /\/\*__ENEMY_REGISTRY_BEGIN__\*\/[\s\S]*?\/\*__ENEMY_REGISTRY_END__\*\//;
if (!re.test(html)) {
  console.error('FAIL: 未在 HTML 找到注册表标记 /*__ENEMY_REGISTRY_BEGIN__*/');
  process.exit(1);
}

if (process.argv.includes('--check')) {
  const norm = function (s) { return s.replace(/\r\n/g, '\n'); };
  const actual = norm(html.match(re)[0]);
  const expected = norm(block);
  if (actual === expected) {
    console.log('ok: editor.html 的敌人注册表与 data/enemies.json 一致(' +
      enemies.map(function (e) { return e.id; }).join(', ') + ')');
    process.exit(0);
  }
  console.error('FAIL: editor.html 的敌人注册表已漂移 —— 跑 `node level_editor/sync-enemies.js` 重新生成');
  const a = actual.split('\n');
  const b = expected.split('\n');
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      console.error('  注册表块第 ' + (i + 1) + ' 行');
      console.error('    盘上: ' + String(a[i]).slice(0, 120));
      console.error('    应为: ' + String(b[i]).slice(0, 120));
      break;
    }
  }
  process.exit(1);
}

html = html.replace(re, block);
fs.writeFileSync(htmlPath, html);
console.log('ok: 敌人注册表已同步 ' + enemies.map(function (e) { return e.id; }).join(', '));
