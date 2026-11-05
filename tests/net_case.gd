extends "res://tests/case.gd"

static var POS := PlayerStateSchema.slot("pos")
static var VEL := PlayerStateSchema.slot("vel")
static var EPOCH := PlayerStateSchema.slot("epoch")

static func _actor(pos: Vector2) -> Array:
	var record: Array = []
	record.resize(PlayerStateSchema.ACTOR_SIZE)
	record[POS] = pos
	record[VEL] = Vector2(60, 0)
	record[EPOCH] = 1
	return record

class LobbySession extends RoomSession:
	var messages: Array[String] = []
	func message(_peer: int, value: String) -> void: messages.append(value)

class RewindWorld extends Node:
	var _snap_tick := 100
	var players := {}

# READY 流程只关心回合状态与计时；广播在这里是空操作。
class ReadyWorld extends AuthorityWorld:
	func broadcast_round() -> void:
		pass

func run(tree: SceneTree) -> void:
	_input()
	_lobby()
	_team_room()
	_ready_flow()
	_codec(tree)
	_beta_path()
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

func _lobby() -> void:
	var codec := NetCodec.new()
	var join := {"code": "00048213", "beta": true}
	var wire := codec.encode_event(NetEvent.Kind.JOIN, join)
	var stream := _body(wire, NetCodec.EVENT + NetEvent.Kind.JOIN)
	expect(wire.size() == 6 and codec.decode_event(NetEvent.Kind.JOIN, stream) == join,
			"JOIN preserves leading-zero room code and gameplay selection")
	expect(stream.get_available_bytes() == 0, "JOIN consumes its complete payload")
	var options := {"map": "res://maps/newfactory.cyrm", "max_players": 8, "match_time": 300,
			"round_full_heal": false, "disabled_weapons": WeaponRegistry.all_ids().slice(0, 1),
			"beta": true, "time": TimeRules.new().to_dict(), "hue": 0.25}
	var create := {"mode": PvpSession.MODE_ROYALE, "options": options}
	stream = _body(codec.encode_event(NetEvent.Kind.CREATE, create), NetCodec.EVENT + NetEvent.Kind.CREATE)
	expect(codec.decode_event(NetEvent.Kind.CREATE, stream) == create and stream.get_available_bytes() == 0,
			"CREATE round trip preserves room options")
	var session := LobbySession.new()
	session.code = join["code"]
	session.mode = PvpSession.MODE_ROYALE
	session.options = options
	session.seats = {1: {"name": "host", "team": 0}, 2: {"name": "guest", "team": 0}}
	var room := session.room_data()
	room.merge({"your_role": 2, "token": "01".repeat(16)})
	stream = _body(codec.encode_event(NetEvent.Kind.ROOM, room), NetCodec.EVENT + NetEvent.Kind.ROOM)
	var decoded: Dictionary = codec.decode_event(NetEvent.Kind.ROOM, stream)
	expect(stream.get_available_bytes() == 0 and decoded["players"] == room["players"]
			and decoded["code"] == room["code"] and decoded["your_role"] == 2
			and decoded["token"] == "01".repeat(16),
			"ROOM preserves roster, options and rejoin credentials")
	expect(decoded["team_size"] == 5, "ROOM derives the 5-player team size")
	expect(decoded["names"] == ["host", "guest"] and decoded["count"] == 2
			and decoded["host_name"] == "host" and decoded["team_counts"] == {0: 2, 1: 0, 2: 0},
			"ROOM derives names, host and team counts from the roster")
	var listed := session.room_data()
	listed.merge({"joinable": false, "rejoinable": true})
	listed["in_match"] = true
	stream = _body(codec.encode_event(NetEvent.Kind.ROOMS, [listed]), NetCodec.EVENT + NetEvent.Kind.ROOMS)
	var rooms: Array = codec.decode_event(NetEvent.Kind.ROOMS, stream)
	expect(stream.get_available_bytes() == 0 and rooms.size() == 1 and rooms[0]["players"] == listed["players"]
			and rooms[0]["in_match"] and not rooms[0]["joinable"] and rooms[0]["rejoinable"],
			"ROOMS preserves match, gameplay and rejoin flags")
	session._on_event(3, NetEvent.Kind.JOIN, join.merged({"beta": false}, true))
	expect(session.messages.back() == "该房间为「错乱大乱斗」，请从「Beta」进入" and session.seats.size() == 2,
			"gameplay mismatch names the Beta room and its entry without adding a seat")
	session.options["beta"] = false
	session._on_event(3, NetEvent.Kind.JOIN, join)
	expect(session.messages.back() == "该房间为「大乱斗」，请从「多人模式」进入" and session.seats.size() == 2,
			"gameplay mismatch names the regular room and its entry")
	session.free()

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
		expect(decoded["world"]["players"][i + 1][POS] == authority.players[i + 1].position, "full STATE position")
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
		expect(decoded == independent, "mixed baselines equal independent full STATE, peer %d" % (i + 1))
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
	# 空手时武器段仍占固定槽位，广播记录不会出现空洞。
	authority.players[2].weapons.drop_current()
	expect(authority.players[2].weapons.current_type_id() == 0, "test drops the last weapon")
	var unarmed: Array = authority.world_state()["players"][2]
	expect(authority.players[2].capture_state().size() == PlayerStateSchema.SIZE
			and unarmed[PlayerStateSchema.CHARACTER_SIZE] != null, "unarmed record keeps the weapon slots")
	authority._snap_tick = 106
	var unarmed_frame := authority.state_for(2, authority.world_state())
	servers[1].state_ack = clients[1].state_ack
	for pair in [[NetCodec.new(), NetCodec.new()], [servers[1], clients[1]]]:
		var decoded := _state(pair[1], pair[0].encode_state(unarmed_frame, NetCodec.StateBatch.new(unarmed_frame)))
		expect(decoded["own"]["state"] == unarmed_frame["own"]["state"],
				"full and delta STATE retain every idle weapon slot after dropping the last weapon")
		expect(Player.prediction_difference(unarmed_frame["own"]["state"], decoded["own"]["state"]).is_empty(),
				"decoded unarmed STATE does not invalidate matching prediction")
	authority.free()

func _beta_path() -> void:
	var record: Array = []
	record.resize(PlayerStateSchema.SIZE)
	record[PlayerStateSchema.slot("pos")] = Vector2(32, 48)
	record[PlayerStateSchema.slot("squat")] = true
	record[PlayerStateSchema.slot("down")] = false
	record[PlayerStateSchema.slot("facing")] = -1
	var world := RewindWorld.new()
	var current: Player = preload("res://scenes/player/player.tscn").instantiate()
	world.add_child(current)
	world.players = {1: current}
	var history := BetaHistory.new(world)
	history.frames = {1: [{"tick": 100, "player": record, "bullets": {}}]}
	history.cursors = {1: 0.0}
	var path := history.collision_path(1)
	expect(path.size() == 1 and path[0][0] == 101 and path[0][1] == Vector2(32, 48) and path[0][2] == 5,
			"rewind path encodes position and pose flags")
	world.free()

func _playback() -> void:
	var playback := SnapshotBuffer.new()
	playback.map_px = Vector2(512, 256)
	var a := {"players": {2: _actor(Vector2(508, 100))}, "pickups": {}}
	var b := {"players": {2: _actor(Vector2(4, 100))}, "pickups": {}}
	playback.push(10, a)
	playback.push(12, b)
	var shown := playback.sample(11)
	expect(shown["players"][2][POS].is_equal_approx(Vector2(0, 100)), "playback interpolates across map seam")
	shown["players"][2][POS] = Vector2(99, 99)
	expect(playback.sample(11)["players"][2][POS].is_equal_approx(Vector2(0, 100)), "presentation edits do not mutate buffered positions")
	expect(a["players"][2][POS] == Vector2(508, 100), "sampling leaves source snapshot intact")

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

# 团队房间容量、选边与开局条件。
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
	var teams_5v5 := {}
	for i in 5:
		teams_5v5[i + 1] = 1
		teams_5v5[i + 6] = 2
	expect(MatchRules.validate_team_spawns("res://maps/demo.cyrm", teams_5v5) == "",
			"demo.cyrm passes 5v5 spawn validation")
	expect(MatchRules.validate_team_spawns("res://maps/newfactory.cyrm", teams_5v5) == "",
			"newfactory.cyrm passes 5v5 spawn validation")


# READY 齐备才进入 COUNTDOWN；重复 READY 与局中重连不重启回合。
func _ready_flow() -> void:
	var session := LobbySession.new()
	session.mode = PvpSession.MODE_TEAM
	var stub := ReadyWorld.new()
	session.add_child(stub)
	stub._round_num = 1
	stub._round_state = NetEvent.RoundState.WAITING
	var p1 := Node.new()
	var p2 := Node.new()
	stub.players = {1: p1, 2: p2}
	session.world = stub
	session.seats = {
		1: {"peer": 11, "ready": true, "team": 1, "deadline": 0.0},
		2: {"peer": 12, "ready": false, "team": 2, "deadline": 0.0},
	}
	session._start_countdown_if_ready()
	expect(stub._round_state == NetEvent.RoundState.WAITING, "WAITING is kept until every seat is ready")
	session.seats[1]["ready"] = false
	session._on_event(11, NetEvent.Kind.READY, 2)
	expect(not session.seats[1]["ready"], "READY for another round is ignored")
	session._on_event(99, NetEvent.Kind.READY, 1)
	expect(not session.seats[1]["ready"], "READY from an unseated peer is ignored")
	session._on_event(11, NetEvent.Kind.READY, 1)
	expect(session.seats[1]["ready"], "a current-round READY is accepted")
	session.seats[2]["ready"] = true
	session._start_countdown_if_ready()
	expect(stub._round_state == NetEvent.RoundState.COUNTDOWN and is_equal_approx(stub._round_timer, 3.0),
			"the last READY starts a full 3 second countdown")
	stub._round_timer = 2.5
	session._start_countdown_if_ready()
	expect(stub._round_state == NetEvent.RoundState.COUNTDOWN and is_equal_approx(stub._round_timer, 2.5),
			"a repeated READY does not restart the countdown")
	stub._round_state = NetEvent.RoundState.PLAYING
	stub._round_timer = 1.5
	session.seats[2]["ready"] = false
	session._on_event(12, NetEvent.Kind.READY, 1)
	expect(session.seats[2]["ready"] and stub._round_state == NetEvent.RoundState.PLAYING
			and is_equal_approx(stub._round_timer, 1.5),
			"a reconnect READY only restores its own data sending")
	stub._round_state = NetEvent.RoundState.WAITING
	session._cancel_waiting_match()
	expect(session.world == null, "an expiring seat cancels the unstarted match")
	if is_instance_valid(stub):
		stub.free()
	p1.free()
	p2.free()
	session.free()
