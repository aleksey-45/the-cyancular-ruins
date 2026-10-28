extends Node

signal input_received(peer: int, packet: Dictionary)
signal remote_input_received(role: int, tick: int, packet: Dictionary)
signal state_received(frame: Dictionary)
signal event_received(peer: int, kind: int, data: Variant)
signal peer_joined(peer: int)
signal peer_left(peer: int)
signal connected_to_server
signal connection_failed
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
var is_server_mode := false
var server_port := DEFAULT_PORT
var ping_ms := 0
var compression_enabled := true
var _transport := GnsEndpoint.new()
var _active := false
var _generation := 0
var _codecs: Dictionary = {}
var _traffic: Dictionary = {}
var _sample_at := Time.get_ticks_msec()
var _state_at := 0
var _state_gap_max := 0
var _state_received_us := 0
var _state_receive_gap_max_us := 0
var _receive_queue_max_us := 0
var _poll_at_us := 0
var _poll_gap_us := 0
var _poll_gap_max_us := 0
var _protocol_waiting_at := 0
var _rejected_protocols: Dictionary = {}
var _pending_messages: Array = []
var _dispatch_budget_hits := 0
var _pending_max := 0
# 仅帧诊断累计；主线程编码、原生发送与日志入队分别计量，单位 us。
var _event_send_profile := PackedInt64Array([0, 0, 0, 0, 0])

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
	_transport.set_compression(compression_enabled)
	var error := _transport.listen(port) as Error
	if error == OK:
		_active = true
		is_server_mode = true
		server_port = _transport.get_port()
		_reset_metrics()
	GameLog.record("listen", {"port": server_port if error == OK else port, "error": error,
			"transport": "gns", "compression": "zstd" if compression_enabled else "none"})
	return error

func start_client(address: String, port: int = DEFAULT_PORT) -> Error:
	stop()
	if not address.is_valid_ip_address():
		address = IP.resolve_hostname(address)
	_transport.set_compression(compression_enabled)
	var error := _transport.connect_to(address, port) as Error
	if error == OK:
		_active = true
		ping_ms = 0
		_reset_metrics()
	GameLog.record("connect", {"address": address, "port": port, "error": error,
			"transport": "gns", "compression": "zstd" if compression_enabled else "none"})
	return error

func stop() -> void:
	_generation += 1
	if _active:
		_log_metrics()
		GameLog.record("transport_stop", {"connected": can_send_to_server(), "server": is_server_mode})
	_active = false
	_transport.close()
	_pending_messages.clear()
	_codecs.clear()
	_protocol_waiting_at = 0
	_rejected_protocols.clear()
	is_server_mode = false

func can_send_to_server() -> bool:
	return _active and not is_server_mode and _transport.is_connected()

func send_input(packet: Dictionary, peer: int = 1) -> void:
	var codec := _codec(peer)
	var bytes := codec.encode_input_hints(packet) if is_server_mode else codec.encode_input(packet)
	_send(peer, Flow.INPUT, bytes)

# 只复用角色区块的编码；每个接收者仍获得独立、完整且可丢包的 INPUT 包。
func broadcast_input_hints(hints: Dictionary, targets: Dictionary) -> void:
	if hints.is_empty() or targets.is_empty(): return
	var started := Time.get_ticks_usec() if FrameTrace.enabled else 0
	var encoded := {}
	var codec := _codec(targets.values()[0])
	for role in hints:
		encoded[role] = codec.encode_input_hint(role, hints[role])
	var encoded_at := Time.get_ticks_usec() if FrameTrace.enabled else 0
	for role in targets:
		if encoded.size() > int(encoded.has(role)):
			_send(targets[role], Flow.INPUT, NetCodec.pack_input_hints(encoded, role))
	if FrameTrace.enabled:
		FrameTrace.span(&"input_hint_encode", started, encoded_at)
		FrameTrace.span(&"input_hint_send", encoded_at, Time.get_ticks_usec())
		FrameTrace.count(&"input_hint_records", hints.size())
		FrameTrace.count(&"input_hint_targets", targets.size())

func send_state(peer: int, frame: Dictionary, batch: NetCodec.StateBatch) -> void:
	_send(peer, Flow.STATE, _codec(peer).encode_state(frame, batch))

func send_event(kind: int, data: Variant = null, peer: int = 1) -> void:
	var started := Time.get_ticks_usec() if FrameTrace.enabled else 0
	var bytes := _codec(peer).encode_event(kind, data)
	var encoded := Time.get_ticks_usec() if FrameTrace.enabled else 0
	_send(peer, Flow.EVENT, bytes)
	var sent := Time.get_ticks_usec() if FrameTrace.enabled else 0
	_log_event("send", peer, kind, bytes.size())
	if FrameTrace.enabled:
		_event_send_profile[0] += 1
		_event_send_profile[1] += encoded - started
		_event_send_profile[2] += sent - encoded
		_event_send_profile[3] += Time.get_ticks_usec() - sent
		_event_send_profile[4] += 1

# 本次广播内共享载荷与压缩结果；不跨事件缓存，也不改变逐连接可靠队列的入队顺序。
func broadcast_event(kind: int, data: Variant, peers: PackedInt32Array) -> void:
	if peers.is_empty(): return
	# BASELINE 修改连接的 roles/history/ACK，必须逐连接执行。
	if kind == NetEvent.Kind.BASELINE:
		for peer in peers: send_event(kind, data, peer)
		return
	var started := Time.get_ticks_usec() if FrameTrace.enabled else 0
	var bytes := _codec(peers[0]).encode_event(kind, data)
	var encoded := Time.get_ticks_usec() if FrameTrace.enabled else 0
	var wire := _wire(bytes)
	var errors := _transport.send_many(peers, Flow.EVENT, wire)
	for index in peers.size():
		_sent(peers[index], Flow.EVENT, wire, errors[index])
	var sent := Time.get_ticks_usec() if FrameTrace.enabled else 0
	for peer in peers: _log_event("send", peer, kind, bytes.size())
	if FrameTrace.enabled:
		_event_send_profile[0] += peers.size()
		_event_send_profile[1] += encoded - started
		_event_send_profile[2] += sent - encoded
		_event_send_profile[3] += Time.get_ticks_usec() - sent
		_event_send_profile[4] += 1

# 只读累计量；调用方取差值，不能清零影响嵌套阶段的计时。
func event_send_profile() -> PackedInt64Array:
	return _event_send_profile.duplicate()

func _send(peer: int, flow: Flow, bytes: PackedByteArray) -> void:
	var wire := _wire(bytes)
	_sent(peer, flow, wire, _transport.send(peer, flow, wire))

func _wire(bytes: PackedByteArray) -> PackedByteArray:
	var wire := PackedByteArray([NetCodec.WIRE_MAGIC, NetCodec.PROTOCOL_VERSION])
	wire.append_array(bytes)
	return wire

func _sent(peer: int, flow: Flow, wire: PackedByteArray, error: int) -> void:
	if FrameTrace.packets: FrameTrace.event(&"packet", {"direction": "send", "peer": peer, "flow": flow, "error": error, "bytes": wire})
	_count("tx_" + ["input", "state", "event"][flow], wire.size())
	if error != OK:
		GameLog.record("send_error", {"flow": flow, "peer": peer, "error": error}, true)
		_traffic["send_errors"] = _traffic.get("send_errors", 0) + 1

func _physics_process(_delta: float) -> void:
	if not _active:
		return
	var started := Time.get_ticks_usec()
	_poll_gap_us = started - _poll_at_us if _poll_at_us > 0 else 0
	_poll_gap_max_us = maxi(_poll_gap_max_us, _poll_gap_us)
	_poll_at_us = started
	var generation := _generation
	# 每帧接纳新包，使排队中的旧 STATE 能被最新锚点合并；派发仍受独立预算约束。
	# 只排空旧批次会把新 STATE 留在原生队列，延长重放窗口并进一步拖慢排空。
	var messages := _transport.poll(RECEIVE_BATCH_MESSAGES)
	var polled := Time.get_ticks_usec()
	var native_count := messages.size()
	_pending_messages.append_array(messages)
	messages = _filter_receive_backlog(_coalesce_messages(_pending_messages))
	_pending_messages = []
	_pending_max = maxi(_pending_max, messages.size())
	# 合并和年龄检查单独计时，不能因旧队列扫描耗尽业务派发的预算。
	var dispatch_started := Time.get_ticks_usec()
	var dispatched := 0
	var dispatched_bytes := 0
	for message: Array in messages:
		if generation != _generation:
			break
		if dispatched > 0 and (Time.get_ticks_usec() - dispatch_started >= DISPATCH_BUDGET_US or dispatched_bytes >= DISPATCH_BUDGET_BYTES):
			_dispatch_budget_hits += 1
			break
		dispatched += 1
		if message[0] == 0: dispatched_bytes += message[2].size()
		var peer: int = message[1]
		match message[0]:
			0: _receive(peer, message[2], message[3])
			1:
				if is_server_mode:
					GameLog.record("peer_connected", {"peer": peer})
					peer_joined.emit(peer)
				else:
					GameLog.record("server_connected")
					_protocol_waiting_at = Time.get_ticks_msec()
					connected_to_server.emit()
			2, 3:
				_codecs.erase(peer)
				GameLog.record("peer_disconnected", {"peer": peer, "reason": message[2], "detail": message[3]}, true)
				if is_server_mode:
					peer_left.emit(peer)
				elif message[0] == 3:
					connection_failed.emit()
				else:
					server_disconnected.emit()
			4:
				GameLog.record("send_error", {"peer": peer, "reason": message[2], "detail": message[3]}, true)
	if generation == _generation: _pending_messages = messages.slice(dispatched)
	var finished := Time.get_ticks_usec()
	if FrameTrace.enabled:
		FrameTrace.span(&"net_poll", started, polled)
		FrameTrace.span(&"net_preprocess", polled, dispatch_started)
		FrameTrace.span(&"net_dispatch", dispatch_started, finished)
		FrameTrace.count(&"net_messages", dispatched)
		FrameTrace.context(&"net", {"native": native_count, "pending": _pending_messages.size(), "poll_gap_us": _poll_gap_us})
	if finished - started > 1000000.0 * ActorStep.DT:
		GameLog.record("transport_slow_dispatch", {"poll_ms": (polled - started) / 1000.0,
				"preprocess_ms": (dispatch_started - polled) / 1000.0,
				"dispatch_ms": (finished - dispatch_started) / 1000.0, "messages": dispatched,
				"native_messages": native_count, "pending_messages": _pending_messages.size(), "server": is_server_mode})
	if _active and Time.get_ticks_msec() - _sample_at >= 1000:
		_log_metrics()
	if _active and _protocol_waiting_at > 0 and Time.get_ticks_msec() - _protocol_waiting_at > 5000:
		_fail_protocol("服务器握手超时，请确认服务端与客户端使用相同版本")

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
		GameLog.record("receive_backlog_reset", {"peer": peer, "messages": totals[peer]["messages"],
				"bytes": totals[peer]["bytes"], "server": is_server_mode}, true)
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
		var realtime := false
		var code := -1
		if message[0] == 0:
			var packet: PackedByteArray = message[2]
			if packet.size() >= 3 and packet[0] == NetCodec.WIRE_MAGIC and packet[1] == NetCodec.PROTOCOL_VERSION:
				code = packet[2]
				realtime = code == NetCodec.STATE
		if realtime:
			var key := Vector2i(message[1], code)
			if latest.has(key):
				var old: Array = result[latest[key]]
				var previous: PackedByteArray = old[2]
				var current: PackedByteArray = message[2]
				# STATE 可能乱序到达；合并时保留最大序号，不能让迟到旧包覆盖新状态。
				if code == NetCodec.STATE and current.size() >= 7 and previous.size() >= 7 \
						and current.decode_u32(3) <= previous.decode_u32(3):
					_count("rx_coalesced_state", current.size())
					continue
				_count("rx_coalesced_state", old[2].size())
				result[latest[key]] = null
			latest[key] = result.size()
		elif code != NetCodec.INPUT:
			# 只清空可替换 STATE 的索引，屏障前保留的消息仍按原位置派发。
			latest.clear()
		result.append(message)
	return result.filter(func(message: Variant) -> bool: return message != null)

func _receive(peer: int, packet: PackedByteArray, received_us: int) -> void:
	if FrameTrace.packets: FrameTrace.event(&"packet", {"direction": "receive", "peer": peer, "received_us": received_us, "bytes": packet})
	if packet.size() < 3 or packet[0] != NetCodec.WIRE_MAGIC or packet[1] != NetCodec.PROTOCOL_VERSION:
		if not _rejected_protocols.has(peer):
			_rejected_protocols[peer] = true
			GameLog.record("protocol_mismatch", {"peer": peer, "expected": NetCodec.PROTOCOL_VERSION}, true)
		if not is_server_mode:
			_fail_protocol("联机协议版本不同，请更新服务端与客户端")
		return
	_protocol_waiting_at = 0
	var queue_us := Time.get_ticks_usec() - received_us
	_receive_queue_max_us = maxi(_receive_queue_max_us, queue_us)
	var stream := StreamPeerBuffer.new()
	stream.data_array = packet
	stream.seek(2)
	var code := stream.get_u8()
	_count("rx_" + ("input" if code == NetCodec.INPUT else "state" if code == NetCodec.STATE else "event"), packet.size())
	var codec := _codec(peer)
	match code:
		NetCodec.INPUT:
			if is_server_mode:
				input_received.emit(peer, codec.decode_input(stream))
			else:
				var hints := codec.decode_input_hints(stream)
				for role in hints:
					remote_input_received.emit(role, hints[role]["tick"], hints[role]["packet"])
		NetCodec.STATE:
			var now := Time.get_ticks_msec()
			var receive_gap_us := received_us - _state_received_us if _state_received_us > 0 else 0
			_state_receive_gap_max_us = maxi(_state_receive_gap_max_us, receive_gap_us)
			_state_received_us = maxi(_state_received_us, received_us)
			if _state_at > 0:
				_state_gap_max = maxi(_state_gap_max, now - _state_at)
				if now - _state_at > 100:
					GameLog.record("state_gap", {"gap_ms": now - _state_at, "last_serial": codec.latest,
							"receive_gap_ms": receive_gap_us / 1000.0, "queue_ms": queue_us / 1000.0,
							"poll_gap_ms": _poll_gap_us / 1000.0})
			_state_at = now
			var decoding := Time.get_ticks_usec() if FrameTrace.enabled else 0
			var frame := codec.decode_state(stream)
			var decoded := Time.get_ticks_usec() if FrameTrace.enabled else 0
			if not frame.is_empty(): state_received.emit(frame)
			if FrameTrace.enabled:
				FrameTrace.span(&"state_decode", decoding, decoded)
				FrameTrace.span(&"state_handlers", decoded, Time.get_ticks_usec())
		_:
			var kind := code - NetCodec.EVENT
			_log_event("receive", peer, kind, packet.size())
			if kind == NetEvent.Kind.BASELINE:
				_log_metrics()
			var decoding := Time.get_ticks_usec() if FrameTrace.enabled else 0
			var payload: Variant = codec.decode_event(kind, stream)
			var decoded := Time.get_ticks_usec() if FrameTrace.enabled else 0
			event_received.emit(peer, kind, payload)
			if FrameTrace.enabled:
				FrameTrace.span(&"event_decode", decoding, decoded)
				FrameTrace.span(&"event_handlers", decoded, Time.get_ticks_usec())
				if kind == NetEvent.Kind.BASELINE: FrameTrace.count(&"baselines")

func _fail_protocol(message: String) -> void:
	stop()
	protocol_error.emit(message)

func _codec(peer: int) -> NetCodec:
	if not _codecs.has(peer): _codecs[peer] = NetCodec.new()
	return _codecs[peer]

func _count(key: String, bytes: int) -> void:
	if not _traffic.has(key):
		_traffic[key] = {"messages": 0, "bytes": 0}
	_traffic[key]["messages"] += 1
	_traffic[key]["bytes"] += bytes

func _log_event(direction: String, peer: int, kind: int, bytes: int) -> void:
	if kind != NetEvent.Kind.TERRAIN and kind != NetEvent.Kind.ROUND:
		GameLog.record("net_event", {"direction": direction, "peer": peer,
				"kind": NetEvent.Kind.keys()[kind], "bytes": bytes})

func _reset_metrics() -> void:
	_state_received_us = 0
	_state_receive_gap_max_us = 0
	_receive_queue_max_us = 0
	_poll_at_us = 0
	_poll_gap_us = 0
	_poll_gap_max_us = 0
	_dispatch_budget_hits = 0
	_pending_max = 0
	_transport.take_poll_statistics()
	_traffic.clear()
	_sample_at = Time.get_ticks_msec()
	_state_at = 0
	_state_gap_max = 0

func _log_metrics() -> void:
	var peers: Array = _transport.statistics()
	for peer: Dictionary in peers:
		peer["codec"] = _codec(peer["peer"]).diagnostics.duplicate()
		if not is_server_mode and peer["rtt_ms"] >= 0 and int(peer["rtt_ms"]) != ping_ms:
			ping_ms = int(peer["rtt_ms"])
			ping_updated.emit(ping_ms)
	var now := Time.get_ticks_msec()
	GameLog.record("transport_sample", {"transport": "gns", "interval_ms": now - _sample_at,
			"peers": peers, "application": _traffic, "state_gap_max_ms": _state_gap_max,
			"state_receive_gap_max_ms": _state_receive_gap_max_us / 1000.0,
			"receive_queue_max_ms": _receive_queue_max_us / 1000.0, "poll_gap_max_ms": _poll_gap_max_us / 1000.0,
			"receive_budget": _transport.take_poll_statistics(), "dispatch_budget_hits": _dispatch_budget_hits,
			"pending_messages": _pending_messages.size(), "pending_max": _pending_max,
			"state_age_ms": now - _state_at if _state_at > 0 else -1})
	_traffic.clear()
	_sample_at = now
	_state_gap_max = 0
	_state_receive_gap_max_us = 0
	_receive_queue_max_us = 0
	_poll_gap_max_us = 0
	_dispatch_budget_hits = 0
	_pending_max = _pending_messages.size()

func _exit_tree() -> void:
	stop()
