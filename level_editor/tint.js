// tint.js —— 辅码(descriptor)的像素数学 + tinted-tile 缓存(规格 §2.3 / §4.2 ④)。
//
// ★ 本模块**必须在 core.js 之后加载**:档位的中性行、象限数、位域取值全部取自
//   `globalThis.Core`,不自己抄一份 —— 抄一份就意味着两处会漂,而漂了的表现是
//   "编辑器里调好的颜色进游戏就变样"(不报错,只在玩的时候看出来)。没有 Core 就当场抛错。
// ★ 像素数学必须与游戏侧 shader **逐像素一致**(规格 §2.3;交接文档 §2.2 是同一份公式):
//     · 是 **HSV** 不是 HSL(饱和度/亮度取的是 HSV 的 S 与 V);
//     · 色相 h' = fposmod(h + (H-4)*15, 360),八档**不对称**(−60°…+45°);
//     · 亮度/饱和度是**乘法**,乘数 = (k+6)/10(即 MUL 表 0.6…1.3)——
//       暗部不会被压成纯黑,中性档 4 恰好是恒等元(×1.0);
//       ★ 别写成 (k-4)*0.1:那既不是乘数、也不是正确的增量(它是"加法"那一支的形状,
//         而在"乘法 vs 加法"正是本文件判别性要求的地方,写错一支等于把结论说反);
//     · alpha a' = a * (A/7),中性档在 **7**(不在 4)。
// ★ 纯逻辑 + 注入式画布:node 里能直接 require 进来断言(`node tint_smoke.js`)。
globalThis.Tint = (function () {
  'use strict';

  var Core = globalThis.Core;
  if (!Core) {
    throw new Error('tint.js: 必须先加载 core.js(本模块的档位常量全部取自 Core,不自己抄一份)');
  }

  // ── 档位含义表(规格 §2.3 的那张表,直接抄成按下标取的数组)──
  var LEVELS = 8;
  var HUE_OFFSET_DEG = [-60, -45, -30, -15, 0, 15, 30, 45];      // = (k - 4) * 15
  var MUL = [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3];             // = (k + 6) / 10
  var ALPHA_NUM = [0, 1, 2, 3, 4, 5, 6, 7];                       // a' = a * k / 7
  // ★ 中性档来自 Core,不写字面量 —— 这是"两边不许漂"的那一条。
  var NEUTRAL = {
    hue: Core.HUE_NEUTRAL, bri: Core.BRI_NEUTRAL,
    sat: Core.SAT_NEUTRAL, alpha: Core.ALPHA_NEUTRAL,
  };

  function hueOffsetOf(level) { return HUE_OFFSET_DEG[level & 7]; }
  function mulOf(level) { return MUL[level & 7]; }
  function alphaScaleOf(level) { return ALPHA_NUM[level & 7] / Core.ALPHA_NEUTRAL; }

  // ── HSV(标准定义,h ∈ [0,360),s/v ∈ [0,1])──
  // ★ 为什么不用 HSL:规格 §2.3 写死是 HSV,而这两个在同一个 (r,g,b) 上会给出**不同的**
  //   饱和度与亮度 —— 用错一个,"编辑器里调好的颜色进游戏就变样"。
  function fposmod(a, n) { var r = a % n; return r < 0 ? r + n : r; }

  function rgbToHsv(r, g, b) {
    var max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    var h = 0;
    if (d !== 0) {
      if (max === r) h = 60 * fposmod((g - b) / d, 6);
      else if (max === g) h = 60 * ((b - r) / d + 2);
      else h = 60 * ((r - g) / d + 4);
    }
    return { h: fposmod(h, 360), s: max === 0 ? 0 : d / max, v: max };
  }

  function hsvToRgb(h, s, v) {
    h = fposmod(h, 360);
    var c = v * s;
    var x = c * (1 - Math.abs(fposmod(h / 60, 2) - 1));
    var m = v - c;
    var i = Math.floor(h / 60) % 6;
    var r1, g1, b1;
    if (i === 0) { r1 = c; g1 = x; b1 = 0; }
    else if (i === 1) { r1 = x; g1 = c; b1 = 0; }
    else if (i === 2) { r1 = 0; g1 = c; b1 = x; }
    else if (i === 3) { r1 = 0; g1 = x; b1 = c; }
    else if (i === 4) { r1 = x; g1 = 0; b1 = c; }
    else { r1 = c; g1 = 0; b1 = x; }
    return { r: r1 + m, g: g1 + m, b: b1 + m };
  }

  function clamp01(x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }

  // ★★ 规范定义(规格 §2.3),浮点进浮点出 —— **与游戏 shader 对齐的就是这一个**。
  //    任何 8 位取整都只是它的落地实现(tintBytes / buildTilePixels)。
  function tintRGBA(r, g, b, a, desc) {
    var hsv = rgbToHsv(r, g, b);
    var h2 = fposmod(hsv.h + hueOffsetOf(Core.hueOf(desc)), 360);
    var s2 = clamp01(hsv.s * mulOf(Core.satOf(desc)));
    var v2 = clamp01(hsv.v * mulOf(Core.brightOf(desc)));
    var rgb = hsvToRgb(h2, s2, v2);
    return { r: rgb.r, g: rgb.g, b: rgb.b, a: a * alphaScaleOf(Core.alphaOf(desc)) };
  }

  // 8 位通道的取整规则**只有这一处**:Math.round(clamp01(x) * 255)。
  function toByte(x) {
    var v = Math.round(clamp01(x) * 255);
    return v < 0 ? 0 : (v > 255 ? 255 : v);
  }
  function tintBytes(r, g, b, a, desc) {
    var o = tintRGBA(r / 255, g / 255, b / 255, a / 255, desc);
    return [toByte(o.r), toByte(o.g), toByte(o.b), toByte(o.a)];
  }

  // ── 贴图几何 ──
  // structure.png 是 320×320、每块 32×32、每行 10 块(游戏侧一致:两行各 10 块 + 第三行两块水)。
  // 象限由 core.js 的 subcellRender 给出(块内 8px 偏移),这里只负责"第 T 块在哪"。
  var BLOCK_PX = 32;
  var QUAD_PX = 32 / Core.SUB_PER_CELL;     // 8
  var TILE_PX = Core.SUB_PX;                // 16 = 象限 8px 放大 2×,正好一个子格

  // ★★ 象限坐标归一化 + 越界守卫(键与像素数学**必须用同一个约定**)。
  //    旧实现有**两条平行的约定**:缓存的键用 `(qx & 3)`(负数被位运算折到 3),
  //    而像素数学用 `qx % Core.SUB_PER_CELL`(负数保持负)。实测后果比"键不好看"重得多:
  //    `get(1,-1,0,desc)` 会**先造出一张错图、并存进象限 3 的键**,随后 `get(1,3,0,desc)`
  //    **直接命中那张错图**(两次调用返回同一个对象)。
  //    今天所有调用方都只循环 0..3,但"从坐标算象限"的调用方(2b 的环面 / 拖拽选区)
  //    出现负坐标很正常 ⇒ 这里把越界坐标**当场抛掉**,回绕由调用方自己先做(别猜)。
  var SUB = Core.SUB_PER_CELL;
  function quadIndex(q, which) {
    if (typeof q !== 'number' || !isFinite(q) || Math.floor(q) !== q || q < 0 || q >= SUB) {
      throw new Error('象限坐标 ' + which + ' = ' + q + ' 非法(合法范围 0..' + (SUB - 1) +
                      ';环面回绕请调用方先自己 ' + which + ' % ' + SUB + ')');
    }
    return q % SUB;
  }

  function textureBlockRect(texture, atlasWidth) {
    var cols = Math.floor(atlasWidth / BLOCK_PX);
    var i = (texture | 0) - 1;
    if (cols <= 0 || i < 0) {
      throw new Error('textureBlockRect: 纹理号 ' + texture + ' 或图集宽度 ' + atlasWidth + ' 非法');
    }
    return { x: (i % cols) * BLOCK_PX, y: Math.floor(i / cols) * BLOCK_PX, w: BLOCK_PX, h: BLOCK_PX };
  }

  // 纯像素:从**图集**(整张 structure.png 的 RGBA)里取纹理 T 的第 (qx,qy) 个 8px 象限,
  // 按描述符 tint,再**最近邻**放大 2× 成 16×16。返回 Uint8ClampedArray(16*16*4)。
  // ★ 放大必须是最近邻(不是插值)—— 与项目其余的 texture_filter=nearest 口径一致。
  // ★★ 调用方契约(**这个函数会抛,别把它当纯函数用**):下面四种实参一律抛错 ——
  //    ① `desc === 0`(**空气**):空气没有贴图。★ 空气是地图数据里**最常见**的那一格,
  //       渲染循环若不先过滤 desc === 0,第一帧就抛、而且每帧都在同一处抛;
  //    ② 纹理号**超出图集行/列**(如 320×320 的图集里只到第 100 块,101 起就抛);
  //    ③ `texture` 实参与 `Core.texOf(desc)` **不一致**(见下);
  //    ④ 象限坐标不是 0..SUB_PER_CELL-1 的整数(见 quadIndex)。
  function buildTilePixels(atlas, atlasWidth, texture, qx, qy, desc) {
    if (Core.texOf(desc) === 0) {
      throw new Error('buildTilePixels: 空气格没有贴图(desc=0x' + (desc >>> 0).toString(16) + ')');
    }
    var rect = textureBlockRect(texture, atlasWidth);
    var srcX = rect.x + quadIndex(qx, 'qx') * QUAD_PX;
    var srcY = rect.y + quadIndex(qy, 'qy') * QUAD_PX;
    var rows = atlas.length / (atlasWidth * 4);
    if (srcX + QUAD_PX > atlasWidth || srcY + QUAD_PX > rows) {
      throw new Error('buildTilePixels: 图集里没有纹理 ' + texture + ' 的象限 (' + qx + ',' + qy +
                      ') —— 图集是 ' + atlasWidth + '×' + rows);
    }
    // ★ 实参 `texture` 必须**就是**描述符里那个:不一致时上面两条都拦不住(那块在坐标系里
    //   是存在的),于是函数**一声不响地**画出另一块砖的像素 —— 屏幕上是一块颜色不对的砖,
    //   而调用方以为自己传对了。这属于"编程错误"档,与 desc=0 同级,故当场抛。
    if (Core.texOf(desc) !== texture) {
      throw new Error('buildTilePixels: 纹理实参 ' + texture + ' 与描述符里的纹理 ' +
                      Core.texOf(desc) + ' 不一致(desc=0x' + (desc >>> 0).toString(16) + ')');
    }
    var scale = TILE_PX / QUAD_PX;
    var out = new Uint8ClampedArray(TILE_PX * TILE_PX * 4);
    for (var y = 0; y < QUAD_PX; y++) {
      for (var x = 0; x < QUAD_PX; x++) {
        var si = ((srcY + y) * atlasWidth + (srcX + x)) * 4;
        var p = tintBytes(atlas[si], atlas[si + 1], atlas[si + 2], atlas[si + 3], desc);
        for (var dy = 0; dy < scale; dy++) {
          for (var dx = 0; dx < scale; dx++) {
            var oi = ((y * scale + dy) * TILE_PX + (x * scale + dx)) * 4;
            out[oi] = p[0]; out[oi + 1] = p[1]; out[oi + 2] = p[2]; out[oi + 3] = p[3];
          }
        }
      }
    }
    return out;
  }

  // ── tinted-tile 缓存(规格 §4.2 ④)──
  // 键 = (纹理, 象限, 描述符) → 一张 16×16 小图。贴图源只有 32×32,一块小图 256 像素,
  // 手算极便宜 —— 但同一块会被画成千上万次,故必须缓存。
  // ★ 画布是**注入**的:node 里没有 document,缓存把"画出来的像素"交给 backend,
  //   于是缓存的键/淘汰/失效逻辑在 node 里可以完整断言。
  var DEFAULT_BACKEND = {
    createTile: function (pixels, size) {
      if (typeof document === 'undefined') {
        throw new Error('Tint: 本环境没有 document,请给 createTileCache 传 backend(node 测试用)');
      }
      var c = document.createElement('canvas');
      c.width = size;
      c.height = size;
      var ctx = c.getContext('2d');
      ctx.imageSmoothingEnabled = false;       // 最近邻,与项目其余部分一致
      ctx.putImageData(new ImageData(pixels, size, size), 0, 0);
      return c;
    },
  };

  function createTileCache(opts) {
    opts = opts || {};
    var maxSize = opts.maxSize === undefined ? DEFAULT_MAX_TILES : opts.maxSize;
    var backend = opts.backend || DEFAULT_BACKEND;
    // ★ Map 的**插入序就是 LRU 序**:命中时 delete + set 把条目提到末尾,
    //   淘汰时取 keys().next().value(最老的那个)。
    var tiles = new Map();
    var atlas = null, atlasWidth = 0;
    var hits = 0, misses = 0, evictions = 0;

    // ★★ 换图**必须**整片失效(审计 A2):旧编辑器在 structure.png 加载完成前写进
    //    纯色兜底、且永不失效 —— 于是地图一直是色块,而且"有时好有时坏"。
    //    资源换了就是换了,没有"部分还新鲜"这回事。
    // ★★ 调用方契约:必须传**平坦的 RGBA 数组**(浏览器里就是 `imageData.data`),
    //    **不是** `ImageData` 对象本身 —— 传对象会**静默**画出一整张全透明小图
    //    (理由见下面的形状守卫)。这不是"建议",是形状闸:不符合形状当场抛。
    function setSource(data, width) {
      // ★★ 形状守卫(I2):最自然的误用是把 `ImageData` **对象**传进来,而不是它的 `.data`。
      //    那时 `atlas.length` 是 `undefined` ⇒ `buildTilePixels` 里 rows = NaN ⇒
      //    那条边界比较(`> NaN`)恒为 false ⇒ **一路产出全透明小图且不报错**
      //    (规格 §7 风险登记里"不静默画空白"那条缓解,在 setSource 这一层原本是开着的)。
      //    ★ 守卫只做在**参数形状**上:像素数学里的抛错仍旧是"编程错误"的哨兵,别动它。
      if (!data || typeof data.length !== 'number' || !isFinite(data.length) || data.length <= 0) {
        throw new Error('setSource: data 必须是平坦的 RGBA 数组(ImageData 的话请传它的 .data),实得 ' +
                        (data === null || data === undefined ? String(data) : typeof data) +
                        (data && typeof data.length === 'number' ? '(length=' + data.length + ')' : ''));
      }
      var w = width | 0;
      // 每像素 4 字节 ⇒ 宽度必须是 4 的倍数(否则"行"不是整数字节);
      // 且总字节数必须是**整行**(宽度×4)的整数倍,否则宽度与数据对不上、rows 是分数。
      if (w <= 0 || w % 4 !== 0) {
        throw new Error('setSource: 图集宽度必须是正的、4 的倍数(每像素 4 字节),实得 ' + width);
      }
      if (data.length % (w * 4) !== 0) {
        throw new Error('setSource: 图集字节数 ' + data.length + ' 不是整行(' + w + '×4 = ' + (w * 4) +
                        ' 字节)的整数倍 —— 宽度与数据对不上');
      }
      atlas = data;
      atlasWidth = w;
      tiles.clear();
    }
    // 键与像素数学取的是**同一个**象限约定(quadIndex):越界坐标在这里就抛,
    // 不允许"键折到 3、像素按负数取"那种两条约定并存的状态(见 quadIndex 的说明)。
    function tileKey(texture, qx, qy, desc) {
      return texture + '/' + quadIndex(qx, 'qx') + '/' + quadIndex(qy, 'qy') + '/' + (desc >>> 0);
    }
    // ★★ 调用方契约(**这个函数会抛**):`desc === 0`(空气)与"纹理号超出图集行/列"都会抛,
    //    越界象限坐标与纹理/描述符不一致同样抛 —— 全部由 buildTilePixels 抛出(见它的注释)。
    //    ★ 空气是地图数据里最常见的一格:渲染循环必须先 `if (desc === 0) continue;`,
    //      否则第一帧就抛、且每帧都在同一处抛。
    function get(texture, qx, qy, desc) {
      var k = tileKey(texture, qx, qy, desc);
      // ★★ 命中判据必须是 `tiles.has(k)`,不能写成 `tiles.get(k) !== undefined`:
      //    backend 若返回 `undefined`(或将来某个 backend 这么做),后者恒为假 ⇒ 那张图
      //    **永不命中**,却已经占着槽位、计入 size、还能把活条目挤掉(实测
      //    `{hits:0,misses:2,size:1}` 且 `has()` 为 true)。
      //    "命中了没有"只有一条判据,get 与 has 必须走同一条。
      if (tiles.has(k)) {
        var hit = tiles.get(k);
        hits++;
        tiles.delete(k);
        tiles.set(k, hit);                     // 提到最近使用端
        return hit;
      }
      misses++;
      if (!atlas) throw new Error('Tint: 还没 setSource,拿不到贴图(别在图片加载完成前画)');
      var tile = backend.createTile(buildTilePixels(atlas, atlasWidth, texture, qx, qy, desc), TILE_PX);
      if (maxSize > 0) {
        tiles.set(k, tile);
        while (tiles.size > maxSize) {
          tiles.delete(tiles.keys().next().value);
          evictions++;
        }
      }
      return tile;
    }
    function has(texture, qx, qy, desc) { return tiles.has(tileKey(texture, qx, qy, desc)); }
    function clear() { tiles.clear(); }
    function stats() {
      return { hits: hits, misses: misses, evictions: evictions, size: tiles.size, maxSize: maxSize };
    }
    return { setSource: setSource, get: get, has: has, clear: clear, stats: stats,
             tileKey: tileKey };
  }

  // 缓存上限(Task 5 用):8192 × 16×16×4 字节 = 正好 8MB(规格 §4.3 闸 1)。
  var DEFAULT_MAX_TILES = 8192;

  return {
    LEVELS: LEVELS,
    HUE_OFFSET_DEG: HUE_OFFSET_DEG, MUL: MUL, ALPHA_NUM: ALPHA_NUM, NEUTRAL: NEUTRAL,
    hueOffsetOf: hueOffsetOf, mulOf: mulOf, alphaScaleOf: alphaScaleOf,
    fposmod: fposmod, rgbToHsv: rgbToHsv, hsvToRgb: hsvToRgb,
    tintRGBA: tintRGBA, tintBytes: tintBytes,
    BLOCK_PX: BLOCK_PX, QUAD_PX: QUAD_PX, TILE_PX: TILE_PX,
    textureBlockRect: textureBlockRect, buildTilePixels: buildTilePixels,
    DEFAULT_MAX_TILES: DEFAULT_MAX_TILES,
    DEFAULT_BACKEND: DEFAULT_BACKEND, createTileCache: createTileCache,
  };
})();
