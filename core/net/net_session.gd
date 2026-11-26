extends Node

signal nearby_changed(rooms: Array[RoomSummary])
signal room_changed(room: Dictionary)
signal room_closed(reason: String)
signal connection_lost
signal notice(message: String)
signal match_baseline(data: Dictionary)

const REPLIES := {
	NetEvent.Kind.CREATE: [NetEvent.Kind.ROOM, NetEvent.Kind.MESSAGE],
	NetEvent.Kind.JOIN: [NetEvent.Kind.ROOM, NetEvent.Kind.MESSAGE],
	NetEvent.Kind.REJOIN: [NetEvent.Kind.ROOM, NetEvent.Kind.BASELINE, NetEvent.Kind.REJOIN_DENIED],
	NetEvent.Kind.LEAVE: [NetEvent.Kind.ROOM_CLOSED],
}
const CONNECT_MS := 8000
enum MatchMessage { STATE, TERRAIN, ROUND }

class Reply:
	var kind: int
	var status := ERR_BUSY
	var message := ""

var room: Dictionary = {}
var match_inbox: Array = []
var _token := ""
var _room_connection := -1
var _direct: Dictionary = {}
var _tunneled := false
var _generation := 0
var _pending: Reply
var _discovery := LanDiscovery.new()
var _poll := Timer.new()
var _server := LocalServer.new()
var _tunnel := Tunnel.new()

func _ready() -> void:
	add_child(_poll)
	_poll.wait_time = 0.1
	_poll.timeout.connect(func() -> void:
		if _discovery.poll(Time.get_ticks_msec() / 1000.0): nearby_changed.emit(_discovery.rooms()))
	NetBus.event_received.connect(_on_event)
	NetBus.state_received.connect(_on_state)
	NetBus.server_disconnected.connect(connection_lost.emit)
	NetBus.protocol_error.connect(_end_room)

func set_browsing(enabled: bool) -> void:
	if enabled == (not _poll.is_stopped()): return
	if enabled:
		if _discovery.listen() == OK: _poll.start()
	else:
		_poll.stop()
		_discovery.stop()

func _on_event(_peer: int, kind: int, data: Variant) -> void:
	if _pending != null and _pending.status == ERR_BUSY and (kind in REPLIES[_pending.kind] or kind == NetEvent.Kind.ROOM_CLOSED):
		var refused := kind in [NetEvent.Kind.MESSAGE, NetEvent.Kind.REJOIN_DENIED] or (
				kind == NetEvent.Kind.ROOM_CLOSED and _pending.kind != NetEvent.Kind.LEAVE)
		_pending.status = ERR_UNAUTHORIZED if refused else OK
		if refused: _pending.message = data
	match kind:
		NetEvent.Kind.ROOM:
			_room_connection = NetBus.connection_generation
			room = data.duplicate()
			_token = room.token
			room.erase("token")
			if not room.in_match: match_inbox.clear()
			set_browsing(false)
			room_changed.emit(room)
		NetEvent.Kind.MESSAGE:
			if _pending == null: notice.emit(data)
		NetEvent.Kind.REJOIN_DENIED:
			_token = ""
		NetEvent.Kind.ROOM_CLOSED:
			_end_room(data)
		NetEvent.Kind.BASELINE:
			_room_connection = NetBus.connection_generation
			room.in_match = true
			set_browsing(false)
			match_inbox.clear()
			match_baseline.emit(data)
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

func connected() -> bool:
	return _room_connection == NetBus.connection_generation and NetBus.can_send_to_server()

func can_rejoin() -> bool:
	return not _token.is_empty() and not connected()

func create_room(mode: String, rules: Dictionary, listed_nearby: bool) -> String:
	close()
	var attempt := _generation
	var port := await _server.launch_and_connect()
	if attempt != _generation: return ""
	if port == 0:
		close()
		return "创建房间失败，请检查日志"
	_direct = {"ip": "127.0.0.1", "port": port}
	var reply := await _request(NetEvent.Kind.CREATE, {"mode": mode, "options": rules, "listed_nearby": listed_nearby})
	if attempt == _generation:
		if reply.status != OK:
			close()
		else:
			var problem := _tunnel.start_host(port, room.code)
			if not problem.is_empty(): notice.emit("房间 %s 已创建，远程入口不可用。%s" % [room.code, problem])
	return reply.message

func join_room(code: String) -> String:
	if not RoomSummary.valid_code(code): return "房间码是 8 位数字（例 00048213）"
	close()
	var attempt := _generation
	var error := await _connect_room(code, Time.get_ticks_msec() + 60000, false)
	if attempt != _generation: return ""
	if error.is_empty():
		var reply := await _request(NetEvent.Kind.JOIN, {"code": code, "beta": PvpSession.beta_mode})
		error = reply.message
	if attempt == _generation and not error.is_empty(): close()
	return error

func rejoin_room() -> String:
	if _token.is_empty(): return "回局凭据已失效"
	_cancel_attempt()
	var attempt := _generation
	var deadline := Time.get_ticks_msec() + RoomOptions.REJOIN_SECONDS * 1000
	var was_browsing := not _poll.is_stopped()
	var host: bool = room.your_role == room.host_role
	if not host: set_browsing(true)
	var data := {"code": room.code, "token": _token}
	while Time.get_ticks_msec() < deadline:
		var error := await _connect_room(data.code, deadline, true)
		if attempt != _generation: return ""
		if error.is_empty():
			var reply := await _request(NetEvent.Kind.REJOIN, data, deadline)
			if reply.status == ERR_UNAUTHORIZED and attempt == _generation:
				close()
				if not was_browsing: set_browsing(false)
			if reply.status != ERR_TIMEOUT or attempt != _generation: return reply.message
			NetBus.stop()
		await get_tree().create_timer(0.5).timeout
		if attempt != _generation: return ""
	if not was_browsing: set_browsing(false)
	return "重连房间超时"

# 先接通路径，业务请求只在选好的连接上发送。房主始终使用自己的游戏服务器。
func _connect_room(code: String, deadline: int, resume: bool) -> String:
	var attempt := _generation
	var host: bool = resume and room.your_role == room.host_role
	var paths := [false] if host else [false, true]
	if _tunneled: paths.reverse()
	var problem := "无法连接房间"
	for via_tunnel: bool in paths:
		var endpoint: Dictionary
		if via_tunnel:
			var until := mini(deadline, Time.get_ticks_msec() + CONNECT_MS) if resume else deadline
			var route := await _tunnel.start_client(code, until)
			if attempt != _generation: return ""
			if route.has("error"):
				problem = route.error
				continue
			endpoint = {"ip": "127.0.0.1", "port": route.port}
		else:
			endpoint = {} if host else _discovery.endpoint(code, Time.get_ticks_msec() / 1000.0)
			if endpoint.is_empty(): endpoint = _direct
			if endpoint.is_empty(): continue
		var remaining := mini(CONNECT_MS, deadline - Time.get_ticks_msec())
		if remaining <= 0: break
		var status := await _connect_endpoint(endpoint, remaining)
		if attempt != _generation: return ""
		if status == OK:
			_tunneled = via_tunnel
			if not via_tunnel:
				_direct = endpoint
				if not host: _tunnel.stop()
			return ""
		if via_tunnel: _tunnel.stop()
	return problem

func _connect_endpoint(endpoint: Dictionary, timeout_ms: int) -> Error:
	return await NetBus.connect_server(endpoint.ip, endpoint.port, timeout_ms)

func _request(kind: int, data: Variant, end_ms := 0) -> Reply:
	var reply := Reply.new()
	reply.kind = kind
	_pending = reply
	if kind in [NetEvent.Kind.CREATE, NetEvent.Kind.JOIN]:
		data = data.merged({"name": PvpSession.player_name, "hue": Settings.pvp_color_hue})
	var deadline := Time.get_ticks_msec() + CONNECT_MS
	if end_ms > 0: deadline = mini(deadline, end_ms)
	NetBus.send_event(kind, data)
	while _pending == reply and reply.status == ERR_BUSY and NetBus.can_send_to_server() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _pending == reply:
		_pending = null
		if reply.status == ERR_BUSY:
			reply.status = ERR_TIMEOUT
			reply.message = "入房结果未确认" if kind == NetEvent.Kind.JOIN else "房间请求未收到确认"
	elif reply.status == ERR_BUSY:
		reply.status = ERR_SKIP
	return reply

func pick_team(side: int) -> void:
	NetBus.send_event(NetEvent.Kind.PICK_TEAM, side)

func start_match() -> void:
	NetBus.send_event(NetEvent.Kind.START)

func return_to_room() -> void:
	NetBus.send_event(NetEvent.Kind.RETURN_TO_ROOM)

func leave_room() -> void:
	if _pending != null and _pending.kind == NetEvent.Kind.LEAVE: return
	var attempt := _generation
	if connected(): await _request(NetEvent.Kind.LEAVE, null)
	if attempt == _generation: _end_room("已退出房间")

func _end_room(reason: String) -> void:
	set_browsing(false)
	if _pending != null and _pending.status == ERR_BUSY:
		_pending.status = ERR_CONNECTION_ERROR
		_pending.message = reason
	close()
	room_closed.emit(reason)

func disconnect_client() -> void:
	set_browsing(false)
	_cancel_attempt()
	if not room.is_empty() and room.your_role != room.host_role: _tunnel.stop()

func _cancel_attempt() -> void:
	_generation += 1
	_pending = null
	match_inbox.clear()
	NetBus.stop()

func close() -> void:
	_cancel_attempt()
	room = {}
	_token = ""
	_direct = {}
	_tunneled = false
	_tunnel.stop()
	_server.stop()

func _exit_tree() -> void:
	close()
