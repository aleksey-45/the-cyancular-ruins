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
var replay_ticks := 0

var _states: Array[PredictionFrame] = []
var _clock := 0.0
var _authority_tick := 0
var _lead := MARGIN
var _rate := 1.0
var _timing_seq := 0
var _discarded_through := 0
var _input := InputBuffer.new()
var _player: Player

func _init() -> void:
	_states.resize(KEEP)

func bind(player: Player) -> void:
	_player = player

func reset(frame: Dictionary, ping_ms: int) -> void:
	var own: Dictionary = frame["own"]
	epoch = own["epoch"]
	sequence = own["input"][InputBuffer.SEQ]
	history.clear()
	actions.clear()
	_anchor(frame, ping_ms)

func _anchor(frame: Dictionary, ping_ms: int) -> void:
	_authority_tick = frame["tick"]
	_clock = _authority_tick + minf(ceilf(ping_ms * 0.06) + MARGIN, MAX_REPLAY)
	_lead = MARGIN
	_rate = 1.0
	_timing_seq = frame["own"]["timing_seq"]
	_discarded_through = 0
	replay_ticks = 0
	_restore(frame)

func capture(record: Array) -> void:
	actions = actions.filter(func(action: Array) -> bool:
		return sequence - action[InputBuffer.SEQ] <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS)
	sequence += 1
	var target := mini(int(_clock) + 1, _authority_tick + MAX_REPLAY)
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
	_clock = minf(_clock + delta * 60.0 * _rate, _authority_tick + MAX_REPLAY)
	if _player.rewinding:
		return
	if tick < int(_clock):
		_input.push(input, tick)
	while tick < int(_clock):
		_player.begin_visual_step()
		_player.present_actions(_step())
	if tick == previous_tick and _clock >= _authority_tick + MAX_REPLAY:
		_player.begin_visual_step()

func reconcile(frame: Dictionary, ping_ms: int) -> Correction:
	var own: Dictionary = frame["own"]
	var at: int = frame["tick"]
	replay_ticks = 0
	if own["epoch"] != epoch:
		reset(frame, ping_ms)
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
	_authority_tick = at
	var difference := PlayerStateSchema.difference(saved.player, own["state"])
	if difference.is_empty() and saved.cursor != InputBuffer.cursor(epoch, action_ack, input, at):
		difference = "input"
	if difference.is_empty() and time_economy != null and saved.account != frame["time"][_player.role]:
		difference = "economy"
	if difference.is_empty():
		return Correction.KEEP

	var started := PerformanceStats.begin()
	_record_correction(at, saved.player["actor"], own["state"]["actor"], difference)
	var previous := _player.global_position
	var end := tick
	_restore(frame)
	while tick < end:
		_step()
		replay_ticks += 1
	_player.rebase_visual_step(previous)
	PerformanceStats.replayed(replay_ticks)
	PerformanceStats.end(PerformanceStats.REPLAY, started)
	return Correction.SMOOTH

func _restore(frame: Dictionary) -> void:
	var own: Dictionary = frame["own"]
	tick = frame["tick"]
	_player.restore_state(own["state"])
	_player.rewinding = own["rewind"]
	if time_economy != null:
		time_economy.restore_account(_player.role, frame["time"][_player.role])
	_input.restore_authority(epoch, own["action_ack"], own["input"], tick)
	_input.push([history, actions], tick)
	_states.fill(null)
	_remember()

func _step() -> Array:
	tick += 1
	var record := _input.take(tick)
	if time_economy != null:
		time_economy.step_haste(_player, record, ActorStep.DT)
	var result := ActorStep.step(_player, record)
	if time_economy != null:
		time_economy.tick(ActorStep.DT)
	_remember()
	return result

func _remember() -> void:
	var started := PerformanceStats.begin()
	var saved := PredictionFrame.new()
	saved.tick = tick
	saved.player = _player.capture_state()
	saved.cursor = _input.capture_cursor(tick)
	if time_economy != null:
		saved.account = time_economy.account_payload(_player.role)
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
	if not PerformanceStats.is_enabled():
		return
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
