class_name CombatSimulator
extends RefCounted

enum Blast { TYPE, POS, DUE }
enum Beam { END_TICK, POINTS }
const BLAST_DELAY := 3
const BEAM_TICKS := 15
const ACTOR_LAYERS := CollisionWorld.LAYER_ENEMY | CollisionWorld.LAYER_TEAM_A | CollisionWorld.LAYER_TEAM_B

var terrain: Terrain
var ground: GroundWeaponField
var time_field: WorldTime
var tick := 0
var projectiles: Dictionary[int, BulletBody] = {}
var beams: Dictionary[int, Array] = {}
var enemies: Array[EnemyBase] = []
var players: Dictionary[int, Player] = {}
var team_counts: Dictionary
var hits: Array[Array] = []
var destroyed_subcells: Dictionary[int, int] = {}
var enemy_kills := 0
var rng := RandomNumberGenerator.new()
var pending_blasts: Dictionary[int, Array] = {}
var _next_enemy_projectile := -1

func _init(map: Terrain, seed_value := 0) -> void:
	rng.seed = seed_value
	terrain = map
	ground = GroundWeaponField.new(map)

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

## 按角色 ID 处理输入。角色全部移动后再处理攻击，当帧生成的弹丸可在本帧移动。
## 查询使用最近一次提交的地形碰撞，本步地形改动统一在步末提交。
func step(inputs: Dictionary) -> Dictionary:
	destroyed_subcells.clear()
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

	var shots := resolve_requests(roles)
	for enemy in enemies:
		if enemy.active:
			enemy.simulate_tick(ActorStep.DT)
	if not reversing:
		step_projectiles(ActorStep.DT)
		settle_blasts()
	terrain.commit()
	return shots

func resolve_requests(roles: Array) -> Dictionary:
	var shots := {}
	for role: int in roles:
		var actor := players[role]
		for request: Dictionary in actor.combat_requests:
			match request["kind"]:
				"fire": shots[ShotRules.shot_id(role, request["serial"])] = request
				"drown": resolve_hit(null, actor, CombatProfiles.DROWN, request["pos"], request["damage"], 0.0)
	var ids := shots.keys()
	ids.sort()
	for id: int in ids:
		var actor: Player = players.get(ShotRules.shooter_role(id))
		if actor != null:
			shots[id] = fire(actor, shots[id])
	return shots

func fire(actor: Player, action: Dictionary) -> Dictionary:
	var spec := WeaponRegistry.definition(action["type_id"])
	var shot := action.merged({"role": actor.role}, true)
	match spec["attack"]:
		WeaponDef.Attack.PROJECTILE:
			shot["vectors"] = ShotRules.projectiles(self, actor, shot, spec)
		WeaponDef.Attack.BEAM:
			var points := ShotRules.beam(self, actor, shot, spec)
			beams[ShotRules.shot_id(actor.role, shot["serial"])] = [tick + BEAM_TICKS, points]
			shot["vectors"] = points
		WeaponDef.Attack.MELEE:
			shot["vectors"] = ShotRules.melee(self, actor, shot, spec)
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

func can_fire(type_id: int, owner: Player, live_cap: int) -> bool:
	if live_cap == 0:
		return true
	for bullet: BulletBody in projectiles.values():
		if bullet.type_id == type_id and bullet.shooter == owner:
			live_cap -= 1
			if live_cap == 0:
				return false
	return true

func erase_projectile(id: int) -> void:
	projectiles[id].release()
	projectiles.erase(id)

func clear() -> void:
	for id: int in projectiles.keys():
		erase_projectile(id)
	beams.clear()
	pending_blasts.clear()

## 结算画面保留在场的弹丸和光束，待结算的爆炸在对局结束时清除。
func finish_match() -> void:
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
	record_destruction(source_role(source), terrain.damage_blast(center, radius, spec["damage"]))

func record_destruction(role: int, count: int) -> void:
	if role > 0 and count > 0:
		destroyed_subcells[role] = destroyed_subcells.get(role, 0) + count

func hit_rewound_elites(hits_by_projectile: Dictionary) -> void:
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
			var id := enemy.slot
			var hit: Dictionary = hits_by_projectile.get_or_add(bullet.entity_id, {})
			if hit.has(id):
				continue
			hit[id] = true
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
	var amount := int(damage)
	if target is EnemyBase:
		if profile["water"] == CombatProfiles.Water.BLAST and damage <= 0.0:
			return false
		var enemy := target as EnemyBase
		var mode: int = profile["npc_impulse"]
		enemy.hurt(amount, direction, 0.0 if mode == CombatProfiles.NpcImpulse.DEFAULT else force,
				mode == CombatProfiles.NpcImpulse.SET)
		return true

	var victim := target as Player
	if not team_counts.is_empty() and source is Player and source != victim:
		amount = roundi(amount * TeamRules.damage_factor(source.team, victim.team, team_counts))
	var before := victim.sim_hp
	victim.simulate_hit(at, amount, force)
	if before > victim.sim_hp:
		hits.append([source_role(source), victim.role, before - victim.sim_hp])
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

func capture_players() -> Dictionary:
	var states := {}
	for role: int in players:
		states[role] = players[role].capture_state()
	return states

func sample_attacks(owner_role := 0) -> Dictionary:
	return {
		"projectiles": capture_projectiles(owner_role),
		"beams": _owned_attacks(beams, owner_role),
		"blasts": _owned_attacks(pending_blasts, owner_role),
	}

func capture_attacks() -> Dictionary:
	var state := sample_attacks()
	state["enemy_next"] = _next_enemy_projectile
	return state

func restore_attacks(state: Dictionary, restore_ids := true) -> void:
	_restore_projectiles(state["projectiles"])
	beams.assign(state["beams"])
	pending_blasts.assign(state["blasts"])
	if restore_ids:
		_next_enemy_projectile = state["enemy_next"]

static func _owned_attacks(records: Dictionary, owner_role: int) -> Dictionary:
	if owner_role == 0:
		return records.duplicate()
	var states := {}
	for id: int in records:
		if ShotRules.shooter_role(id) == owner_role:
			states[id] = records[id]
	return states

func capture_projectiles(owner_role := 0, motion_only := false) -> Dictionary:
	var states := {}
	for id: int in projectiles:
		var bullet := projectiles[id]
		if owner_role == 0 or ShotRules.shooter_role(id) == owner_role:
			states[id] = bullet.motion_state() if motion_only else bullet.capture_state()
	return states

func restore_projectile_motion(states: Dictionary) -> void:
	for id: int in states:
		if projectiles.has(id):
			projectiles[id].restore_motion(states[id])

func capture_enemies(ordinary_only := false) -> Dictionary:
	var states := {}
	for enemy: EnemyBase in enemies:
		if not ordinary_only or not enemy.kind.elite:
			states[enemy.slot] = enemy.capture_state()
	return states

func _restore_projectiles(states: Dictionary) -> void:
	for id: int in projectiles.keys():
		if not states.has(id) or states[id][BulletBody.SNAP_TYPE] != projectiles[id].type_id:
			erase_projectile(id)
	var ids := states.keys()
	ids.sort()
	for id: int in ids:
		var row: Array = states[id]
		var owner: int = row[BulletBody.SNAP_OWNER]
		var source: ActorBody = players[owner] if id >= 0 else enemies[owner]
		var bullet: BulletBody = projectiles.get(id)
		if bullet != null and bullet.shooter != source:
			erase_projectile(id)
			bullet = null
		if bullet == null:
			bullet = spawn_projectile(id, row[BulletBody.SNAP_TYPE], source, row[BulletBody.MOTION_POS],
					row[BulletBody.MOTION_VEL], row[BulletBody.SNAP_DAMAGE])
		bullet.restore_motion(row)
		bullet.hit_damage = row[BulletBody.SNAP_DAMAGE]
		bullet.direct_hit = row[BulletBody.SNAP_DIRECT_HIT]
