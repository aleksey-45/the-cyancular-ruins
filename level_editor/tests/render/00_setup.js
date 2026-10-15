'use strict';
// tests/render/00_setup.js —— 装载被测模块 + 本套件的替身与记账助手(后面的分片裸名引用)。
// ★ 加载顺序是硬依赖:core → tint → render(tint 要 Core,render 要两者)。
const loader = require('../../loader.js');
loader.loadModules(['core', 'tint', 'render']);
const Core = globalThis.Core;
// 合成图集:3 行 × 10 列、每块 32×32(R = 块内 x×8,G = 块内 y×8,B = 块号)。
const COLS = 10, ATLAS_W = COLS * 32, ATLAS_H = 96;
function makeAtlas() {
  const a = new Uint8ClampedArray(ATLAS_W * ATLAS_H * 4);
  for (let y = 0; y < ATLAS_H; y++) {
    for (let x = 0; x < ATLAS_W; x++) {
      const i = (y * ATLAS_W + x) * 4;
      a[i] = (x % 32) * 8; a[i + 1] = (y % 32) * 8;
      a[i + 2] = Math.floor(y / 32) * COLS + Math.floor(x / 32); a[i + 3] = 255;
    }
  }
  return a;
}
// 记录型 backend:每次建图都记账,于是能断言"空气没有进 Tint"(只判颜色是抓不住它的)。
function spyBackend() {
  const calls = [];
  return {
    calls: calls,
    createTile: function (pixels, size) { calls.push({ size: size }); return { fake: true, n: calls.length }; },
  };
}
function makeMap(cellsW, cellsH) {
  const m = Core.createMap('t', cellsW, cellsH);
  return m;
}
function setCells(map, L, list, descOf) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (const c of list) a[c[1] * map.subCols + c[0]] = descOf(c[0], c[1]);
  return map;
}
// ── 相位 ⑩ 的替身:一个把每次 ctx 调用都记下来的假画布 ──
// ★ this.fillStyle / this.globalAlpha 在调用那一刻取:渲染代码是"先设样式再画",不看取值时点就分不出用了哪个颜色。
function fakeCtx() {
  const ops = [];
  const c = {
    ops: ops,
    imageSmoothingEnabled: true, globalAlpha: 1,
    fillStyle: '', strokeStyle: '', font: '', textAlign: '', textBaseline: '', lineWidth: 1,
    setTransform: function () {}, save: function () {}, restore: function () {},
    beginPath: function () {},
    moveTo: function (x, y) { ops.push({ op: 'moveTo', x: x, y: y }); },
    lineTo: function () {},
    stroke: function () { ops.push({ op: 'stroke', style: String(this.strokeStyle) }); },
    fillRect: function (x, y, w, h) {
      ops.push({ op: 'fillRect', style: String(this.fillStyle), alpha: this.globalAlpha, x: x, y: y, w: w, h: h });
    },
    clearRect: function (x, y, w, h) { ops.push({ op: 'clearRect', x: x, y: y, w: w, h: h }); },
    drawImage: function (img, x, y, w, h) {
      // ★ img 也记下来:② 之后主画布上画的是离屏层那张画布(不是小图),而
      //   (数次数是分不出来的:一层的副本数与别的层一样)。
      // ★ comp 是调用那一刻的 globalCompositeOperation:平移的自拷贝用 'copy'
      ops.push({ op: 'drawImage', img: img, comp: this.globalCompositeOperation,
                 alpha: this.globalAlpha, x: x, y: y, w: w, h: h });
    },
    fillText: function (t, x, y) { ops.push({ op: 'fillText', t: String(t), x: x, y: y }); },
    strokeRect: function (x, y, w, h) {
      ops.push({ op: 'strokeRect', style: String(this.strokeStyle), x: x, y: y, w: w, h: h });
    },
  };
  return c;
}
function fakeCanvas(w, h) {
  const c = { width: w | 0, height: h | 0, parentElement: null, ctx: fakeCtx() };
  c.getContext = function () { return c.ctx; };
  return c;
}
// 把一整层的每一格都写成同一个值(背景层 = 一个颜色,纹理层 = 一个描述符)
function fillSub(map, L, v) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  a.fill(v >>> 0);
  return map;
}
function countOps(ctx, prop, val) {
  return ctx.ops.filter(function (o) { return o[prop] === val; }).length;
}
function someOp(ctx, fn) { return ctx.ops.some(fn); }
// ★ 主画布上被 drawImage 过的画布对象(按出现顺序,允许重复):② 之后"这一层有没有
function drawnImages(ctx) {
  return ctx.ops.filter(function (o) { return o.op === 'drawImage' && o.img; })
    .map(function (o) { return o.img; });
}
// ★ 从 made 里挑出"尺寸等于主画布"的那几张 —— 就是 ② 的离屏层(缩略图的尺寸是
//   子格数 × 刻度,两者只有在极小图上才会撞上;这一批用到的图都撞不上)。
function layerCanvasesSince(made, sinceIdx, w, h) {
  return made.slice(sinceIdx).filter(function (c) { return c.width === w && c.height === h; });
}
// 拖动相位(70/80)共用的几何与记账助手。
const SB = Core.SUB_PER_CELL, ZD = 16;
function subPx(sx, sy) { return { x: sx * ZD, y: sy * ZD }; }
function drawnOps(off) { return off.ctx.ops.filter(function (o) { return o.op === 'drawImage'; }); }
// ★ 逐子格按对象身份判"这一格画的是不是这些 tile":同一格允许多次落笔(条带按格迭代,相邻条带各画一次同位置)。
function cellMatches(off, cx, cy, tiles) {
  for (let k = 0; k < SB * SB; k++) {
    const p = subPx(cx * SB + (k % SB), cy * SB + Math.floor(k / SB));
    const got = drawnOps(off).filter(function (o) { return o.x === p.x && o.y === p.y; });
    if (got.length < 1 || !got.every(function (o) { return o.img === tiles[k]; })) return false;
  }
  return true;
}
function cellAnyDraw(off, cx, cy) {
  for (let k = 0; k < SB * SB; k++) {
    const p = subPx(cx * SB + (k % SB), cy * SB + Math.floor(k / SB));
    if (drawnOps(off).some(function (o) { return o.x === p.x && o.y === p.y; })) return true;
  }
  return false;
}
// ★ 拖动必须锚在一份选区上:生产里 pointerdown 只在"按在选区里"时才起拖动,故 s.selection 与
function dragOn(rr, sel, dx, dy) {
  const cur = rr.selection();
  if (!cur || cur.x !== sel.x || cur.y !== sel.y || cur.w !== sel.w || cur.h !== sel.h) rr.setSelection(sel);
  rr.setSelDrag(sel, dx, dy);
}
// 各分片是独立模块,相位体照旧裸名调用这些助手;链上的顺序就是入口 require 的顺序。
globalThis.renderChain = Promise.resolve();
globalThis.dragState = {};
Object.assign(globalThis, { COLS: COLS, ATLAS_W: ATLAS_W, ATLAS_H: ATLAS_H, makeAtlas: makeAtlas,
  spyBackend: spyBackend, makeMap: makeMap, setCells: setCells, fakeCtx: fakeCtx,
  fakeCanvas: fakeCanvas, fillSub: fillSub, countOps: countOps, someOp: someOp,
  drawnImages: drawnImages, layerCanvasesSince: layerCanvasesSince, SB: SB, ZD: ZD, subPx: subPx,
  drawnOps: drawnOps, cellMatches: cellMatches, cellAnyDraw: cellAnyDraw, dragOn: dragOn });