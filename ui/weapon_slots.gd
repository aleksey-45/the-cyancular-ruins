class_name WeaponSlots
extends Control

# 4×2 武器槽位格子(左下角)。每格 = 1 格容量;武器按**紧凑排布**占据连续的格子
# (见 WeaponInventory.slot_start)。三态:未占据=淡灰 / 已占据=淡青 / 手持那把占的格=深青。
#
# ★ **自包含**:能自己 new() 出来挂到任意节点下,不依赖任何 HUD 的继承关系。
#   PvpHud 与 RoyaleHud 是**并列的两个 `extends CanvasLayer`**(没有继承关系),
#   不存在"大乱斗复用 PvP 那块"这条路 —— 所以定位常量放在本文件里,三处引用同一组值。
#
# ★ 格子尺寸与字号都是 16 的倍数:kh_l4/kh_l5 的字号规范扫描覆盖 res://ui 与 res://tests。

const COLS := 4
const ROWS := 2
const CELL := 32.0        # 格子边长
const GAP := 4.0          # 格间距
const PAD := 8.0          # 底板内边距

const PANEL_W := COLS * CELL + (COLS - 1) * GAP + PAD * 2.0   # 164.0
const PANEL_H := ROWS * CELL + (ROWS - 1) * GAP + PAD * 2.0   # 84.0

# 与全局 HUD 底板同值(黑 0.1,见 CLAUDE.md 的「HUD 元素一律垫半透明深底板」)。
# 单机 HUD 的那块挂在既有 PanelContainer 底板上,这个值只被联机两处用到。
const PLATE_COLOR := Color(0, 0, 0, 0.1)

var _weapons: WeaponComponent = null


# 便捷挂载:建实例 + 接线 + 定位到左下角。三处 HUD 都用它,保证位置一致。
# ★ 只设锚点与尺寸,**不 add_child 之外的父级改动** —— 调用方可以之后自己微调 offset。
static func attach_to(parent: Node, weapons: WeaponComponent) -> WeaponSlots:
	var s := WeaponSlots.new()
	s.setup(weapons)
	parent.add_child(s)
	s.anchor_left = 0.0
	s.anchor_right = 0.0
	s.anchor_top = 1.0
	s.anchor_bottom = 1.0
	s.offset_left = 16.0
	s.offset_top = -112.0 - PANEL_H - 8.0   # 落在既有武器区(offset_top=-112)正上方
	s.offset_right = s.offset_left + PANEL_W
	s.offset_bottom = s.offset_top + PANEL_H
	return s


func setup(weapons: WeaponComponent) -> void:
	_weapons = weapons
	custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _weapons != null:
		_weapons.weapon_changed.connect(_on_changed)
		_weapons.inventory_changed.connect(refresh)
	refresh()


func _on_changed(_slot: int) -> void:
	refresh()


func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	# 自绘底板:比再套一层 PanelContainer 少一层节点,也不受容器布局摆布
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, PANEL_H)), PLATE_COLOR, true)

	if _weapons == null or _weapons.inventory == null:
		_draw_empty_cells()
		return

	var inv: WeaponInventory = _weapons.inventory
	var held: Array = inv.held
	if held.is_empty():
		_draw_empty_cells()
		return

	# 8 格 → 归属的背包下标(-1 = 未占)。紧凑排布保证是连续段。
	var owner_of: Array[int] = []
	owner_of.resize(WeaponInventory.CAPACITY)
	owner_of.fill(-1)
	for i in held.size():
		var cost: int = inv.cost_of(int(held[i]["type"]))
		var start: int = inv.slot_start(i)
		for c in range(start, start + cost):
			if c >= 0 and c < WeaponInventory.CAPACITY:
				owner_of[c] = i

	for cell in WeaponInventory.CAPACITY:
		var col := cell % COLS
		var row := cell / COLS
		var p := Vector2(PAD + col * (CELL + GAP), PAD + row * (CELL + GAP))
		var oi: int = owner_of[cell]
		var col_c := UiFactory.C_SLOT_EMPTY
		if oi >= 0:
			col_c = UiFactory.C_SLOT_ACTIVE if oi == _weapons._current_index else UiFactory.C_SLOT_FILLED
		draw_rect(Rect2(p, Vector2(CELL, CELL)), col_c, true)


func _draw_empty_cells() -> void:
	for cell in WeaponInventory.CAPACITY:
		var col := cell % COLS
		var row := cell / COLS
		var p := Vector2(PAD + col * (CELL + GAP), PAD + row * (CELL + GAP))
		draw_rect(Rect2(p, Vector2(CELL, CELL)), UiFactory.C_SLOT_EMPTY, true)
