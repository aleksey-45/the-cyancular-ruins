class_name ReloadRing
extends Node2D

# 换弹圆环:角色后侧的小圆环 + 一位小数倒计时。接口与 main 的 reload_ring.gd 一致 ——
# 宿主每帧调 `set_progress(progress, remain)`;由 player_present 之类的表现层负责挂接/显隐。
# 本控件是自绘控件(画布例外),几何常量留在局部空间;颜色/字体取 v2 设计系统 token。
# 语义色按设计系统 HUD 规则:装填进度 = 强调青(C_ACCENT),底环 = 弱化描边色压暗,数字 = C_TEXT。

const RADIUS := 24.0
const WIDTH := 9.0
const FONT_SIZE := UiDesign.T_H2   # 32:像素字体只在 16 的倍数下锐利

const C_BACK := Color(UiDesign.C_BORDER_DIM, 0.22)
const C_ARC := Color(UiDesign.C_ACCENT, 0.9)
const C_TEXT := Color(UiDesign.C_TEXT, 0.92)

var _progress := 0.0
var _remain := 0.0


func _ready() -> void:
	z_index = 100


func set_progress(progress: float, remain: float) -> void:
	var p := clampf(progress, 0.0, 1.0)
	var r := maxf(remain, 0.0)
	if is_equal_approx(p, _progress) and is_equal_approx(r, _remain):
		return
	_progress = p
	_remain = r
	queue_redraw()


func _draw() -> void:
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 48, C_BACK, WIDTH, true)
	if _progress > 0.0:
		# 从 12 点方向顺时针画进度弧。
		draw_arc(Vector2.ZERO, RADIUS, -PI * 0.5, -PI * 0.5 + TAU * _progress,
				48, C_ARC, WIDTH, true)
	var f: Font = UiDesign.pixel_font()
	var txt := "%.1f" % _remain
	var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var baseline := (f.get_ascent(FONT_SIZE) - f.get_descent(FONT_SIZE)) * 0.5
	draw_string(f, Vector2(-w * 0.5, baseline), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, C_TEXT)
