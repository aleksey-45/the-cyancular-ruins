extends Node

# 全仓脚本加载自检:递归扫 res:// 下全部 .gd 逐个 load(),抓悬空引用/解析错误。
# 场景模式跑(autoload 可用);对"大回退/大合并后的第一件事"特别有用。
#   godot --headless --path . res://tests/probe/allscript_probe.tscn

const SKIP_DIRS := ["res://.godot", "res://builds", "res://releases", "res://gamelogs",
		"res://crashlogs", "res://maps", "res://map", "res://backup", "res://editor/_build",
		"res://_crashtest"]
# ★ 为什么要收 `res://_crashtest`(与 `tools/check_naming.py` 里同名的根同因):它是 gitignore 的
#   现场草稿,存着编译不过的旧 `.gd` 备份;不收它本探针"改前就红",而一条永远红的闸等于没有闸。
#   ⚠ 它与 `tests/path_integrity_allow.txt` 是两份手工同步的真相源(登记:registered-debt R25)——
#   增删 `SKIP_DIRS` 时必须同时改豁免表,否则 `path_integrity_probe` 会红。

# ★ 为什么必须有一条数闸:一个过宽的 `SKIP_DIRS` 项、一个 `.gdignore`、一次 `DirAccess.open`
#   失败,都只让 `_total` 变小,而探针照打 `OK(n)` ⇒ 它是一道 fail-open 的闸:自己瞎了也不知道。
#   故下面的判据用 `!=` 而不是 `<` —— 它同时钉住"没有少、也没有多"。
#
# `EXPECTED_SCRIPTS` 的数法:数的是"`res://` 下参与编译面的 `.gd` 个数" ——
# 排除名字以 `.` 开头的目录、`SKIP_DIRS` 各项、以及 `*.gd.remap`(见 `_collect`)。
# 复算两条(必须同时成立):`git ls-files '*.gd' | wc -l` 等于本常量;
# `git ls-files --others --exclude-standard '*.gd'` = 0(工作树没有未跟踪脚本)。
# 改这个常量是"覆盖变了得有人过目",不是"让闸变绿";历次取值见 git log。
const EXPECTED_SCRIPTS := 188   # 2026-10-23: -3 = core/net/playout_clock.gd + tests/smoke/playout_clock_smoke.gd + tests/probe/replica_smoothness_probe.gd(删除 playout 设计)

var _fails: Array[String] = []
var _total := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for p in _collect("res://"):
		_total += 1
		var s = load(p)
		# 只判 `s == null` 抓不到解析错误:GDScript 解析失败时 `load()` 仍返回非 null 的对象,
		# 只是 `can_instantiate() == false`(实测有一个真解析错误就是从旧判据下溜过去的)。故两条都判。
		var broken := s is GDScript and not (s as GDScript).can_instantiate()
		if s == null or broken:
			_fails.append(p)
			print("LOAD[FAIL]: %s(%s)" % [p, "解析失败/不可实例化" if broken else "load() 返回 null"])
	# 收尾两道(同 `tests/lib/probe_base.gd` 的 `_checks >= EXPECTED_CHECKS` 那条纪律,只是这里
	# 的"条数"是被扫的脚本数):① 脚本数 `!= EXPECTED_SCRIPTS` ⇒ 红(少了是缺口,多了是覆盖变了);
	# ② 有加载失败 ⇒ 红。判词点名条数,否则"闸红了"与"扫描面塌了"在输出上分不出来。
	var count_ok := _total == EXPECTED_SCRIPTS
	if not count_ok:
		print("ALLSCRIPT: 条数闸 FAIL —— 实扫 %d 个脚本,期望 %d(覆盖面对不上;见本文件头部)"
				% [_total, EXPECTED_SCRIPTS])
	if _fails.is_empty() and count_ok:
		print("ALLSCRIPT: OK(%d 个脚本全部加载)" % _total)
		get_tree().quit(0)
	else:
		# 条数闸红时把原因并进裁决行 —— 否则会打出一行像"零失败"的 `FAIL(0/131 失败)`。
		print("ALLSCRIPT: FAIL(%d/%d 失败%s)" % [_fails.size(), _total,
				("" if count_ok else " · 条数闸红(期望 %d)" % EXPECTED_SCRIPTS)])
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
