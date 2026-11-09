class_name WeaponSlots
extends Control

# 左下角容量格子(4×2,三态色)。HUD 例外:用 anchors + UiFactory.MARGIN / SP_* 表达位置,
# 不再从逻辑分辨率反推坐标(契约 .tmp/ui-system-contract.md §5 / docs/eng/ui-design-system.md §5)。

const COLS := 4
const CELL := 22.0   # 格子边长(像素档;4×2 布局与格子大小是设计尺寸,不 token 化)
const GAP := 3.0     # 格子间距
const PAD := 6.0     # 面板四周留白

const PANEL_W := COLS * CELL + (COLS - 1) * GAP + PAD * 2.0

var capacity: int = WeaponInventory.DEFAULT_CAPACITY
var rows: int = rows_for(capacity)
var panel_h: float = panel_h_for(capacity)

# HUD 底板(黑 0.1)。★ 唯一源是 UiFactory.C_PLATE —— 本处是别名,不存字面量;单机 HUD 的那块挂在既有 PanelContainer 底板上,这个值只被联机两处用到。
const PLATE_COLOR := UiFactory.C_PLATE

var _weapons: WeaponComponent = null


static func rows_for(cap: int) -> int:
	return maxi(1, ceili(float(cap) / float(COLS)))


static func panel_h_for(cap: int) -> float:
	var r := rows_for(cap)
	return r * CELL + (r - 1) * GAP + PAD * 2.0


func _derive_layout() -> void:
	var cap := WeaponInventory.DEFAULT_CAPACITY
	if _weapons != null and _weapons.inventory != null:
		cap = _weapons.inventory.capacity
	capacity = maxi(1, cap)
	rows = rows_for(capacity)
	panel_h = panel_h_for(capacity)


static func attach_to(parent: Node, weapons: WeaponComponent) -> WeaponSlots:
	var s := WeaponSlots.new()
	s.setup(weapons)
	parent.add_child(s)
	# 左下角:锚 bottom-left + token(16 = SP_4;112 = SP_9+SP_8;8 = SP_2)。
	# 生产里 hud.gd 随后会用 _place_weapon_slots() 按武器面板实际顶边再贴一次(内容驱动)。
	s.anchor_left = 0.0
	s.anchor_right = 0.0
	s.anchor_top = 1.0
	s.anchor_bottom = 1.0
	s.offset_left = UiFactory.SP_4
	s.offset_top = -(UiFactory.SP_9 + UiFactory.SP_8) - s.panel_h - UiFactory.SP_2
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
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, panel_h)), PLATE_COLOR, true)

	if _weapons == null or _weapons.inventory == null:
		_draw_empty_cells()
		return

	var inv: WeaponInventory = _weapons.inventory
	var held: Array = inv.held
	if held.is_empty():
		_draw_empty_cells()
		return

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
