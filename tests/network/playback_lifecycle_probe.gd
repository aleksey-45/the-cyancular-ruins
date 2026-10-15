extends Node

class MatchView extends PvpMatchClient:
	func _ready() -> void:
		set_physics_process(false)
		set_process(false)
	func _exit_tree() -> void: pass

var game: MatchView
const REMOTE_ID := (2 << 48) | 77

func _ready() -> void:
	_run.call_deferred()

func _frame(tick: int, players: Dictionary, pickups: Dictionary) -> Dictionary:
	return {"tick": tick, "map_revision": 0, "world": {"players": players, "pickups": pickups},
		"own": {"state": game._local.capture_state(), "epoch": 1, "ack": 0, "action_ack": 0,
			"timing_seq": 0, "lead": 2, "input": InputBuffer.neutral(), "rewind": false}, "time": {}}

func _actor(pos: Vector2) -> Dictionary:
	return {"pos": pos, "vel": Vector2(60, 0), "epoch": 1, "pose": 1, "facing": 1,
		"type_id": 0, "hp": 100, "waterproof": 100.0, "aim": Vector2.RIGHT, "downed": false,
		"previewing": false, "haste": false, "rewind": false}

func _state(frame: Dictionary) -> void:
	game._on_state(frame)
	game._apply_pending_authority()

func _run() -> void:
	PvpSession.role = 1
	PvpSession.beta_mode = false
	PvpSession.room_mode = PvpSession.MODE_PVP
	Level0.pvp_mode = true
	MazeGenerator.set_map_file("res://maps/newfactory.cyrm")
	var grid := WorldBuilder.load_grid()
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	Settings.pvp_show_enemy_hp = true
	game = MatchView.new()
	add_child(game)
	game._world = SubViewport.new()
	game._world.size = Vector2i(640, 480)
	game._world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	game.add_child(game._world)
	game._local = preload("res://scenes/player/player.tscn").instantiate()
	game._world.add_child(game._local)
	game._local.set_physics_process(false)
	game._local.role = 1
	game._local.position = Vector2(1000, 500)
	game._rollback.bind(game._local)
	game._rollback.reset(1, 0, 100, 0)
	game._playback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	game.phase = PvpMatchClient.Phase.ONLINE
	_state(_frame(100, {}, {}))
	var pickups := {12: {"type_id": 1, "mag": 3, "pos": Vector2(1100, 500), "vel": Vector2.ZERO}}
	_state(_frame(102, {2: _actor(Vector2(1200, 500))}, pickups))
	assert(game._replicas.has(2) and not game._replicas[2].visible)
	game._playback.render_tick = 101.0
	game._process(0.0)
	assert(not game._replicas[2].visible and game._minimap_others().is_empty())
	assert(not game._id_labels[2].visible and not game._hp_bars[2].visible)
	game._playback.render_tick = 102.0
	game._process(0.0)
	assert(game._replicas[2].visible and game._pickup_nodes.has(12))
	assert(game._id_labels[2].visible and game._hp_bars[2].visible and game._minimap_others().size() == 1)
	var replica: Node2D = game._replicas[2]
	_check_replica_shapes(replica)
	_state(_frame(104, {2: _actor(Vector2(1400, 500))}, pickups))
	game._playback.render_tick = 103.0
	game._process(0.0)
	assert(replica.position.x == 1300.0 and replica.get_node("GhostBody").global_position.x == 1400.0)
	_state(_frame(106, {}, {}))
	game._process(0.0)
	assert(replica.visible and game._pickup_nodes.has(12))
	assert(replica.get_node("GhostBody").collision_layer == 0)
	game._playback.render_tick = 106.0
	game._process(0.0)
	assert(game._replicas.is_empty() and game._pickup_nodes.is_empty())
	var future := _frame(108, {2: _actor(Vector2(1400, 500))}, {})
	future["map_revision"] = 1
	_state(future)
	assert(game._own_tick == 108 and game._last_tick == 106)
	assert(game._replicas[2].get_node("GhostBody").global_position.x == 1400.0)
	assert(game._playback.frames.back()["tick"] == 106)
	game._map_revision = 1
	_state(future)
	assert(game._last_tick == 108 and game._playback.frames.back()["tick"] == 108)
	game._playback.render_tick = 108.0
	game._process(0.0)
	await _check_projectiles()
	game._clear_dynamics()
	game._playback.reset()
	assert(game._bullets.is_empty() and game._playback.frames.is_empty())
	game.free()
	await get_tree().process_frame
	print("PLAYBACK LIFECYCLE PROBE OK collision shapes, birth/death ticks, terrain, local flight, grenade animation, Beta resume")
	get_tree().quit()

func _check_replica_shapes(replica: Node2D) -> void:
	for pose in replica.POSE_SHAPE:
		var actual: CollisionPolygon2D = game._local.get_node(replica.POSE_SHAPE[pose])
		var ghost: CollisionPolygon2D = replica._ghost_shapes[pose]
		for i in actual.polygon.size():
			var expected := actual.to_global(actual.polygon[i]) - game._local.global_position
			var observed: Vector2 = ghost.to_global(ghost.polygon[i]) - replica._ghost.global_position
			assert(expected.is_equal_approx(observed))

func _check_projectiles() -> void:
	var spawn := {"id": REMOTE_ID, "type_id": 1, "pos": Vector2(3000, 1000), "vel": Vector2(600, 0)}
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, spawn)
	var bullet: BulletBase = game._bullets[REMOTE_ID]
	bullet.collision_mask = 0
	assert(bullet.is_physics_processing() and not bullet.apply_damage and bullet.shooter == game._replicas[2])
	for i in 4: await get_tree().physics_frame
	assert(bullet.position.x > 3020)
	var pos := bullet.position
	var frame := _frame(110, {2: _actor(Vector2(1400, 500))}, {})
	frame["map_revision"] = 1
	_state(frame)
	assert(game._bullets[REMOTE_ID] == bullet and bullet.position == pos and bullet.is_physics_processing())
	var state := {"type_id": 1, "pos": Vector2(2900, 1000), "vel": Vector2(600, 0),
			"traveled": 300.0, "fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0}
	game._on_event(1, NetEvent.Kind.BULLET_REWIND, {"role": 2, "rewind": true, "projectiles": {REMOTE_ID: state}})
	assert(not bullet.is_physics_processing() and bullet.position == state["pos"])
	for i in 3: await get_tree().physics_frame
	assert(bullet.position == state["pos"] and bullet.traveled == 300.0)
	game._on_event(1, NetEvent.Kind.BULLET_REWIND, {"role": 2, "rewind": false, "projectiles": {REMOTE_ID: state}})
	for i in 3: await get_tree().physics_frame
	assert(bullet.is_physics_processing() and bullet.position.x > 2910)
	bullet.queue_free()
	await get_tree().process_frame
	# 从武器配置读取真实榴弹，验证重力、射手排除、引信与完整爆炸动画。
	var grenade_type := 0
	for type_id in WeaponRegistry.all_ids():
		var weapon: WeaponBase = load(WeaponRegistry.scene_of(type_id)).instantiate()
		if not weapon is LaserWeaponBase:
			var probe: BulletBase = weapon.bullet_scene.instantiate()
			if probe.explodes: grenade_type = type_id
			probe.free()
		weapon.free()
	assert(grenade_type != 0)
	spawn.merge({"id": REMOTE_ID + 1, "type_id": grenade_type, "pos": game._replicas[2].position, "vel": Vector2(600, -100)}, true)
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, spawn)
	var grenade: BulletBase = game._bullets[REMOTE_ID + 1]
	grenade.collision_mask = 0
	assert(grenade.gravity_factor == WeaponRegistry.projectile_profile(grenade_type)["gravity"] and grenade.gravity_factor > 0)
	for i in 2: await get_tree().physics_frame
	assert(grenade.velocity_vec.y > -100 and not grenade._fuse_active)
	game._local.team = 1
	game._replicas[2].team = 1
	grenade.position = game._local.position
	for i in 2: await get_tree().physics_frame
	assert(not grenade._fuse_active)
	game._local.team = 0
	game._replicas[2].team = 0
	grenade.position = Vector2(3000, 1000)
	game._world.canvas_transform = Transform2D(0.0, Vector2(320, 240) - grenade.position)
	await _capture("before")
	var health: int = game._local.hp
	var terrain := TileDefs.sub_hp.duplicate()
	game._restore_bullet(grenade, {"pos": grenade.position, "vel": grenade.velocity_vec, "traveled": 120.0,
			"fuse_active": true, "fuse_elapsed": 0.35, "fuse_duration": 0.4})
	assert(grenade.traveled == 120.0 and grenade._fuse_elapsed == 0.35)
	for i in 6: await get_tree().physics_frame
	assert(not game._bullets.has(REMOTE_ID + 1))
	var effects := game._world.get_children().filter(func(node: Node) -> bool: return node.scene_file_path == "res://scenes/effects/explosion.tscn")
	assert(effects.size() == 1)
	var effect: AnimatedSprite2D = effects[0]
	assert(effect.is_playing() and effect.animation == &"explode")
	await _capture("explosion")
	var effect_frame := effect.frame
	for i in 4: await get_tree().physics_frame
	assert(effect.frame > effect_frame)
	assert(game._local.hp == health and TileDefs.sub_hp == terrain)
	await get_tree().create_timer(0.6).timeout
	assert(not is_instance_valid(effect))
	print("PROJECTILE EFFECT OK gravity, shooter exclusion, fuse, animation advances and finishes, no client damage")

func _capture(label: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture"): return
	await RenderingServer.frame_post_draw
	var folder := ProjectSettings.globalize_path("res://").path_join(".test_logs/projectile_visual")
	DirAccess.make_dir_recursive_absolute(folder)
	assert(game._world.get_texture().get_image().save_png(folder.path_join(label + ".png")) == OK)
