'use strict';
// tests/tint/00_setup.js —— 装载被测模块 + 本套件的合成图集(后面的分片裸名引用它)。
const loader = require('../../loader.js');
loader.loadModules(['core', 'tint']);

// 合成图集(3 行 × 10 列、每块 32×32):像素编码成 R/G = 块内 x/y × 8,B = 块号,A = 255。
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
Object.assign(globalThis, { makeAtlas: makeAtlas, COLS: COLS, ATLAS_W: ATLAS_W, ATLAS_H: ATLAS_H });   // 后面的分片裸名调用它们
