'use strict';
// tests/editor/00_setup.js —— 本套件的**文件级**助手。分片是各自独立的 CJS 模块,
// 后面的分片要能裸名调用它们 ⇒ 挂到全局(与 tests/tint/00_setup.js 同一手法)。
const Core = globalThis.Core;

const SUB = Core.SUB_PER_CELL;

// 一个"当前工具状态"的最小替身:map / layer / 描述符 / 画笔大小 / 选区。
function stOf(map, L) {
  return { map: map, layer: L, desc: Core.neutralDesc(5), rgba: 0xFF00FFFF,
           brushSize: 1, selection: null, descOnly: false };
}

// 把某一层整层填成一个值(tex 层填描述符,bg 层填 RGBA)。
function filled(map, L, desc) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (let i = 0; i < a.length; i++) a[i] = desc;
  return map;
}

// 某一层非零的格子数(断言"改了几格"用;别在断言里手抄层宽高)。
function countNonZero(map, L) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== 0) n++;
  return n;
}

Object.assign(globalThis, { SUB: SUB, stOf: stOf, filled: filled, countNonZero: countNonZero });
