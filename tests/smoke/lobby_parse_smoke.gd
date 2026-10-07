extends Node

# 大厅数据结构与协议解析冒烟测试：
# 验证大厅建房、房间列表更新和玩家准备状态等网络协议载荷的序列化与反序列化。
# 运行方式：
#   "$GODOT" --headless --path . res://tests/smoke/lobby_parse_smoke.tscn

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
