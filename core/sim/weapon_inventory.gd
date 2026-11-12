class_name WeaponInventory
extends RefCounted

# 武器背包逻辑实现：管理持有的武器列表与背包容量预算（纯逻辑，无 Autoload 依赖）。
#
# 设计说明：
# - 容量上限（默认 8 格）与武器数量上限（默认 4 把）为双重约束条件。
# - 背包容量与数量上限作为实例属性维护，支持不同模式或角色特性动态调整。
# - 武器按三元组扁平存放：快照就是整段整数复制，采集与恢复都不构造条目对象。

const TIER_LIGHT := 0
const TIER_MEDIUM := 1
const TIER_HEAVY := 2
const CELL_COST: Dictionary = {TIER_LIGHT: 2, TIER_MEDIUM: 3, TIER_HEAVY: 4}

# 背包默认约束上限
const DEFAULT_MAX_WEAPONS := 4
const DEFAULT_CAPACITY := 8

var max_weapons: int = DEFAULT_MAX_WEAPONS
var capacity: int = DEFAULT_CAPACITY

# 默认携带状态由装备类型解释。
const DEFAULT_CARRIED := -1

# 条目三元组布局：第 i 把武器的字段起点为 i * STRIDE
const STRIDE := 3
const TYPE := 0
const INST := 1
const CARRIED := 2

# 背包武器列表，按获得顺序排列，每 STRIDE 个整数为一把武器。
# 每个武器实例分配唯一自增的 inst ID，用于追踪具体装备的携带状态。
var items: PackedInt32Array = []

var _next_inst: int = 1

func count() -> int:
	return items.size() / STRIDE

func type_at(index: int) -> int:
	return items[index * STRIDE + TYPE]

func inst_at(index: int) -> int:
	return items[index * STRIDE + INST]

func carried_at(index: int) -> int:
	return items[index * STRIDE + CARRIED]

func set_carried(index: int, carried: int) -> void:
	items[index * STRIDE + CARRIED] = carried

func cost_of(type_id: int) -> int:
	return CELL_COST[WeaponRegistry.definition(type_id)["tier"]]

func used_cell_count() -> int:
	return cell_start(count())


## 优先新增，放不下时尝试替换指定槽位。返回写入的槽位，失败返回 -1。
func try_add(type_id: int, carried: int, replace_index: int = -1) -> int:
	var index := count()
	var used := used_cell_count() + cost_of(type_id)
	if index < max_weapons and used <= capacity:
		items.resize(items.size() + STRIDE)
	else:
		if replace_index < 0 or replace_index >= index or index > max_weapons:
			return -1
		if used - cost_of(type_at(replace_index)) > capacity:
			return -1
		index = replace_index
	var base := index * STRIDE
	items[base + TYPE] = type_id
	items[base + INST] = _next_inst
	items[base + CARRIED] = carried
	_next_inst += 1
	return index

func remove_at(index: int) -> void:
	if index < 0 or index >= count():
		return
	var base := index * STRIDE
	items.remove_at(base)
	items.remove_at(base)
	items.remove_at(base)

func index_of_inst(inst: int) -> int:
	for i in count():
		if inst_at(i) == inst:
			return i
	return -1


## 计算第 index 把武器在背包格子中的起始位置（紧凑排布）
func cell_start(index: int) -> int:
	var n := 0
	for i in range(0, mini(index, count())):
		n += cost_of(type_at(i))
	return n

## 只保留指定槽位的武器，其余丢弃
func keep_only(index: int) -> void:
	items = PackedInt32Array([type_at(index), inst_at(index), carried_at(index)])

## 背包快照。Packed 数组赋值共用缓冲区，快照必须显式复制成独立缓冲
## 否则发出后的快照会随后续换弹、丢弃一起变动。
func snapshot() -> PackedInt32Array:
	return items.duplicate()

## 恢复背包同样复制：调用方传入的多半是历史帧或解码结果，不能与背包共用缓冲
func restore(entries: PackedInt32Array) -> void:
	items = entries.duplicate()
	for i in count():
		# 确保 _next_inst 高于已还原的实例 ID，避免后续生成重复 ID
		_next_inst = maxi(_next_inst, inst_at(i) + 1)

func clear() -> void:
	items.clear()
