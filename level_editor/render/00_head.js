// render/00_head.js —— 'use strict' + 依赖守卫 + 缩放/预算常量;加载顺序 core → tile_defs → tint → render(见 editor.html),本层顶层一行都不碰 DOM。
'use strict';

var RenderCore = globalThis.Core, Tint = globalThis.Tint;   // ★ 不叫 Core:ui/00_head.js 的顶层 var Core 会被 hoist 成拼接后整段的局部名,各片加载期裸读它会拿到 undefined(parts_check 的"全局影子"闸);Tint 全仓只有这一处顶层声明,不存在这个遮蔽
if (!RenderCore) throw new Error('render.js: 必须先加载 core.js');
if (!Tint) throw new Error('render.js: 必须先加载 tint.js');

var SUB = RenderCore.SUB_PER_CELL;

var MIN_ZOOM = 1, MAX_ZOOM = 64;              // px / 子格
var ZOOM_THRESHOLD = 8;                       // 分工阈:< 8 走缩略图,≥ 8 走视口离屏层
var THUMB_PX = 2;                             // 缩略图 2px/子格
var THUMB_MAX_BYTES = 24 * 1024 * 1024;       // 超过就降到 1px/子格(400×300 格 @2px = 30MB,偏大)
var DEFAULT_BUDGET_MS = 8;                    // 闸 2 的单帧 CPU 预算
var DEFAULT_CELL_MAX = 8192;                  // ③ 的条目上限:8192 条 ≈ 1MB(条目只是 16 个 tile 引用,像素只存在 ④ 里,由它自己的上限管)
