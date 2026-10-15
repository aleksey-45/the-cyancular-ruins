extends Node

var generation := 0
var shutting_down := false
var _processes := OwnedProcessGroup.new()
var _tunnel_sample_at := 0
var _sampling_tunnel := false

func _ready() -> void:
	get_tree().auto_accept_quit = false

func launch(path: String, args: PackedStringArray, capture := false) -> int:
	if shutting_down: return -1
	var pid := _processes.launch(path, args, capture)
	if not capture or pid <= 0:
		GameLog.record("process_start", {"executable": path, "pid": pid, "capture": capture})
	return pid

func running(pid: int) -> bool:
	return _processes.running(pid)

func stop(pid: int) -> void:
	GameLog.record("process_stop", {"pid": pid})
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
	GameLog.record("session_close", {"generation": generation, "shutting_down": shutting_down}, true)
	generation += 1
	NetBus.stop()
	_processes.stop_all()
	Tunnel.reset()
	LocalServer.reset()

func _process(_delta: float) -> void:
	if not _sampling_tunnel and Tunnel.is_running() and Time.get_ticks_msec() - _tunnel_sample_at >= 5000:
		_sample_tunnel()

func _sample_tunnel() -> void:
	_sampling_tunnel = true
	_tunnel_sample_at = Time.get_ticks_msec()
	await Tunnel.log_peers()
	_sampling_tunnel = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		shutting_down = true
		get_tree().quit()

func _exit_tree() -> void:
	shutting_down = true
	close()
