class_name WeaponSlots
extends Control

# 4 列 × N 行的武器槽位格子(左下角)。每格 = 1 格容量;武器按**紧凑排布**占据连续的格子
# (见 WeaponInventory.cell_start)。三态:未占据=淡灰 / 已占据=淡青 / 手持那把占的格=深青。
#
# ★ **自包含**:能自己 new() 出来挂到任意节点下,不依赖任何 HUD 的继承关系。
#   PvpHud 与 RoyaleHud 是**并列的两个 `extends CanvasLayer`**(没有继承关系),
#   不存在"大乱斗复用 PvP 那块"这条路 —— 所以定位常量放在本文件里,三处引用同一组值。
#
# ★ **字号**必须是 16 的倍数(kh_l4/kh_l5 的字号规范扫描覆盖 res://ui 与 res://tests,
#   本文件不画字,故只受"别引入非 16 倍数字号载体"这一条约束)。格子**像素尺寸**不受该约定限制。

const COLS := 4
const CELL := 22.0        # 格子边长(用户 2026-09-16「缩小一点」:32 → 22)
const GAP := 3.0          # 格间距
const PAD := 6.0          # 底板内边距

# ★ PANEL_W 只跟**列数**有关 ⇒ 仍是常量(容量长大时格阵向下长,不换行宽)。
const PANEL_W := COLS * CELL + (COLS - 1) * GAP + PAD * 2.0   # 109.0

# 本实例的容量(= 背包容量,`_derive_layout` 里取)与由它派生的行数/面板高。
# ★ `ROWS := 2` / `PANEL_H := 59.0` 两个常量**已删**(2026-09-25):它们现在由容量派生。
#   删干净是刻意的 —— 留着常量名会让"静态读一个失效的值"编得过(**静默**),
#   而删掉之后每一处漏改都是解析期的错。
# ★ 三个初始化式的**声明顺序**是承重的:`rows`/`panel_h` 读上面那个 `capacity`。
var capacity: int = WeaponInventory.DEFAULT_CAPACITY
var rows: int = rows_for(capacity)
var panel_h: float = panel_h_for(capacity)

# HUD 底板(黑 0.1)。★ 唯一源是 `UiFactory.C_PLATE` —— 本处是**别名**,不存字面量。
# 单机 HUD 的那块挂在既有 PanelContainer 底板上,这个值只被联机两处用到。
const PLATE_COLOR := UiFactory.C_PLATE

var _weapons: WeaponComponent = null


# 容量 → 行数。列数恒 COLS,容量长大时**向下长**。
static func rows_for(cap: int) -> int:
	return maxi(1, ceili(float(cap) / float(COLS)))


# 容量 → 面板高(与 PANEL_W 同一套 PAD/GAP)。默认容量 8 ⇒ 2 行 ⇒ 59.0(与改动前逐字相同)。
static func panel_h_for(cap: int) -> float:
	var r := rows_for(cap)
	return r * CELL + (r - 1) * GAP + PAD * 2.0


# 从背包重取容量并重算行数/面板高。`setup()` 与 `refresh()` 都调它。
func _derive_layout() -> void:
	var cap := WeaponInventory.DEFAULT_CAPACITY
	if _weapons != null and _weapons.inventory != null:
		cap = _weapons.inventory.capacity
	capacity = maxi(1, cap)
	rows = rows_for(capacity)
	panel_h = panel_h_for(capacity)


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
	# ★ 这三行必须排在 `s.setup(weapons)` **之后** —— `panel_h` 是实例字段,由 setup 里的
	#   `_derive_layout()` 填。顺序反了会拿默认值算位置(容量非默认时格子面板错位)。
	s.offset_top = -112.0 - s.panel_h - 8.0   # 落在既有武器区(offset_top=-112)正上方
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
	# ★ 每次重取容量:容量/把数现在是**实例字段**(将来按能力分叉),改了之后格子阵要跟着长。
	#   今天生产路径上没有运行时改容量的地方 ⇒ 这一步恒等于 no-op(见已知边界)。
	_derive_layout()
	queue_redraw()


func _draw() -> void:
	# 自绘底板:比再套一层 PanelContainer 少一层节点,也不受容器布局摆布
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, panel_h)), PLATE_COLOR, true)

	if _weapons == null or _weapons.inventory == null:
		_draw_empty_cells()
		return

	var inv: WeaponInventory = _weapons.inventory
	var held: Array = inv.held
	if held.is_empty():
		_draw_empty_cells()
		return

	# 容量格 → 归属的背包下标(-1 = 未占)。紧凑排布保证是连续段。
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
		# ★ 整数除法(`cell` 与 `COLS` 都是 int):3 行的格阵靠它算出行号,别改成 float 除法。
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
