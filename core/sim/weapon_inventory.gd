class_name WeaponInventory
extends RefCounted

signal feedback(kind: String)

const TIER_LIGHT := 0
const TIER_MEDIUM := 1
const TIER_HEAVY := 2
const CELL_COST := [2, 3, 4]
const DEFAULT_CARRIED := -1

# 每件装备独有一行，手持武器直接使用这一行。只有快照将各行打平。
enum { TYPE, INST, CARRIED, STRIDE }

var capacity := 8
var max_weapons := 4
var enabled_types: Array = WeaponRegistry.all_ids()
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

func equip_inst(inst: int) -> void:
	if inst <= 0 or inst == current_inst():
		return
	var item := _find(inst)
	if not item.is_empty():
		_equip(item)

func _equip(item: PackedInt32Array) -> void:
	var cooldown := equipped.fire_cd_timer if equipped != null else 0.0
	equipped = GunBody.new(item)
	equipped.fire_cd_timer = cooldown
	feedback.emit("equipped")

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
	if _slots.size() < max_weapons and used <= capacity:
		_slots.append(item)
	elif equipped != null and _slots.size() <= max_weapons and used - _cost(equipped.type_id) <= capacity:
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
		feedback.emit("pickup_denied")
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

func random_keep_one() -> Array[Dictionary]:
	var dropped: Array[Dictionary] = []
	if not _slots.is_empty():
		var keep := _slots[randi() % _slots.size()]
		for item in _slots:
			if item != keep:
				dropped.append(_drop_data(item))
		_slots.assign([keep])
		_equip(keep)
	return dropped

# [当前槽, 总格数, 类型, 占格数, ...]，装备按获得顺序排列。
func cell_layout() -> PackedInt32Array:
	var active := _slots.find(equipped.item) if equipped != null else -1
	var layout := PackedInt32Array([active, capacity])
	for item in _slots:
		layout.append(item[TYPE])
		layout.append(_cost(item[TYPE]))
	return layout

func snapshot() -> PackedInt32Array:
	var entries := PackedInt32Array()
	for item in _slots:
		entries.append_array(item)
	return entries

func restore(inst: int, entries: PackedInt32Array, values: Array, rewind: bool) -> void:
	if rewind:
		# 主动回溯只退回仍持有的实例的弹药。
		for at in range(0, entries.size(), STRIDE):
			var owned := _find(entries[at + INST])
			if not owned.is_empty():
				owned[CARRIED] = entries[at + CARRIED]
	else:
		_slots.clear()
		for at in range(0, entries.size(), STRIDE):
			_slots.append(entries.slice(at, at + STRIDE))
			_next_inst = maxi(_next_inst, entries[at + INST] + 1)
	var selected := _find(inst) if inst > 0 else PackedInt32Array()
	if not selected.is_empty():
		if inst == current_inst():
			equipped.item = selected
		else:
			equipped = GunBody.new(selected)
		equipped.restore_state_values(values)
	elif not rewind:
		equipped = null
	if equipped != null:
		equipped.fill_default_magazine()
