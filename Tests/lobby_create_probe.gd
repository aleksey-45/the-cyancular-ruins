extends Node

# 大厅建房协议探针(场景模式,autoload 可用):
# 连服务器 → create_room → 等 room_created → 列房间列表。验证当前客户端与大厅的完整交互。
# 用法: Godot_console --headless --path . res://Tests/lobby_create_probe.tscn [-- 服务器IP]

var _addr := "120.53.107.140"

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			_addr = a
	print("PROBE: 目标大厅 %s:7777" % _addr)
	NetBus.local_room_created.connect(func(code: String) -> void:
		print("PROBE: 建房成功!房间号 = %s(当前客户端协议与大厅完全兼容)" % code)
		NetBus.rpc_id(1, "list_rooms"))
	NetBus.local_room_list.connect(func(rooms: Array) -> void:
		print("PROBE: 房间列表 %d 条: %s" % [rooms.size(), str(rooms)])
		print("PROBE: DONE")
		get_tree().quit(0))
	multiplayer.connected_to_server.connect(func() -> void:
		if "--list" in OS.get_cmdline_user_args():
			print("PROBE: 已连上大厅,发送 list_rooms…")
			NetBus.rpc_id(1, "list_rooms")
		else:
			print("PROBE: 已连上大厅,发送 create_room…")
			NetBus.rpc_id(1, "create_room"))
	multiplayer.connection_failed.connect(func() -> void:
		print("PROBE: 连接失败")
		get_tree().quit(1))
	var err := NetBus.start_client(_addr)
	if err != OK:
		print("PROBE: start_client 失败 err=", err)
		get_tree().quit(1)
		return
	await get_tree().create_timer(10.0).timeout
	print("PROBE: 10 秒无响应(超时)")
	get_tree().quit(1)
