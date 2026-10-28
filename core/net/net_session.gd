extends Node

var generation := 0
var shutting_down := false
var _processes := OwnedProcessGroup.new()
var _tunnel_sample_at := 0
var _sampling_tunnel := false
var _cli_worker := CliWorker.new()
var _cli_requests: Array = []

# CLI 的启动、管道读取和回收都由同一个常驻线程独占。
# OwnedProcessGroup 没有并发接口，不能把会话进程表跨线程共享。
class CliRequest extends RefCounted:
	var path: String
	var args: PackedStringArray
	var _mutex := Mutex.new()
	var _cancelled := false
	var _done := false
	var _result: Array = []

	func cancel() -> void:
		_mutex.lock()
		_cancelled = true
		_mutex.unlock()

	func cancelled() -> bool:
		_mutex.lock()
		var value := _cancelled
		_mutex.unlock()
		return value

	func finish(result: Array) -> void:
		_mutex.lock()
		_result = result
		_done = true
		_mutex.unlock()

	func done() -> bool:
		_mutex.lock()
		var value := _done
		_mutex.unlock()
		return value

	func result() -> Array:
		_mutex.lock()
		var value := _result
		_mutex.unlock()
		return value

class CliWorker extends RefCounted:
	var _thread := Thread.new()
	var _mutex := Mutex.new()
	var _wake := Semaphore.new()
	var _queue: Array = []
	var _stopping := false

	func start() -> void:
		var error := _thread.start(_run)
		if error != OK: push_error("CLI 工作线程启动失败: ", error)

	func submit(request: CliRequest) -> void:
		if not _thread.is_started():
			request.finish([-1, "CLI 工作线程不可用", {}])
			return
		_mutex.lock()
		_queue.append(request)
		_mutex.unlock()
		_wake.post()

	func close() -> void:
		if not _thread.is_started(): return
		_mutex.lock()
		_stopping = true
		_mutex.unlock()
		_wake.post()
		_thread.wait_to_finish()

	func _run() -> void:
		var processes := OwnedProcessGroup.new()
		while true:
			_wake.wait()
			_mutex.lock()
			var request: CliRequest = _queue.pop_front() if not _queue.is_empty() else null
			var stopping := _stopping
			_mutex.unlock()
			if request != null:
				if stopping: request.cancel()
				request.finish(_execute(processes, request))
			elif stopping:
				processes.stop_all()
				return

	func _execute(processes: OwnedProcessGroup, request: CliRequest) -> Array:
		if request.cancelled(): return [-1, "进程启动已取消", {}]
		var started := Time.get_ticks_usec()
		var pid := processes.launch(request.path, request.args, true)
		var launched := Time.get_ticks_usec()
		var timing := {"thread": "cli_worker", "path": request.path, "pid": pid,
				"start_us": started, "launch_end_us": launched, "launch_us": launched - started, "poll_max_us": 0}
		if pid <= 0: return [-1, "进程启动失败", timing]
		var output := PackedByteArray()
		var deadline := Time.get_ticks_msec() + 5000
		while true:
			var at := Time.get_ticks_usec()
			var sample: Array = processes.poll(pid)
			output.append_array(sample[2])
			timing["poll_max_us"] = maxi(timing["poll_max_us"], Time.get_ticks_usec() - at)
			if request.cancelled() or Time.get_ticks_msec() >= deadline:
				processes.stop(pid)
				return [-1, "CLI 已取消" if request.cancelled() else "CLI 执行超时", timing]
			if not sample[0]: return [sample[1], output.get_string_from_utf8(), timing]
			OS.delay_msec(2)
		return []

func _ready() -> void:
	get_tree().auto_accept_quit = false
	_cli_worker.start()

func launch(path: String, args: PackedStringArray, capture := false) -> int:
	if shutting_down: return -1
	var started := Time.get_ticks_usec() if FrameTrace.enabled else 0
	var pid := _processes.launch(path, args, capture)
	if FrameTrace.enabled:
		FrameTrace.span(&"cli_launch" if capture else &"process_launch", started, Time.get_ticks_usec())
		FrameTrace.event(&"process_start", {"pid": pid, "capture": capture, "path": path})
	if not capture or pid <= 0:
		GameLog.record("process_start", {"executable": path, "pid": pid, "capture": capture})
	return pid

func running(pid: int) -> bool:
	return _processes.running(pid)

func stop(pid: int) -> void:
	GameLog.record("process_stop", {"pid": pid})
	_processes.stop(pid)

func execute(path: String, args: PackedStringArray) -> Array:
	if shutting_down: return [-1, "进程启动已取消"]
	var started := Time.get_ticks_usec() if FrameTrace.enabled else 0
	var request := CliRequest.new()
	request.path = path
	request.args = args.duplicate()
	var token := generation
	_cli_requests.append(request)
	_cli_worker.submit(request)
	if FrameTrace.enabled: FrameTrace.span(&"cli_enqueue", started, Time.get_ticks_usec())
	while not request.done(): await get_tree().process_frame
	var result := request.result()
	_cli_requests.erase(request)
	if FrameTrace.enabled: FrameTrace.event(&"cli_result", result[2])
	return result.slice(0, 2) if token == generation else [-1, "CLI 已取消"]

func close() -> void:
	GameLog.record("session_close", {"generation": generation, "shutting_down": shutting_down}, true)
	generation += 1
	for request: CliRequest in _cli_requests: request.cancel()
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
	_cli_worker.close()
