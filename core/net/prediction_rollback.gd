class_name PredictionRollback
extends RefCounted

signal step_advanced(from: Vector2, presentation: Array)

const NetPlayer := PlayerStateSchema.Network
const End := CombatSimulator.ProjectileEnd
const Blast := CombatSimulator.Blast
const KEEP := 64
const MAX_REPLAY := 32
const REMOTE_FORECAST := 6

enum Correction { KEEP, SMOOTH, SNAP }

var tick: int:
	get: return combat.tick
var sequence := 0
var history: Array = []
var actions: Array = []
var time_economy: TimeEconomy
var combat: CombatSimulator
var replay_ticks := 0

var _states: Array[PredictionFrame] = []
var _clock := InputClock.new()
var _epoch := -1
var _render_tick := 0
var _clock_step := 1.0
var _discarded_through := 0
var _player: Player
var _authority_frame: Dictionary
var _hits: Dictionary[int, Array] = {}
var _shots: Dictionary[int, Dictionary] = {}
var _projectile_ends: Dictionary[int, Array] = {}
var _replay_tick := 0

func _init() -> void:
	_states.resize(KEEP)

func bind(player: Player) -> void:
	_player = player
	combat = player.combat
	combat.predicting = true

func reset(frame: Dictionary, ping_ms: int, keep_events := false) -> void:
	var own: Array = frame["world"]["players"][_player.role]
	var confirmed_seq := maxi(own[NetPlayer.INPUT][InputBuffer.SEQ], own[NetPlayer.ACTION_ACK])
	if _epoch != own[NetPlayer.EPOCH] or confirmed_seq > sequence:
		_epoch = own[NetPlayer.EPOCH]
		sequence = confirmed_seq
		history.clear()
		actions.clear()
		_clock.reset(frame["tick"], sequence, ping_ms, frame["input_feedback"])
	else:
		_clock.synchronize(frame["tick"], sequence, frame["input_feedback"])
		history = history.filter(func(row: Array) -> bool: return row[InputBuffer.SEQ] > own[NetPlayer.INPUT][InputBuffer.SEQ])
		actions = actions.filter(func(row: Array) -> bool: return row[InputBuffer.SEQ] > own[NetPlayer.ACTION_ACK])
	if not keep_events:
		_hits.clear()
		_shots.clear()
		_projectile_ends.clear()
	_anchor(frame, _state_at(frame["tick"]) if keep_events else null)

func _anchor(frame: Dictionary, saved: PredictionFrame) -> void:
	_authority_frame = frame
	_render_tick = frame["tick"]
	_clock_step = 1.0
	_discarded_through = 0
	_restore(_authority_checkpoint(frame, saved))

func capture(record: Array) -> void:
	actions = actions.filter(func(action: Array) -> bool:
		return sequence - action[InputBuffer.SEQ] <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS)
	sequence += 1
	var epoch := _player.input_buffer.epoch
	var pressed: int = record[ActorInput.PRESSED]
	var released: int = record[ActorInput.RELEASED]
	var weapon_inst: int = record[ActorInput.WINST]
	var target := _clock.sample(sequence, record)
	var aim: Vector2 = record[ActorInput.AIM]
	if pressed != 0 or released != 0 or weapon_inst != 0:
		if weapon_inst == 0 and (pressed | released) & (ActorInput.BIT_ATTACK | ActorInput.BIT_RELOAD | ActorInput.BIT_DROP):
			weapon_inst = _player.weapons.current_inst()
		actions.append([sequence, epoch, target, pressed, released, weapon_inst, aim])
	history.append([sequence, epoch, target, record[ActorInput.AX], record[ActorInput.HELD], aim])
	if history.size() > KEEP:
		_discarded_through = history.pop_front()[InputBuffer.SEQ]

func packet() -> Array:
	return [history.slice(-InputBuffer.REDUNDANCY), actions]

func render_offset(interpolation: float) -> float:
	return _render_tick - _clock_step * (1.0 - interpolation) - tick

func advance(delta: float) -> void:
	var previous_tick := tick
	var limit: int = _authority_frame["tick"] + MAX_REPLAY
	_render_tick = _clock.advance(delta, tick, limit)
	_clock_step = clampf(_render_tick - previous_tick, 0.0, 1.0)
	if _player.rewinding:
		return
	# 本地历史独立于上行冗余长度。预测窗口恢复后也能取回先前尚未入缓冲的样本。
	_player.input_buffer.push([history, actions], tick)
	while tick < _render_tick:
		var from := _player.position
		step_advanced.emit(from, _step())
	if tick == previous_tick and _render_tick >= limit:
		step_advanced.emit(_player.position, [])

func reconcile(frame: Dictionary, ping_ms: int) -> Correction:
	if frame.is_empty():
		if _replay_tick == 0 or _player.rewinding \
				or _authority_frame["world"]["players"][_player.role][NetPlayer.INPUT][InputBuffer.SEQ] < _discarded_through:
			return Correction.KEEP
		return _replay(_replay_tick, "combat", _authority_checkpoint(_authority_frame, _state_at(_authority_frame["tick"])))
	var players: Dictionary = frame["world"]["players"]
	var own: Array = players[_player.role]
	var at: int = frame["tick"]
	for hit_tick: int in _hits.keys():
		if hit_tick <= at:
			_hits.erase(hit_tick)
	if own[NetPlayer.EPOCH] != _player.input_buffer.epoch:
		reset(frame, ping_ms, true)
		return Correction.SNAP
	_clock.synchronize(at, sequence, frame["input_feedback"])
	var input: Array = own[NetPlayer.INPUT]
	var input_seq: int = input[InputBuffer.SEQ]
	var action_ack: int = own[NetPlayer.ACTION_ACK]
	var fresh_anchor: bool = at > tick or tick - at >= KEEP or input_seq < _discarded_through
	history = history.filter(func(record: Array) -> bool: return record[InputBuffer.SEQ] > input_seq)
	actions = actions.filter(func(action: Array) -> bool:
		return action[InputBuffer.SEQ] > action_ack and at - action[InputBuffer.TARGET_TICK] < InputBuffer.ACTION_TICKS)
	var saved := _state_at(at)
	if fresh_anchor or saved == null or own[NetPlayer.REWIND] or _player.rewinding:
		_anchor(frame, saved)
		return Correction.SNAP
	var forecast_extended: bool = at > _authority_frame["tick"] and tick > at \
			and tick > _authority_frame["tick"] + REMOTE_FORECAST
	_authority_frame = frame
	var predicted: Array = saved.players[_player.role]
	var map_size := _player.terrain.map_size
	var difference := PredictionFrame.difference(predicted[NetPlayer.STATE], own[NetPlayer.STATE], map_size)
	if difference.is_empty() and (predicted[NetPlayer.INPUT] != input or predicted[NetPlayer.ACTION_ACK] != action_ack):
		difference = "input"
	if difference.is_empty() and time_economy != null and saved.accounts[_player.role] != frame["time"][_player.role]:
		difference = "economy"
	var local_changed := not difference.is_empty()
	if not local_changed and (saved.accounts != frame["time"] or (players.size() > 1 and forecast_extended)
			or _players_differ(saved.players, players, map_size, _player.role)):
		difference = "players"
	var checkpoint := _authority_checkpoint(frame, saved)
	if difference.is_empty() and (saved.projectiles != checkpoint.projectiles
			or saved.pending_blasts != checkpoint.pending_blasts):
		difference = "projectiles"
	if difference.is_empty() and saved.beams != checkpoint.beams:
		difference = "beams"
	# 快照确定重放起点。迟到事件也可能影响快照之后的预测。
	if difference.is_empty() and _replay_tick == 0:
		replay_ticks = 0
		_retire_events()
		return Correction.KEEP
	return _replay(at, "combat" if difference.is_empty() else difference, checkpoint, local_changed)

static func _players_differ(saved: Dictionary, players: Dictionary, map_size: Vector2, local_role: int) -> bool:
	if saved.size() != players.size():
		return true
	for role: int in players:
		if not saved.has(role):
			return true
		var predicted: Array = saved[role]
		var authority: Array = players[role]
		if predicted == authority:
			continue
		for field in NetPlayer.STATE:
			if predicted[field] != authority[field]:
				return true
		if role != local_role and not PredictionFrame.difference(predicted[NetPlayer.STATE], authority[NetPlayer.STATE], map_size, true).is_empty():
			return true
	return false

func queue_event(kind: int, event: Dictionary) -> void:
	var at: int = event["tick"]
	var authority_tick: int = _authority_frame["tick"]
	match kind:
		NetEvent.Kind.FIRE:
			var id := ShotRules.shot_id(event["role"], event["serial"])
			_shots[id] = event
			var saved := _state_at(at)
			var predicted: Dictionary = saved.shots.get(id, {}) if saved != null else {}
			if predicted.merged(event, true) == predicted:
				return
		NetEvent.Kind.HIT:
			var victim: Player = combat.players.get(event["victim"])
			if at <= authority_tick or victim == null or event["epoch"] < victim.input_buffer.epoch:
				return
			_hits.get_or_add(at, []).append(event)
			if event["epoch"] != victim.input_buffer.epoch:
				return
		NetEvent.Kind.BULLET_END, NetEvent.Kind.EXPLOSION:
			var explosion := kind == NetEvent.Kind.EXPLOSION
			var ids: Array = [event["id"]] if explosion else event["ids"]
			var blast := CombatSimulator.blast_state(event["type_id"], event["pos"], at) if explosion else []
			var check_tick := maxi(at, authority_tick)
			var saved := _state_at(check_tick)
			var remaining := blast if not blast.is_empty() and blast[Blast.DUE] > check_tick else []
			var changed := false
			for id: int in ids:
				if at < projectile_end_tick(id):
					continue
				_projectile_ends[id] = [at, blast]
				changed = changed or saved == null or saved.projectiles.has(id) \
						or saved.pending_blasts.get(id, []) != remaining
			if not changed:
				return
		NetEvent.Kind.TERRAIN:
			var terrain := combat.terrain
			if event["revision"] <= terrain.revision:
				return
			terrain.record_values(at, event["cells"])
			terrain.revision = event["revision"]
	if at <= tick:
		_request_replay(maxi(at, authority_tick))

func projectile_end_tick(id: int) -> int:
	return _projectile_ends[id][End.TICK] if _projectile_ends.has(id) else -1

func _request_replay(at: int) -> void:
	_replay_tick = maxi(_replay_tick, at)

func _replay(at: int, reason: String, checkpoint: PredictionFrame, local_changed := false) -> Correction:
	var started := PerformanceStats.begin()
	var before := _state_at(at) if PerformanceStats.is_enabled() else null
	var end := tick
	var endpoint := _state_at(end)
	_restore(checkpoint)
	while tick < end:
		_step()
		replay_ticks += 1
	var role := _player.role
	var corrected: bool = local_changed or endpoint == null \
			or endpoint.players[role][NetPlayer.STATE] != _state_at(end).players[role][NetPlayer.STATE]
	if corrected and before != null:
		_record_correction(at, before.players[role][NetPlayer.STATE], _state_at(at).players[role][NetPlayer.STATE], reason)
	PerformanceStats.replayed(replay_ticks)
	PerformanceStats.end(PerformanceStats.REPLAY, started)
	return Correction.SMOOTH if corrected else Correction.KEEP

func _restore(checkpoint: PredictionFrame) -> void:
	_replay_tick = 0
	replay_ticks = 0
	checkpoint.restore(combat)
	if time_economy != null:
		for role: int in checkpoint.players:
			time_economy.restore_account(role, checkpoint.accounts[role])
	_player.input_buffer.push([history, actions], tick)
	_retire_events()
	for shot: Dictionary in _shots.values():
		if tick - KEEP < shot["tick"] and shot["tick"] <= tick:
			combat.catch_up_shot(shot, _authority_frame["world"]["projectiles"], tick)
	_states.fill(null)
	_remember()

func _authority_checkpoint(frame: Dictionary, saved: PredictionFrame) -> PredictionFrame:
	var checkpoint := PredictionFrame.new()
	checkpoint.tick = frame["tick"]
	checkpoint.players = frame["world"]["players"]
	checkpoint.accounts = frame["time"]
	checkpoint.beams = frame["world"]["beams"]
	var live: Dictionary = frame["world"]["projectiles"]
	if saved != null:
		for id: int in saved.projectiles:
			var state := saved.projectiles[id]
			var sample: Array = live.get(id, [])
			var owner: Array = checkpoint.players.get(state[BulletBody.SNAP_OWNER], [])
			if not sample.is_empty() and sample[BulletBody.Network.TYPE] == state[BulletBody.SNAP_TYPE] \
					and not owner.is_empty() and not owner[NetPlayer.REWIND]:
				checkpoint.projectiles[id] = BulletBody.with_authoritative_pose(
						state, sample[BulletBody.Network.POS], sample[BulletBody.Network.VEL])
		for id: int in saved.pending_blasts:
			var owner: Array = checkpoint.players.get(ShotRules.shooter_role(id), [])
			if not live.has(id) and not owner.is_empty() \
					and ShotRules.shot_serial(id) <= owner[NetPlayer.STATE][PlayerStateSchema.SHOT_SERIAL]:
				checkpoint.pending_blasts[id] = saved.pending_blasts[id]
	for id: int in _projectile_ends:
		var end := _projectile_ends[id]
		if end[End.TICK] <= checkpoint.tick:
			checkpoint.projectiles.erase(id)
			var blast: Array = end[End.BLAST]
			if not blast.is_empty() and blast[Blast.DUE] > checkpoint.tick:
				checkpoint.pending_blasts[id] = blast
			else:
				checkpoint.pending_blasts.erase(id)
	return checkpoint

func _retire_events() -> void:
	var at: int = _authority_frame["tick"]
	combat.terrain.forget_through(at - KEEP)
	var live_shots := {}
	for id: int in _authority_frame["world"]["projectiles"]:
		live_shots[ShotRules.shot_from_projectile(id)] = true
	for id: int in _shots.keys():
		if _shots[id]["tick"] <= at and (not live_shots.has(id) or _shooter_rewinding(_authority_frame, ShotRules.shooter_role(id))):
			_shots.erase(id)
	for id: int in _projectile_ends.keys():
		if _projectile_ends[id][End.TICK] <= at:
			_projectile_ends.erase(id)

func _shooter_rewinding(frame: Dictionary, role: int) -> bool:
	var players: Dictionary = frame["world"]["players"]
	return players.has(role) and players[role][NetPlayer.REWIND]

func _step() -> Array:
	var next := tick + 1
	var inside_forecast: bool = next <= _authority_frame["tick"] + REMOTE_FORECAST
	var inputs := ActorStep.buffered_inputs(combat.players, next, _player, inside_forecast)
	if time_economy != null:
		time_economy.advance(combat.players, inputs)
	var shots := combat.step(inputs, _shots, _projectile_ends)
	_apply_hits(_hits.get(tick, []))
	for player: Player in combat.players.values():
		# 到达其他玩家的复活帧后，将其移出碰撞层，避免仍留在旧位置的形状挡住角色。
		if player != _player and player.respawn_tick == tick:
			player.collision_layer = 0
	_remember(shots)
	return _player.presentation_events

func _apply_hits(hits: Array) -> void:
	var confirmed := {}
	for hit: Dictionary in hits:
		var role: int = hit["victim"]
		var victim: Player = combat.players.get(role)
		if victim == null or hit["epoch"] != victim.input_buffer.epoch:
			continue
		confirmed[role] = true
		if victim != _player:
			victim.position = hit["pos"]
			victim.facing_direction = hit["facing"]
			victim.rewinding = false
		if victim != _player or hit["impulse_mode"] < 0:
			victim.velocity = hit["vel"]
		if victim != _player or hit["impulse_mode"] > 0:
			victim.motion_knock_velocity = hit["knock"]
		if not victim.apply_hit_health(hit["hp"]) and victim != _player:
			victim.sync_collision_geometry()
	for hit: Array in combat.predicted_hits:
		var target: Player = hit[0]
		if confirmed.has(target.role):
			continue
		target.apply_impulse(hit[1], hit[2])
		target.cancel_charge()

func _remember(shots := {}) -> void:
	var started := PerformanceStats.begin()
	var saved := PredictionFrame.new()
	saved.capture(combat)
	if time_economy != null:
		saved.accounts = time_economy.state_payload()
	saved.shots = shots
	_states[tick % KEEP] = saved
	PerformanceStats.end(PerformanceStats.HISTORY_SAVE, started)

func _state_at(at: int) -> PredictionFrame:
	var saved := _states[at % KEEP]
	return saved if saved != null and saved.tick == at else null

static var corr_n := 0
static var corr_sum := 0.0
static var corr_max := 0.0
static var corr_list: Array[Dictionary] = []
static var corr_reasons := {}

static func reset_correction_stats() -> void:
	corr_n = 0
	corr_sum = 0.0
	corr_max = 0.0
	corr_list.clear()
	corr_reasons.clear()

static func take_correction_samples() -> Array:
	var samples := corr_list
	corr_list = []
	return samples

static func corr_stats() -> Dictionary:
	return {"n": corr_n, "sum": corr_sum, "max": corr_max, "reasons": corr_reasons.duplicate()}

func _record_correction(at: int, predicted: Array, authoritative: Array, field: String) -> void:
	var pos := PlayerStateSchema.POS
	var before: Vector2 = predicted[pos]
	var after: Vector2 = authoritative[pos]
	var distance := GridPathfinder.toroidal_delta_px(before, after, _player.terrain.map_size).length()
	corr_n += 1
	corr_sum += distance
	corr_max = maxf(corr_max, distance)
	var entry: Array = corr_reasons.get(field, [0, 0.0])
	corr_reasons[field] = [entry[0] + 1, entry[1] + distance]
	corr_list.append({"t": at, "sim": tick, "f": field, "d": distance,
			"role": _player.role, "ms": Time.get_ticks_msec(), "pf": Engine.get_physics_frames()})
