class_name ReloadRing
extends RefCounted

# 在角色脚下绘制换弹进度和剩余时间。

const RADIUS := 24.0
const WIDTH := 9.0
const FONT_SIZE := UiDesign.T_H2

const C_BACK := Color(UiDesign.C_BORDER_DIM, 0.22)
const C_ARC := Color(UiDesign.C_ACCENT, 0.9)
const C_TEXT := Color(UiDesign.C_TEXT, 0.92)

static func paint(target: CanvasItem, progress: float, remain: float) -> void:
	target.draw_circle(Vector2.ZERO, RADIUS + WIDTH * 0.5, Color(UiDesign.C_SURFACE, 0.85))
	target.draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 48, C_BACK, WIDTH, true)
	if progress > 0.0:
		# 从 12 点方向顺时针画进度弧。
		target.draw_arc(Vector2.ZERO, RADIUS, -PI * 0.5, -PI * 0.5 + TAU * progress,
				48, C_ARC, WIDTH, true)
	var f: Font = UiDesign.pixel_font()
	var txt := "%.1f" % remain
	var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var baseline := (f.get_ascent(FONT_SIZE) - f.get_descent(FONT_SIZE)) * 0.5
	target.draw_string(f, Vector2(-w * 0.5, baseline), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, C_TEXT)
