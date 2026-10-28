extends Node

func _ready() -> void:
	GameLog.use_role("server")
	var args := OS.get_cmdline_user_args()
	var port := NetBus.DEFAULT_PORT
	if args.has("--port"):
		port = int(args[args.find("--port") + 1])
	if args.has("--seed"):
		seed(int(args[args.find("--seed") + 1]))
	var err := NetBus.start_server(port)
	if err != OK:
		push_error("服务器绑定失败: %d" % err)
		get_tree().quit(1)
		return
	add_child(RoomSession.new())
	print("SERVER READY port=%d" % NetBus.server_port)
