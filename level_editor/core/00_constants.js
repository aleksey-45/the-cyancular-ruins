// core/00_constants.js —— 网格与图层常量。分片约束 / 格式规格 / 推导见 docs/eng/editor-core.md。

'use strict';

const SUB_PER_CELL = 4;          // 每 64px 格细分成 4×4 个 16px 子格(规格 §2.1)
const SUB_PX = 16;               // 子格边长(世界像素)
const CELL_PX = 64;              // 格边长(世界像素)

const LAYER_COUNT = 7;           // 顺序从外到内:前景 / 场景 / 后景 / 背景100% / 75% / 50% / 25%;只有「场景」参与碰撞
const LAYER_FRONT = 0, LAYER_SCENE = 1, LAYER_BACK = 2, LAYER_BG = 3;
// ★ 背景是**四层景深颜色平面**(层号 = layer_flags 位 3..6)。景深系数 f:100% = 与场景同速(最近)、25% 最远。
//   旧文件只有 bit0-3 ⇒ 层 4-6 为 null(不存在),不报错;旧读取器忽略 bit4-6 ⇒ 只看到背景100%。
const LAYER_BG_FIRST = 3, LAYER_BG_LAST = 6;
const LAYER_BG_DEPTH = [1.0, 0.75, 0.5, 0.25];   // 下标 = 层号 - LAYER_BG_FIRST
const LAYER_NAMES = ['前景', '场景', '后景', '背景 100%', '背景 75%', '背景 50%', '背景 25%'];
const LAYER_KINDS = ['tex', 'tex', 'tex', 'color', 'color', 'color', 'color'];
// 颜色层判据的唯一来源(别在 UI/render 里再抄一份"L === LAYER_BG")。
function isColorLayer(L) { return L >= LAYER_BG_FIRST && L <= LAYER_BG_LAST; }
