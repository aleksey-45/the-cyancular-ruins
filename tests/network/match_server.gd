extends Node

var room: RoomSession
var elapsed := 0.0
var max_queue := 0
var weapon_index := -1
var terrain_checked := false
var rounds_checked := false
var origin_tick := -1
var trace: Array = []
var baselines: Array = []
var settled := false
var trace_done := false
var finished := false
var checked: Dictionary = {}
var beta_phase := 0
var drop_checked := false
var stall := false
var stall_announced := false
var neutral_ticks := 0
var rewind_started := -1.0
var battle_started := -1.0
var action_targets: Dictionary = {}
var consumed_actions: Dictionary = {}
var _timing_report := 0
var battle_seconds := 6.0
var capture_trace := true
var _last_throttles: Dictionary = {}
var network_seconds := 0.0
var settle_seconds := 10.0
var _sample: Dictionary = {}
var _sample_wall := 0.0
var _sample_reported := false
var _clock_wall := 0.0
var _clock_us := 0

func _ready() -> void:
	_clock_wall = Time.get_unix_time_from_system()
	_clock_us = Time.get_ticks_usec()
	var args := OS.get_cmdline_user_args()
	var port := int(args[args.find("--port") + 1])
	stall = args.has("--stall")
	capture_trace = not args.has("--no-trace")
	if args.has("--battle-seconds"):
		battle_seconds = float(args[args.find("--battle-seconds") + 1])
	if args.has("--network-seconds"):
		network_seconds = float(args[args.find("--network-seconds") + 1])
		settle_seconds = float(args[args.find("--settle-seconds") + 1])
	seed(123456)
	assert(NetBus.start_server(port) == OK)
	if args.has("--fixed-throttle"):
		multiplayer.peer_connected.connect(func(peer_id: int) -> void:
			(multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(peer_id).throttle_configure(5000, 32, 0))
	if args.has("--none"):
		(multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_host().compress(ENetConnection.COMPRESS_NONE)
	room = RoomSession.new()
	add_child(room)
	NetBus.event_received.connect(func(peer: int, kind: int, data: Variant) -> void:
		if kind == NetEvent.Kind.MESSAGE and data == "CHECK OK":
			checked[room.role_of(peer)] = true)
	NetBus.input_received.connect(func(peer: int, packet: Dictionary) -> void:
		var role := room.role_of(peer)
		for action: Dictionary in packet["actions"]:
			action_targets[Vector3i(role, action["epoch"], action["seq"])] = action["target_tick"]
		if capture_trace and origin_tick >= 0 and not trace_done:
			trace.append({"tick": room.world._snap_tick - origin_tick, "role": room.role_of(peer), "flow": 0, "payload": packet.duplicate(true)}))
	process_physics_priority = 100
	print("MATCH SERVER READY")

func _physics_process(delta: float) -> void:
	var now := _clock_wall + (Time.get_ticks_usec() - _clock_us) / 1000000.0
	if not _sample.is_empty() and not _sample_reported:
		if _sample_wall > 0 and _sample_wall < _sample["end"] and now >= _sample["start"]:
			_sample["max_frame_ms"] = maxf(_sample["max_frame_ms"], (now - _sample_wall) * 1000.0)
		if now >= _sample["end"]:
			print("NETWORK SAMPLE SERVER " + JSON.stringify(_sample))
			_sample_reported = true
	_sample_wall = now
	if room.world == null:
		return
	var world := room.world
	if not _sample.is_empty():
		for player in world.players.values():
			player.combat.hp = player.combat.max_hp
	if not _sample.is_empty() and now >= _sample["start"] and now < _sample["end"]:
		_sample["input_ticks"] += world.players.size()
		for player in world.players.values():
			if player.input_buffer._missing > InputBuffer.HOLD_TICKS:
				_sample["input_missing_ticks"] += 1
	for role in room.seats:
		var seat: Dictionary = room.seats[role]
		if seat["peer"] != 0:
			var peer := (multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(seat["peer"])
			var throttle := int(peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE))
			if _last_throttles.get(role, -1) != throttle:
				print("SEND THROTTLE " + JSON.stringify({"role": role, "throttle": throttle,
					"wall_seconds": Time.get_unix_time_from_system(), "tick": world._snap_tick}))
				_last_throttles[role] = throttle
	if not room.seats.values().all(func(seat: Dictionary) -> bool: return seat["ready"]):
		return
	elapsed += delta
	if elapsed >= _timing_report:
		_timing_report += 5
		var timing := {}
		for role in world.players:
			var player: CharacterBody2D = world.players[role]
			var peer := (multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(room.seats[role]["peer"])
			timing[role] = {"lead": player.input_buffer.lead, "seq": player.input_buffer.timing_seq,
				"ack": player.input_buffer.ack, "epoch": player.input_buffer.epoch,
				"frames": player.input_buffer.frames.size(), "held": player.step_input._held, "rewind": player.rewinding,
				"throttle": peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE)}
		print("INPUT TIMING t=%.1f phase=%d %s" % [elapsed, beta_phase, JSON.stringify(timing)])
	if elapsed > 3.1 and not stall_announced:
		stall_announced = true
		print("MATCH NETWORK WINDOW")
	if trace_done:
		if elapsed - battle_started > battle_seconds + 5 and checked.size() == room.seats.size() and not finished:
			finished = true
			world.rules.winner = 1
			world.rules.finish(world)
		return
	if origin_tick < 0:
		origin_tick = world._snap_tick
	if capture_trace and baselines.is_empty():
		for role in room.seats:
			var baseline := room.baseline_for(role)
			baseline["frame"] = legacy_frame(world, role, legacy_world(world))
			baselines.append({"role": role, "payload": baseline})
		world.event.connect(func(kind: int, data: Variant, except_role: int) -> void:
			for role in room.seats:
				if role != except_role:
					trace.append({"tick": world._snap_tick - origin_tick, "role": role, "flow": 2, "payload": [kind, data]}))
	if capture_trace and world._snap_tick % 2 == 0:
		var state := legacy_world(world)
		for role in room.seats:
			trace.append({"tick": world._snap_tick - origin_tick, "role": role, "flow": 1, "payload": legacy_frame(world, role, state)})
	for player in world.players.values():
		max_queue = maxi(max_queue, player.input_buffer.frames.size())
		if elapsed > 3.1 and elapsed < 8 and player.input_buffer._missing > InputBuffer.HOLD_TICKS:
			neutral_ticks += 1
			assert(player.step_input._axis == 0.0 and player.step_input._held == 0)
		if player.input_buffer.action_ack > 0 and player.input_buffer.action_ack == player.input_seq \
				and (player.step_input._pressed != 0 or player.step_input._released != 0):
			var key := Vector3i(player.role, player.input_buffer.epoch, player.input_seq)
			assert(not consumed_actions.has(key))
			consumed_actions[key] = true
			var age: int = world._snap_tick - action_targets[key]
			assert(age >= 0 and age <= InputBuffer.ACTION_TICKS)
	assert(max_queue <= InputBuffer.FUTURE_TICKS + 1)
	if elapsed > 4 and beta_phase == 0:
		beta_phase = 1
		for bullet in world.live_bullets():
			bullet.queue_free()
		for role in world.players:
			world.respawn(role)
		world.broadcast(NetEvent.Kind.MESSAGE, "TEST HASTE")
	elif elapsed > 6 and beta_phase == 1:
		beta_phase = 2
		world.broadcast(NetEvent.Kind.MESSAGE, "TEST REWIND")
	if beta_phase == 2 and rewind_started < 0 and world.players.values().any(func(player: Node2D) -> bool: return player.rewinding):
		rewind_started = elapsed
	if rewind_started >= 0 and elapsed - rewind_started > 2 and beta_phase == 2:
		beta_phase = 3
		battle_started = elapsed
		world.broadcast(NetEvent.Kind.MESSAGE, "TEST BATTLE")
	var ids := WeaponRegistry.all_ids()
	var index := clampi(int(elapsed - 3), 0, ids.size() - 1)
	if not _sample.is_empty():
		index = ids.find_custom(func(type_id: int) -> bool:
			return WeaponRegistry.scene_of(type_id) == "res://scenes/weapons/rifle_test.tscn")
	if index != weapon_index:
		weapon_index = index
		for player in world.players.values():
			player.weapons.set_initial_inventory([ids[index]])
			player.weapons.current_weapon().fire_cd_timer = 0.0
	if elapsed > 5 and not terrain_checked:
		terrain_checked = true
		for y in TileDefs.sub_rows:
			var found := false
			for x in TileDefs.sub_cols:
				var sub := Vector2i(x, y)
				if TileDefs.bullet_destroyable(TileDefs.sub_texture(sub)):
					TileDefs.damage_sub(sub, 1, "bullet", world.players.values()[0])
					TileDefs.damage_sub(sub, 99999, "bullet", world.players.values()[0])
					found = true
					break
			if found:
				break
	if battle_started >= 0 and elapsed - battle_started > 1 and not rounds_checked:
		rounds_checked = true
		var start_us := Time.get_ticks_usec()
		var start_wall := Time.get_unix_time_from_system()
		world.start_round()
		print("ROUND REBUILD METRICS " + JSON.stringify({"wall_seconds": start_wall,
			"seconds": (Time.get_ticks_usec() - start_us) / 1000000.0, "tick": world._snap_tick}))
	if battle_started >= 0 and elapsed - battle_started > 2 and not drop_checked:
		drop_checked = true
		world.broadcast(NetEvent.Kind.MESSAGE, "TEST DROP")
	if battle_started >= 0 and elapsed - battle_started > 5 and not settled:
		settled = true
		for role in world.players:
			world.respawn(role)
	if network_seconds > 0 and _sample.is_empty() and battle_started >= 0 and elapsed - battle_started > 8:
		for role in world.players:
			world.respawn(role)
		var shape_start := now + 1.0
		_sample = {"shape_start": shape_start, "start": shape_start + settle_seconds,
			"end": shape_start + settle_seconds + network_seconds, "max_frame_ms": 0.0,
			"input_ticks": 0, "input_missing_ticks": 0}
		world.broadcast(NetEvent.Kind.MESSAGE, "NETWORK SAMPLE " + JSON.stringify(_sample))
		print("NETWORK SAMPLE SETTINGS " + JSON.stringify(_sample))
	var sample_done: bool = network_seconds > 0 and not _sample.is_empty() and now >= _sample["end"]
	if sample_done or (network_seconds == 0 and battle_started >= 0 and elapsed - battle_started > battle_seconds):
		if capture_trace:
			var path := ProjectSettings.globalize_path("res://").path_join(".test_logs/network/trace_%d.bin" % world.players.size())
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_var({"count": world.players.size(), "ticks": world._snap_tick - origin_tick, "baselines": baselines, "messages": trace})
			file.close()
		world.broadcast(NetEvent.Kind.MESSAGE, "CHECK CONVERGENCE")
		assert(not stall or neutral_ticks > 0)
		print("MATCH SERVER OK players=%d max_queue=%d weapons=%d terrain=%s round=%s neutral_ticks=%d" % [world.players.size(), max_queue, ids.size(), terrain_checked, rounds_checked, neutral_ticks])
		trace_done = true

# 性能夹具记录完整实体参数，供固定负载回放。
# 固定参数仅写入测试记录，生产 STATE 不传这些字段。
func legacy_world(world: AuthorityWorld) -> Dictionary:
	var state := world.world_state()
	for bullet: BulletBase in world.live_bullets():
		state["projectiles"][bullet.entity_id] = {"id": bullet.entity_id, "input_seq": bullet.input_seq, "input_epoch": bullet.input_epoch,
				"scene": bullet.scene_file_path, "shooter_role": bullet.shooter.role, "pos": bullet.position, "vel": bullet.velocity_vec,
				"speed": bullet.speed, "range": bullet.max_range, "size": bullet.size, "color": bullet.bullet_color}
	for id in state["pickups"]: state["pickups"][id]["inst"] = id
	return state

func legacy_frame(world: AuthorityWorld, role: int, state: Dictionary) -> Dictionary:
	var frame := world.state_for(role, state)
	frame["own"]["input"] = world.players[role].input_buffer._last.duplicate()
	return frame
