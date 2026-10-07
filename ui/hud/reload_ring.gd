class_name ReloadRing
extends Node2D

# 换弹进度环指示器：在角色身旁显示换弹圆环进度与中心倒计时读数。
# 挂载于世界空间，位置随角色朝向与移动实时同步。

const RADIUS := 24.0
const WIDTH := 9.0
const FONT_SIZE := 32
const C_BACK := Color(0.42, 0.45, 0.50, 0.22)
const C_ARC := Color(0.80, 0.84, 0.88, 0.78)
const C_TEXT := Color(0.93, 0.95, 0.97, 0.92)

var _progress := 0.0
var _remain := 0.0


func _ready() -> void:
	z_index = 100


# 更新换弹进度与剩余时间（progress 区间 [0, 1]，remain 为剩余秒数）
func set_progress(progress: float, remain: float) -> void:
	var p := clampf(progress, 0.0, 1.0)
	var r := maxf(remain, 0.0)
	if is_equal_approx(p, _progress) and is_equal_approx(r, _remain):
		return
	_progress = p
	_remain = r
	queue_redraw()


func _draw() -> void:
	# 绘制背景底环与顺时针进度弧
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 48, C_BACK, WIDTH, true)
	if _progress > 0.0:
		draw_arc(Vector2.ZERO, RADIUS, -PI * 0.5, -PI * 0.5 + TAU * _progress,
				48, C_ARC, WIDTH, true)
	# 绘制环心倒计时秒数
	var f := PixelFont.shared()
	var txt := "%.1f" % _remain
	var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var baseline := (f.get_ascent(FONT_SIZE) - f.get_descent(FONT_SIZE)) * 0.5
	draw_string(f, Vector2(-w * 0.5, baseline), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, C_TEXT)
