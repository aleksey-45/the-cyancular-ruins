extends Node

# 联机页解析冒烟(场景模式):load() 统一大厅页场景。
# - 存在的理由:`--check-only --script` 不加载工程,认不出 NetBus 等 autoload,
#   对联机页**必然假阴性**(项目踩过);这类脚本只能在场景模式里验。
#   godot --headless --path . res://tests/smoke/lobby_parse_smoke.tscn

const TARGETS := [
	"res://scenes/mp_lobby.tscn",
]


func _ready() -> void:
	var fails := 0
	for t: String in TARGETS:
		var res = load(t)
		var ok := res != null
		print("PARSE[%s]: %s" % ["OK" if ok else "FAIL", t])
		if not ok:
			fails += 1
	print("PARSE: %d 项,%d 失败 → %s" % [TARGETS.size(), fails, "ALL-OK" if fails == 0 else "FAILED"])
	get_tree().quit(1 if fails > 0 else 0)
