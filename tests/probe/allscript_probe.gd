extends Node

# 全仓脚本加载自检:递归扫 res:// 下全部 .gd 逐个 load(),抓悬空引用/解析错误。
# 场景模式跑(autoload 可用);对"大回退/大合并后的第一件事"特别有用。
#   godot --headless --path . res://tests/probe/allscript_probe.tscn

const SKIP_DIRS := ["res://.godot", "res://builds", "res://releases", "res://gamelogs",
		"res://crashlogs", "res://maps", "res://map", "res://backup", "res://editor/_build"]

var _fails: Array[String] = []
var _total := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for p in _collect("res://"):
		_total += 1
		var s = load(p)
		# ★★ 2026-10-02 合并时实测补的判据:只判 `s == null` **抓不到解析错误** ——
		#   GDScript 解析失败时 `load()` 仍返回**非 null** 的、只是 `can_instantiate() == false`
		#   的 GDScript。实测:往树上放一个引用未声明标识符的脚本,旧实现照样打
		#   "ALLSCRIPT: OK(N 个脚本全部加载)"(`load()` 只在"文件不存在/资源类型不认"时才返回 null)。
		#   ⇒ 必须**两条都判**。合并时就有一个真解析错误(`pvp_match_client.gd` 的 `_delta` /
		#   `cell` 未声明)从旧判据下溜过去,是靠 `team_room_smoke` 红才发现的。
		var broken := s is GDScript and not (s as GDScript).can_instantiate()
		if s == null or broken:
			_fails.append(p)
			print("LOAD[FAIL]: %s(%s)" % [p, "解析失败/不可实例化" if broken else "load() 返回 null"])
	if _fails.is_empty():
		print("ALLSCRIPT: OK(%d 个脚本全部加载)" % _total)
		get_tree().quit(0)
	else:
		print("ALLSCRIPT: FAIL(%d/%d 失败)" % [_fails.size(), _total])
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
