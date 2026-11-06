extends Node


const SKIP_DIRS := ["res://.godot", "res://.tmp", "res://builds", "res://releases", "res://gamelogs",
		"res://crashlogs", "res://maps", "res://map", "res://backup", "res://editor/_build",
		"res://_crashtest", "res://docs"]

const EXPECTED_SCRIPTS := 250

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
	var count_ok := _total == EXPECTED_SCRIPTS
	if not count_ok:
		print("ALLSCRIPT: 条数闸 FAIL —— 实扫 %d 个脚本,期望 %d(覆盖面对不上;见本文件头部)"
				% [_total, EXPECTED_SCRIPTS])
	if _fails.is_empty() and count_ok:
		print("ALLSCRIPT: OK(%d 个脚本全部加载)" % _total)
		get_tree().quit(0)
	else:
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
