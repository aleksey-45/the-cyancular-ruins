// ui/25_spawn.js —— 出生点与敌人的增删与差量。


// ── 出生点与敌人(★ A9:它们的增删也要进历史)──
function snapshotSpawns(map) {
  return {
    players: map.players.map(function (p) { return { x: p.x, y: p.y }; }),
    enemies: map.enemies.map(function (e) { return { type: e.type, x: e.x, y: e.y }; }),
  };
}
function spawnDiff(before, after) {
  return { kind: 'spawn', before: before, after: after };
}
function spawnIndexAt(map, cellX, cellY, kind) {
  var x = Render.wrapIdx(Math.floor(cellX), Core.cellsWOf(map));
  var y = Render.wrapIdx(Math.floor(cellY), Core.cellsHOf(map));
  var i;
  if (kind !== 'enemy') {
    for (i = 0; i < map.players.length; i++) {
      if (map.players[i].x === x && map.players[i].y === y) return { kind: 'player', index: i };
    }
  }
  if (kind !== 'player') {
    for (i = 0; i < map.enemies.length; i++) {
      if (map.enemies[i].x === x && map.enemies[i].y === y) return { kind: 'enemy', index: i };
    }
  }
  return null;
}
function addSpawn(map, kind, cellX, cellY, enemyType) {
  var before = snapshotSpawns(map);
  var x = Render.wrapIdx(Math.floor(cellX), Core.cellsWOf(map));
  var y = Render.wrapIdx(Math.floor(cellY), Core.cellsHOf(map));
  if (kind === 'enemy') map.enemies.push({ type: String(enemyType || 'fly_bird'), x: x, y: y });
  else map.players.push({ x: x, y: y });
  return spawnDiff(before, snapshotSpawns(map));
}
function removeSpawn(map, kind, index) {
  var before = snapshotSpawns(map);
  if (kind === 'enemy') { if (index < 0 || index >= map.enemies.length) return null; map.enemies.splice(index, 1); }
  else { if (index < 0 || index >= map.players.length) return null; map.players.splice(index, 1); }
  return spawnDiff(before, snapshotSpawns(map));
}
function clearSpawns(map) {
  var before = snapshotSpawns(map);
  map.players = []; map.enemies = [];
  return spawnDiff(before, snapshotSpawns(map));
}
