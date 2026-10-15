extends Node

class MatchView extends PvpMatchClient:
	func _ready() -> void:
		set_physics_process(false)
		set_process(false)
	func _exit_tree() -> void:
		pass

var game: MatchView
const REMOTE_ID := (2 << 48) | 77
const LOCAL_ID := (1 << 48) | 88
const OTHER_ID := (3 << 48) | 78
const FUTURE_ID := (1 << 48) | 1001

func _ready() -> void:
	_run.call_deferred()

func _frame(tick: int, players: Dictionary, bullets: Dictionary, pickups: Dictionary, ack: int = 0, action_ack: int = 0) -> Dictionary:
	return {"tick": tick, "map_revision": 0, "world": {"players": players, "projectiles": bullets, "pickups": pickups},
		"own": {"state": game._local.capture_state(), "epoch": 1, "ack": ack, "action_ack": action_ack,
			"timing_seq": 0, "lead": 2, "input": InputBuffer.neutral(), "rewind": false}, "time": {}}

func _actor(pos: Vector2) -> Dictionary:
	return {"pos": pos, "vel": Vector2(60, 0), "epoch": 1, "pose": 1, "facing": 1,
		"type_id": 0, "hp": 100, "waterproof": 100.0, "aim": Vector2.RIGHT, "downed": false,
		"previewing": false, "haste": false, "rewind": false}

func _bullet() -> Dictionary:
	return {"type_id": 1, "input_seq": 1, "input_epoch": 1, "pos": Vector2(1000, 500), "vel": Vector2(60, 0)}

func _state(frame: Dictionary) -> void:
	game._on_state(frame)
	game._apply_pending_authority()

func _run() -> void:
	PvpSession.role = 1
	PvpSession.beta_mode = false
	PvpSession.room_mode = PvpSession.MODE_PVP
	Level0.pvp_mode = true
	MazeGenerator.set_map_file("res://maps/newfactory.cyrm")
	WorldBuilder.load_grid()
	Settings.pvp_show_enemy_hp = true
	game = MatchView.new()
	add_child(game)
	game._world = SubViewport.new()
	game.add_child(game._world)
	game._local = preload("res://scenes/player/player.tscn").instantiate()
	game._world.add_child(game._local)
	game._local.set_physics_process(false)
	game._local.role = 1
	game._rollback.bind(game._local)
	game._rollback.reset(1, 0, 100, 0)
	game._playback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	game.phase = PvpMatchClient.Phase.ONLINE
	_state(_frame(100, {}, {}, {}))
	var players := {2: _actor(Vector2(1000, 500))}
	var bullets := {REMOTE_ID: _bullet()}
	var pickups := {12: {"type_id": 1, "mag": 3, "pos": Vector2(1100, 500), "vel": Vector2.ZERO}}
	_state(_frame(102, players, bullets, pickups))
	assert(game._replicas.has(2) and not game._replicas[2].visible)
	assert(game._bullets.is_empty() and game._pickup_nodes.is_empty())
	game._playback.render_tick = 101.0
	game._process(0.0)
	assert(not game._replicas[2].visible and game._minimap_others().is_empty())
	assert(not game._id_labels[2].visible and not game._hp_bars[2].visible)
	game._playback.render_tick = 102.0
	game._process(0.0)
	assert(game._replicas[2].visible and game._bullets.has(REMOTE_ID) and game._pickup_nodes.has(12))
	assert(game._id_labels[2].visible and game._hp_bars[2].visible and game._minimap_others().size() == 1)
	var replica: Node2D = game._replicas[2]
	_check_replica_shapes(replica)
	var bullet: BulletBase = game._bullets[REMOTE_ID]
	players = {2: _actor(Vector2(1200, 500))}
	bullets = bullets.duplicate(true)
	bullets[REMOTE_ID]["pos"] += Vector2(2, 0)
	bullets[LOCAL_ID] = _bullet()
	_state(_frame(104, players, bullets, pickups))
	# 本地权威弹丸立即合并；远端位置继续插值，碰撞代理已经在最新位置。
	assert(game._bullets.has(LOCAL_ID))
	game._playback.render_tick = 103.0
	game._process(0.0)
	assert(game._bullets[REMOTE_ID] == bullet and replica.position.x == 1100.0)
	assert(replica.get_node("GhostBody").global_position.x == 1200.0)
	_state(_frame(106, {}, {}, {}, 1, 1))
	game._process(0.0)
	assert(game._replicas.has(2) and replica.visible and game._bullets.has(REMOTE_ID) and game._pickup_nodes.has(12))
	assert(replica.get_node("GhostBody").collision_layer == 0 and not game._bullets.has(LOCAL_ID))
	game._playback.render_tick = 105.0
	game._process(0.0)
	assert(game._bullets.has(REMOTE_ID) and game._pickup_nodes.has(12) and replica.visible)
	game._playback.render_tick = 106.0
	game._process(0.0)
	assert(game._replicas.is_empty() and game._bullets.is_empty() and game._pickup_nodes.is_empty())
	# 移动已确认但开火动作仍待确认，预测弹丸不能先被删除；动作确认后不会被旧播放帧复活。
	var predicted: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	predicted.entity_id = 999
	predicted.input_seq = 9
	predicted.shooter = game._local
	game._world.add_child(predicted)
	predicted.set_physics_process(false)
	var action := InputBuffer.neutral()
	action.merge({"seq": 9, "target_tick": 110, "pressed": PacketInputSource.BIT_ATTACK}, true)
	game._rollback.actions.append(action)
	_state(_frame(110, {}, {}, {}, 9, 8))
	assert(game._bullets[999] == predicted)
	_state(_frame(112, {}, {}, {}, 9, 9))
	game._process(0.0)
	assert(game._bullets.is_empty())
	# 同一批到达的出生和消失仍应在稍后的播放时间出现，碰撞代理保持关闭。
	game._on_state(_frame(114, {3: _actor(Vector2(1000, 500))}, {OTHER_ID: _bullet()}, pickups, 9, 9))
	game._on_state(_frame(116, {}, {}, {}, 9, 9))
	assert(game._authority_state["tick"] == 116 and game._own_tick == 112)
	game._apply_pending_authority()
	assert(game._own_tick == 116)
	game._playback.render_tick = 112.0
	game._process(0.0)
	assert(not game._replicas.has(3) and not game._bullets.has(OTHER_ID))
	game._playback.render_tick = 114.0
	game._process(0.0)
	assert(game._replicas[3].visible and game._bullets.has(OTHER_ID) and game._pickup_nodes.has(12))
	assert(game._replicas[3].get_node("GhostBody").collision_layer == 0)
	game._playback.render_tick = 116.0
	game._process(0.0)
	assert(not game._replicas.has(3) and game._bullets.is_empty() and game._pickup_nodes.is_empty())
	var confirmed: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	confirmed.entity_id = FUTURE_ID
	confirmed.input_seq = 20
	confirmed.shooter = game._local
	game._world.add_child(confirmed)
	confirmed.set_physics_process(false)
	# 地形可靠事件未追上时，本地确认和时钟仍前进，远端播放保持原版本。
	var authority_bullet := _bullet()
	authority_bullet["input_seq"] = 10
	var future := _frame(118, {2: _actor(Vector2(1400, 500))}, {FUTURE_ID: authority_bullet}, {}, 10, 10)
	future["map_revision"] = 1
	_state(future)
	assert(game._own_tick == 118 and game._own_ack == 10 and game._last_tick == 116)
	assert(game._replicas[2].get_node("GhostBody").global_position.x == 1400.0)
	assert(game._playback.frames.back()["tick"] == 116)
	game._map_revision = 1
	_state(future)
	assert(game._last_tick == 118 and game._playback.frames.back()["tick"] == 118)
	var vanished := _frame(119, {}, {}, {}, 10, 10)
	vanished["map_revision"] = 1
	_state(vanished)
	assert(not game._bullets.has(FUTURE_ID))
	# 复活重置输入序号后，上一控制阶段的预测弹丸不能永远等待新的 ACK。
	var old_bullet: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	old_bullet.entity_id = 1000
	old_bullet.input_seq = 50
	old_bullet.shooter = game._local
	game._world.add_child(old_bullet)
	old_bullet.set_physics_process(false)
	var respawn := _frame(120, {}, {}, {})
	respawn["map_revision"] = 1
	respawn["own"]["epoch"] = 2
	_state(respawn)
	assert(game._rollback.epoch == 2 and not game._bullets.has(1000))
	game._clear_dynamics()
	game._playback.reset()
	assert(game._playback.frames.is_empty())
	game.free()
	await get_tree().process_frame
	print("PLAYBACK LIFECYCLE PROBE OK collision shapes, birth/death ticks, latest ghost, own ACK before terrain, projectile epoch")
	get_tree().quit()

func _check_replica_shapes(replica: Node2D) -> void:
	var player: CharacterBody2D = game._local
	for pose in replica.POSE_SHAPE:
		var actual: CollisionPolygon2D = player.get_node(replica.POSE_SHAPE[pose])
		var ghost: CollisionPolygon2D = replica._ghost_shapes[pose]
		assert(actual.polygon.size() == ghost.polygon.size())
		for i in actual.polygon.size():
			var expected := actual.to_global(actual.polygon[i]) - player.global_position
			var observed: Vector2 = ghost.to_global(ghost.polygon[i]) - replica._ghost.global_position
			assert(expected.is_equal_approx(observed))
