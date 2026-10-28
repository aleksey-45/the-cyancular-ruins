extends "res://tests/network/tunnel_peer.gd"

const ScriptedInput := preload("res://tests/network/match_input.gd")
var room: RoomSession
var elapsed := 0.0
var max_queue := 0
var gameplay: Dictionary = {}
var origin_tick := -1
var trace: Array = []
var baselines: Array = []
var finished := false
var capture_trace := true
var server_stall_ms := 0
var network_seconds := 0.0
var settle_seconds := 10.0
var sample: Dictionary = {}
var sample_wall := 0.0
var sample_reported := false
var window_announced := false
var clock_wall := 0.0
var clock_us := 0

class MatchRoom extends RoomSession:
	var rejoin_delay_seconds := 0.0
	var initialized := false
	func rejoin(peer: int, target_code: String, token: String) -> void:
		if rejoin_delay_seconds > 0:
			await get_tree().create_timer(rejoin_delay_seconds).timeout
		super.rejoin(peer, target_code, token)
	func send_baselines() -> void:
		if not initialized:
			initialized = true
			var rifle: int = WeaponRegistry.all_ids().filter(func(id: int) -> bool:
				return WeaponRegistry.scene_of(id) == "res://scenes/weapons/rifle_test.tscn")[0]
			var ids := WeaponRegistry.all_ids()
			for role in seats:
				var index: int = role - 1 if mode == "team" else int(seats[role]["name"].trim_prefix("Bot"))
				var cell := ScriptedInput.home(index, mode)
				world.rules.spawns[role] = cell
				world.players[role].position = (Vector2(cell) + Vector2.ONE * 0.5) * GameParameters.TILE_SIZE
				world.players[role].weapons.set_initial_inventory([ids[index % ids.size()], rifle])
		super.send_baselines()

func _ready() -> void:
	clock_wall = Time.get_unix_time_from_system()
	clock_us = Time.get_ticks_usec()
	var args := OS.get_cmdline_user_args()
	capture_trace = not args.has("--no-trace")
	if args.has("--server-stall-ms"):
		server_stall_ms = int(args[args.find("--server-stall-ms") + 1])
	if args.has("--network-seconds"):
		network_seconds = float(args[args.find("--network-seconds") + 1])
		settle_seconds = float(args[args.find("--settle-seconds") + 1])
	seed(123456)
	NetBus.compression_enabled = not args.has("--none")
	assert(NetBus.start_server(int(args[args.find("--port") + 1])) == OK)
	room = MatchRoom.new()
	if args.has("--rejoin-delay-seconds"):
		room.rejoin_delay_seconds = float(args[args.find("--rejoin-delay-seconds") + 1])
	add_child(room)
	NetBus.input_received.connect(func(peer: int, packet: Dictionary) -> void:
		if capture_trace and origin_tick >= 0 and not finished:
			trace.append({"tick": room.world._snap_tick - origin_tick, "role": room.role_of(peer), "flow": 0, "payload": packet.duplicate(true)}))
	process_physics_priority = 100
	await start_test_tunnel(true, NetBus.server_port)
	print("MATCH SERVER READY")

func _physics_process(delta: float) -> void:
	if room.world == null or finished:
		return
	var world := room.world
	var now := clock_wall + (Time.get_ticks_usec() - clock_us) / 1000000.0
	elapsed += delta
	if origin_tick < 0:
		origin_tick = world._snap_tick
		for role in room.seats:
			gameplay[role] = {"distance": 0.0, "jumps": 0, "climb_pixels": 0.0, "shots": 0,
				"position": world.players[role].position, "epoch": world.players[role].input_buffer.epoch}
			if capture_trace:
				var baseline := room.baseline_for(role)
				baseline["frame"] = trace_frame(world, role, trace_world(world))
				baselines.append({"role": role, "payload": baseline})
		if capture_trace:
			world.event.connect(func(kind: int, data: Variant, except_role: int) -> void:
				for role in room.seats:
					if role != except_role and not finished:
						trace.append({"tick": world._snap_tick - origin_tick, "role": role, "flow": 2, "payload": [kind, data]}))
	for role in world.players:
		var player: CharacterBody2D = world.players[role]
		var observed: Dictionary = gameplay[role]
		var movement := GridPathfinder.toroidal_delta_px(observed["position"], player.position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if observed["epoch"] == player.input_buffer.epoch and not player.rewinding:
			observed["distance"] += absf(movement.x)
			if player.climb.is_latched():
				observed["climb_pixels"] += maxf(-movement.y, 0.0)
		if player.step_actions.any(func(action: Dictionary) -> bool:
			return action["kind"] == "impulse" and action["value"] == SquashStretch.Impulse.JUMP):
			observed["jumps"] += 1
		observed["position"] = player.position
		observed["epoch"] = player.input_buffer.epoch
		observed["shots"] = maxi(observed["shots"], player.shot_serial)
		max_queue = maxi(max_queue, player.input_buffer.frames.size())
		assert(max_queue <= InputBuffer.FUTURE_TICKS + 1)
	if capture_trace and world._snap_tick % 2 == 0:
		var state := trace_world(world)
		for role in room.seats:
			trace.append({"tick": world._snap_tick - origin_tick, "role": role, "flow": 1, "payload": trace_frame(world, role, state)})
	if elapsed > 8 and not window_announced:
		window_announced = true
		room.broadcast_room()
		print("MATCH NETWORK WINDOW")
		if server_stall_ms > 0:
			OS.delay_msec(server_stall_ms)
		if network_seconds > 0:
			var start := now + 1.0
			sample = {"shape_start": start, "start": start + settle_seconds,
				"end": start + settle_seconds + network_seconds, "max_frame_ms": 0.0,
				"input_ticks": 0, "input_missing_ticks": 0}
			world.broadcast(NetEvent.Kind.MESSAGE, "NETWORK SAMPLE " + JSON.stringify(sample))
			print("NETWORK SAMPLE SETTINGS " + JSON.stringify(sample))
	if not sample.is_empty() and not sample_reported:
		if sample_wall > 0 and sample_wall < sample["end"] and now >= sample["start"]:
			sample["max_frame_ms"] = maxf(sample["max_frame_ms"], (now - sample_wall) * 1000.0)
		if now >= sample["start"] and now < sample["end"]:
			sample["input_ticks"] += world.players.size()
			for player in world.players.values():
				if player.input_buffer._missing > InputBuffer.HOLD_TICKS:
					sample["input_missing_ticks"] += 1
		if now >= sample["end"]:
			sample_reported = true
			print("NETWORK SAMPLE SERVER " + JSON.stringify(sample))
	sample_wall = now
	if world._round_state == NetEvent.RoundState.MATCH_OVER:
		finished = true
		for role in gameplay:
			var actor: Dictionary = gameplay[role]
			actor.erase("position")
			actor.erase("epoch")
			actor["damage"] = world._stats[role]["dealt"]
			assert(actor["distance"] > 100 and actor["jumps"] > 0 and actor["climb_pixels"] > 64 and actor["shots"] > 0,
				"MATCH SERVER FAIL role=%d actual behavior: %s" % [role, actor])
		assert(world._stats.values().any(func(stats: Dictionary) -> bool: return stats["dealt"] > 0))
		print("GAMEPLAY METRICS " + JSON.stringify(gameplay))
		if capture_trace:
			var path := ProjectSettings.globalize_path("res://").path_join(".test_logs/network/trace_%d.bin" % world.players.size())
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_var({"count": world.players.size(), "ticks": world._snap_tick - origin_tick, "baselines": baselines, "messages": trace})
		print("MATCH SERVER OK players=%d max_queue=%d natural_result=true" % [world.players.size(), max_queue])
		# runner 随后会终止常驻服务端；先正常排空本场的详细诊断。
		FrameTrace.finish()

func trace_world(world: AuthorityWorld) -> Dictionary:
	var state := world.world_state()
	state["projectiles"] = {}
	for bullet: BulletBase in world.live_bullets():
		state["projectiles"][bullet.entity_id] = {"id": bullet.entity_id, "input_seq": bullet.input_seq, "input_epoch": bullet.input_epoch,
				"scene": bullet.scene_file_path, "shooter_role": bullet.shooter.role, "pos": bullet.position, "vel": bullet.velocity_vec,
				"speed": bullet.speed, "range": bullet.max_range, "size": bullet.size, "color": bullet.bullet_color}
	for id in state["pickups"]: state["pickups"][id]["inst"] = id
	return state

func trace_frame(world: AuthorityWorld, role: int, state: Dictionary) -> Dictionary:
	var frame := world.state_for(role, state)
	frame["own"]["input"] = world.players[role].input_buffer._last.duplicate()
	return frame
