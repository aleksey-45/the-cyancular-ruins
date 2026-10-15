class_name WeaponRegistry
extends RefCounted

# 武器注册表:唯一来源 data/weapons.json。★ 纯静态、无 autoload、-s 可测。
# ★★ 绝不 load() 武器场景,tier_of() 返回裸 int 而不是 WeaponBase.Tier(那个类会把 autoload 拖进 -s)。
# ★ 只装身份(id/name/tier/scene);数值留在各枪 .tscn 的 @export 里(保住编辑器可视化调参)。★ json 数组顺序 = 菜单顺序 = 散落顺序,重排 json 会改顺序(无守卫拦误排,已登记)。

const PATH := "res://data/weapons.json"

# tier 字符串 → 数值:直接取 WeaponInventory.TIER_*,不另立一套整数(与 WeaponBase.Tier 的对齐是约定、不是编译器保证)。
const TIER_NAMES: Dictionary = {
	"light": WeaponInventory.TIER_LIGHT,
	"medium": WeaponInventory.TIER_MEDIUM,
	"heavy": WeaponInventory.TIER_HEAVY,
}

static var _entries: Array[Dictionary] = []   # [{id, name, tier, scene}],json 顺序
static var _loaded := false


# 懒加载:首次查询时读一次 —— 6 处调用点分散在 _ready 的很早阶段,漏一处就是"菜单少一把枪"。
static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true   # ★ 先置位:解析失败时不要每次查询都重读+重报一遍
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
# ★★ 逐条校验:不合格 push_error + 跳过该条(这是"每条坏数据都有声音"的新约定,别拿它去改只 continue 不报错的 EnemySpawner)。
		if typeof(raw) != TYPE_DICTIONARY:
			push_error("WeaponRegistry: weapons[%d] 不是对象,已跳过" % idx)
			continue
		var e: Dictionary = raw
# ★★ int(...) 不是可选的美化:JSON 数字一律解析成 float(1 变 1.0),而 1.0 当字典键 / 当 int 形参 / 去 has() 都会静默不命中 ⇒ id 全程必须是真 int。
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
# ★ 只查"路径存在"、不 load(load 会把武器场景连它 preload 的 bullet.tscn 一起拖进 -s);ResourceLoader.exists() 内部走 _path_remap,导出包改名不影响它。
		if scene.is_empty() or not ResourceLoader.exists(scene):
			push_error("WeaponRegistry: id %d 的 scene 不存在(%s),已跳过" % [id, scene])
			continue
		seen[id] = true
		_entries.append({"id": id, "name": wname, "tier": tier_name, "scene": scene})
	if _entries.is_empty():
# ★ 这条故意吼:它兜住"整表为空"的两种成因(json 里无合格条目 / 导出包漏了 json);最坏的失效模式是"发布版里一把枪都没有",不能静默。
		push_error("WeaponRegistry: 注册表为空 —— json 里没有合格条目,或导出包漏了 %s" % PATH)


# ★★ 必须返回真正的 int(装载时那一步同时做校验,这里 int(...) 是二次保险):type_id 全仓当 int 用(字典键、has() 入参),混进 float 会静默不命中。
# ★ 已实测:Array[int] [1,2,3] == [1,2,3] 为真,== [1,2,3.0] 为假 ⇒ 拿 id 数组比字面量 int 数组的断言会变成假红、且看起来像接线漏了。
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


# ★ 返回裸 int(与 `WeaponInventory.TIER_*` 同值)。别改成返回 `WeaponBase.Tier`。
static func tier_of(type_id: int) -> int:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return int(TIER_NAMES[str(e["tier"])])
	return WeaponInventory.TIER_LIGHT


# {type_id: tier} —— 供 `WeaponInventory.new(...)` 注入(它刻意不 import 任何武器类)。
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
