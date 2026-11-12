'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
require('../level_editor/tile_defs.js');
require('../level_editor/core.js');
const server = require('../level_editor/editor_server.js');
const MapFiles = require('../level_editor/map_files.js');
const Core = globalThis.Core;

async function run() {
  const map = Core.createMap('roundtrip', 3, 2);
  map.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(19);
  map.players = [{slot: 2, x: 2, y: 1}, {slot: 1, x: 1, y: 1}];
  map.respawns = [{side: 1, x: 2, y: 0}, {side: 2, x: 1, y: 0}, {side: 1, x: 0, y: 1}];
  map.comments = ['roundtrip note'];
  for (const compress of [false, true]) {
    const bytes = await Core.encodeMap(map, {compress});
    const decoded = await Core.decodeMap(bytes);
    assert.deepEqual(decoded.layers, map.layers);
    assert.deepEqual(decoded.players, map.players);
    assert.deepEqual(decoded.respawns, map.respawns);
    assert.deepEqual(decoded.comments, map.comments);
    assert.equal(decoded.subCols, map.subCols);
    assert.equal(decoded.subRows, map.subRows);
    const corrupted = bytes.slice();
    corrupted[10] ^= 1;
    await assert.rejects(Core.decodeMap(corrupted));
  }
  const points = Core.parseMeta('# player2 2 0\n# player 1 0\n');
  assert.deepEqual(points.players, [{slot: 2, x: 2, y: 0}, {slot: 1, x: 1, y: 0}]);
  assert.equal(Core.buildMeta(points), '# player2 2 0\n# player 1 0\n');
  const legacy = Core.createMap('legacy', 1, 1);
  legacy.players = [{slot: 2, x: 0, y: 0}];
  const desc = Core.packDesc(15, 1, 6, 5, 2);
  for (const layer of legacy.layers.slice(0, 3)) layer.desc[0] = desc;
  legacy.layers[Core.LAYER_BG].rgba[0] = 0x12345678;
  const legacyBytes = await Core.encodeMap(legacy, {compress: false});
  const body = legacyBytes.subarray(Core.HEADER_SIZE);
  const view = new DataView(body.buffer, body.byteOffset, body.byteLength);
  let offset = 2 + view.getUint16(0, true);
  for (let layer = 0; layer < 3; layer++) {
    const entries = view.getUint16(offset + 1, true);
    view.setUint32(offset + 7, Core.packDesc(16, 3, 6, 5, 2), true);
    offset += 4 + entries * 4 + legacy.subCols * legacy.subRows;
  }
  new DataView(legacyBytes.buffer, legacyBytes.byteOffset).setUint32(10, Core.crc32(body), true);
  const migrated = await Core.decodeMap(legacyBytes);
  assert.deepEqual(migrated.layers, legacy.layers);
  assert.deepEqual(migrated.players, legacy.players);
  const saved = await Core.encodeMap(migrated, {compress: false});
  assert.notDeepEqual(saved, legacyBytes);
  assert.deepEqual((await Core.decodeMap(saved)).layers, migrated.layers);
  const shipped = fs.readFileSync(path.join(__dirname, '../maps/newfactory.cyrm'));
  const factory = await Core.decodeMap(shipped);
  assert.ok(factory.layers[Core.LAYER_SCENE].desc.length > 0);
  assert.ok(factory.respawns.filter(r => r.side === 1).length >= 5);
  assert.ok(factory.respawns.filter(r => r.side === 2).length >= 5);
  assert.ok(factory.comments.every(c => !c.startsWith('respawn ')));
  const invalid = Object.assign(Core.createMap('invalid_respawns', 2, 2),
    Core.parseMeta('# respawn 1 0 0\n# respawn 2 0 0\n# respawn 2 2 0\n# respawn 1 0x1 0\n'));
  const warnings = Core.validateMap(invalid).warnings.join('\n');
  assert.match(warnings, /复活点.*重合/);
  assert.match(warnings, /复活点.*越界/);
  assert.match(warnings, /复活点格式无效/);
  assert.deepEqual(invalid.comments, ['respawn 1 0x1 0']);
  await assert.rejects(Core.decodeMap(new TextEncoder().encode('# cyrm-v3\n001F\n')));
  const text = new TextEncoder();
  const imported = await Core.importMap(text.encode('#cyrm-v3\n# respawn 1 0 0\n0029\n'));
  assert.equal(imported.format, 'v3');
  assert.deepEqual(imported.map.respawns, [{side: 1, x: 0, y: 0}]);
  assert.equal(imported.map.layers[1].desc[0], Core.migrateDescriptor(Core.neutralDesc(2)));
  assert.equal(imported.map.layers[1].desc[2], 0);
  assert.equal(imported.map.layers[1].desc[15], imported.map.layers[1].desc[0]);
  const character = await Core.importMap(text.encode('# player 1 1\n2A\n01\n'));
  assert.equal(character.format, 'legacy');
  assert.deepEqual(character.map.players, [{slot: 1, x: 0, y: 0}]);
  assert.equal(character.map.layers[1].desc[2], imported.map.layers[1].desc[0]);
  assert.equal(character.map.layers[1].desc[8], 0);
  await assert.rejects(Core.importMap(text.encode('12\n1\n')));
  await assert.rejects(Core.importMap(text.encode('# cyrm-v5\n001F\n')));
  const unknown = Core.createMap('unknown', 1, 1);
  unknown.layers[Core.LAYER_BACK].desc[0] = Core.neutralDesc(999);
  await assert.rejects(Core.encodeMap(unknown), /999/);
  const outside = Core.createMap('outside', 2, 2);
  outside.players = [{slot: 1, x: 2, y: 0}];
  await assert.rejects(Core.encodeMap(outside), /出生点 P1.*越界/);
  outside.players = [];
  outside.enemies = [{type: 'jump_bird', x: 1, y: -1}];
  await assert.rejects(Core.encodeMap(outside), /敌人.*越界/);
  assert.ok(server.isValidMapName('arena.cyrm'));
  assert.ok(!server.isValidMapName('arena.v3.bak'));
  const downloads = [];
  const store = MapFiles.downloads((name, bytes) => downloads.push([name, bytes]));
  await store.write('arena.cyrm', saved, {create: true});
  await assert.rejects(store.write('arena.cyrm', legacyBytes, {create: true}), /同名/);
  assert.deepEqual(downloads, [['arena.cyrm', saved]]);
  assert.deepEqual(await store.read('arena.cyrm'), saved);
  await assert.rejects(store.read('arena.v3.bak'));

  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cyrm-editor-case-'));
  try {
    await server.writeMapAtomic(directory, 'arena.cyrm', legacyBytes, {create: true});
    await assert.rejects(server.writeMapAtomic(directory, 'arena.cyrm', saved, {create: true}), {code: 'EEXIST'});
    const result = await server.writeMapAtomic(directory, 'arena.cyrm', saved, {backup: true});
    assert.deepEqual(fs.readFileSync(path.join(directory, result.backup)), Buffer.from(legacyBytes));
    assert.deepEqual(fs.readFileSync(path.join(directory, result.name)), Buffer.from(saved));
  } finally {
    for (const name of fs.readdirSync(directory)) fs.unlinkSync(path.join(directory, name));
    fs.rmdirSync(directory);
  }
  console.log('CHECK editor PASS');
}

run().catch(error => { console.error(error); process.exitCode = 1; });
