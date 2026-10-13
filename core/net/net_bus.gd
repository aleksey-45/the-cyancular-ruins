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

func _ready() -> void:
	multiplayer.server_relay = false
	multiplayer.peer_packet.connect(_receive)
	multiplayer.peer_disconnected.connect(func(peer: int) -> void:
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
	return err

func stop() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_peer = null
	_codecs.clear()
	is_server_mode = false

func can_send_to_server() -> bool:
	return _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func send_input(packet: Dictionary) -> void:
	multiplayer.send_bytes(_codec(1).encode_input(packet), 1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, 1)

func send_state(peer: int, frame: Dictionary) -> void:
	multiplayer.send_bytes(_codec(peer).encode_state(frame), peer, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, 2)

func send_event(kind: int, data: Variant = null, peer: int = 1) -> void:
	multiplayer.send_bytes(_codec(peer).encode_event(kind, data), peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)

func _receive(peer: int, packet: PackedByteArray) -> void:
	var stream := StreamPeerBuffer.new()
	stream.data_array = packet
	var code := stream.get_u8()
	var codec := _codec(peer)
	match code:
		NetCodec.INPUT: input_received.emit(peer, codec.decode_input(stream))
		NetCodec.STATE:
			var frame := codec.decode_state(stream)
			if not frame.is_empty(): state_received.emit(frame)
		_:
			var kind := code - NetCodec.EVENT
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
