'use strict';
// 根据 data/tile_defs.json 生成材质表。编辑器页面、Web Worker 和离线版都通过 globalThis.TILE_DEFS 读取该表。
// --check 只校验文件内容。现有材质表与生成结果不一致时，退出码为 1。
const fs = require('fs');
const path = require('path');

const jsonPath = path.join(__dirname, '..', 'data', 'tile_defs.json');
const jsPath = path.join(__dirname, 'tile_defs.js');

const json = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const body = '// 关卡编辑器读取的瓦片属性来自 data/tile_defs.json。\n' +
  'globalThis.TILE_DEFS = ' + JSON.stringify(json, null, 2) + ';\n';
const tileCount = Object.keys(json.tiles || {}).length;

if (process.argv.includes('--check')) {
  const norm = function (s) { return s.replace(/\r\n/g, '\n'); };
  const actual = fs.existsSync(jsPath) ? fs.readFileSync(jsPath, 'utf8') : null;
  if (actual === null) {
    console.error('FAIL: level_editor/tile_defs.js 不存在 —— 跑 `node level_editor/sync-tiles.js` 生成');
    process.exit(1);
  }
  if (norm(actual) === norm(body)) {
    console.log('ok: level_editor/tile_defs.js 与 data/tile_defs.json 一致(纹理数 ' + tileCount + ')');
    process.exit(0);
  }
  console.error('FAIL: level_editor/tile_defs.js 已漂移 —— 跑 `node level_editor/sync-tiles.js` 重新生成');
  const a = norm(actual).split('\n');
  const b = norm(body).split('\n');
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      console.error('  第 ' + (i + 1) + ' 行');
      console.error('    盘上: ' + String(a[i]).slice(0, 120));
      console.error('    应为: ' + String(b[i]).slice(0, 120));
      break;
    }
  }
  process.exit(1);
}

fs.writeFileSync(jsPath, body);
console.log('ok: level_editor/tile_defs.js 已同步(纹理数 ' + tileCount + ')');
