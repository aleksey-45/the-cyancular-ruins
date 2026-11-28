class_name PickupPrompt
extends RefCounted

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


static func paint(target: CanvasItem, key: String) -> void:
	var f := UiDesign.pixel_font()
	var w := f.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var box_size := Vector2(maxf(BOX.x, w + INNER_INSET * 3), BOX.y)
	var outer := Rect2(-box_size * 0.5, box_size)
	target.draw_rect(outer, C_BG, true)
	_stroke(target, outer, C_OUTER)
	_stroke(target, outer.grow(-INNER_INSET), C_INNER)

	var baseline := (f.get_ascent(FONT_SIZE) - f.get_descent(FONT_SIZE)) * 0.5
	var pos := Vector2(-w * 0.5, baseline)
	# 将像素字体错开 1 像素重复绘制，让单字按键更易辨认。
	for off in [Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		target.draw_string(f, pos + off, key, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, C_TEXT)


static func _stroke(target: CanvasItem, r: Rect2, c: Color) -> void:
	target.draw_rect(Rect2(r.position, Vector2(r.size.x, BORDER)), c, true)
	target.draw_rect(Rect2(r.position + Vector2(0.0, r.size.y - BORDER), Vector2(r.size.x, BORDER)), c, true)
	target.draw_rect(Rect2(r.position, Vector2(BORDER, r.size.y)), c, true)
	target.draw_rect(Rect2(r.position + Vector2(r.size.x - BORDER, 0.0), Vector2(BORDER, r.size.y)), c, true)
