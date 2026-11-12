extends Node

const ROOM_REPLIES := {
	NetEvent.Kind.LIST: [NetEvent.Kind.ROOM_LIST],
	NetEvent.Kind.CREATE: [NetEvent.Kind.ROOM, NetEvent.Kind.MESSAGE],
	NetEvent.Kind.JOIN: [NetEvent.Kind.ROOM, NetEvent.Kind.MESSAGE],
	NetEvent.Kind.REJOIN: [NetEvent.Kind.BASELINE, NetEvent.Kind.ROOM, NetEvent.Kind.REJOIN_DENIED],
}

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
		while not request.cancelled() and Time.get_ticks_msec() < deadline:
			var sample: Array = processes.poll(pid)
			output.append_array(sample[2])
			if not sample[0]: return [sample[1], output.get_string_from_utf8()]
			OS.delay_msec(2)
		processes.stop(pid)
		return [-1, "CLI 已取消" if request.cancelled() else "CLI 执行超时"]

func _ready() -> void:
	get_tree().auto_accept_quit = false
	_cli_worker.start()

func launch(path: String, args: PackedStringArray) -> int:
	return -1 if shutting_down else _processes.launch(path, args, false)

func running(pid: int) -> bool:
	return _processes.running(pid)

func stop(pid: int) -> void:
	_processes.stop(pid)

func execute(path: String, args: PackedStringArray) -> Array:
	if shutting_down: return [-1, "进程启动已取消"]
	var request := CliRequest.new()
	request.path = path
	request.args = args.duplicate()
	_cli_requests.append(request)
	_cli_worker.submit(request)
	while not request.done(): await get_tree().process_frame
	var result := request.result()
	_cli_requests.erase(request)
	return [-1, "CLI 已取消"] if request.cancelled() else result

func send_hello() -> void:
	if NetBus.can_send_to_server():
		NetBus.send_event(NetEvent.Kind.HELLO, {"name": PvpSession.player_name, "hue": Settings.pvp_color_hue})

func _lobby_port() -> int:
	var forward := Tunnel.forward_port()
	return forward if forward > 0 else NetBus.server_port

func list_rooms() -> String:
	return room_error(await _room_request(NetEvent.Kind.LIST, PvpSession.beta_mode, _lobby_port()))

func create_room(data: Dictionary) -> String:
	close()
	var port := await LocalServer.launch_and_connect()
	if port <= 0:
		return "创建房间失败，请检查日志"
	return room_error(await _room_request(NetEvent.Kind.CREATE, data, port))

func join_room(code: String) -> String:
	var port := _lobby_port() if Tunnel.on_network(code) and NetBus.can_send_to_server() else 0
	if port <= 0:
		var route := await Tunnel.start_client(code)
		if route.is_empty() or route.has("error"):
			return route.get("error", "")
		port = route["port"]
	return room_error(await _room_request(NetEvent.Kind.JOIN, {"code": code, "beta": PvpSession.beta_mode}, port))

func rejoin_room(retry := false) -> Error:
	var data := PvpSession.rejoin_payload()
	if data.is_empty():
		return ERR_INVALID_DATA
	if not retry:
		return await _room_request(NetEvent.Kind.REJOIN, data, _lobby_port(), 15000)
	var attempt := generation
	var deadline := Time.get_ticks_msec() + 60000
	var tunnel_code := Tunnel.current_code() if Tunnel.forward_port() > 0 else ""
	while attempt == generation and Time.get_ticks_msec() < deadline:
		NetBus.stop()
		var port := NetBus.server_port
		if not tunnel_code.is_empty():
			port = await Tunnel.refresh_forward(tunnel_code, deadline)
		if attempt != generation:
			return ERR_SKIP
		var remaining := deadline - Time.get_ticks_msec()
		if port > 0 and remaining > 0:
			var error := await _room_request(NetEvent.Kind.REJOIN, data, port, mini(5000, remaining))
			if error == OK or error == ERR_SKIP:
				return error
		await get_tree().create_timer(1.0).timeout
	if attempt != generation:
		return ERR_SKIP
	NetBus.stop()
	return ERR_TIMEOUT

func room_error(error: Error) -> String:
	match error:
		OK, ERR_SKIP: return ""
		ERR_INVALID_DATA: return "回局凭据已失效，请重新建房或加入"
		ERR_TIMEOUT: return "房间请求超时，请检查连接"
		ERR_CANT_CONNECT, ERR_CONNECTION_ERROR: return "无法连接房间，请创建房间或输入房间号加入"
		_: return "启动连接失败（%d）" % error

# 场景同步消费业务消息；这里仅等待本次请求对应的应答。
func _room_request(kind: int, data: Variant, port: int, timeout_ms := 8000) -> Error:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var error := await NetBus.connect_local(port, timeout_ms)
	if error != OK:
		return error
	var connection := NetBus.connection_generation
	var expected: Array = ROOM_REPLIES[kind]
	var replied := [false]
	var observe := func(_peer: int, reply: int, _data: Variant) -> void:
		if NetBus.connection_generation == connection and (reply in expected or reply == NetEvent.Kind.ROOM_CLOSED):
			replied[0] = true
	NetBus.event_received.connect(observe)
	if kind != NetEvent.Kind.REJOIN:
		send_hello()
	NetBus.send_event(kind, data)
	while not replied[0] and connection == NetBus.connection_generation and NetBus.can_send_to_server() \
			and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	NetBus.event_received.disconnect(observe)
	if replied[0]:
		return OK
	if connection != NetBus.connection_generation:
		return ERR_SKIP
	return ERR_TIMEOUT if NetBus.can_send_to_server() else ERR_CONNECTION_ERROR

func disconnect_client() -> void:
	generation += 1
	NetBus.stop()

func close() -> void:
	disconnect_client()
	for request: CliRequest in _cli_requests: request.cancel()
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
