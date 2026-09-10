class_name EnemyHpBar
extends Node2D

# 对手头顶血条(可选视觉,实验分支 KikuchiHeinr):两段矩形,ratio 由快照 hp 驱动。
# 挂在 pvp_client 的 UI 层(不随副本旋转/翻转),位置每帧贴到对手头顶。

const SIZE := Vector2(84, 9)

var ratio := 1.0:
	set(v):
		ratio = clampf(v, 0.0, 1.0)
		queue_redraw()


func _draw() -> void:
	var back := Rect2(-SIZE * 0.5 - Vector2(2, 2), SIZE + Vector2(4, 4))
	draw_rect(back, Color(0.0, 0.0, 0.0, 0.45))
	if ratio <= 0.0:
		return
	var col := Color(0.35, 0.9, 0.4) if ratio > 0.25 else Color(0.95, 0.35, 0.3)
	draw_rect(Rect2(-SIZE * 0.5, SIZE * Vector2(ratio, 1.0)), col)
