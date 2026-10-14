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
		var entries := [[1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, codec.encode_input(ProtocolFixture.input())],
				[2, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, codec.encode_state(ProtocolFixture.frame())],
				[0, MultiplayerPeer.TRANSFER_MODE_RELIABLE, codec.encode_event(NetEvent.Kind.BASELINE, baseline)]]
		var expected: Array = entries.map(func(entry: Array) -> PackedByteArray: return entry[2])
		var received: Array = []
		var sends := [0, 0, 0]
		var next_send := 0
		var started := Time.get_ticks_msec()
		deadline = started + 15000
		while received.size() < entries.size() and Time.get_ticks_msec() < deadline:
			if Time.get_ticks_msec() >= next_send:
				for entry in entries:
					if received.has(entry[2]) or (entry[1] == MultiplayerPeer.TRANSFER_MODE_RELIABLE and next_send > 0):
						continue
					client.transfer_channel = entry[0]
					client.transfer_mode = entry[1]
					client.set_target_peer(1)
					assert(client.put_packet(entry[2]) == OK)
					sends[entries.find(entry)] += 1
				next_send = Time.get_ticks_msec() + 100
			server.poll()
			client.poll()
			while server.get_available_packet_count() > 0:
				var packet := server.get_packet()
				assert(expected.has(packet))
				if not received.has(packet):
					received.append(packet)
			await get_tree().process_frame
		var flows: Array = received.map(func(packet: PackedByteArray) -> int: return expected.find(packet))
		print("TRANSPORT CYCLE %d elapsed_ms=%d flows=%s sends=%s throttle=%d" % [cycle,
			Time.get_ticks_msec() - started, flows, sends,
			client.get_peer(1).get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE)])
		if received.size() != entries.size():
			push_error("TRANSPORT PROBE FAIL missing flows: %s" % [entries.size() - received.size()])
			get_tree().quit(1)
			return
		client.close()
		server.close()
		await get_tree().process_frame
	print("TRANSPORT PROBE OK small input, state, fragmented baseline, reconnect Zstd")
	get_tree().quit()
