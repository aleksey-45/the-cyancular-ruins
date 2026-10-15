class_name LocalServer
extends RefCounted

const SERVER_EXE := "Cyancular Ruins Server.exe"
const PROBE_TIMEOUT := 10.0
static var restarting := false
static var _owned_pid := 0

# 向系统要一个 UDP 端口，关闭探测 socket 后交给实际服务端。
static func _pick_free_port() -> int:
	var probe := PacketPeerUDP.new()
	if probe.bind(0, "127.0.0.1") != OK:
		return 0
	var port := probe.get_local_port()
	probe.close()
	return port

static func find_server_exe() -> String:
	if OS.has_feature("editor") or OS.has_feature("macos"):
		return OS.get_executable_path()
	var path := OS.get_executable_path().get_base_dir().path_join(SERVER_EXE)
	return path if FileAccess.file_exists(path) else ""

static func launch_and_connect() -> int:
	var started := Time.get_ticks_msec()
	stop_owned()
	var exe := find_server_exe()
	if exe.is_empty():
		push_error("请把 %s 和客户端放在同一目录" % SERVER_EXE)
		return -1
	var port := _pick_free_port()
	if port == 0:
		return -1
	var args := PackedStringArray()
	if OS.has_feature("editor"):
		args.append_array(["--headless", "--path", ProjectSettings.globalize_path("res://"), "res://server/server_main.tscn"])
	elif OS.has_feature("macos"):
		args.append("--headless")
	args.append("--")
	if OS.has_feature("macos") and OS.has_feature("template"):
		args.append("--server")
	args.append_array(["--port", str(port)])
	args.append_array(["--game-log-dir", GameLog.log_dir()])
	restarting = true
	var generation := NetSession.generation
	_owned_pid = NetSession.launch(exe, args)
	PvpSession.server_address = "127.0.0.1"
	PvpSession.server_port = port
	var ready := _owned_pid > 0 and await _probe(_owned_pid, port)
	if generation != NetSession.generation:
		return -1
	restarting = false
	if ready:
		GameLog.record("local_server_ready", {"pid": _owned_pid, "port": port, "duration_ms": Time.get_ticks_msec() - started})
		print("[LocalServer] SERVER READY pid=%d port=%d" % [_owned_pid, port])
		return port
	NetBus.stop()
	stop_owned()
	push_error("本地服务端启动失败")
	return -1

static func _probe(pid: int, port: int) -> bool:
	if NetBus.start_client("127.0.0.1", port) != OK:
		return false
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(PROBE_TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline and NetSession.running(pid):
		if NetBus.can_send_to_server():
			return true
		await tree.create_timer(0.05).timeout
	return false

static func is_owned_running() -> bool:
	return _owned_pid > 0 and NetSession.running(_owned_pid)

static func stop_owned() -> void:
	if _owned_pid > 0:
		NetSession.stop(_owned_pid)
	reset()

static func reset() -> void:
	_owned_pid = 0
	restarting = false
