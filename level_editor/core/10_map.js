// core/10_map.js —— 地图对象与下标。


// ── 地图对象 ──
// 全部用 TypedArray:4 层 × 150k 子格若用嵌套 JS 数组会到几十 MB 且 GC 压力巨大。
// 下标一律 = y * subCols + x(行主序),与文件里的排布一致。
function createMap(name, cellsW, cellsH) {
  if (!Number.isInteger(cellsW) || !Number.isInteger(cellsH) || cellsW <= 0 || cellsH <= 0) {
    throw new Error('createMap: 格数必须是正整数,收到 ' + cellsW + '×' + cellsH);
  }
  var subCols = cellsW * SUB_PER_CELL;
  var subRows = cellsH * SUB_PER_CELL;
  var n = subCols * subRows;
  return {
    name: String(name == null ? '' : name),
    subCols: subCols,
    subRows: subRows,
    layers: [
      { kind: 'tex', desc: new Uint32Array(n) },
      { kind: 'tex', desc: new Uint32Array(n) },
      { kind: 'tex', desc: new Uint32Array(n) },
      { kind: 'color', rgba: new Uint32Array(n) },   // 背景100%(历史文件恒有这一层,保留默认分配)
      null, null, null,                              // 背景 75%/50%/25%:按需分配,见 ensureLayer
    ],
    players: [],
    enemies: [],
    // ★ `# respawn <1|2> <col> <row>` 的复活点列表(元素 {side, x, y})。侧 1 = 左半、侧 2 = 右半,
    //   与游戏侧 SpawnChooser.SIDE_LEFT/SIDE_RIGHT 同源;格式仍是 meta 文本行,不是二进制字段。
    respawns: [],
    comments: [],
  };
}
function cellsWOf(map) { return map.subCols / SUB_PER_CELL; }
function cellsHOf(map) { return map.subRows / SUB_PER_CELL; }
function subIndex(subCols, X, Y) { return Y * subCols + X; }

// 按需建颜色层:背景 75%/50%/25% 默认 null(不占内存、不置 layer_flags 位),第一次要往里画时才分配。
// ★ 只对颜色层生效;纹理层缺席是"这张图没有这一层"(旧文件),绝不凭空补一层空的。
function ensureLayer(map, L) {
  if (!map || !map.layers) return null;
  if (map.layers[L]) return map.layers[L];
  if (LAYER_KINDS[L] !== 'color') return null;
  map.layers[L] = { kind: 'color', rgba: new Uint32Array(map.subCols * map.subRows) };
  return map.layers[L];
}
