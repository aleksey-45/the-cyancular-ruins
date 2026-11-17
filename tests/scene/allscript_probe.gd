extends Node

# 全仓脚本加载体检:遍历 res:// 下所有 .gd,逐个 load(),抓到解析失败/不可实例化的脚本。
#
# ★ 覆盖闸为什么不是"精确等于一个数字":
#   旧写法是 `_total == EXPECTED_SCRIPTS`,那个常数**没有任何机制校验** —— `tests/run_all.sh`
#   只认 `EXPECTED_CHECKS`,从不看它。结果是:每加/删一个脚本都要手动改一次(历史上 14 次提交
#   改了 14 次),多人同时改工作树时还会互相打架(实测两轮:一边加 6 个、一边删 5 个,数字对不上)。
#   更糟的是它把两种相反的事混成同一个红:真缺陷(整个目录被误跳过)和合法增删。
#
# ★ 现在拆成两条,各自盯一种缺陷:
#   ① **每个顶层目录至少要贡献一个脚本** —— 这条抓的是真缺陷:SKIP_DIRS 误配、或 _collect
#      递归写坏,会让某个子树整个不被检查(那些脚本里的解析错误就此静默溜过)。增删文件不影响它。
#   ② **总数下界 MIN_SCRIPTS** —— 兜底抓"整体塌陷"(比如 _collect 直接返回空、或跳过了一半)。
#      取下界而非等值:新增脚本不该红。**加脚本时不用改这个数**,只有真的删掉大批脚本时才下调。
#   判据只回答"扫描面有没有塌",不回答"仓库里恰好有几个脚本"。

const SKIP_DIRS := ["res://.godot", "res://.tmp", "res://builds", "res://releases", "res://gamelogs",
		"res://crashlogs", "res://maps", "res://map", "res://backup", "res://editor/_build",
		"res://_crashtest", "res://docs"]

# 每个顶层目录都必须被扫到(注意:`res://tools` 不在 SKIP_DIRS 里,它也该被检查)。
const REQUIRED_TOP_DIRS := ["res://core", "res://scenes", "res://server", "res://ui",
		"res://tests", "res://tools"]

# 总数下界。**这不是"仓库里有几个脚本"** —— 加脚本不用改它,只在删掉大批脚本时才下调。
# 现值对应 2026-11 的规模(约 260 支);留出余量,塌陷一半才会红。
const MIN_SCRIPTS := 200

var _fails: Array[String] = []
var _total := 0
var _per_dir: Dictionary = {}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for p in _collect("res://"):
		_total += 1
		var top := "res://" + p.get_slice("/", 2)       # res://core/sim/x.gd -> res://core
		_per_dir[top] = int(_per_dir.get(top, 0)) + 1
		var s = load(p)
		# 只判 `s == null` 抓不到解析错误:GDScript 解析失败时 `load()` 仍返回非 null 的对象,
		# 只是 `can_instantiate() == false`(实测有一个真解析错误就是从旧判据下溜过去的)。故两条都判。
		var broken := s is GDScript and not (s as GDScript).can_instantiate()
		if s == null or broken:
			_fails.append(p)
			print("LOAD[FAIL]: %s(%s)" % [p, "解析失败/不可实例化" if broken else "load() 返回 null"])

	# ① 每个顶层目录都必须有脚本被扫到 —— 抓 SKIP_DIRS 误配 / 递归写坏导致的整个子树漏检。
	var empty_dirs: Array[String] = []
	for d in REQUIRED_TOP_DIRS:
		if int(_per_dir.get(d, 0)) == 0:
			empty_dirs.append(d)
	if not empty_dirs.is_empty():
		print("ALLSCRIPT: 覆盖闸 FAIL —— 这些顶层目录一个脚本都没扫到:%s"
				% [", ".join(empty_dirs)])
		print("  (SKIP_DIRS 误配? _collect 递归写坏? 里面若有 .gd,它们的解析错误此刻无人检查)")

	# ② 总数下界 —— 抓整体塌陷。
	var count_ok := _total >= MIN_SCRIPTS
	if not count_ok:
		print("ALLSCRIPT: 条数闸 FAIL —— 实扫 %d 个脚本,低于下界 %d(扫描面塌了;见本文件头部)"
				% [_total, MIN_SCRIPTS])

	if _fails.is_empty() and empty_dirs.is_empty() and count_ok:
		print("ALLSCRIPT: OK(%d 个脚本全部加载 · %d 个顶层目录全部覆盖)" % [_total, REQUIRED_TOP_DIRS.size()])
		get_tree().quit(0)
	else:
		print("ALLSCRIPT: FAIL(%d/%d 失败%s%s)" % [_fails.size(), _total,
				("" if empty_dirs.is_empty() else " · 覆盖闸红(%d 个目录)" % empty_dirs.size()),
				("" if count_ok else " · 条数闸红(下界 %d)" % MIN_SCRIPTS)])
		get_tree().quit(1)


func _collect(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var p := dir_path.path_join(name)
		if dir.current_is_dir():
			if not name.begins_with(".") and not SKIP_DIRS.has(p):
				out.append_array(_collect(p))
		elif name.ends_with(".gd") and not name.ends_with(".gd.remap"):
			out.append(p)
		name = dir.get_next()
	return out
