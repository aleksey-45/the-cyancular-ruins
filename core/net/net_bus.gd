extends Node

signal input_received(peer: int, packet: Array)
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
const RECEIVE_BATCH_MESSAGES := 256
const MAX_PENDING_MESSAGES := 1024
const MAX_PENDING_BYTES := 64 * 1024 * 1024
const MAX_RECEIVE_AGE_US := 5000000
const MIN_STATE_PACKET_BYTES := 3 + 4 * 4 + 1
var is_server_mode := false
var server_port := DEFAULT_PORT
var ping_ms := 0
var _transport := GnsEndpoint.new()
var _active := false
var connection_generation := 0
var _codecs: Dictionary = {}
var _ping_sample_at := 0
var _protocol_waiting_at := 0
var _pending_messages: Array = []

func _ready() -> void:
	process_physics_priority = -1000

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

func connect_local(port: int, timeout_ms: int, alive := Callable()) -> Error:
	if can_send_to_server() and server_port == port:
		return OK
	stop()
	server_port = port
	var error := _transport.connect_to("127.0.0.1", port) as Error
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

func send_state(peer: int, frame: Dictionary, batch: NetCodec.StateBatch) -> void:
	var perf_started := PerformanceStats.begin()
	var bytes := _codec(peer).encode_state(frame, batch)
	PerformanceStats.end(PerformanceStats.STATE_ENCODE, perf_started)
	_send(peer, Flow.STATE, bytes)

func send_event(kind: int, data: Variant = null, peer: int = 1) -> void:
	_send(peer, Flow.EVENT, _codec(peer).encode_event(kind, data))

# 广播只压缩一次，各连接共享编码结果。
func broadcast_event(kind: int, data: Variant, peers: PackedInt32Array) -> void:
	if peers.is_empty(): return
	assert(kind != NetEvent.Kind.BASELINE)
	var bytes := _codec(peers[0]).encode_event(kind, data)
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
	# 原生层已关闭或找不到连接时，由断线通知处理，避免重复关闭。
	if error == OK or error == ERR_UNCONFIGURED or error == ERR_CONNECTION_ERROR: return
	push_warning("网络发送失败 peer=%d error=%d" % [peer, error])
	_transport.disconnect_peer(peer, "Outgoing message rejected: %d" % error)

func _wire(bytes: PackedByteArray) -> PackedByteArray:
	var wire := PackedByteArray([NetCodec.WIRE_MAGIC, NetCodec.PROTOCOL_VERSION])
	wire.append_array(bytes)
	return wire

func _physics_process(_delta: float) -> void:
	if not _active:
		return
	var perf_poll := PerformanceStats.begin()
	var generation := connection_generation
	# 每帧接纳新包，使排队中的旧 STATE 能被最新锚点合并；派发仍受独立预算约束。
	# 只排空旧批次会把新 STATE 留在原生队列，延长重放窗口并进一步拖慢排空。
	var messages := _transport.poll(RECEIVE_BATCH_MESSAGES)
	_pending_messages.append_array(messages)
	messages = _filter_receive_backlog(_coalesce_messages(_pending_messages))
	_pending_messages = []
	PerformanceStats.end(PerformanceStats.NETWORK_POLL, perf_poll)
	var perf_dispatch := PerformanceStats.begin()
	# 合并和年龄检查单独计时，不能因旧队列扫描耗尽业务派发的预算。
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
			0: _receive(peer, message[2])
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
	for peer: int in rejected:
		_transport.disconnect_peer(peer, "Receive backlog exceeded processing limits")
	# 关闭连接后由正常断线流程重连并获得新 epoch/基线；已有连接事件仍须派发。
	return messages.filter(func(message: Array) -> bool: return message[0] != 0 or not rejected.has(message[1]))

# STATE 只依赖已回传的 ACK，同批尚未派发的中间 STATE 不会成为新基线。
# 同一合并区间内按 peer 保留最大序号 STATE；收到 EVENT、连接通知或无效包时结束区间。
# INPUT 不结束区间，有限冗余记录必须全部解码后去重。
# 屏障只保留本地接收顺序，不建立跨 lane 的发送或接收顺序保证。

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
				# STATE 可能乱序到达；合并时保留最大序号，不能让迟到旧包覆盖新状态。
				if current.decode_u32(3) <= previous.decode_u32(3):
					continue
				result[latest[key]] = null
			latest[key] = result.size()
		elif code != NetCodec.INPUT:
			# 只清空可替换 STATE 的索引，屏障前保留的消息仍按原位置派发。
			latest.clear()
		result.append(message)
	return result.filter(func(message: Variant) -> bool: return message != null)

func _receive(peer: int, packet: PackedByteArray) -> void:
	if packet.size() < 3 or packet[0] != NetCodec.WIRE_MAGIC or packet[1] != NetCodec.PROTOCOL_VERSION:
		if not is_server_mode:
			_fail_protocol("联机协议版本不同，请更新服务端与客户端")
		return
	var code := packet[2]
	var kind := code - NetCodec.EVENT
	if is_server_mode:
		if code != NetCodec.INPUT and (kind < NetEvent.Kind.HELLO or kind > NetEvent.Kind.SUICIDE):
			return
	elif code != NetCodec.STATE and (kind < NetEvent.Kind.ROOM or kind > NetEvent.Kind.BULLET_END):
		return
	var reader := NetCodec.Reader.new(packet, 3)
	var codec := _codec(peer)
	match code:
		NetCodec.INPUT:
			var input := codec.decode_input(reader)
			if reader.valid:
				input_received.emit(peer, input)
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
