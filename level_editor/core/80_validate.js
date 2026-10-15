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

  return { errors: errors, warnings: warnings };
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
