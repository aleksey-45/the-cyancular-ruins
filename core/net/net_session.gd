extends Node

const ROOM_REPLIES := {
	NetEvent.Kind.CREATE: [NetEvent.Kind.ROOM, NetEvent.Kind.MESSAGE],
	NetEvent.Kind.JOIN: [NetEvent.Kind.ROOM, NetEvent.Kind.MESSAGE],
	NetEvent.Kind.REJOIN: [NetEvent.Kind.BASELINE, NetEvent.Kind.ROOM, NetEvent.Kind.REJOIN_DENIED],
}

var _room_ip := "127.0.0.1"
var _room_port := NetBus.DEFAULT_PORT
var _via_tunnel := false
var generation := 0
var shutting_down := false
var _processes := OwnedProcessGroup.new()
var _cli_worker := CliWorker.new()
var _cli_requests: Array = []
enum MatchMessage { STATE, TERRAIN, ROUND }
var match_inbox: Array = []

# 主线程提交 EasyTier 命令并等待结果。取消标记和执行结果由两个线程共享，通过互斥锁访问。
class CliRequest extends RefCounted:
	var path: String
	var args: PackedStringArray
	var _mutex := Mutex.new()
	var _cancelled := false
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
		_mutex.unlock()

	func result() -> Array:
		_mutex.lock()
		var value := _result
		_mutex.unlock()
		return value

# 执行 EasyTier 命令和读取输出都在后台线程进行，主线程可继续更新界面。
class CliWorker extends RefCounted:
	var _thread := Thread.new()
	var _mutex := Mutex.new()
	var _wake := Semaphore.new()
	var _queue: Array = []
	var _stopping := false

	func submit(request: CliRequest) -> void:
		if not _thread.is_started() and _thread.start(_run) != OK:
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
	NetBus.event_received.connect(_on_event)
	NetBus.state_received.connect(_on_state)

func _on_event(_peer: int, kind: int, data: Variant) -> void:
	match kind:
		NetEvent.Kind.ROOM:
			PvpSession.room = data
			_room_ip = NetBus.server_ip
			_room_port = NetBus.server_port
			_via_tunnel = _room_ip == "127.0.0.1" and Tunnel.on_network(data["code"]) and Tunnel.forward_port() == _room_port
			if not data["in_match"]: match_inbox.clear()
		NetEvent.Kind.REJOIN_DENIED: PvpSession.room.erase("token")
		NetEvent.Kind.ROOM_CLOSED: PvpSession.room = {}
		NetEvent.Kind.BASELINE: match_inbox.clear()
		NetEvent.Kind.ROUND:
			match_inbox.clear()
			match_inbox.append([MatchMessage.ROUND, data])
		NetEvent.Kind.TERRAIN:
			match_inbox.append([MatchMessage.TERRAIN, data])

func _on_state(frame: Dictionary) -> void:
	match_inbox.append([MatchMessage.STATE, frame])

func take_match_inbox() -> Array:
	var messages := match_inbox
	match_inbox = []
	return messages

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
	request.args = args
	_cli_requests.append(request)
	_cli_worker.submit(request)
	var result := request.result()
	while result.is_empty():
		await get_tree().process_frame
		result = request.result()
	_cli_requests.erase(request)
	return [-1, "CLI 已取消"] if request.cancelled() else result

func _lobby_port() -> int:
	var forward := Tunnel.forward_port()
	return forward if forward > 0 else NetBus.server_port

func create_room(data: Dictionary) -> String:
	close()
	var port := await LocalServer.launch_and_connect()
	if port <= 0:
		return "创建房间失败，请检查日志"
	return (await _room_request(NetEvent.Kind.CREATE, data, port)).message

func join_room(code: String, endpoint: Dictionary = {}) -> String:
	var payload := {"code": code, "beta": PvpSession.beta_mode}
	if not endpoint.is_empty():
		var error := await _room_request(NetEvent.Kind.JOIN, payload, endpoint["port"], 8000, endpoint["ip"])
		# 原请求仍有效且直连失败时，才尝试通过 EasyTier 隧道加入。
		if not error.retryable():
			return error.message
	var port := _lobby_port() if Tunnel.on_network(code) and NetBus.can_send_to_server() else 0
	if port <= 0:
		var route := await Tunnel.start_client(code)
		if route.is_empty() or route.has("error"):
			return route.get("error", "")
		port = route["port"]
	return (await _room_request(NetEvent.Kind.JOIN, payload, port)).message


func rejoin_room(retry := false) -> String:
	var data := PvpSession.rejoin_payload()
	if data.is_empty(): return "回局凭据已失效，请重新建房或加入"
	var attempt := generation
	var deadline := Time.get_ticks_msec() + (60000 if retry else 15000)
	while attempt == generation and Time.get_ticks_msec() < deadline:
		var port := _room_port
		if _via_tunnel and (retry or not Tunnel.on_network(data["code"])):
			port = await Tunnel.refresh_forward(data["code"], deadline)
		if generation != attempt: return ""
		var remaining := deadline - Time.get_ticks_msec()
		if port > 0 and remaining > 0:
			var reply := await _room_request(NetEvent.Kind.REJOIN, data, port, mini(5000, remaining) if retry else remaining, _room_ip)
			if generation != attempt: return ""
			if not retry or not reply.retryable(): return reply.message
		elif not retry:
			break
		NetBus.stop()
		await get_tree().create_timer(1.0).timeout
	return "" if attempt != generation else "房间请求超时，请检查连接"

class RoomReply:
	var status: Error
	var message: String

	func _init(error: Error, reason := "") -> void:
		status = error
		match error:
			ERR_TIMEOUT: message = "房间请求超时，请检查连接"
			ERR_CANT_CONNECT, ERR_CONNECTION_ERROR: message = "无法连接房间，请创建房间或输入房间号加入"
			OK, ERR_SKIP, ERR_UNAUTHORIZED: message = reason
			_: message = "启动连接失败（%d）" % error

	func retryable() -> bool:
		return status in [ERR_TIMEOUT, ERR_CANT_CONNECT, ERR_CONNECTION_ERROR]

func _room_request(kind: int, data: Dictionary, port: int, timeout_ms := 8000, host := "127.0.0.1") -> RoomReply:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var error := await NetBus.connect_server(host, port, timeout_ms)
	if error != OK: return RoomReply.new(error)
	var connection := NetBus.connection_generation
	var replies: Array[RoomReply] = []
	var observe := func(_peer: int, reply: int, payload: Variant) -> void:
		if NetBus.connection_generation != connection: return
		if reply == NetEvent.Kind.ROOM_CLOSED or reply in ROOM_REPLIES[kind]:
			if reply in [NetEvent.Kind.MESSAGE, NetEvent.Kind.REJOIN_DENIED, NetEvent.Kind.ROOM_CLOSED]:
				replies.append(RoomReply.new(ERR_UNAUTHORIZED, payload))
			else:
				_room_ip = host
				_room_port = port
				replies.append(RoomReply.new(OK))
	NetBus.event_received.connect(observe)
	if kind in [NetEvent.Kind.CREATE, NetEvent.Kind.JOIN]:
		data = data.merged({"name": PvpSession.player_name, "hue": Settings.pvp_color_hue})
	NetBus.send_event(kind, data)
	while replies.is_empty() and connection == NetBus.connection_generation and NetBus.can_send_to_server() \
			and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	NetBus.event_received.disconnect(observe)
	if not replies.is_empty(): return replies[0]
	if connection != NetBus.connection_generation: return RoomReply.new(ERR_SKIP)
	return RoomReply.new(ERR_TIMEOUT if NetBus.can_send_to_server() else ERR_CONNECTION_ERROR)

func disconnect_client() -> void:
	generation += 1
	match_inbox.clear()
	NetBus.stop()

func close() -> void:
	disconnect_client()
	for request: CliRequest in _cli_requests: request.cancel()
	_processes.stop_all()
	Tunnel.reset()
	LocalServer.reset()

func _exit_tree() -> void:
	shutting_down = true
	close()
	_cli_worker.close()
