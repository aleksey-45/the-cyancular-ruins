class_name PickupPrompt
extends Node2D

# 在武器拾取位置上方绘制交互按键。

const BOX := Vector2(50.0, 50.0)          # 自绘外框尺寸(美术几何)
const INNER_INSET := 7.0                  # 内框距外框的距离
const BORDER := 3.0                       # 描边粗细
const FONT_SIZE := UiDesign.T_H2
const GAP_ABOVE := float(UiDesign.SP_9)

const C_BG := Color(UiDesign.C_SURFACE, 0.72)
const C_OUTER := UiDesign.C_ACCENT
const C_INNER := Color(UiDesign.C_ACCENT, 0.55)
const C_TEXT := UiDesign.C_WHITE

const KEY_TEXT := "F"


func _ready() -> void:
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
	# 将像素字体错开 1 像素重复绘制，让单字按键更易辨认。
	for off in [Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		draw_string(f, pos + off, KEY_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, C_TEXT)


func _stroke(r: Rect2, c: Color) -> void:
	draw_rect(Rect2(r.position, Vector2(r.size.x, BORDER)), c, true)
	draw_rect(Rect2(r.position + Vector2(0.0, r.size.y - BORDER), Vector2(r.size.x, BORDER)), c, true)
	draw_rect(Rect2(r.position, Vector2(BORDER, r.size.y)), c, true)
	draw_rect(Rect2(r.position + Vector2(r.size.x - BORDER, 0.0), Vector2(BORDER, r.size.y)), c, true)
