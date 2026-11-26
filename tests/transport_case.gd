extends "res://tests/case.gd"

class UnavailableTunnel extends Tunnel:
	var publications := 0
	var lookups := 0
	func start_host(_port: int, _code: String) -> String:
		publications += 1
		return "test relay unavailable"

	func start_client(_code: String, _deadline: int) -> Dictionary:
		lookups += 1
		return {"error": "unexpected tunnel lookup"}

const CLIENT_COUNT := RoomOptions.ROYALE_PLAYERS.y
const INPUT := 0
const STATE := 1
const EVENT := 2
var _server := GnsEndpoint.new()
var _clients: Array[GnsEndpoint] = []
var _joined := PackedInt32Array()
var _server_messages: Array = []
var _inboxes: Array = []
var _poll_limit := 256
var _within_limit := true
var _client_peers := PackedInt32Array()
var _connection_errors: Array = []

func run(tree: SceneTree) -> void:
	await _host_room()
	await _unconfirmed_join(tree)
	var oversized := PackedByteArray()
	oversized.resize(64 * 1024 * 1024 + 1)
	for flow in [INPUT, STATE, EVENT]:
		expect(_server.send(1, flow, oversized) == ERR_INVALID_PARAMETER, "transport rejects an oversized payload")
	oversized.clear()
	var probe := PacketPeerUDP.new()
	expect(probe.bind(0, "127.0.0.1") == OK, "reserve a dynamic port")
	var port := probe.get_local_port()
	probe.close()
	expect(_server.listen(port) == OK and _server.get_port() == port, "dynamic listener")
	for i in CLIENT_COUNT:
		var client := GnsEndpoint.new()
		_clients.append(client)
		_inboxes.append([])
		expect(client.connect_to("127.0.0.1", _server.get_port()) == OK, "connect client %d" % i)
	if not _until(func() -> bool: return _joined.size() == CLIENT_COUNT and _clients.all(func(client: GnsEndpoint) -> bool: return client.is_connected()), 5000):
		expect(false, "full Royale roster connects: joined=%d connected=%d errors=%s" % [_joined.size(), _clients.filter(func(client: GnsEndpoint) -> bool: return client.is_connected()).size(), _connection_errors])
		return
	expect(_joined.size() == CLIENT_COUNT, "full Royale roster accepted")
	for i in CLIENT_COUNT: _clients[i].send(1, EVENT, PackedByteArray([i]))
	if not _until(func() -> bool: return _server_messages.size() == CLIENT_COUNT):
		expect(false, "client identity messages arrive")
		return
	_client_peers.resize(CLIENT_COUNT)
	for message: Array in _server_messages: _client_peers[message[2][0]] = message[1]
	_server_messages.clear()
	_broadcast_and_order()
	_large_frames()
	_reopen_with_pending_data()
	expect(_within_limit, "poll never expands beyond its logical message limit")

func _host_room() -> void:
	var real_tunnel := NetSession._tunnel
	var unavailable := UnavailableTunnel.new()
	NetSession._tunnel = unavailable
	var notices := []
	var observe := func(value: String) -> void: notices.append(value)
	NetSession.notice.connect(observe)
	var problem := await NetSession.create_room(WorldSpec.DUEL, {}, false)
	expect(problem.is_empty() and NetSession.connected() and NetSession.room.your_role == 1,
			"hosting retains the seat when the remote entrance fails: %s" % problem)
	if NetSession.connected():
		var roster := NetSession.room.merged({"token": NetSession._token})
		NetSession._on_event(1, NetEvent.Kind.ROOM, roster)
		NetSession._on_event(1, NetEvent.Kind.ROOM, roster)
		await NetSession.leave_room()
	expect(unavailable.publications == 1 and notices.any(func(value: String) -> bool: return "test relay unavailable" in value),
			"the host publishes once and reports the separate failure")
	expect(NetSession.room.is_empty() and not NetSession.can_rejoin(), "leaving clears the admitted seat")
	NetSession.notice.disconnect(observe)
	NetSession.close()
	NetSession._tunnel = real_tunnel

func _unconfirmed_join(tree: SceneTree) -> void:
	var server := GnsEndpoint.new()
	var port := NetBus.pick_free_port()
	if server.listen(port) != OK:
		expect(false, "the admission fixture opens a local server")
		return
	var original := NetSession._tunnel
	var tunnel := UnavailableTunnel.new()
	NetSession._tunnel = tunnel
	var code := "00048213"
	for reason: String in ["房间已满", ""]:
		var joins := []
		var poll := func() -> void:
			for message: Array in server.poll():
				if message[0] != 0: continue
				var packet: PackedByteArray = message[2]
				joins.append(packet[2])
				if not reason.is_empty():
					var reply := NetCodec.new().encode_event(NetEvent.Kind.MESSAGE, reason)
					server.send(message[1], EVENT, NetBus._wire(reply))
		tree.physics_frame.connect(poll)
		NetSession._discovery.update({"code": code, "port": port, "mode": WorldSpec.DUEL, "players": 1,
				"max": 2, "in_match": false, "beta": false}, "127.0.0.1", Time.get_ticks_msec() / 1000.0)
		var error := await NetSession.join_room(code)
		tree.physics_frame.disconnect(poll)
		expect(error == ("入房结果未确认" if reason.is_empty() else reason), "admission returns the actual outcome")
		expect(joins == [NetCodec.EVENT + NetEvent.Kind.JOIN] and tunnel.lookups == 0,
				"rejected and unanswered admissions each deliver exactly one JOIN")
	server.close()
	NetSession._tunnel = original
	NetSession._discovery.stop()

func _broadcast_and_order() -> void:
	var targets := PackedInt32Array([-1])
	targets.append_array(_joined)
	var payload := PackedByteArray([41, 42, 43])
	for flow in [INPUT, STATE, EVENT]:
		var results := _server.send_many(targets, flow, payload)
		expect(results.size() == targets.size() and results[0] == ERR_UNCONFIGURED, "broadcast keeps per-peer errors")
		for i in range(1, results.size()): expect(results[i] == OK, "broadcast recipient accepted")
		expect(_until(func() -> bool: return _inboxes.all(func(inbox: Array) -> bool: return inbox.size() == 1)), "broadcast reaches every client")
		for inbox: Array in _inboxes:
			expect(inbox.size() == 1 and inbox[0][2] == payload, "broadcast payload preserved")
			inbox.clear()
	var accepted := true
	const message_count := 1100
	_poll_limit = 1
	for i in message_count:
		var bytes := PackedByteArray()
		bytes.resize(12)
		bytes.encode_u32(0, i)
		accepted = _server.send(_client_peers[0], EVENT, bytes) == OK and accepted
		if (i + 1) % 100 == 0:
			expect(_until(func() -> bool: return _inboxes[0].size() == i + 1), "poll(1) receives independent messages")
	expect(accepted, "send 1100 independent EVENT messages")
	var ordered: bool = _inboxes[0].size() == message_count
	var valid_timestamps := true
	for i in _inboxes[0].size():
		var message: Array = _inboxes[0][i]
		ordered = ordered and message[2].decode_u32(0) == i
		valid_timestamps = valid_timestamps and message[3] > 0
	expect(ordered, "FIFO across independently encoded messages")
	expect(valid_timestamps, "each message has a receive timestamp")
	_poll_limit = 256
	_inboxes[0].clear()

func _large_frames() -> void:
	_poll_limit = 1
	var random := Crypto.new().generate_random_bytes(768 * 1024)
	var realtime := random.slice(0, 64 * 1024)
	expect(_server.send(_client_peers[0], EVENT, random) == OK, "incompressible frame accepted")
	_server.flush()
	expect(_server.send(_client_peers[0], STATE, realtime) == OK, "STATE above 16 KiB accepted alongside EVENT")
	var compressed := PackedByteArray()
	compressed.resize(4 * 1024 * 1024)
	compressed.fill(19)
	expect(_server.send(_client_peers[0], EVENT, compressed) == OK, "queue next frame while large frame drains")
	expect(_until(func() -> bool: return _inboxes[0].size() == 3, 10000), "large fragmented frames complete")
	if _inboxes[0].size() == 3:
		expect(_inboxes[0].any(func(message: Array) -> bool: return message[2] == realtime), "STATE arrives intact")
		var reliable: Array = _inboxes[0].filter(func(message: Array) -> bool: return message[2] != realtime)
		expect(reliable.size() == 2 and reliable[0][2] == random and reliable[1][2] == compressed, "raw fallback and compressed EVENT payloads preserve FIFO")
	_inboxes[0].clear()
	compressed.resize(40 * 1024 * 1024)
	compressed.fill(23)
	for i in 3:
		expect(_server.send(_client_peers[0], EVENT, compressed) == OK, "large message %d queued without disconnecting" % i)
	expect(_server.send(_client_peers[0], EVENT, realtime) == OK, "small message follows large messages")
	expect(_until(func() -> bool: return _inboxes[0].size() == 4, 6000), "large independent messages arrive intact")
	if _inboxes[0].size() == 4:
		for i in 3:
			expect(_inboxes[0][i][2] == compressed, "large message %d preserved" % i)
		expect(_inboxes[0][3][2] == realtime, "trailing message preserves FIFO")
	_inboxes[0].clear()
	expect(_server.send(_client_peers[0], STATE, compressed) == OK, "STATE raw payload above 32 MiB accepted")
	expect(_until(func() -> bool: return _inboxes[0].size() == 1, 6000), "large STATE payload arrives")
	expect(_inboxes[0].size() == 1 and _inboxes[0][0][2] == compressed, "large STATE payload decoded intact")
	_inboxes[0].clear()
	_poll_limit = 256

func _reopen_with_pending_data() -> void:
	var old := Crypto.new().generate_random_bytes(2 * 1024 * 1024)
	expect(_clients[0].send(1, EVENT, old) == OK, "old session queues encoded fragments")
	_clients[0].flush()
	_clients[0].close()
	expect(_clients[0].connect_to("127.0.0.1", _server.get_port()) == OK, "same endpoint reopens with pending data")
	expect(_until(func() -> bool: return _clients[0].is_connected()), "new session connects")
	var fresh := PackedByteArray([71, 72, 73])
	expect(_clients[0].send(1, EVENT, fresh) == OK, "new session sends")
	expect(_until(func() -> bool: return not _server_messages.is_empty()), "new session receives completion")
	expect(_server_messages.size() == 1 and _server_messages[0][2] == fresh, "old data cannot leak into the new connection")
	# 退出测试前发送一条需要分片的消息，使清理连接时仍有尚未发送的数据。
	_clients[0].send(1, EVENT, old)
	_clients[0].flush()

func _until(condition: Callable, timeout_ms: int = 4000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not condition.call() and Time.get_ticks_msec() < deadline:
		_pump()
		OS.delay_msec(1)
	return condition.call()

func _pump() -> void:
	var count := 0
	for message: Array in _server.poll(_poll_limit):
		if message[0] == 0:
			_server_messages.append(message)
			count += 1
		elif message[0] == 1: _joined.append(message[1])
		else: _connection_errors.append(["server", message])
	_within_limit = _within_limit and count <= _poll_limit
	for i in _clients.size():
		count = 0
		for message: Array in _clients[i].poll(_poll_limit):
			if message[0] == 0:
				_inboxes[i].append(message)
				count += 1
			elif message[0] != 1: _connection_errors.append([i, message])
		_within_limit = _within_limit and count <= _poll_limit

func cleanup() -> void:
	for client in _clients: client.close()
	_clients.clear()
	_server.close()
	_inboxes.clear()
	_server_messages.clear()
	super.cleanup()
