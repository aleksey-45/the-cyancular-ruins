extends Node

var server := GnsEndpoint.new()
var client := GnsEndpoint.new()

func _ready() -> void:
	run.call_deferred()

func run() -> void:
	for compressed in [true, false]:
		server.set_compression(compressed)
		client.set_compression(compressed)
		var port := NetBus.pick_free_port()
		assert(port > 0)
		assert(server.listen(port) == OK)
		var error := client.connect_to("127.0.0.1", server.get_port())
		assert(error == OK)
		var peer := 0
		var connected := false
		var deadline := Time.get_ticks_msec() + 5000
		while (peer == 0 or not connected) and Time.get_ticks_msec() < deadline:
			for message: Array in server.poll():
				if message[0] == 1: peer = message[1]
			for message: Array in client.poll():
				if message[0] == 1: connected = true
			await get_tree().process_frame
		assert(peer > 1 and connected)
		var baseline := ProtocolFixture.baseline()
		baseline["map"] = Crypto.new().generate_random_bytes(700 * 1024)
		baseline["projectiles"] = {(1 << 48) | 777: {"type_id": 5, "pos": Vector2(1000, 500), "vel": Vector2(600, 0),
				"traveled": 120.0, "direct_hit": false, "fuse_active": true, "fuse_elapsed": 0.35, "fuse_duration": 0.4}}
		var codec := NetCodec.new()
		var input := codec.encode_input(ProtocolFixture.input())
		var state := codec.encode_state(ProtocolFixture.frame())
		var event := codec.encode_event(NetEvent.Kind.BASELINE, baseline)
		assert(event.size() > 512 * 1024)
		assert(server.send(peer, NetBus.Flow.STATE, baseline["map"]) == ERR_INVALID_PARAMETER)
		assert(server.send(peer, NetBus.Flow.EVENT, event) == OK)
		var received := [false, false, false]
		var next_send := 0
		var started := Time.get_ticks_msec()
		deadline = started + 30000
		while received.has(false) and Time.get_ticks_msec() < deadline:
			if Time.get_ticks_msec() >= next_send:
				if not received[0]: assert(client.send(1, NetBus.Flow.INPUT, input) == OK)
				if not received[1]: assert(server.send(peer, NetBus.Flow.STATE, state) == OK)
				next_send = Time.get_ticks_msec() + 100
			for message: Array in server.poll():
				if message[0] == 0:
					assert(message[3] > 0 and message[3] <= Time.get_ticks_usec())
					assert(message[2] == input)
					received[0] = true
				assert(message[0] != 4)
			for message: Array in client.poll():
				if message[0] == 0:
					assert(message[3] > 0 and message[3] <= Time.get_ticks_usec())
					assert(message[2] == state or message[2] == event)
					received[1 if message[2] == state else 2] = true
				assert(message[0] != 4)
			await get_tree().process_frame
		print("TRANSPORT GNS compression=%s elapsed_ms=%d received=%s" % [
				compressed, Time.get_ticks_msec() - started, received])
		if received.has(false):
			push_error("TRANSPORT PROBE FAIL missing flows")
			get_tree().quit(1)
			return
		var stats := client.take_poll_statistics()
		assert(stats["messages"] > 0 and stats["decoded_bytes"] >= event.size())
		await _check_send_many(peer, baseline["map"])
		client.close()
		server.close()
		await get_tree().process_frame
	await _check_bus_budget()
	print("TRANSPORT PROBE OK GNS input, state, >512 KiB baseline, reconnect, Zstd and raw")
	get_tree().quit()

func _check_send_many(peer: int, oversized: PackedByteArray) -> void:
	assert(server.send_many(PackedInt32Array(), NetBus.Flow.EVENT, PackedByteArray([1])).is_empty())
	assert(server.send_many(PackedInt32Array([peer, -1]), -1, PackedByteArray([1]))
			== PackedInt32Array([ERR_INVALID_PARAMETER, ERR_INVALID_PARAMETER]))
	assert(server.send_many(PackedInt32Array([peer]), NetBus.Flow.EVENT, PackedByteArray())
			== PackedInt32Array([ERR_INVALID_PARAMETER]))
	assert(server.send_many(PackedInt32Array([peer]), NetBus.Flow.STATE, oversized)
			== PackedInt32Array([ERR_INVALID_PARAMETER]))
	var first := PackedByteArray([98, 1, 2, 3])
	var second := PackedByteArray([98, 4, 5, 6])
	assert(server.send_many(PackedInt32Array([peer, -1]), NetBus.Flow.EVENT, first)
			== PackedInt32Array([OK, ERR_UNCONFIGURED]), "one invalid peer cannot drop valid recipients")
	assert(server.send(peer, NetBus.Flow.EVENT, second) == OK)
	var received: Array = []
	var deadline := Time.get_ticks_msec() + 3000
	while received.size() < 2 and Time.get_ticks_msec() < deadline:
		server.poll()
		for message: Array in client.poll():
			if message[0] == 0: received.append(message[2])
		await get_tree().process_frame
	assert(received == [first, second], "broadcast and single-send retain reliable order and exact bytes")
	print("SEND MANY OK partial peer failure, validation and reliable order")

func _check_bus_budget() -> void:
	assert(NetBus.start_server(0) == OK)
	assert(client.connect_to("127.0.0.1", NetBus.server_port) == OK)
	var received: Array = []
	var peers: Array = []
	var left: Array = []
	var handler := func(_peer: int, kind: int, data: Variant) -> void:
		if kind != NetEvent.Kind.MESSAGE: return
		received.append(data)
		# 模拟一次昂贵的完整事件，验证预算在事件之间让出而不丢失可靠消息。
		var until := Time.get_ticks_usec() + NetBus.DISPATCH_BUDGET_US + 100
		while Time.get_ticks_usec() < until: pass
	var joined := func(peer: int) -> void: peers.append(peer)
	var departed := func(peer: int) -> void: left.append(peer)
	NetBus.event_received.connect(handler)
	NetBus.peer_joined.connect(joined)
	NetBus.peer_left.connect(departed)
	var deadline := Time.get_ticks_msec() + 5000
	while (peers.is_empty() or not client.is_connected()) and Time.get_ticks_msec() < deadline:
		client.poll()
		await get_tree().process_frame
	assert(not peers.is_empty() and client.is_connected())
	var codec := NetCodec.new()
	for index in 16:
		var wire := PackedByteArray([NetCodec.WIRE_MAGIC, NetCodec.PROTOCOL_VERSION])
		wire.append_array(codec.encode_event(NetEvent.Kind.MESSAGE, str(index)))
		assert(client.send(1, NetBus.Flow.EVENT, wire) == OK)
	while received.size() < 16 and Time.get_ticks_msec() < deadline:
		client.poll(0)
		await get_tree().process_frame
	assert(received.size() == 16)
	for index in 16: assert(received[index] == str(index), "deferred reliable events must retain order")
	assert(NetBus._dispatch_budget_hits > 0 and NetBus._pending_max > 1,
			"expensive handlers must yield and finish the pending batch on subsequent physics ticks")
	# 旧待派发批次已占满时，仍须接纳新 STATE，才有机会按序号替换旧锚点。
	NetBus.set_physics_process(false)
	var snapshots: Array = []
	var snapshot_handler := func(frame: Dictionary) -> void: snapshots.append(frame)
	NetBus.state_received.connect(snapshot_handler)
	var state_codec := NetCodec.new()
	var frame := ProtocolFixture.frame()
	var old_wire := PackedByteArray([NetCodec.WIRE_MAGIC, NetCodec.PROTOCOL_VERSION])
	old_wire.append_array(state_codec.encode_state(frame))
	frame["tick"] += 2
	var fresh_wire := PackedByteArray([NetCodec.WIRE_MAGIC, NetCodec.PROTOCOL_VERSION])
	fresh_wire.append_array(state_codec.encode_state(frame))
	assert(client.send(1, NetBus.Flow.STATE, fresh_wire) == OK)
	client.poll(0)
	await get_tree().create_timer(0.1).timeout
	for index in 256:
		NetBus._pending_messages.append([0, peers[0], old_wire, Time.get_ticks_usec()])
	NetBus._physics_process(ActorStep.DT)
	assert(snapshots.size() == 1 and snapshots[0]["tick"] == frame["tick"],
			"a full old pending batch must not prevent the latest native STATE from being admitted and coalesced")
	NetBus.state_received.disconnect(snapshot_handler)
	NetBus.set_physics_process(true)
	var filtered := NetBus._filter_receive_backlog([[0, peers[0], PackedByteArray([1]),
			Time.get_ticks_usec() - NetBus.MAX_RECEIVE_AGE_US - 1]])
	assert(filtered.is_empty())
	while left.is_empty() and Time.get_ticks_msec() < deadline:
		client.poll(0)
		await get_tree().process_frame
	assert(left == peers, "a stale receive backlog must close its peer through the normal disconnect flow")
	NetBus.event_received.disconnect(handler)
	NetBus.peer_joined.disconnect(joined)
	NetBus.peer_left.disconnect(departed)
	client.close()
	NetBus.stop()
	print("RECEIVE BUDGET OK deferred reliable order, callback-only polling and stale backlog recovery")
