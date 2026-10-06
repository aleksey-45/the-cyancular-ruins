extends Node
# 冒烟用无头客户端:按命令行参数扮演建房/加入,断言关键流程后退出。
# 用法: godot --headless --path . Tests/pvp_smoke_client.tscn -- --role create
#       godot --headless --path . Tests/pvp_smoke_client.tscn -- --role join --code 0000
# 流程:连大厅(7777)建房/加入 → 大厅配对后发 go_match → 转连该局 worker 并 claim_role → 等 match_start。

var role: String = ""
var code: String = ""

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		match args[i]:
			"--role": role = args[i + 1]
			"--code": code = args[i + 1]
	if role.is_empty():
		printerr("SMOKE_CLIENT FAIL: 缺 --role")
		get_tree().quit(1)
		return
	NetBus.local_server_message.connect(func(t: String) -> void: print("[server] " + t))
	NetBus.local_room_created.connect(func(c: String) -> void:
		print("ROOM_CODE=" + c)
		print("SMOKE_CLIENT OK: 建房拿号"))
	NetBus.local_room_joined.connect(func(r: int) -> void:
		print("SMOKE_CLIENT OK: 加入成功 role=%d" % r))
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_go_match.connect(_on_go_match)
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		printerr("SMOKE_CLIENT FAIL: 连接大厅失败")
		get_tree().quit(1))
	var err := NetBus.start_client("127.0.0.1")
	if err != OK:
		printerr("SMOKE_CLIENT FAIL: start_client %d" % err)
		get_tree().quit(1)

func _on_connected() -> void:
	match role:
		"create":
			NetBus.rpc_id(1, "create_room")
		"join":
			NetBus.rpc_id(1, "join_room", code)
		_:
			printerr("SMOKE_CLIENT FAIL: 非法 role %s" % role)
			get_tree().quit(1)

# 大厅配对完成:断大厅 → 转连对局 worker → claim 角色
func _on_go_match(role_assign: int, port: int) -> void:
	print("SMOKE_CLIENT OK: go_match role=%d port=%d" % [role_assign, port])
	multiplayer.connected_to_server.connect(_claim_worker.bind(role_assign), CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		printerr("SMOKE_CLIENT FAIL: 连接对局 worker 失败")
		get_tree().quit(1), CONNECT_ONE_SHOT)
	NetBus.stop()
	var err := NetBus.start_client("127.0.0.1", port)
	if err != OK:
		printerr("SMOKE_CLIENT FAIL: start_client(worker) %d" % err)
		get_tree().quit(1)

func _claim_worker(role_assign: int) -> void:
	print("SMOKE_CLIENT OK: claim role=%d" % role_assign)
	NetBus.rpc_id(1, "claim_role", role_assign, PvpSession.player_name)

func _on_match_start(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	print("SMOKE_CLIENT OK: match_start")
	get_tree().quit(0)
