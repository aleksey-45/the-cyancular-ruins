extends Node
signal input_received(peer: int, packet: Dictionary)
signal state_received(frame: Dictionary)
signal event_received(peer: int, kind: int, data: Variant)
signal peer_left(peer: int)
signal ping_updated(ms: int)
enum Flow { INPUT, STATE, EVENT }
const DEFAULT_PORT := 7777
const CHANNELS := 3
var is_server_mode := false
var server_port := DEFAULT_PORT
var ping_ms := 0
var _peer: ENetMultiplayerPeer
var _codecs: Dictionary = {}
var _traffic: Dictionary = {}
var _sample_at := Time.get_ticks_msec()
var _state_at := 0
var _state_gap_max := 0

func _ready() -> void:
	multiplayer.server_relay = false
	multiplayer.peer_packet.connect(_receive)
	multiplayer.peer_connected.connect(func(peer: int) -> void:
		GameLog.record("peer_connected", {"peer": peer}))
	multiplayer.connected_to_server.connect(func() -> void: GameLog.record("server_connected"))
	multiplayer.connection_failed.connect(func() -> void: GameLog.record("connection_failed", {}, true))
	multiplayer.server_disconnected.connect(func() -> void: GameLog.record("server_disconnected", {}, true))
	multiplayer.peer_disconnected.connect(func(peer: int) -> void:
		GameLog.record("peer_disconnected", {"peer": peer}, true)
		_codecs.erase(peer)
		peer_left.emit(peer))

func start_server(port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 8, CHANNELS)
	if err == OK:
		peer.get_host().compress(ENetConnection.COMPRESS_ZSTD)
		_codecs.clear()
		multiplayer.multiplayer_peer = peer
		_peer = peer
		is_server_mode = true
		server_port = peer.get_host().get_local_port()
		_reset_metrics()
	GameLog.record("listen", {"port": server_port if err == OK else port, "error": err, "compression": "zstd"})
	return err

func start_client(address: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port, CHANNELS)
	if err == OK:
		peer.get_host().compress(ENetConnection.COMPRESS_ZSTD)
		_codecs.clear()
		multiplayer.multiplayer_peer = peer
		_peer = peer
		is_server_mode = false
		ping_ms = 0
		_reset_metrics()
	GameLog.record("connect", {"address": address, "port": port, "error": err, "compression": "zstd"})
	return err

func stop() -> void:
	if _peer != null:
		_log_metrics()
		GameLog.record("transport_stop", {"status": _peer.get_connection_status(), "server": is_server_mode})
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_peer = null
	_codecs.clear()
	is_server_mode = false

func can_send_to_server() -> bool:
	return _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func send_input(packet: Dictionary) -> void:
	var bytes := _codec(1).encode_input(packet)
	_sent("input", bytes, multiplayer.send_bytes(bytes, 1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, 1), 1)

func send_state(peer: int, frame: Dictionary) -> void:
	var bytes := _codec(peer).encode_state(frame)
	_sent("state", bytes, multiplayer.send_bytes(bytes, peer, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, 2), peer)

func send_event(kind: int, data: Variant = null, peer: int = 1) -> void:
	var bytes := _codec(peer).encode_event(kind, data)
	_sent("event", bytes, multiplayer.send_bytes(bytes, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0), peer)
	_log_event("send", peer, kind, bytes.size())

func _receive(peer: int, packet: PackedByteArray) -> void:
	var stream := StreamPeerBuffer.new()
	stream.data_array = packet
	var code := stream.get_u8()
	_count("rx_" + ("input" if code == NetCodec.INPUT else "state" if code == NetCodec.STATE else "event"), packet.size())
	var codec := _codec(peer)
	match code:
		NetCodec.INPUT: input_received.emit(peer, codec.decode_input(stream))
		NetCodec.STATE:
			var now := Time.get_ticks_msec()
			if _state_at > 0:
				_state_gap_max = maxi(_state_gap_max, now - _state_at)
				if now - _state_at > 100:
					GameLog.record("state_gap", {"gap_ms": now - _state_at, "last_serial": codec.latest})
			_state_at = now
			var frame := codec.decode_state(stream)
			if not frame.is_empty(): state_received.emit(frame)
		_:
			var kind := code - NetCodec.EVENT
			_log_event("receive", peer, kind, packet.size())
			event_received.emit(peer, kind, codec.decode_event(kind, stream))

func _codec(peer: int) -> NetCodec:
	if not _codecs.has(peer): _codecs[peer] = NetCodec.new()
	return _codecs[peer]

func _process(_delta: float) -> void:
	if not is_server_mode and can_send_to_server():
		var peer := _peer.get_peer(1)
		var value := int(peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
		if value != ping_ms:
			ping_ms = value
			ping_updated.emit(value)
	if _peer != null and Time.get_ticks_msec() - _sample_at >= 1000:
		_log_metrics()

func _sent(flow: String, bytes: PackedByteArray, error: Error, peer: int) -> void:
	_count("tx_" + flow, bytes.size())
	if error != OK:
		if not _traffic.has("send_errors"):
			GameLog.record("send_error", {"flow": flow, "peer": peer, "error": error,
					"connected": can_send_to_server()}, true)
		_traffic["send_errors"] = _traffic.get("send_errors", 0) + 1

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
	_traffic.clear()
	_sample_at = Time.get_ticks_msec()
	_state_at = 0
	_state_gap_max = 0

func _log_metrics() -> void:
	var peers: Array = []
	for id in multiplayer.get_peers():
		var peer := _peer.get_peer(id)
		peers.append({"peer": id, "rtt_ms": peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
				"rtt_variance": peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME_VARIANCE),
				"reliable_loss_ratio": peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / ENetPacketPeer.PACKET_LOSS_SCALE,
				"loss_epoch_ms": peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS_EPOCH),
				"throttle": peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE),
				"codec": _codec(id).diagnostics.duplicate()})
	var now := Time.get_ticks_msec()
	GameLog.record("transport_sample", {"interval_ms": now - _sample_at, "peers": peers,
			"application": _traffic, "state_gap_max_ms": _state_gap_max,
			"state_age_ms": now - _state_at if _state_at > 0 else -1})
	_traffic.clear()
	_sample_at = now
	_state_gap_max = 0
