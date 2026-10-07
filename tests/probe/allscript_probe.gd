extends Node

# 全局脚本编译与加载完整性验证探针：
# 递归扫描 res:// 下所有 .gd 脚本并逐个调用 load()，检查是否存在悬空引用、未声明变量或语法解析错误。
# 场景模式运行（保证 Autoload 单例正常初始化）：
#   godot --headless --path . res://tests/probe/allscript_probe.tscn

# 排除目录：
# - 运行时临时目录、导出产物、日志与地图数据等无需参与脚本语法检查的目录。
# - res://_crashtest 包含部分历史弃用脚本与临时备份，不属于工程核心源码，予以跳过以防误报。
const SKIP_DIRS := ["res://.godot", "res://builds", "res://releases", "res://gamelogs",
		"res://crashlogs", "res://maps", "res://map", "res://backup", "res://editor/_build",
		"res://_crashtest"]

# 预期扫描脚本总数：
# 设定固定的扫描脚本数量基准，防止因目录过滤规则异常或遍历失败导致跳过检查却误判为通过。
# 若后续工程正常增删源码脚本，需同步更新该基准值。
const EXPECTED_SCRIPTS := 290

var _fails: Array[String] = []
var _total := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for p in _collect("res://"):
		_total += 1
		var s = load(p)
		# 注意： 2026-10-02 合并时实测补的判据:只判 `s == null` **抓不到解析错误** ——
		#   GDScript 解析失败时 `load()` 仍返回**非 null** 的、只是 `can_instantiate() == false`
		#   的 GDScript。实测:往树上放一个引用未声明标识符的脚本,旧实现照样打
		#   "ALLSCRIPT: OK(N 个脚本全部加载)"(`load()` 只在"文件不存在/资源类型不认"时才返回 null)。
		#    ->  必须**两条都判**。合并时就有一个真解析错误(`pvp_match_client.gd` 的 `_delta` /
		#   `cell` 未声明)从旧判据下溜过去,是靠 `team_room_smoke` 红才发现的。
		var broken := s is GDScript and not (s as GDScript).can_instantiate()
		if s == null or broken:
			_fails.append(p)
			print("LOAD[FAIL]: %s(%s)" % [p, "解析失败/不可实例化" if broken else "load() 返回 null"])
	# - 收尾两道(与 `tests/lib/probe_base.gd` 的 `_checks >= EXPECTED_CHECKS` 同一条纪律,
	#   只是这里的"条数"是**被扫的脚本数**):① 扫到的脚本数 `!= EXPECTED_SCRIPTS`  ->  红
	#   (**两侧都红**:少了是覆盖缺口,多了是覆盖变了);② 有加载失败  ->  红。
	#   判词**明确提示条数**,否则"闸红了"与"扫描面塌了"在输出上分不出来。
	var count_ok := _total == EXPECTED_SCRIPTS
	if not count_ok:
		print("ALLSCRIPT: 条数闸 FAIL —— 实扫 %d 个脚本,期望 %d(覆盖面对不上;见本文件头部)"
				% [_total, EXPECTED_SCRIPTS])
	if _fails.is_empty() and count_ok:
		print("ALLSCRIPT: OK(%d 个脚本全部加载)" % _total)
		get_tree().quit(0)
	else:
		# 计数检查失败时把原因并进裁决行 —— 否则会打出一行像"零失败"的 `FAIL(0/131 失败)`。
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
