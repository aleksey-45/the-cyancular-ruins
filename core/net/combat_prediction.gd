class_name CombatPrediction
extends RefCounted

signal detonated(data: Dictionary)

var blasts: Dictionary = {}
var projectiles: Dictionary = {}
var beams: Dictionary = {}
var hits: Dictionary = {}
var ended: Dictionary = {}
var _player: CharacterBody2D
var tick := 0:
	set(value):
		tick = value
		if _player != null: _player.combat_tick = value
var actors: Dictionary = {}
var time_economy: TimeEconomy
var hitboxes: Dictionary = {}:
	set(value):
		hitboxes = value
		if _native != null: _native.bind_hitboxes(value)
var rewards: Dictionary = {}
var reward_changes: Dictionary = {}
# 已实际执行的阶段结果；确认消息先与这些结果比较，再决定是否使历史失效。
var _outcomes: Dictionary = {}
var _proxy_queries: Dictionary = {}
var _owner_modes: Dictionary = {}
const KEEP := 64
const TARGET_TICK_WINDOW := 12
var _native := NativeCombatKernel.new()
var _native_bound := false

func _ensure_native() -> void:
	if _native_bound: return
	_native.configure(_player, {"projectiles": projectiles, "blasts": blasts, "beams": beams,
			"hits": hits, "ended": ended, "outcomes": _outcomes, "proxy_queries": _proxy_queries,
			"owner_modes": _owner_modes, "hitboxes": hitboxes},
			WeaponRegistry.native_profiles(), {"keep": KEEP, "dt": ActorStep.DT,
			"contact_radius": BulletBase.PLAYER_HIT_RADIUS, "inner_fraction": Explosion.INNER_FRACTION,
			"blocked_fraction": Explosion.BLOCKED_FRACTION, "beam_hit_mult": LaserWeaponBase.HIT_MULT,
			"target_window": TARGET_TICK_WINDOW})
	_native_bound = true

func _publish_native_events() -> void:
	for event: Array in _native.take_notifications():
		detonated.emit(event[1])

func bind(player: CharacterBody2D) -> void:
	_player = player
	player.bind_prediction_projectiles(projectiles)
	player.combat_tick = tick
	player.weapons.projectile_count = count_projectiles
	_native_bound = false
	_ensure_native()

func count_projectiles(type_id: int, role: int = 0) -> int:
	if role == 0: role = _player.role
	var count := 0
	for id in projectiles:
		var entry: NativeProjectileEntry = projectiles[id]
		var bullet: BulletBase = entry["bullet"]
		if id >> 48 == role and bullet.type_id == type_id and entry.active and entry["tick"] < tick and not bullet.finished:
			count += 1
	return count

func _make_bullet(id: int, state: Dictionary, owner: Node2D) -> Node2D:
	var profile := WeaponRegistry.projectile_profile(state["type_id"])
	var bullet = profile["scene"].instantiate()
	bullet.prediction_only = true
	bullet.visible = false
	bullet.apply_damage = false
	bullet.entity_id = id
	bullet.type_id = state["type_id"]
	bullet.shooter = owner
	bullet.hit_impact = profile["impact"]
	bullet.hit_damage = profile["damage"]
	bullet.setup(state["vel"].normalized(), state["vel"].length(), profile["range"], profile["size"], profile["color"], null)
	bullet.gravity_factor = profile["gravity"]
	_player.get_viewport().add_child(bullet)
	bullet.set_physics_process(false)
	bullet.restore_motion(state)
	return bullet

func seed_projectile(id: int, state: Dictionary, tick: int, owner: Node2D, confirmed: bool = true) -> Vector2i:
	# 返回出生身份变化影响的 tick 范围；相同初态只更新确认元数据。
	var changed := Vector2i(tick + 1, tick + 1)
	if projectiles.has(id):
		var previous: NativeProjectileEntry = projectiles[id]
		changed = Vector2i(mini(previous["birth_tick"], tick + 1), maxi(previous["birth_tick"], tick + 1))
		if previous.active and previous["bullet"].type_id == state["type_id"] \
				and previous["origin_tick"] == tick and _same_projectile_state(previous["origin_state"], state):
			changed = Vector2i.ZERO
	# 同一预测序号可能被权威确认成另一把武器；只能复用同一类型的物理资源。
	if projectiles.has(id) and projectiles[id]["bullet"].type_id != state["type_id"]:
		projectiles[id]["bullet"].free()
		projectiles.erase(id)
		if blasts.has(id) and not blasts[id].get("confirmed", false): blasts.erase(id)
	if projectiles.has(id):
		var entry: NativeProjectileEntry = projectiles[id]
		entry["bullet"].shooter = owner
		if confirmed:
			if not entry["confirmed"] or tick <= entry["origin_tick"]:
				entry["origin_tick"] = tick
				entry["origin_state"] = state.duplicate()
				entry["birth_tick"] = tick + 1
			entry["confirmed"] = true
			entry["checkpoints"][tick] = state.duplicate()
		return changed
	var entry := NativeProjectileEntry.new()
	entry.initialize(_make_bullet(id, state, owner), state, tick, confirmed)
	projectiles[id] = entry
	return changed

static func _same_projectile_state(a: Dictionary, b: Dictionary) -> bool:
	# 出生事件和预测规格可能附带不同元数据；只比较完整的弹丸模拟字段。
	for field: Array in NetCodec.PROJECTILE_FIELDS:
		if not a.has(field[0]) or not b.has(field[0]) or a[field[0]] != b[field[0]]: return false
	return true

# 只推进新弹丸，使用已记录的历史位置；不会改变任何角色或地形。
# 地形时效由调用者验证。遇到本地接触即放弃，交给正常后缀重放。
func catch_up_remote(id: int, history: Dictionary, through: int) -> Dictionary:
	_ensure_native()
	return _native.catch_up_remote(id, history, through, ActorStep.DT,
			Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT))

func commit_catch_up(id: int, plan: Dictionary) -> void:
	for at in plan["queries"]:
		_proxy_queries.get_or_add(at, []).append(plan["queries"][at])
		_owner_modes.get_or_add(at, {})[id >> 48] = false
	for at in plan["contacts"]: _remember_outcome(at, ["contact", id], {})

func checkpoint_projectile(id: int, state: Dictionary, at_tick: int, owner: Node2D) -> bool:
	var previous: Dictionary = projectiles[id].checkpoints.get(at_tick, {}) if projectiles.has(id) else {}
	var changed := not _same_projectile_state(previous, state)
	if not projectiles.has(id) or projectiles[id]["bullet"].type_id != state["type_id"]:
		seed_projectile(id, state, at_tick, owner)
	else:
		projectiles[id]["checkpoints"][at_tick] = state.duplicate()
	return changed

func shot_actions(player: CharacterBody2D, actions: Array, tick: int) -> void:
	for action: Dictionary in actions:
		if action["kind"] != "fire":
			continue
		var weapon: WeaponBase = player.weapons.current_weapon()
		if weapon is LaserWeaponBase:
			var id: int = (player.role << 48) | (action["serial"] << 8)
			if beams.has(id) and beams[id].get("confirmed", false): continue
			var beam: Dictionary = weapon._make_beam_report(weapon._emit_beam(action["pos"], action["dir"])["points"])
			beam.merge({"id": (player.role << 48) | (action["serial"] << 8), "tick": tick,
					"type_id": weapon.type_id, "shooter_role": player.role, "confirmed": false})
			beams[beam["id"]] = beam
		else:
			for spec: Dictionary in weapon.projectile_specs(action):
				if projectiles.has(spec["id"]) and not projectiles[spec["id"]]["confirmed"] \
						and projectiles[spec["id"]]["bullet"].type_id != spec["type_id"]:
					projectiles[spec["id"]]["bullet"].free()
					projectiles.erase(spec["id"])
				if not projectiles.has(spec["id"]):
					seed_projectile(spec["id"], spec, tick - 1, player, false)
				else:
					var entry: NativeProjectileEntry = projectiles[spec["id"]]
					# 同一个预测攻击在新锚点重放时更新初态，保留节点和不可变出生身份。
					if entry["confirmed"] and entry["birth_tick"] != tick: continue
					var initial: Dictionary = entry["origin_state"] if entry["confirmed"] else spec
					_reset_projectile(entry, initial, tick - 1)

func _reset_projectile(entry: NativeProjectileEntry, state: Dictionary, at_tick: int) -> void:
	entry.reset_at(state, at_tick)

func can_restore_checkpoint(at_tick: int, states: NativeProjectileSnapshot) -> bool:
	return states.can_restore(projectiles, at_tick)

func restore_checkpoint(at_tick: int, states: NativeProjectileSnapshot) -> void:
	# 保留新收到的权威事件；只撤销失效后缀产生的推测结果。
	for at in _outcomes.keys():
		if at > at_tick: _outcomes.erase(at)
	for at in _proxy_queries.keys():
		if at > at_tick: _proxy_queries.erase(at)
	for at in _owner_modes.keys():
		if at > at_tick: _owner_modes.erase(at)
	for id in beams.keys():
		if not beams[id].get("confirmed", false) and beams[id]["tick"] > at_tick: beams.erase(id)
	for id in blasts.keys():
		if not blasts[id].get("confirmed", false) and blasts[id]["tick"] > at_tick: blasts.erase(id)
	states.restore(projectiles, at_tick)
	self.tick = at_tick

func receive_reward(data: Dictionary) -> bool:
	if rewards.get(data["serial"], {}) == data: return false
	if not reward_changes.has(data["serial"]):
		reward_changes[data["serial"]] = rewards.get(data["serial"], {})
	rewards[data["serial"]] = data.duplicate()
	return true

func step_rewards(at_tick: int, phase: int) -> Array:
	var applied: Array = []
	if time_economy == null: return applied
	# 可靠事件的 serial 保留同一阶段内服务端入账顺序。
	for reward: Dictionary in rewards.values():
		if reward["role"] == _player.role and reward["tick"] == at_tick and reward["phase"] == phase and time_economy.accounts.has(reward["role"]):
			applied.append(reward)
	applied.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["serial"] < b["serial"])
	for reward: Dictionary in applied: time_economy.accounts[reward["role"]].deposit(reward["amount"])
	return applied

func receive_beam(data: Dictionary) -> Vector2i:
	var previous: Dictionary = beams.get(data["id"], {})
	var actual := _outcome(data["tick"], ["beam", data["id"]])
	var fields := ["tick", "type_id", "shooter_role", "pts", "half_width"]
	var same: bool = _same_fields(actual, data, fields) \
			or (previous.get("confirmed", false) and _same_fields(previous, data, fields))
	if not same and actual.has("targets") and _same_fields(actual, data, ["tick", "type_id", "shooter_role"]):
		# 路径/宽度改变但实际接触结果相同，只更新光束确认与表现数据。
		same = true
		for role in actual["targets"]:
			if not _confirmed_hit(data["id"], data["tick"], 1, role).is_empty(): continue
			var contact := LaserWeaponBase.path_contact(data["pts"], actual["targets"][role], data["half_width"] * LaserWeaponBase.HIT_MULT)
			if contact != actual["contacts"].get(role, Vector2(INF, 0.0)):
				same = false
				break
	beams[data["id"]] = data.merged({"confirmed": true}, true)
	return Vector2i.ZERO if same else _changed_span(data["tick"], ["beam", data["id"]])

func confirm_hit(data: Dictionary) -> Vector2i:
	if data["id"] == 0:
		return Vector2i.ZERO
	var previous := _confirmed_hit(data["id"], data["tick"], data["source"], data["victim"])
	if previous == data: return Vector2i.ZERO
	if not hits.has(data["id"]): hits[data["id"]] = []
	if not previous.is_empty(): hits[data["id"]].erase(previous)
	hits[data["id"]].append(data)
	if data["victim"] != _player.role:
		# 他人的 HP/倒地不在本地预测域。仍保留命中用于弹丸结束和榴弹引信。
		var dependent: bool = projectiles.has(data["id"]) and projectiles[data["id"]]["bullet"].explodes
		for at in _outcomes:
			if _outcomes[at].has(["hit", data["id"], data["source"], _player.role]): dependent = true
		if not dependent: return Vector2i.ZERO
	var key := ["hit", data["id"], data["source"], data["victim"]]
	if _same_hit_result(_outcome(data["tick"], key), data):
		return Vector2i.ZERO
	return _changed_span(data["tick"], key)

static func _same_fields(a: Dictionary, b: Dictionary, fields: Array) -> bool:
	for field in fields:
		if not a.has(field) or not b.has(field) or a[field] != b[field]: return false
	return true

static func _same_hit_result(actual: Dictionary, confirmed: Dictionary) -> bool:
	# 源位置仅通过受击结果影响后续模拟；基础速度无法从 HIT 恢复时不猜测。
	return actual.get("velocity_unchanged", false) and _same_fields(actual, confirmed, ["hp", "knock", "facing"])

func _outcome(at_tick: int, key: Array) -> Dictionary:
	return _outcomes.get(at_tick, {}).get(key, {})

func _remember_outcome(at_tick: int, key: Array, value: Dictionary) -> void:
	_outcomes.get_or_add(at_tick, {})[key] = value

func _changed_span(at_tick: int, key: Array) -> Vector2i:
	var span := Vector2i(at_tick, at_tick)
	for at in _outcomes:
		if _outcomes[at].has(key):
			span.x = mini(span.x, at)
			span.y = maxi(span.y, at)
	return span

func end_projectiles(data: Dictionary) -> Vector2i:
	var span := Vector2i.ZERO
	for id in data["ids"]:
		ended[id] = data["tick"]
		if projectiles.has(id) and projectiles[id]["sim_tick"] >= data["tick"]:
			var bullet: BulletBase = projectiles[id]["bullet"]
			# 远端普通弹丸的结束若从未改变本地角色，只修正弹丸生命周期。
			# 榴弹还会影响引信/地形；本地射出的弹丸还可能影响开火数量限制，保守复核。
			var independent: bool = not bullet.explodes and id >> 48 != _player.role and not _has_local_hit(id)
			if bullet.direct_hit and not independent:
				var contact := _changed_span(data["tick"], ["contact", id])
				var confirmed := false
				for hit: Dictionary in hits.get(id, []):
					if hit["tick"] == data["tick"] and hit["source"] == 0 and _same_hit_result(
							_outcome(hit["tick"], ["hit", id, 0, hit["victim"]]), hit):
						confirmed = true
				# 相同结束 tick 还不足以证明命中正确，必须有相同的权威 HIT。
				if not confirmed or contact != Vector2i(data["tick"], data["tick"]):
					span = contact if span == Vector2i.ZERO else Vector2i(mini(span.x, contact.x), maxi(span.y, contact.y))
			bullet.finished = true
	return span

func _has_local_hit(id: int) -> bool:
	for at in _outcomes:
		if _outcomes[at].has(["hit", id, 0, _player.role]): return true
	return false

func prepare(at_tick: int, states: Dictionary) -> void:
	TileDefs.terrain.reset_prediction(at_tick)
	_outcomes.clear()
	_proxy_queries.clear()
	_owner_modes.clear()
	for id in beams.keys():
		if beams[id]["tick"] <= at_tick or not beams[id]["confirmed"]:
			beams.erase(id)
	for id in blasts.keys():
		if not blasts[id]["confirmed"]: blasts.erase(id)
	_prepare_authoritative(at_tick, states)
	acknowledge(at_tick)

# STATE 提供同 tick 的完整弹丸锚点，直接用于恢复。
func _prepare_authoritative(at_tick: int, states: Dictionary) -> void:
	for id in states:
		if not projectiles.has(id) or projectiles[id]["bullet"].type_id != states[id]["type_id"]:
			seed_projectile(id, states[id], at_tick, actors.get(id >> 48))
	for id in projectiles.keys():
		var entry: NativeProjectileEntry = projectiles[id]
		if states.has(id):
			_reset_projectile(entry, states[id], at_tick)
			entry["confirmed"] = true
		else:
			entry["active"] = false
			entry["bullet"].finished = true
			if entry.retired_tick < 0: entry.retired_tick = at_tick
		for checkpoint in entry["checkpoints"].keys():
			if checkpoint <= at_tick: entry["checkpoints"].erase(checkpoint)
		if entry.retired_tick >= 0 and entry.retired_tick < at_tick - KEEP:
			entry["bullet"].free()
			projectiles.erase(id)

func step_beams(tick: int, shooter_role: int, players: Array) -> bool:
	self.tick = tick
	if beams.is_empty() and hits.is_empty(): return false
	_ensure_native()
	return _native.step_beams(tick, shooter_role, players, TileDefs.terrain)

func confirm(data: Dictionary) -> Vector2i:
	var previous: Dictionary = blasts.get(data["id"], {})
	var fields := ["tick", "type_id", "pos"]
	var same: bool = _same_fields(_outcome(data["tick"], ["blast", data["id"]]), data, fields) \
			or (previous.get("confirmed", false) and _same_fields(previous, data, fields))
	blasts[data["id"]] = data.merged({"confirmed": true}, true)
	return Vector2i.ZERO if same else _changed_span(data["tick"], ["blast", data["id"]])

func cancel_role(role: int) -> void:
	for id in projectiles.keys():
		if id >> 48 == role:
			projectiles[id]["bullet"].free()
			projectiles.erase(id)
	for id in beams.keys():
		if id >> 48 == role: beams.erase(id)
	for id in blasts.keys():
		if id >> 48 == role and not blasts[id]["confirmed"]: blasts.erase(id)

func acknowledge(tick: int) -> void:
	# 复用成功时也会调用；否则已结束的榴弹可能一直等不到下一次完整恢复才释放。
	for id in projectiles.keys():
		var entry: NativeProjectileEntry = projectiles[id]
		if not entry.active or entry["bullet"].finished:
			if entry.retired_tick < 0: entry.retired_tick = maxi(tick, entry.sim_tick)
			if entry["retired_tick"] < tick - KEEP:
				entry["bullet"].free()
				projectiles.erase(id)
	for serial in rewards.keys():
		if rewards[serial]["tick"] <= tick:
			rewards.erase(serial)
			reward_changes.erase(serial)
	for id in ended.keys():
		if ended[id] <= tick: ended.erase(id)
	for id in hits.keys():
		var covered: Array = hits[id].filter(func(hit: Dictionary) -> bool: return hit["tick"] <= tick)
		if projectiles.has(id) and not projectiles[id]["bullet"].explodes and not covered.is_empty():
			projectiles[id]["bullet"].free()
			projectiles.erase(id)
		hits[id] = hits[id].filter(func(hit: Dictionary) -> bool: return hit["tick"] > tick)
		if hits[id].is_empty(): hits.erase(id)
	for id in blasts.keys():
		if blasts[id]["tick"] <= tick: blasts.erase(id)
	for id in beams.keys():
		if beams[id]["tick"] <= tick: beams.erase(id)
	for at in _outcomes.keys():
		if at <= tick: _outcomes.erase(at)

# 原生段按攻击 ID 推进；地形改变是明确的提交边界，后续弹丸必须看到新碰撞。
func step(tick: int, players: Array, first_prediction: bool) -> void:
	self.tick = tick
	_ensure_native()
	_native.step(tick, players, TileDefs.terrain, first_prediction)
	_publish_native_events()

func begin_tick(at_tick: int) -> void:
	_proxy_queries[at_tick] = []
	_owner_modes[at_tick] = {}

# 只重查远端几何，固定本地当时的候选结果；包括原先没有接触的路径。
func proxy_queries_match(at_tick: int, proxies: Array) -> bool:
	_ensure_native()
	return _native.proxy_queries_match(at_tick, proxies, actors,
			Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT))

func _confirmed_hit(id: int, tick: int, source: int, role: int) -> Dictionary:
	_ensure_native()
	return _native.confirmed_result_at(id, tick, source, role)

func clear() -> void:
	_native.take_notifications()
	TileDefs.terrain.reset_prediction(-1)
	_outcomes.clear()
	_proxy_queries.clear()
	_owner_modes.clear()
	for entry: NativeProjectileEntry in projectiles.values(): entry["bullet"].free()
	projectiles.clear()
	beams.clear()
	hits.clear()
	ended.clear()
	blasts.clear()
	rewards.clear()
	reward_changes.clear()
