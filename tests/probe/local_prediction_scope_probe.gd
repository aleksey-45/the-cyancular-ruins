extends "res://tests/probe/prediction_reuse_probe.gd"

var remote: Node2D
var remote_state: Dictionary

func _remote_data(pos: Vector2) -> Dictionary:
	var data: Dictionary = game._local.capture_state()
	data.merge({"pos": pos, "vel": Vector2.ZERO, "knock": Vector2.ZERO,
			"role": 2, "pose": data["state"], "waterproof": data["wp"], "downed": false,
			"rewind": false, "epoch": 1, "respawn_tick": 0, "view_tick": 100,
			"input_ack": 0, "action_ack": 0, "input_age": 0, "axis": 0.0, "held": 0,
			"aim": Vector2.RIGHT, "move_mult": Vector2.ONE, "driver": game._local.capture_driver_state(),
			"input": InputBuffer.neutral(), "rewind_path": []}, true)
	return data

func _with_remote(at: int) -> Dictionary:
	var frame := _frame(at)
	frame["world"]["players"][2] = remote_state.duplicate(true)
	frame["world"]["pickups"] = {}
	return frame

func _check_read_only_proxy() -> void:
	remote = preload("res://scenes/player/player_replica.tscn").instantiate()
	remote.role = 2
	game._world.add_child(remote)
	remote.bind_local(game._local)
	remote.set_ghost_layer(2)
	game._replicas[2] = remote
	game._rollback.bind(game._local, game._replicas)
	game._local.collision_mask = 2
	remote_state = _remote_data(Vector2(5000, 500))
	remote_state["driver"]["shot_serial"] = 800
	remote.apply_snapshot(remote_state, game._local.position, 100)
	game._apply_authority(_with_remote(100))
	_advance(6)
	var saved := game._rollback.checkpoint_state(102)
	assert(saved["players"].keys() == [1] and saved["cursors"].keys() == [1],
			"replay history must contain only the local actor and its input cursor")
	assert(remote._forecast.shot_serial == 0 and remote._forecast.weapons.current_inst() == 0,
			"a remote authoritative weapon must not become an independently simulated weapon")
	var state: Array = game._local.capture_prediction_state()
	var projectiles: Dictionary = game._rollback.combat_prediction.snapshot_projectiles()
	assert(not remote.receive_input(102, {"frames": [], "actions": [InputBuffer.neutral().merged({
			"seq": 900, "target_tick": 103, "pressed": PacketInputSource.BIT_ATTACK}, true)]}))
	assert(remote._motion_frames.size() == 1)
	remote_state["driver"]["shot_serial"] += 1
	remote_state["hp"] -= 1
	remote_state["pos"] += Vector2(30, 10)
	game._apply_authority(_with_remote(102))
	assert(game._rollback.diagnostics["replay_ticks"] == 0 and game._local.capture_prediction_state() == state,
			"far-away remote position, HP, weapon and input changes must preserve local predictions")
	assert(game._rollback.combat_prediction.snapshot_projectiles() == projectiles)
	assert(not game._rollback._commands[106]["actor_queries"].is_empty(), "empty-space movement queries must be retained")
	print("LOCAL SCOPE READ ONLY OK hints, remote state and weapon changes do not replay local motion")

func _check_new_blocker() -> void:
	var own_at_104: Vector2 = game._rollback.checkpoint_state(104)["players"][1]["pos"]
	remote_state["pos"] = own_at_104 + Vector2(30, 0)
	var frame := _with_remote(102)
	game._apply_authority(frame)
	assert(game._rollback.reuse_detail["reason"] == "blocking" and game._rollback.diagnostics["replay_ticks"] > 0,
			"a new blocker entering a previously empty movement query must invalidate its first affected tick")
	var state: Array = game._local.capture_prediction_state()
	remote.apply_snapshot(remote_state, game._local.position, 102)
	game._rollback.reconcile(frame["own"], 102, 0, false, frame["world"]["projectiles"])
	assert(game._local.capture_prediction_state() == state,
			"dependency-selected suffix and full local replay must agree against the same proxy timeline")
	print("LOCAL SCOPE BLOCKING OK negative query, first changed contact and full replay agreement")

func _check_bounded_motion() -> void:
	remote._forecast.gravity = 0.0
	remote_state["pos"] = Vector2(GameParameters.MAP_WIDTH - 2.0, 500)
	remote_state["vel"] = Vector2(120, 0)
	remote_state["axis"] = 120.0 / game._local.move_speed
	remote_state["knock"] = Vector2.ZERO
	remote.apply_snapshot(remote_state, Vector2.ZERO, 120)
	remote.anchor_collision(Vector2.ZERO, 123)
	assert(remote._forecast.position.is_equal_approx(Vector2(4, 500)), "proxy extrapolation must wrap across the world seam")
	remote.anchor_collision(Vector2.ZERO, 120 + remote.MOTION_HORIZON)
	var end: Vector2 = remote._forecast.position
	var generated: int = remote.motion_steps
	remote.anchor_collision(Vector2.ZERO, 123)
	remote.anchor_collision(Vector2.ZERO, 120 + remote.MOTION_HORIZON + 20)
	assert(remote._forecast.position == end and remote.proxy_stale and remote._forecast.velocity == Vector2.ZERO,
			"a stale proxy holds its terrain-constrained endpoint and exposes its age")
	assert(remote.motion_steps == generated, "repeated samples and requests beyond the budget do not regenerate the trajectory")
	assert(remote.MOTION_HORIZON == PredictionRollback.MAX_REPLAY, "logical trajectory capacity must cover the complete local recovery window")
	remote_state["respawn_tick"] = 153
	remote.apply_snapshot(remote_state, Vector2.ZERO, 152)
	remote.anchor_collision(Vector2.ZERO, 154)
	assert(remote._ghost.collision_layer == 0)
	remote._forecast.gravity = GameParameters.gravity0
	print("LOCAL SCOPE PROXY OK separate logical horizon, cached samples, stale marker, seam and respawn boundary")

func _check_motion_trajectory() -> void:
	remote_state = _remote_data(Vector2(3000, 500))
	remote_state.merge({"floor": false, "axis": 0.0, "vel": Vector2.ZERO, "jbuf": 0.0,
			"clatch": false, "swim": false, "charge": false}, true)
	remote.apply_snapshot(remote_state, Vector2.ZERO, 200)
	remote.anchor_collision(Vector2.ZERO, 208)
	var fall := GameParameters.gravity0 * ActorStep.DT * ActorStep.DT * (8.0 * 9.0 / 2.0)
	assert(is_equal_approx(remote._forecast.position.y, 500.0 + fall), "airborne proxies integrate gravity beyond six ticks")
	assert(not remote.proxy_stale and remote.proxy_sample_tick == 208)
	var wall := StaticBody2D.new()
	var wall_shape := CollisionShape2D.new()
	wall_shape.shape = RectangleShape2D.new()
	wall_shape.shape.size = Vector2(16, 800)
	wall.position = Vector2(3208, 500)
	wall.add_child(wall_shape)
	game._world.add_child(wall)
	var floor_body := StaticBody2D.new()
	var floor_shape := CollisionShape2D.new()
	floor_shape.shape = RectangleShape2D.new()
	floor_shape.shape.size = Vector2(800, 20)
	floor_body.position = Vector2(3200, 710)
	floor_body.add_child(floor_shape)
	game._world.add_child(floor_body)
	await get_tree().physics_frame
	TileDefs.terrain.notify_geometry_changed(Rect2())
	remote_state["vel"] = Vector2(700, 0)
	remote_state["axis"] = 1.0
	remote.apply_snapshot(remote_state, Vector2.ZERO, 210)
	remote.anchor_collision(Vector2.ZERO, 242)
	var blocked: Vector2 = remote._forecast.position
	assert(remote._forecast.collision_rect().end.x <= 3200.01 and remote._forecast.collision_rect().end.y <= 700.01,
			"trajectory cannot extrapolate through a wall or the floor")
	assert(remote._forecast._grounded and remote._forecast.velocity.y == 0.0, "landing changes the proxy movement mode")
	assert(remote._forecast.hp == remote_state["hp"] and remote._forecast.waterproof == remote_state["waterproof"],
			"movement forecasting must not change remote health or oxygen")
	wall.free()
	TileDefs.terrain.notify_geometry_changed(Rect2())
	remote.anchor_collision(Vector2.ZERO, 242)
	assert(remote._forecast.position.x > blocked.x + 100.0, "terrain changes invalidate trajectory and native query caches")
	floor_body.free()
	TileDefs.terrain.notify_geometry_changed(Rect2())
	print("LOCAL SCOPE MOTION OK gravity, wall/floor constraints, landing and terrain cache invalidation")

func _check_combat_ownership() -> void:
	var prediction := game._rollback.combat_prediction
	var hp: int = remote._forecast.hp
	prediction._apply_hit((1 << 48) | 256, 160, 0, remote._forecast, Vector2.ZERO, 300, 10)
	assert(remote._forecast.hp == hp, "local speculative combat must not mutate a remote actor")
	var own_hp: int = game._local.hp
	prediction._apply_hit((2 << 48) | 256, 160, 0, game._local, game._local.position - Vector2(20, 0), 300, 10)
	assert(game._local.hp == own_hp - 10, "known local impacts still participate in local prediction")
	print("LOCAL SCOPE COMBAT OK remote state is read only and local impacts remain predicted")

func _check_motion_storage_boundaries() -> void:
	remote._forecast.gravity = 0.0
	remote._motion_frames.clear()
	remote_state = _remote_data(Vector2(1500, 500))
	remote_state.merge({"axis": 0.0, "vel": Vector2.ZERO, "floor": false}, true)
	for at in [800, 802, 804]:
		remote_state["pos"] = Vector2(at * 2.0, 500)
		remote.apply_snapshot(remote_state.duplicate(true), Vector2.ZERO, at)
	# Queries cross several retained anchors in both directions, including before
	# the oldest anchor. The latest anchor must not hide an older valid sample.
	for at in [804, 803, 801, 799, 802, 804]:
		remote.anchor_collision(Vector2.ZERO, at)
		var anchor_tick := 804 if at >= 804 else 802 if at >= 802 else 800
		assert(remote._forecast.position == Vector2(anchor_tick * 2.0, 500),
				"out-of-order sample requests must select the latest anchor at or before the query")
	var full: Dictionary = remote._forecast.capture_motion_state()
	remote._forecast.position += Vector2(100, 200)
	remote._forecast.velocity = Vector2(70, 80)
	remote._forecast.restore_motion_state(full, remote._forecast.state)
	assert(remote._forecast.capture_motion_state() == full, "the dictionary state adapter must retain every motion field")
	remote_state["rewind"] = true
	remote_state["vel"] = Vector2(60, 0)
	remote_state["rewind_path"] = [{"tick": 840,
			"body": {"pos": Vector2(1500, 600), "facing": -1, "squat": true, "down": true}}]
	remote.apply_snapshot(remote_state, Vector2.ZERO, 800)
	remote.anchor_collision(Vector2.ZERO, 840)
	assert(not remote.proxy_stale and remote.proxy_sample_tick == 840
			and remote._forecast.position == Vector2(1500, 600) and remote._forecast.velocity == Vector2(60, 0)
			and remote._forecast.is_downed() and remote._forecast.facing_direction == -1,
			"a known rewind knot remains valid beyond the ordinary motion horizon")
	remote.anchor_collision(Vector2.ZERO, 841)
	assert(remote.proxy_stale and remote._forecast.velocity == Vector2.ZERO,
			"a query beyond the last known rewind knot must freeze motion")
	remote.anchor_collision(Vector2.ZERO, 840)
	assert(not remote.proxy_stale and remote._forecast.velocity == Vector2(60, 0),
			"resampling a known knot after a stale query must restore its motion")
	remote._forecast.gravity = GameParameters.gravity0
	print("LOCAL SCOPE STORAGE OK anchor lookup, dictionary state adapter and rewind horizon boundaries")

func _check_regional_invalidation() -> void:
	remote._forecast.gravity = 0.0
	remote_state = _remote_data(Vector2(3000, 500))
	remote_state.merge({"axis": 1.0, "vel": Vector2(700, 0), "floor": false}, true)
	remote.apply_snapshot(remote_state, Vector2.ZERO, 300)
	remote.anchor_collision(Vector2.ZERO, 308)
	var endpoint: Vector2 = remote._forecast.position
	var generated: int = remote.motion_steps
	var revision := CollisionBuilder.geometry_revision
	var map_size := Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	TileDefs.terrain.notify_geometry_changed(Rect2(0, 0, 128, 128))
	assert(not CollisionBuilder.affects_since(revision, remote._motion_frames[-1]["bounds"]))
	remote.anchor_collision(Vector2.ZERO, 308)
	assert(remote.motion_steps == generated and remote._forecast.position == endpoint,
			"a distant terrain rebuild must preserve the complete local proxy trajectory")
	var wall := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	shape.shape = RectangleShape2D.new()
	shape.shape.size = Vector2(16, 400)
	wall.position = Vector2(3078, 500)
	wall.add_child(shape)
	game._world.add_child(wall)
	await get_tree().physics_frame
	TileDefs.terrain.notify_geometry_changed(Rect2(3070, 300, 16, 400))
	remote.anchor_collision(Vector2.ZERO, 308)
	assert(remote.motion_steps > generated and remote._forecast.collision_rect().end.x <= 3070.01,
			"a newly inserted wall entering the swept query region must invalidate the cached empty path")
	revision = CollisionBuilder.geometry_revision
	TileDefs.terrain.notify_geometry_changed(Rect2(map_size.x - 64, 0, 64, 128))
	assert(CollisionBuilder.affects_since(revision, Rect2(-8, 0, 32, 100)), "change regions must wrap across map seams")
	revision = CollisionBuilder.geometry_revision
	for index in 129:
		TileDefs.terrain.notify_geometry_changed(Rect2(0, 0, 16, 16))
	assert(CollisionBuilder.affects_since(revision, Rect2(5000, 3000, 100, 100)), "expired change history must conservatively invalidate")
	wall.free()
	TileDefs.terrain.notify_geometry_changed(Rect2())
	remote._forecast.gravity = GameParameters.gravity0
	print("LOCAL SCOPE REGIONS OK distant reuse, new negative-path blocker, seam and history expiry")

func _check_history_metadata() -> void:
	var actor := NativeActorBody.new()
	add_child(actor)
	var collider := NativeActorCollider.new()
	collider.initialize(actor, 2)
	var snapshots := NativePredictionHistory.new()
	var states := {}
	snapshots.bind_sources(states, {}, {}, 32)
	snapshots.configure_remotes([[17, actor, collider, 0]])
	snapshots.remember(900, game._local, 0, [], [], {}, 0, 0, 0)
	var before: Dictionary = states[900].duplicate(true)
	actor.rewinding = true
	collider.collision_layer = 0
	snapshots.configure_remotes([[17, actor, collider, 925]])
	snapshots.remember(901, game._local, 0, [], [], {}, 0, 0, 0)
	assert(states[900] == before and states[901]["remote"][17] == [true, 925]
			and states[901]["layers"][17] == 0,
			"rewind, respawn and layer changes must create new metadata without altering older checkpoints")
	actor.free()
	snapshots.remember(902, game._local, 0, [], [], {}, 0, 0, 0)
	assert(states[902]["remote"].is_empty() and states[902]["layers"].is_empty()
			and states[901]["remote"].has(17), "destroyed proxies must disappear only from new checkpoints")
	snapshots.configure_remotes([])
	snapshots.remember(903, game._local, 0, [], [], {}, 0, 0, 0)
	assert(states[903]["remote"].is_empty() and states[900] == before)
	print("LOCAL SCOPE HISTORY OK immutable metadata across mode, layer, respawn and lifetime changes")

func _check_projectile_dependencies() -> void:
	var prediction := game._rollback.combat_prediction
	remote_state["respawn_tick"] = 0
	remote_state["rewind"] = false
	remote_state["vel"] = Vector2.ZERO
	remote_state["pos"] = Vector2(5000, 500)
	remote.apply_snapshot(remote_state, Vector2.ZERO, 160)
	var state := {"type_id": 1, "pos": Vector2(200, 100), "vel": Vector2(600, 0), "traveled": 0.0,
			"fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	var id := (1 << 48) | 256
	prediction.seed_projectile(id, state, 159, game._local)
	var bullet: BulletBase = prediction.projectiles[id]["bullet"]
	bullet.adjudicated_pos = Vector2(0, 100)
	prediction.tick = 160
	prediction.begin_tick(160)
	assert(prediction._contact(bullet, [game._local, remote._forecast]) == null)
	assert(prediction.proxy_queries_match(160, [remote._forecast]))
	remote_state["pos"] = Vector2(100, 100)
	remote.apply_snapshot(remote_state, Vector2.ZERO, 160)
	assert(not prediction.proxy_queries_match(160, [remote._forecast]),
			"a remote actor entering an originally empty bullet path must invalidate that dependency")
	prediction.clear()
	id = (2 << 48) | 256
	state["pos"] = Vector2(3000, 100)
	prediction.actors = {1: game._local, 2: remote._forecast}
	prediction.seed_projectile(id, state, 159, remote._forecast)
	prediction.begin_tick(160)
	prediction.step(160, [game._local, remote._forecast], false)
	remote_state["rewind"] = true
	remote.apply_snapshot(remote_state, Vector2.ZERO, 160)
	assert(not prediction.proxy_queries_match(160, [remote._forecast]),
			"a changed owner rewind mode must invalidate paused projectile motion even without a contact")
	prediction.clear()
	print("LOCAL SCOPE DEPENDENCIES OK empty bullet paths and owner rewind modes")

func _check_remote_projectile_end() -> void:
	var prediction := game._rollback.combat_prediction
	var id := (2 << 48) | 512
	var state := {"type_id": 1, "pos": Vector2(200, 100), "vel": Vector2(600, 0), "traveled": 0.0,
			"fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	for local_hit in [false, true]:
		prediction.seed_projectile(id, state, 159, remote._forecast)
		var bullet: BulletBase = prediction.projectiles[id]["bullet"]
		prediction.projectiles[id]["sim_tick"] = 161
		if local_hit: prediction._apply_hit(id, 161, 0, game._local, game._local.position, 0, 1)
		prediction._finish_direct(bullet, 161)
		var span := prediction.end_projectiles({"ids": [id], "tick": 160})
		assert((span != Vector2i.ZERO) == local_hit,
				"remote ordinary bullet ends replay only when an already predicted local hit must be revoked")
		assert(bullet.finished)
		prediction.clear()
	print("LOCAL SCOPE END OK independent projectile lifetime versus revoked local hit")

func _check_remote_birth() -> void:
	_setup()
	remote = preload("res://scenes/player/player_replica.tscn").instantiate()
	remote.role = 2
	game._world.add_child(remote)
	remote.bind_local(game._local)
	remote.set_ghost_layer(2)
	game._replicas[2] = remote
	remote_state = _remote_data(Vector2(5000, 500))
	remote.apply_snapshot(remote_state, game._local.position, 100)
	game._rollback.bind(game._local, game._replicas)
	game._rollback._prepare_colliders()
	game._rollback._remember_state()
	var frame := _with_remote(100)
	game._apply_authority(frame)
	_advance(6)
	var before: Array = game._local.capture_prediction_state()
	var applications: int = game._authority_applications
	var spawn := {"id": (2 << 48) | 1024, "type_id": 1, "pos": Vector2(5000, 500), "vel": Vector2(600, 0), "tick": 102}
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, spawn)
	game._apply_pending_authority()
	assert(game._authority_applications == applications and game._local.capture_prediction_state() == before,
			"an independent late birth must catch up without restoring local actor/history")
	var expected := game._rollback.combat_prediction.snapshot_projectiles()
	assert(expected[spawn["id"]]["pos"] == Vector2(5050, 500))
	assert(game._rollback._states[102]["projectiles"].has(spawn["id"]),
			"independent catch-up must backfill projectile checkpoints for later STATE and suffix validation")
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, spawn)
	assert(game._pending_replay.is_empty() and game._rollback.combat_prediction.snapshot_projectiles() == expected,
			"duplicate birth must preserve the caught-up projectile")
	game._rollback.reconcile(frame["own"], 100, 0, false, {})
	assert(game._local.capture_prediction_state() == before and game._rollback.combat_prediction.snapshot_projectiles() == expected,
			"independent birth and complete local replay must produce identical actor/projectile state")
	# 出生路径靠近历史本地位置时，必须保留迟到命中的正常重放。
	spawn = spawn.merged({"id": (2 << 48) | 1280,
			"pos": game._rollback._states[102]["contacts"][1][0] - Vector2(15, 0)}, true)
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, spawn)
	assert(game._pending_replay_tick == 102, "possible local contact must invalidate its original tick")
	game._apply_pending_authority()
	assert(game._local.hp < 100 and game._rollback.diagnostics["replay_ticks"] == 5)
	before = game._local.capture_prediction_state()
	expected = game._rollback.combat_prediction.snapshot_projectiles()
	game._rollback.reconcile(frame["own"], 100, 0, false, {})
	assert(game._local.capture_prediction_state() == before and game._rollback.combat_prediction.snapshot_projectiles() == expected)
	# 地形历史在可能路径内变化、缺少历史，以及爆炸弹都不能用当前地形直接追赶。
	spawn = spawn.merged({"id": (2 << 48) | 1536, "pos": Vector2(5000, 500)}, true)
	var terrain_blast := _blast()
	spawn["pos"] = terrain_blast["pos"]
	_predict(terrain_blast)
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, spawn)
	assert(game._pending_replay_tick == 102)
	game._terrain.restore_checkpoint(100)
	game._pending_replay = ""
	game._pending_replay_tick = 0
	spawn["id"] += 256
	game._rollback._states[103].erase("contacts")
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, spawn)
	assert(game._pending_replay_tick == 102)
	game._pending_replay = ""
	game._pending_replay_tick = 0
	spawn = spawn.merged({"id": (2 << 48) | 2048, "type_id": 5}, true)
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, spawn)
	assert(game._pending_replay_tick == 102)
	game._rollback.combat_prediction.clear()
	game.free()
	print("LOCAL SCOPE BIRTH OK independent catch-up/checkpoints, duplicate, local hit, terrain, missing history and grenade")

func _check_frame_batch() -> void:
	_setup()
	game.phase = PvpMatchClient.Phase.ONLINE
	remote = preload("res://scenes/player/player_replica.tscn").instantiate()
	remote.role = 2
	game._world.add_child(remote)
	remote.bind_local(game._local)
	game._replicas[2] = remote
	remote_state = _remote_data(Vector2(5000, 500))
	remote.apply_snapshot(remote_state, game._local.position, 100)
	game._rollback.bind(game._local, game._replicas)
	_advance(6)
	game._on_state(_with_remote(102))
	game._apply_frame_authority()
	var applications: int = game._authority_applications
	var before: Array = game._local.capture_prediction_state()
	var spawn := {"id": (2 << 48) | 4096, "type_id": 1, "tick": 106,
			"pos": game._rollback.checkpoint_state(106)["contacts"][1][0] - Vector2(15, 0), "vel": Vector2(600, 0)}
	game._on_state(_with_remote(104))
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, spawn)
	game._on_state(_with_remote(105))
	game._apply_frame_authority()
	assert(game._deferred_authority.size() == 3 and game._last_tick == 102
			and not game._rollback.combat_prediction.projectiles.has(spawn["id"]),
			"late messages must not mutate the simulation after this display frame's batch")
	assert(game._authority_applications == applications and game._local.capture_prediction_state() == before)
	var display_frame := Engine.get_process_frames()
	while Engine.get_process_frames() == display_frame:
		await get_tree().process_frame
	game._apply_frame_authority()
	assert(game._deferred_authority.is_empty() and game._own_tick == 105
			and game._authority_applications == applications + 1,
			"multiple late states and an interacting event must merge into one next-frame reconciliation")
	assert(game._local.hp < 100 and game._rollback.diagnostics["replay_ticks"] == 1,
			"the newest matching state preserves the prefix and only the affected tick is replayed")
	game._apply_frame_authority()
	assert(game._authority_applications == applications + 1)
	game._on_state(_with_remote(106))
	assert(game._deferred_authority.size() == 1)
	game._clear_dynamics()
	assert(game._deferred_authority.is_empty(), "a new baseline must discard the previous batch's queued messages")
	game.free()
	print("LOCAL SCOPE BATCH OK held mutations, merged state/event, suffix replay, one batch and reset")

func _run() -> void:
	_setup()
	_check_read_only_proxy()
	_check_new_blocker()
	_check_bounded_motion()
	await _check_motion_trajectory()
	await _check_regional_invalidation()
	_check_motion_storage_boundaries()
	_check_history_metadata()
	_check_projectile_dependencies()
	_check_remote_projectile_end()
	_check_combat_ownership()
	game._rollback.combat_prediction.clear()
	game.free()
	_check_remote_birth()
	await _check_frame_batch()
	print("LOCAL PREDICTION SCOPE PROBE OK")
	get_tree().quit()
