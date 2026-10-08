class_name WeaponComponent
extends Node

# 武器子系统：管理武器配置、背包库存、武器切换、移动惩罚与后坐力。
# 武器实例挂载于角色的 weapon_slot 节点下，由 Player 根节点在物理帧循环中驱动。
#
# 背包机制：
# - 玩家拥有 8 格容量预算（轻型 2 格 / 中型 3 格 / 重型 4 格）与最多持有 4 把武器的上限限制。
# - _current_type 记录当前手持武器的类型 ID（0 为空手），用于网络同步与远端副本呈现。
# - 背包位置索引仅用于本地切枪与背包界面高亮。
# - 武器属性统一由 core/sim/weapon_registry.gd（WeaponRegistry）从 data/weapons.json 中读取。

signal weapon_changed(type_id: int)    # 装备武器变更信号（0 为空手）
signal inventory_changed()          # 背包内容变更信号，供 UI 刷新

# 当前手持武器类型 ID（0 为空手）
var _current_type: int = 0
var _current_index: int = -1        # 当前手持武器在背包中的索引（-1 为空手）
var _weapon: WeaponBase = null
var inventory: WeaponInventory
var body: CharacterBody2D

# 启用的武器类型 ID 列表。默认启用全部武器，在 _init 中初始化。
# 单人模式由关卡根据运行参数配置，多人模式由客户端根据房间配置同步。
# 切换武器时会自动跳过未启用的武器类型。
var enabled_types: Array = []


func _init() -> void:
	# 在 _init 中构建背包对象，确保无场景树上下文时也能正常实例化与调用
	inventory = WeaponInventory.new(WeaponRegistry.tiers_map())
	# 默认启用注册表中的所有武器类型
	enabled_types = WeaponRegistry.all_ids()


func _ready() -> void:
	body = get_parent() as CharacterBody2D


func set_enabled_types(disabled: Array[int]) -> void:
	enabled_types = WeaponRegistry.all_ids().filter(func(t: int) -> bool: return not disabled.has(t))
	if enabled_types.is_empty():
		# 保证至少启用一把武器（默认启用注册表首个武器）
		var ids := WeaponRegistry.all_ids()
		enabled_types = [ids[0]] if not ids.is_empty() else []
	# 若当前手持武器被禁用，切换至背包中第一把可用武器；若无可用武器则清空手持
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


# 获取默认初始武器类型 ID（用于角色出生或复活时的默认装配）
func default_type() -> String:
	return str(enabled_types[0]) if enabled_types.size() > 0 else "1"


# ── 初始背包 ──
# 初始化背包武器列表（单人模式开局为空，多人模式通常包含初始武器）
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


# ── 切枪 ──
# 按背包槽位顺序循环切换武器
func cycle_index(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		# 无可切换武器或目标即当前武器时直接返回
		return
	_equip_index(next)


# 计算滚轮循环切换时的目标槽位索引
func _peek_cycle(dir: int) -> int:
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


# ── 网络切枪 ──
# 本地立即切换以保证即时操作手感，同时将目标武器的实例 ID（inst）打包进输入包由服务端同步。
# 采用唯一实例 ID 而非槽位下标进行通信，可避免客户端与服务端在拾取/丢弃期间因槽位顺序不一致导致的切枪错误。
var _switch_inst := 0   # 待发送切枪请求的目标武器实例 ID（>0 表示待发送，打包后清零）

func request_net_cycle(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		return
	push_switch_inst(inst_at_index(next))
	_equip_index(next)


# 记录待发送切枪请求的目标武器实例 ID
func push_switch_inst(inst: int) -> void:
	_switch_inst = inst


func consume_switch_inst() -> int:
	var v := _switch_inst
	_switch_inst = 0
	return v


# 解析切枪输入并提取待上行的武器实例 ID：
# - 数字键输入按槽位查出对应武器实例 ID
# - 滚轮切换已由 request_net_cycle 预存实例 ID
# 优先处理数字键输入，读取后清空滚轮切枪缓存；返回 0 表示当前帧无切枪请求。
func take_uplink_switch(key_index: int) -> int:
	var wheel_inst := consume_switch_inst()
	if key_index > 0:
		var inst := inst_at_index(key_index - 1)
		if inst > 0:
			return inst
	return wheel_inst


# 获取指定槽位索引的武器实例 ID；越界返回 0
func inst_at_index(index: int) -> int:
	if index < 0 or index >= inventory.held.size():
		return 0
	return int(inventory.held[index]["inst"])


# 按武器类型 ID 切换装备（用于预测回滚与服务端状态校正）。
# 若背包中不存在该类型武器，记录错误并不执行装配。
func equip_type(type_id: int) -> void:
	if not is_type_enabled(type_id):
		Sfx.play("deny")
		return
	var idx := inventory.first_index_of_type(type_id)
	if idx < 0:
		push_error("equip_type: 背包里没有类型 %d —— 不再凭空加入" % type_id)
		return
	_equip_index(idx)


# 按武器实例 ID 切换装备（用于处理网络输入与服务端同步）。
# 若指定实例不存在（已被丢弃或替换），则保持当前状态不变。
func equip_inst(inst: int) -> void:
	if inst <= 0:
		return
	var idx := inventory.index_of_inst(inst)
	if idx < 0:
		return
	_equip_index(idx)


# 按背包槽位索引切换装备
func equip_index(i: int) -> void:
	_equip_index(i)


func _equip_index(index: int) -> void:
	if index < 0 or index >= inventory.held.size():
		return
	# 切枪时继承旧武器的剩余冷却时间，防止通过快速切枪跳过后摇
	var inherit_cd := 0.0
	if _weapon != null and is_instance_valid(_weapon):
		inherit_cd = _weapon.fire_cd_timer
		# 仅当旧武器已处于场景树中时才将弹药写回背包数据条目；
		# 避免同帧多次切枪时尚未运行 _ready 的临时实例将弹药覆盖为 0
		if _weapon.is_inside_tree() and _current_index >= 0 and _current_index < inventory.held.size():
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
	_weapon = scene.instantiate() as WeaponBase
	# 必须在 add_child 之前设置 pending_mag，确保新武器 _ready 时能正确读取待恢复弹药
	if int(inventory.held[index]["mag"]) != WeaponInventory.MAG_FULL:
		_weapon.pending_mag = clampi(int(inventory.held[index]["mag"]), 0, _weapon.mag_size)
	body.weapon_slot.call_deferred("add_child", _weapon)
	_weapon.equip(body, inherit_cd)
	Sfx.play("switch")
	weapon_changed.emit(type_id)
	inventory_changed.emit()


# 清空手持武器状态（背包为空或当前武器被禁用且无替代时调用）
func _unequip() -> void:
	if _weapon != null and is_instance_valid(_weapon):
		if _weapon.is_inside_tree() and _current_index >= 0 and _current_index < inventory.held.size():
			inventory.held[_current_index]["mag"] = _weapon.mag_ammo
		_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_type = 0
	weapon_changed.emit(0)
	inventory_changed.emit()


# 同步写入武器弹药量：
# - 若武器已在场景树中，直接写入 mag_ammo；
# - 若武器尚未加入场景树，写入 pending_mag 等待 _ready 阶段应用。
static func apply_mag(w: WeaponBase, mag: int) -> void:
	if w == null or not is_instance_valid(w):
		return
	if w.is_inside_tree():
		w.mag_ammo = clampi(mag, 0, w.mag_size)
	else:
		w.pending_mag = clampi(mag, 0, w.mag_size)


# ── 拾取 / 丢弃 ──

# 记录最近一次被替换掉落的武器信息 {type, mag}
var _last_dropped: Dictionary = {}

const PICKUP_DENIED := -1

# 拾取一把指定类型与弹药量的武器：
# 返回值：>0 为被替换掉的武器类型 ID；0 为正常拾取未发生替换；PICKUP_DENIED (-1) 为背包已满无法拾取
func pick_up(type_id: int, mag: int) -> int:
	if not is_type_enabled(type_id):
		Sfx.play("deny")
		return PICKUP_DENIED
	if inventory.can_hold(type_id):
		inventory.add(type_id, mag)
		inventory_changed.emit()
		_equip_index(inventory.held.size() - 1)
		return 0
	# 容量不足或数量达到上限时，与当前手持武器进行替换
	if _current_index < 0:
		Sfx.play("deny")
		return PICKUP_DENIED
	var entry: Dictionary = inventory.held[_current_index]
	var dropped := int(entry["type"])
	var dropped_mag := int(entry["mag"])
	if _weapon != null and is_instance_valid(_weapon) and _weapon.is_inside_tree():
		dropped_mag = _weapon.mag_ammo
	# 原位替换武器类型并保留实例 ID
	inventory.held[_current_index] = {"type": type_id, "inst": int(entry["inst"]), "mag": mag}
	_equip_index(_current_index)
	_last_dropped = {"type": dropped, "mag": dropped_mag}
	return dropped


func take_last_dropped() -> Dictionary:
	var d := _last_dropped
	_last_dropped = {}
	return d


# 丢弃当前手持武器。返回丢弃武器的信息 {type, mag}；若空手则返回空字典
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
	inventory_changed.emit()
	# 丢弃后自动切换至背包中第一把可用武器；若背包为空则保持空手
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)
	else:
		weapon_changed.emit(0)
	return out


# 角色复活处理：从背包中随机保留一把武器，返回其余武器信息用于在死亡点生成掉落物
func random_keep_one() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if inventory.held.is_empty():
		return out
	var keep := randi() % inventory.held.size()
	var keep_entry: Dictionary = inventory.held[keep]
	for i in range(0, inventory.held.size()):
		if i != keep:
			out.append(inventory.held[i].duplicate())
	var kept: Array[Dictionary] = [keep_entry]
	inventory.held = kept
	_equip_index(0)
	return out


# ── 快照 / 恢复（预测回滚使用）──

# 将当前武器弹药同步至背包条目，并生成完整的背包状态快照
func snapshot_inventory() -> Array:
	_flush_current_mag()
	return inventory.snapshot()


# 根据服务端权威状态恢复背包。
# 返回值：是否成功按 want_inst 匹配到手持武器
func restore_inventory(entries: Array, want_inst: int = 0) -> bool:
	var keep_type := _current_type
	inventory.restore(entries)
	# 优先按武器实例 ID 查找对应槽位；若未指定或未找到则按武器类型查找
	var idx := inventory.index_of_inst(want_inst) if want_inst > 0 else -1
	var by_inst := idx >= 0
	if not by_inst:
		idx = inventory.first_index_of_type(keep_type) if keep_type > 0 else -1
	if idx >= 0:
		_current_index = idx
		# 保持当前手持类型记录，供外部逻辑比对是否需要重新实例化武器
		_current_type = keep_type
		inventory_changed.emit()
		return by_inst
	# 若权威状态表明手持武器已被移除，则清理手持武器实例
	if _weapon != null and is_instance_valid(_weapon):
		_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_type = 0
	inventory_changed.emit()
	return false


func _flush_current_mag() -> void:
	if _weapon == null or not is_instance_valid(_weapon) or not _weapon.is_inside_tree():
		return
	if _current_index >= 0 and _current_index < inventory.held.size():
		inventory.held[_current_index]["mag"] = _weapon.mag_ammo


# ── 辅助方法 ──

# 将当前武器弹药同步至背包数据条目
func reset_mag_state() -> void:
	_flush_current_mag()


func current_weapon() -> WeaponBase:
	return _weapon


func current_type_id() -> int:
	return _current_type


# 获取当前手持武器的唯一实例 ID；空手或越界返回 0
func current_inst() -> int:
	return inst_at_index(_current_index)


func movement_multiplier() -> Vector2:
	if _weapon == null:
		return Vector2.ONE
	return _weapon.get_movement_multiplier()


# 武器物理逻辑（冷却、预瞄、后坐力）每物理帧由 Player 显式驱动，确保回滚模拟确定性
func tick(delta: float) -> void:
	if _weapon != null:
		_weapon.tick(delta)


func apply_recoil(push: float, is_squat: bool, is_latched: bool) -> void:
	if is_squat:
		return
	if is_latched:
		push *= 0.1  # 攀爬状态下后坐力衰减为 10%
	body.velocity.x -= body.facing_direction * push


func cancel_aim() -> void:
	if _weapon != null:
		_weapon.cancel_aim()
