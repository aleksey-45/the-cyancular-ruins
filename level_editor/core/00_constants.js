// core/00_constants.js —— 网格与图层常量。分片约束 / 格式规格 / 推导见 docs/eng/editor-core.md。

'use strict';

const SUB_PER_CELL = 4;          // 每 64px 格细分成 4×4 个 16px 子格(规格 §2.1)
const SUB_PX = 16;               // 子格边长(世界像素)
const CELL_PX = 64;              // 格边长(世界像素)

const LAYER_COUNT = 4;           // 顺序从外到内:前景 / 场景 / 后景 / 背景;只有「场景」参与碰撞
const LAYER_FRONT = 0, LAYER_SCENE = 1, LAYER_BACK = 2, LAYER_BG = 3;
const LAYER_NAMES = ['前景', '场景', '后景', '背景'];
const LAYER_KINDS = ['tex', 'tex', 'tex', 'color'];
