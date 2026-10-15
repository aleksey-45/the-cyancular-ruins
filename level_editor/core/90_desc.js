// core/90_desc.js —— descriptor 位域(辅码)。


// 位域(规格 §2.3):hue/bright/sat/alpha 各 3 位(bit0-11),texture 位 12-23(1-4095,0=空气),bit24-31 保留 0;档位表见 docs/eng/editor-core.md。
const DESC_AIR = 0;
const TEXTURE_MAX = 4095;
const HUE_NEUTRAL = 4, BRI_NEUTRAL = 4, SAT_NEUTRAL = 4, ALPHA_NEUTRAL = 7;

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
// ★ isAir(d) 判的是整体等于 DESC_AIR(0),只对本编码器产出的数据可靠;读外来文件时唯一判据是 texOf(d) === 0(见 docs/eng/editor-core.md)。
function isAir(d)    { return d === DESC_AIR; }

function neutralDesc(texture) {
  return packDesc(texture, HUE_NEUTRAL, BRI_NEUTRAL, SAT_NEUTRAL, ALPHA_NEUTRAL);  // 中性 = 完全按原图;alpha 的中性档是 7,其余三列是 4
}
