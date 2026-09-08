'use strict';
// 从 data/enemies.json 重新生成 structure-editor.html 内嵌的敌人注册表
// (/*__ENEMY_REGISTRY_BEGIN__*/ ... /*__ENEMY_REGISTRY_END__*/ 之间)。
// 用法:node level_editor/sync-enemies.js
const fs = require('fs');
const path = require('path');

const dir = __dirname;
const jsonPath = path.join(dir, '..', 'data', 'enemies.json');
const htmlPath = path.join(dir, 'structure-editor.html');

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

let html = fs.readFileSync(htmlPath, 'utf8');
const re = /\/\*__ENEMY_REGISTRY_BEGIN__\*\/[\s\S]*?\/\*__ENEMY_REGISTRY_END__\*\//;
if (!re.test(html)) {
  console.error('FAIL: 未在 HTML 找到注册表标记 /*__ENEMY_REGISTRY_BEGIN__*/');
  process.exit(1);
}
html = html.replace(re, block);
fs.writeFileSync(htmlPath, html);
console.log('ok: 敌人注册表已同步 ' + enemies.map(function (e) { return e.id; }).join(', '));
