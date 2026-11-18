class_name CombatSimulator
extends RefCounted

enum Blast { TYPE, POS, DUE }
enum Beam { END_TICK, POINTS }
enum ProjectileEnd { TICK, BLAST }

signal projectile_ended(id: int)
signal fired(shot: Dictionary)
signal detonated(id: int, position: Vector2, type_id: int)
signal tile_hit(position: Vector2, texture_id: int)
signal player_hit(source_role: int, victim: Player, damage: int, knock_changed: bool, force: float)
signal npc_hit(source: ActorBody, victim: EnemyBase, damage: int)
signal projectile_hit_npc(type_id: int)
signal grain_dropped(position: Vector2)

const BLAST_DELAY := 3
const BEAM_TICKS := 15
const ACTOR_LAYERS := CollisionWorld.LAYER_ENEMY | CollisionWorld.LAYER_TEAM_A | CollisionWorld.LAYER_TEAM_B

var terrain: Terrain
var ground: GroundWeaponField
var time_field: TimeField
var tick := 0
var projectiles: Dictionary[int, BulletBody] = {}
var beams: Dictionary[int, Array] = {}
var enemies: Array[EnemyBase] = []
var players: Dictionary[int, Player] = {}
var team_counts: Dictionary
var predicting := false
var predicted_hits: Array = []
var pending_blasts: Dictionary[int, Array] = {}
var _next_enemy_projectile := -1

func _init(map: Terrain) -> void:
	terrain = map
	ground = GroundWeaponField.new(map)

func drop_grain(at: Vector2, amount: int) -> void:
	if time_field != null:
		time_field.schedule_grain(amount)
		grain_dropped.emit(at)

func add_player(role: int, team := 0, player_collision := false) -> Player:
	var player := Player.new(self, role)
	player.set_team_collision(team, player_collision)
	players[role] = player
	return player

func remove_player(role: int) -> void:
	for bullet: BulletBody in projectiles.values():
		if bullet.shooter == players[role]:
			erase_projectile(bullet.entity_id)
	players[role].release()
	players.erase(role)

func add_enemy(type_id: String, player: Player, at: Vector2) -> EnemyBase:
	var kind: EnemyType = load(EnemyType.paths[type_id])
	var enemy: EnemyBase = kind.ai.new(self, player, at, kind)
	enemies.append(enemy)
	return enemy

func clear_enemies() -> void:
	for enemy in enemies:
		enemy.release()
	enemies.clear()

func close() -> void:
	clear()
	ground.clear()
	clear_enemies()
	for role: int in players.keys():
		remove_player(role)

## 输入按角色 ID 处理。角色全部移动后才发射，当帧生成的弹丸参加本帧的运动。
func step(inputs: Dictionary, confirmed_shots: Dictionary = {}, projectile_ends: Dictionary = {}) -> Dictionary:
	var reversing := time_field != null and time_field.is_rewinding()
	if not reversing:
		tick += 1
		for id: int in beams.keys():
			if beams[id][Beam.END_TICK] <= tick:
				beams.erase(id)
		ground.step(time_field.world_delta(ActorStep.DT) if time_field != null else ActorStep.DT)
	var roles := inputs.keys()
	roles.sort()
	for role: int in roles:
		ActorStep.step(players[role], inputs[role])

	predicted_hits.clear()
	var shots := resolve_requests(roles, confirmed_shots)
	for enemy in enemies:
		if enemy.active:
			enemy.simulate_tick(ActorStep.DT)
	if not reversing:
		apply_projectile_ends(projectile_ends)
		step_projectiles(ActorStep.DT)
		settle_blasts()
	terrain.flush_collisions()
	return shots

func resolve_requests(roles: Array, confirmed_shots: Dictionary = {}) -> Dictionary:
	var shots := {}
	for role: int in roles:
		var actor := players[role]
		for request: Dictionary in actor.combat_requests:
			match request["kind"]:
				"fire": shots[ShotRules.shot_id(role, request["serial"])] = request
				"drown": resolve_hit(null, actor, CombatProfiles.DROWN, request["pos"], request["damage"], 0.0)
	for id: int in confirmed_shots:
		var shot: Dictionary = confirmed_shots[id]
		if shot["tick"] == tick:
			shots[id] = shot
		else:
			shots.erase(id)
	var ids := shots.keys()
	ids.sort()
	for id: int in ids:
		var actor: Player = players.get(ShotRules.shooter_role(id))
		if actor != null:
			actor.shot_serial = maxi(actor.shot_serial, shots[id]["serial"])
			shots[id] = fire(actor, shots[id])
	return shots

func fire(actor: Player, action: Dictionary) -> Dictionary:
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
		if spec["attack"] == WeaponRegistry.Attack.BEAM:
			beams[ShotRules.shot_id(actor.role, shot["serial"])] = [tick + BEAM_TICKS, shot["vectors"]]
		ShotRules.hitscan(self, actor, shot, spec)
	return shot

func spawn_enemy_projectile(type_id: int, enemy: EnemyBase, velocity: Vector2) -> void:
	var id := _next_enemy_projectile
	_next_enemy_projectile -= 1
	spawn_projectile(id, type_id, enemy, enemy.position, velocity)

func spawn_projectile(id: int, type_id: int, source: ActorBody, pos: Vector2, vel: Vector2,
		damage_override: int = -1) -> BulletBody:
	assert(not projectiles.has(id))
	var bullet := BulletBody.new(terrain, id, type_id, source, pos, vel, damage_override)
	projectiles[id] = bullet
	return bullet

func count_projectiles(type_id: int, owner: Player) -> int:
	var count := 0
	for bullet: BulletBody in projectiles.values():
		if bullet.type_id == type_id and bullet.shooter == owner:
			count += 1
	return count

func erase_projectile(id: int) -> void:
	projectiles[id].release()
	projectiles.erase(id)

func clear() -> void:
	for id: int in projectiles.keys():
		erase_projectile(id)
	beams.clear()
	clear_blasts()

func catch_up_shot(shot: Dictionary, live: Dictionary, at: int) -> void:
	var owner: Player = players.get(shot["role"])
	var spec := WeaponRegistry.definition(shot["type_id"])
	if owner == null or spec["attack"] != WeaponRegistry.Attack.PROJECTILE:
		return
	var id := ShotRules.shot_id(owner.role, shot["serial"])
	var ids: Array[int] = []
	var velocities: PackedVector2Array = shot["vectors"]
	for pellet in velocities.size():
		var key := ShotRules.pellet_id(id, pellet)
		var existing: BulletBody = projectiles.get(key)
		if live.has(key) and live[key][BulletBody.Network.TYPE] == shot["type_id"] and (existing == null or existing.launch != shot):
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
		pending_blasts.erase(key)
		if projectiles.has(key):
			bullet.restore_pose(live[key][BulletBody.Network.POS], live[key][BulletBody.Network.VEL])
	tick = at

func clear_blasts() -> void:
	pending_blasts.clear()

func step_projectiles(delta: float) -> void:
	var started := PerformanceStats.begin()
	var ids := projectiles.keys()
	ids.sort()
	for id: int in ids:
		var bullet := projectiles[id]
		if not (bullet.shooter is Player and bullet.shooter.rewinding):
			step_projectile(bullet, delta)
	PerformanceStats.end(PerformanceStats.COMBAT_STEP, started)

func step_projectile(bullet: BulletBody, delta: float) -> void:
	if time_field != null:
		if time_field.is_rewinding():
			return
		delta = delta * time_field.player_speed_mult() if bullet.shooter is Player else time_field.world_delta(delta)
	ShotRules.step_projectile(self, bullet, delta)

static func blast_state(type_id: int, pos: Vector2, at: int) -> Array:
	return [type_id, pos, at + BLAST_DELAY]

func submit_blast(id: int, pos: Vector2, type_id: int) -> void:
	pending_blasts[id] = blast_state(type_id, pos, tick)
	if not predicting:
		detonated.emit(id, pos, type_id)

func apply_projectile_ends(ends: Dictionary) -> void:
	for id: int in ends:
		var end: Array = ends[id]
		if tick > end[ProjectileEnd.TICK]:
			continue
		pending_blasts.erase(id)
		if tick == end[ProjectileEnd.TICK]:
			if projectiles.has(id):
				erase_projectile(id)
			if not end[ProjectileEnd.BLAST].is_empty():
				pending_blasts[id] = end[ProjectileEnd.BLAST]

func settle_blasts() -> void:
	var ready: Array[int] = []
	for id: int in pending_blasts:
		if pending_blasts[id][Blast.DUE] <= tick:
			ready.append(id)
	ready.sort_custom(func(a: int, b: int) -> bool:
		var ta: int = pending_blasts[a][Blast.DUE]
		var tb: int = pending_blasts[b][Blast.DUE]
		return a < b if ta == tb else ta < tb)
	for id: int in ready:
		var blast: Array = pending_blasts[id]
		pending_blasts.erase(id)
		resolve_blast(blast[Blast.POS], WeaponRegistry.blast_definition(blast[Blast.TYPE]), players.get(ShotRules.shooter_role(id)))

func resolve_blast(center: Vector2, spec: Dictionary, source: ActorBody) -> void:
	var radius: float = spec["radius"]
	var actors: Array[ActorBody] = []
	actors.assign(players.values())
	actors.sort_custom(func(a: Player, b: Player) -> bool: return a.role < b.role)
	for enemy in enemies:
		if enemy.active:
			actors.append(enemy)
	for target in actors:
		var distance := _delta(center, target.position).length()
		if distance > radius:
			continue
		var blocked := not terrain.line_of_sight(center, target.position)
		var cover := BlastCurve.cover_multiplier(distance, radius, blocked)
		var inner := radius * BlastCurve.INNER_FRACTION
		resolve_hit(source, target, CombatProfiles.BLAST, center,
				BlastCurve.falloff(distance, radius, inner, spec["damage"]) * cover,
				BlastCurve.falloff(distance, radius, inner, spec["impact"]) * cover,
				hit_direction(center, target.position))
	if not predicting:
		terrain.damage_blast(terrain.blast_cells(center, radius),
				radius, spec["damage"], source_role(source))

func hit_rewound_elites() -> void:
	# 恢复玩家弹丸的位置后，检查它们是否与仍在活动的精英敌人相撞。
	# 回溯期间，同一枚弹丸只能对同一个敌人结算一次伤害。
	var space := terrain.physics
	for bullet: BulletBody in projectiles.values():
		var source := bullet.shooter
		if not source is Player:
			continue
		for entry: Dictionary in space.shape_overlaps(bullet.shape, bullet.transform, CollisionWorld.LAYER_ENEMY):
			var enemy := entry["collider"] as EnemyBase
			if enemy == null or not enemy.kind.elite or enemy.is_dead:
				continue
			var id := enemy.get_instance_id()
			if bullet.rewind_hits.has(id):
				continue
			bullet.rewind_hits[id] = true
			resolve_hit(source, enemy, CombatProfiles.DIRECT, bullet.position, bullet.hit_damage,
					bullet.hit_impact, hit_direction(bullet.position, enemy.position))

func resolve_hit(source: ActorBody, target: ActorBody, profile: Dictionary, at: Vector2,
		damage: float, force: float, direction := Vector2.ZERO) -> bool:
	var targets: int = profile["targets"]
	if target is Player:
		if not (targets & _relation(source, target)) or target.sim_downed or target.rewinding:
			return false
		if time_field != null and time_field.is_rewinding():
			return false
		if target.sim_iframes > 0.0 and profile.get("respects_iframes", false):
			return false
	elif target is EnemyBase:
		if not (targets & CombatProfiles.Target.NPC):
			return false
	else:
		return false

	match profile["water"]:
		CombatProfiles.Water.BLAST:
			var mult := terrain.water_multiplier(target.position)
			damage *= mult
			force *= mult
		CombatProfiles.Water.WET:
			if terrain.water(target.position):
				damage = roundi(damage * CombatProfiles.FLY_BIRD_WET_MULT)
	if predicting:
		if force != 0.0 and target is Player:
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

static func _relation(source: ActorBody, target: Player) -> int:
	if source == target:
		return CombatProfiles.Target.SELF
	if source is Player and source.team != 0 and source.team == target.team:
		return CombatProfiles.Target.ALLY
	return CombatProfiles.Target.OPPONENT

static func source_role(source: ActorBody) -> int:
	return source.role if source is Player else 0

func _delta(from: Vector2, to: Vector2) -> Vector2:
	var size := terrain.map_size
	return GridPathfinder.toroidal_delta_px(from, to, size)

func hit_direction(from: Vector2, to: Vector2) -> Vector2:
	var delta := _delta(from, to)
	return delta.normalized() if delta.length_squared() > 1.0 else Vector2.RIGHT
