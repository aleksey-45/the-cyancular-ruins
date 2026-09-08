'use strict';
// 从 data/tile_defs.json 重新生成 level_editor/tile_defs.js(编辑器打包副本)。
// tile_defs.js 以 <script src> 方式加载(window.TILE_DEFS),file:// 下也可靠。
// 用法:node level_editor/sync-tiles.js
const fs = require('fs');
const path = require('path');

const jsonPath = path.join(__dirname, '..', 'data', 'tile_defs.json');
const jsPath = path.join(__dirname, 'tile_defs.js');

const json = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const body = '// 由 sync-tiles.js 从 data/tile_defs.json 生成;改配置请改 JSON 再跑一次。\n' +
  'window.TILE_DEFS = ' + JSON.stringify(json, null, 2) + ';\n';
fs.writeFileSync(jsPath, body);
console.log('ok: level_editor/tile_defs.js 已同步(纹理数 ' +
  Object.keys(json.tiles || {}).length + ')');
