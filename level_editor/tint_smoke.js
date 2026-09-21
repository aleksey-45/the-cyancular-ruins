'use strict';
// Node 冒烟 —— 辅码像素数学与 tinted-tile 缓存(level_editor/tint.js)。
// Run: cd level_editor && node tint_smoke.js
// 判据:文本 `TINT SMOKE OK` + 退出码 0。
// ★ tint.js 是经典脚本(globalThis.Tint),core.js 是它的硬依赖 —— 加载顺序不能反。

require('./core.js');
require('./tint.js');
const Core = globalThis.Core;
const Tint = globalThis.Tint;

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function sameBytes(actual, expected, msg) {
  const a = Array.prototype.slice.call(actual);
  const e = Array.prototype.slice.call(expected);
  if (a.length !== e.length) {
    fail++; console.error('  FAIL - ' + msg + ' (长度 ' + a.length + ' ≠ 期望 ' + e.length + ')');
    return;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== e[i]) {
      fail++; console.error('  FAIL - ' + msg + ' (第 ' + i + ' 个字节: 实得 ' + a[i] + ', 期望 ' + e[i] + ')');
      return;
    }
  }
  pass++; console.log('  ok  - ' + msg);
}
// ★ 反向断言必须同时断言「错在哪」:只判「有没有抛」是假绿。
function throws(fn, msg, expectSub) {
  let e = null;
  try { fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && String(e.message).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + e.message);
    return;
  }
  pass++; console.log('  ok  - ' + msg);
}

// 合成图集:3 行 × 10 列、每块 32×32。每个像素编码成
//   R = 块内 x × 8, G = 块内 y × 8, B = 块号(0-based), A = 255
// 于是"取到了哪一块的哪个像素"既好读、也能被断言验。
const COLS = 10, ATLAS_W = COLS * 32, ATLAS_H = 96;
function makeAtlas() {
  const a = new Uint8ClampedArray(ATLAS_W * ATLAS_H * 4);
  for (let y = 0; y < ATLAS_H; y++) {
    for (let x = 0; x < ATLAS_W; x++) {
      const i = (y * ATLAS_W + x) * 4;
      a[i] = (x % 32) * 8;
      a[i + 1] = (y % 32) * 8;
      a[i + 2] = Math.floor(y / 32) * COLS + Math.floor(x / 32);
      a[i + 3] = 255;
    }
  }
  return a;
}

(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 某个断言挂住了');
    process.exit(1);
  }, 120000);

  // ==== 相位 ① 常量与来源 ====
  ok(Tint.LEVELS === 8, 'LEVELS === 8(规格 §2.3 的八档)');
  eq(Tint.HUE_OFFSET_DEG, [-60, -45, -30, -15, 0, 15, 30, 45], 'hue 档位表(不对称:−60…+45)');
  eq(Tint.MUL, [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3], '亮度/饱和度乘法档位表');
  eq(Tint.NEUTRAL, { hue: Core.HUE_NEUTRAL, bri: Core.BRI_NEUTRAL, sat: Core.SAT_NEUTRAL,
                     alpha: Core.ALPHA_NEUTRAL },
     '★ 中性档直接取自 Core(不自己抄一份)');
  ok(Tint.NEUTRAL.hue === 4 && Tint.NEUTRAL.alpha === 7,
     '★ 三列的中性档不在同一行:色相/亮度/饱和在档 4,alpha 在档 7');
  eq(Tint.hueOffsetOf(4), 0, 'hue 中性档 4 → 0°');
  eq(Tint.mulOf(4), 1, '亮度/饱和度中性档 4 → ×1.0(恒等元)');
  eq(Tint.alphaScaleOf(7), 1, 'alpha 中性档 7 → ×1');
  ok(Math.abs(Tint.alphaScaleOf(4) - 4 / 7) < 1e-12, '★ alpha 档 4 是 4/7 而不是 1');
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

  // ==== 相位 ③ tint.js 对 core.js 的依赖是结构性的 ====
  (function () {
    const saveCore = globalThis.Core, saveTint = globalThis.Tint;
    const p = require.resolve('./tint.js');
    delete require.cache[p];
    delete globalThis.Core;
    let err = null;
    try { require('./tint.js'); } catch (e) { err = e; }
    delete require.cache[p];
    globalThis.Core = saveCore;
    globalThis.Tint = saveTint;
    ok(err !== null && /core\.js/.test(String(err.message)),
       '★ 没有 Core 时 tint.js 当场抛错(常量是派生来的,不是抄来的):' + (err ? err.message : '(没抛)'));
  })();

  // ==== 相位 ④ golden:手工从规格 §2.3 推导的期望值 ====
  // (这一组是"编辑器与游戏 shader 必须逐像素一致"的唯一硬证据 ——
  //  期望值全部手推,不是拿实现跑出来的。)
  (function () {
    const N = Core.neutralDesc(1);
    // 纯红 (255,0,0) → HSV(0,1,1)。
    // H=5(+15°):h'=15 → 扇区 0 → c=1,x=1*(1-|fposmod(0.25,2)-1|)=0.25 → (1,0.25,0) → (255,64,0)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 5, 4, 7, 7)), [255, 64, 0, 255],
       '★ golden: 纯红 +15° 色相 → (255,64,0)');
    // H=3(−15°):h'=fposmod(-15,360)=345 → 扇区 5 → c=1,x=0.25 → (1,0,0.25) → (255,0,64)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 3, 4, 7, 7)), [255, 0, 64, 255],
       '★ golden: 纯红 −15° 色相 → (255,0,64)');
    // H=0(−60°):h'=300 → 扇区 5 → x=1 → (1,0,1) 品红 → (255,0,255)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 0, 4, 7, 7)), [255, 0, 255, 255],
       '★ golden: 纯红 −60° → 品红(色相在 360° 上环绕)');
    // H=7(+45°):h'=45 → 扇区 0 → x=1*(1-|0.75-1|)=0.75 → (1,0.75,0) → (255,191,0)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 7, 4, 7, 7)), [255, 191, 0, 255],
       '★ golden: 纯红 +45° 色相 → (255,191,0)');
    // 白: s=0,v=1。B=2(×0.8) → v'=0.8 → 0.8*255=204
    eq(Tint.tintBytes(255, 255, 255, 255, Core.packDesc(1, 4, 2, 4, 7)), [204, 204, 204, 255],
       '★ golden: 白 ×0.8 亮度 → 204');
    // 中灰 128/255 × 0.8 = 0.40157 → 102.4 → round 102(加法变亮会得到 77)
    eq(Tint.tintBytes(128, 128, 128, 255, Core.packDesc(1, 4, 2, 4, 7)), [102, 102, 102, 255],
       '★ golden: 中灰 ×0.8 亮度 → 102(**乘法**不是加法)');
    // S=0(×0.6): 纯红 s=1 → 0.6 → HSV(0,0.6,1) → (1,0.4,0.4) → (255,102,102)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 0, 7)), [255, 102, 102, 255],
       '★ golden: 纯红 ×0.6 饱和度 → (255,102,102)');
    eq(Tint.tintBytes(255, 255, 255, 255, Core.packDesc(1, 4, 4, 0, 7)), [255, 255, 255, 255],
       '★ golden: 白 ×0.6 饱和度 → 仍是白(s=0 时饱和度无效)');
    // S=7(×1.3)作用在已饱和的红上会被 clamp 到 1 —— 不许出越界通道
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 7, 7)), [255, 0, 0, 255],
       '★ golden: 饱和度已满时 ×1.3 被 clamp(不越界)');
    // A=3: a' = 255 × 3/7 = 109.2857 → 109
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 4, 3)), [255, 0, 0, 109],
       '★ golden: alpha 档 3 → 109(= 255×3/7)');
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 4, 0)), [255, 0, 0, 0],
       '★ golden: alpha 档 0 → 0(全透明,颜色不受影响)');
    eq(Tint.tintBytes(255, 0, 0, 255, N), [255, 0, 0, 255], '中性描述符是恒等:纯红');
    // 浮点规范定义与 8 位落地是同一件事
    const f = Tint.tintRGBA(1, 0, 0, 1, Core.neutralDesc(1));
    ok(f.r === 1 && f.g === 0 && f.b === 0 && f.a === 1, 'tintRGBA: 中性描述符下浮点也是恒等');
    const g = Tint.tintRGBA(1, 0, 0, 1, Core.packDesc(1, 5, 4, 7, 7));
    ok(Math.abs(g.g - 0.25) < 1e-12, 'tintRGBA: 浮点值是 0.25(取整只发生在 tintBytes 里)');
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 5, 4, 7, 7))[1], Math.round(0.25 * 255),
       'tintBytes 的取整规则 = Math.round(x*255),只此一处');
  })();

  // ==== 相位 ⑤ 穷举:中性描述符对 8 位输入逐字节恒等 ====
  (function () {
    const vals = [0, 1, 2, 3, 17, 63, 64, 127, 128, 129, 191, 254, 255];
    let bad = 0, n = 0;
    for (const R of vals) for (const G of vals) for (const B of vals) for (const A of vals) {
      n++;
      const o = Tint.tintBytes(R, G, B, A, Core.neutralDesc(1));
      if (o[0] !== R || o[1] !== G || o[2] !== B || o[3] !== A) bad++;
    }
    ok(bad === 0, '★ 中性描述符对 ' + n + ' 组 8 位输入逐字节恒等(含非灰度色)');
    // 浮点往返:rgb → hsv → rgb 的最大误差必须远小于一个 8 位刻度(1/255 ≈ 0.0039)
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

  // ==== 相位 ⑥ 贴图块定位与 16×16 小图 ====
  (function () {
    eq(Tint.textureBlockRect(1, 320), { x: 0, y: 0, w: 32, h: 32 }, 'textureBlockRect: 第 1 块在左上');
    eq(Tint.textureBlockRect(10, 320), { x: 288, y: 0, w: 32, h: 32 }, 'textureBlockRect: 第 10 块在第一行行尾');
    eq(Tint.textureBlockRect(11, 320), { x: 0, y: 32, w: 32, h: 32 }, 'textureBlockRect: 第 11 块换行(每行 10 块)');
    eq(Tint.textureBlockRect(21, 320), { x: 0, y: 64, w: 32, h: 32 }, 'textureBlockRect: 第 21 块(第三行首块 = 水)');
    eq(Tint.textureBlockRect(22, 320), { x: 32, y: 64, w: 32, h: 32 }, 'textureBlockRect: 第 22 块(水面)');
    let inside = true;
    for (let t = 1; t <= 22; t++) {
      const r = Tint.textureBlockRect(t, 320);
      if (r.x < 0 || r.y < 0 || r.x + r.w > 320 || r.y + r.h > 320) inside = false;
    }
    ok(inside, 'textureBlockRect: 22 块纹理全部落在 320×320 的 structure.png 里');
    throws(function () { Tint.textureBlockRect(0, 320); }, 'textureBlockRect: 纹理号 0 抛错', '纹理号');

    const atlas = makeAtlas();
    const neutral = Core.neutralDesc(3);
    const px = Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 0, neutral);
    ok(px instanceof Uint8ClampedArray && px.length === 16 * 16 * 4, 'buildTilePixels: 返回 16×16 RGBA');
    let upscaled = true;
    for (let y = 0; y < 16; y++) {
      for (let x = 0; x < 16; x++) {
        const o = (y * 16 + x) * 4;
        const sx = Math.floor(x / 2), sy = Math.floor(y / 2);
        if (px[o] !== sx * 8 || px[o + 1] !== sy * 8 || px[o + 2] !== 2 || px[o + 3] !== 255) upscaled = false;
      }
    }
    ok(upscaled, '★ buildTilePixels: 取纹理 3 的 (0,0) 象限,8px 最近邻放大 2× 成 16×16');

    const q = Tint.buildTilePixels(atlas, ATLAS_W, 3, 2, 1, neutral);
    let quadOk = true;
    for (let y = 0; y < 16; y++) {
      for (let x = 0; x < 16; x++) {
        const o = (y * 16 + x) * 4;
        const sx = 16 + Math.floor(x / 2), sy = 8 + Math.floor(y / 2);
        if (q[o] !== sx * 8 || q[o + 1] !== sy * 8) quadOk = false;
      }
    }
    ok(quadOk, '★ buildTilePixels: 象限 (2,1) 取的是块内 (16..23, 8..15)(取角映射)');

    // 端到端:白图集 + 亮度档 2 → 整块 204(与相位 ④ 手推的 golden 同源)
    const white = makeAtlas();
    for (let i = 0; i < white.length; i += 4) { white[i] = 255; white[i + 1] = 255; white[i + 2] = 255; }
    const wt = Tint.buildTilePixels(white, ATLAS_W, 1, 1, 3, Core.packDesc(1, 4, 2, 4, 7));
    let all204 = true;
    for (let i = 0; i < wt.length; i += 4) {
      if (wt[i] !== 204 || wt[i + 1] !== 204 || wt[i + 2] !== 204 || wt[i + 3] !== 255) all204 = false;
    }
    ok(all204, '★ buildTilePixels 端到端:白图集 + 亮度档 2 → 整块 16×16 全是 204');

    throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 0, Core.DESC_AIR); },
           'buildTilePixels: 空气格没有贴图,抛错', '空气');
    throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 31, 0, 0, neutral); },
           'buildTilePixels: 图集里没有这块(越出下边界)抛错', '图集');
  })();

  // ==== 断言区结束 ====
  console.log('');
  console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
  if (fail === 0) console.log('TINT SMOKE OK');
  process.exit(fail === 0 ? 0 : 1);
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
