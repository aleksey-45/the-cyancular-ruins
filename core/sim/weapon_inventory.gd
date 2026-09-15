class_name WeaponInventory
extends RefCounted

# 武器背包的**纯逻辑**:持有表 + 容量预算。无 autoload 依赖、可 -s 测。
#
# ★ tier 数值刻意与 WeaponBase.Tier 对齐(LIGHT=0/MEDIUM=1/HEAVY=2),但**不 import
#   weapon_base.gd** —— 它的 @export 默认值 preload 了 bullet.tscn,会连带把 autoload
#   拖进 -s 冒烟(见 tests 里"autoload 尚未实例化"的注释)。对齐关系由
#   enemy_logic_smoke 的 _phase_weapon_registry 钉住(漂移即红)。
#
# ★ 容量(8 格)与把数上限(4 把)是**两条闸门**,不是一条推另一条
#   —— 用户 2026-09-15 明确裁定「就算容量给 100 也最多四把」。
#   但要说实话:按今天的 cost 表(最便宜 2 格),4 把 × 2 = 8 = CAPACITY,
#   所以 MAX_WEAPONS 其实已被容量蕴含。它**不是死代码**:一旦有人把轻武器改成
#   1 格、或把 CAPACITY 调大,"最多 4 把"这个承诺就只剩这一条在守 ——
#   tests/weapon_inventory_smoke.gd 里钉了那条临界等式,它一旦不成立就该回来重看这里。

const TIER_LIGHT := 0
const TIER_MEDIUM := 1
const TIER_HEAVY := 2
const SLOT_COST: Dictionary = {TIER_LIGHT: 2, TIER_MEDIUM: 3, TIER_HEAVY: 4}

const MAX_WEAPONS := 4
const CAPACITY := 8

# 条目里的 mag == MAG_FULL 表示「满弹」:入树后不覆盖武器 _ready 设的满弹。
const MAG_FULL := -1

# 背包条目,按获得顺序。每条 {"type": 类型 id 1-6, "inst": 实例序号, "mag": 残弹}
# ★ inst 是必需的:允许持有同类型两把,残弹必须按**具体那把**记 ——
#   按类型记会让「丢一把空弹手枪、捡一把满地手枪」变成免费换弹,且完全不报错。
var held: Array[Dictionary] = []

var _tiers: Dictionary         # type_id -> tier
var _next_inst: int = 1


func _init(tiers: Dictionary) -> void:
	_tiers = tiers


func tier_of(type_id: int) -> int:
	return int(_tiers.get(type_id, TIER_LIGHT))


func cost_of(type_id: int) -> int:
	return int(SLOT_COST.get(tier_of(type_id), SLOT_COST[TIER_LIGHT]))


func used_slots() -> int:
	var n := 0
	for e in held:
		n += cost_of(int(e["type"]))
	return n


# 两条闸门都在这里。调用方必须先问过它再 add() —— add() 自己不代替闸门
# (加了就是"静默超容",出问题时看不出是哪一步放进去的)。
func can_hold(type_id: int) -> bool:
	if held.size() >= MAX_WEAPONS:
		return false
	return used_slots() + cost_of(type_id) <= CAPACITY


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


# 紧凑排布:第 index 把占据格子 [slot_start(index), slot_start(index)+cost)。
# 删中间一条,其后整体左移 —— 换来实现上的"格子永不空洞",HUD 上看到的是整段移动。
func slot_start(index: int) -> int:
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
		# ★ 必须把 _next_inst 顶到已用 inst 之上 —— 否则恢复后新加的条目会与旧条目撞 inst,
		#   而 inst 是"哪把是哪个"的唯一凭据(撞了 = 残弹串到另一把枪上)。
		_next_inst = maxi(_next_inst, inst + 1)


func clear() -> void:
	held.clear()
