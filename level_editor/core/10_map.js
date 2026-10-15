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
      { kind: 'color', rgba: new Uint32Array(n) },
    ],
    players: [],
    enemies: [],
    comments: [],
  };
}
function cellsWOf(map) { return map.subCols / SUB_PER_CELL; }
function cellsHOf(map) { return map.subRows / SUB_PER_CELL; }
function subIndex(subCols, X, Y) { return Y * subCols + X; }
