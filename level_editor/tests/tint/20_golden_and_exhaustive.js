'use strict';
// tests/tint/20_golden_and_exhaustive.js —— 手工从规格推导的 golden 值 + 穷举恒等(与游戏 shader 逐像素一致的唯一硬证据)。
const Core = globalThis.Core;
const Tint = globalThis.Tint;

(function () {
  const N = Core.neutralDesc(1);
  // ★ 一张表 = 一条守卫(D9):这些 golden 是**从规格手推**的,行标签里带着推导 ——
  //   逐条断言只会让"改一次映射"变成动 11 行,而失败信息仍然只点名一个。
  tableEq('golden:从规格手推的 HSV / 档位映射(纯红 + 白 逐档)', [
    ['H=5(+15°):扇区 0,x=0.25 → (255,64,0)', Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 5, 4, 7, 7)), [255, 64, 0, 255]],
    ['H=3(−15°):h\'=345,扇区 5 → (255,0,64)', Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 3, 4, 7, 7)), [255, 0, 64, 255]],
    ['H=0(−60°):h\'=300 → 品红(色相在 360° 上环绕)', Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 0, 4, 7, 7)), [255, 0, 255, 255]],
    ['H=7(+45°):x=0.75 → (255,191,0)', Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 7, 4, 7, 7)), [255, 191, 0, 255]],
    ['白 ×0.8 亮度 → 204', Tint.tintBytes(255, 255, 255, 255, Core.packDesc(1, 4, 2, 4, 7)), [204, 204, 204, 255]],
    ['中灰 ×0.8 → 102(**乘法**不是加法;加法会得到 77)', Tint.tintBytes(128, 128, 128, 255, Core.packDesc(1, 4, 2, 4, 7)), [102, 102, 102, 255]],
    ['S=0(×0.6):纯红 s=1→0.6 → (255,102,102)', Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 0, 7)), [255, 102, 102, 255]],
    ['白 ×0.6 饱和度 → 仍是白(s=0 时饱和度无效)', Tint.tintBytes(255, 255, 255, 255, Core.packDesc(1, 4, 4, 0, 7)), [255, 255, 255, 255]],
    ['饱和度已满时 ×1.3 被 clamp(不越界通道)', Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 7, 7)), [255, 0, 0, 255]],
    ['alpha 档 3 → 109(= 255×3/7)', Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 4, 3)), [255, 0, 0, 109]],
    ['alpha 档 0 → 0(全透明,颜色不受影响)', Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 4, 0)), [255, 0, 0, 0]],
    ['中性描述符是恒等:纯红', Tint.tintBytes(255, 0, 0, 255, N), [255, 0, 0, 255]],
  ]);
  const f = Tint.tintRGBA(1, 0, 0, 1, Core.neutralDesc(1));
  ok(f.r === 1 && f.g === 0 && f.b === 0 && f.a === 1, 'tintRGBA: 中性描述符下浮点也是恒等');
  const g = Tint.tintRGBA(1, 0, 0, 1, Core.packDesc(1, 5, 4, 7, 7));
  ok(Math.abs(g.g - 0.25) < 1e-12, 'tintRGBA: 浮点值是 0.25(取整只发生在 tintBytes 里)');
  eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 5, 4, 7, 7))[1], Math.round(0.25 * 255),
     'tintBytes 的取整规则 = Math.round(x*255),只此一处');
})();

(function () {
  const vals = [0, 1, 2, 3, 17, 63, 64, 127, 128, 129, 191, 254, 255];
  let bad = 0, n = 0;
  for (const R of vals) for (const G of vals) for (const B of vals) for (const A of vals) {
    n++;
    const o = Tint.tintBytes(R, G, B, A, Core.neutralDesc(1));
    if (o[0] !== R || o[1] !== G || o[2] !== B || o[3] !== A) bad++;
  }
  ok(bad === 0, '★ 中性描述符对 ' + n + ' 组 8 位输入逐字节恒等(含非灰度色)');
  let worst = 0;
  for (let i = 0; i <= 255; i += 3) {
    for (let j = 0; j <= 255; j += 7) {
      for (let k = 0; k <= 255; k += 11) {
        const r = i / 255, g = j / 255, b = k / 255;
        const hsv = Tint.rgbToHsv(r, g, b);
        const o = Tint.hsvToRgb(hsv.h, hsv.s, hsv.v);
        worst = Math.max(worst, Math.abs(o.r - r), Math.abs(o.g - g), Math.abs(o.b - b));
      }
    }
  }
  ok(worst < 1e-9, '★ rgbToHsv → hsvToRgb 的浮点往返最大误差 ' + worst.toExponential(2) + ' < 1e-9');
})();
