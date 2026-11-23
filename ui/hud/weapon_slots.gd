class_name WeaponSlots
extends Control

# 左下角容量格子（4×2，三态色）。布局由 HUD 的容器驱动；本控件只按布局数据自绘格子，
# 颜色全部引用 UI 设计系统 v2 的 UiDesign slot token（不写 Color 字面量）。

const COLS := 4
const CELL := 22.0       # 格子边长（设计像素档；4×2 布局与格子大小不 token 化）
const GAP := 3.0         # 格子间距
const PAD := 6.0         # 面板四周留白
const PANEL_W := COLS * CELL + (COLS - 1) * GAP + PAD * 2.0

var _layout := PackedInt32Array([-1, 0])

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(PANEL_W, row_height(1))

## 布局 = WeaponInventory.cell_layout()：[当前武器索引, 背包容量, (类型, 占格数)×N]。
func show_inventory(layout: PackedInt32Array) -> void:
	_layout = layout
	var capacity := _capacity()
	var rows := row_count(capacity)
	custom_minimum_size = Vector2(PANEL_W, row_height(rows))
	queue_redraw()

static func row_count(capacity: int) -> int:
	return maxi(1, ceili(float(maxi(capacity, 0)) / COLS))

static func row_height(rows: int) -> float:
	return rows * (CELL + GAP) - GAP + PAD * 2.0

func _capacity() -> int:
	return maxi(0, _layout[1]) if _layout.size() > 1 else 0

func _draw() -> void:
	var panel := Vector2(PANEL_W, custom_minimum_size.y)
	draw_rect(Rect2(Vector2.ZERO, panel), UiDesign.C_PLATE)
	var capacity := _capacity()
	if capacity <= 0:
		_draw_cell(0, UiDesign.C_SLOT_EMPTY)
		return
	var current := _layout[0]
	var first := 0
	for slot in range(2, _layout.size() - 1, 2):
		var end := mini(first + _layout[slot + 1], capacity)
		var color := UiDesign.C_SLOT_ACTIVE if ((slot - 2) / 2) == current else UiDesign.C_SLOT_FILLED
		for cell in range(first, end):
			_draw_cell(cell, color)
		first = end
	for cell in range(first, capacity):
		_draw_cell(cell, UiDesign.C_SLOT_EMPTY)

func _draw_cell(cell: int, color: Color) -> void:
	var point := Vector2(PAD, PAD) + Vector2(cell % COLS, cell / COLS) * (CELL + GAP)
	draw_rect(Rect2(point, Vector2(CELL, CELL)), color)
