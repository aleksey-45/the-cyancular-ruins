class_name PredictionWorld
extends RefCounted

# 唯一整数时钟与角色推进入口。显示副本不持有这里的物理体。
var tick := 0
var local: Player
var terrain: Terrain
var time_economy: TimeEconomy
var combat := CombatPrediction.new()
var history := PredictionHistory.new()
var actors: Dictionary = {}
var roles: Array = []
var _players: Array = []
var _slots: Dictionary = {}
var _controls: Dictionary = {}
var _rewind_paths: Dictionary = {}
var _local_respawn := 0
var _rewind_events: Dictionary = {}

func bind(player: Player) -> void:
	local = player
	_slots[player.role] = player
	_rewind_paths[player.role] = []
	_set_roster([])
	combat.bind(player)
	combat.actors = actors

func actor(role: int) -> ActorBody:
	return _slots[role]

# 槽和 RID 的生命周期属于对局；离场只撤下碰撞，历史仍可恢复同一个槽。
func ensure_actor(role: int, team: int) -> void:
	if not _slots.has(role):
		var body: ActorBody = preload("res://core/sim/actor_body.tscn").instantiate()
		body.name = "PredictedActor%d" % role
		body.role = role
		body.process_mode = Node.PROCESS_MODE_DISABLED
		body.collision_layer = 0
		local.get_parent().add_child(body)
		_slots[role] = body
	var body := actor(role)
	body.team = team
	body.collision_mask = CollisionWorld.LAYER_TERRAIN | CollisionWorld.team_layer(3 - team)
	body._apply_layers()

func _set_roster(remotes: Array) -> void:
	for body: ActorBody in actors.values():
		if body != local:
			body.collision_layer = 0
			body._apply_layers()
	actors.clear()
	actors[local.role] = local
	for role in remotes:
		actors[role] = actor(role)
	roles = actors.keys()
	roles.sort()
	_players.clear()
	for role in roles:
		_players.append(actors[role])

func capture(cursor: Array) -> PredictionFrame:
	var saved := PredictionFrame.new()
	saved.tick = tick
	saved.player = local.capture_state()
	saved.cursor = cursor
	for role in roles:
		var body := actor(role)
		saved.layers[role] = body.collision_layer
		if body != local:
			saved.remote[role] = PredictionActorState.capture(body, _controls[role])
	saved.rewinding = local.rewinding
	saved.respawn_tick = _local_respawn
	saved.projectiles = ProjectileSnapshot.capture(combat.projectiles)
	if time_economy != null:
		saved.time[local.role] = time_economy.account_payload(local.role)
	saved.terrain_generation = terrain.generation
	return saved

func restore(saved: PredictionFrame) -> void:
	terrain.restore_checkpoint(saved.tick)
	_set_roster(saved.remote.keys())
	local.restore_state(saved.player)
	local.rewinding = saved.rewinding
	_local_respawn = saved.respawn_tick
	_controls = saved.remote.duplicate()
	for role in saved.remote:
		PredictionActorState.restore(actor(role), saved.remote[role])
	for role in roles:
		actor(role).collision_layer = saved.layers[role]
		actor(role)._apply_layers()
	if time_economy != null:
		time_economy.restore_account(local.role, saved.time[local.role])
	combat.restore_checkpoint(saved.tick, saved.projectiles)
	tick = saved.tick

func restore_authority(frame: Dictionary) -> void:
	var records: Dictionary = frame["world"]["players"]
	var remotes := records.keys()
	remotes.erase(local.role)
	_set_roster(remotes)
	local.restore_state(frame["own"]["state"])
	local.rewinding = frame["own"]["rewind"]
	accept_rewind_paths(frame)
	_local_respawn = records[local.role][PlayerStateSchema.slot("respawn_tick")]
	_controls.clear()
	for role in remotes:
		var state := PredictionActorState.project(records[role])
		_controls[role] = state
		PredictionActorState.restore(actor(role), state)
	for role in roles:
		actor(role).collision_layer = CollisionWorld.team_layer(actor(role).team)
		actor(role)._apply_layers()
	if time_economy != null:
		time_economy.restore_account(local.role, frame["time"][local.role])
	combat.time_economy = time_economy
	combat.prepare(frame["tick"], frame["world"]["projectiles"])
	tick = frame["tick"]
	acknowledge(tick)

func difference(saved: PredictionFrame, frame: Dictionary) -> String:
	var records: Dictionary = frame["world"]["players"]
	if records.size() != saved.remote.size() + 1:
		return "roster"
	if saved.layers[local.role] != CollisionWorld.team_layer(local.team):
		return "layer"
	for role in records:
		if role == local.role:
			continue
		if not saved.remote.has(role):
			return "roster"
		var field := PredictionActorState.difference(saved.remote[role],
				PredictionActorState.project(records[role]))
		if not field.is_empty():
			return "remote_%s" % field
		if saved.layers[role] != CollisionWorld.team_layer(actor(role).team):
			return "layer"
	if saved.rewinding != frame["own"]["rewind"] \
			or saved.respawn_tick != records[local.role][PlayerStateSchema.slot("respawn_tick")]:
		return "local_control"
	for role in records:
		var path: Array = records[role][PlayerStateSchema.slot("rewind_path")]
		if _path_between(_rewind_paths[role], saved.tick, tick) != _path_between(path, saved.tick, tick):
			return "local_rewind_path" if role == local.role else "remote_rewind_path"
	return ""

# 路径是已接收的模拟指令；检查点恢复不撤销之后获知的未来安排。
func accept_rewind_paths(frame: Dictionary) -> void:
	_rewind_paths.clear()
	for role in frame["world"]["players"]:
		_rewind_paths[role] = frame["world"]["players"][role][PlayerStateSchema.slot("rewind_path")]

static func _path_between(path: Array, after: int, through: int) -> Array:
	return path.filter(func(knot: Array) -> bool: return after < knot[0] and knot[0] <= through)

func confirm_rewind(data: Dictionary) -> void:
	_rewind_events[Vector2i(data["tick"] + 1, data["role"])] = data

func acknowledge(at: int) -> void:
	for key: Vector2i in _rewind_events.keys():
		if key.x <= at:
			_rewind_events.erase(key)

func reset(at: int) -> void:
	tick = at
	history.frames.clear()
	acknowledge(at)

func clear() -> void:
	_set_roster([])
	_controls.clear()
	_rewind_paths.clear()
	_local_respawn = 0
	history.frames.clear()
	_rewind_events.clear()
	combat.clear()

func step_tick(record: Dictionary, replay: bool) -> Array:
	var at := tick + 1
	combat.tick = at
	combat.time_economy = time_economy
	var actions: Array = []
	for role in roles:
		var body := actor(role)
		if body == local:
			if time_economy != null:
				time_economy.step_haste(local, record, ActorStep.DT)
			actions = ActorStep.step(local, record)
			combat.shot_actions(local, actions, at)
		elif not body.rewinding:
			_step_remote(body, _controls[role])
		body.sync_collision_geometry()
		combat.step_beams(at, role, _players)
		combat.step_rewards(at, role)
	_step_beta(at)
	if time_economy != null:
		var account: GrainAccount = time_economy.accounts[local.role]
		if local.rewinding:
			account.spend(ActorStep.DT, time_economy.rules.rewind_burn)
		account.regen(ActorStep.DT)
	combat.step(at, _players, not replay)
	combat.step_rewards(at, 0)
	combat.step_rewards(at, -1)
	# 规则阶段到达复活时刻；新生位置未知，旧尸体退出碰撞直到下一 STATE。
	for role in roles:
		var respawn: int = _local_respawn if role == local.role else _controls[role][PredictionActorState.RESPAWN]
		if respawn > 0 and at >= respawn:
			actor(role).collision_layer = 0
			actor(role)._apply_layers()
	terrain.flush_collisions()
	tick = at
	return actions

func _step_remote(body: ActorBody, control: Array) -> void:
	var started := PerformanceStats.begin()
	var input := body.step_input
	input.raw_axis = control[PredictionActorState.AXIS]
	input.raw_held = control[PredictionActorState.HELD]
	input.axis = 0.0 if body._controls_locked else input.raw_axis
	input.held = 0 if body._controls_locked else input.raw_held
	input.vertical_axis = -1.0 if input.held & ActorInput.BIT_UP else (1.0 if input.held & ActorInput.BIT_DOWN else 0.0)
	input.pressed = 0
	input.released = 0
	input.weapon_inst = 0
	input.aim = Vector2.ZERO
	body.simulate_motion(ActorStep.DT, control[PredictionActorState.MULTIPLIER],
			body.pvp_haste_mult, true, Level0.pvp_mode, terrain)
	PerformanceStats.end(PerformanceStats.ACTOR_STEP, started)

func _step_beta(at: int) -> void:
	for role in roles:
		var body := actor(role)
		var key := Vector2i(at, role)
		if _rewind_events.has(key):
			var event: Dictionary = _rewind_events[key]
			body.rewinding = event["rewind"]
			for id in event["projectiles"]:
				combat.projectiles[id].restore_at(event["projectiles"][id], at - 1)
		if not body.rewinding:
			continue
		for knot: Array in _rewind_paths[role]:
			if knot[0] != at:
				continue
			var flags: int = knot[2]
			body.global_position = knot[1]
			body.facing_direction = -1 if flags & 4 else 1
			body.is_squat = bool(flags & 1)
			body.sim_downed = bool(flags & 2)
			body.rotation = -PI / 2.0 * body.facing_direction if body.sim_downed else 0.0
			body.sync_collision_geometry()
