// core.js —— `.cyrm` v4 数据模型 + 二进制编解码 + v3 迁移 + 校验。
// ★ 纯逻辑,不引用任何 DOM API:必须能被 node 直接 new Function(src)() 求值(smoke.js 就是这么跑的)。
// ★ 格式规格:docs/superpowers/specs/2026-09-19-cyrm-v4-editor-design.md §2 / §3。
//   v3 packed = texture*16 + shape 与 v4 descriptor 是两种完全不同的编码 —— 本文件里
//   _v3Pack / _v3TexOf / _v3ShapeOf 专管前者,packDesc / texOf 专管后者,不得混用。
globalThis.Core = (function () {
  'use strict';

  // ── 常量 ──
  const SUB_PER_CELL = 4;          // 每 64px 格细分成 4×4 个 16px 子格(规格 §2.1)
  const SUB_PX = 16;               // 子格边长(世界像素)
  const CELL_PX = 64;              // 格边长(世界像素)

  // ── descriptor 位域(规格 §2.3)──
  //   bit  0- 2  hue         0-7
  //   bit  3- 5  brightness  0-7
  //   bit  6- 8  saturation  0-7
  //   bit  9-11  alpha       0-7
  //   bit 12-23  texture     1-4095(0 = 空气)
  //   bit 24-31  保留,固定 0
  const DESC_AIR = 0;
  const TEXTURE_MAX = 4095;
  const HUE_NEUTRAL = 4, BRI_NEUTRAL = 4, SAT_NEUTRAL = 4, ALPHA_NEUTRAL = 7;

  // 打包成 u32。纹理不在 1..TEXTURE_MAX 内一律当空气(含 0 与负数)。
  function packDesc(texture, hue, bright, sat, alpha) {
    texture = texture | 0;
    if (texture <= 0 || texture > TEXTURE_MAX) return DESC_AIR;
    return (((hue & 7)) |
            ((bright & 7) << 3) |
            ((sat & 7) << 6) |
            ((alpha & 7) << 9) |
            (texture << 12)) >>> 0;
  }
  function texOf(d)    { return (d >>> 12) & 0xFFF; }
  function hueOf(d)    { return d & 7; }
  function brightOf(d) { return (d >>> 3) & 7; }
  function satOf(d)    { return (d >>> 6) & 7; }
  function alphaOf(d)  { return (d >>> 9) & 7; }
  function isAir(d)    { return d === DESC_AIR; }

  // 中性描述符 = 完全按原图,一点色都不改。
  // ★ 三列的中性档不在同一行:alpha 的中性在档 7,其余在档 4。
  function neutralDesc(texture) {
    return packDesc(texture, HUE_NEUTRAL, BRI_NEUTRAL, SAT_NEUTRAL, ALPHA_NEUTRAL);
  }

  return {
    SUB_PER_CELL: SUB_PER_CELL,
    SUB_PX: SUB_PX,
    CELL_PX: CELL_PX,
    DESC_AIR: DESC_AIR,
    TEXTURE_MAX: TEXTURE_MAX,
    HUE_NEUTRAL: HUE_NEUTRAL, BRI_NEUTRAL: BRI_NEUTRAL,
    SAT_NEUTRAL: SAT_NEUTRAL, ALPHA_NEUTRAL: ALPHA_NEUTRAL,
    packDesc: packDesc,
    texOf: texOf, hueOf: hueOf, brightOf: brightOf, satOf: satOf, alphaOf: alphaOf,
    isAir: isAir, neutralDesc: neutralDesc,
  };
})();
