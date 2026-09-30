extends Node
# 冒烟用无头客户端:按命令行参数扮演建房/加入,断言关键流程后退出。
# 用法: godot --headless --path . Tests/pvp_smoke_client.tscn -- --role create
#       godot --headless --path . Tests/pvp_smoke_client.tscn -- --role join --code 48213
#       godot --headless --path . Tests/pvp_smoke_client.tscn -- --role join --code 48213 --port 24117
# 流程:连服务端(默认 7777)→ 建房/加入 → 配对后收 go_match → **在既有的那条连接上** claim_role →
#       等 match_start。
# ★ 2026-09-29:服务端已是**单进程单端口**,`go_match` 带的端口就是客户端此刻连着的那个 ——
#   这里**不再**断开重连(重连会换一个 peer id,服务端房里的 `players` 立刻对不上,
#   那个 peer 会被当掉线处理)。生产侧同一处改动见 `scenes/lobby_page.gd::_do_go_match`。
# ★ `--port` 是给**隧道联调**用的:客机连的是本机那个 `port-forward` 的绑定端口(≠ 房主端口),
#   于是"穿过隧道进房间"这件事可以在**一台机器**上端到端地验一遍(见 docs/netplay.md §8.2)。

var role: String = ""
var code: String = ""
var port: int = NetBus.DEFAULT_PORT

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		match args[i]:
			"--role": role = args[i + 1]
			"--code": code = args[i + 1]
			"--port": port = int(args[i + 1])
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
		printerr("SMOKE_CLIENT FAIL: 连接服务端失败")
		get_tree().quit(1))
	print("SMOKE_CLIENT: 连 127.0.0.1:%d(role=%s)" % [port, role])
	var err := NetBus.start_client("127.0.0.1", port)
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

# 配对完成:**连接不动**,直接 claim 角色(与生产同路)
func _on_go_match(role_assign: int, port: int) -> void:
	print("SMOKE_CLIENT OK: go_match role=%d port=%d(连接不动)" % [role_assign, port])
	NetBus.rpc_id(1, "claim_role", role_assign, PvpSession.player_name)

func _on_match_start(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	print("SMOKE_CLIENT OK: match_start")
	get_tree().quit(0)
