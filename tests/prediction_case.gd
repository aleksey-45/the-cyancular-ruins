extends "res://tests/case.gd"

class PhaseCombat extends CombatPrediction:
	var phases: Array = []
	func step_beams(at: int, role: int, players: Array) -> void:
		phases.append(["role", at, role, players[0].global_position])
		super(at, role, players)
	func step(at: int, players: Array, first: bool) -> void:
		phases.append(["projectiles", at, players[0].global_position])
		super(at, players, first)

var _views: Array[SubViewport] = []
var _terrains: Array[Terrain] = []

static func wire_state(state: Array, rewind: bool = false) -> Array:
	var record := state.duplicate()
	record.resize(PlayerStateSchema.ACTOR_SIZE)
	for field in ["type_id", "axis", "held", "respawn_tick"]:
		record[PlayerStateSchema.slot(field)] = 0
	for field in ["previewing", "haste"]:
		record[PlayerStateSchema.slot(field)] = false
	record[PlayerStateSchema.slot("aim")] = Vector2.RIGHT
	record[PlayerStateSchema.slot("epoch")] = 1
	record[PlayerStateSchema.slot("rewind")] = rewind
	record[PlayerStateSchema.slot("move_mult")] = Vector2.ONE
	record[PlayerStateSchema.slot("rewind_path")] = []
	return record

func run(tree: SceneTree) -> void:
	for local_role in [1, 2]:
		_contact(tree, local_role, 2)
	_contact(tree, 1, 3)
	_controls_and_phases(tree)
	for role in [1, 2]: _rewind_paths(tree, role)
	_known_events(tree)

func _map_world(tree: SceneTree, info: Dictionary) -> Dictionary:
	var view := SubViewport.new()
	view.world_2d = World2D.new()
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	tree.root.add_child(view)
	_views.append(view)
	var geometry := Terrain.new()
	geometry.configure(info["grid"], info["subgrid"], TileDefs._defs,
			{"tile_size": Terrain.TILE_SIZE, "sub_size": Terrain.SUB_SIZE,
			"chunk_cells": Terrain.CHUNK_CELLS, "cache_states": Terrain.CACHE_STATES,
			"wall_type": TileDefs.TYPE_WALL, "liquid_type": TileDefs.TYPE_LIQUID,
			"ledge_thickness": Terrain.LEDGE_THICKNESS, "blast_inner": TileDefs.BLAST_INNER_FRACTION})
	geometry.attach(view)
	geometry.flush_collisions()
	_terrains.append(geometry)
	return {"view": view, "terrain": geometry}

func _frame(at: int, authority: Dictionary, local_role: int) -> Dictionary:
	var records := {}
	for role in authority:
		records[role] = wire_state(authority[role].capture_state(), authority[role].rewinding)
	return {"tick": at, "map_revision": 0,
		"own": {"state": authority[local_role].capture_state(), "epoch": 1,
			"ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2,
			"input": InputBuffer.neutral(), "rewind": authority[local_role].rewinding},
		"world": {"players": records, "projectiles": {}}, "time": {}}

func _state(frame: PredictionFrame) -> Array:
	return [frame.tick, frame.player, frame.remote, frame.layers, frame.rewinding,
		frame.projectiles._values, frame.time]

func _contact(tree: SceneTree, local_role: int, count: int) -> void:
	cleanup()
	TileDefs.load_defs()
	var info := MapFormat.load_map_info("res://maps/newfactory.cyrm", true)
	GameParameters.MAP_WIDTH = 9600
	GameParameters.MAP_HEIGHT = 6400
	Level0.pvp_mode = true
	CombatComponent.pvp_arena = true
	var server := _map_world(tree, info)
	var client := _map_world(tree, info)
	var authority := {}
	for role in range(1, count + 1):
		TileDefs.terrain = server["terrain"]
		var body := player(server["view"], role)
		body.team = 1 if role % 2 else 2
		body.weapons.set_initial_inventory([])
		body.global_position = Vector2(5900, 5766.92 - (role - 1) * 106.08)
		body._grounded = true
		body.collision_layer = CollisionWorld.team_layer(body.team)
		body.collision_mask = 1 | CollisionWorld.team_layer(3 - body.team)
		body._apply_layers()
		body.sync_collision_geometry()
		authority[role] = body
	TileDefs.terrain = client["terrain"]
	var local := player(client["view"], local_role)
	local.team = authority[local_role].team
	local.weapons.set_initial_inventory([])
	local.collision_mask = authority[local_role].collision_mask
	local._apply_layers()
	var rollback := PredictionRollback.new()
	rollback.bind(local)
	rollback.terrain = client["terrain"]
	for role in authority:
		if role != local_role: rollback.world.ensure_actor(role, authority[role].team)
	rollback.reset(1, 0, 0, 0)
	rollback.world.restore_authority(_frame(0, authority, local_role))
	rollback._remember_state()
	var local_differences := 0
	var world_differences := 0
	var mutations := 0
	var replay_differences := 0
	for at in range(1, 241):
		TileDefs.terrain = server["terrain"]
		for role in authority:
			ActorStep.step(authority[role], InputBuffer.neutral())
		TileDefs.terrain = client["terrain"]
		rollback._clock = at + 4
		while rollback.world.tick < at + 4:
			rollback._step(rollback._input.take(rollback.world.tick + 1), true)
		if at % 2: continue
		var frame := _frame(at, authority, local_role)
		var saved: PredictionFrame = rollback._states[at]
		if not Player.prediction_difference(saved.player, frame["own"]["state"]).is_empty():
			local_differences += 1
		if not rollback.world.difference(saved, frame).is_empty():
			world_differences += 1
		var before := _state(rollback.world.capture(rollback._input.capture_cursor()))
		var reuse := rollback.reusable_tick(frame) >= 0
		if before != _state(rollback.world.capture(rollback._input.capture_cursor())):
			mutations += 1
		rollback.reconcile(frame, 0, reuse)
		if at % 30 == 0:
			before = _state(rollback.world.capture(rollback._input.capture_cursor()))
			var immutable := saved.remote.duplicate(true)
			rollback.replay_from(at + 1)
			if before != _state(rollback.world.capture(rollback._input.capture_cursor())) or saved.remote != immutable:
				replay_differences += 1
	expect(local_differences == 0 and world_differences == 0,
			"stacked actors agree exactly for 120 snapshots, local=%d actors=%d local_diff=%d remote_diff=%d" % [local_role, count, local_differences, world_differences])
	expect(mutations == 0, "authority comparison never changes the future collision world")
	expect(replay_differences == 0, "whole-world replay reproduces future contact state and preserves old checkpoints")
	rollback.combat_prediction.clear()
	cleanup()

func _controls_and_phases(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var local := player(parent, 1)
	local.gravity = 0.0
	local.global_position = Vector2(300, 400)
	local.apply_collision_pose()
	var rollback := PredictionRollback.new()
	rollback.bind(local)
	rollback.terrain = TileDefs.terrain
	rollback.world.ensure_actor(2, 2)
	var records := {1: wire_state(local.capture_state()), 2: wire_state(local.capture_state())}
	records[2][PlayerStateSchema.slot("pos")] = Vector2(600, 400)
	var own := {"state": local.capture_state(), "epoch": 1, "ack": 0, "action_ack": 0,
		"timing_seq": 0, "lead": 2, "input": InputBuffer.neutral(), "rewind": false}
	var frame := {"tick": 0, "map_revision": 0, "own": own,
		"world": {"players": records, "projectiles": {}}, "time": {}}
	rollback.reset(1, 0, 0, 0)
	rollback.world.restore_authority(frame)
	rollback._remember_state()
	rollback._clock = 4
	while rollback.world.tick < 4: rollback._step(rollback._input.take(rollback.world.tick + 1), true)
	expect(rollback.reusable_tick(frame) == 4, "the unchanged complete world retains its predicted suffix")
	_catchup(rollback)
	for field in ["pos", "axis", "held", "squat", "locked", "move_mult", "rewind", "respawn_tick"]:
		var changed := frame.duplicate(true)
		match field:
			"pos": changed["world"]["players"][2][PlayerStateSchema.slot(field)] += Vector2(0.001, 0)
			"axis": changed["world"]["players"][2][PlayerStateSchema.slot(field)] = 1.0
			"held": changed["world"]["players"][2][PlayerStateSchema.slot(field)] = ActorInput.BIT_DOWN
			"move_mult": changed["world"]["players"][2][PlayerStateSchema.slot(field)] = Vector2(0.5, 1)
			"respawn_tick": changed["world"]["players"][2][PlayerStateSchema.slot(field)] = 3
			_: changed["world"]["players"][2][PlayerStateSchema.slot(field)] = true
		expect(rollback.reusable_tick(changed) < 0, "remote-only %s change invalidates the world suffix" % field)
	var departed := frame.duplicate(true)
	departed["world"]["players"].erase(2)
	expect(rollback.reusable_tick(departed) < 0, "remote roster changes invalidate the world suffix")
	rollback.reconcile(departed, 0, false)
	expect(not rollback.world.actors.has(2) and rollback.world.actor(2).collision_layer == 0,
			"departure removes collision without freeing its stable actor slot")
	# 角色阶段看到上一步回溯位姿；本 tick 的路径只在 Beta 阶段写入。
	var phase := PhaseCombat.new()
	rollback.world.combat = phase
	phase.bind(local)
	phase.actors = rollback.world.actors
	frame["own"]["rewind"] = true
	frame["world"]["players"][1][PlayerStateSchema.slot("rewind")] = true
	frame["world"]["players"][1][PlayerStateSchema.slot("rewind_path")] = [[1, Vector2(250, 400), 0]]
	frame["world"]["players"][2][PlayerStateSchema.slot("axis")] = 1.0
	rollback.world.restore_authority(frame)
	var remote_before := rollback.world.actor(2).global_position
	rollback.world.step_tick(InputBuffer.neutral(), true)
	expect(phase.phases[0][3] == Vector2(300, 400) and phase.phases[1][3] == Vector2(300, 400),
			"all role beam stages run before the current Beta path knot")
	expect(phase.phases[2][2] == Vector2(250, 400), "projectiles see the current Beta path knot")
	expect(rollback.world.tick == 1 and rollback.world.actor(2).global_position.x > remote_before.x,
			"local rewind leaves the world clock and remote movement running")
	var remote_rid := rollback.world.actor(2).get_rid()
	frame["own"]["epoch"] = 2
	frame["own"]["rewind"] = false
	frame["world"]["players"][1][PlayerStateSchema.slot("rewind")] = false
	frame["world"]["players"][1][PlayerStateSchema.slot("rewind_path")] = []
	rollback.reconcile(frame, 0, false)
	expect(rollback.epoch == 2 and rollback.world.tick == 2 and not local.rewinding
			and rollback.world.actor(2).get_rid() == remote_rid,
			"an epoch boundary rebuilds the whole world and retains stable remote RIDs")
	rollback.combat_prediction.clear()
	cleanup()

func _rewind_paths(tree: SceneTree, role: int) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var local := player(parent, 1)
	local.global_position = Vector2(300, 400)
	local.apply_collision_pose()
	var rollback := PredictionRollback.new()
	rollback.bind(local)
	rollback.terrain = TileDefs.terrain
	rollback.world.ensure_actor(2, 2)
	var records := {1: wire_state(local.capture_state(), true), 2: wire_state(local.capture_state(), true)}
	records[2][PlayerStateSchema.slot("pos")] = Vector2(600, 400)
	var origin: Vector2 = records[role][PlayerStateSchema.slot("pos")]
	var middle := origin + Vector2(50, 0)
	var future_pos := origin + Vector2(100, 0)
	records[role][PlayerStateSchema.slot("rewind_path")] = [[2, middle, 0], [4, origin, 0]]
	var frame := {"tick": 0, "map_revision": 0,
		"own": {"state": local.capture_state(), "rewind": true, "epoch": 1,
			"ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2, "input": InputBuffer.neutral()},
		"world": {"players": records, "projectiles": {}}, "time": {}}
	rollback.reset(1, 0, 0, 0)
	rollback.world.restore_authority(frame)
	rollback._remember_state()
	rollback._clock = 4
	while rollback.world.tick < 4: rollback._step(rollback._input.take(rollback.world.tick + 1), true)
	var boundary := frame.duplicate(true)
	boundary["world"]["players"][role][PlayerStateSchema.slot("rewind_path")][1][1] = origin + Vector2(25, 0)
	expect(rollback.reusable_tick(boundary) < 0, "a path change at the predicted endpoint requires replay, role=%d" % role)
	var future := frame.duplicate(true)
	future["world"]["players"][role][PlayerStateSchema.slot("rewind_path")].append([6, future_pos, 0])
	var before := _state(rollback.world.capture(rollback._input.capture_cursor()))
	var saved: PredictionFrame = rollback._states[3]
	var immutable := _state(saved).duplicate(true)
	var authority := future.duplicate(true)
	expect(rollback.reusable_tick(future) == 4, "future path updates retain the predicted suffix, role=%d" % role)
	expect(before == _state(rollback.world.capture(rollback._input.capture_cursor())), "path comparison leaves the world unchanged")
	rollback.reconcile(future, 0, true)
	expect(rollback.replay_ticks == 0 and rollback._states[3] == saved
			and before == _state(rollback.world.capture(rollback._input.capture_cursor())),
			"accepting future paths preserves physics and existing checkpoints")
	rollback._clock = 6
	while rollback.world.tick < 6: rollback._step(rollback._input.take(rollback.world.tick + 1), true)
	expect(rollback.world.actor(role).global_position == future_pos, "the accepted future knot executes at its tick")
	# tick 3 的检查点产生于新路径到达前；比较依据是之后实际采用的路径。
	var next := future.duplicate(true)
	next["tick"] = 3
	next["own"]["state"] = saved.player
	next["world"]["players"][role][PlayerStateSchema.slot("pos")] = middle
	next["world"]["players"][role][PlayerStateSchema.slot("rewind_path")] = [[4, origin, 0], [6, future_pos, 0]]
	expect(rollback.reusable_tick(next) == 6, "comparison trims expired knots and uses the latest accepted plan")
	rollback.reconcile(next, 0, true)
	before = _state(rollback.world.capture(rollback._input.capture_cursor()))
	rollback.replay_from(4)
	expect(before == _state(rollback.world.capture(rollback._input.capture_cursor()))
			and _state(saved) == immutable and future == authority,
			"restoring an older checkpoint retains new paths without changing history or authority data")
	var changed := next.duplicate(true)
	var corrected := origin + Vector2(75, 0)
	changed["world"]["players"][role][PlayerStateSchema.slot("rewind_path")][0][1] = corrected
	expect(rollback.reusable_tick(changed) < 0, "an intermediate path change requires replay even when the endpoint agrees")
	rollback.reconcile(changed, 0, false)
	var corrected_state: Array = rollback._states[4].player if role == local.role else rollback._states[4].remote[role]
	expect(rollback.replay_ticks == 3 and corrected_state[PlayerStateSchema.slot("pos")] == corrected
			and rollback.world.actor(role).global_position == future_pos,
			"world replay corrects the intermediate pose even when paths converge")
	rollback.combat_prediction.clear()
	cleanup()

func _catchup(rollback: PredictionRollback) -> void:
	var original := _state(rollback.world.capture(rollback._input.capture_cursor()))
	var initial: PredictionFrame = rollback._states[0]
	var phases := PhaseCombat.new()
	rollback.world.combat = phases
	phases.bind(rollback.world.local)
	phases.actors = rollback.world.actors
	for batch in [true, false]:
		rollback.world.restore(initial)
		rollback.world.history.discard_after(0)
		rollback._input.restore_cursor(initial.cursor)
		rollback._clock = 0
		phases.phases.clear()
		if batch:
			rollback.advance(4.0 * ActorStep.DT)
		else:
			for at in 4: rollback.advance(ActorStep.DT)
		expect(_state(rollback.world.capture(rollback._input.capture_cursor())) == original,
				"normal prediction and clock catch-up produce the same world, batch=%s" % batch)
		expect(phases.phases.size() == 12,
				"each of four ticks runs two role phases and one projectile phase exactly once")

func _known_events(tree: SceneTree) -> void:
	var timely := _event_result(tree, false)
	var late := _event_result(tree, true)
	expect(timely == late, "late rewind, projectile and reward events equal one timely world simulation")
	cleanup()

func _event_result(tree: SceneTree, late: bool) -> Array:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var local := player(parent, 1)
	local.global_position = Vector2(300, 400)
	local.apply_collision_pose()
	var rollback := PredictionRollback.new()
	rollback.bind(local)
	rollback.terrain = TileDefs.terrain
	rollback.time_economy = TimeEconomy.new(TimeRules.new(), [1])
	rollback.time_economy.accounts[1].balance = 10.0
	rollback.world.ensure_actor(2, 2)
	var remote := wire_state(local.capture_state())
	remote[PlayerStateSchema.slot("pos")] = Vector2(600, 400)
	remote[PlayerStateSchema.slot("rewind_path")] = [[3, Vector2(650, 400), 0]]
	var frame := {"tick": 0, "own": {"state": local.capture_state(), "rewind": false},
		"world": {"players": {1: wire_state(local.capture_state()), 2: remote}, "projectiles": {}},
		"time": rollback.time_economy.state_payload()}
	rollback.reset(1, 0, 0, 0)
	rollback.world.restore_authority(frame)
	rollback._remember_state()
	var id: int = (2 << 48) | 256
	var state := {"type_id": WeaponRegistry.all_ids()[0], "pos": Vector2(650, 700),
		"vel": Vector2(100, 0), "traveled": 0.0, "fuse_active": false,
		"fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	var rewind := {"tick": 2, "role": 2, "rewind": true,
		"projectiles": {id: state.merged({"pos": Vector2(680, 700)}, true)}}
	var reward := {"serial": 1, "tick": 2, "phase": 2, "role": 1, "amount": 3}
	if not late:
		rollback.combat_prediction.seed_projectile(id, state, 1, rollback.world.actor(2))
		rollback.world.confirm_rewind(rewind)
		rollback.combat_prediction.receive_reward(reward)
	for at in range(1, 6):
		rollback._clock = at
		rollback._step(rollback._input.take(at), true)
	if late:
		rollback.combat_prediction.seed_projectile(id, state, 1, rollback.world.actor(2))
		rollback.world.confirm_rewind(rewind)
		rollback.combat_prediction.receive_reward(reward)
		expect(rollback.review_rewards() == 2, "late reward joins the same earliest world replay boundary")
		rollback.replay_from(2)
	expect(rollback.world.actor(2).rewinding and rollback.world.actor(2).global_position == Vector2(650, 400),
			"a known rewind event applies its role mode and path in the Beta stage")
	expect(rollback.combat_prediction.projectiles[id].bullet.position == Vector2(680, 700),
			"rewinding owner projectiles restore at the Beta stage and stay paused")
	expect(rollback.time_economy.accounts[1].balance == 13.0, "the role reward deposits once at its original phase")
	var result := _state(rollback.world.capture(rollback._input.capture_cursor()))
	# 校正结束事件也必须撤销这个攻击更早的错误接触，但收包不改变物理弹丸。
	rollback.combat_prediction._outcomes[3] = {["contact", id]: {}}
	var span := rollback.combat_prediction.end_projectiles({"tick": 5, "ids": [id]})
	expect(span == Vector2i(3, 5) and not rollback.combat_prediction.projectiles[id].bullet.finished,
			"end confirmation invalidates the earliest attack contact without mutating the running world")
	rollback.combat_prediction.clear()
	return result

func cleanup() -> void:
	for geometry in _terrains: geometry.close()
	_terrains.clear()
	for view in _views:
		CollisionWorld.release_space(view.world_2d.space)
		view.free()
	_views.clear()
	super()
