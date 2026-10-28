class_name PredictionRollback
extends RefCounted
signal tick_finished
const KEEP := 64
const MAX_REPLAY := 32
const MARGIN := 2.0
var history: Array = []
var epoch := 1
var sequence := 0
var sent: Array = []
var actions: Array = []
var _clock := 0.0
var _sim_tick := 0
var _authority_tick := 0
var _lead := MARGIN
var _rate := 1.0
var _timing_seq := 0
var _clock_correction_seq := 0
var _discarded_through := 0
var _input := InputBuffer.new()
var _player: Player
var _replicas: Dictionary = {}
var _collision_anchor: ActorCollider
var _roles: Array = []
var _actor_roles: Array = []
var _players: Array = []
var _states: Dictionary = {}
var _native_history := NativePredictionHistory.new()
var _hitboxes: Dictionary = {}
var _commands: Dictionary = {}
var _reuse_buffers: Dictionary = {}
var _reuse_cursors: Dictionary = {}
var _reuse_commands: Dictionary = {}
var _reuse_tick := -1
var _reuse_economy: Dictionary = {}
var effect_counts: Dictionary = {}
var last_effect_review: Dictionary = {}
var reuse_counts: Dictionary = {}
var reuse_detail: Dictionary = {}
var reuse_totals := {"full": 0, "prefix": 0, "saved_ticks": 0, "prefix_saved_ticks": 0, "replayed_ticks": 0}
var terrain_revision := 0
var terrain: NativeTerrain
var time_economy: TimeEconomy
var combat_prediction := preload("res://core/net/combat_prediction.gd").new()
var diagnostics := {"reason": "", "replay_ticks": 0}
var profile_steps := OS.get_cmdline_user_args().has("--prediction-profile") or OS.get_cmdline_user_args().has("--frame-trace")

func bind(player: Player, replicas: Dictionary = {}, collision_anchor: ActorCollider = null) -> void:
	_player = player
	_player.cache_terrain_motion = true
	_player.track_actor_queries = true
	combat_prediction.bind(player)
	combat_prediction.hitboxes = _hitboxes
	_replicas = replicas
	_collision_anchor = collision_anchor
	_native_history.bind_sources(_states, combat_prediction.projectiles, _hitboxes, KEEP)
	_bind_history_remotes()

func _bind_history_remotes() -> void:
	var records: Array = []
	var roles := _replicas.keys()
	roles.sort()
	for role in roles:
		records.append([role, _replicas[role]._forecast, _replicas[role]._ghost, _replicas[role]._respawn_tick])
	_native_history.configure_remotes(records)

func reset(new_epoch: int, ack: int, tick: int, ping_ms: int) -> void:
	epoch = new_epoch
	sequence = ack
	sent.clear()
	history.clear()
	actions.clear()
	_states.clear()
	_hitboxes.clear()
	_commands.clear()
	_reuse_buffers.clear()
	_reuse_cursors.clear()
	_reuse_commands.clear()
	_reuse_tick = -1
	_reuse_economy.clear()
	_input.reset(epoch)
	_authority_tick = tick
	_clock = tick + minf(ceilf(ping_ms * 0.06) + MARGIN, MAX_REPLAY)
	_sim_tick = tick
	_lead = MARGIN
	_rate = 1.0
	_timing_seq = 0
	_clock_correction_seq = 0
	_discarded_through = 0

func capture(source: PlayerInput, aim: Vector2, view_tick: int, weapon_inst: int) -> void:
	actions = actions.filter(func(action: Dictionary) -> bool:
		return sequence - action["seq"] <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS)
	sequence += 1
	var record := PacketInputSource.pack_record(source, sequence, aim)
	record["epoch"] = epoch
	record["target_tick"] = mini(int(_clock) + 1, _authority_tick + MAX_REPLAY)
	record["view_tick"] = view_tick
	record["winst"] = weapon_inst
	if record["pressed"] != 0 or record["released"] != 0 or weapon_inst != 0:
		var action := record.duplicate()
		if weapon_inst == 0 and (record["pressed"] | record["released"]) & (PacketInputSource.BIT_ATTACK | PacketInputSource.BIT_RELOAD | PacketInputSource.BIT_DROP):
			action["winst"] = _player.weapons.current_inst()
		action.erase("ax")
		action.erase("held")
		actions.append(action)
	for key in ["pressed", "released", "winst"]:
		record.erase(key)
	sent.append(record)
	if sent.size() > InputBuffer.REDUNDANCY:
		sent.pop_front()
	history.append(record)
	if history.size() > KEEP:
		_discarded_through = history.pop_front()["seq"]

func packet() -> Dictionary:
	return {"frames": sent, "actions": actions}

func advance(delta: float) -> void:
	var previous_tick := _sim_tick
	_clock = minf(_clock + delta * 60.0 * _rate, _authority_tick + MAX_REPLAY)
	if _sim_tick < int(_clock):
		_input.push(packet(), _sim_tick)
		_prepare_colliders()
	while _sim_tick < int(_clock):
		_sim_tick += 1
		var record := _input.take(_sim_tick)
		if not _player.rewinding:
			_player.begin_visual_step()
			_player.execute_actions(_step(record))
	if _sim_tick == previous_tick and _clock >= _authority_tick + MAX_REPLAY:
		_player.begin_visual_step()

# 比较本地锚点和实际查询依赖；代理只提供明确 tick/阶段的只读几何。
# 返回可保留的最后一帧；-1 表示恢复权威锚点。
func reusable_tick(frame: Dictionary, invalid_from: int = 0) -> int:
	_reuse_buffers.clear()
	_reuse_cursors.clear()
	_reuse_commands.clear()
	_reuse_tick = -1
	_reuse_economy.clear()
	accept_proxies(frame)
	var tick: int = frame["tick"]
	var own: Dictionary = frame["own"]
	if not _states.has(tick): return reject_reuse("missing_anchor")
	if own["epoch"] != epoch: return reject_reuse("epoch")
	if own["rewind"]: return reject_reuse("own_rewind")
	if _clock < tick or int(_clock) - tick > MAX_REPLAY or own["ack"] < _discarded_through:
		return reject_reuse("clock_or_history")
	var saved: Dictionary = _states[tick]
	if terrain != null:
		var error := terrain.difference(tick, saved["terrain"], frame["map_revision"])
		if not error.is_empty(): return reject_reuse(error)
	elif saved["revision"] != frame["map_revision"]:
		return reject_reuse("map_revision")
	var field := Player.prediction_difference(saved["players"].get(_player.role, []), own["state"])
	if not field.is_empty(): return reject_reuse("own_state", _player.role, field)
	# 弹道仍使用保守锚点检查；远端玩家的 HP、武器、账户不再成为本地锚点条件。
	if saved["projectiles"] != frame["world"].get("projectiles", {}): return reject_reuse("projectiles")
	var economy_tick := 0
	var accounts := {}
	if frame["time"].has(_player.role): accounts[_player.role] = frame["time"][_player.role]
	if saved["time"] != accounts:
		if time_economy == null or not accounts.has(_player.role): return reject_reuse("accounts")
		if accounts[_player.role]["m"] != time_economy.rules.haste_mult: return reject_reuse("account_rules")
		_reuse_economy = PredictionEconomy.review(time_economy, _states, _commands,
				combat_prediction.rewards, tick, _sim_tick, [_player.role], accounts)
		_reuse_economy["source"] = "state"
		economy_tick = _reuse_economy["invalid_from"]
	var buffer := InputBuffer.new()
	buffer.restore_authority(own["epoch"], own["ack"], own["action_ack"], own["input"], tick)
	buffer.push({"frames": history, "actions": actions}, tick)
	_reuse_buffers[_player.role] = buffer
	_reuse_cursors[tick] = {_player.role: _cursor(buffer)}
	_reuse_tick = tick
	var stop := "full"
	for at in range(tick + 1, _sim_tick + 1):
		if invalid_from > tick and at >= invalid_from:
			stop = "event"
			break
		if economy_tick > tick and at >= economy_tick:
			stop = "economy"
			break
		if not _commands.has(at) or not _states.has(at):
			stop = "missing_suffix"
			break
		var command := buffer.take(at)
		if not _same_command(command, _commands[at]["inputs"].get(_player.role, {}),
				_commands[at]["beams"].has(_player.role), _commands[at]["shots"].has(_player.role)):
			stop = "command"
			break
		_sample_proxies(at, true)
		if not ActorCollider.queries_match(_commands[at].get("actor_queries", []), _player):
			stop = "blocking"
			break
		_sample_proxies(at)
		if not combat_prediction.proxy_queries_match(at, _remote_players()):
			stop = "projectile_contact"
			break
		_reuse_cursors[at] = {_player.role: _cursor(buffer)}
		_reuse_commands[at] = {_player.role: command}
		_reuse_tick = at
	_sample_proxies(_sim_tick)
	if _reuse_tick < _sim_tick and not can_replay_from(_reuse_tick + 1, tick):
		return reject_reuse("suffix_" + stop)
	reuse_detail = {"reason": stop, "through_tick": _reuse_tick}
	var key := "full" if _reuse_tick == _sim_tick else "prefix_" + stop
	reuse_counts[key] = reuse_counts.get(key, 0) + 1
	return _reuse_tick

func can_reuse(frame: Dictionary) -> bool:
	return reusable_tick(frame) == _sim_tick

func reject_reuse(reason: String, role: int = 0, field: String = "") -> int:
	_reuse_tick = -1
	_reuse_economy.clear()
	var key := reason + ("." + field if not field.is_empty() else "")
	reuse_counts[key] = reuse_counts.get(key, 0) + 1
	reuse_detail = {"reason": reason, "role": role, "field": field}
	return -1

static func _same_command(a: Dictionary, b: Dictionary, beam: bool, shot: bool) -> bool:
	if b.is_empty(): return false
	for key in ["epoch", "ax", "held", "pressed", "released", "winst"]:
		if a[key] != b[key]: return false
	if a["aim"] != b["aim"] and (shot or a["aim"] == Vector2.ZERO or b["aim"] == Vector2.ZERO
			or WeaponBase.aim_facing_hint(a["aim"]) != WeaponBase.aim_facing_hint(b["aim"])): return false
	return not beam or a["view_tick"] == b["view_tick"]

func _commit_reuse(partial: bool) -> void:
	if _reuse_buffers.is_empty(): return
	if not _reuse_economy.is_empty():
		_commit_economy(_reuse_economy, _reuse_tick)
		_reuse_economy.clear()
	if not partial: _input = _reuse_buffers[_player.role]
	for at in _reuse_cursors:
		if _states.has(at): _states[at]["cursors"] = _reuse_cursors[at]
	for at in _reuse_commands: _commands[at]["inputs"] = _reuse_commands[at]
	if not partial:
		var latest: Dictionary = _commands.get(_sim_tick, {}).get("inputs", {}).get(_player.role, {})
		if not latest.is_empty():
			_player.input_seq = latest["seq"]
			_player.view_tick = latest["view_tick"]
	_reuse_buffers.clear()
	_reuse_cursors.clear()
	_reuse_commands.clear()

func checkpoint_state(tick: int) -> Dictionary:
	var result: Dictionary = _states[tick].duplicate()
	var players := {}
	for role in result["players"]:
		players[role] = Player.expand_prediction_state(result["players"][role])
	result["players"] = players
	return result

func confirm_projectile(id: int, state: Dictionary, at_tick: int, owner: Node2D) -> bool:
	var predicted: Dictionary = _states.get(at_tick, {}).get("projectiles", {}).get(id, {})
	var changed := combat_prediction.checkpoint_projectile(id, state, at_tick, owner)
	return changed and not CombatPrediction._same_projectile_state(predicted, state)

# 新的远端普通弹丸可以单独追赶；不撤销本地角色、账户或其他爆炸。
# 只有历史完整、扫掠范围的地形未改变且没有本地接触时才提交结果。
func review_projectile_spawn(id: int, changed: Vector2i, new_identity: bool) -> Vector2i:
	if changed == Vector2i.ZERO or changed.x > _sim_tick: return changed
	if not new_identity or id >> 48 == _player.role: return changed
	var entry: NativeProjectileEntry = combat_prediction.projectiles[id]
	var bullet: BulletBase = entry["bullet"]
	var origin: int = entry["origin_tick"]
	if bullet.explodes or TimeField.current != null or origin < _authority_tick \
			or _sim_tick - origin > MAX_REPLAY or not _states.has(origin) \
			or combat_prediction.hits.has(id): return changed
	var ticks := _sim_tick - origin
	var travel := bullet.velocity_vec.length() * ActorStep.DT * ticks \
			+ GameParameters.gravity0 * maxf(bullet.gravity_factor, 0.0) * ActorStep.DT * ActorStep.DT * ticks * (ticks + 1) / 2.0
	var padding := CollisionAabb.world_rect(bullet).size.length() + bullet.safe_margin + 1.0
	var bounds := Rect2(bullet.position, Vector2.ONE).grow(travel + padding)
	if CollisionBuilder.affects_since(_states[origin].get("geometry", -1), bounds): return changed
	if terrain != null and not terrain.unchanged_since(origin, bounds): return changed
	for at in range(origin + 1, _sim_tick + 1):
		if not _states.has(at) or not _states[at].has("contacts") \
				or not _states[at]["remote"].has(id >> 48) \
				or _states[at]["remote"][id >> 48][0]: return changed
	var plan := combat_prediction.catch_up_remote(id, _states, _sim_tick)
	if plan.is_empty(): return changed
	for at in plan["states"]:
		var state: Dictionary = plan["states"][at]
		if not state.is_empty(): _states[at]["projectiles"][id] = state
	combat_prediction.commit_catch_up(id, plan)
	return Vector2i.ZERO

# 收包只更新奖励账本；整批收齐后检查实际依赖，不能把新 serial 当成行为变化。
func review_rewards() -> int:
	last_effect_review = {}
	if combat_prediction.reward_changes.is_empty(): return 0
	var changes := combat_prediction.reward_changes.duplicate()
	combat_prediction.reward_changes.clear()
	var first := _sim_tick + 1
	var roles: Array = []
	for serial in changes:
		var previous: Dictionary = changes[serial]
		var latest: Dictionary = combat_prediction.rewards.get(serial, {})
		if previous == latest: continue
		for reward: Dictionary in [previous, latest]:
			if reward.is_empty() or reward["tick"] <= _authority_tick or reward["tick"] > _sim_tick: continue
			if reward["role"] != _player.role or time_economy == null: continue
			first = mini(first, reward["tick"])
			if not roles.has(reward["role"]): roles.append(reward["role"])
	if roles.is_empty():
		effect_counts["reward_unconsumed"] = effect_counts.get("reward_unconsumed", 0) + 1
		return 0
	var plan := PredictionEconomy.review(time_economy, _states, _commands,
			combat_prediction.rewards, first - 1, _sim_tick, roles)
	plan["source"] = "reward"
	_commit_economy(plan, plan["through"])
	return plan["invalid_from"]

func bullet_rewind_matches(data: Dictionary) -> bool:
	var at: int = data["tick"]
	var role: int = data["role"]
	if not _states.has(at): return false
	var saved := {}
	for id in _states[at]["projectiles"]:
		if id >> 48 == role: saved[id] = _states[at]["projectiles"][id]
	if saved.size() != data["projectiles"].size(): return false
	for id in saved:
		if not data["projectiles"].has(id) or not combat_prediction.projectiles.has(id) \
				or not CombatPrediction._same_projectile_state(saved[id], data["projectiles"][id]): return false
	var actor: Player = _player if role == _player.role else _replicas[role]._forecast if _replicas.has(role) else null
	if actor == null or actor.rewinding != data["rewind"]: return false
	for tick in range(at + 1, _sim_tick + 1):
		if not _states.has(tick): return false
		var mode: Variant = _states[tick].get("rewinding") if role == _player.role else _states[tick]["remote"].get(role, [null])[0]
		if mode != data["rewind"]: return false
	return true

func _commit_economy(plan: Dictionary, through: int) -> void:
	var roles: Array = plan["roles"]
	for at in plan["states"]:
		if at > through or not _states.has(at): continue
		for role in roles: _states[at]["time"][role] = plan["states"][at][role]
		if _commands.has(at) and plan["rewards"].has(at):
			var trace: Dictionary = _commands[at]["economy"]
			trace["rewards"] = trace["rewards"].filter(func(reward: Dictionary) -> bool: return not roles.has(reward["role"]))
			trace["rewards"].append_array(plan["rewards"][at])
	if through == _sim_tick and plan["states"].has(through):
		for role in roles: time_economy.restore_account(role, plan["states"][through][role])
	last_effect_review = {"source": plan["source"], "reason": plan["reason"],
			"invalid_from": plan["invalid_from"], "through_tick": through, "role": plan["role"]}
	var key: String = plan["source"] + "_" + plan["reason"]
	effect_counts[key] = effect_counts.get(key, 0) + 1

static func _cursor(buffer: InputBuffer) -> Array:
	return buffer.capture_cursor()

func can_replay_from(dirty_tick: int, anchor_tick: int = -1) -> bool:
	var at := dirty_tick - 1
	if _player.rewinding or at < maxi(_authority_tick, anchor_tick) or not _states.has(at): return false
	var saved: Dictionary = _states[at]
	if saved["cursors"][_player.role][0] != epoch: return false
	if terrain != null:
		if not terrain.can_restore(at, saved["terrain"]): return false
	elif saved["revision"] != terrain_revision:
		return false
	if _discarded_through > saved["cursors"][_player.role][1]: return false
	if saved["layers"].size() != _replicas.size(): return false
	for role in _replicas:
		if not saved["layers"].has(role): return false
		if saved["layers"][role] != _replicas[role]._ghost.collision_layer: return false
	return combat_prediction.can_restore_checkpoint(at, saved["projectiles"])

func replay_from(dirty_tick: int) -> void:
	var at := dirty_tick - 1
	var saved: Dictionary = _states[at]
	var previous := _player.global_position
	var started := Time.get_ticks_usec()
	if terrain != null: terrain.restore_checkpoint(at)
	_player.restore_state(Player.expand_prediction_state(saved["players"][_player.role]))
	_input.restore_cursor(saved["cursors"][_player.role])
	_input.push(packet().merged({"frames": history}, true), at)
	if time_economy != null:
		for role in saved["time"]: time_economy.restore_account(role, saved["time"][role])
	var restored := Time.get_ticks_usec()
	_prepare_colliders()
	combat_prediction.restore_checkpoint(at, saved["projectiles"])
	var prepared := Time.get_ticks_usec()
	for tick in _states.keys():
		if tick > at: _states.erase(tick)
	for tick in _commands.keys():
		if tick > at: _commands.erase(tick)
	for tick in _hitboxes.keys():
		if tick > at: _hitboxes.erase(tick)
	_sim_tick = at
	diagnostics = {"reason": "", "replay_ticks": 0, "checkpoint_tick": at,
			"reused_ticks": at - _authority_tick}
	while _sim_tick < int(_clock):
		_sim_tick += 1
		diagnostics["replay_ticks"] += 1
		_step(_input.take(_sim_tick), true)
	_player.rebase_visual_step(previous)
	var finished := Time.get_ticks_usec()
	diagnostics.merge({"restore_ms": (restored - started) / 1000.0,
			"combat_ms": (prepared - restored) / 1000.0, "replay_ms": (finished - prepared) / 1000.0})

func reconcile(own: Dictionary, tick: int, ping_ms: int, reuse: bool = false, projectiles: Variant = null) -> bool:
	_authority_tick = tick
	var changed: bool = own["epoch"] != epoch
	diagnostics = {"reason": "epoch" if changed else "", "replay_ticks": 0}
	if changed:
		reset(own["epoch"], own["ack"], tick, ping_ms)
	var desired := tick + minf(ceilf(ping_ms * 0.06) + MARGIN, MAX_REPLAY)
	if _clock < tick or int(_clock) - tick > MAX_REPLAY:
		diagnostics["reason"] = "clock"
		_clock = desired
		history.clear()
		sent.clear()
		actions.clear()
		_discarded_through = 0
		_clock_correction_seq = sequence
	if own["timing_seq"] > _timing_seq and own["timing_seq"] > _clock_correction_seq:
		_timing_seq = own["timing_seq"]
		_lead = lerpf(_lead, own["lead"], 0.1)
		_rate = 1.02 if _lead < MARGIN - 1.0 else 0.96 if _lead > MARGIN + 1.0 else 1.0
	history = history.filter(func(record: Dictionary) -> bool: return record["seq"] > own["ack"])
	sent = sent.filter(func(record: Dictionary) -> bool: return record["seq"] > own["ack"])
	actions = actions.filter(func(action: Dictionary) -> bool:
		return action["seq"] > own["action_ack"] and tick - action["target_tick"] <= InputBuffer.ACTION_TICKS)
	if reuse and not changed and diagnostics["reason"].is_empty() and not own["rewind"]:
		var through := _reuse_tick
		var partial := through < _sim_tick
		_commit_reuse(partial)
		if partial: replay_from(through + 1)
		if terrain != null: terrain.acknowledge(tick)
		combat_prediction.acknowledge(tick)
		diagnostics["reused_ticks"] = maxi(through - tick, 0)
		diagnostics["reuse"] = reuse_detail
		reuse_totals["prefix" if partial else "full"] += 1
		reuse_totals["saved_ticks"] += diagnostics["reused_ticks"]
		if partial: reuse_totals["prefix_saved_ticks"] += diagnostics["reused_ticks"]
		reuse_totals["replayed_ticks"] += diagnostics["replay_ticks"]
		_discarded_through = 0
		return false
	var previous := _player.global_position
	var started := Time.get_ticks_usec()
	_player.restore_state(own["state"])
	var restored := Time.get_ticks_usec()
	_prepare_colliders()
	combat_prediction.prepare(tick, projectiles)
	var prepared := Time.get_ticks_usec()
	_input.restore_authority(epoch, own["ack"], own["action_ack"], own["input"], tick)
	_input.push({"frames": history, "actions": actions}, tick)
	_sim_tick = tick
	_states.clear()
	_commands.clear()
	for at in _hitboxes.keys():
		if at >= tick: _hitboxes.erase(at)
	_remember_state()
	if own["ack"] < _discarded_through or own["rewind"]:
		diagnostics["reason"] = "rewind" if own["rewind"] else "history"
		history.clear()
		_sim_tick = int(_clock)
	else:
		while _sim_tick < int(_clock):
			diagnostics["replay_ticks"] += 1
			_sim_tick += 1
			_step(_input.take(_sim_tick), true)
	_player.rebase_visual_step(previous)
	var finished := Time.get_ticks_usec()
	diagnostics.merge({"restore_ms": (restored - started) / 1000.0,
			"combat_ms": (prepared - restored) / 1000.0, "replay_ms": (finished - prepared) / 1000.0})
	_discarded_through = 0
	return changed or own["rewind"]

func _prepare_colliders() -> void:
	_roles = _replicas.keys()
	_roles.sort()
	_actor_roles = _roles.duplicate()
	_actor_roles.append(_player.role)
	_actor_roles.sort()
	combat_prediction.actors = {_player.role: _player}
	combat_prediction.time_economy = time_economy
	var colliders: Array[ActorCollider] = []
	var history_remotes: Array = []
	if _collision_anchor != null: colliders.append(_collision_anchor)
	for role in _roles:
		var replica: Node2D = _replicas[role]
		colliders.append(replica._ghost)
		combat_prediction.actors[role] = replica._forecast
		history_remotes.append([role, replica._forecast, replica._ghost, replica._respawn_tick])
	_player.actor_colliders = colliders
	_native_history.configure_remotes(history_remotes)

func accept_proxies(frame: Dictionary) -> void:
	var actors: Dictionary = frame["world"]["players"]
	for role in _replicas:
		if actors.has(role): _replicas[role].apply_snapshot(actors[role], _player.global_position, frame["tick"])
		else: _replicas[role].set_ghost_layer(0)
	_prepare_colliders()

func _sample_proxies(at: int, movement: bool = false) -> void:
	for role in _roles:
		# 服务器按角色编号依次移动；本地阶段尚未移动的代理读取前一 tick。
		_replicas[role].anchor_collision(_player.global_position, at - int(movement and role > _player.role))
		if _replicas[role]._respawn_tick > 0 and at > _replicas[role]._respawn_tick:
			_replicas[role]._ghost.collision_layer = 0

func _remote_players() -> Array:
	var result: Array = []
	for role in _roles:
		if _replicas[role]._ghost.collision_layer != 0: result.append(_replicas[role]._forecast)
	return result

func _local_time_state() -> Dictionary:
	if time_economy == null or not time_economy.accounts.has(_player.role): return {}
	return {_player.role: time_economy.account_payload(_player.role)}

func _step(record: Dictionary, replay: bool = false) -> Array:
	var started := Time.get_ticks_usec() if profile_steps else 0
	var commands := {_player.role: record}
	var beams := {}
	var shots := {}
	var trace := {"valid": time_economy != null, "haste": {}, "rewind": {}, "rewards": []}
	combat_prediction.tick = _sim_tick
	combat_prediction.begin_tick(_sim_tick)
	_sample_proxies(_sim_tick, true)
	_players = _remote_players()
	_players.append(_player)
	var result: Array = []
	var actor_us := 0
	for role in _actor_roles:
		trace["haste"][role] = [true, 1.0]
		if role == _player.role:
			var actor_started := Time.get_ticks_usec() if profile_steps else 0
			var locked := _player._controls_locked
			if time_economy != null: time_economy.step_haste(_player, record, ActorStep.DT)
			result = ActorStep.step(_player, record)
			if profile_steps: actor_us = Time.get_ticks_usec() - actor_started
			if FrameTrace.enabled: FrameTrace.span(&"local_actor", actor_started, actor_started + actor_us)
			trace["haste"][role] = [locked, _player.pvp_haste_mult]
			if result.any(func(action: Dictionary) -> bool: return action["kind"] == "fire"): shots[role] = true
			combat_prediction.shot_actions(_player, result, _sim_tick)
		if combat_prediction.step_beams(_sim_tick, role, _players): beams[role] = true
		trace["rewards"].append_array(combat_prediction.step_rewards(_sim_tick, role))
	if time_economy != null:
		trace["rewind"][_player.role] = [(record["held"] & PacketInputSource.BIT_REWIND) != 0
				and not _player._controls_locked and not _player.is_downed(), false]
		time_economy.accounts[_player.role].regen(ActorStep.DT)
	_sample_proxies(_sim_tick)
	_players = _remote_players()
	_players.append(_player)
	_native_history.capture_hitboxes(_sim_tick, _players)
	var combat_started := Time.get_ticks_usec() if profile_steps else 0
	combat_prediction.step(_sim_tick, _players, not replay)
	var projectiles_finished := Time.get_ticks_usec() if FrameTrace.enabled else 0
	trace["rewards"].append_array(combat_prediction.step_rewards(_sim_tick, 0))
	trace["rewards"].append_array(combat_prediction.step_rewards(_sim_tick, -1))
	var terrain_started := Time.get_ticks_usec() if FrameTrace.enabled else 0
	tick_finished.emit()
	if FrameTrace.enabled:
		FrameTrace.span(&"combat_simulation", combat_started, projectiles_finished)
		FrameTrace.span(&"terrain_collision_commit", terrain_started, Time.get_ticks_usec())
	_commands[_sim_tick] = {"inputs": commands, "beams": beams, "shots": shots, "economy": trace,
			"actor_queries": _player.actor_queries.duplicate()}
	_commands.erase(_sim_tick - KEEP)
	var remember_started := Time.get_ticks_usec() if profile_steps else 0
	_remember_state()
	if profile_steps:
		var finished := Time.get_ticks_usec()
		var costs: Dictionary = diagnostics.get_or_add("step_profile", {"ticks": 0, "actors_us": 0,
				"attacks_us": 0, "projectiles_us": 0, "remember_us": 0, "total_us": 0})
		costs["ticks"] += 1
		costs["actors_us"] += actor_us
		costs["attacks_us"] += combat_started - started - actor_us
		costs["projectiles_us"] += remember_started - combat_started
		costs["remember_us"] += finished - remember_started
		costs["total_us"] += finished - started
		if FrameTrace.enabled:
			FrameTrace.span(&"prediction_step", started, finished)
			FrameTrace.span(&"projectile_step", combat_started, remember_started)
			FrameTrace.span(&"remember_state", remember_started, finished)
			FrameTrace.count(&"replay_ticks" if replay else &"forward_ticks")
	return result

func _remember_state() -> void:
	_native_history.remember(_sim_tick, _player, _player.weapons.current_inst(),
			_player.weapons.snapshot_inventory(true), _cursor(_input), _local_time_state(),
			terrain_revision, CollisionBuilder.geometry_revision, terrain.generation if terrain != null else 0)
	if terrain != null: terrain.prune_before(_sim_tick - KEEP)
