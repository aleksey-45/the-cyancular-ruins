class_name EnemyHpBar
extends Node2D


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
