extends Node

# 联机页解析冒烟(场景模式):load() 三个大厅页场景 + 我们的隧道链路脚本。
# ★ 存在的理由:`--check-only --script` 不加载工程,认不出 NetBus 等 autoload,
#   对联机页**必然假阴性**(项目踩过);这类脚本只能在场景模式里验。
#   godot --headless --path . res://tests/lobby_parse_smoke.tscn
# ★ 2026-09-30 迁移:原表里还有 `ui/one_click_net.gd` 与 `core/net/easytier_link.gd`
#   (KH 线的 TUN 版一键联机,外加 OneClickNet 面板实例化+开关那一段)——
#   那整套已随"联机只留我们这套"的裁定删除,本冒烟随之换成我们的隧道两件套
#   (外加 local_server:三页的建房路径都走它,它挂了三个页面全进不去)。

const TARGETS := [
	"res://scenes/matchmaking.tscn",
	"res://scenes/royale_lobby.tscn",
	"res://scenes/team_lobby.tscn",
	"res://core/net/tunnel.gd",
	"res://core/config/tunnel_meta.gd",
	"res://core/net/local_server.gd",
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
