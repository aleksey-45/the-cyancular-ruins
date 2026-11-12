class_name WeaponComponent
extends Node

# 管理背包与武器实例；数值来自 WeaponRegistry。

signal inventory_changed()          # 背包内容变更信号，供 UI 刷新
var _presented: Array = []

var _current_index: int:
	get: return body.equipped.slot if body.equipped != null else -1
var inventory := WeaponInventory.new()
var body: Player
var _view: WeaponBase
var enabled_types: Array = WeaponRegistry.all_ids()

func _ready() -> void:
	body = get_parent() as Player

func is_type_enabled(type_id: int) -> bool:
	return enabled_types.has(type_id)

func _first_enabled_index() -> int:
	for i in inventory.count():
		if is_type_enabled(inventory.type_at(i)):
			return i
	return -1


# 初始化背包武器列表（单人模式开局为空，多人模式通常包含初始武器）
func set_initial_inventory(types: Array) -> void:
	inventory.clear()
	body.equipped = null
	for t in types:
		if is_type_enabled(int(t)):
			inventory.try_add(int(t), WeaponInventory.DEFAULT_CARRIED)
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)


# 计算滚轮循环切换时的目标槽位索引
func _peek_cycle(dir: int) -> int:
	var n := inventory.count()
	if n == 0:
		return -1
	var order: Array[int] = []
	for i in n:
		if is_type_enabled(inventory.type_at(i)):
			order.append(i)
	if order.is_empty():
		return -1
	var idx := order.find(_current_index)
	if idx < 0:
		idx = 0
	return order[posmod(idx + dir, order.size())]


# 滚轮请求与数字键一样在共享角色步进中消费。
var _switch_inst := 0   # 待发送切枪请求的目标武器实例 ID（>0 表示待发送，打包后清零）

func request_cycle(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		return
	_switch_inst = inst_at_index(next)


# 解析切枪输入并提取待上行的武器实例 ID：
# - 数字键输入按槽位查出对应武器实例 ID
# - 滚轮切换已由 request_cycle 预存实例 ID
# 优先处理数字键输入，读取后清空滚轮切枪缓存；返回 0 表示当前帧无切枪请求。
func take_uplink_switch(key_index: int) -> int:
	var wheel_inst := _switch_inst
	_switch_inst = 0
	if key_index > 0:
		var inst := inst_at_index(key_index - 1)
		if inst > 0:
			return inst
	return wheel_inst


# 获取指定槽位索引的武器实例 ID；越界返回 0
func inst_at_index(index: int) -> int:
	if index < 0 or index >= inventory.count():
		return 0
	return inventory.inst_at(index)


# 按武器实例 ID 切换装备（用于处理网络输入与服务端同步）。
# 若指定实例不存在（已被丢弃或替换），则保持当前状态不变。
func equip_inst(inst: int) -> void:
	if inst <= 0 or inst == current_inst():
		return
	var idx := inventory.index_of_inst(inst)
	if idx < 0:
		return
	_equip_index(idx)


# 按背包槽位索引切换装备
func _equip_index(index: int, announce := true) -> void:
	var outgoing := body.equipped
	body.equipped = GunBody.new(inventory, index)
	if outgoing != null:
		body.equipped.fire_cd_timer = outgoing.fire_cd_timer
	if announce:
		_play_sfx("switch")

func pick_up(type_id: int, carried: int) -> Dictionary:
	var outgoing := body.equipped
	var previous := outgoing.carried if outgoing != null else WeaponInventory.DEFAULT_CARRIED
	var index := inventory.try_add(type_id, carried, _current_index) if is_type_enabled(type_id) else -1
	if index < 0:
		_play_sfx("deny")
		return {"ok": false}
	var dropped := {}
	if index == _current_index:
		dropped = {"type": outgoing.type_id, "carried": previous}
	_equip_index(index)
	return {"ok": true, "dropped": dropped}


# 丢弃当前手持武器。返回丢弃武器的信息 {type, carried}；若空手则返回空字典
func drop_current() -> Dictionary:
	if _current_index < 0:
		return {}
	var out := {"type": inventory.type_at(_current_index), "carried": body.equipped.carried}
	inventory.remove_at(_current_index)
	body.equipped = null
	# 丢弃后自动切换至背包中第一把可用武器；若背包为空则保持空手
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)
	return out


# 角色复活处理：从背包中随机保留一把武器，返回其余武器信息用于在死亡点生成掉落物
func random_keep_one() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := inventory.count()
	if n == 0:
		return out
	var keep := randi() % n
	for i in n:
		if i != keep:
			out.append({"type": inventory.type_at(i), "carried": inventory.carried_at(i)})
	inventory.keep_only(keep)
	_equip_index(0)
	return out



# 回溯恢复仍持有的装备，拾取和丢弃以当前归属为准。
func rewind_inventory(entries: PackedInt32Array, equipped_inst: int) -> bool:
	for start in range(0, entries.size(), WeaponInventory.STRIDE):
		var index := inventory.index_of_inst(entries[start + WeaponInventory.INST])
		if index >= 0:
			inventory.set_carried(index, entries[start + WeaponInventory.CARRIED])
	var index := inventory.index_of_inst(equipped_inst)
	if index >= 0 and index != _current_index:
		_equip_index(index, false)
	elif body.equipped != null:
		body.equipped.bind_slot(_current_index)
	return index >= 0

func restore_inventory(entries: PackedInt32Array, equipped_inst: int) -> void:
	var same_inst := current_inst() == equipped_inst
	inventory.restore(entries)
	var index := inventory.index_of_inst(equipped_inst) if equipped_inst > 0 else -1
	if same_inst and index >= 0:
		body.equipped.bind_slot(index)
	else:
		body.equipped = GunBody.new(inventory, index) if index >= 0 else null

func weapon_view() -> WeaponBase:
	var type_id := current_type_id()
	if _view != null and _view.type_id != type_id:
		_view.hide()
		_view.queue_free()
		_view = null
	if type_id != 0 and _view == null:
		_view = WeaponBase.new()
		_view.configure(type_id, body.animator)
		body.weapon_slot.add_child(_view)
	return _view

func present() -> void:
	var layout: Array = [current_inst(), inventory.capacity]
	for i in inventory.count():
		layout.append(Vector2i(inventory.inst_at(i), inventory.type_at(i)))
	if layout != _presented:
		_presented = layout
		inventory_changed.emit()

func current_type_id() -> int:
	return body.equipped.type_id if body.equipped != null else 0


# 获取当前手持武器的唯一实例 ID；空手或越界返回 0
func current_inst() -> int:
	return inst_at_index(_current_index)

func cancel_aim() -> void:
	if body.equipped != null:
		body.equipped.cancel_aim()

func _play_sfx(sound: String) -> void:
	body.step_actions.append({"kind": "sound", "sound": sound})
