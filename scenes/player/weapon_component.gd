class_name WeaponComponent
extends Node

# 武器组件的**薄壳**:节点生命周期、启用类型、滚轮/上行输入、帧胶水与信号转发。
# 背包与手持的实现 = WeaponLoadout;整态武器段 = WeaponState。两者都不是 Node,可以脱离场景单测。
const WeaponLoadoutScript := preload("res://scenes/player/weapon_loadout.gd")
const WeaponState := preload("res://scenes/player/weapon_state.gd")

# ★ 场景路径 / 显示名 / 重量档三张常量表已整体删除:唯一来源是 data/weapons.json,由 core/sim/weapon_registry.gd(WeaponRegistry)读;这里不留任何副本,留一张就会与 json 分家。

signal weapon_changed(type_id: int)
signal inventory_changed()

var loadout = WeaponLoadoutScript.new()
var body: CharacterBody2D

# 跨域只读面(HUD / 探针 / 整态直接读它们的旧名字;实现搬进 loadout 后仍保持同一写法)。
var inventory: WeaponInventory:
	get:
		return loadout.inventory
var enabled_types: Array:
	get:
		return loadout.enabled_types
	set(v):
		loadout.enabled_types = v
var _current_index: int:
	get:
		return loadout.current_index()

var _switch_inst := 0


func _ready() -> void:
	body = get_parent() as CharacterBody2D
	loadout.setup(body)
	loadout.weapon_changed.connect(func(t: int) -> void: weapon_changed.emit(t))
	loadout.inventory_changed.connect(func() -> void: inventory_changed.emit())


# ── 启用类型 ──
func set_enabled_types(disabled: Array[int]) -> void:
	loadout.set_enabled_types(disabled)


func is_type_enabled(type_id: int) -> bool:
	return loadout.is_type_enabled(type_id)


func default_type() -> String:
	return loadout.default_type()


func set_initial_inventory(types: Array) -> void:
	loadout.set_initial_inventory(types)


# ── 切枪环 + 上行 inst(输入/协议面留在这里;背包与手持状态在 loadout)──
func cycle_index(dir: int) -> void:
	loadout.cycle_index(dir)


func request_net_cycle(dir: int) -> void:
	var next: int = loadout.peek_cycle(dir)
	if next < 0 or next == loadout.current_index():
		return
	push_switch_inst(loadout.inst_at_index(next))
	loadout.equip_index(next)


func push_switch_inst(inst: int) -> void:
	_switch_inst = inst


func consume_switch_inst() -> int:
	var v := _switch_inst
	_switch_inst = 0
	return v


func take_uplink_switch(key_index: int) -> int:
	var wheel_inst := consume_switch_inst()
	if key_index > 0:
		var inst: int = loadout.inst_at_index(key_index - 1)
		if inst > 0:
			return inst
	return wheel_inst


# 滚轮切枪(仅本地输入):设置开关、倒地闸门、PvP 的"本地即时切 + 上行 inst"都在这里,根不再复制一份按键表。
# 返回 true = 事件已被消费。
func try_wheel_switch(event: InputEvent) -> bool:
	if not Settings.wheel_switch or body == null or body.is_downed():
		return false
	if not (event is InputEventMouseButton) or not event.pressed:
		return false
	var dir := 0
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		dir = -1
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		dir = 1
	if dir == 0:
		return false
	if Level0.pvp_mode:
		request_net_cycle(dir)
	else:
		cycle_index(dir)
	return true


# ── 手持 / 背包(转发)──
func equip_type(type_id: int) -> void:
	loadout.equip_type(type_id)


func equip_inst(inst: int) -> void:
	loadout.equip_inst(inst)


func equip_index(i: int) -> void:
	loadout.equip_index(i)


func equip_index_authoritative(index: int) -> void:
	loadout.equip_index_authoritative(index)


func instance_matched() -> bool:
	return loadout.instance_matched()


func current_weapon() -> WeaponBase:
	return loadout.current_weapon()


func current_type_id() -> int:
	return loadout.current_type_id()


func current_inst() -> int:
	return loadout.current_inst()


func current_index() -> int:
	return loadout.current_index()


func snapshot_inventory() -> Array:
	return loadout.snapshot_inventory()


func restore_inventory(entries: Array, want_inst: int = 0) -> bool:
	return loadout.restore_inventory(entries, want_inst)


func reset_mag_state() -> void:
	loadout.reset_mag_state()


func pick_up(type_id: int, mag: int) -> int:
	return loadout.pick_up(type_id, mag)


func drop_current() -> Dictionary:
	return loadout.drop_current()


func take_last_dropped() -> Dictionary:
	return loadout.take_last_dropped()


func random_keep_one() -> Array[Dictionary]:
	return loadout.random_keep_one()


# ── 帧胶水:当前武器只由 loadout 知道,壳只转发 ──
func movement_multiplier() -> Vector2:
	return loadout.movement_multiplier()


func tick(delta: float) -> void:
	loadout.tick(delta)


func apply_recoil(push: float, is_squat: bool, is_latched: bool) -> void:
	loadout.apply_recoil(push, is_squat, is_latched)


func cancel_aim() -> void:
	loadout.cancel_aim()


# 弹量唯一写入口(保留静态 API:回溯路径与探针直接调它)。
static func apply_mag(w: WeaponBase, mag: int) -> void:
	if w == null or not is_instance_valid(w):
		return
	w.set_mag(mag)


# ── 整态武器段:实现在 WeaponState(纯静态,协议面);键名 = C2_SCHEMA + WEAPON_SCHEMA ──
func capture_state() -> Dictionary:
	return WeaponState.capture(self)


func restore_state(st: Dictionary) -> void:
	WeaponState.restore(self, st)


func sync_soft(st: Dictionary) -> void:
	WeaponState.sync_soft(self, st)


func inv_structure_equal(want: Array) -> bool:
	return WeaponState.inv_structure_equal(self, want)


func apply_state(st: Dictionary) -> void:
	WeaponState.apply(self, st)
