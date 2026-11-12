class_name LocalServer
extends RefCounted

const PROBE_TIMEOUT_MS := 10000
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
	var generation := NetSession.generation
	_owned_pid = NetSession.launch(exe, args)
	var ready := _owned_pid > 0 and await NetBus.connect_local(port, PROBE_TIMEOUT_MS, NetSession.running.bind(_owned_pid)) == OK
	if generation != NetSession.generation:
		return -1
	if ready:
		print("[LocalServer] SERVER READY pid=%d port=%d" % [_owned_pid, port])
		return port
	stop_owned()
	push_error("本地服务端启动失败")
	return -1

static func stop_owned() -> void:
	if _owned_pid > 0:
		NetSession.stop(_owned_pid)
	reset()

static func reset() -> void:
	_owned_pid = 0
