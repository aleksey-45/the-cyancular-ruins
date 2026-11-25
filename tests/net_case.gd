extends "res://tests/case.gd"

class LobbySession extends RoomSession:
	var messages: Array[String] = []
	var terrain_patches := 0

	# 房间规则用例直接传入事件，物理帧仍由场景树驱动。
	func _ready() -> void:
		pass

	func message(_peer: int, value: String) -> void: messages.append(value)

	func _broadcast(kind: int, data: Variant, except_role := 0) -> void:
		terrain_patches += int(kind == NetEvent.Kind.TERRAIN)
		super(kind, data, except_role)

func run(tree: SceneTree) -> void:
	_input()
	_input_schedule()
	_clock_steps()
	_lobby()
	_room_admission()
	_royale_capacity()
	_tunnel_parsing()
	_team_room()
	await _ready_flow(tree, false)
	await _ready_flow(tree, true)
	_codec()
	_event_records()
	_malformed_packets()

func _input() -> void:
	var buffer := InputBuffer.new()
	var record := [1, 1, 100, 1.0, ActorInput.BIT_ATTACK, Vector2.RIGHT]
	var action := [1, 1, 100, ActorInput.BIT_UP, 0, 0, Vector2.LEFT]
	var packet := [[record], [action]]
	buffer.push(packet, 99)
	var first := buffer.take(100)
	expect(first[ActorInput.AX] == 1.0 and first[ActorInput.PRESSED] == ActorInput.BIT_UP
			and first[ActorInput.AIM] == Vector2.LEFT, "input/action consumed at target tick with the action's aim")
	buffer.push(packet, 100)
	var second := buffer.take(101)
	expect(second[ActorInput.PRESSED] == 0 and second[ActorInput.AIM] == Vector2.RIGHT,
			"redundant action does not fire twice or replace the held input's aim")
	expect(buffer.take(100 + InputBuffer.HOLD_TICKS)[ActorInput.HELD] != 0, "held input survives its allowed window")
	var expired := buffer.take(101 + InputBuffer.HOLD_TICKS)
	expect(expired[ActorInput.AX] == 0.0 and expired[ActorInput.HELD] == 0, "expired input becomes neutral")
	buffer.restore_authority(1, 1, record)
	var restored := buffer.take(121)
	expect(restored[ActorInput.HELD] == 0 and buffer._last[InputBuffer.SEQ] == 1,
			"expired authority input keeps its sequence")
	expect(record[InputBuffer.FRAME_HELD] == ActorInput.BIT_ATTACK, "restoring expired input leaves the baseline frame intact")
	var confirmed := [2, 1, 122, 0.0, 0, Vector2.RIGHT]
	var confirmed_edge := [2, 1, 122, ActorInput.BIT_UP, 0, 0, Vector2.RIGHT]
	var future_edge := [3, 1, 123, ActorInput.BIT_RELOAD, 0, 0, Vector2.RIGHT]
	buffer.push([[confirmed], [confirmed_edge, future_edge]], 121)
	buffer.acknowledge(2, confirmed)
	expect(buffer.consumed_seq == 2 and buffer.take(122)[ActorInput.PRESSED] == 0
			and buffer.take(123)[ActorInput.PRESSED] == ActorInput.BIT_RELOAD,
			"acknowledging live prediction skips a confirmed queued action and retains later input")
	buffer.acknowledge(1, record)
	expect(buffer.consumed_seq == 2 and buffer.action_ack == 3, "an older acknowledgment keeps predicted input progress")
	buffer.reset(2)
	buffer.push(packet, 100)
	var ignored := buffer.take(101)
	expect(ignored[ActorInput.PRESSED] == 0 and buffer._last[InputBuffer.SEQ] == 0, "old epoch is ignored")
	buffer.reset(1)
	buffer.push([[], [action]], 100 + InputBuffer.ACTION_TICKS)
	expect(buffer.take(101 + InputBuffer.ACTION_TICKS)[ActorInput.PRESSED] == 0 and buffer.action_ack == 1,
			"late action is acknowledged without execution")
	var codec := NetCodec.new()
	codec.state_ack = 0x5060708
	var aim := Vector2(0.25, -0.5)
	var wire_packet := [
		[[12, 7, 100, -0.5, ActorInput.BIT_REWIND, aim], [13, 7, 101, 1.0, ActorInput.BIT_REWIND, aim],
				[14, 7, 101, 1.0, ActorInput.BIT_REWIND, aim]],
		[[12, 7, 100, ActorInput.BIT_PICKUP | ActorInput.BIT_CHARGE_RIGHT, ActorInput.BIT_ATTACK, 0x1020304, Vector2.DOWN]],
	]
	var wire := codec.encode_input(wire_packet)
	var protocol_bytes := ("c726000807060507000000030c0000000f58000000000000000000e0bf00010000803e000000bf"
			+ "0d00000002000000000000f03f0e0000000157000000010c000000640000002002080004030201000000000000803f")
	expect(NetBus._wire(wire).hex_encode() == protocol_bytes, "INPUT encodes packet-local phase deltas and a self-contained action tick")
	var stream := _body(wire, NetCodec.INPUT)
	expect(codec.decode_input(stream) == wire_packet and stream.remaining() == 0,
			"both held samples and edges preserve the originally committed tick")
	var other := NetCodec.new()
	var sparse := [[], [[1, 7, 3000, ActorInput.BIT_DROP, 0, 37, Vector2.LEFT]]]
	expect(other.decode_input(_body(codec.encode_input(sparse), NetCodec.INPUT)) == sparse,
			"an old edge is independently decodable without any frame or preceding packet")
	codec.state_ack = 123
	for length in range(wire.size() - 8, wire.size()):
		var truncated := NetCodec.Reader.new(wire.slice(0, length), 1)
		expect(codec.decode_input(truncated).is_empty() and not truncated.valid and codec.state_ack == 123,
				"partial INPUT does not commit its snapshot ACK")
	var missing_target := wire.duplicate()
	missing_target[14] &= ~1 # 第一个样本的增量掩码必须含完整偏移。
	var invalid := NetCodec.Reader.new(missing_target, 1)
	expect(codec.decode_input(invalid).is_empty() and not invalid.valid and codec.state_ack == 123,
			"an incomplete first sample cannot decode a target or advance the ACK")
	wire = codec.encode_event(NetEvent.Kind.START, null)
	expect(wire.size() == 1, "START has no obsolete bot payload")
	stream = _body(wire, NetCodec.EVENT + NetEvent.Kind.START)
	expect(codec.decode_event(NetEvent.Kind.START, stream) == null and stream.remaining() == 0, "START round trip")

func _input_schedule() -> void:
	var scheduler := InputScheduler.new()
	var buffer := InputBuffer.new()
	var row := [1, 1, 105, 1.0, 0, Vector2.RIGHT]
	var edge := [1, 1, 105, ActorInput.BIT_UP, 0, 0, Vector2.RIGHT]
	expect(scheduler.submit(buffer, [[row], [edge]], 100), "the authority accepts a valid client commitment")
	var conflict := row.duplicate()
	conflict[InputBuffer.TARGET_TICK] = 102
	scheduler.submit(buffer, [[conflict], [edge]], 101)
	expect(buffer.take(104)[ActorInput.AX] == 0.0, "a conflicting repeat cannot move a queued sample forward")
	var input := buffer.take(105)
	expect(input[ActorInput.AX] == 1.0 and input[ActorInput.PRESSED] == ActorInput.BIT_UP
			and buffer.take(106)[ActorInput.PRESSED] == 0, "early input and duplicate edge execute once at P")
	edge = [2, 1, 105, ActorInput.BIT_DROP, 0, 0, Vector2.RIGHT]
	scheduler.submit(buffer, [[], [edge]], 106)
	expect(buffer.take(107)[ActorInput.PRESSED] == ActorInput.BIT_DROP and edge[InputBuffer.TARGET_TICK] == 105,
			"late input executes at availability and keeps its original age")
	expect(not scheduler.submit(buffer, [[[3, 1, 107, 0.0, 0, Vector2.RIGHT]], []], 200),
			"a stalled input clock requests a fresh epoch")
	buffer.reset(2)
	scheduler = InputScheduler.new()
	scheduler.submit(buffer, [[row], [edge]], 200)
	expect(scheduler.feedback.is_empty(), "old epoch input cannot seed a new controller")
	for seq in range(1, 241):
		var target := seq + 200
		var at := target - 1 + int(seq > 140) * 3
		row = [seq, 2, target, 1.0, 0, Vector2.RIGHT]
		scheduler.submit(buffer, [[row], []], at)
		scheduler.submit(buffer, [[row], []], at + 1)
		buffer.take(at + 1)
	var clock := InputClock.new()
	var neutral := [0.0, 0, 0, 0, 0, Vector2.RIGHT]
	clock.reset(440, 240, 0, scheduler.feedback)
	var target := clock.sample(241, neutral)
	expect(target == 444, "first-copy feedback follows a persistent upstream step across duplicate packets")

	var sender := NetCodec.new()
	var receiver := NetCodec.new()
	var host := arena(WorldSpec.DUEL, [1, 2], {}, {})
	var frame := host.packet({})
	var feedback := PackedByteArray([0, 11, 0xff])
	_state(receiver, sender.encode_state(feedback, NetCodec.StateBatch.new(frame)))
	sender.state_ack = receiver.state_ack
	sender.encode_state(PackedByteArray([6, 7, 8, 9, 10]), NetCodec.StateBatch.new(frame))
	feedback = PackedByteArray([251])
	expect(_state(receiver, sender.encode_state(feedback, NetCodec.StateBatch.new(frame)))["input_feedback"] == feedback,
			"STATE relays opaque scheduling feedback even across a lost report")
	host.close()

	clock.reset(98, 0, 0, PackedByteArray())
	var previous := 100
	var last_change := -100
	var spaced := true
	var repeated := InputClock.pack_feedback(1, 103, 103)
	for seq in range(1, 221):
		clock.synchronize(0, seq - 1, repeated if seq % 2 else PackedByteArray())
		target = clock.sample(seq, neutral)
		var end := clock.advance(ActorStep.DT, previous, 1000)
		if end != previous + 1:
			spaced = spaced and seq - last_change >= 6 and target == previous + 2
			last_change = seq
		previous = end
	expect(spaced and previous - 220 == 103, "spaced catch-up settles at a repeated absolute target exactly once")
	clock.synchronize(0, 220, InputClock.pack_feedback(220, 100, 100))
	clock.synchronize(0, 220, repeated)
	var unknown := InputClock.pack_feedback(300, 140, 140)
	unknown[-1] = 0xff
	clock.synchronize(0, 220, unknown)
	var protected := true
	for seq in range(221, 321):
		target = clock.sample(seq, [0.0, 0, ActorInput.BIT_UP, 0, 0, Vector2.RIGHT])
		var end := clock.advance(ActorStep.DT, previous, 1000)
		protected = protected and end == previous + 1 and target == end
		previous = end
	expect(protected, "a new button edge is immediately simulated even when the clock needs to slow down")
	var monotone := true
	for seq in range(321, 521):
		var analog := [0.75 if seq % 2 == 0 else 0.8, 0, 0, 0, 0, Vector2.RIGHT]
		target = clock.sample(seq, analog)
		var end := clock.advance(ActorStep.DT, previous, 1000)
		monotone = monotone and target > previous and end >= previous
		previous = end
	expect(monotone and previous - 520 == 100, "small analog variations allow lead recovery without scheduling into the past")

func _clock_steps() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261122
	var optimal := true
	for trial in 128:
		var errors := PackedFloat64Array()
		for i in InputClock.SPACING:
			errors.append(rng.randf_range(-2.0, 2.0))
		var since := rng.randi_range(0, InputClock.SPACING)
		var protect := trial % 2 == 0
		var chosen := InputClock._choose_step(errors, since, protect)
		var best := INF
		var achieved := INF
		# 直接累加所有合法路径的逐步损失，包含全程匀速的路径。
		for slot in range(-1, InputClock.SPACING):
			if slot >= 0 and since + slot < InputClock.SPACING:
				continue
			for direction: int in [-1, 1]:
				if slot == 0 and protect and direction < 0:
					continue
				var cost := 0.0
				for k in InputClock.SPACING:
					var movement := direction if slot >= 0 and k >= slot else 0
					cost += (errors[k] - movement) ** 2
				best = minf(best, cost)
				if chosen == (direction if slot == 0 else 0):
					achieved = minf(achieved, cost)
		optimal = optimal and is_equal_approx(best, achieved)
	expect(optimal, "clock chooses a minimum-cost feasible first step for every reference path")

func _lobby() -> void:
	var codec := NetCodec.new()
	var join := {"code": "00048213", "beta": true}
	var wire := codec.encode_event(NetEvent.Kind.JOIN, join)
	var stream := _body(wire, NetCodec.EVENT + NetEvent.Kind.JOIN)
	expect(wire.size() == 6 and codec.decode_event(NetEvent.Kind.JOIN, stream) == join,
			"JOIN preserves leading-zero room code and gameplay selection")
	expect(stream.remaining() == 0, "JOIN consumes its complete payload")
	var rules := TimeRules.normalized({"initial": 1200.25, "cap": 100.0, "regen": NAN,
			"damage_gain": 500, "unused": true})
	expect(rules["initial"] == 1200.25 and rules["cap"] == rules["initial"]
			and rules["regen"] == 50.0 and rules["damage_gain"] == 50 and not rules.has("unused"),
			"one validation pass bounds lobby rules and rejects non-finite values")
	var options := {"map": "res://maps/newfactory.cyrm", "max_players": 8, "match_time": 300,
			"round_full_heal": false, "disabled_weapons": WeaponRegistry.all_ids().slice(0, 1),
			"beta": true, "time": rules, "player_collision": true}
	var create := {"mode": PvpSession.MODE_ROYALE, "options": options}
	stream = _body(codec.encode_event(NetEvent.Kind.CREATE, create), NetCodec.EVENT + NetEvent.Kind.CREATE)
	expect(codec.decode_event(NetEvent.Kind.CREATE, stream) == create and stream.remaining() == 0,
			"CREATE round trip preserves room options")
	var session := LobbySession.new()
	session.code = join["code"]
	session.mode = PvpSession.MODE_ROYALE
	session.options = options
	session.seats = {1: {"name": "host", "team": 0, "peer": 1}, 2: {"name": "guest", "team": 0, "peer": 2}}
	var room := session.room_data()
	room.merge({"your_role": 2, "token": "01".repeat(16)})
	stream = _body(codec.encode_event(NetEvent.Kind.ROOM, room), NetCodec.EVENT + NetEvent.Kind.ROOM)
	var decoded: Dictionary = codec.decode_event(NetEvent.Kind.ROOM, stream)
	expect(stream.remaining() == 0 and decoded["players"] == room["players"]
			and decoded["code"] == room["code"] and decoded["your_role"] == 2
			and decoded["token"] == "01".repeat(16) and decoded["player_collision"],
			"ROOM preserves roster, options and rejoin credentials")
	expect(decoded["can_start"], "ROOM carries the server's start decision")
	expect(decoded["count"] == 2 and decoded["host_name"] == "host"
			and decoded["team_counts"] == {0: 2, 1: 0, 2: 0},
			"ROOM derives host and team counts from the roster")
	var listed := session.room_data()
	listed["in_match"] = true
	listed["player_collision"] = false
	for entry in [{}, listed]:
		stream = _body(codec.encode_event(NetEvent.Kind.ROOM_LIST, entry), NetCodec.EVENT + NetEvent.Kind.ROOM_LIST)
		var room_list: Dictionary = codec.decode_event(NetEvent.Kind.ROOM_LIST, stream)
		expect(stream.remaining() == 0 and room_list.is_empty() == entry.is_empty(),
				"the room list represents an empty or occupied endpoint")
		if not entry.is_empty():
			expect(room_list["players"] == listed["players"] and room_list["in_match"]
					and room_list["beta"] and not room_list["player_collision"],
					"ROOM_LIST preserves the room roster and mode")
	session._on_event(3, NetEvent.Kind.JOIN, join.merged({"beta": false}, true))
	expect(session.messages.back() == "该房间为「错乱大乱斗」，请从「Beta」进入" and session.seats.size() == 2,
			"gameplay mismatch names the Beta room and its entry without adding a seat")
	session.options["beta"] = false
	session._on_event(3, NetEvent.Kind.JOIN, join)
	expect(session.messages.back() == "该房间为「大乱斗」，请从「多人模式」进入" and session.seats.size() == 2,
			"gameplay mismatch names the regular room and its entry")
	session.free()

func _tunnel_parsing() -> void:
	expect(Tunnel.parse_peers_json("[]") == [], "an empty peer list is a valid response")
	for invalid in ["unavailable", "null", "{}", "42"]:
		expect(Tunnel.parse_peers_json(invalid) == null, "invalid or non-array CLI output is rejected")
	var peers: Array = Tunnel.parse_peers_json(
			'[{"hostname":"cyr-host-1024","ipv4":"invalid"},{"hostname":"cyr-host-54321","ipv4":"10.126.126.1"}]')
	expect(Tunnel.pick_host_peer(peers) == {"ipv4": "10.126.126.1", "port": 54321},
			"host lookup skips invalid addresses and reads the game port")
	expect(not Tunnel.start_host(65536, "01234567").is_empty(), "tunnel rejects an out-of-range host port")

func _room_admission() -> void:
	var session := LobbySession.new()
	var guest := {"name": "player", "hue": 0.0}
	var create := {"mode": PvpSession.MODE_PVP, "options": {}}
	session._on_event(11, NetEvent.Kind.CREATE, create)
	expect(session.code.is_empty() and session.seats.is_empty(), "CREATE before HELLO leaves the room empty")
	session._on_event(11, NetEvent.Kind.HELLO, guest)
	session._on_event(11, NetEvent.Kind.CREATE, create)
	expect(not session.code.is_empty() and session.role_of(11) == 1, "valid CREATE can be retried after HELLO")
	expect(not session.room_data()["player_collision"], "collision is disabled when CREATE omits the option")
	var join := {"code": session.code, "beta": false}
	session._on_event(11, NetEvent.Kind.JOIN, join)
	session._on_event(12, NetEvent.Kind.JOIN, join)
	expect(session.seats.size() == 1 and not session.room_data()["can_start"],
			"duplicate and unidentified JOIN requests do not reserve a second seat")
	session._on_event(12, NetEvent.Kind.HELLO, guest)
	session._on_event(12, NetEvent.Kind.JOIN, join)
	session.rejoin(11, session.code, session.seats[2]["token"])
	expect(session.room_data()["can_start"] and session.seats[2]["peer"] == 12,
			"a second identified peer may join and an existing peer cannot acquire that seat")
	session.free()

func _royale_capacity() -> void:
	var session := LobbySession.new()
	var guest := {"name": "player", "hue": 0.0}
	session._on_event(1, NetEvent.Kind.HELLO, guest)
	session._on_event(1, NetEvent.Kind.CREATE, {"mode": PvpSession.MODE_ROYALE,
			"options": {"map": "res://maps/newfactory.cyrm", "max_players": 16, "player_collision": true}})
	var join := {"code": session.code, "beta": false}
	for peer in range(2, 18):
		session._on_event(peer, NetEvent.Kind.HELLO, guest)
		session._on_event(peer, NetEvent.Kind.JOIN, join)
	expect(session.seats.size() == 16 and session.role_of(16) == 16 and session.role_of(17) == 0,
			"Royale admits sixteen players and rejects a seventeenth")
	var roles := session.seats.keys()
	for path: String in ["res://maps/demo.cyrm", session.map_path()]:
		var host := arena(session.mode, roles, {}, session.options, path)
		var authority := host.world
		expect(authority.problem.is_empty(), "%s starts a sixteen-player Royale: %s" % [path, authority.problem])
		var sides := SpawnPicker.respawn_cells(authority.spec.map)
		var points: Array = sides[1] + sides[2]
		expect(players_on_map_points(authority, roles, points), "%s assigns sixteen distinct marked points" % path)
		authority.rules.phase = MatchRules.Phase.PLAYING
		authority.players[16].force_down()
		authority.players[16].respawn_tick = authority.tick + 1
		host.fixed_step()
		expect(players_on_map_points(authority, [16], points), "%s revives the sixteenth player on a marked point" % path)
		var sender := NetCodec.new()
		var receiver := NetCodec.new()
		var frame := host.packet({})
		var got := _state(receiver, sender.encode_state(PackedByteArray(), NetCodec.StateBatch.new(frame)))
		expect(got == frame and got["checkpoint"]["players"].size() == 16, "full state delivers all sixteen players")
		sender.state_ack = receiver.state_ack
		authority.players[16].position.x += 16.0
		frame = host.packet({})
		got = _state(receiver, sender.encode_state(PackedByteArray(), NetCodec.StateBatch.new(frame)))
		expect(got == frame, "delta state delivers an update for the sixteenth player")
		host.close()
	session.free()

func _codec() -> void:
	var mode := WorldSpec.ROYALE
	var host := arena(mode, [1, 2], {}, RoomOptions.normalized(mode, {"beta": true, "time": {"cap": 1800.25}}))
	var world := host.world
	world.rules.phase = MatchRules.Phase.PLAYING
	var actor := world.players[1]
	actor.weapons.set_initial_inventory([WeaponRegistry.Type.GRENADE])
	var sender := NetCodec.new()
	var receiver := NetCodec.new()
	var sibling := NetCodec.new()
	var aim := Vector2(0.6, 0.8)
	var feedback := InputClock.pack_feedback(1, 4.0, 4.75, 0.05)
	for at in range(1, 11):
		var fire := ActorInput.BIT_ATTACK if at == 1 else 0
		host.fixed_step({1: [0.0, 0, 0, fire, 0, aim]})
	world.personal_time.accounts[1].restore_state([72.125, 250.0, 17.75, true])
	var frame := host.packet({2: 59.75})
	frame["input_feedback"] = feedback
	var batch := NetCodec.StateBatch.new(frame)
	var full := sender.encode_state(feedback, batch)
	var independent := sibling.encode_state(PackedByteArray(), batch)
	expect(batch.deltas.size() == 1 and independent != full, "full state fanout shares the world payload")
	expect(_state(receiver, full) == frame, "complete state preserves equipment, live grenade, history and account")

	var first_ack := receiver.state_ack
	sender.state_ack = first_ack
	sibling.state_ack = 1
	for at in range(11, 17):
		host.fixed_step({1: [1.0, ActorInput.BIT_REWIND if at < 14 else 0, 0, 0, 0, aim]})
	var next := host.packet({})
	batch = NetCodec.StateBatch.new(next)
	var delta := sender.encode_state(PackedByteArray(), batch)
	expect(delta.size() < full.size(), "a recent acknowledged base only needs changed state and history rows")
	expect(_state(receiver, delta) == next, "delta reconstructs the complete state after history sampling")
	expect(_state(receiver, full).is_empty(), "an out-of-order state cannot replace a newer one")
	var no_base := NetCodec.new()
	no_base.state_ack = first_ack
	expect(_state(no_base, delta).is_empty() and no_base.state_ack == 0, "a lost base requests a complete state")
	expect(sender.decode_input(_body(receiver.encode_input([[], []]), NetCodec.INPUT)) == [[], []]
			and sender.state_ack == receiver.state_ack, "input acknowledges the adopted codec sequence")

	world.personal_time.accounts[1].locked = false
	world.personal_time.accounts[1].balance = 240.0
	host.fixed_step({1: [0.0, ActorInput.BIT_REWIND, 0, 0, 0, aim]})
	var rewound := host.packet({})
	var branch := sender.encode_state(PackedByteArray(), NetCodec.StateBatch.new(rewound))
	expect(_state(receiver, branch) == rewound, "delta removes the abandoned suffix when a skill rewinds")
	var fresh := NetCodec.new()
	var baseline := {"code": "12345678", "mode": mode, "role": 1, "roles": world.spec.roles,
		"seed": world.spec.seed, "teams": {}, "options": world.spec.options, "names": {1: "A", 2: "B"},
		"hues": {1: 0.0, 2: 22.0}, "map": CyrmMap.read_bytes("res://maps/newfactory.cyrm"),
		"sub_hp": world.terrain.get_modified(), "frame": rewound}
	var wire := sender.encode_event(NetEvent.Kind.BASELINE, baseline)
	expect(fresh.decode_event(NetEvent.Kind.BASELINE, _body(wire, NetCodec.EVENT + NetEvent.Kind.BASELINE)) == baseline,
			"a fresh decoder gets an independent logical checkpoint from BASELINE")
	expect(fresh.history.size() == 1, "BASELINE creates one codec reference")

	var offset := world.terrain.cell(actor.position)
	actor.position = world.terrain.cell_center(offset + Vector2i(2, 0))
	world.combat.clear()
	world.combat.submit_blast(ShotRules.shot_id(1, 8), actor.position, WeaponRegistry.Type.GRENADE)
	var ending := host.packet({})
	var end_wire := sender.encode_state(PackedByteArray(), NetCodec.StateBatch.new(ending))
	expect(_state(fresh, end_wire) == ending, "a projectile removal and a pending blast are separate state")
	host.close()

func _event_records() -> void:
	var codec := NetCodec.new()
	var records := {
		NetEvent.Kind.CREATE: {"mode": WorldSpec.ROYALE, "options": {
			"map": "res://maps/newfactory.cyrm", "max_players": 8, "match_time": 300,
			"round_full_heal": false, "disabled_weapons": [1, 5], "beta": true,
			"time": TimeRules.normalized({"cap": 1800.25}), "player_collision": false}},
		NetEvent.Kind.TERRAIN: {"version": 9, "cells": {Vector2i(34, 1): 0, Vector2i(2, 10): 4}},
	}
	for kind: int in records:
		var wire := codec.encode_event(kind, records[kind])
		expect(codec.decode_event(kind, NetCodec.Reader.new(wire, 1)) == records[kind],
				"event %d decodes to the original record" % kind)

func _malformed_packets() -> void:
	var codec := NetCodec.new()
	codec.state_ack = 42
	var short_input := NetCodec.Reader.new(PackedByteArray([100, 0, 0, 0]))
	expect(codec.decode_input(short_input).is_empty() and not short_input.valid and codec.state_ack == 42,
			"invalid INPUT does not acknowledge a snapshot")
	var short_terrain := NetCodec.Reader.new(PackedByteArray([9, 0, 0, 0, 255, 255, 255, 255]))
	expect(codec.decode_event(NetEvent.Kind.TERRAIN, short_terrain) == null and not short_terrain.valid,
			"TERRAIN rejects a cell count larger than the remaining packet")
	var bad_mode := NetCodec.Reader.new(PackedByteArray([255, 0, 0]))
	expect(codec.decode_event(NetEvent.Kind.CREATE, bad_mode) == null and not bad_mode.valid,
			"CREATE rejects an unknown mode before indexing the mode table")

	var received: Array[int] = []
	var stamps: Array[int] = []
	var stamp := func(_peer: int, _packet: Array, us: int) -> void: stamps.append(us)
	NetBus.input_received.connect(stamp)
	var listen := func(_peer: int, kind: int, _data: Variant) -> void: received.append(kind)
	NetBus.event_received.connect(listen)
	var was_server: bool = NetBus.is_server_mode
	NetBus.is_server_mode = true
	NetBus._receive(999, PackedByteArray([NetCodec.WIRE_MAGIC, 17, NetCodec.EVENT + NetEvent.Kind.START]), 0)
	var patch := {"version": 9, "cells": {Vector2i.ZERO: 0}}
	NetBus._receive(999, NetBus._wire(codec.encode_event(NetEvent.Kind.TERRAIN, patch)), 0)
	NetBus._receive(999, NetBus._wire(codec.encode_event(NetEvent.Kind.START, null)), 0)
	NetBus._receive(999, NetBus._wire(codec.encode_input([[], []])), 123456)
	NetBus.is_server_mode = was_server
	NetBus._codecs.erase(999)
	NetBus.event_received.disconnect(listen)
	NetBus.input_received.disconnect(stamp)
	expect(stamps == [123456], "INPUT dispatch preserves the native receipt timestamp")
	expect(received == [NetEvent.Kind.START], "server dispatches valid client commands from the current protocol only")

func _body(wire: PackedByteArray, type: int) -> NetCodec.Reader:
	expect(not wire.is_empty() and wire[0] == type, "packet type")
	return NetCodec.Reader.new(wire, 1)

func _state(codec: NetCodec, wire: PackedByteArray) -> Dictionary:
	var stream := _body(wire, NetCodec.STATE)
	var decoded := codec.decode_state(stream)
	if not decoded.is_empty(): expect(stream.remaining() == 0, "STATE decoder consumes packet")
	return decoded

## 覆盖组队房间的加入、换队与开局检查，包括每队人数上限。
func _team_room() -> void:
	var session := LobbySession.new()
	session.mode = PvpSession.MODE_TEAM
	session.options = {"map": "res://maps/demo.cyrm"}
	expect(session.max_players() == 10, "team rooms accept up to 10 players")
	for i in 10:
		session.guests[100 + i] = {"name": "p%d" % i, "hue": 0.0}
		session.add_seat(100 + i)
	expect(session.team_count(1) == 5 and session.team_count(2) == 5,
			"new seats balance 5/5 and ties go to team A first")
	expect(session.team_ready(), "a full 5v5 roster is ready")
	var team_b_role := 6
	var peer_b: int = session.seats[team_b_role]["peer"]
	session._pick_team(peer_b, team_b_role, 1)
	expect(session.messages.back().contains("已满"), "switching into a full team reports a message")
	session._pick_team(peer_b, team_b_role, 3)
	expect(session.messages.back().contains("A 队或 B 队"), "only team 1 or 2 is accepted")
	session.seats[3]["peer"] = 0
	expect(not session.team_ready(), "an offline seat blocks the team start")
	expect(not session.room_data()["can_start"], "ROOM reports that the offline seat blocks starting")
	session.seats[3]["peer"] = 103
	session.free()
	var small := LobbySession.new()
	small.mode = PvpSession.MODE_TEAM
	small.options = {}
	for role in range(1, 7):
		small.seats[role] = {"peer": role, "token": "", "name": "p%d" % role, "hue": 0.0,
				"team": 1 if role <= 5 else 2, "deadline": 0.0}
	expect(small.team_ready(), "a 5v1 roster satisfies the team start condition")
	small.seats[6]["team"] = 1
	expect(small.team_count(2) == 0, "a roster without both teams cannot start")
	small.free()


func _ready_flow(tree: SceneTree, beta: bool) -> void:
	var session := LobbySession.new()
	tree.root.add_child(session)
	session.code = "12345678"
	session.mode = PvpSession.MODE_TEAM
	session.options = RoomOptions.normalized(session.mode, {"map": "res://maps/demo.cyrm", "beta": beta})
	session.guests = {11: {"name": "A", "hue": 0.0}, 12: {"name": "B", "hue": 0.5}}
	session.add_seat(11)
	session.add_seat(12)
	session.options["disabled_weapons"] = WeaponRegistry.all_ids()
	session.start_match()
	expect(session.world == null and not session.messages.is_empty(), "a rejected start leaves the room idle")
	await tree.physics_frame
	session.options["disabled_weapons"] = []
	session.start_match()
	await tree.physics_frame
	var tick := session.world.tick
	await tree.physics_frame
	expect(session.world.tick == tick + 1, "the room advances the match once per physics frame")
	session._on_event(11, NetEvent.Kind.READY, 2)
	expect(not session.seats[1]["ready"], "READY for another round is ignored")
	session._on_event(99, NetEvent.Kind.READY, 1)
	expect(not session.seats[1]["ready"], "READY from an unseated peer is ignored")
	session._on_event(11, NetEvent.Kind.READY, 1)
	expect(session.seats[1]["ready"], "READY confirms the current baseline")
	expect(session.world.rules.phase == MatchRules.Phase.WAITING, "WAITING is kept until every seat is ready")
	session._on_event(12, NetEvent.Kind.READY, 1)
	var rules := session.world.rules
	expect(rules.phase == MatchRules.Phase.WAITING, "READY leaves the countdown to the fixed step")
	await tree.physics_frame
	expect(rules.phase == MatchRules.Phase.COUNTDOWN and is_equal_approx(rules.round_timer, 3.0 - ActorStep.DT),
			"the last READY starts the countdown on the fixed step")
	var remaining := rules.round_timer
	session._on_event(12, NetEvent.Kind.READY, 1)
	await tree.physics_frame
	expect(rules.phase == MatchRules.Phase.COUNTDOWN and rules.round_timer < remaining,
			"a repeated READY does not restart the countdown")
	rules.round_timer = ActorStep.DT
	await tree.physics_frame
	var token: String = session.seats[2]["token"]
	session.rejoin(12, session.code, token)
	session._on_event(12, NetEvent.Kind.READY, 1)
	expect(session.seats[2]["ready"] and rules.phase == MatchRules.Phase.PLAYING,
			"a reconnect READY only restores its own data sending")

	var terrain := session.world.terrain
	var hp := terrain.get_hp(Vector2i.ZERO)
	terrain.apply_at(terrain.version, {Vector2i.ZERO: hp + 1})
	await tree.physics_frame
	var patches := session.terrain_patches
	session.rejoin(12, session.code, token)
	rules.phase = MatchRules.Phase.ROUND_OVER
	rules.round_timer = ActorStep.DT
	rules.round_winner = 1
	rules.rounds_won[1] = 1
	await tree.physics_frame
	expect(rules.round_number == 2 and session.seats[1]["peer"] == 11 and not session.seats[1]["ready"],
			"a new round sends a fresh baseline on the existing connection")
	expect(terrain.get_hp(Vector2i.ZERO) == hp and session._published_terrain == terrain.version
			and patches > 0 and session.terrain_patches == patches,
			"the new baseline replaces the terrain reset patch and advances the publication cursor")
	terrain = null
	session._on_event(12, NetEvent.Kind.READY, 1)
	expect(not session.seats[2]["ready"], "a reconnect READY for the old round leaves the new baseline pending")
	session._on_event(11, NetEvent.Kind.READY, 2)
	await tree.physics_frame
	expect(rules.phase == MatchRules.Phase.WAITING, "the new round waits for its own acknowledgments")
	session._on_event(12, NetEvent.Kind.READY, 2)
	await tree.physics_frame
	expect(rules.phase == MatchRules.Phase.COUNTDOWN, "both new round acknowledgments start the countdown")
	rules.round_timer = ActorStep.DT
	await tree.physics_frame

	session.remove_seat(2)
	expect(rules.phase == MatchRules.Phase.PLAYING, "leaving queues a world command")
	await tree.physics_frame
	var result := arena_round(session.world)
	tick = session.world.tick
	await tree.physics_frame
	expect(rules.phase == MatchRules.Phase.MATCH_OVER and session.world.tick == tick
			and arena_round(session.world) == result, "the room keeps the final result at the last simulated tick")
	var old_match: WeakRef = weakref(session.world)
	var body: WeakRef = weakref(session.world.players[1])
	var space: WeakRef = weakref(session.world.terrain.physics.world)
	session._on_event(11, NetEvent.Kind.LEAVE, null)
	expect(session.world == null and old_match.get_ref() == null and body.get_ref() == null and space.get_ref() == null,
			"returning to the room releases the match, player and physics world")

	session.add_seat(12)
	session.start_match()
	expect(session.world.tick == 0 and session.world.rules.phase == MatchRules.Phase.WAITING,
			"the same room can open a fresh match")
	session.remove_seat(2)
	expect(session.world == null, "an expiring seat cancels the unstarted match")
	session.add_seat(12)
	session.start_match()
	old_match = weakref(session.world)
	session.free()
	expect(old_match.get_ref() == null, "closing a room releases its active match")
