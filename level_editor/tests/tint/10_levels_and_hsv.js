'use strict';
// tests/tint/10_levels_and_hsv.js —— 档位表、中性档来源、HSV(是 HSV 不是 HSL)。
const Core = globalThis.Core;
const Tint = globalThis.Tint;

// ==== 相位 ① 常量与来源 ====
ok(Tint.LEVELS === 8, 'LEVELS === 8(规格 §2.3 的八档)');
eq(Tint.HUE_OFFSET_DEG, [-60, -45, -30, -15, 0, 15, 30, 45], 'hue 档位表(不对称:−60…+45)');
eq(Tint.MUL, [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3], '亮度/饱和度乘法档位表');
// ★ 期望值**写死**(4/4/4/7),不从 `Core` 现读:两边同源的话,连"中性档整体挪到别的档"都测不出来
//   (实测:把 tint.js 那四个 `Core.*` 换成字面量,同源那版全绿)。
//   ★ 它**测不到**"究竟是读 Core 还是自己抄了一份字面量" —— 那只能读源码判形态,D6 不许。
eq(Tint.NEUTRAL, { hue: 4, bri: 4, sat: 4, alpha: 7 },
   '★ 中性档 = 色相/亮度/饱和在档 4、alpha 在档 7(期望值写死,不与被测代码同源)');
ok(Tint.NEUTRAL.hue === 4 && Tint.NEUTRAL.alpha === 7,
   '★ 三列的中性档不在同一行:色相/亮度/饱和在档 4,alpha 在档 7');
eq(Tint.hueOffsetOf(4), 0, 'hue 中性档 4 → 0°');
eq(Tint.mulOf(4), 1, '亮度/饱和度中性档 4 → ×1.0(恒等元)');
eq(Tint.alphaScaleOf(7), 1, 'alpha 中性档 7 → ×1');
ok(Math.abs(Tint.alphaScaleOf(4) - 4 / 7) < 1e-12, '★ alpha 档 4 是 4/7 而不是 1');
// ★★ 整表钉住:只钉中性档与档 4 两个采样点时,把 ALPHA_NUM 的档 1 与档 2 对调**全绿**,
//    而 alpha 档 1 与档 2 的整体透明度互换 —— 透明度的档位表正是本文件头号关切。
eq(Tint.ALPHA_NUM, [0, 1, 2, 3, 4, 5, 6, 7], 'alpha 档位表(分子 0..7,中性档在 7)');
eq([0, 1, 2, 3, 4, 5, 6, 7].map(Tint.alphaScaleOf),
   [0, 1 / 7, 2 / 7, 3 / 7, 4 / 7, 5 / 7, 6 / 7, 1],
   '★ alpha 整表 [0..7].map(alphaScaleOf) = 0, 1/7 … 1(逐档单调,中性档 7 恰为恒等)');
ok(Tint.BLOCK_PX === 32 && Tint.QUAD_PX === 8 && Tint.TILE_PX === 16,
   '贴图几何:块 32 / 象限 8 / 小图 16(= Core.SUB_PX)');
ok(Tint.TILE_PX === Core.SUB_PX && Tint.QUAD_PX * 2 === Tint.TILE_PX,
   '★ 小图边长 = 子格边长(16),象限 8px 放大 2× 正好铺满');
ok(Tint.DEFAULT_MAX_TILES * Tint.TILE_PX * Tint.TILE_PX * 4 === 8 * 1024 * 1024,
   '★ 缓存上限 ' + Tint.DEFAULT_MAX_TILES + ' 张 × 16×16×4 字节 = 正好 8MB(规格 §4.3 闸 1)');

// ==== 相位 ② HSV(是 HSV 不是 HSL)====
eq(Tint.rgbToHsv(1, 0, 0), { h: 0, s: 1, v: 1 }, 'rgbToHsv: 纯红 → (0,1,1)');
eq(Tint.rgbToHsv(0, 1, 1), { h: 180, s: 1, v: 1 }, 'rgbToHsv: 青 → (180,1,1)');
eq(Tint.rgbToHsv(0.5, 0.5, 0.5), { h: 0, s: 0, v: 0.5 }, 'rgbToHsv: 灰 → s=0');
eq(Tint.rgbToHsv(0, 0, 0), { h: 0, s: 0, v: 0 }, 'rgbToHsv: 黑 → 全 0(不能出 NaN)');
const cyan = Tint.hsvToRgb(180, 1, 1);
ok(Math.abs(cyan.r) < 1e-12 && Math.abs(cyan.g - 1) < 1e-12 && Math.abs(cyan.b - 1) < 1e-12,
   'hsvToRgb: (180,1,1) → 青');
eq(Tint.hsvToRgb(360, 1, 1), Tint.hsvToRgb(0, 1, 1), 'hsvToRgb: 360° 与 0° 同结果');
ok(Math.abs(Tint.fposmod(-60, 360) - 300) < 1e-12, 'fposmod: 负数绕回正区间');

// ==== 相位 ③ tint 对 Core 的依赖是结构性的 ====
(function () {
  const saveCore = globalThis.Core, saveTint = globalThis.Tint;
  const p = require.resolve('../../tint.js');
  delete require.cache[p];
  delete globalThis.Core;
  let err = null;
  try { require('../../tint.js'); } catch (e) { err = e; }
  delete require.cache[p];
  globalThis.Core = saveCore;
  globalThis.Tint = saveTint;
  ok(err !== null && /core\.js/.test(String(err.message)),
     '★ 没有 Core 时 tint.js 当场抛错(常量是派生来的,不是抄来的):' + (err ? err.message : '(没抛)'));
})();
