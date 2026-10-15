// render/10_torus_layers.js —— 环面折算 wrapIdx/quadOf + 四层的格读取(缺席层 = 全空气)。

function wrapIdx(v, n) { return v - Math.floor(v / n) * n; }   // ★ 视图越过接缝、选区拖动、3×3 副本的 cx = -1 都会给出负数坐标,而 % 对负数返回负数
function quadOf(v) { return wrapIdx(v, SUB); }        // 恒在 0..SUB-1(否则 Tint 会抛)

// ★ layer_flags 允许某个层不存在 ⇒ map.layers[L] 可以是 null(全空气,不是"错误");直接摸它 .desc 会在打开缺层文件时当场炸。
function layerArray(map, L) {
  var lay = map.layers[L];
  if (!lay) return null;
  return lay.kind === 'tex' ? lay.desc : lay.rgba;
}
function descAt(map, L, X, Y) {
  var a = layerArray(map, L);
  if (!a) return 0;
  return a[wrapIdx(Y, map.subRows) * map.subCols + wrapIdx(X, map.subCols)];
}
function rgbaAt(map, X, Y) {
  var a = layerArray(map, RenderCore.LAYER_BG);
  if (!a) return 0;
  return a[wrapIdx(Y, map.subRows) * map.subCols + wrapIdx(X, map.subCols)];
}
