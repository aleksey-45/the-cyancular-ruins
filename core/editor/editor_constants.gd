class_name EditorConstants
extends RefCounted

# 移植自已退役的浏览器编辑器 core/00_constants.js(2026-11-09 删除,历史见 git)—— 网格与图层常量(格式规格见 docs/eng/editor-core.md)。

const SUB_PER_CELL: int = 4          # 每 64px 格细分成 4×4 个 16px 子格
const SUB_PX: int = 16               # 子格边长(世界像素)
const CELL_PX: int = 64              # 格边长(世界像素)

const LAYER_COUNT: int = 7           # 前景 / 场景 / 后景 / 背景100% / 75% / 50% / 25%;只有「场景」参与碰撞
const LAYER_FRONT: int = 0
const LAYER_SCENE: int = 1
const LAYER_BACK: int = 2
const LAYER_BG: int = 3
# 背景是四层景深颜色平面(层号 = layer_flags 位 3..6);旧文件只有 bit0-3 ⇒ 层 4-6 为 null,不报错。
const LAYER_BG_FIRST: int = 3
const LAYER_BG_LAST: int = 6
const LAYER_BG_DEPTH := [1.0, 0.75, 0.5, 0.25]   # 下标 = 层号 - LAYER_BG_FIRST
const LAYER_NAMES := ["前景", "场景", "后景", "背景 100%", "背景 75%", "背景 50%", "背景 25%"]
const LAYER_KINDS := ["tex", "tex", "tex", "color", "color", "color", "color"]


# 颜色层判据的唯一来源(别在 UI / render 里再抄一份「L == LAYER_BG」)。
static func is_color_layer(layer: int) -> bool:
	return layer >= LAYER_BG_FIRST and layer <= LAYER_BG_LAST
