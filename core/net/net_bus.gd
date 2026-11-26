extends Node

signal input_received(peer: int, packet: Array, received_us: int)
signal state_received(frame: Dictionary)
signal event_received(peer: int, kind: int, data: Variant)
signal peer_left(peer: int)
signal server_disconnected
signal ping_updated(ms: int)
signal protocol_error(message: String)

enum Flow { INPUT, STATE, EVENT }
const DEFAULT_PORT := 7777
const DISPATCH_BUDGET_US := 2000
const DISPATCH_BUDGET_BYTES := 512 * 1024
const MAX_PENDING_MESSAGES := 1024
const MAX_PENDING_BYTES := 64 * 1024 * 1024
const MAX_RECEIVE_AGE_US := 5000000
const MIN_STATE_PACKET_BYTES := 3 + 4 * 4 + 1
var is_server_mode := false
var server_ip := "127.0.0.1"
var server_port := DEFAULT_PORT
var ping_ms := 0
var _transport := GnsEndpoint.new()
var _active := false
var connection_generation := 0
var _codecs: Dictionary = {}
var _ping_sample_at := 0
var _protocol_waiting_at := 0
var _pending_messages: Array = []

func pick_free_port() -> int:
	var probe := PacketPeerUDP.new()
	if probe.bind(0, "127.0.0.1") != OK:
		return 0
	var port := probe.get_local_port()
	probe.close()
	return port

func start_server(port: int = DEFAULT_PORT) -> Error:
	stop()
	if port == 0:
		port = pick_free_port()
		if port == 0:
			return ERR_CANT_CREATE
	var error := _transport.listen(port) as Error
	if error == OK:
		_active = true
		is_server_mode = true
		server_port = _transport.get_port()
	return error

func connect_server(ip: String, port: int, timeout_ms: int, alive := Callable()) -> Error:
	if can_send_to_server() and server_ip == ip and server_port == port:
		return OK
	stop()
	server_ip = ip
	server_port = port
	var error := _transport.connect_to(ip, port) as Error
	if error != OK:
		return error
	_active = true
	ping_ms = 0
	_ping_sample_at = Time.get_ticks_msec()
	var attempt := connection_generation
	var deadline := _ping_sample_at + timeout_ms
	while attempt == connection_generation and _active and Time.get_ticks_msec() < deadline:
		if alive.is_valid() and not alive.call():
			break
		if can_send_to_server():
			return OK
		await get_tree().create_timer(0.05).timeout
	if attempt != connection_generation:
		return ERR_SKIP
	error = ERR_TIMEOUT if _active else ERR_CANT_CONNECT
	stop()
	return error

func stop() -> void:
	connection_generation += 1
	_active = false
	_transport.close()
	_pending_messages.clear()
	_codecs.clear()
	_protocol_waiting_at = 0
	is_server_mode = false

func can_send_to_server() -> bool:
	return _active and not is_server_mode and _transport.is_connected()

func send_input(packet: Array) -> void:
	_send(1, Flow.INPUT, _codec(1).encode_input(packet))

func send_state(peer: int, feedback: PackedByteArray, batch: NetCodec.StateBatch) -> void:
	var codec := _codec(peer)
	if codec.waiting_full > codec.state_ack:
		return
	var perf_started := PerformanceStats.begin()
	var bytes := codec.encode_state(feedback, batch)
	PerformanceStats.end(PerformanceStats.STATE_ENCODE, perf_started)
	_send(peer, Flow.EVENT if codec.waiting_full != 0 else Flow.STATE, bytes)

func send_final_state(peers: PackedInt32Array, batch: NetCodec.StateBatch) -> void:
	var started := PerformanceStats.begin()
	var encoder := NetCodec.new()
	for peer: int in peers:
		encoder.serial = maxi(encoder.serial, _codec(peer).serial)
	var bytes := encoder.encode_state(PackedByteArray(), batch, true)
	for peer: int in peers:
		_codec(peer).serial = encoder.serial
	PerformanceStats.end(PerformanceStats.STATE_ENCODE, started)
	_send_reliable(peers, bytes)

func send_event(kind: int, data: Variant = null, peer: int = 1, batch: NetCodec.StateBatch = null) -> void:
	_send(peer, Flow.EVENT, _codec(peer).encode_event(kind, data, batch))

# 同一个事件发给多个连接时，所有接收方共用编码后的字节。
func broadcast_event(kind: int, data: Variant, peers: PackedInt32Array) -> void:
	if peers.is_empty(): return
	assert(kind != NetEvent.Kind.BASELINE)
	_send_reliable(peers, _codec(peers[0]).encode_event(kind, data))

func _send_reliable(peers: PackedInt32Array, bytes: PackedByteArray) -> void:
	var perf_started := PerformanceStats.begin()
	var wire := _wire(bytes)
	var errors := _transport.send_many(peers, Flow.EVENT, wire)
	for i in peers.size(): _check_send_result(peers[i], errors[i])
	PerformanceStats.end(PerformanceStats.TRANSPORT_SEND, perf_started)

func _send(peer: int, flow: Flow, bytes: PackedByteArray) -> void:
	var perf_started := PerformanceStats.begin()
	var wire := _wire(bytes)
	_check_send_result(peer, _transport.send(peer, flow, wire))
	PerformanceStats.end(PerformanceStats.TRANSPORT_SEND, perf_started)

func _check_send_result(peer: int, error: int) -> void:
	# 发送时若发现连接已关闭，等待传输层的断开通知清理连接状态。
	if error == OK or error == ERR_UNCONFIGURED or error == ERR_CONNECTION_ERROR: return
	push_warning("网络发送失败 peer=%d error=%d" % [peer, error])
	_transport.disconnect_peer(peer, "Outgoing message rejected: %d" % error)

func _wire(bytes: PackedByteArray) -> PackedByteArray:
	var wire := PackedByteArray([NetCodec.WIRE_MAGIC, NetCodec.PROTOCOL_VERSION])
	wire.append_array(bytes)
	return wire

func _ready() -> void:
	process_physics_priority = -100

func _physics_process(_delta: float) -> void:
	if not _active:
		return
	var perf_poll := PerformanceStats.begin()
	var generation := connection_generation
	# 新收到的消息与此前积压的消息一起合并和筛选。
	var messages := _transport.poll()
	_pending_messages.append_array(messages)
	messages = _filter_receive_backlog(_coalesce_messages(_pending_messages))
	_pending_messages = []
	PerformanceStats.end(PerformanceStats.NETWORK_POLL, perf_poll)
	var perf_dispatch := PerformanceStats.begin()
	# 性能统计将快照合并和积压检查归入轮询。后续的消息分发另行计时。
	var dispatch_started := Time.get_ticks_usec()
	var dispatched := 0
	var dispatched_bytes := 0
	for message: Array in messages:
		if generation != connection_generation:
			break
		if dispatched > 0 and (Time.get_ticks_usec() - dispatch_started >= DISPATCH_BUDGET_US or dispatched_bytes >= DISPATCH_BUDGET_BYTES):
			break
		dispatched += 1
		if message[0] == 0: dispatched_bytes += message[2].size()
		var peer: int = message[1]
		match message[0]:
			0: _receive(peer, message[2], message[3])
			1:
				if not is_server_mode:
					_protocol_waiting_at = Time.get_ticks_msec()
			2, 3:
				_codecs.erase(peer)
				if is_server_mode:
					peer_left.emit(peer)
				else:
					_active = false
					if message[0] == 2:
						server_disconnected.emit()
	if generation == connection_generation: _pending_messages = messages.slice(dispatched)
	if _active and not is_server_mode and Time.get_ticks_msec() - _ping_sample_at >= 1000:
		_update_ping()
	if _active and _protocol_waiting_at > 0 and Time.get_ticks_msec() - _protocol_waiting_at > 5000:
		_fail_protocol("服务器握手超时，请确认服务端与客户端使用相同版本")
	PerformanceStats.end(PerformanceStats.NETWORK_DISPATCH, perf_dispatch)

func _filter_receive_backlog(messages: Array) -> Array:
	var totals := {}
	var rejected := {}
	var now := Time.get_ticks_usec()
	for message: Array in messages:
		if message[0] != 0: continue
		var peer: int = message[1]
		if not totals.has(peer): totals[peer] = {"messages": 0, "bytes": 0}
		totals[peer]["messages"] += 1
		totals[peer]["bytes"] += message[2].size()
		if totals[peer]["messages"] > MAX_PENDING_MESSAGES or totals[peer]["bytes"] > MAX_PENDING_BYTES or now - int(message[3]) > MAX_RECEIVE_AGE_US:
			rejected[peer] = true
	# 任一条消息等待过久，或某连接积压的消息数、字节数超出限制时，关闭该连接。
	for peer: int in rejected:
		_transport.disconnect_peer(peer, "Receive backlog exceeded processing limits")
	# 连接关闭后，过滤其尚未处理的游戏数据。连接状态通知仍交给分发流程。
	return messages.filter(func(message: Array) -> bool: return message[0] != 0 or not rejected.has(message[1]))

# 连续的 STATE 和 INPUT 消息中，每个连接仅保留序号最新的 STATE。较新的快照以已确认的快照为增量基准，可以跳过中间项。
# 可靠事件、连接通知和无法识别的消息会截断这段队列。INPUT 保持接收顺序，由输入缓冲区去重。
func _coalesce_messages(messages: Array) -> Array:
	var result: Array = []
	var latest := {}
	for message: Array in messages:
		var code := -1
		if message[0] == 0:
			var packet: PackedByteArray = message[2]
			if packet.size() >= 3 and packet[0] == NetCodec.WIRE_MAGIC and packet[1] == NetCodec.PROTOCOL_VERSION:
				code = packet[2]
		if code == NetCodec.STATE and message[2].size() >= MIN_STATE_PACKET_BYTES:
			var key: int = message[1]
			if latest.has(key):
				var old: Array = result[latest[key]]
				var previous: PackedByteArray = old[2]
				var current: PackedByteArray = message[2]
				if current.decode_u32(3) <= previous.decode_u32(3):
					continue
				result[latest[key]] = null
			latest[key] = result.size()
		elif code != NetCodec.INPUT:
			latest.clear()
		result.append(message)
	return result.filter(func(message: Variant) -> bool: return message != null)

func _receive(peer: int, packet: PackedByteArray, received_us: int) -> void:
	if packet.size() < 3 or packet[0] != NetCodec.WIRE_MAGIC or packet[1] != NetCodec.PROTOCOL_VERSION:
		if not is_server_mode:
			_fail_protocol("联机协议版本不同，请更新服务端与客户端")
		return
	var code := packet[2]
	var kind := code - NetCodec.EVENT
	if is_server_mode:
		if code != NetCodec.INPUT and (kind < NetEvent.Kind.CREATE or kind > NetEvent.Kind.SUICIDE):
			return
	elif code != NetCodec.STATE and (kind < NetEvent.Kind.ROOM or kind > NetEvent.Kind.ROOM_CLOSED):
		return
	var reader := NetCodec.Reader.new(packet, 3)
	var codec := _codec(peer)
	match code:
		NetCodec.INPUT:
			var input := codec.decode_input(reader)
			if reader.valid:
				input_received.emit(peer, input, received_us)
		NetCodec.STATE:
			var frame := codec.decode_state(reader)
			if not frame.is_empty():
				_protocol_waiting_at = 0
				state_received.emit(frame)
		_:
			var payload: Variant = codec.decode_event(kind, reader)
			if reader.valid:
				_protocol_waiting_at = 0
				event_received.emit(peer, kind, payload)
	if not reader.valid and not is_server_mode:
		_fail_protocol("收到无效联机数据")

func _fail_protocol(message: String) -> void:
	stop()
	protocol_error.emit(message)

func _codec(peer: int) -> NetCodec:
	if not _codecs.has(peer): _codecs[peer] = NetCodec.new()
	return _codecs[peer]

func _update_ping() -> void:
	_ping_sample_at = Time.get_ticks_msec()
	var value: int = _transport.get_ping()
	if value >= 0 and value != ping_ms:
		ping_ms = value
		ping_updated.emit(ping_ms)

func _exit_tree() -> void:
	stop()
