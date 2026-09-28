extends Node

# 联机页解析冒烟(场景模式):load() 三个大厅页场景 + 一键联机两个新脚本,
# 外加 OneClickNet 面板实例化+开关(纯 UI 构建,不触内核/提权)。
# ★ 存在的理由:`--check-only --script` 不加载工程,认不出 NetBus 等 autoload,
#   对联机页**必然假阴性**(项目踩过);这类脚本只能在场景模式里验。
#   godot --headless --path . res://tests/lobby_parse_smoke.tscn

const TARGETS := [
	"res://scenes/matchmaking.tscn",
	"res://scenes/royale_lobby.tscn",
	"res://scenes/team_lobby.tscn",
	"res://ui/one_click_net.gd",
	"res://core/net/easytier_link.gd",
]


func _ready() -> void:
	var fails := 0
	for t: String in TARGETS:
		var res = load(t)
		var ok := res != null
		print("PARSE[%s]: %s" % ["OK" if ok else "FAIL", t])
		if not ok:
			fails += 1
	# 一键联机面板:实例化 + setup + open + close(纯 UI,不触内核/提权)
	var panel = load("res://ui/one_click_net.gd").new()
	add_child(panel)
	panel.setup()
	panel.open()
	await get_tree().process_frame
	panel.close()
	panel.queue_free()
	print("PARSE[OK]: OneClickNet 实例化+开关(无报错)")
	print("PARSE: %d 项,%d 失败 → %s" % [TARGETS.size() + 1, fails, "ALL-OK" if fails == 0 else "FAILED"])
	get_tree().quit(1 if fails > 0 else 0)
