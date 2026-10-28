extends Node

class MatchView extends PvpMatchClient:
	func _ready() -> void:
		set_physics_process(false)
		set_process(false)
	func _exit_tree() -> void: pass

class TerrainView extends Level0:
	func _ready() -> void:
		set_physics_process(false)
		set_process(false)
	func _exit_tree() -> void: pass

var game: MatchView

func _ready() -> void:
	_run.call_deferred()

func _state(frame: Dictionary) -> void:
	game._on_state(frame)
	game._apply_pending_authority()

var rows: Array = []
var local_template: Dictionary
var remote_template: Dictionary
var own_template: Dictionary
const OWNER_ID := 77

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.test_logs/rewind_late_fix"))
	PvpSession.role = 1
	PvpSession.beta_mode = false
	PvpSession.room_mode = PvpSession.MODE_PVP
	Level0.pvp_mode = true
	Settings.pvp_show_enemy_hp = false
	MazeGenerator.set_map_file("res://maps/newfactory.cyrm")
	var grid := WorldBuilder.load_grid()
	for owner in [1, 2]:
		for order in ["event_then_state_same_batch", "state_then_event_same_batch", "start_and_resume_same_batch", "state_applied_then_old_start", "state_applied_then_old_resume"]:
			_setup()
			_check_order(owner, order)
			game._rollback.combat_prediction.clear()
			game.free()
	for owner in [1, 2]:
		for check: Callable in [_check_anchor_boundary, _check_snapshot_only, _check_retired, _check_queued_visual, _check_resume_detonation, _check_matching_confirmation]:
			_setup()
			check.call(owner)
			game._rollback.combat_prediction.clear()
			game.free()
	_setup()
	_check_reuse()
	game._rollback.combat_prediction.clear()
	game.free()
	var file := FileAccess.open("res://.test_logs/rewind_late_fix/result.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "\t"))
	file.close()
	print("BULLET REWIND ORDER PROBE OK: ", rows.size(), " cases")
	get_tree().quit()

func _setup() -> void:
	game = MatchView.new()
	add_child(game)
	game._level0 = TerrainView.new()
	game.add_child(game._level0)
	game._world = SubViewport.new()
	game._world.size = Vector2i(640, 480)
	game._level0.add_child(game._world)
	game._local = preload("res://scenes/player/player.tscn").instantiate()
	game._world.add_child(game._local)
	game._local.enable_manual_simulation()
	game._local.set_physics_process(false)
	game._local.role = 1
	game._local.gravity = 0.0
	game._local.collision_mask = 0
	game._local.position = Vector2(1000, 500)
	game._collision_anchor = ActorCollider.new(game._local, 32)
	game._rollback.bind(game._local, game._replicas, game._collision_anchor)
	game._rollback.reset(1, 0, 98, 0)
	game._playback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	game.phase = PvpMatchClient.Phase.ONLINE
	game._ensure_replica(2)
	game._replicas[2]._forecast.gravity = 0.0
	game._replicas[2]._forecast.position = Vector2(1600, 500)
	game._replicas[2]._forecast.collision_mask = 0
	local_template = _actor_from_player(game._local, InputBuffer.neutral())
	remote_template = _actor_from_player(game._replicas[2]._forecast, InputBuffer.neutral())
	own_template = game._local.capture_state().duplicate(true)
	_state(_snapshot(98, 2, 1, {}))

func _actor_from_player(player: CharacterBody2D, input: Dictionary) -> Dictionary:
	return player.capture_motion_state().merged({"pose": player.state,
			"driver": player.capture_driver_state(), "input": input.duplicate(true), "rewind_path": [],
			"type_id": player.weapons.current_type_id(), "hp": player.hp, "waterproof": player.waterproof,
			"downed": player.is_downed(), "aim": Vector2.RIGHT, "previewing": false, "haste": false,
			"rewind": player.rewinding, "epoch": input["epoch"], "respawn_tick": 0,
			"input_ack": input["seq"], "action_ack": 0, "input_age": 0, "axis": input["ax"],
			"held": input["held"], "move_mult": player.weapons.movement_multiplier()}, true)

func _snapshot(tick: int, owner: int, epoch: int, projectiles: Dictionary) -> Dictionary:
	var frame := ProtocolFixture.frame(tick)
	frame["own"]["state"] = own_template.duplicate(true)
	frame["world"]["players"] = {1: local_template.duplicate(true), 2: remote_template.duplicate(true)}
	frame["world"]["players"][owner]["epoch"] = epoch
	frame["world"]["players"][owner]["input"]["epoch"] = epoch
	if owner == 1:
		frame["own"]["epoch"] = epoch
		frame["own"]["input"]["epoch"] = epoch
	frame["world"]["projectiles"] = projectiles.duplicate(true)
	return frame

func _projectile(x: float) -> Dictionary:
	return {"type_id": 1, "pos": Vector2(x, 1000), "vel": Vector2(600, 0), "traveled": x - 2800,
			"direct_hit": false, "fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0}

func _sample(owner: int, id: int) -> Dictionary:
	var prediction: Variant = game._rollback.combat_prediction.projectiles.get(id)
	var visual: BulletBase = game._bullets.get(id)
	var actor: CharacterBody2D = game._local if owner == 1 else game._replicas[owner]._forecast
	return {"authority_tick": game._own_tick, "simulation_tick": game._rollback._sim_tick,
			"owner_rewinding": actor.rewinding, "prediction_present": prediction != null,
			"prediction_active": prediction.active if prediction != null else false,
			"prediction_x": prediction["bullet"].position.x if prediction != null else null,
			"visual_x": visual.position.x if visual != null else null,
			"visual_running": visual.is_physics_processing() if visual != null else false,
			"prediction_instance": prediction["bullet"].get_instance_id() if prediction != null else 0,
			"visual_instance": visual.get_instance_id() if visual != null else 0,
			"pending_replay": game._pending_replay, "reuse": game._rollback.reuse_detail.duplicate(true)}

func _tick_without_state() -> void:
	game._apply_pending_authority()
	game._rollback.advance(ActorStep.DT)
	for bullet: BulletBase in game._bullets.values():
		if bullet.is_physics_processing(): bullet.simulate_tick(ActorStep.DT)

func _check_order(owner: int, order: String) -> void:
	var id := (owner << 48) | OWNER_ID
	# 出生事件始终先交付，保留同一 EVENT lane 的可靠顺序。
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, _projectile(2990).merged({"id": id, "tick": 99}))
	game._bullets[id].collision_mask = 0
	var event := {"role": owner, "tick": 100, "rewind": order != "state_applied_then_old_resume",
			"projectiles": {id: _projectile(3000)}}
	if not event["rewind"]:
		game._on_event(1, NetEvent.Kind.BULLET_REWIND, event.merged({"tick": 99, "rewind": true}, true))
	var frame := _snapshot(102, owner, 2, {id: _projectile(3020)})
	var before: Dictionary = {}
	match order:
		"event_then_state_same_batch":
			game._on_event(1, NetEvent.Kind.BULLET_REWIND, event)
			game._on_state(frame)
			game._apply_pending_authority()
		"state_then_event_same_batch":
			game._on_state(frame)
			game._on_event(1, NetEvent.Kind.BULLET_REWIND, event)
			game._apply_pending_authority()
		"start_and_resume_same_batch":
			game._on_state(frame)
			game._on_event(1, NetEvent.Kind.BULLET_REWIND, event)
			game._on_event(1, NetEvent.Kind.BULLET_REWIND, event.merged({"tick": 101, "rewind": false}, true))
			game._apply_pending_authority()
		_:
			_state(frame)
			before = _sample(owner, id)
			game._on_event(1, NetEvent.Kind.BULLET_REWIND, event)
	var row := {"owner": owner, "order": order, "before_event": before, "after_dispatch": _sample(owner, id)}
	_tick_without_state()
	row["after_next_prediction_tick"] = _sample(owner, id)
	_state(_snapshot(104, owner, 2, {id: _projectile(3040)}))
	row["after_next_state"] = _sample(owner, id)
	assert(game._own_tick == 104)
	assert(not row["after_dispatch"]["owner_rewinding"])
	assert(row["after_dispatch"]["prediction_present"] and row["after_dispatch"]["prediction_active"],
			"an older rewind must not erase or deactivate applied authority projectiles")
	assert(row["after_dispatch"]["visual_running"], "applied authority must retain resumed visual flight")
	assert(row["after_next_prediction_tick"]["prediction_active"])
	assert(row["after_next_state"]["prediction_active"] and row["after_next_state"]["visual_running"])
	if not before.is_empty():
		assert(before == row["after_dispatch"], "a covered event must leave the current simulation and visuals unchanged")
	game._on_event(1, NetEvent.Kind.BULLET_REWIND, event.merged({"tick": 101, "rewind": false}, true))
	row["after_reliable_resume"] = _sample(owner, id)
	assert(row["after_reliable_resume"] == row["after_next_state"], "a covered resume must not reseed inactive projectiles")
	rows.append(row)
	print("REWIND ORDER ", JSON.stringify(row))

func _cursor_input(cursor: Array) -> Dictionary:
	return InputBuffer.neutral().merged({"epoch": cursor[0], "seq": cursor[3], "target_tick": cursor[4],
			"view_tick": cursor[5], "ax": cursor[6], "held": cursor[7], "aim": cursor[8]}, true)

func _check_matching_confirmation(owner: int) -> void:
	var id := (owner << 48) | OWNER_ID
	_state(_snapshot(102, owner, 2, {id: _projectile(3020)}))
	var before := _sample(owner, id)
	var applications: int = game._authority_applications
	var confirmation := {"role": owner, "tick": 102, "rewind": false, "projectiles": {id: _projectile(3020)}}
	game._on_event(1, NetEvent.Kind.BULLET_REWIND, confirmation)
	game._on_event(1, NetEvent.Kind.BULLET_REWIND, confirmation)
	game._apply_pending_authority()
	assert(_sample(owner, id) == before and game._authority_applications == applications,
			"matching or duplicate rewind metadata must not cancel projectiles or replay the world")
	rows.append({"owner": owner, "order": "matching_and_duplicate_confirmation", "after": before})

func _check_reuse() -> void:
	var id := (2 << 48) | OWNER_ID
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, _projectile(2990).merged({"id": id, "tick": 99}))
	game._bullets[id].collision_mask = 0
	_state(_snapshot(102, 2, 2, {id: _projectile(3020)}))
	var tick := game._rollback._sim_tick
	var saved: Dictionary = game._rollback.checkpoint_state(tick)
	var fresh := _snapshot(tick, 2, 2, saved["projectiles"])
	fresh["own"]["state"] = saved["players"][1].duplicate(true)
	var cursor: Array = saved["cursors"][1]
	fresh["own"]["epoch"] = cursor[0]
	fresh["own"]["ack"] = cursor[1]
	fresh["own"]["action_ack"] = cursor[2]
	fresh["own"]["input"] = _cursor_input(cursor)
	assert(not saved["cursors"].has(2), "read-only remote proxies have no replay input cursor")
	var remote := _actor_from_player(game._replicas[2]._forecast, InputBuffer.neutral())
	fresh["world"]["players"][2] = remote
	assert(game._rollback.reusable_tick(fresh) >= 0, "control snapshot must match actual prediction history")
	game._on_event(1, NetEvent.Kind.BULLET_REWIND,
			{"role": 2, "tick": 100, "rewind": true, "projectiles": {id: _projectile(3000)}})
	var before := _sample(2, id)
	_state(fresh)
	var after := _sample(2, id)
	assert(game._rollback.reuse_detail["reason"] == "full")
	assert(before["prediction_instance"] == after["prediction_instance"])
	assert(before["prediction_present"] and before["prediction_active"])
	assert(after["prediction_present"] and after["prediction_active"], "full history reuse must retain live prediction projectiles")
	var row := {"order": "late_event_then_matching_state_reuse", "before_state": before, "after_state": after}
	game._on_event(1, NetEvent.Kind.BULLET_REWIND,
			{"role": 2, "tick": 101, "rewind": false, "projectiles": {id: _projectile(3000)}})
	row["after_reliable_resume"] = _sample(2, id)
	_state(_snapshot(106, 2, 2, {id: _projectile(3060)}))
	row["after_resume_and_fresh_state"] = _sample(2, id)
	assert(row["after_reliable_resume"]["visual_running"])
	assert(row["after_resume_and_fresh_state"]["prediction_active"])
	rows.append(row)
	print("REWIND REUSE ", JSON.stringify(row))

func _rewinding_frame(tick: int, owner: int, epoch: int, id: int) -> Dictionary:
	var frame := _snapshot(tick, owner, epoch, {id: _projectile(3000 + (tick - 100) * 10)})
	frame["world"]["players"][owner]["rewind"] = true
	if owner == PvpSession.role: frame["own"]["rewind"] = true
	return frame

func _check_anchor_boundary(owner: int) -> void:
	var id := (owner << 48) | OWNER_ID
	_state(_snapshot(102, owner, 2, {id: _projectile(3020)}))
	game._on_event(1, NetEvent.Kind.BULLET_REWIND,
			{"role": owner, "tick": 102, "rewind": true, "projectiles": {id: _projectile(3000)}})
	assert(not game._bullets[id].is_physics_processing(), "an event anchored at the applied tick is still new")
	_state(_rewinding_frame(104, owner, 2, id))
	game._on_event(1, NetEvent.Kind.BULLET_REWIND,
			{"role": owner, "tick": 106, "rewind": false, "projectiles": {id: _projectile(3010)}})
	_state(_rewinding_frame(106, owner, 2, id))
	assert(game._bullets[id].is_physics_processing() and game._bullets[id].position.x == 3010,
			"an earlier STATE must not undo a newer resume event")
	_state(_snapshot(108, owner, 3, {id: _projectile(3080)}))
	var before := _sample(owner, id)
	game._on_event(1, NetEvent.Kind.BULLET_REWIND,
			{"role": owner, "tick": 106, "rewind": false, "projectiles": {id: _projectile(3010)}})
	assert(_sample(owner, id) == before)
	rows.append({"owner": owner, "order": "anchor_equality_and_newer_event", "after": before})

func _check_snapshot_only(owner: int) -> void:
	var id := (owner << 48) | OWNER_ID
	_state(_rewinding_frame(102, owner, 1, id))
	assert(game._bullets.has(id) and not game._bullets[id].is_physics_processing())
	_state(_snapshot(104, owner, 2, {id: _projectile(3040)}))
	assert(game._bullets[id].is_physics_processing() and game._bullets[id].position.x == 3040,
			"STATE must resume visual flight without waiting for the reliable resume event")
	var before := _sample(owner, id)
	for rewind in [true, false]:
		game._on_event(1, NetEvent.Kind.BULLET_REWIND,
				{"role": owner, "tick": 100, "rewind": rewind, "projectiles": {id: _projectile(3000)}})
		assert(_sample(owner, id) == before)
	game._clear_dynamics()
	assert(game._bullet_rewind_visuals.is_empty(), "baseline and scene resets must clear visual timestamps")
	rows.append({"owner": owner, "order": "state_only_start_resume_and_reset", "after": before})

func _check_retired(owner: int) -> void:
	var id := (owner << 48) | OWNER_ID
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, _projectile(2990).merged({"id": id, "tick": 99}))
	game._bullets[id].free()
	_state(_snapshot(102, owner, 2, {}))
	game._on_event(1, NetEvent.Kind.BULLET_REWIND,
			{"role": owner, "tick": 100, "rewind": false, "projectiles": {id: _projectile(3000)}})
	assert(not game._bullets.has(id) and not game._rollback.combat_prediction.snapshot_projectiles().has(id),
			"a covered event must not resurrect a retired visual or prediction projectile")
	rows.append({"owner": owner, "order": "covered_event_cannot_resurrect", "after": _sample(owner, id)})

func _check_queued_visual(owner: int) -> void:
	var id := (owner << 48) | OWNER_ID
	game._on_event(1, NetEvent.Kind.BULLET_SPAWN, _projectile(2990).merged({"id": id, "tick": 99}))
	var old: BulletBase = game._bullets[id]
	game._on_event(1, NetEvent.Kind.BULLET_REWIND,
			{"role": owner, "tick": 100, "rewind": true, "projectiles": {}})
	assert(old.is_queued_for_deletion())
	_state(_snapshot(102, owner, 2, {id: _projectile(3020)}))
	assert(game._bullets[id] != old and not game._bullets[id].is_queued_for_deletion()
			and game._bullets[id].is_physics_processing(), "new authority must replace queued visuals with live instances")
	rows.append({"owner": owner, "order": "authority_replaces_queued_visual", "after": _sample(owner, id)})

func _check_resume_detonation(owner: int) -> void:
	var id := (owner << 48) | OWNER_ID
	game._rollback.combat_prediction.detonated.connect(game._present_explosion.bind(true))
	var grenade := _projectile(3000).merged({"type_id": 5, "fuse_active": true,
			"fuse_elapsed": 0.0, "fuse_duration": 0.05}, true)
	var frozen := _rewinding_frame(102, owner, 1, id)
	frozen["world"]["projectiles"][id] = grenade
	_state(frozen)
	var resumed := _snapshot(104, owner, 2, {id: grenade})
	game._rollback._clock = 106.0
	_state(resumed)
	game._rollback.advance(ActorStep.DT)
	assert(game._explosions_shown.has(id), "resumed prediction must retain its detonation feedback")
	assert(not game._bullets.has(id) or game._bullets[id].is_queued_for_deletion(),
			"a grenade detonated immediately after resuming must stay removed from the visuals")
	rows.append({"owner": owner, "order": "resume_detonation_not_resurrected", "after": _sample(owner, id)})
