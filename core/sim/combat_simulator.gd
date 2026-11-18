class_name CombatSimulator
extends RefCounted

signal projectile_ended(id: int)
signal fired(shot: Dictionary)
signal detonated(id: int, position: Vector2, type_id: int, cells: PackedInt32Array)
signal tile_hit(position: Vector2, texture_id: int)
signal player_hit(source_role: int, victim: Player, damage: int, knock_changed: bool, force: float)
signal npc_hit(source: Node, victim: EnemyBase, damage: int)
signal projectile_hit_npc(type_id: int)
signal grain_dropped(position: Vector2)

const BLAST_DELAY := 3
const ACTOR_LAYERS := CollisionWorld.LAYER_ENEMY | CollisionWorld.LAYER_TEAM_A | CollisionWorld.LAYER_TEAM_B

var terrain: Terrain
var time_field: TimeField
var tick := 0
var projectiles: Dictionary[int, BulletBody] = {}
var players: Dictionary
var team_counts: Dictionary
var predicting := false
var predicted_hits: Array = []
var blast_target_query: Callable
var _pending_blasts: Dictionary = {}
var _next_enemy_projectile := -1
var _parent: Node
var _multiplayer_rules: bool

func _init(map: Terrain, parent: Node, multiplayer_rules := false) -> void:
	terrain = map
	_parent = parent
	_multiplayer_rules = multiplayer_rules

func drop_grain(at: Vector2, amount: int) -> void:
	time_field.schedule_grain(amount)
	grain_dropped.emit(at)

func add_simulated_player(role: int, team: int, player_collision: bool, enabled_weapons: Array) -> Player:
	var actor: Player = load("res://scenes/player/player_body.tscn").instantiate()
	actor.role = role
	actor.set_team_collision(team, player_collision)
	actor.process_mode = Node.PROCESS_MODE_DISABLED
	actor.projectile_count = count_projectiles.bind(actor)
	_parent.add_child(actor)
	actor.weapons.enabled_types = enabled_weapons
	players[role] = actor
	return actor

func submit(actor: Player, requests: Array) -> void:
	for request: Dictionary in requests:
		match request["kind"]:
			"fire": fire(actor, request)
			"drown":
				resolve_hit(null, actor, CombatProfiles.DROWN, request["pos"], request["damage"], 0.0)

func fire(actor: ActorBody, action: Dictionary) -> Dictionary:
	var spec := WeaponRegistry.definition(action["type_id"])
	var shot := action
	if not shot.has("vectors"):
		shot = action.merged({"role": actor.role, "tick": tick}, true)
		ShotRules.prepare(terrain, shot, spec)
	if not predicting:
		fired.emit(shot)
	if spec["attack"] == WeaponRegistry.Attack.PROJECTILE:
		ShotRules.projectiles(self, actor, shot, spec)
	else:
		ShotRules.hitscan(self, actor, shot, spec)
	return shot

func spawn_enemy_projectile(type_id: int, enemy: EnemyBase, velocity: Vector2) -> void:
	var id := _next_enemy_projectile
	_next_enemy_projectile -= 1
	spawn_projectile(id, type_id, enemy.get_instance_id(), enemy.global_position, velocity)

func spawn_projectile(id: int, type_id: int, source: int, pos: Vector2, vel: Vector2,
		damage_override: int = -1) -> BulletBody:
	assert(not projectiles.has(id))
	var bullet := BulletBody.new()
	var spec := WeaponRegistry.projectile_definition(type_id)
	var damage: int = spec["damage"] if damage_override == -1 else damage_override
	bullet.configure(self, id, type_id, spec["projectile"],
			source, pos, vel,
			spec["size"], spec["gravity"], spec["range"], damage, spec["impact"])
	_parent.add_child(bullet)
	projectiles[id] = bullet
	return bullet

func count_projectiles(type_id: int, owner: Player) -> int:
	var count := 0
	for bullet: BulletBody in projectiles.values():
		if bullet.type_id == type_id and bullet.shooter == owner:
			count += 1
	return count

func erase_projectile(id: int) -> void:
	var bullet := projectiles[id]
	projectiles.erase(id)
	bullet.queue_free()

func clear() -> void:
	for id: int in projectiles.keys():
		erase_projectile(id)
	clear_blasts()

func capture_projectiles(include_pending_blasts := false) -> Dictionary:
	var states := _pending_blasts.duplicate() if include_pending_blasts else {}
	for bullet: BulletBody in projectiles.values():
		states[bullet.entity_id] = bullet.capture_state()
	return states

func restore_prediction_projectiles(states: Dictionary) -> void:
	_pending_blasts.clear()
	for id: int in projectiles.keys():
		var state: Variant = states.get(id)
		if not state is Array or state[BulletBody.SNAP_TYPE] != projectiles[id].type_id:
			erase_projectile(id)
	for id: int in states:
		var state: Variant = states[id]
		if state is Dictionary:
			_pending_blasts[id] = state
			continue
		var owner: ActorBody = players.get(id >> 48)
		if owner == null:
			continue
		var bullet := _restore_projectile(id, state, owner.get_instance_id())
		bullet.launch = state[BulletBody.SNAP_LAUNCH]
		bullet.hit_damage = state[BulletBody.SNAP_DAMAGE]
		bullet.direct_hit = state[BulletBody.SNAP_DIRECT_HIT]

func rewind_projectiles(states: Dictionary) -> void:
	for id: int in states:
		var state: Array = states[id]
		_restore_projectile(id, state, state[BulletBody.SNAP_SOURCE])
	for id: int in projectiles.keys():
		if not states.has(id):
			erase_projectile(id)
	# 所有弹丸归位后，每枚倒飞弹丸仍可命中同一精英一次。
	var space := CollisionWorld.for_space(terrain.space_rid())
	for bullet: BulletBody in projectiles.values():
		var source := bullet.shooter
		if not source is Player:
			continue
		for entry: Dictionary in space.shape_overlaps(bullet.shape, bullet.global_transform, CollisionWorld.LAYER_ENEMY):
			var elite := entry["collider"] as EnemyBase
			if elite == null or not elite.has_meta("elite") or elite.is_dead:
				continue
			var id := elite.get_instance_id()
			if bullet.rewind_hits.has(id):
				continue
			bullet.rewind_hits[id] = true
			resolve_hit(source, elite, CombatProfiles.DIRECT, bullet.global_position, bullet.hit_damage,
					bullet.hit_impact, hit_direction(bullet.global_position, elite.global_position))

func _restore_projectile(id: int, state: Array, source: int) -> BulletBody:
	var bullet: BulletBody = projectiles.get(id)
	var start := BulletBody.SNAP_MOTION
	if bullet == null:
		bullet = spawn_projectile(id, state[BulletBody.SNAP_TYPE], source, state[start + BulletBody.MOTION_POS],
				state[start + BulletBody.MOTION_VEL], state[BulletBody.SNAP_DAMAGE])
	bullet.restore_motion(state, start)
	return bullet

func catch_up_shot(shot: Dictionary, live: Dictionary, at: int) -> void:
	var owner: ActorBody = players.get(shot["role"])
	var spec := WeaponRegistry.definition(shot["type_id"])
	if owner == null or spec["attack"] != WeaponRegistry.Attack.PROJECTILE:
		return
	var id := ShotRules.shot_id(owner.role, shot["serial"])
	var ids: Array[int] = []
	var velocities: PackedVector2Array = shot["vectors"]
	for pellet in velocities.size():
		var key := id | pellet
		var existing: BulletBody = projectiles.get(key)
		if live.has(key) and live[key]["type_id"] == shot["type_id"] and (existing == null or existing.launch != shot):
			if existing != null:
				erase_projectile(key)
			ids.append(key)
	if ids.is_empty():
		return
	ShotRules.projectiles(self, owner, shot, spec, ids)
	for key: int in ids:
		var bullet := projectiles[key]
		for launch_tick in range(shot["tick"], at + 1):
			tick = launch_tick
			step_projectile(bullet, ActorStep.DT)
			if not projectiles.has(key):
				break
		_pending_blasts.erase(key)
		if projectiles.has(key):
			bullet.restore_pose(live[key]["pos"], live[key]["vel"])
	tick = at

func clear_blasts() -> void:
	_pending_blasts.clear()

func step_projectiles(delta: float) -> void:
	var started := PerformanceStats.begin()
	var ids := projectiles.keys()
	ids.sort()
	for id: int in ids:
		var bullet := projectiles[id]
		if not (bullet.shooter is ActorBody and bullet.shooter.rewinding):
			step_projectile(bullet, delta)
	PerformanceStats.end(PerformanceStats.COMBAT_STEP, started)

func step_projectile(bullet: BulletBody, delta: float) -> void:
	if time_field != null:
		if time_field.is_rewinding():
			return
		delta = delta * time_field.player_speed_mult() if bullet.shooter is Player else time_field.world_delta(delta)
	ShotRules.step_projectile(self, bullet, delta, _multiplayer_rules)

static func blast_state(type_id: int, pos: Vector2, at: int) -> Dictionary:
	return {"type_id": type_id, "pos": pos, "due": at + BLAST_DELAY}

func submit_blast(id: int, pos: Vector2, type_id: int, source: Node) -> void:
	if _multiplayer_rules:
		if not predicting:
			detonated.emit(id, pos, type_id, PackedInt32Array())
		assert(not _pending_blasts.has(id))
		_pending_blasts[id] = blast_state(type_id, pos, tick)
	else:
		var spec := WeaponRegistry.blast_definition(type_id)
		var cells := terrain.blast_cells(pos, spec["radius"])
		detonated.emit(id, pos, type_id, PackedInt32Array(cells.keys()))
		resolve_blast(pos, spec, source, cells)

func apply_projectile_ends(ends: Dictionary) -> void:
	for id: int in ends:
		var end: Dictionary = ends[id]
		if tick > end["tick"]:
			continue
		_pending_blasts.erase(id)
		if tick == end["tick"]:
			if projectiles.has(id):
				erase_projectile(id)
			if not end["blast"].is_empty():
				_pending_blasts[id] = end["blast"]

func settle_blasts() -> void:
	var ready: Array[int] = []
	for id: int in _pending_blasts:
		if _pending_blasts[id]["due"] <= tick:
			ready.append(id)
	ready.sort_custom(func(a: int, b: int) -> bool:
		var ta: int = _pending_blasts[a]["due"]
		var tb: int = _pending_blasts[b]["due"]
		return a < b if ta == tb else ta < tb)
	for id: int in ready:
		var blast: Dictionary = _pending_blasts[id]
		_pending_blasts.erase(id)
		resolve_blast(blast["pos"], WeaponRegistry.blast_definition(blast["type_id"]), players.get(id >> 48))

func resolve_blast(center: Vector2, spec: Dictionary, source: Node, cells = null) -> void:
	var radius: float = spec["radius"]
	for target: Node2D in _blast_targets(center, radius):
		var distance := _delta(center, target.global_position).length()
		if distance > radius:
			continue
		var blocked := not terrain.line_of_sight(center, target.global_position)
		var cover := BlastCurve.cover_multiplier(distance, radius, blocked)
		var inner := radius * BlastCurve.INNER_FRACTION
		resolve_hit(source, target, CombatProfiles.BLAST, center,
				BlastCurve.falloff(distance, radius, inner, spec["damage"]) * cover,
				BlastCurve.falloff(distance, radius, inner, spec["impact"]) * cover,
				hit_direction(center, target.global_position))
	if not predicting:
		terrain.damage_blast(cells if cells != null else terrain.blast_cells(center, radius),
				radius, spec["damage"], source_role(source))

static func roster_blast_targets(_center: Vector2, _radius: float, roster: Dictionary) -> Array:
	var roles := roster.keys()
	roles.sort()
	var targets: Array = []
	for role in roles: targets.append(roster[role])
	return targets

func _blast_targets(center: Vector2, radius: float) -> Array:
	if blast_target_query.is_valid():
		return blast_target_query.call(center, radius)
	var targets: Array = []
	var seen := {}
	var space := CollisionWorld.for_space(terrain.space_rid())
	for at in space.toroidal_centers(center, radius):
		for entry: Dictionary in space.circle_overlaps(at, radius, ACTOR_LAYERS):
			var target: Node2D = entry["collider"]
			if target != null and not seen.has(target.get_instance_id()):
				seen[target.get_instance_id()] = true
				targets.append(target)
	return targets

func resolve_hit(source: Node, target: Node2D, profile: Dictionary, at: Vector2,
		damage: float, force: float, direction := Vector2.ZERO) -> bool:
	var targets: int = profile["targets"]
	if target is ActorBody:
		if not (targets & _relation(source, target)) or target.sim_downed or target.rewinding:
			return false
		if time_field != null and time_field.is_rewinding():
			return false
		if not _multiplayer_rules and target.sim_iframes > 0.0 and not profile["ignore_iframes"]:
			return false
	elif target is EnemyBase:
		if not (targets & CombatProfiles.Target.NPC):
			return false
	else:
		return false

	match profile["water"]:
		CombatProfiles.Water.BLAST:
			var mult := terrain.water_multiplier(target.global_position)
			damage *= mult
			force *= mult
		CombatProfiles.Water.WET:
			if terrain.water(target.global_position):
				damage = roundi(damage * CombatProfiles.FLY_BIRD_WET_MULT)
	if predicting:
		if force != 0.0 and target is ActorBody:
			predicted_hits.append([target, at, force])
		return true

	var amount := int(damage)
	if target is EnemyBase:
		if profile["water"] == CombatProfiles.Water.BLAST and damage <= 0.0:
			return false
		var enemy := target as EnemyBase
		var enemy_hp := enemy.hp
		var mode: int = profile["npc_impulse"]
		enemy.hurt(amount, direction, 0.0 if mode == CombatProfiles.NpcImpulse.DEFAULT else force,
				mode == CombatProfiles.NpcImpulse.SET)
		npc_hit.emit(source, enemy, enemy_hp - enemy.hp)
		return true

	var victim := target as Player
	if not team_counts.is_empty() and source is Player and source != victim:
		amount = roundi(amount * TeamRules.damage_factor(source.team, victim.team, team_counts))
	var before := victim.sim_hp
	var knock := victim.motion_knock_velocity
	victim.simulate_hit(at, amount, force)
	player_hit.emit(source_role(source), victim, before - victim.sim_hp, knock != victim.motion_knock_velocity, force)
	return true

static func _relation(source: Node, target: ActorBody) -> int:
	if source == target:
		return CombatProfiles.Target.SELF
	if source is ActorBody and source.team != 0 and source.team == target.team:
		return CombatProfiles.Target.ALLY
	return CombatProfiles.Target.OPPONENT

static func source_role(source: Node) -> int:
	return source.role if source is ActorBody else 0

func _delta(from: Vector2, to: Vector2) -> Vector2:
	var size := terrain.map_size
	return GridPathfinder.toroidal_delta_px(from, to, size)

func hit_direction(from: Vector2, to: Vector2) -> Vector2:
	var delta := _delta(from, to)
	return delta.normalized() if delta.length_squared() > 1.0 else Vector2.RIGHT
