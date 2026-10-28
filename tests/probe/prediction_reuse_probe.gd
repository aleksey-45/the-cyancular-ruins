extends Node

class MatchView extends PvpMatchClient:
	func _ready() -> void:
		set_process(false)
		set_physics_process(false)
	func _exit_tree() -> void: pass

class TerrainView extends Level0:
	func _ready() -> void:
		set_process(false)
		set_physics_process(false)
	func _exit_tree() -> void: pass

var game: MatchView
var source := PacketInputSource.new()

func _ready() -> void:
	_run.call_deferred()

func _frame(at_tick: int) -> Dictionary:
	var saved := game._rollback.checkpoint_state(at_tick)
	var cursor: Array = saved["cursors"][1]
	return {"tick": at_tick, "map_revision": game._map_revision,
			"own": {"state": saved["players"][1], "epoch": cursor[0], "ack": cursor[1],
			"action_ack": cursor[2], "timing_seq": 0, "lead": 2, "rewind": false,
			"input": InputBuffer.neutral().merged({"epoch": cursor[0], "seq": cursor[3],
				"target_tick": cursor[4], "view_tick": cursor[5], "ax": cursor[6], "held": cursor[7], "aim": cursor[8]}, true)},
			"world": {"players": {1: {"rewind": false}}, "projectiles": saved["projectiles"]}, "time": saved["time"]}

func _setup() -> void:
	PvpSession.role = 1
	PvpSession.beta_mode = false
	Level0.pvp_mode = true
	MazeGenerator.set_map_file("res://maps/newfactory.cyrm")
	var grid := WorldBuilder.load_grid()
	game = MatchView.new()
	add_child(game)
	game._level0 = TerrainView.new()
	game.add_child(game._level0)
	game._level0.terrain = TileDefs.terrain
	game._world = SubViewport.new()
	game._world.name = "WorldViewport"
	game._level0.add_child(game._world)
	game._local = preload("res://scenes/player/player.tscn").instantiate()
	game._world.add_child(game._local)
	game._local.role = 1
	game._local.enable_manual_simulation()
	game._local.gravity = 0.0
	game._local.collision_mask = 0
	game._local.position = Vector2(3000, 500)
	game._local.set_controls_locked(false)
	game._rollback.bind(game._local)
	game._rollback.reset(1, 0, 100, 0)
	game._rollback._clock = 100.0
	game._bind_prediction_terrain()
	game._terrain.reset_prediction(100)
	game._rollback.tick_finished.connect(game._level0.flush_terrain_collision)
	game._rollback._remember_state()
	game._apply_authority(_frame(100))
	source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0}, true))

func _advance(count: int) -> void:
	for index in count:
		game._rollback.capture(source, Vector2.RIGHT, 100, 0)
		game._rollback.advance(ActorStep.DT)

func _blast() -> Dictionary:
	for y in TileDefs.sub_rows:
		for x in TileDefs.sub_cols:
			var sub := Vector2i(x, y)
			if TileDefs.sub_alive(sub) and TileDefs.explosion_destroyable(TileDefs.sub_texture(sub)):
				var pos := Vector2(sub * 16) + Vector2(8, 8)
				if GridPathfinder.toroidal_delta_px(pos, game._local.position,
						GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length() > 500:
					return {"id": (1 << 48) | 256, "tick": 103, "type_id": 5, "pos": pos, "confirmed": false}
	assert(false, "fixture requires destructible terrain away from the actor")
	return {}

func _change_input(at_tick: int, axis: float) -> void:
	for record: Dictionary in game._rollback.history:
		if record["target_tick"] == at_tick:
			record["ax"] = axis
			return
	assert(false, "fixture input must remain in the unacknowledged window")

func _check_world_reuse() -> void:
	var blast := _blast()
	game._rollback.combat_prediction.blasts[blast["id"]] = blast
	_advance(6)
	assert(not game._terrain.pending_cells().is_empty())
	var predicted_hp := TileDefs.sub_hp.duplicate()
	var actor: Dictionary = game._local.capture_state()
	var frame := _frame(102)
	var revision := TileDefs.collision_revision
	game._apply_authority(frame)
	assert(game._rollback.diagnostics["replay_ticks"] == 0 and game._rollback.reuse_detail["reason"] == "full",
			"a future explosion must not prevent comparing and reusing a matching historical world")
	assert(game._local.capture_state() == actor and TileDefs.sub_hp == predicted_hp and TileDefs.collision_revision == revision)
	assert(game._rollback.combat_prediction.confirm(blast) == Vector2i.ZERO,
			"matching explosion confirmation must not invalidate the simulated result")
	_change_input(105, -1.0)
	game._pending_replay_tick = 105
	var generation := game._terrain.generation
	game._apply_authority(frame, "input")
	assert(game._rollback.diagnostics["checkpoint_tick"] == 104 and game._rollback.diagnostics["replay_ticks"] == 2)
	assert(TileDefs.sub_hp == predicted_hp and TileDefs.collision_revision == revision,
			"a checkpoint after the explosion must retain terrain without reviving and destroying its collision")
	actor = game._local.capture_state()
	game._rollback.reconcile(frame["own"], 102, 0, false, {})
	assert(game._local.capture_state() == actor and TileDefs.sub_hp == predicted_hp,
			"checkpoint replay and full authoritative replay must produce identical actor and terrain state")
	assert(game._terrain.generation != generation)
	# 同 tick 补丁可以分批到达；比较历史时既不能漏掉子格，也不能累计预测伤害。
	var cells := game._terrain.prediction_cells_at(103)
	var first := {}
	var second := {}
	var index := 0
	for sub in cells:
		if index % 2 == 0: first[sub] = cells[sub]
		else: second[sub] = cells[sub]
		index += 1
	revision = TileDefs.collision_revision
	var geometry := CollisionBuilder.geometry_revision
	game.apply_terrain({"tick": 103, "revision": 1, "cells": first})
	game.apply_terrain({"tick": 103, "revision": 2, "cells": second})
	assert(TileDefs.sub_hp == predicted_hp and TileDefs.collision_revision == revision
			and CollisionBuilder.geometry_revision == geometry, "matching terrain patches must only confirm metadata")
	frame = _frame(104)
	game._apply_authority(frame)
	assert(game._rollback.diagnostics["replay_ticks"] == 0 and game._terrain.pending_cells().is_empty(),
			"matching changed terrain revisions must preserve the complete predicted suffix")
	# 第一个后续 tick 就失效时，锚点本身仍可复用，不必完整恢复。
	_change_input(105, 1.0)
	generation = game._terrain.generation
	game._apply_authority(frame)
	assert(game._rollback.diagnostics["checkpoint_tick"] == 104 and game._rollback.diagnostics["replay_ticks"] == 2
			and game._terrain.generation == generation, "the first invalid command must replay from the validated anchor")
	actor = game._local.capture_state()
	game._rollback.reconcile(frame["own"], 104, 0, false, {})
	assert(game._local.capture_state() == actor and TileDefs.sub_hp == predicted_hp)
	# 未预测到的权威地形变化必须拒绝复用，不能把收包后的当前值当成历史预测值。
	var target := Vector2i(-1, -1)
	for y in TileDefs.sub_rows:
		for x in TileDefs.sub_cols:
			var sub := Vector2i(x, y)
			if TileDefs.sub_alive(sub) and TileDefs.explosion_destroyable(TileDefs.sub_texture(sub)):
				target = sub
				break
		if target.x >= 0: break
	assert(target.x >= 0)
	frame = _frame(105)
	game.apply_terrain({"tick": 105, "revision": 3, "cells": {target: 0}})
	frame["map_revision"] = 3
	assert(not game._rollback.can_reuse(frame) and game._rollback.reuse_detail["reason"] == "terrain_state")
	var tick := game._rollback._sim_tick
	game._rollback.advance(ActorStep.DT)
	assert(game._rollback._sim_tick == tick + 1 and not game._rollback.can_replay_from(tick),
			"pending terrain authority must invalidate old checkpoints while the prediction clock continues")
	game._apply_authority(frame)
	assert(not game._terrain.needs_state and not TileDefs.sub_alive(target))
	assert(int(game._terrain.history_stats()["prediction_ticks"]) <= PredictionRollback.KEEP)
	print("WORLD REUSE OK same-tick comparison, future terrain, suffix checkpoints, patch confirmation and divergence")

func _check_confirmations() -> void:
	var prediction := CombatPrediction.new()
	prediction.bind(game._local)
	game._local.apply_authoritative_state(100, game._local.max_waterproof, false)
	var id := (2 << 48) | 256
	var pos := game._local.position - Vector2(20, 0)
	prediction._apply_hit(id, 201, 0, game._local, pos, 300.0, 10)
	var hit := {"id": id, "tick": 201, "source": 0, "victim": 1, "shooter": 2, "damage": 10,
			"pos": pos, "hp": game._local.hp, "knock": game._local.combat.knock_velocity, "facing": game._local.facing_direction}
	assert(prediction.confirm_hit(hit) == Vector2i.ZERO and prediction.confirm_hit(hit) == Vector2i.ZERO)
	assert(prediction.confirm_hit(hit.merged({"pos": pos + Vector2(1, 0)}, true)) == Vector2i.ZERO,
			"a changed source position with identical complete hit effects must keep simulation")
	assert(prediction.hits[id].size() == 1, "duplicate confirmation must not append another logical hit")
	var state := {"type_id": 1, "pos": Vector2(3000, 500), "vel": Vector2(100, 0), "traveled": 0.0,
			"fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	prediction.seed_projectile(id, state, 200, game._local)
	var bullet: BulletBase = prediction.projectiles[id]["bullet"]
	prediction.projectiles[id]["sim_tick"] = 201
	prediction._finish_direct(bullet, 201)
	assert(prediction.end_projectiles({"tick": 201, "ids": [id]}) == Vector2i.ZERO,
			"matching HIT and BULLET_END must retain the same predicted contact")
	assert(prediction.end_projectiles({"tick": 200, "ids": [id]}) == Vector2i(200, 201),
			"a rejected contact must invalidate the original contact tick too")
	prediction.projectiles[id]["bullet"].free()
	prediction.projectiles.erase(id)
	prediction.ended.clear()
	assert(prediction.confirm_hit(hit.merged({"hp": hit["hp"] - 1}, true)) == Vector2i(201, 201),
			"a genuinely different damage result must invalidate the hit stage")
	var blast := {"id": id, "tick": 202, "type_id": 5, "pos": Vector2(200, 200), "confirmed": false}
	prediction.blasts[id] = blast
	prediction.step(202, [], false)
	assert(prediction.confirm(blast) == Vector2i.ZERO)
	assert(prediction.confirm(blast.merged({"tick": 204}, true)) == Vector2i(202, 204),
			"moving a confirmed explosion must invalidate the old tick as well as the new tick")
	var beam := {"id": id, "tick": 203, "type_id": 6, "shooter_role": 2,
			"pts": PackedVector2Array([Vector2.ZERO, Vector2(20, 0)]), "half_width": 2.0}
	prediction.beams[id] = beam
	assert(prediction.step_beams(203, 2, []))
	assert(prediction.receive_beam(beam) == Vector2i.ZERO)
	assert(prediction.receive_beam(beam.merged({"half_width": 3.0}, true)) == Vector2i.ZERO,
			"changed beam geometry without changed contacts must keep simulation")
	game._local.apply_authoritative_state(100, game._local.max_waterproof, false)
	var touching := beam.merged({"tick": 205, "pts": PackedVector2Array([
			game._local.position - Vector2(100, 0), game._local.position + Vector2(100, 0)])}, true)
	prediction.beams[id] = touching
	assert(prediction.step_beams(205, 2, [game._local]))
	assert(prediction._outcomes[205][["beam", id]]["contacts"].has(1))
	assert(prediction.receive_beam(touching.merged({"pts": PackedVector2Array([
			game._local.position - Vector2(100, 200), game._local.position + Vector2(100, -200)])}, true)) == Vector2i(203, 205),
			"a changed beam contact must invalidate its affected historical ticks")
	var reward := {"serial": 1, "tick": 203, "role": 1, "phase": 0, "amount": 10}
	assert(prediction.receive_reward(reward) and not prediction.receive_reward(reward))
	prediction.restore_checkpoint(201, {})
	assert(not prediction._outcomes.has(202) and not prediction._outcomes.has(203))
	prediction.acknowledge(201)
	assert(prediction._outcomes.is_empty())
	prediction.clear()
	print("CONFIRMATION REUSE OK matching and changed hits, explosions, beams, duplicate rewards and checkpoint invalidation")

func _predict(blast: Dictionary) -> int:
	var profile := WeaponRegistry.projectile_profile(blast["type_id"])
	return game._terrain.predict_blast(blast["id"], blast["type_id"], blast["pos"], blast["tick"],
			profile["explosion_radius"], profile["explosion_damage"])

func _check_terrain_batch() -> void:
	_setup()
	var blast := _blast()
	_predict(blast)
	var hp := TileDefs.sub_hp.duplicate()
	var grid := MazeGenerator.copy_grid(MazeGenerator.current_grid)
	var collision := game._terrain.get_collision_snapshot(true)
	game._terrain.reset_prediction(100)
	var profile := WeaponRegistry.projectile_profile(blast["type_id"])
	game._terrain.damage_blast(blast["pos"], profile["explosion_radius"], profile["explosion_damage"], 0)
	assert(TileDefs.sub_hp == hp and MazeGenerator.current_grid == grid
			and game._terrain.get_collision_snapshot(true) == collision,
			"normal and predicted damage must share exactly the same terrain calculation")
	game._terrain.reset()
	var candidates := Explosion.destructible_subs(blast["pos"], profile["explosion_radius"])
	var sub: Vector2i = candidates[0]["sub"]
	var full_hp := game._terrain.get_hp(sub)
	TileDefs.apply_sub_hp(sub, 0)
	_predict(blast)
	var builds: int = game._terrain.history_stats()["kernel_builds"]
	game._terrain.restore_checkpoint(100)
	TileDefs.restore_sub(sub, full_hp)
	_predict(blast)
	assert(game._terrain.history_stats()["kernel_builds"] == builds and game._terrain.get_hp(sub) < full_hp,
			"cached kernels include candidates restored by an earlier branch")
	game._terrain.acknowledge(103)
	assert(game._terrain.history_stats()["kernels"] == 0)
	game._rollback.combat_prediction.clear()
	game.free()
	print("TERRAIN BATCH OK shared normal/predicted damage, restored candidate and cache lifetime")

func _run() -> void:
	_setup()
	_check_world_reuse()
	_check_confirmations()
	game._rollback.combat_prediction.clear()
	game.free()
	_check_terrain_batch()
	print("PREDICTION REUSE PROBE OK complete historical world and event validation")
	get_tree().quit()
