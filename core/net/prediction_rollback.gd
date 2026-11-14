class_name PredictionRollback
extends RefCounted

const KEEP := 64
const MAX_REPLAY := 32
const MARGIN := 2.0

enum Correction { KEEP, SMOOTH, SNAP }

var tick := 0
var epoch := 1
var sequence := 0
var history: Array = []
var actions: Array = []
var time_economy: TimeEconomy
var combat: CombatSimulator
var proxy_motion: Dictionary[int, Dictionary] = {}
var replay_ticks := 0

var _states: Array[PredictionFrame] = []
var _clock := 0.0
var _lead := MARGIN
var _rate := 1.0
var _timing_seq := 0
var _discarded_through := 0
var _input := InputBuffer.new()
var _player: Player
var _prepare_step: Callable
var _authority_frame: Dictionary
var _hits: Dictionary[int, Array] = {}
var _shots: Dictionary[int, Dictionary] = {}
var _projectile_ends: Dictionary[int, Dictionary] = {}
var _replay_tick := 0
var _late_shot := false

func _init() -> void:
	_states.resize(KEEP)

func bind(player: Player, prepare_step := Callable(), simulator: CombatSimulator = null) -> void:
	_player = player
	_prepare_step = prepare_step
	combat = simulator
	if combat != null:
		combat.predicting = true
		combat.players[_player.role] = _player
		_player.projectile_count = combat.count_projectiles.bind(_player)

func reset(frame: Dictionary, ping_ms: int, keep_events := false) -> void:
	var own: Dictionary = frame["own"]
	epoch = own["epoch"]
	sequence = own["input"][InputBuffer.SEQ]
	history.clear()
	actions.clear()
	if not keep_events:
		_hits.clear()
		_shots.clear()
		_projectile_ends.clear()
		_states.fill(null)
	_anchor(frame, ping_ms)

func _anchor(frame: Dictionary, ping_ms: int) -> void:
	_authority_frame = frame
	_clock = frame["tick"] + minf(ceilf(ping_ms * 0.06) + MARGIN, MAX_REPLAY)
	_lead = MARGIN
	_rate = 1.0
	_timing_seq = frame["own"]["timing_seq"]
	_discarded_through = 0
	_restore()

func capture(record: Array) -> void:
	actions = actions.filter(func(action: Array) -> bool:
		return sequence - action[InputBuffer.SEQ] <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS)
	sequence += 1
	var target := mini(int(_clock) + 1, _authority_frame["tick"] + MAX_REPLAY)
	var pressed: int = record[ActorInput.PRESSED]
	var released: int = record[ActorInput.RELEASED]
	var weapon_inst: int = record[ActorInput.WINST]
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

func advance(delta: float, input: Array) -> void:
	var previous_tick := tick
	var limit: int = _authority_frame["tick"] + MAX_REPLAY
	_clock = minf(_clock + delta * 60.0 * _rate, limit)
	if _player.rewinding:
		return
	if tick < int(_clock):
		_input.push(input, tick)
	while tick < int(_clock):
		_player.begin_visual_step()
		_player.present_actions(_step())
	if tick == previous_tick and _clock >= limit:
		_player.begin_visual_step()

func reconcile(frame: Dictionary, ping_ms: int) -> Correction:
	if frame.is_empty():
		if _replay_tick == 0 or _player.rewinding \
				or _authority_frame["own"]["input"][InputBuffer.SEQ] < _discarded_through:
			return Correction.KEEP
		return _replay(_replay_tick, "combat")
	var own: Dictionary = frame["own"]
	var at: int = frame["tick"]
	replay_ticks = 0
	for hit_tick: int in _hits.keys():
		if hit_tick <= at:
			_hits.erase(hit_tick)
	for role: int in proxy_motion.keys():
		if proxy_motion[role]["tick"] <= at or not frame["world"]["players"].has(role):
			proxy_motion.erase(role)
	if own["epoch"] != epoch:
		reset(frame, ping_ms, true)
		return Correction.SNAP
	var input: Array = own["input"]
	var input_seq: int = input[InputBuffer.SEQ]
	var action_ack: int = own["action_ack"]
	var fresh_anchor: bool = at > tick or tick - at >= KEEP or input_seq < _discarded_through
	history = history.filter(func(record: Array) -> bool: return record[InputBuffer.SEQ] > input_seq)
	actions = actions.filter(func(action: Array) -> bool:
		return action[InputBuffer.SEQ] > action_ack and at - action[InputBuffer.TARGET_TICK] < InputBuffer.ACTION_TICKS)
	var saved := _state_at(at)
	if fresh_anchor or saved == null or own["rewind"] or _player.rewinding:
		_anchor(frame, ping_ms)
		return Correction.SNAP
	if own["timing_seq"] > _timing_seq:
		_timing_seq = own["timing_seq"]
		_lead = lerpf(_lead, own["lead"], 0.1)
		_rate = 1.02 if _lead < MARGIN - 1.0 else 0.96 if _lead > MARGIN + 1.0 else 1.0
	_authority_frame = frame
	var difference := PlayerStateSchema.difference(saved.player, own["state"])
	if difference.is_empty() and saved.cursor != InputBuffer.cursor(epoch, action_ack, input, at):
		difference = "input"
	if difference.is_empty() and time_economy != null and saved.account != frame["time"][_player.role]:
		difference = "economy"
	if difference.is_empty() and combat != null and (_late_shot or saved.projectiles != _projectiles_at(frame, saved)):
		difference = "projectiles"
	if difference.is_empty() and _replay_tick <= at:
		_replay_tick = 0
		_retire_combat_events()
		return Correction.KEEP
	return _replay(at, "combat" if difference.is_empty() else difference)

func queue_shot(shot: Dictionary) -> void:
	var at: int = shot["tick"]
	if combat == null:
		return
	var id := ShotRules.shot_id(shot["role"], shot["serial"])
	_shots[id] = shot
	if at <= tick:
		var saved := _state_at(at)
		if saved == null or saved.shots.get(id) != shot:
			_late_shot = true
			_request_replay(maxi(at, _authority_frame["tick"]))

func queue_projectile_end(id: int, at: int, blast := {}) -> void:
	if combat == null:
		return
	_projectile_ends[id] = {"tick": at, "blast": blast}
	if at <= tick:
		var check_tick := maxi(at, _authority_frame["tick"])
		var saved := _state_at(check_tick)
		var remaining := blast if int(blast.get("due", 0)) > check_tick else {}
		if saved == null or saved.projectiles.get(id, {}) != remaining:
			_request_replay(check_tick)

func queue_hit(hit: Dictionary) -> void:
	var at: int = hit["tick"]
	var own: bool = hit["victim"] == _player.role
	if at <= _authority_frame["tick"] or (own and hit["epoch"] < epoch):
		return
	_hits.get_or_add(at, []).append(hit)
	var affected_tick := at + int(not own)
	if affected_tick <= tick and (not own or hit["epoch"] == epoch):
		_request_replay(affected_tick)

func _request_replay(at: int) -> void:
	_replay_tick = maxi(_replay_tick, at)

func _replay(at: int, reason: String) -> Correction:
	var started := PerformanceStats.begin()
	var before := _state_at(at) if PerformanceStats.is_enabled() else null
	var previous := _player.global_position
	var end := tick
	var endpoint := _state_at(end)
	_restore()
	while tick < end:
		_step()
		replay_ticks += 1
	var combat_only := combat != null and (reason == "combat" or reason == "projectiles")
	var corrected := not combat_only or endpoint == null or endpoint.player != _state_at(end).player
	if corrected:
		_player.rebase_visual_step(previous)
		if before != null:
			_record_correction(at, before.player["actor"], _state_at(at).player["actor"], reason)
	PerformanceStats.replayed(replay_ticks)
	PerformanceStats.end(PerformanceStats.REPLAY, started)
	return Correction.SMOOTH if corrected else Correction.KEEP

func _restore() -> void:
	var own: Dictionary = _authority_frame["own"]
	tick = _authority_frame["tick"]
	_replay_tick = 0
	replay_ticks = 0
	proxy_motion.clear()
	_player.restore_state(own["state"])
	_player.rewinding = own["rewind"]
	if time_economy != null:
		time_economy.restore_account(_player.role, _authority_frame["time"][_player.role])
	_input.restore_authority(epoch, own["action_ack"], own["input"], tick)
	_input.push([history, actions], tick)
	if combat != null:
		combat.restore_projectiles(_projectiles_at(_authority_frame, _state_at(tick)))
		_retire_combat_events()
		if _prepare_step.is_valid():
			_prepare_step.call(tick, true)
		for shot: Dictionary in _shots.values():
			if tick - KEEP < shot["tick"] and shot["tick"] <= tick:
				combat.catch_up_shot(shot, _authority_frame["world"]["projectiles"], tick)
	_late_shot = false
	_states.fill(null)
	_remember()

func _projectiles_at(frame: Dictionary, saved: PredictionFrame) -> Dictionary:
	var states := {}
	var live: Dictionary = frame["world"]["projectiles"]
	if saved != null:
		for id: int in saved.projectiles:
			var state: Dictionary = saved.projectiles[id]
			if state.has("due"):
				var serial := (id >> 8) & 0xffffffff
				if not live.has(id) and (id >> 48 != _player.role or serial <= frame["own"]["state"]["actor"][PlayerStateSchema.SHOT_SERIAL]):
					states[id] = state
			elif live.has(id) and live[id]["type_id"] == state["type_id"] and not _shooter_rewinding(frame, id >> 48):
				var motion: Array = state["motion"]
				var sample: Dictionary = live[id]
				if motion[BulletBody.MOTION_POS] != sample["pos"] or motion[BulletBody.MOTION_VEL] != sample["vel"]:
					motion = motion.duplicate()
					motion[BulletBody.MOTION_POS] = sample["pos"]
					motion[BulletBody.MOTION_VEL] = sample["vel"]
					state = state.merged({"motion": motion}, true)
				states[id] = state
	for id: int in _projectile_ends:
		var end := _projectile_ends[id]
		if end["tick"] <= frame["tick"]:
			var blast: Dictionary = end["blast"]
			if int(blast.get("due", 0)) > frame["tick"]:
				states[id] = blast
			else:
				states.erase(id)
	return states

func _retire_combat_events() -> void:
	var at: int = _authority_frame["tick"]
	var live_shots := {}
	for id: int in _authority_frame["world"]["projectiles"]:
		live_shots[id & ~0xff] = true
	for id: int in _shots.keys():
		if _shots[id]["tick"] <= at and (not live_shots.has(id) or _shooter_rewinding(_authority_frame, id >> 48)):
			_shots.erase(id)
	for id: int in _projectile_ends.keys():
		if _projectile_ends[id]["tick"] <= at:
			_projectile_ends.erase(id)

func _shooter_rewinding(frame: Dictionary, role: int) -> bool:
	if role == _player.role:
		return frame["own"]["rewind"]
	var state: Array = frame["world"]["players"].get(role, [])
	return not state.is_empty() and state[PlayerStateSchema.REMOTE_REWIND]

func _step() -> Array:
	tick += 1
	if _prepare_step.is_valid():
		_prepare_step.call(tick, false)
	var record := _input.take(tick)
	if time_economy != null:
		time_economy.step_haste(_player, record, ActorStep.DT)
	var result := ActorStep.step(_player, record)
	if time_economy != null:
		time_economy.tick(ActorStep.DT)
	var shots := _step_combat(result) if combat != null else {}
	_apply_hits(_hits.get(tick, []))
	_remember(shots)
	return result

func _step_combat(actions: Array) -> Dictionary:
	if _prepare_step.is_valid():
		_prepare_step.call(tick, true)
	var shots := {}
	for action: Dictionary in actions:
		if action["kind"] != "fire":
			continue
		var id := ShotRules.shot_id(_player.role, action["serial"])
		if not _shots.has(id):
			shots[id] = action.merged({"role": _player.role, "tick": tick})
	for id: int in _shots:
		if _shots[id]["tick"] == tick:
			shots[id] = _shots[id]
	combat.tick = tick
	combat.predicted_hits.clear()
	var ids := shots.keys()
	ids.sort()
	for id: int in ids:
		var shot: Dictionary = shots[id]
		var shooter: ActorBody = combat.players.get(shot["role"])
		if shooter != null:
			combat.fire(shooter, shot)
	combat.apply_projectile_ends(_projectile_ends)
	combat.step_projectiles(ActorStep.DT)
	combat.settle_blasts()
	return shots

func _apply_hits(hits: Array) -> void:
	var confirmed := {}
	for hit: Dictionary in hits:
		var role: int = hit["victim"]
		if role != _player.role:
			proxy_motion[role] = hit
			confirmed[role] = true
			continue
		if hit["epoch"] != epoch:
			continue
		confirmed[role] = true
		match hit["impulse_mode"]:
			-1: _player.velocity = hit["vel"]
			1: _player.motion_knock_velocity = hit["knock"]
		_player.apply_hit_health(hit["hp"])
	if combat == null:
		return
	for hit: Array in combat.predicted_hits:
		var target: ActorBody = hit[0]
		if confirmed.has(target.role):
			continue
		target.apply_impulse(hit[1], hit[2])
		target.cancel_charge()
		if target != _player:
			proxy_motion[target.role] = {"tick": tick, "pos": target.global_position,
				"vel": target.velocity, "knock": target.motion_knock_velocity,
				"hp": target.sim_hp, "facing": target.facing_direction}

func _remember(shots := {}) -> void:
	var started := PerformanceStats.begin()
	var saved := PredictionFrame.new()
	saved.tick = tick
	saved.player = _player.capture_state()
	saved.cursor = _input.capture_cursor(tick)
	if time_economy != null:
		saved.account = time_economy.account_payload(_player.role)
	if combat != null:
		saved.projectiles = combat.capture_projectiles()
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
