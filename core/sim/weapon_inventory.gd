class_name WeaponInventory
extends RefCounted

const TIER_LIGHT := 0
const CELL_COST := [2, 3, 4]
const DEFAULT_CARRIED := -1

# 每把武器在背包里有自己的实例和弹药数量。手持武器使用同一条记录，快照按顺序传递所有记录。
enum { TYPE, INST, CARRIED, STRIDE }

const CAPACITY := 8
const MAX_WEAPONS := 4
var enabled_types: Array = WeaponRegistry.enabled_ids()
var equipped: GunBody
var _slots: Array[PackedInt32Array] = []
var _next_inst := 1

func is_type_enabled(type_id: int) -> bool:
	return type_id in enabled_types

func current_inst() -> int:
	return equipped.item[INST] if equipped != null else 0

func inst_at_index(index: int) -> int:
	return _slots[index][INST] if index >= 0 and index < _slots.size() else 0

func _find(inst: int) -> PackedInt32Array:
	for item in _slots:
		if item[INST] == inst:
			return item
	return []

func cycle_instance(dir: int) -> int:
	var items := _slots.filter(func(item: PackedInt32Array) -> bool: return is_type_enabled(item[TYPE]))
	if items.is_empty():
		return 0
	var current := items.find(equipped.item) if equipped != null else -1
	var next := posmod(maxi(current, 0) + dir, items.size())
	return items[next][INST] if next != current else 0

func equip_inst(inst: int) -> bool:
	if inst == current_inst(): return inst > 0
	var item := _find(inst)
	if item.is_empty(): return false
	_equip(item)
	return true

func _equip(item: PackedInt32Array) -> void:
	var cooldown := equipped.fire_cd_timer if equipped != null else 0.0
	equipped = GunBody.new(item)
	equipped.fire_cd_timer = cooldown

func _equip_first() -> void:
	equipped = null
	for item in _slots:
		if is_type_enabled(item[TYPE]):
			_equip(item)
			return

func set_initial_inventory(types: Array) -> void:
	_slots.clear()
	equipped = null
	for type_id in types:
		_add(int(type_id), DEFAULT_CARRIED)
	_equip_first()

static func _cost(type_id: int) -> int:
	return CELL_COST[WeaponRegistry.definition(type_id)["tier"]]

func _add(type_id: int, carried: int) -> PackedInt32Array:
	if not is_type_enabled(type_id):
		return []
	var used := _cost(type_id)
	for item in _slots:
		used += _cost(item[TYPE])
	var item := PackedInt32Array([type_id, _next_inst, carried])
	if _slots.size() < MAX_WEAPONS and used <= CAPACITY:
		_slots.append(item)
	elif equipped != null and used - _cost(equipped.type_id) <= CAPACITY:
		_slots[_slots.find(equipped.item)] = item
	else:
		return []
	_next_inst += 1
	return item

static func _drop_data(item: PackedInt32Array) -> Dictionary:
	return {"type": item[TYPE], "carried": item[CARRIED]}

func pick_up(type_id: int, carried: int) -> Dictionary:
	var count := _slots.size()
	var item := _add(type_id, carried)
	if item.is_empty():
		return {"ok": false}
	var dropped := _drop_data(equipped.item) if count == _slots.size() else {}
	_equip(item)
	return {"ok": true, "dropped": dropped}

func drop_current() -> Dictionary:
	if equipped == null:
		return {}
	var item := equipped.item
	_slots.erase(item)
	_equip_first()
	return _drop_data(item)

func random_keep_one(rng: RandomNumberGenerator) -> Array[Dictionary]:
	var dropped: Array[Dictionary] = []
	if not _slots.is_empty():
		var keep := _slots[rng.randi_range(0, _slots.size() - 1)]
		for item in _slots:
			if item != keep:
				dropped.append(_drop_data(item))
		_slots.assign([keep])
		_equip(keep)
	return dropped

# 给 HUD 的数组先记录手持武器在背包中的索引，再记录背包容量。没有手持武器时索引是 -1。
# 后面每两项描述一把武器，依次为武器类型和占用的格数。
static func layout(entries: PackedInt32Array, inst: int) -> PackedInt32Array:
	var active := -1
	var layout := PackedInt32Array([active, CAPACITY])
	for at in range(0, entries.size(), STRIDE):
		if entries[at + INST] == inst:
			layout[0] = at / STRIDE
		layout.append(entries[at + TYPE])
		layout.append(_cost(entries[at + TYPE]))
	return layout

func snapshot() -> PackedInt32Array:
	var entries := PackedInt32Array()
	for item in _slots:
		entries.append_array(item)
	return entries

func capture_into(values: Array) -> void:
	values[PlayerStateSchema.WEAPON_NEXT] = _next_inst
	values[PlayerStateSchema.WEAPON_INST] = current_inst()
	values[PlayerStateSchema.INVENTORY] = snapshot()
	values[PlayerStateSchema.EQUIPMENT] = equipped.state_values() if equipped != null else []

func restore(state: Array, rewind: bool) -> void:
	var inst: int = state[PlayerStateSchema.WEAPON_INST]
	var entries: PackedInt32Array = state[PlayerStateSchema.INVENTORY]
	if rewind:
		# 按实例 ID 将历史弹药量恢复到当前仍持有的武器。
		for at in range(0, entries.size(), STRIDE):
			var owned := _find(entries[at + INST])
			if not owned.is_empty():
				owned[CARRIED] = entries[at + CARRIED]
	else:
		_next_inst = state[PlayerStateSchema.WEAPON_NEXT]
		_slots.clear()
		for at in range(0, entries.size(), STRIDE):
			_slots.append(entries.slice(at, at + STRIDE))
	var selected := _find(inst) if inst > 0 else PackedInt32Array()
	if not selected.is_empty():
		if inst == current_inst() and equipped.type_id == selected[TYPE]:
			equipped.item = selected
		else:
			equipped = GunBody.new(selected)
		equipped.restore_state_values(state[PlayerStateSchema.EQUIPMENT])
	elif not rewind:
		equipped = null
	if rewind and equipped != null:
		equipped.fill_default_magazine()
