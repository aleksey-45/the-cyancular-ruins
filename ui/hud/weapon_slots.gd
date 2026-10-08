class_name WeaponSlots
extends Control

# 武器背包槽位网格界面组件（通常显示于屏幕左下角）。
# 固定为 4 列，行数由背包总容量动态派生。
# 每个格子对应 1 点负重容量，武器按连续段紧凑排布。
# 槽位分为三种视觉状态：未占用、已占用、当前手持武器占用。

const COLS := 4
const CELL := 22.0        # 格子边长（像素）
const GAP := 3.0          # 格间距
const PAD := 6.0          # 底板内边距

# 面板宽度由列数与边距决定
const PANEL_W := COLS * CELL + (COLS - 1) * GAP + PAD * 2.0   # 109.0

# 背包容量与派生的行数及面板高度
var capacity: int = WeaponInventory.DEFAULT_CAPACITY
var rows: int = rows_for(capacity)
var panel_h: float = panel_h_for(capacity)

# 统一底板颜色
const PLATE_COLOR := UiFactory.C_PLATE

var _weapons: WeaponComponent = null


# 根据容量计算所需网格行数（至少 1 行）
static func rows_for(cap: int) -> int:
	return maxi(1, ceili(float(cap) / float(COLS)))


# 根据容量计算面板总高度
static func panel_h_for(cap: int) -> float:
	var r := rows_for(cap)
	return r * CELL + (r - 1) * GAP + PAD * 2.0


# 根据武器背包组件刷新容量、行数与面板尺寸
func _derive_layout() -> void:
	var cap := WeaponInventory.DEFAULT_CAPACITY
	if _weapons != null and _weapons.inventory != null:
		cap = _weapons.inventory.capacity
	capacity = maxi(1, cap)
	rows = rows_for(capacity)
	panel_h = panel_h_for(capacity)


# 实例化并挂载至父节点左下角布局
static func attach_to(parent: Node, weapons: WeaponComponent) -> WeaponSlots:
	var s := WeaponSlots.new()
	s.setup(weapons)
	parent.add_child(s)
	s.anchor_left = 0.0
	s.anchor_right = 0.0
	s.anchor_top = 1.0
	s.anchor_bottom = 1.0
	s.offset_left = 16.0
	s.offset_top = -112.0 - s.panel_h - 8.0   # 位于常规武器信息区域正上方
	s.offset_right = s.offset_left + PANEL_W
	s.offset_bottom = s.offset_top + s.panel_h
	return s


func setup(weapons: WeaponComponent) -> void:
	_weapons = weapons
	_derive_layout()
	custom_minimum_size = Vector2(PANEL_W, panel_h)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _weapons != null:
		_weapons.weapon_changed.connect(_on_changed)
		_weapons.inventory_changed.connect(refresh)
	refresh()


func _on_changed(_type_id: int) -> void:
	refresh()


func refresh() -> void:
	_derive_layout()
	queue_redraw()


func _draw() -> void:
	# 绘制半透明背景底板
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, panel_h)), PLATE_COLOR, true)

	if _weapons == null or _weapons.inventory == null:
		_draw_empty_cells()
		return

	var inv: WeaponInventory = _weapons.inventory
	var held: Array = inv.held
	if held.is_empty():
		_draw_empty_cells()
		return

	# 构建每个格子归属的武器索引映射（-1 表示未占用）
	var owner_of: Array[int] = []
	owner_of.resize(capacity)
	owner_of.fill(-1)
	for i in held.size():
		var cost: int = inv.cost_of(int(held[i]["type"]))
		var start: int = inv.cell_start(i)
		for c in range(start, start + cost):
			if c >= 0 and c < capacity:
				owner_of[c] = i

	for cell in capacity:
		var col := cell % COLS
		var row := cell / COLS
		var p := Vector2(PAD + col * (CELL + GAP), PAD + row * (CELL + GAP))
		var oi: int = owner_of[cell]
		var col_c := UiFactory.C_SLOT_EMPTY
		if oi >= 0:
			col_c = UiFactory.C_SLOT_ACTIVE if oi == _weapons._current_index else UiFactory.C_SLOT_FILLED
		draw_rect(Rect2(p, Vector2(CELL, CELL)), col_c, true)


func _draw_empty_cells() -> void:
	for cell in capacity:
		var col := cell % COLS
		var row := cell / COLS
		var p := Vector2(PAD + col * (CELL + GAP), PAD + row * (CELL + GAP))
		draw_rect(Rect2(p, Vector2(CELL, CELL)), UiFactory.C_SLOT_EMPTY, true)

