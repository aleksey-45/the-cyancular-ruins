class_name WeaponInventory
extends RefCounted

# 武器背包的**纯逻辑**:持有表 + 容量预算。无 autoload 依赖、可 -s 测。
#
# - `tier` 数值刻意与 WeaponBase.Tier 对齐(LIGHT=0/MEDIUM=1/HEAVY=2),但**不 import
#   weapon_base.gd** —— 它的 @export 默认值 preload 了 bullet.tscn,会连带把 autoload
#   拖进 -s 冒烟(见 tests 里"autoload 尚未实例化"的注释)。对齐关系由
#   enemy_logic_smoke 的 _phase_weapon_registry 钉住(漂移即红)。
#
# - 容量(**默认** 8 格)与把数上限(**默认** 4 把)是**两条门控前置校验**,不是一条推另一条
#   —— 用户 2026-09-15 明确裁定「就算容量给 100 也最多四把」。
#   但要说实话:按今天的 cost 表(最便宜 2 格),4 把 × 2 = 8 = 默认容量,
#   所以"把数上限"其实已被容量蕴含。它**不是死代码**:一旦有人把轻武器改成
#   1 格、或把默认容量调大,"最多 4 把"这个承诺就只剩这一条在守 ——
#   tests/smoke/weapon_inventory_smoke.gd 里钉了那条临界等式,它一旦不成立就该回来重看这里。
#
# - 为什么两条门控前置校验是**实例字段**而不是类常量(2026-09-25):它们将来要按**能力/模式分叉**
#   (例如某个 buff 把容量加到 12、某个模式只许带两把)。做成常量的话那种分叉只能靠
#   改全局值实现,而全局值会让**同一局里的所有人**一起变。字段化之后每个背包各自持有
#   自己的两条门控前置校验,默认值不变  ->  协议(capture_state / match_options)零改动。

const TIER_LIGHT := 0
const TIER_MEDIUM := 1
const TIER_HEAVY := 2
const CELL_COST: Dictionary = {TIER_LIGHT: 2, TIER_MEDIUM: 3, TIER_HEAVY: 4}

# 两条门控前置校验的**默认值**。-  名字带 `DEFAULT_` 是刻意的:它们只在**构造**时用一次,
# 之后每个实例各自持有 `capacity` / `max_weapons` —— 别再让调用方读这两个常量当"容量"
# (那会得到"默认值"而不是"这个背包的容量",是**静默的错值**)。
const DEFAULT_MAX_WEAPONS := 4
const DEFAULT_CAPACITY := 8

var max_weapons: int = DEFAULT_MAX_WEAPONS
var capacity: int = DEFAULT_CAPACITY

# 条目里的 mag == MAG_FULL 表示「满弹」:加入场景树后不覆盖武器 _ready 设的满弹。
const MAG_FULL := -1

# 背包条目,按获得顺序。每条 {"type": 类型 id 1-6, "inst": 实例序号, "mag": 残弹}
# - `inst` 是必需的:允许持有同类型两把,残弹必须按**具体那把**记 ——
#   按类型记会让「丢一把空弹手枪、捡一把满地手枪」变成免费换弹,且完全不报错。
var held: Array[Dictionary] = []

var _tiers: Dictionary         # type_id -> tier
var _next_inst: int = 1


func _init(tiers: Dictionary, new_capacity: int = DEFAULT_CAPACITY,
		new_max_weapons: int = DEFAULT_MAX_WEAPONS) -> void:
	_tiers = tiers
	# - 钳到 ≥ 1:0 格 / 0 把会让 `can_hold()` 恒假  ->  玩家永远捡不起任何枪(死锁),
	#   而那种配置错误在实机上表现为"拾取没反应",查起来很久。
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


# 两条门控前置校验都在这里。调用方必须先问过它再 add() —— add() 自己不代替门控前置校验
# (加了就是"静默超容",出问题时看不出是哪一步放进去的)。
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


# 紧凑排布:第 index 把占据格子 [cell_start(index), cell_start(index)+cost)。
# 删中间一条,其后整体左移 —— 换来实现上的"格子永不空洞",HUD 上看到的是整段移动。
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
		# - 必须把 _next_inst 顶到已用 inst 之上 —— 否则恢复后新加的条目会与旧条目撞 inst,
		#   而 inst 是"哪把是哪个"的唯一凭据(撞了 = 残弹串到另一把枪上)。
		_next_inst = maxi(_next_inst, inst + 1)


func clear() -> void:
	held.clear()
