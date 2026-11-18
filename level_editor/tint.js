globalThis.Tint = (function () {
  'use strict';

  var Core = globalThis.Core;
  if (!Core) {
    throw new Error('tint.js: 必须先加载 core.js(本模块的档位常量全部取自 Core,不自己抄一份)');
  }

  var LEVELS = 8;
  var HUE_OFFSET_DEG = [-60, -45, -30, -15, 0, 15, 30, 45];      // 色相偏移以度为单位，数组索引对应颜色设置中的色相档位。
  var MUL = [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3];             // 亮度与饱和度共用同一组缩放系数。
  var ALPHA_NUM = [0, 1, 2, 3, 4, 5, 6, 7];
  var NEUTRAL = {
    hue: Core.HUE_NEUTRAL, bri: Core.BRI_NEUTRAL,
    sat: Core.SAT_NEUTRAL, alpha: Core.ALPHA_NEUTRAL,
  };

  function hueOffsetOf(level) { return HUE_OFFSET_DEG[level & 7]; }
  function mulOf(level) { return MUL[level & 7]; }
  function alphaScaleOf(level) { return ALPHA_NUM[level & 7] / Core.ALPHA_NEUTRAL; }

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

  function tintRGBA(r, g, b, a, desc) {
    var hsv = rgbToHsv(r, g, b);
    var h2 = fposmod(hsv.h + hueOffsetOf(Core.hueOf(desc)), 360);
    var s2 = clamp01(hsv.s * mulOf(Core.satOf(desc)));
    var v2 = clamp01(hsv.v * mulOf(Core.brightOf(desc)));
    var rgb = hsvToRgb(h2, s2, v2);
    return { r: rgb.r, g: rgb.g, b: rgb.b, a: a * alphaScaleOf(Core.alphaOf(desc)) };
  }

  // 将通道值限制在 0 到 1，再换算为一个字节所能表示的整数。
  function toByte(x) {
    var v = Math.round(clamp01(x) * 255);
    return v < 0 ? 0 : (v > 255 ? 255 : v);
  }
  function tintBytes(r, g, b, a, desc) {
    var o = tintRGBA(r / 255, g / 255, b / 255, a / 255, desc);
    return [toByte(o.r), toByte(o.g), toByte(o.b), toByte(o.a)];
  }

  // 图集中的每张纹理占 32×32 像素，计算纹理位置时使用图集的实际宽度。
  var BLOCK_PX = 32;
  var QUAD_PX = 32 / Core.SUB_PER_CELL;     // 一张纹理按 4×4 切分，每个子格取其中 8×8 像素。
  var TILE_PX = Core.SUB_PX;
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

  // 取出子格对应的图集区域，应用颜色设置，再以最近邻方式放大，输出 16×16 像素的 RGBA 数据。
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

  var DEFAULT_BACKEND = {
    createTile: function (pixels, size) {
      if (typeof document === 'undefined') {
        throw new Error('Tint: 本环境没有 document,请给 createTileCache 传 backend(node 测试用)');
      }
      var c = document.createElement('canvas');
      c.width = size;
      c.height = size;
      var ctx = c.getContext('2d');
      ctx.imageSmoothingEnabled = false;
      ctx.putImageData(new ImageData(pixels, size, size), 0, 0);
      return c;
    },
  };

  function createTileCache(opts) {
    opts = opts || {};
    var maxSize = opts.maxSize === undefined ? DEFAULT_MAX_TILES : opts.maxSize;
    var backend = opts.backend || DEFAULT_BACKEND;
    // 缓存淘汰最近最少使用的图像。命中时将该图像移到末尾。
    var tiles = new Map();
    var atlas = null, atlasWidth = 0;
    var hits = 0, misses = 0, evictions = 0;

    function setSource(data, width) {
      if (!data || typeof data.length !== 'number' || !isFinite(data.length) || data.length <= 0) {
        throw new Error('setSource: data 必须是平坦的 RGBA 数组(ImageData 的话请传它的 .data),实得 ' +
                        (data === null || data === undefined ? String(data) : typeof data) +
                        (data && typeof data.length === 'number' ? '(length=' + data.length + ')' : ''));
      }
      var w = width | 0;
      // 图集宽度必须是 4 像素的倍数。每个 RGBA 像素占 4 字节，因此每行有 w * 4 字节。
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
    function tileKey(texture, qx, qy, desc) {
      return texture + '/' + quadIndex(qx, 'qx') + '/' + quadIndex(qy, 'qy') + '/' + (desc >>> 0);
    }
    // 只有缓存中没有对应结果时，才按纹理编号、子格位置及颜色设置生成图像。
    function get(texture, qx, qy, desc) {
      var k = tileKey(texture, qx, qy, desc);
      if (tiles.has(k)) {
        var hit = tiles.get(k);
        hits++;
        tiles.delete(k);
        tiles.set(k, hit);
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
