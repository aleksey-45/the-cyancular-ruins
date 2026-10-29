class_name LocalServer
extends RefCounted

const PROBE_TIMEOUT := 10.0
static var restarting := false
static var _owned_pid := 0

static func launch_and_connect() -> int:
	stop_owned()
	var exe := OS.get_executable_path()
	var port := NetBus.pick_free_port()
	if port == 0:
		return -1
	var args := PackedStringArray(["--headless"])
	if OS.has_feature("editor"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://"), "res://server/server_main.tscn"])
	args.append_array(["--", "--server"])
	args.append_array(["--port", str(port)])
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

static func stop_owned() -> void:
	if _owned_pid > 0:
		NetSession.stop(_owned_pid)
	reset()

static func reset() -> void:
	_owned_pid = 0
	restarting = false
