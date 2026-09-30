extends Node

# 全量脚本加载冒烟(**场景模式** —— 必须,`-s` 没有 autoload,认不出 NetBus/GameParameters/Settings,
# 对绝大多数脚本必然假阴性)。
# 判据:每个 .gd 都能 load 且 can_instantiate。任何 Parse Error / Compile Error 都会让它出现在 BAD 里。
#   godot --headless --path . res://tests/script_load_probe.tscn

const DIRS := ["res://core", "res://scenes", "res://server", "res://ui", "res://tests", "res://render"]
const SKIP := ["script_load_probe.gd"]   # 自己

var _bad: Array[String] = []
var _n := 0


func _ready() -> void:
	for d in DIRS:
		_walk(d)
	for f in DirAccess.get_files_at("res://"):
		if f.ends_with(".gd"):
			_check("res://" + f)
	# 排除已知的"模式探针"(它们故意只跑某一种模式),其余坏一个就是坏一个
	print("ALLLOAD total=%d bad=%d" % [_n, _bad.size()])
	for b in _bad:
		print("  BAD ", b)
	print("ALLLOAD: %s" % ("ALL-OK" if _bad.is_empty() else "FAILED"))
	get_tree().quit(1 if not _bad.is_empty() else 0)


func _walk(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd") and not SKIP.has(f):
			_check(dir + "/" + f)
	for sub in d.get_directories():
		_walk(dir + "/" + sub)


func _check(p: String) -> void:
	_n += 1
	var s: GDScript = load(p)
	if s == null or not s.can_instantiate():
		_bad.append(p)
