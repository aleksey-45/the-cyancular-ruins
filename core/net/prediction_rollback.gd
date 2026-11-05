class_name PredictionRollback
extends RefCounted
const KEEP := 64
const MAX_REPLAY := 32
const MARGIN := 2.0
var history: Array = []
var epoch := 1
var sequence := 0
var sent: Array = []
var actions: Array = []
var _clock := 0.0
var world := PredictionWorld.new()
var _authority_tick := 0
var _lead := MARGIN
var _rate := 1.0
var _timing_seq := 0
var _clock_correction_seq := 0
var _discarded_through := 0
var _input := InputBuffer.new()
var _player: Player
var _states: Dictionary[int, PredictionFrame]:
	get: return world.history.frames
var _last_reject: Dictionary = {}
var terrain: Terrain:
	get: return world.terrain
	set(value): world.terrain = value
var time_economy: TimeEconomy:
	get: return world.time_economy
	set(value): world.time_economy = value
var combat_prediction: CombatPrediction:
	get: return world.combat
var replay_ticks := 0

func bind(player: Player) -> void:
	_player = player
	world.bind(player)

func reset(new_epoch: int, ack: int, tick: int, ping_ms: int) -> void:
	epoch = new_epoch
	sequence = ack
	sent.clear()
	history.clear()
	actions.clear()
	_input.reset(epoch)
	_authority_tick = tick
	_clock = tick + minf(ceilf(ping_ms * 0.06) + MARGIN, MAX_REPLAY)
	world.reset(tick)
	_lead = MARGIN
	_rate = 1.0
	_timing_seq = 0
	_clock_correction_seq = 0
	_discarded_through = 0

func capture(source: PlayerInput, aim: Vector2, weapon_inst: int) -> void:
	actions = actions.filter(func(action: Dictionary) -> bool:
		return sequence - action["seq"] <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS)
	sequence += 1
	var record := PacketInputSource.pack_record(source, sequence, aim)
	record["epoch"] = epoch
	record["target_tick"] = mini(int(_clock) + 1, _authority_tick + MAX_REPLAY)
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
	var previous_tick := world.tick
	_clock = minf(_clock + delta * 60.0 * _rate, _authority_tick + MAX_REPLAY)
	if world.tick < int(_clock):
		_input.push(packet(), world.tick)
	while world.tick < int(_clock):
		_player.begin_visual_step()
		_player.execute_actions(_step(_input.take(world.tick + 1)))
	if world.tick == previous_tick and _clock >= _authority_tick + MAX_REPLAY:
		_player.begin_visual_step()

# 比较不改动物理世界；所有角色和预测玩法都相等才保留后缀。
func reusable_tick(frame: Dictionary, invalid_from: int = 0) -> int:
	_last_reject = {"tick": int(frame["tick"]), "sim": world.tick,
			"clock": snappedf(_clock, 2), "n": _states.size()}
	var tick: int = frame["tick"]
	var own: Dictionary = frame["own"]
	if not _states.has(tick): return _reject_reuse("no_tick")
	if own["epoch"] != epoch: return _reject_reuse("epoch")
	if _clock < tick or int(_clock) - tick > MAX_REPLAY or own["ack"] < _discarded_through:
		return _reject_reuse("clock")
	if invalid_from > tick: return _reject_reuse("event")
	var saved := _states[tick]
	var error := terrain.difference(tick, saved.terrain_generation, frame["map_revision"])
	if not error.is_empty(): return _reject_reuse("terrain")
	var field := Player.prediction_difference(saved.player, own["state"])
	if not field.is_empty():
		_last_reject["field"] = field
		return _reject_reuse("fields")
	var remote_field := world.difference(saved, frame)
	if not remote_field.is_empty(): return _reject_reuse(remote_field)
	var cursor := InputBuffer.new()
	cursor.restore_authority(epoch, own["ack"], own["action_ack"], own["input"], tick)
	if saved.cursor != cursor.capture_cursor(): return _reject_reuse("input")
	if not saved.projectiles.matches(frame["world"]["projectiles"]): return _reject_reuse("projectiles")
	var accounts := {}
	if frame["time"].has(_player.role): accounts[_player.role] = frame["time"][_player.role]
	if saved.time != accounts: return _reject_reuse("economy")
	return world.tick

func _reject_reuse(tag: String = "") -> int:
	if tag != "":
		corr_reject[tag] = int(corr_reject.get(tag, 0)) + 1
		_last_reject["tag"] = tag
	return -1

func confirm_projectile(id: int, state: Dictionary, at_tick: int, owner: Node2D) -> bool:
	var same: bool = _states.has(at_tick) and _states[at_tick].projectiles.state_matches(id, state)
	var changed := combat_prediction.checkpoint_projectile(id, state, at_tick, owner)
	return changed and not same

# 奖励也由世界重放按原阶段入账，不原地修补历史账户。
func review_rewards() -> int:
	var first := 0
	for serial in combat_prediction.reward_changes:
		for reward: Dictionary in [combat_prediction.reward_changes[serial], combat_prediction.rewards[serial]]:
			if reward.is_empty() or reward["role"] != _player.role:
				continue
			var at: int = reward["tick"]
			if _authority_tick < at and at <= world.tick:
				first = at if first == 0 else mini(first, at)
	combat_prediction.reward_changes.clear()
	return first

func bullet_rewind_matches(data: Dictionary) -> bool:
	var at: int = data["tick"]
	var role: int = data["role"]
	if not _states.has(at): return false
	if not _states[at].projectiles.matches(data["projectiles"], role): return false
	for id in data["projectiles"]:
		if not combat_prediction.projectiles.has(id): return false
	if not world.actors.has(role) or world.actor(role).rewinding != data["rewind"]: return false
	for tick in range(at + 1, world.tick + 1):
		if not _states.has(tick): return false
		if role != _player.role and not _states[tick].remote.has(role): return false
		var mode: bool = _states[tick].rewinding if role == _player.role else _states[tick].remote[role][PredictionActorState.REWIND]
		if mode != data["rewind"]: return false
	return true

func can_replay_from(dirty_tick: int) -> bool:
	var at := dirty_tick - 1
	if at < _authority_tick or not _states.has(at):
		return false
	var saved := _states[at]
	if saved.cursor[0] != epoch or _discarded_through > saved.cursor[1]:
		return false
	return terrain.can_restore(at, saved.terrain_generation) and combat_prediction.can_restore_checkpoint(at, saved.projectiles)

func replay_from(dirty_tick: int) -> void:
	var perf_started := PerformanceStats.begin()
	var at := dirty_tick - 1
	var saved := _states[at]
	var previous := _player.global_position
	world.restore(saved)
	_input.restore_cursor(saved.cursor)
	_input.push({"frames": history, "actions": actions}, at)
	world.history.discard_after(at)
	_replay_to_clock()
	_player.rebase_visual_step(previous)
	PerformanceStats.end(PerformanceStats.REPLAY, perf_started)

static var corr_n := 0
static var corr_sum := 0.0
static var corr_max := 0.0
# 只保留当前导出窗口的原始样本，由 PerfMonitor 每秒取走。
static var corr_list: Array[Dictionary] = []
static var corr_reasons := {}
static var corr_reject := {}
static var corr_pos_ctx := {}
static var corr_gap := {}

static func reset_correction_stats() -> void:
	corr_n = 0
	corr_sum = 0.0
	corr_max = 0.0
	corr_list.clear()
	corr_reasons.clear()
	corr_reject.clear()
	corr_pos_ctx.clear()
	corr_gap.clear()


static func take_correction_samples() -> Array:
	var samples: Array = corr_list.duplicate()
	corr_list.clear()
	return samples


static func corr_stats() -> Dictionary:
	return {"n": corr_n, "sum": corr_sum, "max": corr_max, "reasons": corr_reasons.duplicate(),
			"reject": corr_reject.duplicate(), "pos_ctx": corr_pos_ctx.duplicate(),
			"gap": corr_gap.duplicate()}

func _corr_record(tick: int, authoritative: Array, own: Dictionary, reuse: bool,
		trigger: String = "state", ctx: Dictionary = {}) -> void:
	# 校正统计属于观测数据，只有显式开启性能统计时才记录。
	if not PerformanceStats.is_enabled():
		return
	var sample := {"t": tick, "sim": int(ctx.get("sim", world.tick)),
			"clk": snappedf(float(ctx.get("clock", _clock)), 2),
			"auth": int(ctx.get("auth", _authority_tick)),
			"trig": trigger, "reuse": reuse, "rew": bool(own["rewind"]),
			"ack": int(own["ack"]), "seq": sequence, "ep": epoch,
			"n": _states.size(), "lo": 0, "hi": 0,
			"hist": int(ctx.get("history", 0)), "hist2": history.size(),
			"disc": int(ctx.get("discarded", 0)),
			"cr": bool(ctx.get("clock_reset", false)), "chg": bool(ctx.get("changed", false)),
			"role": _player.role, "ms": Time.get_ticks_msec(),
		"pf": Engine.get_physics_frames()}
	if not _states.is_empty():
		var keys: Array = _states.keys()
		sample["lo"] = int(keys.min())
		sample["hi"] = int(keys.max())
	var lo: int = sample["lo"]
	var hi: int = sample["hi"]
	if sample["n"] == 0:
		sample["gap"] = "none"
	elif tick > hi:
		sample["gap"] = "ahead"
		sample["ahead"] = tick - hi
	elif tick < lo:
		sample["gap"] = "old"
		sample["behind"] = lo - tick
	elif _states.has(tick):
		sample["gap"] = "ok"
	else:
		sample["gap"] = "gap"
	sample["lag"] = tick - int(sample["sim"])
	sample["clag"] = snappedf(float(tick) - float(sample["clk"]), 2)
	if authoritative.size() > PlayerStateSchema.slot("pos"):
		var apos: Vector2 = authoritative[PlayerStateSchema.slot("pos")]
		sample["apos"] = [snappedf(apos.x, 1), snappedf(apos.y, 1)]
		sample["afloor"] = bool(authoritative[PlayerStateSchema.slot("floor")])
		sample["hp"] = int(authoritative[PlayerStateSchema.slot("hp")])
	if _player != null:
		sample["cpos"] = [snappedf(_player.global_position.x, 1), snappedf(_player.global_position.y, 1)]
		sample["onfloor"] = _player._grounded
		sample["ax"] = snappedf(float(_input._last["ax"]), 2)
		sample["held"] = int(_input._last["held"])
	# 近身聚集上下文：最近距离与 64/128/256px 内的人数。
	var nearest := 1.0e12
	var n64 := 0
	var n128 := 0
	var n256 := 0
	for other: ActorBody in world.actors.values():
		if other == _player or other.collision_layer == 0: continue
		var gap_px := GridPathfinder.toroidal_delta_px(_player.global_position,
				(other as Node2D).global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		nearest = minf(nearest, gap_px)
		if gap_px < 64.0: n64 += 1
		if gap_px < 128.0: n128 += 1
		if gap_px < 256.0: n256 += 1
	sample["near"] = snappedf(nearest, 1)
	sample["n64"] = n64
	sample["n128"] = n128
	sample["n256"] = n256
	sample["skip"] = false
	sample["jump"] = maxi(0, int(sample["clk"]) - tick) if sample["skip"] else 0
	var g: Array = corr_gap.get(sample["gap"], [0, 0, 0.0, 0.0])
	g[0] = int(g[0]) + 1
	g[1] = maxi(int(g[1]), int(sample.get("ahead", 0)))
	g[2] = maxf(float(g[2]), float(sample["lag"]))
	g[3] = maxf(float(g[3]), float(sample["clag"]))
	corr_gap[sample["gap"]] = g
	if not _states.has(tick):
		sample["f"] = "no_state"
		sample["rej"] = _last_reject.duplicate()
		corr_list.append(sample)
		_note_reason("no_state", 0.0)
		return
	var predicted: Vector2 = _states[tick].player[0]
	var delta := GridPathfinder.toroidal_delta_px(predicted, authoritative[PlayerStateSchema.slot("pos")],
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
	corr_n += 1
	corr_sum += delta
	corr_max = maxf(corr_max, delta)
	var field: String = Player.prediction_difference(_states[tick].player, authoritative)
	if field == "":
		if own["rewind"]:
			field = "rewind"
		elif not reuse:
			field = "reuse_rejected"
		else:
			field = "other"
	sample["f"] = field
	sample["d"] = delta
	var pvel: Vector2 = _states[tick].player[PlayerStateSchema.slot("vel")]
	var avel: Vector2 = authoritative[PlayerStateSchema.slot("vel")]
	sample["ppos"] = [snappedf(predicted.x, 1), snappedf(predicted.y, 1)]
	sample["pvel"] = [snappedf(pvel.x, 1), snappedf(pvel.y, 1)]
	sample["avel"] = [snappedf(avel.x, 1), snappedf(avel.y, 1)]
	sample["vd"] = snappedf(pvel.distance_to(avel), 1)
	if PlayerStateSchema.INDEX.has(field):
		var slot := PlayerStateSchema.slot(field)
		# 本地预测记录只到 37 槽，广播状态还带表现字段。
		if slot < _states[tick].player.size() and slot < authoritative.size():
			sample["pv"] = str(_states[tick].player[slot])
			sample["av"] = str(authoritative[slot])
	if field == "pos":
		var band := "<64" if nearest < 64.0 else ("64-256" if nearest < 256.0 else ("256-1024" if nearest < 1024.0 else ">1024"))
		var vdelta: float = sample["vd"]
		var key := "%s|%s|%s" % [band, "floor" if _player._grounded else "air",
				"velok" if vdelta < 20.0 else "veldiff"]
		corr_pos_ctx[key] = int(corr_pos_ctx.get(key, 0)) + 1
		sample["band"] = band
	corr_list.append(sample)
	_note_reason(field, delta)

func _note_reason(reason: String, px: float) -> void:
	var e: Array = corr_reasons.get(reason, [0, 0.0])
	e[0] = int(e[0]) + 1
	e[1] = float(e[1]) + px
	corr_reasons[reason] = e

func reconcile(frame: Dictionary, ping_ms: int, reuse: bool, trigger: String = "state") -> bool:
	var own: Dictionary = frame["own"]
	var tick: int = frame["tick"]
	var diag := {"sim": world.tick, "clock": _clock, "auth": _authority_tick,
			"changed": false, "clock_reset": false, "history": history.size(),
			"discarded": _discarded_through}
	_authority_tick = tick
	var changed: bool = own["epoch"] != epoch
	diag["changed"] = changed
	replay_ticks = 0
	if changed:
		reset(own["epoch"], own["ack"], tick, ping_ms)
	var desired := tick + minf(ceilf(ping_ms * 0.06) + MARGIN, MAX_REPLAY)
	var clock_reset: bool = _clock < tick or int(_clock) - tick > MAX_REPLAY or own["ack"] < _discarded_through
	diag["clock_reset"] = clock_reset
	if clock_reset:
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
	if reuse and not changed and not clock_reset:
		# 输入游标和物理世界都保留在预测末端，不再次消费已模拟的输入。
		world.accept_rewind_paths(frame)
		terrain.acknowledge(tick)
		combat_prediction.acknowledge(tick)
		world.acknowledge(tick)
		_discarded_through = 0
		return false
	var perf_started := PerformanceStats.begin()
	diag["history_after"] = history.size()
	_corr_record(tick, own["state"], own, reuse, trigger, diag)
	var previous := _player.global_position
	world.restore_authority(frame)
	_input.restore_authority(epoch, own["ack"], own["action_ack"], own["input"], tick)
	_input.push({"frames": history, "actions": actions}, tick)
	_states.clear()
	_remember_state()
	_replay_to_clock()
	_player.rebase_visual_step(previous)
	_discarded_through = 0
	PerformanceStats.end(PerformanceStats.REPLAY, perf_started)
	return changed or own["rewind"]

func _replay_to_clock() -> void:
	replay_ticks = 0
	while world.tick < int(_clock):
		replay_ticks += 1
		_step(_input.take(world.tick + 1), true)
	PerformanceStats.replayed(replay_ticks)

func _step(record: Dictionary, replay: bool = false) -> Array:
	var result := world.step_tick(record, replay)
	_remember_state()
	return result

func _remember_state() -> void:
	var started := PerformanceStats.begin()
	world.history.remember(world.capture(_input.capture_cursor()), KEEP)
	terrain.prune_before(world.tick - KEEP)
	PerformanceStats.end(PerformanceStats.HISTORY_SAVE, started)
