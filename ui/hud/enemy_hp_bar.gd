class_name EnemyHpBar
extends Node2D

# 敌人头顶血条(世界坐标自绘):深色底槽 + 按比例填充。接口与 main 的 enemy_hp_bar.gd 一致 ——
# 宿主(副本/分身表现层)设 `ratio` 即可,本类自己 queue_redraw。
# 自绘控件(画布例外):几何常量留在局部空间;颜色取 v2 token —— 旧版绿/红改为与 HUD 同源的
# 「强调青常态 / 危险红残血」,低血阈值与 main 相同(25%)。

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
