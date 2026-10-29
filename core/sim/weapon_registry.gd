class_name WeaponRegistry
extends RefCounted

# 武器注册表：统一由 res://data/weapons.json 驱动。
#
# 特性说明：
# - 纯静态工具类，无 Autoload 依赖。
# - 元数据查询不加载场景；客户端首次查询弹丸表现参数时加载并缓存对应武器场景配置。
# - 仅负责武器基础元数据（id、name、tier、scene 路径），具体战斗数值在各武器场景的 @export 中配置。
# - all_ids() 返回顺序严格保持与 JSON 数组中定义的顺序一致。

const PATH := "res://data/weapons.json"

# 武器量级字符串到数值常量的映射（对齐 WeaponInventory.TIER_*）
const TIER_NAMES: Dictionary = {
	"light": WeaponInventory.TIER_LIGHT,
	"medium": WeaponInventory.TIER_MEDIUM,
	"heavy": WeaponInventory.TIER_HEAVY,
}

static var _entries: Array[Dictionary] = []   # [{id, name, tier, scene}]
static var _loaded := false
static var _projectile_profiles: Dictionary = {}

static func projectile_profile(type_id: int) -> Dictionary:
	if not _projectile_profiles.has(type_id):
		var weapon = load(scene_of(type_id)).instantiate()
		var projectile = weapon.bullet_scene.instantiate()
		_projectile_profiles[type_id] = {"scene": weapon.bullet_scene, "range": weapon.bullet_range,
				"size": weapon.bullet_size, "color": weapon.bullet_color, "gravity": weapon.bullet_gravity,
				"impact": weapon.impact, "damage": weapon.damage,
				"explosion_visual": projectile.explosion_visual, "explosion_radius": projectile.explosion_radius,
				"explosion_knockback": projectile.explosion_knockback, "explosion_damage": projectile.explosion_damage}
		projectile.free()
		weapon.free()
	return _projectile_profiles[type_id]


# 原生战斗核使用同一份场景参数；初始化时一次读取，热循环不实例化场景或回调脚本。
static func native_profiles() -> Dictionary:
	for type_id: int in all_ids(): projectile_profile(type_id)
	return _projectile_profiles

# 懒加载：首次查询时自动读取配置文件
static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_entries = []
	var text := FileAccess.get_file_as_string(PATH)
	if text.is_empty():
		push_error("WeaponRegistry: 无法读取配置文件 %s（请确认导出包中已包含该资源）" % PATH)
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed.get("weapons", []) is Array):
		push_error("WeaponRegistry: %s 顶层格式必须为 {\"weapons\": [...]}" % PATH)
		return
	var seen := {}
	var idx := -1
	for raw in parsed["weapons"]:
		idx += 1
		if typeof(raw) != TYPE_DICTIONARY:
			push_error("WeaponRegistry: weapons[%d] 不是对象结构，已跳过" % idx)
			continue
		var e: Dictionary = raw
		# 强制转换为 int 类型，避免 JSON 解析浮点数作为字典键时产生不匹配
		var id := int(e.get("id", 0))
		if id <= 0:
			push_error("WeaponRegistry: weapons[%d].id 必须为正整数（实际为 %s），已跳过" % [idx, str(e.get("id"))])
			continue
		if seen.has(id):
			push_error("WeaponRegistry: 武器 ID %d 重复（weapons[%d]），已跳过" % [id, idx])
			continue
		var tier_name := str(e.get("tier", ""))
		if not TIER_NAMES.has(tier_name):
			push_error("WeaponRegistry: 武器 ID %d 的 tier 属性非法（实际为 \"%s\"，应为 light/medium/heavy），已跳过" % [id, tier_name])
			continue
		var wname := str(e.get("name", ""))
		if wname.is_empty():
			push_error("WeaponRegistry: 武器 ID %d 缺少 name 属性，已跳过" % id)
			continue
		var scene := str(e.get("scene", ""))
		if scene.is_empty() or not ResourceLoader.exists(scene):
			push_error("WeaponRegistry: 武器 ID %d 的 scene 资源不存在（%s），已跳过" % [id, scene])
			continue
		seen[id] = true
		_entries.append({"id": id, "name": wname, "tier": tier_name, "scene": scene})
	if _entries.is_empty():
		push_error("WeaponRegistry: 注册表为空，未解析到有效武器配置条目：%s" % PATH)


## 获取所有已登记的武器 ID 列表（严格保证为整数类型）
static func all_ids() -> Array[int]:
	_ensure_loaded()
	var out: Array[int] = []
	for e in _entries:
		out.append(int(e["id"]))
	return out


## 检查指定 ID 的武器是否已登记
static func has(type_id: int) -> bool:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return true
	return false


## 获取武器预制体场景路径
static func scene_of(type_id: int) -> String:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return str(e["scene"])
	return ""


## 获取武器显示名称
static func name_of(type_id: int) -> String:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return str(e["name"])
	return ""


## 获取武器量级（返回 WeaponInventory.TIER_* 整数值）
static func tier_of(type_id: int) -> int:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return int(TIER_NAMES[str(e["tier"])])
	return WeaponInventory.TIER_LIGHT


## 获取全量武器量级映射表 {type_id: tier}，用于初始化背包
static func tiers_map() -> Dictionary:
	_ensure_loaded()
	var out := {}
	for e in _entries:
		out[int(e["id"])] = int(TIER_NAMES[str(e["tier"])])
	return out
