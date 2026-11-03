// ui/25_spawn.js —— 出生点 / 按侧复活点 / 敌人的增删与差量。


// ── 出生点 / 复活点 / 敌人(★ A9:它们的增删也要进历史)──
// ★ respawns 是无序数组,但**同侧顺序有意义**(游戏侧按文件顺序去重、首次出现生效)⇒ 快照按数组顺序拷。
function snapshotSpawns(map) {
  return {
    players: map.players.map(function (p) { return { x: p.x, y: p.y }; }),
    enemies: map.enemies.map(function (e) { return { type: e.type, x: e.x, y: e.y }; }),
    respawns: (map.respawns || []).map(function (r) { return { side: r.side, x: r.x, y: r.y }; }),
  };
}
function spawnDiff(before, after) {
  return { kind: 'spawn', before: before, after: after };
}
// 从快照装回地图(撤销/重做与崩溃恢复共用;★ 重启字段不是整份替换 map)。
function applySpawns(map, snap) {
  if (!snap) return;
  map.players = (snap.players || []).map(function (p) { return { x: p.x, y: p.y }; });
  map.enemies = (snap.enemies || []).map(function (e) { return { type: e.type, x: e.x, y: e.y }; });
  map.respawns = (snap.respawns || []).map(function (r) { return { side: r.side, x: r.x, y: r.y }; });
}
function respawnCounts(map) {
  var out = { 1: 0, 2: 0 };
  var rs = (map && map.respawns) || [];
  for (var i = 0; i < rs.length; i++) if (out[rs[i].side] !== undefined) out[rs[i].side]++;
  return out;
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
  map.players = []; map.enemies = []; map.respawns = [];
  return spawnDiff(before, snapshotSpawns(map));
}

// ── 按侧复活点(`# respawn <1|2> <col> <row>`)──
// ★ 侧 1 = 左半(x < cellsW/2)、侧 2 = 右半 —— 与游戏侧 SpawnChooser.SIDE_LEFT/SIDE_RIGHT 同源。
//   放错半区**不拦**(地图作者可能故意这么干),由 validateMap 报 warning。
function sideOfCell(map, cellX) {
  var half = Core.cellsWOf(map) / 2;
  return Render.wrapIdx(Math.floor(cellX), Core.cellsWOf(map)) < half ? 1 : 2;
}
function addRespawn(map, side, cellX, cellY) {
  var before = snapshotSpawns(map);
  var x = Render.wrapIdx(Math.floor(cellX), Core.cellsWOf(map));
  var y = Render.wrapIdx(Math.floor(cellY), Core.cellsHOf(map));
  if (!map.respawns) map.respawns = [];
  map.respawns.push({ side: (side === 2 ? 2 : 1), x: x, y: y });
  return { diff: spawnDiff(before, snapshotSpawns(map)), x: x, y: y, side: (side === 2 ? 2 : 1) };
}
// 删"这一侧离 (cellX,cellY) 最近的那个点"(精确同格优先)。没有可删的返回 null。
function removeRespawnNear(map, side, cellX, cellY) {
  var rs = (map && map.respawns) || [];
  var x = Render.wrapIdx(Math.floor(cellX), Core.cellsWOf(map));
  var y = Render.wrapIdx(Math.floor(cellY), Core.cellsHOf(map));
  var bi = -1, bd = Infinity;
  for (var i = 0; i < rs.length; i++) {
    if (rs[i].side !== side) continue;
    var d = Math.abs(rs[i].x - x) + Math.abs(rs[i].y - y);
    if (d < bd) { bd = d; bi = i; }
  }
  if (bi < 0) return null;
  var before = snapshotSpawns(map);
  var at = { x: rs[bi].x, y: rs[bi].y };
  rs.splice(bi, 1);
  return { diff: spawnDiff(before, snapshotSpawns(map)), at: at };
}
function clearRespawns(map, side) {
  var rs = (map && map.respawns) || [];
  var keep = [];
  for (var i = 0; i < rs.length; i++) if (side && rs[i].side !== side) keep.push(rs[i]);
  if (keep.length === rs.length) return null;
  var before = snapshotSpawns(map);
  map.respawns = keep;
  return spawnDiff(before, snapshotSpawns(map));
}
