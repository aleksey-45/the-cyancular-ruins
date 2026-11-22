class_name CombatSnapshot
extends RefCounted

# 正数指定个人回溯的角色 ID。WORLD 和 NETWORK 用于恢复整帧战斗状态。
const WORLD := 0
const NETWORK := -1

var tick: int
var players: Dictionary
var projectiles: Dictionary[int, Array]
var beams: Dictionary
var pending_blasts: Dictionary[int, Array]

var enemies: Dictionary[int, Array]
var elapsed: float

func capture(combat: CombatSimulator) -> void:
	tick = combat.tick
	players = {}
	for role: int in combat.players:
		players[role] = combat.players[role].capture_checkpoint()
	projectiles = {}
	for bullet: BulletBody in combat.projectiles.values():
		projectiles[bullet.entity_id] = bullet.capture_state()
	beams = combat.beams.duplicate()
	pending_blasts = combat.pending_blasts.duplicate()

func capture_environment(combat: CombatSimulator) -> void:
	if combat.time_field:
		elapsed = combat.time_field.elapsed
	enemies = {}
	for enemy in combat.enemies:
		if not enemy.kind.elite:
			enemies[enemy.slot] = enemy.capture_rewind_state()

func restore(combat: CombatSimulator, scope := NETWORK) -> void:
	if scope > WORLD:
		combat.players[scope].restore_checkpoint(players[scope], scope)
		for id: int in projectiles:
			if ShotRules.shooter_role(id) == scope and combat.projectiles.has(id):
				combat.projectiles[id].restore_motion(projectiles[id])
		return

	combat.tick = tick
	combat.terrain.restore(tick)
	for role: int in players:
		combat.players[role].restore_checkpoint(players[role], scope)
	combat.beams.assign(beams)
	combat.pending_blasts = pending_blasts.duplicate()

	for id: int in combat.projectiles.keys():
		if not projectiles.has(id) or projectiles[id][BulletBody.SNAP_TYPE] != combat.projectiles[id].type_id:
			combat.erase_projectile(id)
	for id: int in projectiles:
		var state := projectiles[id]
		var bullet: BulletBody = combat.projectiles.get(id)
		if bullet == null:
			var owner: int = state[BulletBody.SNAP_OWNER]
			var source: ActorBody = combat.players[owner] if id >= 0 else combat.enemies[owner]
			bullet = combat.spawn_projectile(id, state[BulletBody.SNAP_TYPE], source, state[BulletBody.MOTION_POS],
					state[BulletBody.MOTION_VEL], state[BulletBody.SNAP_DAMAGE])
		bullet.restore_motion(state)
		bullet.launch = state[BulletBody.SNAP_LAUNCH]
		bullet.hit_damage = state[BulletBody.SNAP_DAMAGE]
		bullet.direct_hit = state[BulletBody.SNAP_DIRECT_HIT]
	if scope == WORLD:
		if combat.time_field:
			combat.time_field.elapsed = elapsed
		for slot: int in enemies:
			combat.enemies[slot].rewind_restore(enemies[slot])
