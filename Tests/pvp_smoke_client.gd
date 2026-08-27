extends Node
# 冒烟用无头客户端:按命令行参数扮演建房/加入,断言关键流程后退出。
# 用法: godot --headless --path . Tests/pvp_smoke_client.tscn -- --role create
#       godot --headless --path . Tests/pvp_smoke_client.tscn -- --role join --code 0000

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
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		printerr("SMOKE_CLIENT FAIL: 连接失败")
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

func _on_match_start(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	print("SMOKE_CLIENT OK: match_start")
	get_tree().quit(0)
