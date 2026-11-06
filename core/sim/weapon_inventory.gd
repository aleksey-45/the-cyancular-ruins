class_name WeaponInventory
extends RefCounted


const TIER_LIGHT := 0
const TIER_MEDIUM := 1
const TIER_HEAVY := 2
const CELL_COST: Dictionary = {TIER_LIGHT: 2, TIER_MEDIUM: 3, TIER_HEAVY: 4}

# 两条闸门的默认值。★ 名字带 DEFAULT_ 是刻意的:只在构造时用一次 —— 别再让调用方读它们当"容量"(那是静默的错值)。
const DEFAULT_MAX_WEAPONS := 4
const DEFAULT_CAPACITY := 8

var max_weapons: int = DEFAULT_MAX_WEAPONS
var capacity: int = DEFAULT_CAPACITY

const MAG_FULL := -1

# 背包条目,按获得顺序:{"type", "inst", "mag"}。★ inst 是必需的:允许同类型两把,残弹必须按具体那把记 —— 按类型记会让"丢一把空弹、捡一把满弹"变成免费换弹且不报错。
var held: Array[Dictionary] = []

var _tiers: Dictionary
var _next_inst: int = 1


func _init(tiers: Dictionary, new_capacity: int = DEFAULT_CAPACITY,
		new_max_weapons: int = DEFAULT_MAX_WEAPONS) -> void:
	_tiers = tiers
	capacity = maxi(1, new_capacity)
	max_weapons = maxi(1, new_max_weapons)


func tier_of(type_id: int) -> int:
	return int(_tiers.get(type_id, TIER_LIGHT))


func cost_of(type_id: int) -> int:
	return int(CELL_COST.get(tier_of(type_id), CELL_COST[TIER_LIGHT]))


func used_cell_count() -> int:
	var n := 0
	for e in held:
		n += cost_of(int(e["type"]))
	return n


# 两条闸门都在这里;调用方必须先问过它再 add() —— add() 自己不代替闸门(加了就是静默超容,出问题看不出是哪一步放进去的)。
func can_hold(type_id: int) -> bool:
	if held.size() >= max_weapons:
		return false
	return used_cell_count() + cost_of(type_id) <= capacity


func add(type_id: int, mag: int) -> int:
	var inst := _next_inst
	_next_inst += 1
	held.append({"type": type_id, "inst": inst, "mag": mag})
	return inst


func remove_at(index: int) -> Dictionary:
	if index < 0 or index >= held.size():
		return {}
	return held.pop_at(index)


func index_of_inst(inst: int) -> int:
	for i in held.size():
		if int(held[i]["inst"]) == inst:
			return i
	return -1


func first_index_of_type(type_id: int) -> int:
	for i in held.size():
		if int(held[i]["type"]) == type_id:
			return i
	return -1


func cell_start(index: int) -> int:
	var n := 0
	for i in range(0, mini(index, held.size())):
		n += cost_of(int(held[i]["type"]))
	return n


func snapshot() -> Array:
	var out: Array = []
	for e in held:
		out.append({"type": int(e["type"]), "inst": int(e["inst"]), "mag": int(e["mag"])})
	return out


func restore(entries: Array) -> void:
	held.clear()
	for e in entries:
		var d: Dictionary = e
		var inst := int(d.get("inst", 0))
		held.append({"type": int(d.get("type", 1)), "inst": inst, "mag": int(d.get("mag", MAG_FULL))})
# ★ 必须把 _next_inst 顶到已用 inst 之上 —— 否则恢复后新加的条目会与旧条目撞 inst,而 inst 是"哪把是哪个"的唯一凭据(撞了 = 残弹串到另一把枪上)。
		_next_inst = maxi(_next_inst, inst + 1)


func clear() -> void:
	held.clear()
