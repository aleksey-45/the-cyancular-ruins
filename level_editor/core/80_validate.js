// core/80_validate.js —— 尺寸钳制与整图校验。


// ── 尺寸上限(规格 §4.3 闸 1)──
// 旧编辑器的 clampMin(v, min, def) 第三参是"非数字时的默认值"而不是上限,
// 输 99999 就会去分配一张巨图然后卡死浏览器。这里给硬上限。
const MAX_CELLS_W = 400;
const MAX_CELLS_H = 300;
const DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;

function clampMapSize(w, h) {
  var wi = parseInt(w, 10), hi = parseInt(h, 10);
  if (!isFinite(wi)) wi = DEFAULT_CELLS_W;
  if (!isFinite(hi)) hi = DEFAULT_CELLS_H;
  return {
    w: Math.max(1, Math.min(MAX_CELLS_W, wi)),
    h: Math.max(1, Math.min(MAX_CELLS_H, hi)),
  };
}

// ── 导出前校验(规格 §4.7)──
// 只报告,不阻止导出 —— 编辑器不该替用户做决定。
// errors   = 真正非法,导出会产出坏文件
// warnings = 能导出,但游戏里大概不按你预期跑
function validateMap(map) {
  var errors = [], warnings = [];
  if (!map || !map.layers || map.layers.length !== LAYER_COUNT) {
    errors.push('图层数不是 ' + LAYER_COUNT);
    return { errors: errors, warnings: warnings };
  }
  if (map.subCols % SUB_PER_CELL !== 0 || map.subRows % SUB_PER_CELL !== 0) {
    errors.push('尺寸 ' + map.subCols + '×' + map.subRows + ' 不是 ' + SUB_PER_CELL + ' 的倍数');
  }
  var n = map.subCols * map.subRows;
  var L, layer;
  for (L = 0; L < LAYER_COUNT; L++) {
    layer = map.layers[L];
    if (!layer) continue;
    var arr = layer.kind === 'tex' ? layer.desc : layer.rgba;
    if (!arr || arr.length !== n) {
      errors.push(LAYER_NAMES[L] + '层长度不是 ' + map.subCols + '×' + map.subRows);
    }
  }
  if (errors.length) return { errors: errors, warnings: warnings };

  // ── 纹理合法性:desc 的 tex 非 0 且不在 tile_defs 键集 ⇒ error(encodeMap 只拒 errors)──
  // ★ 拦两类:① legacy 纹理 id(2,3,4,5,16,17,18 —— 新图集那 7 槽全透明;读时应已被
  //   95_legacy.js 迁移,内存里还有 = 有入口绕过了迁移);② 越界号(格式只保证 tex ≤ 4095)。
  // ★ TILE_DEFS 缺席(部分 node 冒烟只装 core)时跳过:没有表可判,别把"没表"当成"全非法"。
  var defs = globalThis.TILE_DEFS;
  if (defs && defs.tiles) {
    var knownTex = {};
    var texKeys = Object.keys(defs.tiles);
    for (var ki = 0; ki < texKeys.length; ki++) knownTex[texKeys[ki]] = true;
    for (L = 0; L < LAYER_COUNT; L++) {
      layer = map.layers[L];
      if (!layer || layer.kind !== 'tex' || !layer.desc) continue;
      var badTex = null;
      for (var di = 0; di < layer.desc.length; di++) {
        var tx = texOf(layer.desc[di]);
        if (tx === 0 || knownTex[tx]) continue;
        if (!badTex) badTex = {};
        badTex[tx] = true;
      }
      if (badTex) {
        errors.push(LAYER_NAMES[L] + '层有纹理 ' +
                    Object.keys(badTex).sort(function (a, b) { return a - b; }).join('/') +
                    ' 不在 tile_defs(legacy id 应在读时已迁移,越界号没有对应图集槽位)');
      }
    }
    if (errors.length) return { errors: errors, warnings: warnings };
  }

  var cellsW = map.subCols / SUB_PER_CELL, cellsH = map.subRows / SUB_PER_CELL;
  var scene = map.layers[LAYER_SCENE] ? map.layers[LAYER_SCENE].desc : null;

  // 出生点
  if (map.players.length === 0) {
    warnings.push('一个出生点都没有');
  }
  if (map.players.length > 2) {
    warnings.push('有 ' + map.players.length + ' 个出生点,但游戏只认前两个' +
                  '(第 3 个及以后在 map_format.gd 里读不到)');
  }
  var i;
  for (i = 0; i < map.players.length; i++) {
    warnings = warnings.concat(_checkSpawn(map.players[i], '出生点 P' + (i + 1),
                                          cellsW, cellsH, scene));
  }
  for (i = 0; i < map.enemies.length; i++) {
    warnings = warnings.concat(_checkSpawn(map.enemies[i], '敌人 ' + map.enemies[i].type,
                                          cellsW, cellsH, scene));
  }

  // 四层全空
  var allEmpty = true;
  for (L = 0; L < LAYER_COUNT && allEmpty; L++) {
    layer = map.layers[L];
    if (!layer) continue;
    var a = layer.kind === 'tex' ? layer.desc : layer.rgba;
    for (var k = 0; k < a.length; k++) if (a[k] !== 0) { allEmpty = false; break; }
  }
  if (allEmpty) warnings.push('四个图层全是空的');

  // 按阵营半区的复活点(`# respawn <1|2>`)
  warnings = warnings.concat(_checkRespawns(map, cellsW, cellsH, scene));
  return { errors: errors, warnings: warnings };
}

// ── 复活点判据(与游戏侧同源,常量见 core/sim/spawn_chooser.gd 与 tools/map_spawn_meta.gd)──
// ★ 全是 warning:编辑器只报告、不阻止保存(游戏侧自己对不合规的老图有回退路径)。
const RESPAWN_MIN_PER_SIDE = 5;      // 每侧最少点数(当前两张图各 9)
const RESPAWN_MIN_SIDE_GAP = 5;      // 同侧两两环面距离下限(格)
const RESPAWN_EDGE_MARGIN = 10;      // 离接缝 x=0/cols 与半区中线的最短距离(格)
const RESPAWN_BUCKETS = 3;           // 每个半区按 3×3 桶切分,要求每桶 ≥1 点
function _torusDist(a, b, n) {
  var d = Math.abs(a - b);
  return Math.min(d, n - d);
}
function _checkRespawns(map, cellsW, cellsH, sceneDesc) {
  var out = [];
  var rs = map.respawns || [];
  var pvpIntent = map.players.length >= 2;
  if (!rs.length) {
    if (pvpIntent) out.push('这是 PvP 图(有 player2)但没有任何「# respawn」复活点:联机会走老图两点回退');
    return out;                        // 单机图不需要按侧复活点
  }
  var half = cellsW / 2;
  for (var side = 1; side <= 2; side++) {
    var pts = [];
    for (var i = 0; i < rs.length; i++) if (rs[i].side === side) pts.push(rs[i]);
    var label = '侧 ' + side;
    if (!pts.length) { out.push(label + ' 一个复活点都没有(该侧要做联机出生就至少 ' + RESPAWN_MIN_PER_SIDE + ' 个)'); continue; }
    if (pts.length < RESPAWN_MIN_PER_SIDE) {
      out.push(label + ' 只有 ' + pts.length + ' 个复活点,少于建议的 ' + RESPAWN_MIN_PER_SIDE + ' 个');
    }
    // ① 必须在自己的半区里
    var wrong = [];
    for (i = 0; i < pts.length; i++) {
      var own = side === 1 ? (pts[i].x < half) : (pts[i].x >= half);
      if (!own) wrong.push(pts[i].x + ',' + pts[i].y);
      out = out.concat(_checkSpawn(pts[i], label + ' 复活点', cellsW, cellsH, sceneDesc));
    }
    if (wrong.length) {
      out.push(label + ' 有 ' + wrong.length + ' 个点不在自己半区(' +
               (side === 1 ? '左半 x<' + half : '右半 x≥' + half) + '):' + wrong.slice(0, 3).join(' ') +
               (wrong.length > 3 ? ' …' : ''));
    }
    // ② 离接缝/中线太近
    var marg = [];
    for (i = 0; i < pts.length; i++) {
      var m = side === 1 ? Math.min(pts[i].x, half - pts[i].x) : Math.min(pts[i].x - half, cellsW - pts[i].x);
      if (m < RESPAWN_EDGE_MARGIN) marg.push(pts[i].x + ',' + pts[i].y);
    }
    if (marg.length) {
      out.push(label + ' 有 ' + marg.length + ' 个点离接缝/半区中线不足 ' + RESPAWN_EDGE_MARGIN +
               ' 格:' + marg.slice(0, 3).join(' ') + (marg.length > 3 ? ' …' : ''));
    }
    // ③ 同侧两两环面距离(只报第一对最近的,避免刷屏)
    var best = null;
    for (i = 0; i < pts.length; i++) {
      for (var j = i + 1; j < pts.length; j++) {
        var d = Math.max(_torusDist(pts[i].x, pts[j].x, cellsW), _torusDist(pts[i].y, pts[j].y, cellsH));
        if (!best || d < best.d) best = { d: d, a: pts[i], b: pts[j] };
      }
    }
    if (best && best.d < RESPAWN_MIN_SIDE_GAP) {
      out.push(label + ' 有两个点挨得太近(环面距离 ' + best.d + ' 格 < ' + RESPAWN_MIN_SIDE_GAP + '):(' +
               best.a.x + ',' + best.a.y + ')-(' + best.b.x + ',' + best.b.y + ')');
    }
    // ④ 3×3 桶覆盖(PvP 图要求每桶 ≥1;非 PvP 图只提示不只当错误)
    var bset = {};
    for (i = 0; i < pts.length; i++) {
      var bx = Math.floor(((pts[i].x - (side === 1 ? 0 : half)) / (half / RESPAWN_BUCKETS)));
      var by = Math.floor(pts[i].y / (cellsH / RESPAWN_BUCKETS));
      bx = Math.max(0, Math.min(RESPAWN_BUCKETS - 1, bx));
      by = Math.max(0, Math.min(RESPAWN_BUCKETS - 1, by));
      bset[bx + '/' + by] = true;
    }
    var empty = [];
    for (var cx = 0; cx < RESPAWN_BUCKETS; cx++) {
      for (var cy = 0; cy < RESPAWN_BUCKETS; cy++) {
        if (!bset[cx + '/' + cy]) empty.push('(' + cx + ',' + cy + ')');
      }
    }
    if (empty.length) {
      out.push(label + ' 的 3×3 桶有 ' + empty.length + ' 个空桶' +
               (pvpIntent ? '(PvP 图要求每桶 ≥1)' : '(非 PvP 图只作提示)') + ':' + empty.slice(0, 4).join(' '));
    }
  }
  return out;
}

// 越界 / 落在实心格。返回 warning 文案数组(可能为空)。
function _checkSpawn(pt, label, cellsW, cellsH, sceneDesc) {
  var out = [];
  if (pt.x < 0 || pt.y < 0 || pt.x >= cellsW || pt.y >= cellsH) {
    out.push(label + ' 坐标 (' + pt.x + ',' + pt.y + ') 越界(地图是 ' + cellsW + '×' + cellsH + ' 格)');
    return out;
  }
  if (!sceneDesc) return out;
  // 「场景」层该格 4×4 子格全非空才算实心
  var subCols = cellsW * SUB_PER_CELL;
  var solid = true;
  for (var dy = 0; dy < SUB_PER_CELL && solid; dy++) {
    for (var dx = 0; dx < SUB_PER_CELL; dx++) {
      if (sceneDesc[(pt.y * SUB_PER_CELL + dy) * subCols + (pt.x * SUB_PER_CELL + dx)] === 0) {
        solid = false; break;
      }
    }
  }
  if (solid) out.push(label + ' 落在实心格里(场景层该格被填满)');
  return out;
}
