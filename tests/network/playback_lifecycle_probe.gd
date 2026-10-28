extends Node

class MatchView extends PvpMatchClient:
	func _ready() -> void:
		set_physics_process(false)
		set_process(false)
	func _exit_tree() -> void: pass

class TerrainView extends Level0:
	func _ready() -> void:
		set_process(false)
		set_physics_process(false)
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
	return {"pos": pos, "vel": Vector2(60, 0), "knock": Vector2.ZERO, "epoch": 1, "pose": 1, "facing": 1,
		"type_id": 0, "hp": 100, "waterproof": 100.0, "aim": Vector2.RIGHT, "downed": false,
		"previewing": false, "haste": false, "rewind": false}.merged(ProtocolFixture.actor_motion()).merged({"axis": 60.0 / 700.0}, true)

func _state(frame: Dictionary) -> void:
	game._on_state(frame)
	game._apply_pending_authority()

func _event(kind: int, data: Dictionary) -> void:
	game._on_event(1, kind, data)
	game._apply_pending_authority()

func _run() -> void:
	PvpSession.role = 1
	PvpSession.beta_mode = false
	PvpSession.room_mode = PvpSession.MODE_PVP
	Level0.pvp_mode = true
	MazeGenerator.set_map_file("res://maps/newfactory.cyrm")
	var grid := WorldBuilder.load_grid()
	Settings.pvp_show_enemy_hp = true
	game = MatchView.new()
	add_child(game)
	game._level0 = TerrainView.new()
	game._level0.terrain = TileDefs.terrain
	game.add_child(game._level0)
	game._world = SubViewport.new()
	game._world.name = "WorldViewport"
	game._world.size = Vector2i(640, 480)
	game._world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	game._level0.add_child(game._world)
	game._local = preload("res://scenes/player/player.tscn").instantiate()
	game._world.add_child(game._local)
	game._local.set_physics_process(false)
	game._local.role = 1
	game._local.collision_mask = 3
	game._local.position = Vector2(1000, 500)
	game._collision_anchor = ActorCollider.new(game._local, 32)
	game._rollback.bind(game._local, game._replicas, game._collision_anchor)
	game._rollback.reset(1, 0, 100, 0)
	game._playback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	game.phase = PvpMatchClient.Phase.ONLINE
	game._ensure_replica(99)
	assert(game._replicas[99]._ghost.collision_layer == 0, "players without authority data cannot block prediction")
	game._on_event(1, NetEvent.Kind.ROOM, {"code": "00001234", "in_match": true})
	assert(game.phase == PvpMatchClient.Phase.ONLINE and game.is_inside_tree())
	assert(PvpSession.room["code"] == "00001234" and not Level0._switching)
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
	replica._forecast.gravity = 0.0
	_check_replica_shapes(replica)
	_check_immediate_collision(replica)
	await _check_seam_collision(replica)
	await _check_moving_collision(replica)
	await _check_knocked_collision(replica)
	await _check_contact_timing(replica)
	await _check_respawn_collision(replica)
	await _check_shared_motion(replica)
	await _check_terrain_motion_cache(replica)
	_check_rewind_path(replica)
	await _check_remote_input(replica)
	_check_hint_backlog(replica)
	_check_late_input(replica)
	_state(_frame(104, {2: _actor(Vector2(1400, 500))}, pickups))
	game._playback.render_tick = 103.0
	game._process(0.0)
	assert(replica.position.x == 1300.0)
	var collision_x := 1400.0 + clampf(game._rollback._sim_tick - 104, 0, replica.MOTION_HORIZON)
	assert(is_equal_approx(replica._forecast.global_position.x, collision_x))
	_state(_frame(106, {}, {}))
	game._process(0.0)
	assert(replica.visible and game._pickup_nodes.has(12))
	assert(replica._ghost.collision_layer == 0)
	game._playback.render_tick = 106.0
	game._process(0.0)
	assert(game._replicas.is_empty() and game._pickup_nodes.is_empty())
	var future := _frame(108, {2: _actor(Vector2(1400, 500))}, {})
	future["map_revision"] = 1
	_state(future)
	assert(game._own_tick == 106 and game._last_tick == 106)
	assert(game._authority_state.is_empty() and not game._replicas.has(2))
	assert(game._playback.frames.back()["tick"] == 106)
	game._map_revision = 1
	game._apply_pending_authority()
	assert(game._last_tick == 108 and game._playback.frames.back()["tick"] == 108)
	assert(game._own_tick == 108)
	game._playback.render_tick = 108.0
	game._process(0.0)
	await _check_projectiles()
	_check_projectile_limit()
	_check_projectile_end()
	_check_correction_counts()
	_check_sparse_prediction_samples()
	_check_terrain_batch(grid)
	_check_predicted_terrain(grid)
	game._clear_dynamics()
	game._playback.reset()
	assert(game._bullets.is_empty() and game._playback.frames.is_empty())
	game.free()
	print("PLAYBACK LIFECYCLE PROBE OK room updates, correction counts, collision shapes, birth/death ticks, terrain, local flight, grenade animation, Beta resume")
	get_tree().quit()

func _check_projectile_limit() -> void:
	game._clear_dynamics()
	var player := game._local
	player.weapons.set_initial_inventory([5])
	player.enable_manual_simulation()
	player.gravity = 0.0
	player.collision_mask = 0
	player.position = Vector2(1000, 500)
	player.velocity = Vector2.ZERO
	player.combat.knock_velocity = Vector2.ZERO
	player.shot_serial = 2
	var weapon: WeaponBase = player.weapons.current_weapon()
	var own := {"state": player.capture_state(), "epoch": 1, "ack": 0, "action_ack": 0,
		"timing_seq": 0, "lead": 2, "input": InputBuffer.neutral(), "rewind": false}
	var rollback := PredictionRollback.new()
	rollback.bind(player)
	var state := {"type_id": 5, "pos": Vector2(3000, 1000), "vel": Vector2(10, 0), "traveled": 0.0,
		"fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	var visuals: Array[BulletBase] = []
	for serial in range(1, 3):
		rollback.combat_prediction.seed_projectile((player.role << 48) | (serial << 8), state, 100, player)
		var bullet: BulletBase = preload("res://scenes/weapons/grenade_bullet.tscn").instantiate()
		bullet.source = weapon
		game._world.add_child(bullet)
		bullet.set_physics_process(false)
		visuals.append(bullet)
	var record := InputBuffer.neutral().merged({"seq": 1, "epoch": 1, "target_tick": 101,
		"aim": Vector2.LEFT}, true)
	var action := record.merged({"pressed": 0, "released": PacketInputSource.BIT_ATTACK,
		"winst": player.weapons.current_inst()}, true)
	var results := []
	for repeat in 2:
		rollback.reset(1, 0, 100, 0)
		rollback._clock = 101.0
		rollback.history = [record]
		rollback.actions = [action]
		rollback.reconcile(own, 100, 0)
		results.append({"pos": player.position, "serial": player.shot_serial, "mag": weapon.mag_ammo})
		if repeat == 0:
			var visual: BulletBase = preload("res://scenes/weapons/grenade_bullet.tscn").instantiate()
			visual.source = weapon
			game._world.add_child(visual)
			visual.set_physics_process(false)
			visuals.append(visual)
	assert(results[0] == results[1] and results[1]["serial"] == 3,
		"the current visual projectile count must not change a replayed shot, ammo or recoil")
	var saturated := own.duplicate(true)
	saturated["state"]["shot_serial"] = 3
	rollback.combat_prediction.seed_projectile((player.role << 48) | (3 << 8), state, 100, player)
	rollback.reset(1, 0, 100, 0)
	rollback._clock = 101.0
	rollback.history = [record]
	rollback.actions = [action]
	rollback.reconcile(saturated, 100, 0)
	assert(player.shot_serial == 3 and weapon.mag_ammo == saturated["state"]["mag"],
		"three simulated live grenades must still enforce the configured limit")
	for visual in visuals: visual.free()
	rollback.combat_prediction.clear()
	game._rollback.bind(player, game._replicas, game._collision_anchor)
	print("PROJECTILE LIMIT OK repeated shot, ammo, recoil and simulated cap")

func _check_projectile_end() -> void:
	var player := game._local
	player.apply_authoritative_state(50, player.max_waterproof, false)
	player.position = Vector2(1000, 500)
	player.velocity = Vector2.ZERO
	player.combat.knock_velocity = Vector2.ZERO
	player.gravity = 0.0
	player.collision_mask = 0
	var own := {"state": player.capture_state(), "epoch": 1, "ack": 0, "action_ack": 0,
		"timing_seq": 0, "lead": 2, "input": InputBuffer.neutral(), "rewind": false}
	var rollback := PredictionRollback.new()
	rollback.bind(player)
	var id := (2 << 48) | (127 << 8)
	var state := {"type_id": 2, "pos": Vector2(800, 500), "vel": Vector2(3000, 0), "traveled": 0.0,
		"fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	rollback.combat_prediction.seed_projectile(id, state, 100, null)
	rollback.combat_prediction.projectiles[id]["bullet"].collision_mask = 0
	# 服务器在 102 tick 已终止子弹；当前碰撞环境已不再挡住其出生弹道。
	assert(rollback.combat_prediction.end_projectiles({"tick": 102, "ids": [id]}) == Vector2i.ZERO,
		"ending a bullet without predicted contacts does not change past actor simulation")
	for repeat in 2:
		rollback.reset(1, 0, 100, 0)
		rollback._clock = 108.0
		rollback.reconcile(own, 100, 0)
		assert(player.hp == 50 and player.combat.knock_velocity == Vector2.ZERO,
			"an authoritative end must prevent a retired bullet from hitting during replay")
	rollback.combat_prediction.prepare(104)
	assert(not rollback.combat_prediction.projectiles.has(id) and rollback.combat_prediction.ended.is_empty(),
		"acknowledged lifecycle records and projectile history must be released")
	rollback.combat_prediction.clear()
	rollback.combat_prediction.seed_projectile(id, state, 100, null)
	rollback.combat_prediction.projectiles[id]["bullet"].collision_mask = 0
	rollback.reset(1, 0, 100, 0)
	rollback._clock = 108.0
	rollback.reconcile(own, 100, 0)
	assert(player.hp < 50, "the counterfactual flight must predict an actual actor hit")
	assert(rollback.combat_prediction.end_projectiles({"tick": 102, "ids": [id]}) != Vector2i.ZERO,
		"an end that rejects a predicted hit must request actor replay")
	rollback.reset(1, 0, 100, 0)
	rollback._clock = 108.0
	rollback.reconcile(own, 100, 0)
	assert(player.hp == 50 and player.combat.knock_velocity == Vector2.ZERO)
	rollback.combat_prediction.clear()
	game._rollback.bind(player, game._replicas, game._collision_anchor)
	print("PROJECTILE END OK no resurrection, repeat replay, acknowledgement and contact-dependent replay")

func _check_predicted_terrain(grid: Array[Array]) -> void:
	var layer := TileMapLayer.new()
	layer.tile_set = TerrainAtlas.make_wall_tileset()
	game._world.add_child(layer)
	Level0.wall_layer = layer
	var sub := Vector2i(-1, -1)
	for y in TileDefs.sub_rows:
		for x in TileDefs.sub_cols:
			var cell := Vector2i(x, y)
			if TileDefs.sub_alive(cell) and TileDefs.explosion_destroyable(TileDefs.sub_texture(cell)):
				sub = cell
				break
		if sub.x >= 0: break
	assert(sub.x >= 0)
	game._level0._paint_maze(layer)
	assert(layer.get_cell_source_id(sub) == 0)
	var initial := TileDefs.sub_hp.duplicate()
	var before_grid := MazeGenerator.copy_grid(grid)
	var revision := game._map_revision
	var prediction := game._rollback.combat_prediction
	prediction.confirm({"id": 500, "tick": 400, "type_id": 5, "pos": Vector2(sub * 16) + Vector2(8, 8)})
	var predicted: PackedInt32Array
	for repeat in 2:
		prediction.prepare(399)
		assert(TileDefs.sub_hp == initial and MazeGenerator.current_grid == before_grid,
				"replay must restore the complete authoritative terrain before predicting again")
		prediction.step(400, [], false)
		assert(not TileDefs.sub_alive(sub) and not game._terrain.pending_cells().is_empty())
		assert(layer.get_cell_source_id(sub) == 0,
				"replay must change logical terrain without committing intermediate TileMap visuals")
		assert(game._map_revision == revision, "temporary destruction must not change the authoritative revision")
		if repeat == 0: predicted = TileDefs.sub_hp.duplicate()
		else: assert(TileDefs.sub_hp == predicted, "replaying an explosion must not accumulate tile damage")
	game._level0.flush_terrain_visuals()
	assert(layer.get_cell_source_id(sub) == -1,
			"the presentation phase must commit the final terrain after repeated replay")
	var far := Vector2i(-1, -1)
	for y in TileDefs.sub_rows:
		for x in TileDefs.sub_cols:
			var cell := Vector2i(x, y)
			if TileDefs.sub_alive(cell) and TileDefs.explosion_destroyable(TileDefs.sub_texture(cell)) and cell.distance_to(sub) > 40:
				far = cell
				break
		if far.x >= 0: break
	assert(far.x >= 0)
	game._rollback._sim_tick = 400
	game.apply_terrain({"tick": 399, "revision": revision + 1, "cells": {far: 0}})
	assert(not TileDefs.sub_alive(sub) and not TileDefs.sub_alive(far),
			"an older terrain patch must preserve the already predicted future blast")
	prediction.prepare(399)
	initial[far.y * TileDefs.sub_cols + far.x] = 0
	assert(TileDefs.sub_hp == initial,
			"restoring speculation must preserve the newly received authoritative terrain")
	prediction.step(400, [], false)
	game.apply_terrain({"tick": 400, "revision": revision + 2, "cells": {sub: 0}})
	prediction.prepare(400)
	var confirmed := initial.duplicate()
	confirmed[sub.y * TileDefs.sub_cols + sub.x] = 0
	assert(TileDefs.sub_hp == confirmed and game._terrain.pending_cells().is_empty(),
			"authority must replace speculation without applying damage twice or restoring confirmed destruction")
	prediction.clear()
	assert(TileDefs.sub_hp == confirmed)
	game._level0.flush_terrain_visuals()
	print("TERRAIN PREDICTION OK repeat, rollback, older patch, authority replacement, revision and clear")

func _check_sparse_prediction_samples() -> void:
	var client := preload("res://tests/network/match_client.gd").new()
	client.game = game
	client.driver = preload("res://tests/network/match_input.gd").new()
	client.driver.stop = true
	var width := GameParameters.MAP_WIDTH
	client.predicted = [{"epoch": 1, "tick": 101, "pos": Vector2(width - 1, 500)},
		{"epoch": 1, "tick": 103, "pos": Vector2(1, 500)}]
	var frame := _frame(102, {}, {})
	frame["own"]["state"]["pos"] = Vector2(0, 500)
	client.on_state(frame)
	assert(client.convergence_error < 0.001 and client.metrics["convergence_samples"] == 1)
	client.free()

func _check_correction_counts() -> void:
	_check_explosion_visual_replay()
	game._log_counts.clear()
	for tick in range(200, 210):
		var frame := _frame(tick, {}, {})
		game._local.position += Vector2(256, 0)
		game._apply_authority(frame)
	assert(game._log_counts["corrections_8px"] == 10)
	assert(game._log_counts["corrections_32px"] == 10)
	assert(game._log_counts["corrections_128px"] == 10)
	var respawn := _frame(212, {}, {})
	respawn["own"]["epoch"] = 2
	game._local.position += Vector2(256, 0)
	game._apply_authority(respawn)
	var rewind := _frame(214, {}, {})
	rewind["own"]["epoch"] = 2
	rewind["own"]["rewind"] = true
	game._local.position += Vector2(256, 0)
	game._apply_authority(rewind)
	assert(game._log_counts["reconciles"] == 12 and game._log_counts["correction_checks"] == 10)
	assert(game._log_counts["corrections_8px"] == 10)

func _check_explosion_visual_replay() -> void:
	var player := game._local
	var original: Dictionary = player.capture_state()
	var gravity: float = player.gravity
	var mask: int = player.collision_mask
	for speed in [0.0, 700.0]:
		player.restore_state(original)
		player.gravity = 0.0
		player.collision_mask = 0
		player.position = Vector2(1000, 500) - Vector2(speed * ActorStep.DT, 0)
		player.correct_visual(player.position, true)
		player.begin_visual_step()
		player.position = Vector2(1000, 500)
		player.velocity = Vector2(speed, 0)
		player.present_prediction(0.0, -0.5)
		var visible: Vector2 = player.visuals.global_position
		var previous: Vector2 = player.corrected_position()
		var own: Dictionary = _frame(100, {}, {})["own"]
		own["state"]["knock"] = Vector2(3000, 0)
		var rollback := PredictionRollback.new()
		rollback.bind(player)
		rollback.reset(1, 0, 100, 60)
		rollback._sim_tick = int(rollback._clock)
		rollback.reconcile(own, 100, 60)
		assert(player.position.x > previous.x, "authority blast must move the simulation forward")
		player.correct_visual(previous, false)
		player.present_prediction(0.0, -0.5)
		assert(player.visuals.global_position.distance_to(visible) < 0.01,
				"receiving an explosion at the same render time must not kick the picture backwards")
		rollback.advance(ActorStep.DT)
		player.present_prediction(0.0, -0.5)
		assert(player.visuals.global_position.x > visible.x, "the next real prediction tick must show the blast motion")
	player.restore_state(original)
	player.gravity = gravity
	player.collision_mask = mask
	player.correct_visual(player.position, true)

func _check_replica_shapes(replica: Node2D) -> void:
	for crouched in [false, true]:
		replica._forecast.is_squat = crouched
		replica._forecast.apply_collision_pose()
		var expected: Rect2 = replica._forecast.collision_rect()
		expected.position -= replica._forecast.global_position
		var observed: Rect2 = replica._ghost.world_rect(replica._forecast.global_position)
		observed.position -= replica._forecast.global_position
		assert(expected.is_equal_approx(observed), "actor blocking must match the logical hull")
	var down := _actor(Vector2(1400, 500))
	down["downed"] = true
	down["facing"] = -1
	replica.apply_snapshot(down, game._local.position, 105)
	assert(is_equal_approx(replica._forecast.global_rotation, PI / 2.0))
	var shape: RectangleShape2D = replica._forecast.hulls[0].shape
	var rotated_size: Vector2 = Vector2(shape.size.y, shape.size.x) * replica._forecast.scale
	assert(replica._ghost.world_rect(replica._forecast.global_position).size.is_equal_approx(rotated_size),
			"downed rectangle bounds must rotate with the body")
	replica.render_snapshot(_actor(Vector2(1300, 500)), game._local.position)
	assert(is_equal_approx(replica._forecast.global_rotation, PI / 2.0))
	replica.apply_snapshot(_actor(Vector2(1400, 500)), game._local.position, 105)
	assert(is_zero_approx(replica._forecast.global_rotation))

func _check_terrain_batch(grid: Array[Array]) -> void:
	game._level0.terrain.attach(game._world)
	var cells: Array[Vector2i] = []
	var chunk := Vector2i(-1, -1)
	for y in TileDefs.sub_rows:
		for x in TileDefs.sub_cols:
			var sub := Vector2i(x, y)
			if not TileDefs.sub_alive(sub) or not TileDefs.explosion_destroyable(TileDefs.sub_texture(sub)):
				continue
			var found := CollisionBuilder.chunk_of(Vector2i(x / 4, y / 4))
			if cells.is_empty(): chunk = found
			if found == chunk: cells.append(sub)
			if cells.size() == 2: break
		if cells.size() == 2: break
	assert(cells.size() == 2)
	game._level0.terrain.invalidate_chunk(chunk)
	game._level0.flush_terrain_collision()
	var node_name := "DestructibleChunk_%d_%d" % [chunk.x, chunk.y]
	var before := game._world.get_node(node_name).get_instance_id()
	var before_layout: Array = _terrain_layout(game._world.get_node(node_name))
	var geometry := CollisionBuilder.geometry_revision
	var shape_id := game._world.get_node(node_name).get_child(0).get_instance_id()
	game._level0.terrain.invalidate_chunk(chunk)
	game._level0.flush_terrain_collision()
	assert(CollisionBuilder.geometry_revision == geometry
			and game._world.get_node(node_name).get_child(0).get_instance_id() == shape_id,
			"an unchanged collision layout must preserve shapes and its geometry version")
	var revision := game._map_revision
	var future := _frame(300, {}, {})
	future["map_revision"] = revision + 2
	game._on_state(future)
	game.apply_terrain({"tick": 300, "revision": revision + 1, "cells": {cells[0]: 0}})
	game._apply_pending_authority()
	assert(game._own_tick < 300)
	var partial := game._world.get_node(node_name).get_instance_id()
	var partial_layout: Array = _terrain_layout(game._world.get_node(node_name))
	game.apply_terrain({"tick": 300, "revision": revision + 2, "cells": {cells[1]: 0}})
	assert(game._world.get_node(node_name).get_instance_id() == partial
			and _terrain_layout(game._world.get_node(node_name)) == partial_layout)
	game._apply_pending_authority()
	assert(game._own_tick == 300 and game._level0.terrain.dirty_count() == 0)
	assert(game._world.get_node(node_name).get_instance_id() == before and partial == before,
			"collision commits retain the chunk body")
	assert(_terrain_layout(game._world.get_node(node_name)) != partial_layout and partial_layout != before_layout,
			"the same body must still receive every committed geometry change")
	# 同一物理帧内的多个破坏，保留旧碰撞到统一提交点。
	for sub in cells:
		TileDefs.restore_sub(sub, 1)
	game._level0.terrain.invalidate_chunk(chunk)
	game._level0.flush_terrain_collision()
	before = game._world.get_node(node_name).get_instance_id()
	before_layout = _terrain_layout(game._world.get_node(node_name))
	for i in cells.size():
		game.apply_terrain({"tick": 300, "revision": revision + 3 + i, "cells": {cells[i]: 0}})
		assert(game._world.get_node(node_name).get_instance_id() == before
				and _terrain_layout(game._world.get_node(node_name)) == before_layout)
	game._apply_pending_authority()
	assert(game._world.get_node(node_name).get_instance_id() == before
			and _terrain_layout(game._world.get_node(node_name)) != before_layout)
	# 到包之后地形又推进时，旧版本权威状态不能进入重放。
	var stale := _frame(302, {}, {})
	stale["map_revision"] = game._map_revision
	game._on_state(stale)
	game.apply_terrain({"tick": 303, "revision": game._map_revision + 1, "cells": {cells[0]: 0}})
	game._apply_pending_authority()
	assert(game._own_tick == 300 and game._authority_state.is_empty())

func _check_immediate_collision(replica: Node2D) -> void:
	var origin: Vector2 = game._local.position
	var previous: Vector2 = replica._opponent_canonical
	var colliders: Array[ActorCollider] = game._local.actor_colliders
	var single: Array[ActorCollider] = [replica._ghost]
	game._local.actor_colliders = single
	replica.apply_snapshot(_actor(origin + Vector2(200, 0)), origin, 103)
	assert(ActorCollider.clip(game._local.collision_rect(), 0, 400.0, ActorCollider.obstacles(game._local, 2)) < 400.0, "new player position blocks prediction immediately")
	replica.apply_snapshot(_actor(origin + Vector2(200, 400)), origin, 104)
	assert(ActorCollider.clip(game._local.collision_rect(), 0, 400.0, ActorCollider.obstacles(game._local, 2)) == 400.0, "old player position no longer blocks prediction")
	game._local.actor_colliders = colliders
	replica.apply_snapshot(_actor(previous), origin, 105)

func _check_seam_collision(replica: Node2D) -> void:
	var player := game._local
	var original: Dictionary = player.capture_state()
	var gravity: float = player.gravity
	var previous: Vector2 = replica._opponent_canonical
	player.position = Vector2(GameParameters.MAP_WIDTH - 40, 500)
	player.velocity = Vector2(700, 0)
	player.gravity = 0.0
	replica.apply_snapshot(_actor(Vector2(120, 500)), player.position, 100)
	var rollback := PredictionRollback.new()
	rollback.bind(player, game._replicas, game._collision_anchor)
	rollback.reset(1, 0, 0, 0)
	rollback._clock = 0.0
	var source := PacketInputSource.new()
	source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0}, true))
	for tick in 20:
		await get_tree().physics_frame
		rollback.capture(source, Vector2.RIGHT, 0, 0)
		rollback.advance(ActorStep.DT)
	var blocked: bool = player.position.x < 100.0
	var position := player.position
	player.restore_state(original)
	player.gravity = gravity
	replica.apply_snapshot(_actor(previous), player.position, 105)
	assert(blocked, "prediction must keep player collisions across seam: %s" % position)

func _check_moving_collision(replica: Node2D) -> void:
	var player := game._local
	var original: Dictionary = player.capture_state()
	var gravity: float = player.gravity
	player.gravity = 0.0
	player.position = Vector2(1000, 500)
	player.velocity = Vector2(2100, 0)
	player.pvp_haste_mult = 3.0
	var remote := _actor(Vector2(1120, 500))
	remote["vel"] = Vector2(2100, 0)
	remote["axis"] = 1.0
	remote["haste_mult"] = 3.0
	replica.apply_snapshot(remote, player.position, 0)
	var rollback := PredictionRollback.new()
	rollback.bind(player, game._replicas, game._collision_anchor)
	rollback.reset(1, 0, 0, 0)
	rollback._clock = 0.0
	var source := PacketInputSource.new()
	source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0}, true))
	for tick in 6:
		await get_tree().physics_frame
		rollback.capture(source, Vector2.RIGHT, 0, 0)
		rollback.advance(ActorStep.DT)
	assert(absf(player.position.x - 1210.0) < 0.1, "following a moving player must not collide with its old position")
	player.position = Vector2(1000, 500)
	player.velocity = Vector2(2100, 0)
	remote["vel"] = Vector2(-2100, 0)
	remote["axis"] = -1.0
	replica.apply_snapshot(remote, player.position, 0)
	rollback.reset(1, 0, 0, 0)
	rollback._clock = 0.0
	for tick in 6:
		await get_tree().physics_frame
		rollback.capture(source, Vector2.RIGHT, 0, 0)
		rollback.advance(ActorStep.DT)
	assert(player.position.x < 1210.0, "a head-on kinematic proxy must truncate local movement")
	remote["vel"] = Vector2(2100, 0)
	remote["axis"] = 1.0
	replica.apply_snapshot(remote, player.position, 0)
	var wall := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	shape.shape = RectangleShape2D.new()
	shape.shape.size = Vector2(32, 300)
	wall.position = Vector2(1400, 500)
	wall.add_child(shape)
	game._world.add_child(wall)
	await get_tree().physics_frame
	replica.anchor_collision(player.position, 12)
	assert(replica._forecast.position.x > 1330.0 and replica._forecast.collision_rect().end.x <= 1384.01,
			"logical motion extends past six ticks and must stop at the wall")
	wall.free()
	player.restore_state(original)
	player.gravity = gravity
	replica.apply_snapshot(_actor(Vector2(1200, 500)), player.position, 102)

func _check_knocked_collision(replica: Node2D) -> void:
	var player := game._local
	var original: Dictionary = player.capture_state()
	var gravity: float = player.gravity
	player.gravity = 0.0
	player.position = Vector2(1000, 500)
	player.velocity = Vector2(2100, 0)
	player.pvp_haste_mult = 3.0
	var remote := _actor(Vector2(1120, 500))
	remote["vel"] = Vector2.ZERO
	remote["axis"] = 0.0
	remote["knock"] = Vector2(3000, 0)
	replica.apply_snapshot(remote, player.position, 0)
	var rollback := PredictionRollback.new()
	rollback.bind(player, game._replicas, game._collision_anchor)
	rollback.reset(1, 0, 0, 0)
	rollback._clock = 0.0
	var source := PacketInputSource.new()
	source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0}, true))
	var expected := 1120.0
	var knock := 3000.0
	for tick in 6:
		await get_tree().physics_frame
		expected += knock * ActorStep.DT
		knock *= exp(-PlayerParams.player_knock_decay_rate * ActorStep.DT)
		rollback.capture(source, Vector2.RIGHT, 0, 0)
		rollback.advance(ActorStep.DT)
	assert(absf(player.position.x - 1210.0) < 0.1, "a knocked player must not leave a stationary blocker")
	assert(absf(replica._forecast.position.x - expected) < 0.1, "remote knock must follow the authority decay: %s vs %s" % [replica._forecast.position.x, expected])
	player.restore_state(original)
	player.gravity = gravity
	replica.apply_snapshot(_actor(Vector2(1200, 500)), player.position, 102)

func _check_contact_timing(replica: Node2D) -> void:
	var player := game._local
	var original: Dictionary = player.capture_state()
	var gravity: float = player.gravity
	var reference: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	game._world.add_child(reference)
	reference.set_physics_process(false)
	reference.collision_layer = 0
	reference.collision_mask = 16
	reference.gravity = 0.0
	var carrier: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	game._world.add_child(carrier)
	carrier.enable_manual_simulation()
	carrier.collision_layer = 0
	var blocker := ActorCollider.new(carrier, 16)
	reference.actor_colliders.assign([blocker])
	for role in [1, 3]:
		player.role = role
		player.restore_state(original)
		player.position = Vector2(1000, 500)
		player.velocity = Vector2(1736, 0)
		player.gravity = 0.0
		var remote := _actor(Vector2(1085, 500))
		remote["vel"] = Vector2(1936, 0)
		remote["axis"] = 1936.0 / 2100.0
		remote["haste_mult"] = 3.0
		replica.apply_snapshot(remote, player.position, 0)
		reference.restore_state(player.capture_state())
		var position: Vector2 = remote["pos"]
		if role > 2:
			position += remote["vel"] * ActorStep.DT
		carrier.position = position
		await get_tree().physics_frame
		ActorStep.step(reference, InputBuffer.neutral())
		var rollback := PredictionRollback.new()
		rollback.bind(player, game._replicas, game._collision_anchor)
		rollback.reset(1, 0, 0, 0)
		rollback._clock = 0.0
		rollback.advance(ActorStep.DT)
		assert(player.position.distance_to(reference.position) < 0.01, "prediction must query the same contact time as authority")
		assert(player.velocity.is_equal_approx(reference.velocity))
	reference.free()
	carrier.free()
	player.role = 1
	player.restore_state(original)
	player.gravity = gravity
	replica.apply_snapshot(_actor(Vector2(1200, 500)), player.position, 102)

func _check_respawn_collision(replica: Node2D) -> void:
	var player := game._local
	var original: Dictionary = player.capture_state()
	var gravity: float = player.gravity
	var reference: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	game._world.add_child(reference)
	reference.set_physics_process(false)
	reference.collision_layer = 0
	reference.collision_mask = 16
	reference.gravity = 0.0
	var carrier: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	game._world.add_child(carrier)
	carrier.enable_manual_simulation()
	carrier.collision_layer = 0
	carrier.position = Vector2(1120, 500)
	carrier.rotation = -PI / 2.0
	var blocker := ActorCollider.new(carrier, 16)
	reference.actor_colliders.assign([blocker])
	var record := InputBuffer.neutral().merged({"ax": 1.0}, true)
	for role in [1, 3]:
		player.role = role
		player.restore_state(original)
		player.position = Vector2(1000, 500)
		player.velocity = Vector2(2100, 0)
		player.pvp_haste_mult = 3.0
		player.gravity = 0.0
		reference.restore_state(player.capture_state())
		var remote := _actor(Vector2(1120, 500))
		remote.merge({"vel": Vector2.ZERO, "pose": 2, "hp": 0, "downed": true, "axis": 0.0, "respawn_tick": 3}, true)
		replica.set_ghost_layer(2)
		replica.apply_snapshot(remote, player.position, 0)
		var rollback := PredictionRollback.new()
		rollback.bind(player, game._replicas, game._collision_anchor)
		rollback.reset(1, 0, 0, 0)
		rollback._clock = 0.0
		var source := PacketInputSource.new()
		source.apply_packet(record)
		var contact_x := 0.0
		for tick in range(1, 10):
			await get_tree().physics_frame
			blocker.collision_layer = 16 if tick <= 3 else 0
			ActorStep.step(reference, record)
			rollback.capture(source, Vector2.RIGHT, 0, 0)
			rollback.advance(ActorStep.DT)
			assert(player.position.distance_to(reference.position) < 0.01,
					"the corpse must stop blocking on the same tick as authority: role %d tick %d" % [role, tick])
			assert((replica._ghost.collision_layer != 0) == (tick <= 3))
			if tick == 3:
				contact_x = player.position.x
		assert(player.position.x > contact_x + 20, "scheduled respawn releases prediction before the next snapshot")
	reference.free()
	carrier.free()
	player.role = 1
	player.restore_state(original)
	player.gravity = gravity
	replica.set_ghost_layer(2)
	replica.apply_snapshot(_actor(Vector2(1200, 500)), player.position, 102)

func _check_shared_motion(replica: Node2D) -> void:
	var data := _actor(Vector2(2000, 800))
	data["vel"] = Vector2(700, 0)
	data["axis"] = 1.0
	replica.apply_snapshot(data, game._local.position, 100)
	for at in range(101, 111):
		replica.anchor_collision(game._local.position, at)
		var expected: Vector2 = data["pos"] + data["vel"] * (at - 100) / 60.0
		assert(replica._opponent_canonical.is_equal_approx(expected), "known sustained motion continues through the required logical horizon")
	data["rewind"] = true
	replica.apply_snapshot(data, game._local.position, 200)
	replica.anchor_collision(game._local.position, 206)
	assert(replica._opponent_canonical == data["pos"], "rewind without path remains at its authority anchor")
	assert(not get_tree().get_nodes_in_group("player").has(replica._forecast))
	replica.apply_snapshot(_actor(Vector2(1200, 500)), game._local.position, 102)

func _check_terrain_motion_cache(replica: Node2D) -> void:
	var actor: CharacterBody2D = replica._forecast
	var owner_node := Node2D.new()
	game._world.add_child(owner_node)
	var shape := RectangleShape2D.new()
	shape.size = Vector2(32, 400)
	_install_test_wall(owner_node, shape, Vector2(1400, 500))
	await get_tree().physics_frame
	actor.actor_colliders.assign([])
	actor.collision_mask = 1
	actor.position = Vector2(1200, 500)
	actor.cache_terrain_motion = false
	ActorStep.move_by(actor, Vector2(300, 50))
	var expected := actor.position
	actor.cache_terrain_motion = true
	actor.terrain_motion_cache.clear()
	for repeat in 2:
		actor.position = Vector2(1200, 500)
		actor.motion_contacts.clear()
		ActorStep.move_by(actor, Vector2(300, 50))
		assert(actor.position == expected and not actor.motion_contacts.is_empty(), "cache must preserve complete terrain travel and contact")
	assert(actor.terrain_motion_hits >= 2, "replaying identical axis queries must reuse retained results")
	# 超过缓存容量并绕过一轮淘汰，再次查询仍需与原生碰撞逐次一致。
	for index in 280:
		var motion := Vector2(100 + index, 25)
		actor.cache_terrain_motion = false
		actor.position = Vector2(1200, 500)
		actor.motion_contacts.clear()
		var expected_blocked := ActorStep.move_by(actor, motion)
		var expected_position := actor.position
		var expected_contacts: int = actor.motion_contacts.size()
		actor.cache_terrain_motion = true
		actor.position = Vector2(1200, 500)
		actor.motion_contacts.clear()
		var blocked := ActorStep.move_by(actor, motion)
		assert(actor.position == expected_position and blocked == expected_blocked
				and actor.motion_contacts.size() == expected_contacts, "FIFO eviction must preserve each native movement result")
		assert(actor.terrain_motion_cache.size() <= 256, "terrain query cache remains bounded")
	_install_test_wall(owner_node, shape, Vector2(1500, 500))
	await get_tree().physics_frame
	actor.position = Vector2(1200, 500)
	ActorStep.move_by(actor, Vector2(300, 50))
	assert(actor.position.x > expected.x + 90.0, "terrain rebuild must invalidate cached collision results")
	owner_node.free()
	TileDefs.terrain.notify_geometry_changed(Rect2())
	replica.bind_local(game._local)
	replica.apply_snapshot(_actor(Vector2(1200, 500)), game._local.position, 102)
	print("TERRAIN MOTION CACHE OK exact travel/contact and rebuild invalidation")

func _check_rewind_path(replica: Node2D) -> void:
	var world := AuthorityWorld.new()
	world.set_physics_process(false)
	game._world.add_child(world)
	var reference: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	world.add_child(reference)
	reference.set_physics_process(false)
	reference.role = 2
	reference.collision_layer = 0
	reference.set_input_source(PacketInputSource.new())
	reference.input_source._held = PacketInputSource.BIT_REWIND
	reference.rewinding = true
	world.players = {2: reference}
	world._round_state = NetEvent.RoundState.PLAYING
	world._snap_tick = 100
	world.time_economy = TimeEconomy.new(null, [2])
	var beta := BetaHistory.new(world)
	beta.frames[2] = []
	beta.cursors[2] = 0.0
	for tick in range(40, 101, 3):
		reference.position = Vector2(1000 + tick * 10, 500 + tick * 3)
		reference.is_squat = tick % 2 == 0
		beta.frames[2].append({"tick": tick, "player": reference.capture_state(), "bullets": {}})
	var actor: Dictionary = ProtocolFixture.frame()["world"]["players"][1].merged(reference.capture_motion_state(), true)
	actor.merge({"driver": reference.capture_driver_state(), "rewind": true, "rewind_path": beta.collision_path(2)}, true)
	# 经过真实 STATE 编解码再交给副本，覆盖空轨迹与增量快照的字段形式。
	var frame := ProtocolFixture.frame(100)
	frame["world"]["players"][2] = actor
	var sender := NetCodec.new()
	var receiver := NetCodec.new()
	var decoded := receiver.decode_state(ProtocolFixture.stream(sender.encode_state(frame)))
	assert(decoded == frame)
	replica.apply_snapshot(decoded["world"]["players"][2], game._local.position, 100)
	var reference_collider := ActorCollider.new(reference, 2)
	for tick in range(101, 133):
		world._snap_tick = tick
		beta.tick(ActorStep.DT)
		replica.step_rewind(tick)
		assert(replica._ghost.world_rect(Vector2(1000, 500)) == reference_collider.world_rect(Vector2(1000, 500)), "rewinding blocker must follow server history at every predicted tick")
	sender.state_ack = 1
	frame["tick"] = 102
	assert(receiver.decode_state(ProtocolFixture.stream(sender.encode_state(frame))) == frame)
	world.free()
	replica.apply_snapshot(_actor(Vector2(1200, 500)), game._local.position, 102)
	print("REWIND PATH OK codec/delta and 32 exact authority collision frames")

func _check_remote_input(replica: Node2D) -> void:
	var state := _actor(Vector2(1400, 500))
	state["vel"] = Vector2.ZERO
	state["axis"] = 0.0
	replica.apply_snapshot(state, game._local.position, 1000)
	var input := InputBuffer.neutral().merged({"seq": 1, "target_tick": 1002, "ax": 1.0,
			"held": PacketInputSource.BIT_UP | PacketInputSource.BIT_HASTE, "pressed": PacketInputSource.BIT_UP}, true)
	assert(not replica.receive_input(1000, {"frames": [input], "actions": [input]}))
	replica.anchor_collision(game._local.position, 1004)
	assert(replica._forecast.position == state["pos"], "hints cannot move a read-only authority proxy")
	state["pos"] += Vector2(20, -20)
	replica.apply_snapshot(state, game._local.position, 1004)
	assert(replica._forecast.position == state["pos"], "a new authority anchor updates collision geometry immediately")
	replica.apply_snapshot(_actor(Vector2(1400, 500)), game._local.position, 105)

func _check_hint_backlog(replica: Node2D) -> void:
	replica.apply_snapshot(_actor(Vector2(1400, 500)), game._local.position, 1000)
	var snapshots: int = replica._motion_frames.size()
	for index in 512:
		var input := InputBuffer.neutral().merged({"seq": index + 1, "target_tick": 1001 + index,
				"ax": 1.0 if index % 2 else -1.0, "pressed": PacketInputSource.BIT_UP}, true)
		assert(not replica.receive_input(1000 + index, {"frames": [input], "actions": [input]}))
	assert(replica._motion_frames.size() == snapshots,
			"remote hint traffic must not build replay history or block local prediction")
	replica.apply_snapshot(_actor(Vector2(1400, 500)), game._local.position, 105)
	print("HINT BACKLOG OK 512 updates retain no remote replay input")

func _check_late_input(replica: Node2D) -> void:
	var original := _frame(game._own_tick, game._latest_players, {})
	var rollback := game._rollback
	var gravity: float = game._local.gravity
	game._local.gravity = 0.0
	game._local.position = Vector2(1000, 500)
	game._local.velocity = Vector2(700, 0)
	game._rollback = PredictionRollback.new()
	game._rollback.bind(game._local, game._replicas, game._collision_anchor)
	game._rollback.reset(1, 0, 1000, 0)
	game._rollback._clock = 1000.0
	var frame := _frame(1000, {2: _actor(Vector2(1080, 500))}, {})
	game._apply_authority(frame)
	var source := PacketInputSource.new()
	source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0}, true))
	for index in 4:
		game._rollback.capture(source, Vector2.RIGHT, 0, 0)
		game._rollback.advance(ActorStep.DT)
	var before: Vector2 = game._local.position
	var reconciles: int = game._log_counts["reconciles"]
	var snapshots: int = replica._motion_frames.size()
	var actions: Array = []
	for index in 512:
		actions.append(InputBuffer.neutral().merged({"seq": index + 1, "target_tick": 1002,
				"pressed": PacketInputSource.BIT_UP}, true))
	game._on_remote_input(2, 1000, {"frames": [], "actions": actions})
	game._apply_pending_authority()
	assert(game._local.position == before and game._log_counts["reconciles"] == reconciles,
			"late and overflowing remote hints must not replay or freeze the local actor")
	game._on_event(1, NetEvent.Kind.HIT, {"id": (2 << 48) | 256, "tick": 1002,
			"shooter": 2, "victim": 1, "damage": 20, "hp": 80, "facing": 1, "source": 0,
			"pos": Vector2(1100, 500), "knock": Vector2(-1500, -1000)})
	game._apply_pending_authority()
	assert(game._local.hp == 80 and game._own_tick == 1000,
			"late authority impacts still repair the local actor at their original stage")
	reconciles = game._log_counts["reconciles"]
	game._apply_pending_authority()
	assert(game._log_counts["reconciles"] == reconciles, "unchanged authority events cannot replay twice")
	game._rollback.advance(ActorStep.DT)
	assert(game._rollback._sim_tick == 1005 and replica._motion_frames.size() == snapshots)
	game._local.gravity = gravity
	game._rollback = rollback
	game._apply_authority(original)
	print("LOCAL HISTORY OK hints cannot freeze motion; late authority hits still replay once")

func _check_projectiles() -> void:
	var spawn := {"id": REMOTE_ID, "tick": game._own_tick, "type_id": 1, "pos": Vector2(3000, 1000), "vel": Vector2(600, 0)}
	_event(NetEvent.Kind.BULLET_SPAWN, spawn)
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
			"traveled": 300.0, "direct_hit": false, "fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0}
	_event(NetEvent.Kind.BULLET_REWIND, {"role": 2, "tick": game._own_tick, "rewind": true, "projectiles": {REMOTE_ID: state}})
	assert(not bullet.is_physics_processing() and bullet.position == state["pos"])
	for i in 3: await get_tree().physics_frame
	assert(bullet.position == state["pos"] and bullet.traveled == 300.0)
	_event(NetEvent.Kind.BULLET_REWIND, {"role": 2, "tick": game._own_tick, "rewind": false, "projectiles": {REMOTE_ID: state}})
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
	_event(NetEvent.Kind.BULLET_SPAWN, spawn)
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
			"direct_hit": false, "fuse_active": true, "fuse_elapsed": 0.35, "fuse_duration": 0.4})
	assert(grenade.traveled == 120.0 and grenade._fuse_elapsed == 0.35)
	for i in 6: await get_tree().physics_frame
	assert(not game._bullets.has(REMOTE_ID + 1))
	var effects := game._world.get_children().filter(func(node: Node) -> bool: return node.scene_file_path == "res://scenes/effects/explosion.tscn")
	assert(effects.is_empty(), "a client fuse must not invent the explosion outcome")
	var explosion_pos := Vector2(2800, 1000)
	var outcome := {"id": REMOTE_ID + 1, "type_id": grenade_type,
			"pos": explosion_pos, "tick": game._own_tick}
	game._present_explosion(outcome, true)
	_event(NetEvent.Kind.EXPLOSION, outcome)
	game._world.canvas_transform = Transform2D(0.0, Vector2(320, 240) - explosion_pos)
	effects = game._world.get_children().filter(func(node: Node) -> bool: return node.scene_file_path == "res://scenes/effects/explosion.tscn")
	assert(effects.size() == 1)
	var effect: AnimatedSprite2D = effects[0]
	assert(effect.position == GridPathfinder.anchor_to_nearest(explosion_pos, game._local.position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT))
	assert(effect.is_playing() and effect.animation == &"explode")
	await _capture("explosion")
	var effect_frame := effect.frame
	await get_tree().create_timer(0.12).timeout
	assert(effect.frame > effect_frame)
	assert(game._local.hp == health and TileDefs.sub_hp == terrain)
	await get_tree().create_timer(0.6).timeout
	assert(not is_instance_valid(effect))
	spawn["id"] = REMOTE_ID + 2
	_event(NetEvent.Kind.BULLET_SPAWN, spawn)
	var flying: BulletBase = game._bullets[REMOTE_ID + 2]
	assert(not flying._fuse_active)
	_event(NetEvent.Kind.EXPLOSION, {"id": REMOTE_ID + 2, "type_id": grenade_type,
			"pos": explosion_pos, "tick": game._own_tick})
	assert(flying.is_queued_for_deletion(), "the authority explosion must finish a still-flying visual projectile")
	assert(game._local.hp == health and TileDefs.sub_hp == terrain)
	print("PROJECTILE EFFECT OK gravity, shooter exclusion, fuse, animation advances and finishes, no client damage")

func _capture(label: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture"): return
	await RenderingServer.frame_post_draw
	var folder := ProjectSettings.globalize_path("res://").path_join(".test_logs/projectile_visual")
	DirAccess.make_dir_recursive_absolute(folder)
	assert(game._world.get_texture().get_image().save_png(folder.path_join(label + ".png")) == OK)

func _terrain_layout(body: Node) -> Array:
	var result: Array = []
	for child: CollisionShape2D in body.get_children():
		result.append([child.position, child.shape.size])
	return result

func _install_test_wall(parent: Node, shape: RectangleShape2D, position: Vector2) -> void:
	var body := parent.get_node_or_null("Wall") as StaticBody2D
	if body == null:
		body = StaticBody2D.new()
		body.name = "Wall"
		parent.add_child(body)
		var hull := CollisionShape2D.new()
		hull.shape = shape
		body.add_child(hull)
	body.position = position
	TileDefs.terrain.notify_geometry_changed(Rect2())
