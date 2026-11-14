extends "res://tests/case.gd"

const POS: int = PlayerStateSchema.POS
const VEL: int = PlayerStateSchema.VEL

static func _actor(pos: Vector2) -> Dictionary:
	var record: Array = []
	record.resize(PlayerStateSchema.SIZE)
	record[POS] = pos
	record[VEL] = Vector2(60, 0)
	record[PlayerStateSchema.KNOCK_VEL] = Vector2.ZERO
	return {"state": {"actor": record}, "aim": Vector2.RIGHT, "epoch": 1, "rewind": false}

class LobbySession extends RoomSession:
	var messages: Array[String] = []
	func message(_peer: int, value: String) -> void: messages.append(value)

# READY 流程只关心回合状态与计时；广播在这里是空操作。
class ReadyWorld extends AuthorityWorld:
	func broadcast_round() -> void:
		pass

func run(tree: SceneTree) -> void:
	_input()
	_lobby()
	_room_admission()
	_tunnel_parsing()
	_team_room()
	_ready_flow()
	_codec(tree)
	_combat_events()
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
	var protocol_bytes := ("c718000807060507000000030c0000000f64000000000000000000e0bf00010000803e000000bf"
			+ "0d0000000365000000000000000000f03f0e00000000010c000000640000002000080004030201000000000000803f")
	expect(NetBus._wire(wire).hex_encode() == protocol_bytes, "INPUT header, frame deltas and actions match the wire format")
	var stream := _body(wire, NetCodec.INPUT)
	var decoded := codec.decode_input(stream)
	expect(decoded == wire_packet, "input wire preserves frame fields, action edges and scheduling")
	expect(stream.remaining() == 0, "input decoder consumes packet")
	wire = codec.encode_event(NetEvent.Kind.START, null)
	expect(wire.size() == 1, "START has no obsolete bot payload")
	stream = _body(wire, NetCodec.EVENT + NetEvent.Kind.START)
	expect(codec.decode_event(NetEvent.Kind.START, stream) == null and stream.remaining() == 0, "START round trip")

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
			"beta": true, "time": rules}
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
			and decoded["token"] == "01".repeat(16),
			"ROOM preserves roster, options and rejoin credentials")
	expect(decoded["can_start"], "ROOM carries the server's start decision")
	expect(decoded["count"] == 2 and decoded["host_name"] == "host"
			and decoded["team_counts"] == {0: 2, 1: 0, 2: 0},
			"ROOM derives host and team counts from the roster")
	var listed := session.room_data()
	listed["in_match"] = true
	for entry in [{}, listed]:
		stream = _body(codec.encode_event(NetEvent.Kind.ROOM_LIST, entry), NetCodec.EVENT + NetEvent.Kind.ROOM_LIST)
		var room_list: Dictionary = codec.decode_event(NetEvent.Kind.ROOM_LIST, stream)
		expect(stream.remaining() == 0 and room_list.is_empty() == entry.is_empty(),
				"the room list represents an empty or occupied endpoint")
		if not entry.is_empty():
			expect(room_list["players"] == listed["players"] and room_list["in_match"] and room_list["beta"],
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

func _codec(tree: SceneTree) -> void:
	var parent := world(tree)
	var authority := AuthorityWorld.new()
	authority.players = {1: player(parent, 1), 2: player(parent, 2)}
	authority.combat_rules = CombatSimulator.new(_terrain, parent, true)
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
	authority._snap_tick = 100
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
		var remote: Dictionary = decoded["world"]["players"][2]
		expect(decoded["world"]["players"] == captured["players"], "full STATE preserves all players' authoritative and equipment state")
		expect(remote["respawn_tick"] == 102, "full STATE carries the scheduled respawn of a downed actor")
		expect(remote["state"]["actor"][PlayerStateSchema.KNOCK_VEL] == Vector2(240, -120)
				and remote["state"]["actor"][PlayerStateSchema.GROUNDED], "full STATE carries remote knockback and grounded state")
		expect(decoded["time"] == frames[i]["time"], "full STATE preserves mutable time account fields")
	var account: GrainAccount = authority.time_economy.accounts[1]
	account.spend(0.25, 100.0)
	authority.time_economy.restore_account(1, authority.time_economy.account_payload(1))
	expect(account.cap == 1800.25 and account.balance == 975.0,
			"account reconciliation uses the rule capacity and restores the active balance")
	servers[0].state_ack = clients[0].state_ack
	# Peer 2 still needs a full frame; common bytes must not mix its baseline with peer 1.
	authority.players[1].position += Vector2(8, 0)
	var gun := authority.players[1].equipped as GunBody
	gun.carried = 5
	gun.fire_cd_timer = 0.5
	gun.hold_elapsed = 0.15
	authority._snap_tick = 102
	authority.players[2].motion_knock_velocity = Vector2.ZERO
	var buffer: InputBuffer = authority.players[1].input_buffer
	var record := [2, 1, 102, 0.0, 0, Vector2.RIGHT]
	var action := [1, 1, 101, ActorInput.BIT_UP, 0, 0, Vector2.RIGHT]
	buffer.push([[record], [action]], 100)
	buffer.take(102)
	captured = authority.world_state()
	captured["projectiles"] = {123: {"type_id": WeaponRegistry.Type.COMPOUND_BOW, "pos": Vector2(10, 20),
			"vel": Vector2(30, 0)}}
	accounts = authority.time_economy.state_payload()
	frames = [authority.state_for(1, captured, accounts), authority.state_for(2, captured, accounts)]
	batch = NetCodec.StateBatch.new(frames[0])
	for i in 2:
		var wire: PackedByteArray = servers[i].encode_state(frames[i], batch)
		var decoded := _state(clients[i], wire)
		var independent := _state(NetCodec.new(), NetCodec.new().encode_state(frames[i], NetCodec.StateBatch.new(frames[i])))
		expect(decoded == independent, "mixed baselines equal independent full STATE, peer %d" % (i + 1))
		if i == 0:
			var still_downed: Dictionary = decoded["world"]["players"][2]
			expect(still_downed["state"]["actor"][PlayerStateSchema.DOWNED] and still_downed["respawn_tick"] == 0,
					"delta STATE clears an overdue respawn forecast for a still downed actor")
			expect(still_downed["state"]["actor"][PlayerStateSchema.KNOCK_VEL] == Vector2.ZERO,
					"delta STATE clears a remote knockback that has stopped")
			var own: Dictionary = decoded["world"]["players"][1]
			expect(own["input"][InputBuffer.SEQ] == 2 and own["action_ack"] == 1,
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
	authority._snap_tick = 104
	authority.players[2].weapons.inventory.max_weapons = 1
	authority.players[2].weapons.pick_up(WeaponRegistry.Type.COMPOUND_BOW, 0)
	captured = authority.world_state()
	frames = [authority.state_for(1, captured, accounts), authority.state_for(2, captured, accounts)]
	batch = NetCodec.StateBatch.new(frames[0])
	for i in 2:
		var decoded := _state(clients[i], servers[i].encode_state(frames[i], batch))
		expect(decoded["world"]["projectiles"].is_empty() and decoded["world"]["players"] == captured["players"],
				"delta STATE removes ended projectiles and restores replaced equipment")
	authority.players[2].weapons.drop_current()
	expect(authority.players[2].weapons.current_type_id() == 0, "test drops the last weapon")
	expect(authority.world_state()["players"][2]["state"]["equipment"].is_empty(), "unarmed actor has no equipment payload")
	authority._snap_tick = 106
	var unarmed_frame := authority.state_for(2, authority.world_state(), accounts)
	servers[1].state_ack = clients[1].state_ack
	for pair in [[NetCodec.new(), NetCodec.new()], [servers[1], clients[1]]]:
		var decoded := _state(pair[1], pair[0].encode_state(unarmed_frame, NetCodec.StateBatch.new(unarmed_frame)))
		var state: Dictionary = decoded["world"]["players"][2]["state"]
		var expected: Dictionary = unarmed_frame["world"]["players"][2]["state"]
		expect(state == expected,
				"full and delta STATE retain empty equipment after dropping the last weapon")
		expect(PlayerStateSchema.difference(expected, state).is_empty(),
				"decoded unarmed STATE does not invalidate matching prediction")
	var baseline := {"code": "01234567", "mode": PvpSession.MODE_PVP, "role": 2, "options": {},
			"names": {1: "host", 2: "guest"}, "hues": {2: 0.5}, "teams": {}, "map": PackedByteArray([1, 2, 3]),
			"sub_hp": {Vector2i(2, 3): 4}, "round_state": authority.round_state().merged({"grace": {}}),
			"frame": unarmed_frame}
	var wire: PackedByteArray = servers[1].encode_event(NetEvent.Kind.BASELINE, baseline)
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
	authority.free()

func _combat_events() -> void:
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
	var listen := func(_peer: int, kind: int, _data: Variant) -> void: received.append(kind)
	NetBus.event_received.connect(listen)
	var was_server: bool = NetBus.is_server_mode
	NetBus.is_server_mode = true
	NetBus._receive(999, PackedByteArray([NetCodec.WIRE_MAGIC, 17, NetCodec.EVENT + NetEvent.Kind.START]))
	var patch := {"tick": 9, "revision": 7, "cells": {Vector2i.ZERO: 0}}
	NetBus._receive(999, NetBus._wire(codec.encode_event(NetEvent.Kind.TERRAIN, patch)))
	NetBus._receive(999, NetBus._wire(codec.encode_event(NetEvent.Kind.START, null)))
	NetBus.is_server_mode = was_server
	NetBus._codecs.erase(999)
	NetBus.event_received.disconnect(listen)
	expect(received == [NetEvent.Kind.START], "server dispatches valid client commands from the current protocol only")

func _playback() -> void:
	var playback := SnapshotBuffer.new()
	playback.map_px = Vector2(512, 256)
	var a := {"players": {2: _actor(Vector2(508, 100))}, "pickups": {}}
	var b := {"players": {2: _actor(Vector2(4, 100))}, "pickups": {}}
	playback.push(10, a)
	playback.push(12, b)
	var shown := playback.sample(11)
	expect(shown["players"][2]["pos"].is_equal_approx(Vector2(0, 100)), "playback interpolates across map seam")
	shown["players"][2]["pos"] = Vector2(99, 99)
	expect(playback.sample(11)["players"][2]["pos"].is_equal_approx(Vector2(0, 100)), "presentation edits do not mutate buffered positions")
	expect(a["players"][2]["state"]["actor"][POS] == Vector2(508, 100), "sampling leaves source snapshot intact")

func _body(wire: PackedByteArray, type: int) -> NetCodec.Reader:
	expect(not wire.is_empty() and wire[0] == type, "packet type")
	return NetCodec.Reader.new(wire, 1)

func _state(codec: NetCodec, wire: PackedByteArray) -> Dictionary:
	var stream := _body(wire, NetCodec.STATE)
	var decoded := codec.decode_state(stream)
	if not decoded.is_empty(): expect(stream.remaining() == 0, "STATE decoder consumes packet")
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


# READY 齐备才进入 COUNTDOWN；重复 READY 与局中重连不重启回合。
func _ready_flow() -> void:
	var session := LobbySession.new()
	session.mode = PvpSession.MODE_TEAM
	var stub := ReadyWorld.new()
	session.add_child(stub)
	session.world = stub
	session.seats = {
		1: {"peer": 11, "name": "A", "token": "a".repeat(32), "ready": false, "team": 1, "deadline": 0.0},
		2: {"peer": 12, "name": "B", "token": "b".repeat(32), "ready": false, "team": 2, "deadline": 0.0},
	}
	session._on_event(11, NetEvent.Kind.READY, 2)
	expect(not session.seats[1]["ready"], "READY for another round is ignored")
	session._on_event(99, NetEvent.Kind.READY, 1)
	expect(not session.seats[1]["ready"], "READY from an unseated peer is ignored")
	session._on_event(11, NetEvent.Kind.READY, 1)
	expect(session.seats[1]["ready"], "a current-round READY is accepted")
	expect(stub.rules.phase == NetEvent.RoundState.WAITING, "WAITING is kept until every seat is ready")
	session._on_event(12, NetEvent.Kind.READY, 1)
	expect(stub.rules.phase == NetEvent.RoundState.COUNTDOWN and is_equal_approx(stub.rules.round_timer, 3.0),
			"the last READY starts a full 3 second countdown")
	stub.rules.advance(0.5)
	session._on_event(12, NetEvent.Kind.READY, 1)
	expect(stub.rules.phase == NetEvent.RoundState.COUNTDOWN and is_equal_approx(stub.rules.round_timer, 2.5),
			"a repeated READY does not restart the countdown")
	stub.rules.advance(2.5)
	session.seats[2]["ready"] = false
	session._on_event(12, NetEvent.Kind.READY, 1)
	expect(session.seats[2]["ready"] and stub.rules.phase == NetEvent.RoundState.PLAYING,
			"a reconnect READY only restores its own data sending")
	stub.rules = MatchRules.new()
	session.remove_seat(2)
	expect(session.world == null, "an expiring seat cancels the unstarted match")
	session.free()
