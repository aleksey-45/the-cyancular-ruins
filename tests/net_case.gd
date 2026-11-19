extends "res://tests/case.gd"

const NetPlayer := PlayerStateSchema.Network
const Sample := SnapshotBuffer.Sample
const POS: int = PlayerStateSchema.POS
const VEL: int = PlayerStateSchema.VEL

static func _actor(pos: Vector2, epoch := 1, rewind := false) -> Array:
	var record: Array = []
	record.resize(PlayerStateSchema.SIZE)
	record[POS] = pos
	record[VEL] = Vector2(60, 0)
	record[PlayerStateSchema.KNOCK_VEL] = Vector2.ZERO
	record[PlayerStateSchema.EQUIPMENT] = []
	return [epoch, 0, rewind, 0, Vector2.RIGHT, [], record]

class LobbySession extends RoomSession:
	var messages: Array[String] = []

	# 房间规则用例直接传入事件，物理帧仍由场景树驱动。
	func _ready() -> void:
		pass

	func message(_peer: int, value: String) -> void: messages.append(value)

func run(tree: SceneTree) -> void:
	_input()
	_input_schedule()
	_lobby()
	_room_admission()
	_royale_capacity()
	_tunnel_parsing()
	_team_room()
	await _ready_flow(tree)
	_codec(tree)
	_event_records()
	_combat_events(tree)
	_projectile_deltas()
	_malformed_packets()
	_playback()

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
		[[12, 7, 100, ActorInput.BIT_PICKUP, ActorInput.BIT_ATTACK, 0x1020304, Vector2.DOWN]],
	]
	var wire := codec.encode_input(wire_packet)
	var protocol_bytes := ("c721000807060507000000030c00000007000000000000e0bf00010000803e000000bf"
			+ "0d00000001000000000000f03f0e00000000010c0000002000080004030201000000000000803f")
	expect(NetBus._wire(wire).hex_encode() == protocol_bytes, "INPUT header, frame deltas and actions match the wire format")
	var stream := _body(wire, NetCodec.INPUT)
	var decoded := codec.decode_input(stream)
	for group: Array in wire_packet:
		for row: Array in group:
			row[InputBuffer.TARGET_TICK] = 0
	expect(decoded == wire_packet, "INPUT preserves controls and edges, authority supplies the target tick")
	expect(stream.remaining() == 0, "input decoder consumes packet")
	var reported := wire_packet + [Vector2i(0x01020304, -5)]
	var feedback_wire := codec.encode_input(reported)
	expect(feedback_wire.slice(0, wire.size()) == wire and feedback_wire.slice(wire.size()).hex_encode() == "04030201fb"
			and codec.decode_input(_body(feedback_wire, NetCodec.INPUT)) == reported, "optional input report costs five bytes and preserves a signed margin")
	codec.state_ack = 123
	for length in range(wire.size() + 1, feedback_wire.size()):
		var truncated := NetCodec.Reader.new(feedback_wire.slice(0, length), 1)
		expect(codec.decode_input(truncated).is_empty() and not truncated.valid and codec.state_ack == 123,
				"partial notice does not commit the packet ACK")
	wire = codec.encode_event(NetEvent.Kind.START, null)
	expect(wire.size() == 1, "START has no obsolete bot payload")
	stream = _body(wire, NetCodec.EVENT + NetEvent.Kind.START)
	expect(codec.decode_event(NetEvent.Kind.START, stream) == null and stream.remaining() == 0, "START round trip")

func _input_schedule() -> void:
	var scheduler := InputScheduler.new()
	var buffer := InputBuffer.new()
	var row := [1, 1, 9999, 1.0, 0, Vector2.RIGHT]
	var edge := [1, 1, -50, ActorInput.BIT_UP, 0, 0, Vector2.RIGHT]
	var packet := [[row], [edge]]
	scheduler.submit(buffer, packet, 100, 123000)
	scheduler.submit(buffer, packet, 101, 125000)
	expect(InputScheduler.target(scheduler.announcement(), 1) == 103 and buffer.take(102)[ActorInput.AX] == 0.0,
			"authority sets the first deadline from availability and a two-tick margin")
	var input := buffer.take(103)
	expect(input[ActorInput.AX] == 1.0 and input[ActorInput.PRESSED] == ActorInput.BIT_UP
			and buffer.take(104)[ActorInput.PRESSED] == 0 and row[InputBuffer.TARGET_TICK] == 9999,
			"continuous input and a repeated edge share the authority deadline without mutating the caller")
	row[InputBuffer.SEQ] = 2
	expect(not scheduler.submit(buffer, [[row], []], 200, 3000000), "a stalled input clock requests a fresh epoch")
	buffer.reset(2)
	scheduler = InputScheduler.new()
	scheduler.submit(buffer, packet, 201, 3016000)
	expect(scheduler.announcement() == InputScheduler.UNBOUND, "delayed packets cannot anchor a new epoch")
	scheduler.submit(buffer, [[[45, 2, 0, 1.0, 0, Vector2.RIGHT]], [[1, 2, 0, ActorInput.BIT_UP, 0, 0, Vector2.RIGHT]]],
			200, 3020000)
	expect(InputScheduler.target(scheduler.announcement(), 45) == 203 and buffer.take(203)[ActorInput.PRESSED] == 0
			and buffer.action_ack == 1, "an old retransmitted edge cannot shift the first continuous sample's anchor")
	var offsets := []
	offsets.resize(100)
	offsets.fill(0)
	offsets[0] = 1
	expect(InputScheduler._best_step(offsets, 0, 0, 0, 3) == 0, "one percent late is inside the deadline budget")
	offsets[1] = 1
	expect(InputScheduler._best_step(offsets, 0, 0, 0, 3) == 1, "one more tick recovers the excess misses")
	offsets[0] = 8
	offsets[1] = 8
	expect(InputScheduler._best_step(offsets, 0, 0, 0, 3) == 0, "unrecoverable misses do not buy an extra tick")
	offsets.fill(3)
	expect(InputScheduler._best_step(offsets, 0, 0, 0, 3) == 1, "the horizon can start crossing a multi-tick delay step")
	scheduler = InputScheduler.new()
	buffer.reset(1)
	var feedback := InputScheduler.InstallFeedback.new()
	for k in range(1, 121):
		var current := [[[k, 1, 0, 1.0, 0, Vector2.RIGHT]], []]
		if k >= 65:
			feedback.install(1, scheduler.announcement(), k - 1, scheduler.notice_confirmed())
			feedback.attach(current, k)
		if k == 65:
			expect(current.back() == Vector2i(90, 26), "first installation measures the actual client sample")
			current.pop_back() # 首份回报丢失。
		if k == 80:
			expect(current.back() == Vector2i(90, 26), "a retry preserves the original installation margin")
		if k == 95:
			expect(current.size() == 2 and scheduler.notice_confirmed(), "a confirmed report costs nothing on subsequent inputs")
		scheduler.submit(buffer, current, k - 1, roundi(k * 1000000.0 / 60))
		scheduler.update(k)
		buffer.take(k)
	expect(scheduler.announcement()[2] == 127 and not scheduler.notice_confirmed(),
			"the next plan uses the measured five samples plus one snapshot interval")
	feedback.install(2, InputScheduler.UNBOUND, 0, false)
	var empty := [[row], []]
	feedback.attach(empty, 200)
	expect(empty.size() == 2, "a new epoch drops the pending installation report")
	var sender := NetCodec.new()
	var receiver := NetCodec.new()
	var frame := {"tick": 100, "map_revision": 0, "world": NetCodec.EMPTY_WORLD, "time": {}, "own": [1, 3, 0, 0]}
	_state(receiver, sender.encode_state(frame, NetCodec.StateBatch.new(frame)))
	sender.state_ack = receiver.state_ack
	frame = frame.merged({"tick": 160, "own": [1, 3, 180, 2]}, true)
	sender.encode_state(frame, NetCodec.StateBatch.new(frame)) # 此次公告丢失。
	frame = frame.merged({"tick": 220, "own": [180, 2, 240, 3]}, true)
	var recovered := _state(receiver, sender.encode_state(frame, NetCodec.StateBatch.new(frame)))
	expect(recovered["own"] == frame["own"] and InputScheduler.target(recovered["own"], 239) == 241
			and InputScheduler.target(recovered["own"], 240) == 243, "the next STATE restores both schedule segments across a lost notice")
	sender.state_ack = receiver.state_ack
	var plain := sender.encode_state(frame, NetCodec.StateBatch.new(frame))
	frame["notice_ack"] = true
	var confirmed := sender.encode_state(frame, NetCodec.StateBatch.new(frame))
	expect(confirmed.size() == plain.size() and _state(receiver, confirmed).get("notice_ack", false),
			"the report ACK uses one existing header bit without adding a downlink byte")
	frame["_sent_input"] = Vector2i(1, 115)
	var observed := _state(receiver, sender.encode_state(frame, NetCodec.StateBatch.new(frame)))
	expect(not observed.has("_sent_input"), "the sending anchor for a passive ACK stays local")
	var reply := receiver.encode_input([[row], []])
	sender.decode_input(NetCodec.Reader.new(reply, 1))
	expect(sender.input_at_acked_snapshot == 115, "a new snapshot ACK carries a free network progress sample")
	sender.decode_input(NetCodec.Reader.new(reply, 1))
	expect(sender.input_at_acked_snapshot == 0, "a duplicate ACK cannot remeasure an older input packet")
	frame["_sent_input"] = Vector2i(2, 116)
	_state(receiver, sender.encode_state(frame, NetCodec.StateBatch.new(frame)))
	sender.decode_input(NetCodec.Reader.new(receiver.encode_input([[row], []]), 1))
	expect(sender.input_at_acked_snapshot == 0, "a prior input epoch cannot sample another epoch's sent snapshot")
	expect(scheduler._notice(0) == 60, "an unconfirmed notice defaults to the conservative upper bound")
	var delayed := InputScheduler.new()
	delayed._notices.append(Vector4i(90, 30, 5, 12))
	expect(delayed._notice(9) == 18 and delayed._notice(3) == 12,
			"seven samples of client installation delay carry over when the network estimate changes")

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
	var authority: AuthorityWorld
	for path: String in ["res://maps/demo.cyrm", session.map_path()]:
		authority = AuthorityWorld.new()
		var problem := authority.setup(session.mode, path, roles, {}, session.options)
		expect(problem.is_empty(), "%s starts a sixteen-player Royale: %s" % [path, problem])
		if not problem.is_empty():
			session.free()
			return
		var sides: Dictionary = MapFormat.load_map(path)["spawns"]["respawn"]
		var points: Array = sides[1] + sides[2]
		expect(players_on_map_points(authority, roles, points), "%s assigns sixteen distinct marked points" % path)
		authority.players[16].force_down()
		expect(authority.respawn(16) and players_on_map_points(authority, roles, points),
				"%s revives the sixteenth player on a free marked point" % path)
	session.free()
	var server := NetCodec.new()
	var client := NetCodec.new()
	var captured := authority.world_state()
	var frame := authority.state_for(16, captured, {})
	var decoded := _state(client, server.encode_state(frame, NetCodec.StateBatch.new(frame)))
	expect(decoded.get("world", {}).get("players", {}).size() == 16,
			"a full snapshot delivers all sixteen players")
	server.state_ack = client.state_ack
	authority.players[16].position.x += 16.0
	captured = authority.world_state()
	frame = authority.state_for(16, captured, {})
	decoded = _state(client, server.encode_state(frame, NetCodec.StateBatch.new(frame)))
	expect(decoded.get("world", {}).get("players", {}).get(16, []) == captured["players"][16],
			"a delta snapshot delivers an update for the sixteenth player")

func _codec(tree: SceneTree) -> void:
	var parent := world(tree)
	var authority := AuthorityWorld.new()
	player(parent, 1)
	player(parent, 2)
	authority.combat_rules = parent.combat
	authority.time_economy = TimeEconomy.new({"cap": 1800.25}, [1, 2])
	authority.players[1].weapons.set_initial_inventory([WeaponRegistry.Type.M249])
	authority.players[2].weapons.set_initial_inventory([WeaponRegistry.Type.COMPOUND_BOW])
	var bow := authority.players[2].equipped as GunBody
	bow.hold_elapsed = 0.4
	bow.aiming = true
	authority.players[2]._grounded = true
	var servers := [NetCodec.new(), NetCodec.new()]
	var clients := [NetCodec.new(), NetCodec.new()]
	authority.rules.phase = NetEvent.RoundState.PLAYING
	authority.players[2].sim_downed = true
	authority.players[2].respawn_tick = 102
	authority.players[2].motion_knock_velocity = Vector2(240, -120)
	authority.combat_rules.tick = 100
	authority.combat_rules.ground.tick = authority.combat_rules.tick
	authority.combat_rules.ground.spawn(WeaponRegistry.Type.PISTOL, 1, Vector2(128, 99), Vector2.ZERO, 2)
	var captured := authority.world_state()
	var accounts := authority.time_economy.state_payload()
	var frames := [authority.state_for(1, captured, accounts), authority.state_for(2, captured, accounts)]
	var batch := NetCodec.StateBatch.new(frames[0])
	var first_wires: Array[PackedByteArray] = []
	for i in 2:
		var wire: PackedByteArray = servers[i].encode_state(frames[i], batch)
		first_wires.append(wire)
		var truncated := NetCodec.Reader.new(wire.slice(0, wire.size() - 1), 1)
		expect(clients[i].decode_state(truncated).is_empty() and not truncated.valid
				and clients[i].latest == 0 and clients[i].state_ack == 0 and clients[i].history.is_empty(),
				"a truncated full STATE does not commit its sequence, ACK or baseline")
		var decoded := _state(clients[i], wire)
		var remote: Array = decoded["world"]["players"][2]
		expect(decoded["world"]["players"] == captured["players"], "full STATE preserves all players' authoritative and equipment state")
		expect(decoded["world"]["pickups"] == captured["pickups"], "full STATE preserves the pickup owner and deadline")
		expect(remote[NetPlayer.RESPAWN_TICK] == 102, "full STATE carries the scheduled respawn of a downed actor")
		expect(remote[NetPlayer.STATE][PlayerStateSchema.KNOCK_VEL] == Vector2(240, -120)
				and remote[NetPlayer.STATE][PlayerStateSchema.GROUNDED], "full STATE carries remote knockback and grounded state")
		expect(decoded["time"] == frames[i]["time"], "full STATE preserves mutable time account fields")
	var account: GrainAccount = authority.time_economy.accounts[1]
	account.spend(0.25, 100.0)
	var spent := account.capture_state()
	account.spend(5.0, 100.0)
	authority.time_economy.restore_account(1, spent)
	expect(spent == [975.0, 25.0, 0.0, false] and account.capture_state() == spent and account.cap == 1800.25,
			"reconciliation restores the saved account slots and uses the capacity from the rules")
	servers[0].state_ack = clients[0].state_ack
	# 第一个客户端已确认了基准快照。第二个客户端还没有可用于增量更新的基准，因此接收完整快照。
	authority.players[1].position += Vector2(8, 0)
	var gun := authority.players[1].equipped as GunBody
	gun.carried = 5
	gun.fire_cd_timer = 0.5
	gun.hold_elapsed = 0.15
	authority.combat_rules.tick = 102
	authority.players[2].motion_knock_velocity = Vector2.ZERO
	var buffer: InputBuffer = authority.players[1].input_buffer
	var record := [2, 1, 102, 0.0, 0, Vector2.RIGHT]
	var action := [1, 1, 101, ActorInput.BIT_UP, 0, 0, Vector2.RIGHT]
	buffer.push([[record], [action]], 100)
	buffer.take(102)
	captured = authority.world_state()
	captured["pickups"][1][WeaponPickup.Network.POS] += Vector2.RIGHT
	captured["projectiles"] = {123: [WeaponRegistry.Type.COMPOUND_BOW, Vector2(10, 20), Vector2(30, 0)]}
	accounts = authority.time_economy.state_payload()
	frames = [authority.state_for(1, captured, accounts), authority.state_for(2, captured, accounts)]
	batch = NetCodec.StateBatch.new(frames[0])
	for i in 2:
		var wire: PackedByteArray = servers[i].encode_state(frames[i], batch)
		var decoded := _state(clients[i], wire)
		var independent := _state(NetCodec.new(), NetCodec.new().encode_state(frames[i], NetCodec.StateBatch.new(frames[i])))
		expect(decoded == independent, "mixed baselines equal independent full STATE, peer %d" % (i + 1))
		if i == 0:
			expect(clients[i].history[1] == _state(NetCodec.new(), first_wires[i]),
					"a delta preserves the acknowledged player's slots, pickup and time account for subsequent packets")
			var still_downed: Array = decoded["world"]["players"][2]
			expect(still_downed[NetPlayer.STATE][PlayerStateSchema.DOWNED] and still_downed[NetPlayer.RESPAWN_TICK] == 0,
					"delta STATE clears an overdue respawn forecast for a still downed actor")
			expect(still_downed[NetPlayer.STATE][PlayerStateSchema.KNOCK_VEL] == Vector2.ZERO,
					"delta STATE clears a remote knockback that has stopped")
			var own: Array = decoded["world"]["players"][1]
			expect(own[NetPlayer.INPUT][InputBuffer.SEQ] == 2 and own[NetPlayer.ACTION_ACK] == 1,
					"delta STATE carries separate frame and action confirmations")
			expect(decoded["world"]["players"] == captured["players"], "delta STATE preserves input, equipment timers and inventory for all roles")
			var old_message := [0, 1, NetBus._wire(first_wires[0]), Time.get_ticks_usec()]
			var new_message := [0, 1, NetBus._wire(wire), Time.get_ticks_usec()]
			var event_message := [0, 1, NetBus._wire(servers[i].encode_event(NetEvent.Kind.START, null)), Time.get_ticks_usec()]
			var coalesced: Array = NetBus._coalesce_messages([new_message, old_message])
			expect(coalesced.size() == 1 and coalesced[0] == new_message, "late STATE cannot replace a newer queued state")
			expect(NetBus._coalesce_messages([old_message, event_message, new_message]).size() == 3, "events form a receive-side STATE coalescing barrier")
			var missing := NetCodec.new()
			expect(_state(missing, wire).is_empty() and missing.state_ack == 0, "missing baseline requests a full STATE")
		servers[i].state_ack = clients[i].state_ack
	authority.combat_rules.tick = 104
	authority.players[2].weapons.max_weapons = 1
	authority.players[2].weapons.pick_up(WeaponRegistry.Type.COMPOUND_BOW, 0)
	captured = authority.world_state()
	frames = [authority.state_for(1, captured, accounts), authority.state_for(2, captured, accounts)]
	batch = NetCodec.StateBatch.new(frames[0])
	for i in 2:
		var decoded := _state(clients[i], servers[i].encode_state(frames[i], batch))
		expect(decoded["world"]["projectiles"].is_empty() and decoded["world"]["players"] == captured["players"],
				"delta STATE removes ended projectiles and restores replaced equipment")
	authority.players[2].weapons.drop_current()
	expect(authority.players[2].equipped == null, "test drops the last weapon")
	expect(authority.world_state()["players"][2][NetPlayer.STATE][PlayerStateSchema.EQUIPMENT].is_empty(), "unarmed actor has no equipment payload")
	authority.combat_rules.tick = 106
	var unarmed_frame := authority.state_for(2, authority.world_state(), accounts)
	servers[1].state_ack = clients[1].state_ack
	for pair in [[NetCodec.new(), NetCodec.new()], [servers[1], clients[1]]]:
		var decoded := _state(pair[1], pair[0].encode_state(unarmed_frame, NetCodec.StateBatch.new(unarmed_frame)))
		var state: Array = decoded["world"]["players"][2][NetPlayer.STATE]
		var expected: Array = unarmed_frame["world"]["players"][2][NetPlayer.STATE]
		expect(state == expected,
				"full and delta STATE retain empty equipment after dropping the last weapon")
		expect(PredictionFrame.difference(expected, state).is_empty(),
				"decoded unarmed STATE does not invalidate matching prediction")
	var baseline := {"code": "01234567", "mode": PvpSession.MODE_PVP, "role": 2, "options": {"player_collision": true},
			"names": {1: "host", 2: "guest"}, "hues": {2: 0.5}, "teams": {}, "map": PackedByteArray([1, 2, 3]),
			"sub_hp": {Vector2i(2, 3): 4}, "round_state": authority.round_state().merged({"grace": {}}),
			"frame": unarmed_frame}
	var wire: PackedByteArray = servers[1].encode_event(NetEvent.Kind.BASELINE, baseline)
	var digest := wire.hex_encode().sha256_text()
	expect(digest == "a429b17296674864af07cd8819e101e3175a4793f167267d3b955931a54f3203",
			"BASELINE matches the v33 layout (%s)" % digest)
	var client: NetCodec = clients[1]
	var known := client.history.keys()
	var ack := client.state_ack
	var short := NetCodec.Reader.new(wire.slice(0, wire.size() - 1), 1)
	expect(client.decode_event(NetEvent.Kind.BASELINE, short) == null and not short.valid
			and client.history.keys() == known and client.state_ack == ack,
			"truncated BASELINE leaves the current history and ACK intact")
	var full := NetCodec.Reader.new(wire, 1)
	expect(client.decode_event(NetEvent.Kind.BASELINE, full) == baseline and full.valid
			and client.history.size() == 1 and client.state_ack > ack,
			"valid BASELINE replaces the history after decoding its full frame")
	authority.time_economy.restore_account(17, [72.125, 250.0, 17.75, true])
	var received := authority.time_economy.state_payload()
	authority.time_economy.accounts[17].regen(0.25)
	expect(received[17] == [72.125, 250.0, 17.75, true]
			and authority.time_economy.accounts[17].capture_state() == [72.125, 250.0, 5.25, true],
			"restoring a new role preserves its loan and lock, and later repayment leaves the snapshot intact")

func _event_records() -> void:
	var codec := NetCodec.new()
	var records := {
		NetEvent.Kind.CREATE: {"mode": PvpSession.MODE_ROYALE, "options": {
			"map": "res://maps/newfactory.cyrm", "max_players": 8, "match_time": 300,
			"round_full_heal": false, "disabled_weapons": [1, 5], "beta": true,
			"time": TimeRules.normalized({"cap": 1800.25}), "player_collision": false}},
		NetEvent.Kind.TERRAIN: {"tick": 9, "revision": 7, "cells": {Vector2i(34, 1): 0, Vector2i(2, 10): 4}},
		NetEvent.Kind.ROUND: {"state": 2, "round": 3, "timer": 1.25, "winner": 2, "match_winner": 0,
			"mvp": 2, "scores": {1: -2, 2: 3}, "rounds_won": {2: 1}, "left": [3],
			"grace": {1: 2.5}, "alive": {1: false, 2: true},
			"stats": {2: {"kills": 5, "deaths": 1, "assists": 2, "dealt": 333, "taken": 44, "acs": 3.5}}},
	}
	# 用当前协议 的参考编码检验兼容性。测试比较事件十六进制文本的 SHA-256。
	var expected := {
		NetEvent.Kind.CREATE: "248e1dc5623cf0eaa55d334ce5be25378bb6957471dccc48e4d96121c82af899",
		NetEvent.Kind.TERRAIN: "ed33184f65bf5a3c0cec57f899cbbd7813e567c06afe2223823a0ae0a7e140c4",
		NetEvent.Kind.ROUND: "33d37b690f525a9d6fc802416ec2d5b0f73c7040f442d80ebfffe7b8549886d2",
	}
	for kind: int in records:
		var wire := codec.encode_event(kind, records[kind])
		expect(wire.hex_encode().sha256_text() == expected[kind], "event %d matches its wire layout" % kind)
		expect(codec.decode_event(kind, NetCodec.Reader.new(wire, 1)) == records[kind],
				"event %d decodes to the original record" % kind)

func _combat_events(tree: SceneTree) -> void:
	var codec := NetCodec.new()
	var id := (2 << 48) | 256
	var shot := {"kind": "fire", "role": 2, "serial": 1, "tick": 100, "type_id": WeaponRegistry.Type.GRENADE,
			"pos": Vector2(8, 16), "dir": Vector2.LEFT, "charge": 1.0, "speed_mult": 3.0}
	var events := {
		NetEvent.Kind.FIRE: shot,
		NetEvent.Kind.BULLET_END: {"tick": 100, "ids": [id]},
		NetEvent.Kind.EXPLOSION: {"id": id, "type_id": shot["type_id"], "pos": Vector2(8, 16), "tick": 101},
		NetEvent.Kind.HIT: {"shooter": 2, "victim": 1, "damage": 5, "tick": 102, "epoch": 3,
				"hp": -2, "impulse_mode": -1, "pos": Vector2(16, 32),
				"facing": -1, "vel": Vector2(400, -200), "knock": Vector2(12, -8)},
	}
	for kind: int in events:
		var data: Dictionary = events[kind]
		var stream := _body(codec.encode_event(kind, data), NetCodec.EVENT + kind)
		expect(codec.decode_event(kind, stream) == data and stream.remaining() == 0,
				"combat event %d round trips the authority facts" % kind)
	expect(codec.encode_event(NetEvent.Kind.HIT, events[NetEvent.Kind.HIT]).hex_encode()
			== "1102000100050000006600000003000000feffffffff0000804100000042ff0000c843000048c300004041000000c1",
			"HIT keeps its wire layout")
	var fire := shot.merged({"vectors": PackedVector2Array([Vector2.LEFT]), "trace": {}})
	var explosion: Dictionary = events[NetEvent.Kind.EXPLOSION].merged({"cells": PackedInt32Array([1, 513])})
	for kind: int in [NetEvent.Kind.FIRE, NetEvent.Kind.EXPLOSION]:
		var result := fire if kind == NetEvent.Kind.FIRE else explosion
		var wire := NetBus._wire(codec.encode_event(kind, result))
		expect(wire.size() == (39 if kind == NetEvent.Kind.FIRE else 24)
				and wire == NetBus._wire(codec.encode_event(kind, events[kind])),
				"event %d sends parameters without local geometry" % kind)
	var normal := shot.merged({"speed_mult": 1.0}, true)
	var default_wire := codec.encode_event(NetEvent.Kind.FIRE, normal)
	expect(NetBus._wire(default_wire).size() == 31 and codec.decode_event(NetEvent.Kind.FIRE,
			_body(default_wire, NetCodec.EVENT + NetEvent.Kind.FIRE)) == normal,
			"FIRE omits default charge and speed, and restores them exactly")

	var shooter := player(world(tree))
	for haste: float in [1.0, 2.0]:
		shooter.personal_haste_mult = haste
		for type_id: int in WeaponRegistry.all_ids():
			shooter.weapons.set_initial_inventory([type_id])
			var gun := shooter.equipped as GunBody
			gun.hold_elapsed = 0.4
			gun._fire(shooter, Vector2.RIGHT)
			var fired: Dictionary = shooter.combat_requests.back().merged({"role": shooter.role, "tick": 100})
			var bytes := NetBus._wire(codec.encode_event(NetEvent.Kind.FIRE, fired))
			var expected := 31
			if type_id == WeaponRegistry.Type.COMPOUND_BOW: expected += 8
			if haste != 1.0 and gun.definition["attack"] == WeaponRegistry.Attack.PROJECTILE: expected += 8
			expect(bytes.size() == expected, "weapon %d sends only active launch modifiers at %sx" % [type_id, haste])

func _projectile_deltas() -> void:
	var pellets := {}
	for id in 8:
		pellets[id] = [WeaponRegistry.Type.S686, Vector2.ZERO, Vector2.RIGHT]
	var shot := ShotRules.shot_id(2, 1)
	var points := PackedVector2Array([Vector2(8, 24), Vector2(120, 24), Vector2(-80, 24)])
	var frame := {"tick": 1, "map_revision": 0, "own": InputScheduler.UNBOUND, "time": {},
			"world": {"players": {}, "pickups": {}, "projectiles": pellets, "beams": {shot: [16, points]}}}
	var server := NetCodec.new()
	var client := NetCodec.new()
	var first := _state(client, server.encode_state(frame, NetCodec.StateBatch.new(frame)))
	expect(first["world"]["beams"] == frame["world"]["beams"], "a full STATE preserves a reflected beam and its deadline")
	server.state_ack = client.state_ack
	frame = frame.duplicate(true)
	frame["tick"] = 2
	var quiet := server.encode_state(frame, NetCodec.StateBatch.new(frame))
	expect(quiet.size() == 18 and _state(client, quiet)["world"] == frame["world"],
			"unchanged pellets and beams leave only the STATE header")
	server.state_ack = client.state_ack
	frame = frame.duplicate(true)
	frame["tick"] = 3
	frame["world"]["projectiles"][3][BulletBody.Network.POS] = Vector2(10, 0)
	var update := server.encode_state(frame, NetCodec.StateBatch.new(frame))
	expect(update.size() - quiet.size() == 21 and _state(client, update)["world"] == frame["world"],
			"one moving pellet sends only its ID, field mask and position")
	server.state_ack = client.state_ack
	frame = frame.duplicate(true)
	frame["tick"] = 16
	frame["world"]["beams"] = {ShotRules.shot_id(1, 2): [31, PackedVector2Array([Vector2.ZERO, Vector2.RIGHT])]}
	var changed := _state(client, server.encode_state(frame, NetCodec.StateBatch.new(frame)))
	expect(changed["world"]["beams"] == frame["world"]["beams"] and first["world"]["beams"].has(shot),
			"a delta adds and removes beams while preserving the earlier snapshot")

func _malformed_packets() -> void:
	var codec := NetCodec.new()
	codec.state_ack = 42
	var short_input := NetCodec.Reader.new(PackedByteArray([100, 0, 0, 0]))
	expect(codec.decode_input(short_input).is_empty() and not short_input.valid and codec.state_ack == 42,
			"invalid INPUT does not acknowledge a snapshot")
	var short_terrain := NetCodec.Reader.new(PackedByteArray([9, 0, 0, 0, 7, 0, 0, 0, 255, 255, 255, 255]))
	expect(codec.decode_event(NetEvent.Kind.TERRAIN, short_terrain) == null and not short_terrain.valid,
			"TERRAIN rejects a cell count larger than the remaining packet")
	var bad_mode := NetCodec.Reader.new(PackedByteArray([255, 0, 0]))
	expect(codec.decode_event(NetEvent.Kind.CREATE, bad_mode) == null and not bad_mode.valid,
			"CREATE rejects an unknown mode before indexing the mode table")

	var received: Array[int] = []
	var stamps: Array[int] = []
	var stamp := func(_peer: int, _packet: Array, us: int, _input_at_snapshot: int) -> void: stamps.append(us)
	NetBus.input_received.connect(stamp)
	var listen := func(_peer: int, kind: int, _data: Variant) -> void: received.append(kind)
	NetBus.event_received.connect(listen)
	var was_server: bool = NetBus.is_server_mode
	NetBus.is_server_mode = true
	NetBus._receive(999, PackedByteArray([NetCodec.WIRE_MAGIC, 17, NetCodec.EVENT + NetEvent.Kind.START]), 0)
	var patch := {"tick": 9, "revision": 7, "cells": {Vector2i.ZERO: 0}}
	NetBus._receive(999, NetBus._wire(codec.encode_event(NetEvent.Kind.TERRAIN, patch)), 0)
	NetBus._receive(999, NetBus._wire(codec.encode_event(NetEvent.Kind.START, null)), 0)
	NetBus._receive(999, NetBus._wire(codec.encode_input([[], []])), 123456)
	NetBus.is_server_mode = was_server
	NetBus._codecs.erase(999)
	NetBus.event_received.disconnect(listen)
	NetBus.input_received.disconnect(stamp)
	expect(stamps == [123456], "INPUT dispatch preserves the native receipt timestamp")
	expect(received == [NetEvent.Kind.START], "server dispatches valid client commands from the current protocol only")

func _playback() -> void:
	var playback := SnapshotBuffer.new()
	playback.map_px = Vector2(512, 256)
	var a := {"players": {2: _actor(Vector2(508, 100))}, "pickups": {}, "beams": {}}
	var b := {"players": {2: _actor(Vector2(4, 100))}, "pickups": {}, "beams": {}}
	var loading := [0.0, false, false, -1, 0.5, 0.0]
	b["players"][2][NetPlayer.STATE][PlayerStateSchema.EQUIPMENT] = loading
	playback.push(10, a)
	playback.push(12, b)
	var shown := playback.sample(11)
	expect(playback.sample(11, 2)["players"].is_empty() and playback.latest_players.has(2),
			"remote sampling skips the local role and preserves the complete authority frame")
	expect(shown["players"][2][Sample.POS].is_equal_approx(Vector2(0, 100)), "playback interpolates across map seam")
	shown["players"][2][Sample.POS] = Vector2(99, 99)
	expect(playback.sample(11)["players"][2][Sample.POS].is_equal_approx(Vector2(0, 100)), "presentation edits do not mutate buffered positions")
	expect(a["players"][2][NetPlayer.STATE][POS] == Vector2(508, 100), "sampling leaves source snapshot intact")
	expect(shown["players"][2][Sample.SOURCE][NetPlayer.STATE][PlayerStateSchema.EQUIPMENT].is_empty() and playback.sample(12)["players"][2][Sample.SOURCE][NetPlayer.STATE][PlayerStateSchema.EQUIPMENT] == loading,
			"the held weapon pose follows the displayed player's equipment snapshot")
	playback.reset()
	playback.map_px.x = 1024.0
	playback.push(10, {"players": {2: _actor(Vector2(980, 100))}, "pickups": {}, "beams": {}})
	playback.push(12, {"players": {2: _actor(Vector2(260, 100), 1, true)}, "pickups": {}, "beams": {}})
	playback.push(14, {"players": {2: _actor(Vector2(600, 100), 2)}, "pickups": {}, "beams": {}})
	expect(playback.sample(11)["players"][2][Sample.POS] == Vector2(108, 100),
			"a large rewind step interpolates across the seam")
	expect(playback.sample(13)["players"][2][Sample.POS] == Vector2(430, 100),
			"remote playback interpolates through the epoch change when rewind ends")
	playback.push(16, {"players": {2: _actor(Vector2(610, 100), 3)}, "pickups": {}, "beams": {}})
	expect(playback.sample(15)["players"][2][Sample.POS] == Vector2(600, 100)
			and playback.sample(16)["players"][2][Sample.POS] == Vector2(610, 100),
			"a respawn still switches directly at its snapshot even over a short distance")

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
				"team": 1 if role <= 5 else 2, "deadline": 0.0, "ready": false}
	expect(small.team_ready(), "a 5v1 roster satisfies the team start condition")
	small.seats[6]["team"] = 1
	expect(small.team_count(2) == 0, "a roster without both teams cannot start")
	small.free()


func _ready_flow(tree: SceneTree) -> void:
	var session := LobbySession.new()
	tree.root.add_child(session)
	session.code = "12345678"
	session.mode = PvpSession.MODE_TEAM
	session.options = RoomOptions.normalized(session.mode, {"map": "res://maps/demo.cyrm", "beta": true})
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
	var tick := session.world.combat_rules.tick
	await tree.physics_frame
	expect(session.world.combat_rules.tick == tick + 1, "the room advances the match once per physics frame")
	session._on_event(11, NetEvent.Kind.READY, 2)
	expect(not session.seats[1]["ready"], "READY for another round is ignored")
	session._on_event(99, NetEvent.Kind.READY, 1)
	expect(not session.seats[1]["ready"], "READY from an unseated peer is ignored")
	session._on_event(11, NetEvent.Kind.READY, 1)
	expect(session.seats[1]["ready"], "a current-round READY is accepted")
	expect(session.world.rules.phase == NetEvent.RoundState.WAITING, "WAITING is kept until every seat is ready")
	session._on_event(12, NetEvent.Kind.READY, 1)
	var rules := session.world.rules
	expect(rules.phase == NetEvent.RoundState.COUNTDOWN and is_equal_approx(rules.round_timer, 3.0),
			"the last READY starts a full 3 second countdown")
	rules.advance(0.5)
	session._on_event(12, NetEvent.Kind.READY, 1)
	expect(rules.phase == NetEvent.RoundState.COUNTDOWN and is_equal_approx(rules.round_timer, 2.5),
			"a repeated READY does not restart the countdown")
	rules.advance(2.5)
	session.seats[2]["ready"] = false
	session._on_event(12, NetEvent.Kind.READY, 1)
	expect(session.seats[2]["ready"] and rules.phase == NetEvent.RoundState.PLAYING,
			"a reconnect READY only restores its own data sending")

	session.remove_seat(2)
	var result := session.world.round_state()
	tick = session.world.combat_rules.tick
	await tree.physics_frame
	expect(rules.phase == NetEvent.RoundState.MATCH_OVER and session.world.combat_rules.tick == tick
			and session.world.round_state() == result, "the room keeps the final result at the last simulated tick")
	var old_match: WeakRef = weakref(session.world)
	var body: WeakRef = weakref(session.world.players[1])
	var space: WeakRef = weakref(session.world.terrain.physics.world)
	session._on_event(11, NetEvent.Kind.LEAVE, null)
	expect(session.world == null and old_match.get_ref() == null and body.get_ref() == null and space.get_ref() == null,
			"returning to the room releases the match, player and physics world")

	session.add_seat(12)
	session.start_match()
	expect(session.world.combat_rules.tick == 0 and session.world.rules.phase == NetEvent.RoundState.WAITING,
			"the same room can open a fresh match")
	session.remove_seat(2)
	expect(session.world == null, "an expiring seat cancels the unstarted match")
	session.add_seat(12)
	session.start_match()
	old_match = weakref(session.world)
	session.free()
	expect(old_match.get_ref() == null, "closing a room releases its active match")
