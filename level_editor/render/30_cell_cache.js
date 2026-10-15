// render/30_cell_cache.js —— ③ 格位图缓存:内容版本号(touch)与代际(setSource)两条失效轴。

function createCellCache(opts) {
  opts = opts || {};
  var maxCells = opts.maxCells === undefined ? DEFAULT_CELL_MAX : opts.maxCells;
  var build = opts.build;
  if (typeof build !== 'function') throw new Error('createCellCache: 缺 build 回调');
  var ver = new Map();                         // 内容版本号
  var entries = new Map();                     // 键 -> {v, gen, tile}
  var gen = 0, hits = 0, misses = 0, evictions = 0;

  function key(L, cx, cy) { return L + '/' + cx + '/' + cy; }
  function version(L, cx, cy) { var v = ver.get(key(L, cx, cy)); return v === undefined ? 0 : v; }
  function touch(L, cx, cy) { ver.set(key(L, cx, cy), version(L, cx, cy) + 1); }
  // ★★ 两条独立的失效轴必须都判:① 内容版本号(touch,编辑某格 +1 ⇒ 下次只重建这一格);② 代际(gen,setSource 递增 —— 换贴图源后即便内容一个字没改,旧 tile 也已作废)。
  //    只判 ① 会交出上一张图集算出来的 tile:整张图是色块、"有时好有时坏",不报错。
  // ★★ setSource 刻意不清表:陈旧条目靠 gen 不等恒 miss、被重建覆盖。清了表,get 里那句 e.gen === gen 就成了死代码,删掉 gen 比较再也杀不掉任何东西 —— 而它正是这条轴唯一抓得住的地方。
function setSource() { gen++; }
  function get(L, cx, cy) {
    var k = key(L, cx, cy);
    var v = version(L, cx, cy);
    var e = entries.get(k);
    if (e !== undefined && e.v === v && e.gen === gen) {
      hits++;
      entries.delete(k); entries.set(k, e);    // 命中提到最近端(Map 的插入序 = LRU 序)
      return e.tile;
    }
    misses++;
    var tile = build(L, cx, cy);
    // ★ 重建的键也要先 delete 再 set:Map.set 对已存在的键保留原来的插入位置,而这条路径恰恰常发生在"换图后 setSource 刻意不清表"留下的陈旧条目上 —— 不先删,刚重建出来的条目可能还蹲在最冷的位置,下一次淘汰就把它扔掉。
    entries.delete(k);
    entries.set(k, { v: v, gen: gen, tile: tile });
    while (entries.size > maxCells) { entries.delete(entries.keys().next().value); evictions++; }
    return tile;
  }
  function clear() { entries.clear(); }
  function stats() {
    return { hits: hits, misses: misses, evictions: evictions,
             size: entries.size, maxCells: maxCells, generation: gen };
  }
  return { version: version, touch: touch, setSource: setSource,
           get: get, clear: clear, stats: stats };
}
