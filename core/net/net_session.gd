extends Node

var generation := 0
var shutting_down := false
var _processes := OwnedProcessGroup.new()
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
			request.finish([-1, "CLI 工作线程不可用"])
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
		if request.cancelled(): return [-1, "进程启动已取消"]
		var pid := processes.launch(request.path, request.args, true)
		if pid <= 0: return [-1, "进程启动失败"]
		var output := PackedByteArray()
		var deadline := Time.get_ticks_msec() + 5000
		while true:
			var sample: Array = processes.poll(pid)
			output.append_array(sample[2])
			if request.cancelled() or Time.get_ticks_msec() >= deadline:
				processes.stop(pid)
				return [-1, "CLI 已取消" if request.cancelled() else "CLI 执行超时"]
			if not sample[0]: return [sample[1], output.get_string_from_utf8()]
			OS.delay_msec(2)
		return []

func _ready() -> void:
	get_tree().auto_accept_quit = false
	_cli_worker.start()

func launch(path: String, args: PackedStringArray, capture := false) -> int:
	if shutting_down: return -1
	var pid := _processes.launch(path, args, capture)
	return pid

func running(pid: int) -> bool:
	return _processes.running(pid)

func stop(pid: int) -> void:
	_processes.stop(pid)

func execute(path: String, args: PackedStringArray) -> Array:
	if shutting_down: return [-1, "进程启动已取消"]
	var request := CliRequest.new()
	request.path = path
	request.args = args.duplicate()
	var token := generation
	_cli_requests.append(request)
	_cli_worker.submit(request)
	while not request.done(): await get_tree().process_frame
	var result := request.result()
	_cli_requests.erase(request)
	return result if token == generation else [-1, "CLI 已取消"]

func close() -> void:
	generation += 1
	for request: CliRequest in _cli_requests: request.cancel()
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
	_cli_worker.close()
