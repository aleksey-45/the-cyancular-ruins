extends "res://tests/case.gd"

func run(tree: SceneTree) -> void:
	_input()
	_codec(tree)
	_playback()

func _input() -> void:
	var buffer := InputBuffer.new()
	var record := InputBuffer.neutral().merged({"seq": 1, "target_tick": 100, "ax": 1.0, "held": ActorInput.BIT_ATTACK}, true)
	var action := record.merged({"pressed": ActorInput.BIT_UP}, true)
	buffer.push({"frames": [record], "actions": [action]}, 99)
	var first := buffer.take(100)
	expect(first["ax"] == 1.0 and first["pressed"] == ActorInput.BIT_UP, "input/action consumed at target tick")
	buffer.push({"frames": [record], "actions": [action]}, 100)
	expect(buffer.take(101)["pressed"] == 0, "redundant action does not fire twice")
	expect(buffer.take(100 + InputBuffer.HOLD_TICKS)["held"] != 0, "held input survives its allowed window")
	var expired := buffer.take(101 + InputBuffer.HOLD_TICKS)
	expect(expired["ax"] == 0.0 and expired["held"] == 0, "expired input becomes neutral")
	buffer.restore_authority(1, 1, 1, record, 120)
	expect(buffer.take(121)["held"] == 0, "expired authority seed cannot revive held input")
	buffer.reset(2)
	buffer.push({"frames": [record], "actions": [action]}, 100)
	expect(buffer.take(101)["pressed"] == 0 and buffer.ack == 0, "old epoch is ignored")
	buffer.reset(1)
	buffer.push({"frames": [], "actions": [action]}, 100 + InputBuffer.ACTION_TICKS)
	expect(buffer.take(101 + InputBuffer.ACTION_TICKS)["pressed"] == 0 and buffer.action_ack == 1, "late action is acknowledged without execution")
	var codec := NetCodec.new()
	var wire := codec.encode_input({"frames": [record], "actions": [action]})
	var stream := _body(wire, NetCodec.INPUT)
	var decoded := codec.decode_input(stream)
	expect(decoded["frames"][0]["target_tick"] == 100 and decoded["actions"][0]["pressed"] == ActorInput.BIT_UP,
			"input wire preserves scheduling and action edges")
	expect(stream.get_available_bytes() == 0, "input decoder consumes packet")
	wire = codec.encode_event(NetEvent.Kind.START, null)
	expect(wire.size() == 1, "START has no obsolete bot payload")
	stream = _body(wire, NetCodec.EVENT + NetEvent.Kind.START)
	expect(codec.decode_event(NetEvent.Kind.START, stream) == null and stream.get_available_bytes() == 0, "START round trip")

func _codec(tree: SceneTree) -> void:
	var parent := world(tree)
	var authority := AuthorityWorld.new()
	authority.players = {1: player(parent, 1), 2: player(parent, 2)}
	var servers := [NetCodec.new(), NetCodec.new()]
	var clients := [NetCodec.new(), NetCodec.new()]
	authority._snap_tick = 100
	var captured := authority.world_state()
	var frames := [authority.state_for(1, captured), authority.state_for(2, captured)]
	var batch := NetCodec.StateBatch.new(frames[0])
	var first_wires: Array[PackedByteArray] = []
	for i in 2:
		var wire: PackedByteArray = servers[i].encode_state(frames[i], batch)
		first_wires.append(wire)
		var decoded := _state(clients[i], wire)
		expect(decoded["world"]["players"][i + 1]["pos"] == authority.players[i + 1].position, "full STATE position")
		# A caller may mutate its decoded copy; subsequent deltas must use intact history.
		decoded["world"]["players"][1]["pos"] = Vector2(-999, -999)
		decoded["own"]["state"]["inv"][0]["mag"] = -999
	servers[0].state_ack = clients[0].state_ack
	# Peer 2 still needs a full frame; common bytes must not mix its baseline with peer 1.
	authority.players[1].position += Vector2(8, 0)
	authority._snap_tick = 102
	captured = authority.world_state()
	captured["projectiles"] = {123: {"type_id": WeaponRegistry.all_ids()[0], "pos": Vector2(10, 20),
			"vel": Vector2(30, 0), "traveled": 40.0, "fuse_active": false, "fuse_elapsed": 0.0,
			"fuse_duration": 0.0, "direct_hit": false}}
	frames = [authority.state_for(1, captured), authority.state_for(2, captured)]
	batch = NetCodec.StateBatch.new(frames[0])
	for i in 2:
		var wire: PackedByteArray = servers[i].encode_state(frames[i], batch)
		var decoded := _state(clients[i], wire)
		var independent := _state(NetCodec.new(), NetCodec.new().encode_state(frames[i], NetCodec.StateBatch.new(frames[i])))
		expect(decoded == independent, "mixed baselines and caller mutation equal independent full STATE, peer %d" % (i + 1))
		if i == 0:
			var old_message := [0, 1, NetBus._wire(first_wires[0]), Time.get_ticks_usec()]
			var new_message := [0, 1, NetBus._wire(wire), Time.get_ticks_usec()]
			var event_message := [0, 1, NetBus._wire(servers[i].encode_event(NetEvent.Kind.START, null)), Time.get_ticks_usec()]
			var coalesced: Array = NetBus._coalesce_messages([new_message, old_message])
			expect(coalesced.size() == 1 and coalesced[0] == new_message, "late STATE cannot replace a newer queued state")
			expect(NetBus._coalesce_messages([old_message, event_message, new_message]).size() == 3, "events form a receive-side STATE coalescing barrier")
			var missing := NetCodec.new()
			expect(_state(missing, wire).is_empty() and missing.state_ack == 0, "missing baseline requests a full STATE")
		servers[i].state_ack = clients[i].state_ack
	authority._snap_tick = 104
	captured = authority.world_state()
	frames = [authority.state_for(1, captured), authority.state_for(2, captured)]
	batch = NetCodec.StateBatch.new(frames[0])
	for i in 2:
		var decoded := _state(clients[i], servers[i].encode_state(frames[i], batch))
		expect(decoded["world"]["projectiles"].is_empty(), "removed projectiles disappear from delta")
	authority.free()

func _playback() -> void:
	var playback := SnapshotBuffer.new()
	playback.map_px = Vector2(512, 256)
	var a := {"players": {2: {"pos": Vector2(508, 100), "vel": Vector2(60, 0), "epoch": 1}}, "pickups": {}}
	var b := {"players": {2: {"pos": Vector2(4, 100), "vel": Vector2(60, 0), "epoch": 1}}, "pickups": {}}
	playback.push(10, a)
	playback.push(12, b)
	var shown := playback.sample(11)
	expect(shown["players"][2]["pos"].is_equal_approx(Vector2(0, 100)), "playback interpolates across map seam")
	shown["players"][2]["pos"] = Vector2(99, 99)
	expect(playback.sample(11)["players"][2]["pos"].is_equal_approx(Vector2(0, 100)), "presentation edits do not mutate buffered positions")
	expect(a["players"][2]["pos"] == Vector2(508, 100), "sampling leaves source snapshot intact")

func _body(wire: PackedByteArray, type: int) -> StreamPeerBuffer:
	var stream := StreamPeerBuffer.new()
	stream.data_array = wire
	expect(stream.get_u8() == type, "packet type")
	return stream

func _state(codec: NetCodec, wire: PackedByteArray) -> Dictionary:
	var stream := _body(wire, NetCodec.STATE)
	var decoded := codec.decode_state(stream)
	if not decoded.is_empty(): expect(stream.get_available_bytes() == 0, "STATE decoder consumes packet")
	return decoded
