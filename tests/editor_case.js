'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
require('../level_editor/core.js');
const server = require('../level_editor/editor_server.js');
require('../level_editor/standalone_files.js');
const Core = globalThis.Core;

async function run() {
  const map = Core.createMap('roundtrip', 3, 2);
  map.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(19);
  map.players = [{x: 1, y: 1}, {x: 2, y: 1}];
  for (const compress of [false, true]) {
    const bytes = await Core.encodeMap(map, {compress});
    const decoded = await Core.decodeMap(bytes);
    assert.deepEqual(decoded.layers, map.layers);
    assert.deepEqual(decoded.players, map.players);
    assert.equal(decoded.subCols, map.subCols);
    assert.equal(decoded.subRows, map.subRows);
    const corrupted = bytes.slice();
    corrupted[10] ^= 1;
    await assert.rejects(Core.decodeMap(corrupted));
  }
  const shipped = fs.readFileSync(path.join(__dirname, '../maps/newfactory.cyrm'));
  assert.ok((await Core.decodeMap(shipped)).layers[Core.LAYER_SCENE].desc.length > 0);
  await assert.rejects(Core.decodeMap(new TextEncoder().encode('# cyrm-v3\n001F\n')));
  assert.ok(server.isValidMapName('arena.cyrm'));
  assert.ok(!server.isValidMapName('arena.v3.bak'));
  const store = globalThis.StandaloneFiles.createStore(async () => {});
  assert.equal((await store.request('/api/map?p=arena.v3.bak')).status, 400);
  console.log('CHECK editor PASS');
}

run().catch(error => { console.error(error); process.exitCode = 1; });
