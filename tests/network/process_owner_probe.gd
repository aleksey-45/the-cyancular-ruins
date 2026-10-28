extends Node
const Tunnel := preload("res://core/net/tunnel.gd")
var output := ""
var mode := ""
var cli_finished := false
var cli_result: Array = []

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	output = args[args.find("--output") + 1]
	mode = args[args.find("--mode") + 1]
	if mode == "echo":
		print("ARGUMENT_CAPTURE " + JSON.stringify(args.slice(args.find("--echo") + 1)))
		print("管道内容".repeat(6000))
		get_tree().quit(7)
		return
	if mode == "hang":
		_write({"cli": OS.get_process_id()})
		return
	if mode == "descendant":
		assert(Tunnel.available())
		var pid := NetSession.launch(Tunnel.core_exe(), _core_args()) if OS.has_feature("macos") else OS.create_process(Tunnel.core_exe(), _core_args())
		assert(pid > 0)
		_write({"descendant": pid})
		return
	_run.call_deferred()

func _child_args(child_mode: String, file: String) -> PackedStringArray:
	return PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"res://tests/network/process_owner_probe.tscn", "--", "--mode", child_mode, "--output", file])

func _core_args() -> PackedStringArray:
	var rpc := TCPServer.new()
	assert(rpc.listen(0, "127.0.0.1") == OK)
	var rpc_port := rpc.get_local_port()
	rpc.stop()
	var udp := PacketPeerUDP.new()
	assert(udp.bind(0, "127.0.0.1") == OK)
	var udp_port := udp.get_local_port()
	udp.close()
	return PackedStringArray(["--no-tun", "--network-name", "cyr-owner-test", "--network-secret", "owner-test",
			"--listeners", "udp://127.0.0.1:%d" % udp_port, "--rpc-portal", "127.0.0.1:%d" % rpc_port])

func _write(data: Dictionary) -> void:
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _boot() -> void:
	assert(await LocalServer.launch_and_connect() > 0)

func _cli() -> void:
	cli_result = await NetSession.execute(OS.get_executable_path(), _child_args("hang", output + ".cli"))
	cli_finished = true

func _capture_arguments() -> void:
	var values := PackedStringArray(["", "空 格", "a\"b", "尾部\\", "\\\"混合"])
	var args := _child_args("echo", output + ".echo")
	args.append("--echo")
	args.append_array(values)
	var capture: Array = await NetSession.execute(OS.get_executable_path(), args)
	assert(capture[0] == 7 and capture[1].contains("ARGUMENT_CAPTURE " + JSON.stringify(values)))
	assert(capture[1].contains("管道内容".repeat(6000)))

func _run() -> void:
	if mode not in ["startup", "leave"]:
		await _capture_arguments()
	_boot.call_deferred()
	await get_tree().process_frame
	assert(Tunnel.available())
	Tunnel._pid = NetSession.launch(Tunnel.core_exe(), _core_args())
	assert(Tunnel._pid > 0)
	# 离房场景让 CLI 进程组后创建，覆盖守护进程继承寿命管道的顺序。
	if mode == "leave":
		await _capture_arguments()
	if mode != "startup":
		while not NetBus.can_send_to_server(): await get_tree().process_frame
		var child := NetSession.launch(OS.get_executable_path(), _child_args("descendant", output + ".child"))
		assert(child > 0)
		while not FileAccess.file_exists(output + ".child"): await get_tree().process_frame
		if mode != "transition":
			_cli.call_deferred()
			while not FileAccess.file_exists(output + ".cli"): await get_tree().process_frame
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output + ".child"))
		data["child"] = child
		if mode != "transition": data.merge(JSON.parse_string(FileAccess.get_file_as_string(output + ".cli")))
		data.merge({"client": OS.get_process_id(), "server": LocalServer._owned_pid, "easytier": Tunnel._pid})
		_write(data)
	else:
		_write({"client": OS.get_process_id(), "server": LocalServer._owned_pid, "easytier": Tunnel._pid})
	print("PROCESS OWNER READY ", mode)
	if mode in ["forced", "startup"]: return
	await get_tree().create_timer(1.5).timeout
	if mode == "transition":
		get_tree().change_scene_to_file("res://tests/network/process_owner_followup.tscn")
		return
	if mode == "leave":
		NetSession.close()
		var deadline := Time.get_ticks_msec() + 2000
		while not cli_finished and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		if not cli_finished or cli_result.is_empty() or cli_result[0] != -1:
			push_error("CLI 取消失败: finished=%s result=%s" % [cli_finished, cli_result])
			get_tree().quit(1)
			return
		assert(await LocalServer.launch_and_connect() > 0)
		NetSession.close()
		print("PROCESS SESSION REOPEN OK")
	elif mode == "window":
		get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
		return
	print("PROCESS OWNER QUIT ", mode)
	get_tree().quit()
