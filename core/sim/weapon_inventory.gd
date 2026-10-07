class_name WeaponInventory
extends RefCounted

# 武器背包逻辑实现：管理持有的武器列表与背包容量预算（纯逻辑，无 Autoload 依赖）。
#
# 设计说明：
# - 武器量级数值与 WeaponBase.Tier 对齐（LIGHT=0, MEDIUM=1, HEAVY=2），但不直接引用
#   WeaponBase，避免将场景预加载依赖引入纯逻辑单元测试。
# - 容量上限（默认 8 格）与武器数量上限（默认 4 把）为双重约束条件。
# - 背包容量与数量上限作为实例属性维护，支持不同模式或角色特性动态调整。

const TIER_LIGHT := 0
const TIER_MEDIUM := 1
const TIER_HEAVY := 2
const CELL_COST: Dictionary = {TIER_LIGHT: 2, TIER_MEDIUM: 3, TIER_HEAVY: 4}

# 背包默认约束上限
const DEFAULT_MAX_WEAPONS := 4
const DEFAULT_CAPACITY := 8

var max_weapons: int = DEFAULT_MAX_WEAPONS
var capacity: int = DEFAULT_CAPACITY

# 条目中的 mag == MAG_FULL 表示满弹状态（加入场景树后不覆盖武器 _ready 初始化的弹药）
const MAG_FULL := -1

# 背包武器条目列表，按获得顺序排列。每项结构为 {"type": type_id, "inst": inst_id, "mag": ammo}
# 每个武器实例分配唯一自增的 inst ID，用于精确追踪具体武器的剩余弹药。
var held: Array[Dictionary] = []

var _tiers: Dictionary         # type_id -> tier
var _next_inst: int = 1


func _init(tiers: Dictionary, new_capacity: int = DEFAULT_CAPACITY,
		new_max_weapons: int = DEFAULT_MAX_WEAPONS) -> void:
	_tiers = tiers
	capacity = maxi(1, new_capacity)
	max_weapons = maxi(1, new_max_weapons)


func set_capacity(n: int) -> void:
	capacity = maxi(1, n)


func set_max_weapons(n: int) -> void:
	max_weapons = maxi(1, n)


func tier_of(type_id: int) -> int:
	return int(_tiers.get(type_id, TIER_LIGHT))


func cost_of(type_id: int) -> int:
	return int(CELL_COST.get(tier_of(type_id), CELL_COST[TIER_LIGHT]))


func used_cell_count() -> int:
	var n := 0
	for e in held:
		n += cost_of(int(e["type"]))
	return n


## 检查背包是否能够容纳指定类型的武器（同时满足数量上限与格子容量上限）
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


## 计算第 index 把武器在背包格子中的起始位置（紧凑排布）
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
		# 确保 _next_inst 高于已还原的实例 ID，避免后续生成重复 ID
		_next_inst = maxi(_next_inst, inst + 1)


func clear() -> void:
	held.clear()
