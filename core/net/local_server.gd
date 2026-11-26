class_name LocalServer
extends RefCounted

var _processes := OwnedProcessGroup.new()

func launch_and_connect() -> int:
	var port := NetBus.pick_free_port()
	if port == 0: return 0
	var args := PackedStringArray(["--headless"])
	if OS.has_feature("editor"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://"), "res://server/server_main.tscn"])
	args.append_array(["--", "--server", "--port", str(port)])
	var pid := _processes.launch(OS.get_executable_path(), args, false)
	if pid > 0 and await NetBus.connect_server("127.0.0.1", port, 10000, _processes.running.bind(pid)) == OK:
		print("[LocalServer] SERVER READY pid=%d port=%d" % [pid, port])
		return port
	return 0

func stop() -> void:
	_processes.stop_all()
