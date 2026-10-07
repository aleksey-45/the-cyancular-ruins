class_name WeaponRegistry
extends RefCounted

# 武器注册表:唯一来源 `data/weapons.json`(与 data/enemies.json / data/tile_defs.json 相同机制)。
#
# - 纯静态、无 autoload、`-s` 可测(与 MapFormat / GridPathfinder 相同机制)。
#
# 注意： **绝不 `load()` 武器场景**,`tier_of()` 返回**裸 int**,不返回 `WeaponBase.Tier`:
#   `weapon_base.gd:7` 的 `@export var bullet_scene = preload("res://scenes/weapons/bullet.tscn")`
#   会把 autoload 拖进 `-s` —— `weapon_inventory.gd:6-9` 记的正是这条,它宁可让调用方
#   **注入** tiers 表也不 import 那个类。数值对齐由 enemy_logic_smoke 逐条钉住。
#
# - 只装身份(id / name / tier / scene 路径)。数值(fire_cooldown / damage / mag_size /
#   reload_time / recoil / …)继续留在各枪的 .tscn @export 里 —— 保住 Godot 编辑器里
#   可视化调参的能力,与 data/enemies.json 同构。
#
# - json **数组顺序 = 菜单顺序 = 散落顺序**(`all_ids()` 原样按 json 顺序返回)。
#   重排 json 会改变菜单与散落顺序 —— 不是 bug,但没有守卫拦误排(登记,本次不做)。

const PATH := "res://data/weapons.json"

# tier 字符串 → 数值。-  数值直接取 `WeaponInventory.TIER_*`,**不另立一套整数** ——
#   那一套与 `WeaponBase.Tier` 的对齐由 enemy_logic_smoke 钉着(约定,不是编译器保证)。
#   const 里引用别的类的常量是本仓既有写法(见 weapon_component 旧 TIERS 表的 `WeaponBase.Tier.*`)。
const TIER_NAMES: Dictionary = {
	"light": WeaponInventory.TIER_LIGHT,
	"medium": WeaponInventory.TIER_MEDIUM,
	"heavy": WeaponInventory.TIER_HEAVY,
}

static var _entries: Array[Dictionary] = []   # [{id, name, tier, scene}],json 顺序
static var _loaded := false


# 懒加载:首次查询时读一次。不需要调用方记得先 load —— 本仓有 6 处调用点分散在
# `_ready` 的很早阶段(菜单/大厅/关卡),漏一处就是"菜单少一把枪"。
static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true   # - 先置位:解析失败时不要每次查询都重读+重报一遍
	_entries = []
	var text := FileAccess.get_file_as_string(PATH)
	if text.is_empty():
		push_error("WeaponRegistry: 读不到 %s —— 导出包里没有它?" % PATH)
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed.get("weapons", []) is Array):
		push_error("WeaponRegistry: %s 顶层必须是 {\"weapons\": [...]}" % PATH)
		return
	var seen := {}
	var idx := -1
	for raw in parsed["weapons"]:
		idx += 1
		# 注意： 逐条校验:**不合格 push_error + 跳过该条**。
		#   ⚠ 这**不是** EnemySpawner 的约定 —— 它(`enemy_spawner.gd:29-31`)对逐条的坏数据
		#   只是 `continue`,一个字都不打;`push_error` + 整表留空只发生在**文件级**。
		#   本文件是"每条坏数据都有声音"的**新约定**,别拿这条去改 EnemySpawner。
		if typeof(raw) != TYPE_DICTIONARY:
			push_error("WeaponRegistry: weapons[%d] 不是对象,已跳过" % idx)
			continue
		var e: Dictionary = raw
		# 注意： `int(...)` **不是可选的美化**:JSON 的数字一律解析成 float(`1` 变 `1.0`),
		#   而 `1.0` 当字典键 / 当 `int` 形参 / 去 `.has(type_id)` 都会**静默不命中**。
		#   id 全程必须是真 int —— 出口 `all_ids()` 里那一次 `int(...)` 是二次保险,
		#   这里这次才是正本(顺带把非数字的 `id` 归一成 0、被下面那条挡掉)。
		var id := int(e.get("id", 0))
		if id <= 0:
			push_error("WeaponRegistry: weapons[%d].id 不是正整数(实际 %s),已跳过" % [idx, str(e.get("id"))])
			continue
		if seen.has(id):
			push_error("WeaponRegistry: id %d 重复(weapons[%d]),已跳过" % [id, idx])
			continue
		var tier_name := str(e.get("tier", ""))
		if not TIER_NAMES.has(tier_name):
			push_error("WeaponRegistry: id %d 的 tier 非法(实际 \"%s\";只认 light/medium/heavy),已跳过" % [id, tier_name])
			continue
		var wname := str(e.get("name", ""))
		if wname.is_empty():
			push_error("WeaponRegistry: id %d 缺 name,已跳过" % id)
			continue
		var scene := str(e.get("scene", ""))
		# - 只查"路径存在",**不 load** —— load 会把武器场景(以及它 preload 的 bullet.tscn)
		#   拖进 `-s`,而本文件必须能 `-s` 空跑。真正的"能不能 load / tier 对不对"由
		#   enemy_logic_smoke 的 _phase_weapon_registry 逐条验(它本来就要实例化比 tier)。
		#   - `ResourceLoader.exists()` 内部会走 `_path_remap`(引擎 resource_loader.cpp:1254),
		#   故导出包里 `.tscn` 的改名不影响它。
		if scene.is_empty() or not ResourceLoader.exists(scene):
			push_error("WeaponRegistry: id %d 的 scene 不存在(%s),已跳过" % [id, scene])
			continue
		seen[id] = true
		_entries.append({"id": id, "name": wname, "tier": tier_name, "scene": scene})
	if _entries.is_empty():
		# - 这条是**故意吼的**:它同时提供容错保障两种"整表为空"的成因 —— json 里一条都不合格,
		#   以及导出包里没有这份 json(那种情况下上面第一条已经 push_error 了)。
		#   本特性最坏的失效模式是"发布版里一把枪都没有",不能让它静默。
		push_error("WeaponRegistry: 注册表为空 —— json 里没有合格条目,或导出包漏了 %s" % PATH)


# 注意： **必须返回真正的 int,一个 float 都不能有**(2026-09-26 订正)。
#   坑在 JSON:`JSON.parse_string` 把**所有数字都解析成 float**  ->  `e["id"]` 是 `1.0` 而不是 `1`。
#   两步都要 `int(...)`:装载时 `var id := int(e.get("id", 0))`(那一步同时做校验),
#   以及这里 `out.append(int(e["id"]))`(二次保险,也是**要命的那一步**)。
#   为什么不容忍 float:`type_id` 全仓当 int 用 —— 它是 `tier_of(type_id: int)` /
#   `is_type_enabled(type_id: int)` / `WeaponInventory.SLOT_COST` 一类**字典的键**、
#   以及 `enabled_types.has(type_id)` 的入参;混进 float 会在这些地方**静默不命中**。
#   - 更直接的一条(已实测):`Array[int] [1,2,3] == Array [1,2,3]` 为**真**,
#   但 `== [1, 2, 3.0]` 为**假** —— 于是任何拿 id 数组去比**字面量 int 数组**的断言
#   (enemy_logic_smoke 的 ⑦、以及将来任何探针)会变成**虚假失败（测试用例误报）**,而且看起来像"接线漏了"。
#   那正是本文件 ② 那条"float 当键会让 has() 永远假"的镜像。
static func all_ids() -> Array[int]:
	_ensure_loaded()
	var out: Array[int] = []
	for e in _entries:
		out.append(int(e["id"]))
	return out


static func has(type_id: int) -> bool:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return true
	return false


static func scene_of(type_id: int) -> String:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return str(e["scene"])
	return ""


static func name_of(type_id: int) -> String:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return str(e["name"])
	return ""


# - 返回**裸 int**(与 `WeaponInventory.TIER_*` 同值)。别改成返回 `WeaponBase.Tier`。
static func tier_of(type_id: int) -> int:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return int(TIER_NAMES[str(e["tier"])])
	return WeaponInventory.TIER_LIGHT


# {type_id: tier} —— 供 `WeaponInventory.new(...)` **注入**(它刻意不 import 任何武器类)。
static func tiers_map() -> Dictionary:
	_ensure_loaded()
	var out := {}
	for e in _entries:
		out[int(e["id"])] = int(TIER_NAMES[str(e["tier"])])
	return out


# 只给测试:重读 json(改了 json 后不必重启进程)。
static func reload() -> void:
	_loaded = false
	_entries = []
	_ensure_loaded()
