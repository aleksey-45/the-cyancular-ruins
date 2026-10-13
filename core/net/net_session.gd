extends Node

var generation := 0
var shutting_down := false
var _processes := OwnedProcessGroup.new()

func _ready() -> void:
	get_tree().auto_accept_quit = false

func launch(path: String, args: PackedStringArray, capture := false) -> int:
	if shutting_down: return -1
	return _processes.launch(path, args, capture)

func running(pid: int) -> bool:
	return _processes.running(pid)

func stop(pid: int) -> void:
	_processes.stop(pid)

func execute(path: String, args: PackedStringArray) -> Array:
	var pid := launch(path, args, true)
	if pid <= 0: return [-1, "进程启动已取消"]
	var output := PackedByteArray()
	var deadline := Time.get_ticks_msec() + 5000
	while true:
		var sample: Array = _processes.poll(pid)
		output.append_array(sample[2])
		if not sample[0]: return [sample[1], output.get_string_from_utf8()]
		if Time.get_ticks_msec() >= deadline:
			stop(pid)
			return [-1, "CLI 执行超时"]
		await get_tree().process_frame
	return []

func close() -> void:
	generation += 1
	NetBus.stop()
	_processes.stop_all()
	Tunnel.reset()
	LocalServer.reset()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		shutting_down = true
		get_tree().quit()

func _exit_tree() -> void:
	shutting_down = true
	close()
