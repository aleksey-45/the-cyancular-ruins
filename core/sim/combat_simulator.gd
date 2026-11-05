class_name CombatSimulator
extends RefCounted

# 本地预测与权威共用的攻击推进：弹丸、爆炸、光束、命中确认与查询依赖。
# 命中几何完全来自 Godot 物理；本类只保存事件顺序、角色归属与玩法结算。

const IMPACT := 0
const RADIUS := 1
const KNOCK := 2
const DAMAGE := 3
const BLAST_DAMAGE := 4
# 爆炸视觉在触发 tick 展示；伤害、击退与地形破坏统一延迟到触发后第 3 个 tick。
const BLAST_DELAY := 3

var projectiles: Dictionary = {}
var blasts: Dictionary = {}
var beams: Dictionary = {}
var hits: Dictionary = {}
var ended: Dictionary = {}
var outcomes: Dictionary = {}
var players: Array = []
var notifications: Array = []
var geometry: Terrain = null
var team_counts: Dictionary = {}

var _profiles: Dictionary = {}
var _local_id := 0
var _keep := 0
var _inner_fraction := 0.0
var _blocked_fraction := 0.0
var _beam_hit_mult := 0.0
var _step_delta := 0.0
var _tick := 0
var _first_prediction := false

func configure(player: ActorBody, sources: Dictionary, weapon_profiles: Dictionary, rules: Dictionary) -> void:
	_local_id = player.get_instance_id() if player != null else 0
	projectiles = sources["projectiles"]
	blasts = sources["blasts"]
	beams = sources["beams"]
	hits = sources["hits"]
	ended = sources["ended"]
	outcomes = sources["outcomes"]
	_keep = int(rules["keep"])
	_inner_fraction = float(rules["inner_fraction"])
	_blocked_fraction = float(rules["blocked_fraction"])
	_beam_hit_mult = float(rules["beam_hit_mult"])
	_step_delta = float(rules["dt"])
	_profiles.clear()
	for id in weapon_profiles:
		var data: Dictionary = weapon_profiles[id]
		_profiles[int(id)] = [float(data["impact"]), float(data["explosion_radius"]),
			float(data["explosion_knockback"]), int(data["damage"]), int(data["explosion_damage"])]

## 团队模式固定阵容；空词典表示不应用团队伤害倍率。
func set_team_counts(counts: Dictionary) -> void:
	team_counts = counts.duplicate()

func take_notifications() -> Array:
	var result := notifications
	notifications = []
	return result

func _local() -> ActorBody:
	return null if _local_id == 0 else instance_from_id(_local_id) as ActorBody

func _actor(role: int) -> ActorBody:
	for candidate in players:
		var player := candidate as ActorBody
		if player != null and player.role == role:
			return player
	return null

static func _merge_ids(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var result := PackedInt64Array()
	var i := 0
	var j := 0
	while i < a.size() or j < b.size():
		var value := 0
		if i >= a.size():
			value = b[j]
			j += 1
		elif j >= b.size():
			value = a[i]
			i += 1
		elif a[i] < b[j]:
			value = a[i]
			i += 1
		elif b[j] < a[i]:
			value = b[j]
			j += 1
		else:
			value = a[i]
			i += 1
			j += 1
		result.append(value)
	return result

## 本帧有效的攻击身份：活体条目 + 只剩确认结果的身份，按 id 升序。
func _attack_ids(entries: Dictionary, source: int, role := 0) -> PackedInt64Array:
	var included := _live_ids(entries, source, role)
	var confirmed := _confirmed_ids(source, role)
	if confirmed.is_empty():
		return included
	return _merge_ids(included, confirmed)

## 本帧仍有活体条目的攻击身份，按 id 升序；确认结果由调用方按阶段单独处理。
func _live_ids(entries: Dictionary, source: int, role := 0) -> PackedInt64Array:
	var ids := PackedInt64Array()
	ids.resize(entries.size())
	var i := 0
	for id: int in entries:
		ids[i] = id
		i += 1
	ids.sort()
	var included := PackedInt64Array()
	for id: int in ids:
		if (role != 0 and id >> 48 != role) or not entries.has(id):
			continue
		if source != 1:
			var entry := entries[id] as ProjectileEntry
			if entry == null or (not entry.active and entry.birth_tick != _tick):
				continue
			var bullet := entry.get_bullet()
			if (bullet == null or bullet.finished) and entry.birth_tick != _tick:
				continue
		elif int(Dictionary(entries[id])["tick"]) != _tick:
			continue
		included.append(id)
	return included

## 本帧有确认结果、没有活体条目的攻击身份，按 id 升序。
func _confirmed_ids(source: int, role := 0) -> PackedInt64Array:
	var ids := PackedInt64Array()
	for id: int in hits:
		for hit: Dictionary in hits[id]:
			if int(hit["tick"]) == _tick and int(hit["source"]) == source and (role == 0 or int(hit["shooter"]) == role):
				ids.append(id)
				break
	ids.sort()
	return ids

func _confirmed_hit(id: int, source: int, role: int) -> Dictionary:
	return confirmed_result_at(id, _tick, source, role)

func confirmed_result_at(id: int, at: int, source: int, role: int) -> Dictionary:
	if not hits.has(id):
		return {}
	for hit: Dictionary in hits[id]:
		if int(hit["tick"]) == at and int(hit["source"]) == source and int(hit["victim"]) == role:
			return hit
	return {}

func _remember_outcome(key: Array, value: Dictionary) -> void:
	if not outcomes.has(_tick):
		outcomes[_tick] = {}
	outcomes[_tick][key] = value

func _apply_hit(id: int, source: int, target: ActorBody, position: Vector2, force: float, damage := 0) -> void:
	if target == null or target != _local():
		return
	var previous_velocity := target.velocity
	var confirmed := _confirmed_hit(id, source, target.role)
	if confirmed.is_empty():
		var applied := damage
		var shooter := _actor(id >> 48)
		if shooter != null and not team_counts.is_empty():
			applied = roundi(float(damage) * TeamRules.damage_factor(shooter.team, target.team, team_counts))
		target.simulate_hit(position, applied, force)
	else:
		target.facing_direction = int(confirmed["facing"])
		target.simulate_hit(position, target.sim_hp - int(confirmed["hp"]), 0.0)
		target.motion_knock_velocity = confirmed["knock"]
		target.apply_authoritative_state(int(confirmed["hp"]), target.waterproof, int(confirmed["hp"]) <= 0)
	_remember_outcome(["hit", id, source, target.role], {"pos": position, "hp": target.sim_hp,
		"facing": target.facing_direction, "knock": target.motion_knock_velocity,
		"velocity_unchanged": previous_velocity == target.velocity})

func _apply_confirmed_hits(id: int, source: int, role := 0) -> bool:
	if not hits.has(id):
		return false
	var applied := false
	for hit: Dictionary in hits[id]:
		if int(hit["tick"]) != _tick or int(hit["source"]) != source or (role != 0 and int(hit["shooter"]) != role):
			continue
		for candidate in players:
			var player := candidate as ActorBody
			if player != null and player.role == int(hit["victim"]):
				_apply_hit(id, source, player, hit["pos"], 0.0)
				applied = true
	return applied

## 当前 tick 的一次推进。
func _simulate_projectile(bullet: BulletBody, delta: float) -> void:
	var result := bullet.advance_physics(delta)
	if result == BulletBody.AdvanceResult.RANGE_END or result == BulletBody.AdvanceResult.FUSE_END:
		if bullet.explodes:
			bullet.exploded = true
		bullet.finished = true

## 本帧物理推进命中的角色归属；队友、自己与倒地/回溯由层与结算规则排除。
func _impact_victim(bullet: BulletBody) -> ActorBody:
	return _actor(bullet.impact_role) if bullet.impact_role != 0 else null

func _finish_direct(bullet: BulletBody) -> void:
	_remember_outcome(["contact", bullet.entity_id], {})
	bullet.direct_hit = true
	if bullet.explodes:
		bullet.start_player_fuse()
	else:
		bullet.finished = true

## 触发 tick 只结束弹丸并记录结果；t+3 才结算预测伤害、击退与地形破坏。
## 同一结算 tick 已有权威 HIT 时只应用权威绝对 HP；未来 tick 的 HIT 不取消本 tick 的预测。
func _step_blast(id: int) -> void:
	if not blasts.has(id):
		_apply_confirmed_hits(id, 2)
		return
	var blast: Dictionary = blasts[id]
	var trigger_tick := int(blast["tick"])
	var due_tick := trigger_tick + BLAST_DELAY
	if trigger_tick == _tick:
		if projectiles.has(id):
			var body: BulletBody = null if projectiles[id] == null else (projectiles[id] as ProjectileEntry).get_bullet()
			if body != null:
				body.finished = true
				body.exploded = true
		if _first_prediction:
			notifications.append(["detonated", blast])
		_remember_outcome(["blast", id], blast.duplicate())
	if due_tick <= _tick and not bool(blast.get("settled", false)):
		blast["settled"] = true
		var type_id := int(blast["type_id"])
		if _profiles.has(type_id):
			var profile: Array = _profiles[type_id]
			var target: ActorBody = _local()
			if target != null and not target.sim_downed and not target.rewinding \
					and _confirmed_hit(id, 2, target.role).is_empty():
				var center: Vector2 = blast["pos"]
				var blast_radius := float(profile[RADIUS])
				var size := geometry.size()
				var distance := GridPathfinder.toroidal_delta_px(center, target.global_position, size.x, size.y).length()
				if distance <= blast_radius:
					var blocked: bool = not geometry.empty() and not geometry.line_of_sight(center, target.global_position)
					var inner := blast_radius * _inner_fraction
					var cover := 1.0
					if distance > inner:
						cover = _blocked_fraction if blocked else 1.0
					var mult := cover * geometry.water_multiplier(target.global_position)
					_apply_hit(id, 2, target, center, BlastCurve.falloff(distance, blast_radius, inner, float(profile[KNOCK])) * mult,
						int(BlastCurve.falloff(distance, blast_radius, inner, float(profile[BLAST_DAMAGE])) * mult))
			geometry.predict_blast(id, type_id, blast["pos"], _tick,
					float(profile[RADIUS]), int(profile[BLAST_DAMAGE]))
	_apply_confirmed_hits(id, 2)

## 一个 tick 只有两个攻击阶段：全部弹丸（含直接命中与引信触发）→ 全部到期爆炸。
## 地形碰撞由 PredictionWorld 在 tick 末尾统一提交一次。
func step(at: int, targets: Array, world: Terrain, first: bool) -> void:
	var started := PerformanceStats.begin()
	_tick = at
	players = targets
	geometry = world
	_first_prediction = first
	if geometry == null:
		PerformanceStats.end(PerformanceStats.COMBAT_STEP, started)
		return
	for recorded: int in outcomes.keys():
		if recorded < _tick - _keep:
			outcomes.erase(recorded)
	if _local() == null:
		PerformanceStats.end(PerformanceStats.COMBAT_STEP, started)
		return
	# 阶段 1：所有弹丸按 ID 推进并结算直接命中；本阶段只登记新爆炸，不结算范围伤害。
	for id: int in _attack_ids(projectiles, 0):
		_step_projectile(id)
	# 阶段 2：触发通知与到期结算都只在这里发生；多个爆炸按 (due_tick, id) 排序。
	var blast_ids := _blast_ids()
	for id: int in _confirmed_ids(2):
		if not blast_ids.has(id):
			blast_ids.append(id)
	for id: int in blast_ids:
		_step_blast(id)
	PerformanceStats.end(PerformanceStats.COMBAT_STEP, started)

## 单颗弹丸的本帧推进；爆炸结算由 step() 在所有弹丸之后统一执行。
func _step_projectile(id: int) -> void:
	var entry: ProjectileEntry = projectiles[id] as ProjectileEntry if projectiles.has(id) else null
	var bullet := entry.get_bullet() if entry != null else null
	if bullet == null:
		_apply_confirmed_hits(id, 0)
		return
	var owner := bullet.get_shooter() as ActorBody
	if not entry.active and entry.confirmed and entry.birth_tick == _tick:
		entry.restore_at(entry.origin_state, entry.origin_tick)
	if ended.has(id) and int(ended[id]) <= _tick:
		bullet.finished = true
	if not entry.active or _tick <= entry.tick or bullet.finished or (owner != null and owner.rewinding):
		_apply_confirmed_hits(id, 0)
		return
	entry.sim_tick = _tick
	entry.moved_tick = _tick
	bullet.adjudicated_pos = bullet.position
	_simulate_projectile(bullet, _step_delta)
	if entry.checkpoints.has(_tick):
		bullet.restore_motion(entry.checkpoints[_tick])
	bullet.fuse_started = false
	if bullet.exploded and not (blasts.has(id) and bool(Dictionary(blasts[id])["confirmed"])):
		blasts[id] = {"id": id, "type_id": bullet.type_id, "pos": bullet.position,
			"tick": _tick, "confirmed": false}
	_adjudicate(id, bullet, owner)

## 本帧要处理的爆炸：触发 tick 或已到期且未结算，按 (due_tick, id) 升序。
func _blast_ids() -> Array:
	var pending: Array = []
	for id: int in blasts:
		var record: Dictionary = blasts[id]
		var trigger_tick := int(record["tick"])
		if trigger_tick == _tick or (trigger_tick + BLAST_DELAY <= _tick and not bool(record.get("settled", false))):
			pending.append([trigger_tick + BLAST_DELAY, id])
	pending.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	var result: Array = []
	for item: Array in pending:
		result.append(int(item[1]))
	return result

## 单颗弹丸本帧的命中结算：服务端确认结果优先，其余读取本帧物理推进的命中归属。
## 只有推进成功（moved_tick 已更新）的弹丸会走到这里。
func _adjudicate(id: int, bullet: BulletBody, owner: ActorBody) -> void:
	if _apply_confirmed_hits(id, 0):
		_finish_direct(bullet)
		return
	if bullet.finished or bullet.direct_hit or (owner != null and owner.rewinding):
		return
	var known := false
	if hits.has(id):
		for record: Dictionary in hits[id]:
			if int(record["source"]) == 0:
				known = true
				break
	var victim: ActorBody = null
	var position := bullet.position
	if not known:
		victim = _impact_victim(bullet)
	else:
		for record: Dictionary in hits[id]:
			if int(record["source"]) != 0 or int(record["tick"]) != _tick:
				continue
			victim = _actor(int(record["victim"]))
			position = record["pos"]
	if victim == null:
		return
	# 倒地目标仍消耗弹丸，但权威端不会扣血或施加击退。
	if victim.sim_downed:
		_finish_direct(bullet)
		return
	_apply_hit(id, 0, victim, position, bullet.hit_impact,
		int(bullet.direct_hit_damage if bullet.explodes else bullet.hit_damage))
	_finish_direct(bullet)

## 本帧光束：每束只做一次全角色接触查询，再结算本地角色。
## 角色就是真实物理体：本地玩家被命中靠自己的碰撞层，射手本体按 RID 排除。
func step_beams(at: int, role: int, targets: Array, world: Terrain) -> void:
	_tick = at
	players = targets
	geometry = world
	if geometry == null:
		return
	var local := _local()
	if local == null:
		return
	var space := CollisionWorld.acquire(local)
	for id: int in _attack_ids(beams, 1, role):
		if beams.has(id):
			var beam: Dictionary = beams[id]
			if int(beam["tick"]) == _tick and int(beam["shooter_role"]) == role:
				var mask := CollisionWorld.LAYER_TEAM_A | CollisionWorld.LAYER_TEAM_B
				# 只排除射手本体；本地玩家的真实体留在掩码里，远端光束直接命中它。
				var exclude: Array = []
				var shooter := _actor(role)
				if shooter != null:
					exclude.append(shooter.get_rid())
				var radius := float(beam["half_width"]) * _beam_hit_mult
				var contacts := space.beam_role_contacts(beam["pts"], radius, mask, exclude)
				# 结算结果只包含本地实际受到的命中。
				var hits_now := {}
				if not local.sim_downed and not local.rewinding and contacts.has(local.role) \
						and (shooter == null or shooter.team == 0 or shooter.team != local.team) \
						and _confirmed_hit(id, 1, local.role).is_empty():
					hits_now[local.role] = contacts[local.role]
					if _profiles.has(int(beam["type_id"])):
						var profile: Array = _profiles[int(beam["type_id"])]
						_apply_hit(id, 1, local, contacts[local.role], float(profile[IMPACT]), int(profile[DAMAGE]))
				var result := beam.duplicate()
				result["contacts"] = hits_now
				_remember_outcome(["beam", id], result)
		_apply_confirmed_hits(id, 1, role)
