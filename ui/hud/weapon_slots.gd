class_name WeaponSlots
extends Control

const COLS := 4
const CELL := 22.0
const GAP := 3.0
const PAD := 6.0
const PANEL_W := COLS * CELL + (COLS - 1) * GAP + PAD * 2.0

var _layout := PackedInt32Array([0, 0])

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func show_inventory(layout: PackedInt32Array) -> void:
	_layout = layout
	var rows := maxi(1, ceili(float(layout[1]) / COLS))
	custom_minimum_size = Vector2(PANEL_W, rows * (CELL + GAP) - GAP + PAD * 2)
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, custom_minimum_size), UiFactory.C_PLATE)
	var first := 0
	for slot in range(2, _layout.size(), 2):
		var end := mini(first + _layout[slot + 1], _layout[1])
		var color := UiFactory.C_SLOT_ACTIVE if (slot - 2) / 2 == _layout[0] else UiFactory.C_SLOT_FILLED
		for cell in range(first, end):
			_draw_cell(cell, color)
		first = end
	for cell in range(first, maxi(1, _layout[1])):
		_draw_cell(cell, UiFactory.C_SLOT_EMPTY)

func _draw_cell(cell: int, color: Color) -> void:
	var point := Vector2(PAD, PAD) + Vector2(cell % COLS, cell / COLS) * (CELL + GAP)
	draw_rect(Rect2(point, Vector2(CELL, CELL)), color)

