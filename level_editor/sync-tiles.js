'use strict';
// 从 data/tile_defs.json 重新生成 level_editor/tile_defs.js(编辑器打包副本)。
// tile_defs.js 以 <script src> 方式加载(window.TILE_DEFS),file:// 下也可靠。
// 用法:node level_editor/sync-tiles.js [--check]
//   --check: 仅校验不写入。若与 data/tile_defs.json 不一致则退出码为 1。
const fs = require('fs');
const path = require('path');

const jsonPath = path.join(__dirname, '..', 'data', 'tile_defs.json');
const jsPath = path.join(__dirname, 'tile_defs.js');

const json = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const body = '// 由 sync-tiles.js 从 data/tile_defs.json 生成;改配置请改 JSON 再跑一次。\n' +
  'window.TILE_DEFS = ' + JSON.stringify(json, null, 2) + ';\n';
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
