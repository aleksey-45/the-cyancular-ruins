class_name PickupPrompt
extends Node2D


const BOX := Vector2(50.0, 50.0)
const INNER_INSET := 7.0
const BORDER := 3.0
const FONT_SIZE := 32
const GAP_ABOVE := 64.0

const C_BG := Color(0.24, 0.42, 0.46, 0.72)
const C_OUTER := Color(0.35, 0.85, 0.90, 1.0)
const C_INNER := Color(0.20, 0.55, 0.62, 1.0)
const C_TEXT := Color(0.92, 0.97, 1.0, 1.0)


func _ready() -> void:
	z_index = 100


func _draw() -> void:
	var half := BOX * 0.5
	var outer := Rect2(-half, BOX)
	draw_rect(outer, C_BG, true)
	_stroke(outer, C_OUTER)
	var ins := Vector2(INNER_INSET, INNER_INSET)
	_stroke(Rect2(-half + ins, BOX - ins * 2.0), C_INNER)

	var f := PixelFont.shared()
	var w := f.get_string_size("F", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var baseline := (f.get_ascent(FONT_SIZE) - f.get_descent(FONT_SIZE)) * 0.5
	var pos := Vector2(-w * 0.5, baseline)
	for off in [Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		draw_string(f, pos + off, "F", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, C_TEXT)


func _stroke(r: Rect2, c: Color) -> void:
	draw_rect(Rect2(r.position, Vector2(r.size.x, BORDER)), c, true)
	draw_rect(Rect2(r.position + Vector2(0.0, r.size.y - BORDER), Vector2(r.size.x, BORDER)), c, true)
	draw_rect(Rect2(r.position, Vector2(BORDER, r.size.y)), c, true)
	draw_rect(Rect2(r.position + Vector2(r.size.x - BORDER, 0.0), Vector2(BORDER, r.size.y)), c, true)
