class_name GuideCanvas
extends Node2D

# UI 通道画布(不吃后处理的环境光/遮挡,只做叠加)。内容 = 瞄准线/预瞄弧/装填读条/伤害文字。
const FONT := PixelFont.FONT

var _lines: Array[Array] = []
var _circles: Array[Array] = []
var _arcs: Array[Array] = []
var _labels: Array[Array] = []


func begin() -> void:
	_lines.clear()
	_circles.clear()
	_arcs.clear()
	_labels.clear()


func submit() -> void:
	queue_redraw()


func line(points: PackedVector2Array, color: Color, width: float) -> void:
	_lines.append([points, color, width])


func circle(at: Vector2, radius: float, color: Color) -> void:
	_circles.append([at, radius, color])


func arc(at: Vector2, radius: float, start: float, end: float, color: Color, width: float) -> void:
	_arcs.append([at, radius, start, end, color, width])


func text_at(value: String, at: Vector2, color: Color, _plate := false, outline := 0) -> void:
	_labels.append([value, at, color, outline])


static func centered_baseline() -> float:
	return (FONT.get_ascent(32) - FONT.get_descent(32)) * 0.5


func _draw() -> void:
	for row in _lines:
		draw_polyline(row[0], row[1], row[2], true)
	for row in _arcs:
		draw_arc(row[0], row[1], row[2], row[3], 48, row[4], row[5], true)
	for row in _circles:
		draw_circle(row[0], row[1], row[2], true, -1.0, true)
	for row in _labels:
		if int(row[3]) > 0:
			draw_string_outline(FONT, row[1], row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 32, int(row[3]),
					Color8(10, 12, 16, 200))
		draw_string(FONT, row[1], row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 32, row[2])
