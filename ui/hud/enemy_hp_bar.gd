class_name EnemyHpBar
extends Node2D

# 敌人头顶的血条使用世界坐标绘制，生命值低于 25% 时转为红色。

const SIZE := Vector2(84, 9)
const LOW_RATIO := 0.25

const C_BACK := Color(UiDesign.C_BG, 0.45)
const C_FILL := UiDesign.C_ACCENT
const C_LOW := UiDesign.C_DANGER

var ratio := 1.0:
	set(value):
		ratio = clampf(value, 0.0, 1.0)
		queue_redraw()


func _draw() -> void:
	# 底槽比条每边外扩 BORDER_W,保证浅色地形上也能读出条的位置。
	var pad := Vector2(UiDesign.BORDER_W, UiDesign.BORDER_W)
	var back := Rect2(-SIZE * 0.5 - pad, SIZE + pad * 2.0)
	draw_rect(back, C_BACK)
	if ratio <= 0.0:
		return
	draw_rect(Rect2(-SIZE * 0.5, SIZE * Vector2(ratio, 1.0)), C_LOW if ratio < LOW_RATIO else C_FILL)
