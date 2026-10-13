extends Node

var server := ENetMultiplayerPeer.new()
var client := ENetMultiplayerPeer.new()

func _ready() -> void:
	run.call_deferred()

func run() -> void:
	for cycle in 2:
		assert(server.create_server(0, 1, 3) == OK)
		server.get_host().compress(ENetConnection.COMPRESS_ZSTD)
		assert(client.create_client("127.0.0.1", server.get_host().get_local_port(), 3) == OK)
		client.get_host().compress(ENetConnection.COMPRESS_ZSTD)
		var deadline := Time.get_ticks_msec() + 5000
		while client.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED and Time.get_ticks_msec() < deadline:
			server.poll()
			client.poll()
			await get_tree().process_frame
		assert(client.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
		var large := PackedByteArray()
		large.resize(256 * 1024)
		for i in large.size():
			large[i] = (i * 13) % 251
		var codec := NetCodec.new()
		var baseline := ProtocolFixture.baseline()
		baseline["map"] = large
		for entry in [[1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, codec.encode_input(ProtocolFixture.input())],
				[2, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, codec.encode_state(ProtocolFixture.frame())],
				[0, MultiplayerPeer.TRANSFER_MODE_RELIABLE, codec.encode_event(NetEvent.Kind.BASELINE, baseline)]]:
			var packet: PackedByteArray = entry[2]
			client.transfer_channel = entry[0]
			client.transfer_mode = entry[1]
			client.set_target_peer(1)
			assert(client.put_packet(packet) == OK)
			var received := false
			deadline = Time.get_ticks_msec() + 5000
			while not received and Time.get_ticks_msec() < deadline:
				server.poll()
				client.poll()
				if server.get_available_packet_count() > 0:
					assert(server.get_packet() == packet)
					received = true
				await get_tree().process_frame
			assert(received)
		client.close()
		server.close()
		await get_tree().process_frame
	print("TRANSPORT PROBE OK small input, state, fragmented baseline, reconnect Zstd")
	get_tree().quit()
