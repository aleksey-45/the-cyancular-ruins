// core/40_meta.js —— 元数据段(JSON)编解码。


// meta 文本形状与游戏侧 MapFormat.parse_spawn_metadata() 对齐:先注释、再出生点、再**按侧复活点**、
// 最后敌人(规格 §3.2)。★ respawn 行按侧分组写(侧 1 全部在前、侧 2 在后):游戏侧按文件顺序去重,
// 顺序一变"首次出现生效"的那条也会变,故输出必须确定。
function buildMeta(map) {
  var lines = [];
  var i;
  for (i = 0; i < map.comments.length; i++) lines.push('# ' + map.comments[i]);
  for (i = 0; i < map.players.length; i++) {
    var kw = i === 0 ? 'player' : (i === 1 ? 'player2' : 'player' + (i + 1));
    lines.push('# ' + kw + ' ' + map.players[i].x + ' ' + map.players[i].y);
  }
  var rs = map.respawns || [];
  for (var side = 1; side <= 2; side++) {
    for (i = 0; i < rs.length; i++) {
      if (rs[i].side !== side) continue;
      lines.push('# respawn ' + side + ' ' + rs[i].x + ' ' + rs[i].y);
    }
  }
  for (i = 0; i < map.enemies.length; i++) {
    var e = map.enemies[i];
    lines.push('# enemy ' + e.type + ' ' + e.x + ' ' + e.y);
  }
  return lines.length ? lines.join('\n') + '\n' : '';
}

// 解析失败的行降级成注释,不丢掉 —— 编辑器不许静默吃掉用户写的东西(详见 docs/eng/editor-core.md)。
function parseMeta(text) {
  // 整数字面量(允许前导正负号):不用 isFinite,因为 parseInt 的前缀截断不是 NaN(3.5 / 7abc / 1e3 都会被静默改写)。
  var INT_TOKEN = /^[+-]?\d+$/;
  var players = [], enemies = [], respawns = [], comments = [];
  var lines = String(text == null ? '' : text).split(/\r?\n/);
  for (var i = 0; i < lines.length; i++) {
    var s = lines[i].trim();
    if (s === '') continue;
    if (s.charAt(0) !== '#') { comments.push(s); continue; }
    var body = s.slice(1).trim();
    var parts = body.split(/\s+/);
    var head = parts[0];
    if (/^player\d*$/.test(head) && parts.length >= 3) {
      if (INT_TOKEN.test(parts[1]) && INT_TOKEN.test(parts[2])) {
        players.push({ x: parseInt(parts[1], 10), y: parseInt(parts[2], 10) });
        continue;
      }
    } else if (head === 'respawn' && parts.length >= 4) {
      // ★ 侧号只认 1|2(与 map_format.gd 同口径);认不出的行**降级成注释**而不是丢掉。
      var side = parseInt(parts[1], 10);
      if ((parts[1] === '1' || parts[1] === '2') &&
          INT_TOKEN.test(parts[2]) && INT_TOKEN.test(parts[3])) {
        respawns.push({ side: side, x: parseInt(parts[2], 10), y: parseInt(parts[3], 10) });
        continue;
      }
    } else if (head === 'enemy' && parts.length >= 4) {
      if (INT_TOKEN.test(parts[2]) && INT_TOKEN.test(parts[3])) {
        enemies.push({ type: parts[1], x: parseInt(parts[2], 10), y: parseInt(parts[3], 10) });
        continue;
      }
    }
    comments.push(body);
  }
  return { players: players, enemies: enemies, respawns: respawns, comments: comments };
}
