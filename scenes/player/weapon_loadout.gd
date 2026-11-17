class_name WeaponLoadout
extends RefCounted

# 背包 + 手持实例:**唯一**变更点(装备 / 切枪 / 拾取丢弃 / 弹量写回)。
# 不是 Node:没有 _ready/_process,顺序由 WeaponComponent 的调用点决定(与 PlayerMotor 同一条纪律)。


# ★ 场景路径 / 显示名 / 重量档三张常量表已整体删除:唯一来源是 data/weapons.json,由 core/sim/weapon_registry.gd(WeaponRegistry)读;这里不留任何副本,留一张就会与 json 分家。

signal weapon_changed(type_id: int)
signal inventory_changed()

var _current_type: int = 0
var _current_index: int = -1
var _weapon: WeaponBase = null
var inventory: WeaponInventory
var body: CharacterBody2D

var enabled_types: Array = []



func _init() -> void:
	inventory = WeaponInventory.new(WeaponRegistry.tiers_map())
	enabled_types = WeaponRegistry.all_ids()


func setup(b: CharacterBody2D) -> void:
	body = b


func set_enabled_types(disabled: Array[int]) -> void:
	enabled_types = WeaponRegistry.all_ids().filter(func(t: int) -> bool: return not disabled.has(t))
	if enabled_types.is_empty():
		# 不允许全禁:至少留注册表里的第一把(今天 = 1 号手枪)。★ 这里从前写死 [1];注册表化之后「手枪」这个概念只活在 json 的顺序里,写死一个 id 会在将来重排 json / 删号时静默指到别的枪。
		var ids := WeaponRegistry.all_ids()
		enabled_types = [ids[0]] if not ids.is_empty() else []
	if _current_type > 0 and not is_type_enabled(_current_type):
		var fallback := _first_enabled_index()
		if fallback >= 0:
			_equip_index(fallback)
		else:
			_unequip()


func is_type_enabled(type_id: int) -> bool:
	return enabled_types.has(type_id)


func _first_enabled_index() -> int:
	for i in inventory.held.size():
		if is_type_enabled(int(inventory.held[i]["type"])):
			return i
	return -1


func default_type() -> String:
	return str(enabled_types[0]) if enabled_types.size() > 0 else "1"


func set_initial_inventory(types: Array) -> void:
	inventory.clear()
	_unequip()
	for t in types:
		if is_type_enabled(int(t)):
			inventory.add(int(t), WeaponInventory.MAG_FULL)
	inventory_changed.emit()
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)


func cycle_index(dir: int) -> void:
	var next := peek_cycle(dir)
	if next < 0 or next == _current_index:
		return
	_equip_index(next)


func peek_cycle(dir: int) -> int:
	var n := inventory.held.size()
	if n == 0:
		return -1
	var order: Array[int] = []
	for i in n:
		if is_type_enabled(int(inventory.held[i]["type"])):
			order.append(i)
	if order.is_empty():
		return -1
	var idx := order.find(_current_index)
	if idx < 0:
		idx = 0
	return order[(idx + dir + order.size() * 2) % order.size()]


var _equipped_inst := 0









func inst_at_index(index: int) -> int:
	if index < 0 or index >= inventory.held.size():
		return 0
	return int(inventory.held[index]["inst"])


# 按类型 id 切枪(rollback / 权威兜底走这条)。
# ★ 背包里没有这个类型 = 异常,不再顺手造一把:旧实现有一条「没有就加」的兜底,而它会静默改变背包长度 —— 那正是两端 held 不同序的另一条产生源;单机不受影响(pick_up 走 WeaponInventory.add)。
func equip_type(type_id: int) -> void:
	if not is_type_enabled(type_id):
		Sfx.play("deny")
		return
	var idx := inventory.first_index_of_type(type_id)
	if idx < 0:
		push_error("equip_type: 背包里没有类型 %d —— 不再凭空加入(§4.5;见本函数注释)" % type_id)
		return
	_equip_index(idx)


# 按 inst 切枪(网络上行 / 权威落点走这条)。★ 找不到那把时静默不动:inst 逐把唯一,服务器手里没有它只可能是那一把已经不在了(被丢/被换),此时切到别的枪是错的。
func equip_inst(inst: int) -> void:
	if inst <= 0:
		return
	var idx := inventory.index_of_inst(inst)
	if idx < 0:
		return
	_equip_index(idx)


func equip_index(i: int) -> void:
	_equip_index(i)


func _equip_index(index: int, flush_current: bool = true) -> void:
	if index < 0 or index >= inventory.held.size():
		return
	var inherit_cd := 0.0
	if _weapon != null and is_instance_valid(_weapon):
		inherit_cd = _weapon.fire_cd_timer
		# 残弹写回条目只认已入树的枪:同帧第二次切枪时上一把还是 call_deferred 未入树(其 _ready 未跑 ⇒ mag_ammo 仍是 0),照记会把残弹永久抹成 0;真机可达(滚轮走 _unhandled_input,一帧内缓冲的 OS 事件会一次性泵完)。
		if flush_current and _weapon.is_inside_tree() and _current_index >= 0 and _current_index < inventory.held.size():
			inventory.held[_current_index]["mag"] = _weapon.mag_ammo
		_weapon.queue_free()
		_weapon = null
	var type_id := int(inventory.held[index]["type"])
	var scene_path := WeaponRegistry.scene_of(type_id)
	var scene: PackedScene = load(scene_path) if not scene_path.is_empty() else null
	if scene == null:
		push_error("weapon scene not found: id=%d(%s)" % [type_id, scene_path])
		return
	if body == null or body.weapon_slot == null:
		push_error("weapon_slot not assigned")
		return
	_current_index = index
	_current_type = type_id
	_equipped_inst = int(inventory.held[index]["inst"])
	_weapon = scene.instantiate() as WeaponBase
	if int(inventory.held[index]["mag"]) != WeaponInventory.MAG_FULL:
		_weapon.pending_mag = clampi(int(inventory.held[index]["mag"]), 0, _weapon.mag_size)
	body.weapon_slot.add_child.call_deferred(_weapon)
	_weapon.equip(body, inherit_cd)
	Sfx.play("switch")
	weapon_changed.emit(type_id)
	inventory_changed.emit()


func _unequip() -> void:
	if _weapon != null and is_instance_valid(_weapon):
		if _weapon.is_inside_tree() and _current_index >= 0 and _current_index < inventory.held.size():
			inventory.held[_current_index]["mag"] = _weapon.mag_ammo
		_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_type = 0
	_equipped_inst = 0
	weapon_changed.emit(0)
	inventory_changed.emit()





var _last_dropped: Dictionary = {}


# 拾取一把类型为 type_id、残弹为 mag 的枪。返回值:被替换掉的类型 id(>0 = 有替换);0 = 捡成功且没有替换;-1 = 被拒绝、没捡成。
# ★ -1 必须与 0 分开:调用方(Level0.try_pickup_for)在捡成功后会把地面那件删掉,若被闸门拒绝也返回 0,地面那把会被直接抹掉而玩家什么都没拿到(静默丢枪);替换规则 = 放不下时替换手上当前那把,被换下的 {type, mag} 经 take_last_dropped() 取走。
const PICKUP_DENIED := -1

func pick_up(type_id: int, mag: int) -> int:
	if not is_type_enabled(type_id):
		Sfx.play("deny")
		return PICKUP_DENIED
	if inventory.can_hold(type_id):
		inventory.add(type_id, mag)
		inventory_changed.emit()
		_equip_index(inventory.held.size() - 1)
		return 0
	if _current_index < 0:
		Sfx.play("deny")
		return PICKUP_DENIED
	var entry: Dictionary = inventory.held[_current_index]
	var dropped := int(entry["type"])
	var dropped_mag := int(entry["mag"])
	if _weapon != null and is_instance_valid(_weapon) and _weapon.is_inside_tree():
		dropped_mag = _weapon.mag_ammo
	inventory.held[_current_index] = {"type": type_id, "inst": int(entry["inst"]), "mag": mag}
	_equip_index(_current_index, false)
	_last_dropped = {"type": dropped, "mag": dropped_mag}
	return dropped


func take_last_dropped() -> Dictionary:
	var d := _last_dropped
	_last_dropped = {}
	return d


func drop_current() -> Dictionary:
	if _current_index < 0:
		return {}
	var e: Dictionary = inventory.held[_current_index]
	var mag := int(e["mag"])
	if _weapon != null and is_instance_valid(_weapon) and _weapon.is_inside_tree():
		mag = _weapon.mag_ammo
	var out := {"type": int(e["type"]), "mag": mag}
	inventory.remove_at(_current_index)
	_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_type = 0
	_equipped_inst = 0
	inventory_changed.emit()
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)
	else:
		weapon_changed.emit(0)
	return out


func random_keep_one() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if inventory.held.is_empty():
		return out
	_flush_current_mag()
	var keep := randi() % inventory.held.size()
	var keep_entry: Dictionary = inventory.held[keep]
	for i in range(0, inventory.held.size()):
		if i != keep:
			out.append(inventory.held[i].duplicate())
	var kept: Array[Dictionary] = [keep_entry]
	inventory.held = kept
	_equip_index(0, false)
	return out



func snapshot_inventory() -> Array:
	_flush_current_mag()
	return inventory.snapshot()


# 用权威整态重建背包。★ 必须先于 equip_type(wslot):否则重放时可能切到客户端背包里没有的类型,而 equip_type 只 push_error、不加入。
# 返回值 = 是否按 want_inst 解析成功(手持下标来自权威的 winst);调用方靠它决定重建实例时走下标还是走类型 —— 返回 false 表示走的是按类型兜底(老载荷无 winst、或权威那把不在表里),此时下标只代表旧类型那把,拿它去重建会把权威的 wslot 顶掉。
func restore_inventory(entries: Array, want_inst: int = 0) -> bool:
	var keep_type := _current_type
	inventory.restore(entries)
	var idx := inventory.index_of_inst(want_inst) if want_inst > 0 else -1
	var by_inst := idx >= 0
	if not by_inst:
		idx = inventory.first_index_of_type(keep_type) if keep_type > 0 else -1
	if idx >= 0:
		_current_index = idx
		# ★★ _current_type 保持 keep_type(旧类型),不要改成表里那一条的类型:调用方 WeaponState.apply 靠 wslot != _current_type 决定要不要 equip_type(),而 equip_type() 顺带重建武器实例。
		# 改成表里那条的类型后,同类型时那个判据恒假 ⇒ 实例永不重建 ⇒ 被清空过背包的一方恢复后手上没枪,武器不再写 set_facing、与权威在 facing 上发散(pvp_twin_smoke 实测红);真正的类型不一致那一档仍由调用方的 equip_type(wslot) 收尾。
		_current_type = keep_type
		inventory_changed.emit()
		return by_inst
	if _weapon != null and is_instance_valid(_weapon):
		_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_type = 0
	inventory_changed.emit()
	return false


func instance_matched() -> bool:
	return _weapon != null and is_instance_valid(_weapon) and _equipped_inst == inst_at_index(_current_index) \
			and _equipped_inst > 0


# 权威同步专用:按当前下标重建手持实例,不把旧实例残弹写回条目 —— 条目刚被权威整表覆盖过,
# 写回就是"把上一把枪的残弹盖到这一把上"(用户实测:两把狙击枪切枪后弹数/开火异常)。
func equip_index_authoritative(index: int) -> void:
	_equip_index(index, false)


func _flush_current_mag() -> void:
	if _weapon == null or not is_instance_valid(_weapon) or not _weapon.is_inside_tree():
		return
	if _current_index >= 0 and _current_index < inventory.held.size():
		inventory.held[_current_index]["mag"] = _weapon.mag_ammo



func reset_mag_state() -> void:
	_flush_current_mag()


# ★ 原 refill_current_weapon() / _refill_mag() 已删除:唯一理由是 _refill_mag 必须 deferred 并排在 _restore_mag 之后,而那条帧末写回已随 pending_mag 一起删掉;全仓也没有生产调用点(复活满弹由 Level0.restart_single 统一重置背包)。
# ⚠ 删掉 _restore_mag 不等于弹数有了常规纠正路径:_close_enough 仍不比 mag,sync_soft_state 的指纹只比结构 ⇒ 非回滚来源的弹数分歧仍会静默保留(见 docs/systems/gameplay/weapons.md)。


func current_weapon() -> WeaponBase:
	return _weapon


func current_type_id() -> int:
	return _current_type


func current_inst() -> int:
	return inst_at_index(_current_index)


# 手持下标(背包位置):整态回灌判"实例与下标分家"、HUD/探针读口。
func current_index() -> int:
	return _current_index


func movement_multiplier() -> Vector2:
	if _weapon == null:
		return Vector2.ONE
	return _weapon.get_movement_multiplier()


# 武器帧逻辑(冷却/缓冲开火/预瞄/后坐)由根每物理帧显式驱动,保证与 body 跑在同一个固定 tick 上(rollback 重放需要确定性),不依赖 idle _process。
func tick(delta: float) -> void:
	if _weapon != null:
		_weapon.tick(delta)


func apply_recoil(push: float, is_squat: bool, is_latched: bool) -> void:
	if is_squat:
		return
	if is_latched:
		push *= 0.1
	body.velocity.x -= body.facing_direction * push


func cancel_aim() -> void:
	if _weapon != null:
		_weapon.cancel_aim()


# 滚轮切枪(仅本地输入):设置开关、倒地闸门、PvP 的"本地即时切 + 上行 inst"都在这里,根不再复制一份按键表。
# 返回 true = 事件已被消费。


# ── 整态(回滚/权威同步)的武器段 ──
# 实现搬进 scenes/player/weapon_state.gd(WeaponState):协议键与"背包/手持怎么变"是两种变更理由。
# 键名 = 线上 C2_SCHEMA + WEAPON_SCHEMA(唯一 schema 见 core/net/net_codec.gd);本文件不另立键清单。








