class_name CombatSimulator
extends RefCounted

signal projectile_spawned(bullet: BulletBody)
signal projectile_ended(id: int)
signal beam_fired(id: int, shot: Dictionary, points: PackedVector2Array)
signal detonated(id: int, position: Vector2, radius: float)
signal tile_hit(position: Vector2, texture_id: int)
signal player_hit(source_role: int, victim: Player, damage: int, knock_changed: bool, force: float)
signal npc_hit(source: Node, victim: EnemyBase, damage: int)
signal projectile_hit_npc(type_id: int)
signal grain_dropped(position: Vector2, amount: int)

const BLAST_DELAY := 3
const ACTOR_LAYERS := CollisionWorld.LAYER_ENEMY | CollisionWorld.LAYER_TEAM_A | CollisionWorld.LAYER_TEAM_B

var terrain: Terrain
var time_field: TimeField
var tick := 0
var projectiles: Dictionary[int, BulletBody] = {}
var players: Dictionary
var team_counts: Dictionary
var _pending_blasts: Dictionary = {}
var _next_enemy_projectile := -1
var _parent: Node
var _pvp: bool

func _init(map: Terrain, parent: Node, pvp: bool = false) -> void:
	terrain = map
	_parent = parent
	_pvp = pvp

func submit(actor: Player, actions: Array) -> void:
	for action: Dictionary in actions:
		match action["kind"]:
			"fire": fire(actor, action)
			"drown":
				resolve_hit(null, actor, CombatProfiles.DROWN, action["pos"], action["damage"], 0.0)

func fire(actor: Player, shot: Dictionary) -> void:
	var spec := WeaponRegistry.definition(shot["type_id"])
	match spec["attack"]:
		WeaponRegistry.Attack.PROJECTILE: ShotRules.projectiles(self, actor, shot, spec)
		WeaponRegistry.Attack.BEAM: ShotRules.beam(self, actor, shot, spec)
		WeaponRegistry.Attack.MELEE: ShotRules.melee(self, actor, shot, spec)

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
	bullet.set_physics_process(not _pvp)
	projectiles[id] = bullet
	projectile_spawned.emit(bullet)
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
	bullet.set_physics_process(false)
	bullet.queue_free()

func clear() -> void:
	for id: int in projectiles.keys():
		erase_projectile(id)
	clear_blasts()

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
	ShotRules.step_projectile(self, bullet, delta, _pvp)

func submit_blast(id: int, pos: Vector2, spec: Dictionary, source: Node) -> void:
	detonated.emit(id, pos, spec["radius"])
	if _pvp:
		assert(not _pending_blasts.has(id))
		_pending_blasts[id] = {"due": tick + BLAST_DELAY, "pos": pos, "spec": spec, "role": source_role(source)}
	else:
		resolve_blast(pos, spec, source)

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
		resolve_blast(blast["pos"], blast["spec"], players.get(blast["role"]))

func resolve_blast(center: Vector2, spec: Dictionary, source: Node) -> void:
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
	terrain.damage_blast(center, radius, spec["damage"], source_role(source))

func _blast_targets(center: Vector2, radius: float) -> Array:
	var targets: Array = []
	if _pvp:
		var roles := players.keys()
		roles.sort()
		for role in roles:
			targets.append(players[role])
	else:
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
	if target is Player:
		if not (targets & _relation(source, target)) or target.sim_downed or target.rewinding:
			return false
		if time_field != null and time_field.is_rewinding():
			return false
		if not _pvp and target.sim_iframes > 0.0 and not profile["ignore_iframes"]:
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

static func _relation(source: Node, target: Player) -> int:
	if source == target:
		return CombatProfiles.Target.SELF
	if source is Player and source.team != 0 and source.team == target.team:
		return CombatProfiles.Target.ALLY
	return CombatProfiles.Target.OPPONENT

static func source_role(source: Node) -> int:
	return source.role if source is Player else 0

func _delta(from: Vector2, to: Vector2) -> Vector2:
	var size := terrain.map_size
	return GridPathfinder.toroidal_delta_px(from, to, size)

func hit_direction(from: Vector2, to: Vector2) -> Vector2:
	var delta := _delta(from, to)
	return delta.normalized() if delta.length_squared() > 1.0 else Vector2.RIGHT
