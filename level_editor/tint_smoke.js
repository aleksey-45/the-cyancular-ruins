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
  // ★★ 整表钉住(M2),不只钉中性档与档 4 两个采样点:变异实测 —— 把 ALPHA_NUM 的档 1 与
  //    档 2 **对调**,上面每一条(含 alphaScaleOf(4)=4/7 与 alphaScaleOf(7)=1)**全绿**,
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
    // ★ I3.3:纹理实参必须**就是**描述符里那个 —— 不一致时上面两条都拦不住(那块在坐标系里
    //   存在),旧实现会一声不响地画出**另一块砖**的像素(屏幕上是一块颜色不对的砖)。
    throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 0, Core.neutralDesc(5)); },
           '★ buildTilePixels: 纹理实参与描述符里的纹理不一致 → 抛错(不许画另一块砖)', '不一致');
    // ★ I3.2:象限坐标越界(含负数)一律抛 —— 旧实现靠 `%` 静默取负、靠 `& 3` 静默折到 3。
    throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, -1, 0, neutral); },
           '★ buildTilePixels: 象限坐标 -1 → 抛错(不许静默取负)', '象限坐标');
    throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 4, neutral); },
           '★ buildTilePixels: 象限坐标 4(越界)→ 抛错', '象限坐标');
    throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, 0.5, 0, neutral); },
           '★ buildTilePixels: 象限坐标 0.5(非整数)→ 抛错', '象限坐标');
  })();

  // ==== 相位 ⑦ tinted-tile 缓存(规格 §4.2 ④ / §4.3 闸 1)====
  (function () {
    // 注入式 backend:node 里没有 canvas,缓存把"画出来的像素"交给 backend ——
    // 我们记录它收到了什么,于是能断言"缓存给出去的像素 = 直算的像素"。
    const made = [];
    const backend = {
      createTile: function (pixels, size) {
        made.push({ pixels: pixels, size: size });
        return { fake: true, pixels: pixels, size: size };
      },
    };
    const atlas = makeAtlas();
    const N1 = Core.neutralDesc(1), N2 = Core.neutralDesc(2), N3 = Core.neutralDesc(3), N4 = Core.neutralDesc(4);

    // 没 setSource 就 get → 抛错(而不是画出一块空白)
    const bare = Tint.createTileCache({ backend: backend });
    throws(function () { bare.get(1, 0, 0, N1); }, 'createTileCache: 没 setSource 就 get → 抛错', 'setSource');

    const cache = Tint.createTileCache({ maxSize: 3, backend: backend });
    cache.setSource(atlas, ATLAS_W);
    const a = cache.get(3, 2, 1, Core.neutralDesc(3));
    eq(made.length, 1, '未命中才会让 backend 造图');
    ok(a && a.fake === true, 'get 返回的正是 backend 造出来的那个对象');
    sameBytes(made[0].pixels,
              Tint.buildTilePixels(atlas, ATLAS_W, 3, 2, 1, Core.neutralDesc(3)),
              '★ 缓存交给 backend 的像素与直接算的逐字节一致(缓存没有改坏像素)');
    eq(made[0].size, Tint.TILE_PX, 'backend 收到的尺寸是 16');
    ok(a === cache.get(3, 2, 1, Core.neutralDesc(3)), '相同键第二次命中同一个对象');
    eq(made.length, 1, '命中不再造图');
    eq(cache.stats(), { hits: 1, misses: 1, evictions: 0, size: 1, maxSize: 3 }, 'stats 记账(hits/misses/evictions/size)');
    ok(cache.has(3, 2, 1, Core.neutralDesc(3)), 'has: 命中');
    ok(!cache.has(3, 2, 1, Core.packDesc(3, 5, 4, 4, 7)),
       '★ 描述符不同 = 不同键(同一象限的不同辅码各存一份)');
    ok(!cache.has(2, 2, 1, Core.neutralDesc(3)), '★ 纹理不同 = 不同键');
    ok(!cache.has(3, 1, 1, Core.neutralDesc(3)), '★ 象限不同 = 不同键');

    // LRU:maxSize 3,塞第 4 个 → 最久未用的那个被淘汰
    cache.clear();
    cache.get(1, 0, 0, N1);            // A
    cache.get(2, 0, 0, N2);            // B
    cache.get(3, 0, 0, N3);            // C
    cache.get(1, 0, 1, N1);            // D → A 最久未用,被淘汰
    ok(!cache.has(1, 0, 0, N1), '★ LRU: 塞第 4 个时最久未用的那个被淘汰');
    ok(cache.has(2, 0, 0, N2) && cache.has(3, 0, 0, N3) && cache.has(1, 0, 1, N1), 'LRU: 其余三个还在');
    eq(cache.stats().size, 3, 'LRU: 容量守住 maxSize');
    ok(cache.stats().evictions >= 1, 'LRU: 淘汰计数被记上');
    cache.get(2, 0, 0, N2);            // 命中 → B 提到最近端
    cache.get(4, 0, 0, N4);            // E → 淘汰此时最久未用的 C
    ok(cache.has(2, 0, 0, N2), '★ LRU: 命中过的条目被提到最近端(没被淘汰)');
    ok(!cache.has(3, 0, 0, N3), '★ LRU: 被淘汰的是最久未用的那个');

    // ★★ 换图必须整片失效 —— 审计 A2 的原样翻版:
    //    旧编辑器在 structure.png 加载完成前写进纯色兜底且**永不失效**,
    //    于是地图一直是色块,还"有时好有时坏"。
    const beforeStats = cache.stats();
    cache.setSource(atlas, ATLAS_W);
    eq(cache.stats().size, 0, '★★ setSource 清空缓存(资源换了 = 缓存全废,不许留旧的色块)');
    ok(!cache.has(3, 0, 0, N3), 'setSource 之后旧条目查不到');
    ok(cache.stats().hits === beforeStats.hits && cache.stats().misses === beforeStats.misses,
       'setSource 不重置记账(hits/misses 是累计量)');
    const m0 = made.length;
    cache.get(3, 0, 0, N3);
    eq(made.length - m0, 1, 'setSource 之后同一个键会重新造(确实失效了,不是"命中旧图")');

    // maxSize 0 = 不缓存
    const nocache = Tint.createTileCache({ maxSize: 0, backend: backend });
    nocache.setSource(atlas, ATLAS_W);
    const m1 = made.length;
    nocache.get(1, 0, 0, N1);
    nocache.get(1, 0, 0, N1);
    eq(made.length - m1, 2, 'maxSize 0 → 每次都现造(不缓存)');
    eq(nocache.stats().size, 0, 'maxSize 0 → size 恒 0');
    eq(Tint.createTileCache({ backend: backend }).stats().maxSize, Tint.DEFAULT_MAX_TILES,
       '默认 maxSize = DEFAULT_MAX_TILES');

    // ★ 浏览器默认后端在 node 里必须**明确报错**,而不是悄悄画不出来
    throws(function () { Tint.DEFAULT_BACKEND.createTile(new Uint8ClampedArray(4), 1); },
           '★ DEFAULT_BACKEND 在 node(没有 document)里明确抛错', 'document');

    // ════════════ 下面三条(I2 / I3.1 / I3.2)刻意放在本块**最后**:
    //   上面好几条断言数的是 `made.length` 这类相对计数,插在中间会把它们整体挪位。
    //   各自用自己的 backend(与共享的 `made` 完全隔离)。

    // ── I3.1 命中判据:必须是 `has(k)`,不能是 `get(k) !== undefined` ──
    // ★ 一个返回 undefined 的 backend 在旧判据下:那张图**永不命中**,却已经占着槽位、
    //   计入 size、还能把活条目挤掉 —— 实测 {hits:0,misses:2,size:1} 且 has() 为 true。
    const undefBackend = { createTile: function () { return undefined; } };
    const uc = Tint.createTileCache({ maxSize: 3, backend: undefBackend });
    uc.setSource(atlas, ATLAS_W);
    uc.get(1, 0, 0, N1);
    uc.get(1, 0, 0, N1);
    eq(uc.stats(), { hits: 1, misses: 1, evictions: 0, size: 1, maxSize: 3 },
       '★★ 缓存: backend 返回 undefined 时**照样命中**(命中判据是 has(k),不是 get(k) !== undefined)');
    ok(uc.has(1, 0, 0, N1), '★ 缓存: 上面那条的条目 has() 为 true(与命中判据同一条)');

    // ── I3.2 键的象限约定必须与像素数学**同一条** ──
    // ★ 旧实现:键用 `(qx & 3)`、像素用 `qx % SUB_PER_CELL` ⇒ `get(3,-1,0,desc)` 会先造出
    //   一张**错图**并存进**象限 3 的键**,随后 `get(3,3,0,desc)` **直接命中那张错图**
    //   (两次调用返回同一个对象)。今天所有调用方都只循环 0..3,但"从坐标算象限"的
    //   调用方(2b 的环面 / 拖拽选区)出现负坐标很正常。
    const made2 = [];
    const backend2 = {
      createTile: function (pixels, size) {
        made2.push({ pixels: pixels, size: size });
        return { fake: true, pixels: pixels, size: size };
      },
    };
    const qc = Tint.createTileCache({ backend: backend2 });
    qc.setSource(atlas, ATLAS_W);
    throws(function () { qc.get(3, -1, 0, Core.neutralDesc(3)); },
           '★★ 缓存: 象限坐标 -1 → 抛错(不许"折到象限 3"再造出一张错图)', '象限坐标');
    eq(made2.length, 0, '★ 越界坐标连一张图都没造(抛出发生在建图之前)');
    eq(qc.stats().size, 0, '★ 越界坐标一个条目都没写进缓存(不留幽灵条目)');
    const q3 = qc.get(3, 3, 0, Core.neutralDesc(3));
    sameBytes(q3.pixels, Tint.buildTilePixels(atlas, ATLAS_W, 3, 3, 0, Core.neutralDesc(3)),
              '★★ 象限 3 拿到的是**正确**那张(旧实现在这里会命中 -1 那趟造出来的错图)');
    ok(qc.has(3, 3, 0, Core.neutralDesc(3)), '★ 象限 3 的键确实落在 3 上');

    // ── I2 setSource 的形状守卫:最自然的误用必须**当场抛**,不许静默画全透明 ──
    // ★ 传 `ImageData` **对象**而不是 `.data`:旧实现 `atlas.length` 是 undefined ⇒
    //   buildTilePixels 里 rows = NaN ⇒ 边界比较(`> NaN`)恒假 ⇒ 一路产出全透明小图。
    const shape = Tint.createTileCache({ backend: backend2 });
    throws(function () { shape.setSource({ data: atlas, width: ATLAS_W }, ATLAS_W); },
           '★★ setSource: 传 ImageData **对象**(而不是它的 .data)→ 抛错', 'RGBA 数组');
    throws(function () { shape.setSource(undefined, ATLAS_W); },
           '★ setSource: data 是 undefined → 抛错', 'RGBA 数组');
    throws(function () { shape.setSource(atlas, 6); },
           '★ setSource: 宽度不是 4 的倍数 → 抛错', '4 的倍数');
    throws(function () { shape.setSource(atlas, 0); },
           '★ setSource: 宽度 0 → 抛错', '4 的倍数');
    throws(function () { shape.setSource(atlas.subarray(0, 100), ATLAS_W); },
           '★ setSource: 字节数不是整行(宽×4)的整数倍 → 抛错(否则 rows 是分数)', '整数倍');
    // ★ 被形状闸拒掉的调用**不许**动到上一份图集(守卫在赋值之前)
    shape.setSource(atlas, ATLAS_W);
    const s1 = shape.get(3, 0, 0, N3);
    throws(function () { shape.setSource(atlas.subarray(0, 100), ATLAS_W); },
           '(对照)同一条非整行的数据依旧被拒', '整数倍');
    ok(shape.has(3, 0, 0, N3) && shape.get(3, 0, 0, N3) === s1,
       '★ 被形状闸拒掉的 setSource 不清缓存、不换图集(上一份还完好)');
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
