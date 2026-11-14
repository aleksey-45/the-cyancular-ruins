class_name PredictionRollback
extends RefCounted

const KEEP := 64
const MAX_REPLAY := 32
const MARGIN := 2.0

enum Correction { KEEP, SMOOTH, SNAP }

var tick := 0
var sequence := 0
var history: Array = []
var actions: Array = []
var time_economy: TimeEconomy
var combat: CombatSimulator
var replay_ticks := 0

var _states: Array[PredictionFrame] = []
var _clock := 0.0
var _lead := MARGIN
var _rate := 1.0
var _timing_seq := 0
var _discarded_through := 0
var _player: Player
var _authority_frame: Dictionary
var _hits: Dictionary[int, Array] = {}
var _shots: Dictionary[int, Dictionary] = {}
var _projectile_ends: Dictionary[int, Dictionary] = {}
var _replay_tick := 0
var _late_shot := false

func _init() -> void:
	_states.resize(KEEP)

func bind(player: Player, simulator: CombatSimulator) -> void:
	_player = player
	combat = simulator
	combat.players[_player.role] = _player
	combat.predicting = true
	_player.projectile_count = combat.count_projectiles.bind(_player)

func reset(frame: Dictionary, ping_ms: int, keep_events := false) -> void:
	var own: Dictionary = frame["world"]["players"][_player.role]
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
	var epoch := _player.input_buffer.epoch
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
		_player.input_buffer.push(input, tick)
	while tick < int(_clock):
		_player.begin_visual_step()
		_player.present_actions(_step())
	if tick == previous_tick and _clock >= limit:
		_player.begin_visual_step()

func reconcile(frame: Dictionary, ping_ms: int) -> Correction:
	if frame.is_empty():
		if _replay_tick == 0 or _player.rewinding \
				or _authority_frame["world"]["players"][_player.role]["input"][InputBuffer.SEQ] < _discarded_through:
			return Correction.KEEP
		return _replay(_replay_tick, "combat")
	var players: Dictionary = frame["world"]["players"]
	var own: Dictionary = players[_player.role]
	var at: int = frame["tick"]
	replay_ticks = 0
	for hit_tick: int in _hits.keys():
		if hit_tick <= at:
			_hits.erase(hit_tick)
	if own["epoch"] != _player.input_buffer.epoch:
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
	var timing: Dictionary = frame["own"]
	if timing["timing_seq"] > _timing_seq:
		_timing_seq = timing["timing_seq"]
		_lead = lerpf(_lead, timing["lead"], 0.1)
		_rate = 1.02 if _lead < MARGIN - 1.0 else 0.96 if _lead > MARGIN + 1.0 else 1.0
	var forecast_extended: bool = at > _authority_frame["tick"] and tick > at \
			and tick > _authority_frame["tick"] + SnapshotBuffer.MAX_EXTRAPOLATION
	_authority_frame = frame
	var predicted: Dictionary = saved.players[_player.role]
	var difference := PlayerStateSchema.difference(predicted["state"], own["state"])
	if difference.is_empty() and (predicted["input"] != input or predicted["action_ack"] != action_ack):
		difference = "input"
	if difference.is_empty() and time_economy != null and saved.accounts[_player.role] != frame["time"][_player.role]:
		difference = "economy"
	if difference.is_empty() and (saved.players != players or saved.accounts != frame["time"]
			or (players.size() > 1 and forecast_extended)):
		difference = "players"
	if difference.is_empty() and (_late_shot or saved.projectiles != _projectiles_at(frame, saved)):
		difference = "projectiles"
	if difference.is_empty() and _replay_tick <= at:
		_replay_tick = 0
		_retire_combat_events()
		return Correction.KEEP
	return _replay(at, "combat" if difference.is_empty() else difference)

func queue_shot(shot: Dictionary) -> void:
	var at: int = shot["tick"]
	var id := ShotRules.shot_id(shot["role"], shot["serial"])
	_shots[id] = shot
	if at <= tick:
		var saved := _state_at(at)
		if saved == null or saved.shots.get(id) != shot:
			_late_shot = true
			_request_replay(maxi(at, _authority_frame["tick"]))

func queue_projectile_end(id: int, at: int, blast := {}) -> void:
	_projectile_ends[id] = {"tick": at, "blast": blast}
	if at <= tick:
		var check_tick := maxi(at, _authority_frame["tick"])
		var saved := _state_at(check_tick)
		var remaining := blast if int(blast.get("due", 0)) > check_tick else {}
		if saved == null or saved.projectiles.get(id, {}) != remaining:
			_request_replay(check_tick)

func queue_hit(hit: Dictionary) -> void:
	var at: int = hit["tick"]
	var victim: Player = combat.players.get(hit["victim"])
	if at <= _authority_frame["tick"] or victim == null or hit["epoch"] < victim.input_buffer.epoch:
		return
	_hits.get_or_add(at, []).append(hit)
	if at <= tick and hit["epoch"] == victim.input_buffer.epoch:
		_request_replay(at)

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
	var role := _player.role
	var world_only := reason in ["combat", "projectiles", "players"]
	var corrected: bool = not world_only or endpoint == null \
			or endpoint.players[role]["state"] != _state_at(end).players[role]["state"]
	if corrected:
		_player.rebase_visual_step(previous)
		if before != null:
			_record_correction(at, before.players[role]["state"]["actor"], _state_at(at).players[role]["state"]["actor"], reason)
	PerformanceStats.replayed(replay_ticks)
	PerformanceStats.end(PerformanceStats.REPLAY, started)
	return Correction.SMOOTH if corrected else Correction.KEEP

func _restore() -> void:
	tick = _authority_frame["tick"]
	_replay_tick = 0
	replay_ticks = 0
	var world: Dictionary = _authority_frame["world"]
	for role: int in world["players"]:
		combat.players[role].restore_network_state(world["players"][role])
		if time_economy != null:
			time_economy.restore_account(role, _authority_frame["time"][role])
	_player.input_buffer.push([history, actions], tick)
	combat.restore_projectiles(_projectiles_at(_authority_frame, _state_at(tick)))
	_retire_combat_events()
	for shot: Dictionary in _shots.values():
		if tick - KEEP < shot["tick"] and shot["tick"] <= tick:
			combat.catch_up_shot(shot, world["projectiles"], tick)
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
				var owner: Dictionary = frame["world"]["players"].get(id >> 48, {})
				if not live.has(id) and not owner.is_empty() \
						and ((id >> 8) & 0xffffffff) <= owner["state"]["actor"][PlayerStateSchema.SHOT_SERIAL]:
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
	return frame["world"]["players"].get(role, {}).get("rewind", false)

func _step() -> Array:
	tick += 1
	var inside_forecast: bool = tick <= _authority_frame["tick"] + SnapshotBuffer.MAX_EXTRAPOLATION
	var stepped := ActorStep.step_players(combat.players, tick, time_economy, _player, inside_forecast)
	if time_economy != null:
		time_economy.tick(ActorStep.DT)
	var shots := _step_combat(stepped)
	_apply_hits(_hits.get(tick, []))
	for player: Player in combat.players.values():
		# 复活在移动与命中之后结算，下一 tick 才不再查询旧位置。
		if player != _player and player.respawn_tick == tick:
			player.collision_layer = 0
			player._apply_layers()
	_remember(shots)
	return _player.step_actions

func _step_combat(stepped: Array) -> Dictionary:
	var shots := {}
	for player: Player in stepped:
		for action: Dictionary in player.step_actions:
			if action["kind"] == "fire":
				var id := ShotRules.shot_id(player.role, action["serial"])
				if not _shots.has(id):
					shots[id] = action.merged({"role": player.role, "tick": tick})
	for id: int in _shots:
		if _shots[id]["tick"] == tick:
			shots[id] = _shots[id]
	combat.tick = tick
	combat.predicted_hits.clear()
	var ids := shots.keys()
	ids.sort()
	for id: int in ids:
		var shot: Dictionary = shots[id]
		var shooter: Player = combat.players.get(shot["role"])
		if shooter != null:
			# 可靠出手也可能先于远端输入进入重放，占用同一个射击序号。
			shooter.shot_serial = maxi(shooter.shot_serial, shot["serial"])
			combat.fire(shooter, shot)
	combat.apply_projectile_ends(_projectile_ends)
	combat.step_projectiles(ActorStep.DT)
	combat.settle_blasts()
	return shots

func _apply_hits(hits: Array) -> void:
	var confirmed := {}
	for hit: Dictionary in hits:
		var role: int = hit["victim"]
		var victim: Player = combat.players.get(role)
		if victim == null or hit["epoch"] != victim.input_buffer.epoch:
			continue
		confirmed[role] = true
		if victim != _player:
			victim.global_position = hit["pos"]
			victim.facing_direction = hit["facing"]
			victim.rewinding = false
		if victim != _player or hit["impulse_mode"] < 0:
			victim.velocity = hit["vel"]
		if victim != _player or hit["impulse_mode"] > 0:
			victim.motion_knock_velocity = hit["knock"]
		if not victim.apply_hit_health(hit["hp"]) and victim != _player:
			victim.apply_authoritative_state(victim.sim_hp, victim.waterproof, victim.sim_downed)
	for hit: Array in combat.predicted_hits:
		var target: ActorBody = hit[0]
		if confirmed.has(target.role):
			continue
		target.apply_impulse(hit[1], hit[2])
		target.cancel_charge()

func _remember(shots := {}) -> void:
	var started := PerformanceStats.begin()
	var saved := PredictionFrame.new()
	saved.tick = tick
	for role: int in combat.players:
		var player: Player = combat.players[role]
		saved.players[role] = player.capture_network_state()
	if time_economy != null:
		saved.accounts = time_economy.state_payload()
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
