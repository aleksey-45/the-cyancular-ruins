class_name PickupPrompt
extends Node2D

# 武器拾取提示:世界坐标里的小方框 + 按键字母。接口与 main 的 pickup_prompt.gd 一致 ——
# 挂点用 `PickupPrompt.GAP_ABOVE` 定位(Node2D,拾取物子节点,scale 由挂点换算世界/像素比)。
# 本控件是**自绘**控件:_draw 里的方框/描边/字位置是美术几何(画布例外,不是布局坐标);
# 颜色与字体一律取 v2 设计系统 token,不写字面量。
# 旧版青绿配色 → v2:半透明深底 + 强调青双描边 + 纯白按键字(与 HUD 底板同一语汇)。

const BOX := Vector2(50.0, 50.0)          # 自绘外框尺寸(美术几何)
const INNER_INSET := 7.0                  # 内框距外框的距离
const BORDER := 3.0                       # 描边粗细
const FONT_SIZE := UiDesign.T_H2          # 32:像素字体只在 16 的倍数下锐利
const GAP_ABOVE := float(UiDesign.SP_9)   # 挂在拾取物上方 64px(main 同值,挂点直接引用)

# 颜色全部由 UiDesign token 派生(不做第二份调色板):底色 = 面板表面色压半透明,
# 双描边 = 强调青(不透明外圈 + 55% 内圈),按键字 = C_WHITE。
const C_BG := Color(UiDesign.C_SURFACE, 0.72)
const C_OUTER := UiDesign.C_ACCENT
const C_INNER := Color(UiDesign.C_ACCENT, 0.55)
const C_TEXT := UiDesign.C_WHITE

const KEY_TEXT := "F"


func _ready() -> void:
	# 世界内自绘 UI:压在地形/拾取物之上(与 main 同值)。
	z_index = 100


func _draw() -> void:
	var half := BOX * 0.5
	var outer := Rect2(-half, BOX)
	draw_rect(outer, C_BG, true)
	_stroke(outer, C_OUTER)
	var ins := Vector2(INNER_INSET, INNER_INSET)
	_stroke(Rect2(-half + ins, BOX - ins * 2.0), C_INNER)

	var f: Font = UiDesign.pixel_font()
	var w := f.get_string_size(KEY_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var baseline := (f.get_ascent(FONT_SIZE) - f.get_descent(FONT_SIZE)) * 0.5
	var pos := Vector2(-w * 0.5, baseline)
	# 像素字体单字太细:右上偏移 1px 重画 4 次做伪粗体(与 main 一致的画法)。
	for off in [Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		draw_string(f, pos + off, KEY_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, C_TEXT)


func _stroke(r: Rect2, c: Color) -> void:
	draw_rect(Rect2(r.position, Vector2(r.size.x, BORDER)), c, true)
	draw_rect(Rect2(r.position + Vector2(0.0, r.size.y - BORDER), Vector2(r.size.x, BORDER)), c, true)
	draw_rect(Rect2(r.position, Vector2(BORDER, r.size.y)), c, true)
	draw_rect(Rect2(r.position + Vector2(r.size.x - BORDER, 0.0), Vector2(BORDER, r.size.y)), c, true)
