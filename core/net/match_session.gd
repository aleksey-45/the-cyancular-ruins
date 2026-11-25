class_name MatchSession
extends RefCounted

const KEEP := 64
const MAX_REPLAY := InputBuffer.FUTURE_TICKS
const REMOTE_MOVEMENT := ActorInput.BIT_UP | ActorInput.BIT_DOWN
const Actor := preload("res://core/sim/player_state_schema.gd")

var world: MatchWorld
var role := 0
var remote := false
var latest_authority: Dictionary = {}
var last_input_target := 0
var replay_ticks := 0
var outgoing_input: Array

var _buffers: Dictionary[int, InputBuffer] = {}
var _schedulers: Dictionary[int, InputScheduler] = {}
var _commands: Array = []
var _pending: Dictionary[int, Dictionary] = {}
var _prediction := InputBuffer.new()
var _clock := InputClock.new()
var _seq := 0
var _history: Array = []
var _actions: Array = []
var _discarded := 0
var _current: Dictionary = {}
var _previous: Dictionary = {}

static func open_local(spec: WorldSpec, observing_role := 0) -> MatchSession:
	var session := MatchSession.new()
	session.world = MatchWorld.create(spec)
	session.role = observing_role
	if session.world.problem.is_empty():
		for id: int in spec.roles:
			session._buffers[id] = InputBuffer.new()
		if observing_role != 0:
			session._current = session.world.frame.sample()
			session._previous = session._current
	return session

static func open_remote(baseline: Dictionary, ping_ms: int) -> MatchSession:
	var config := WorldSpec.new(baseline["map"], baseline["mode"], baseline["roles"],
			baseline["teams"], baseline["options"], baseline["seed"])
	var session := MatchSession.new()
	session.world = MatchWorld.create(config)
	session.role = baseline["role"]
	session.remote = true
	session.install(baseline, ping_ms)
	return session

func install(baseline: Dictionary, ping_ms: int) -> void:
	var frame: Dictionary = baseline["frame"]
	_pending.clear()
	world.terrain.install_baseline(frame["checkpoint"]["terrain"], baseline["sub_hp"])
	_adopt(frame, ping_ms, true)

func enqueue(command: int, seat := 0) -> void:
	_commands.append([command, seat])

func receive_state(frame: Dictionary) -> void:
	var state: Dictionary = frame["checkpoint"]
	var version: int = state["terrain"]
	var previous: Dictionary = _pending.get(version, latest_authority)
	if state["tick"] > previous["checkpoint"]["tick"]:
		_pending[version] = frame

func receive_terrain(patch: Dictionary) -> void:
	world.terrain.queue_patch(patch["version"], patch["cells"])

func accept_input(seat: int, packet: Array, received_us: int) -> void:
	if world.rules.phase == MatchRules.Phase.MATCH_OVER:
		return
	if not _schedulers.has(seat):
		_schedulers[seat] = InputScheduler.new()
	if not _schedulers[seat].submit(_buffers[seat], packet, world.tick, received_us):
		reset_input(seat, true)

func reset_input(seat: int, new_epoch: bool) -> void:
	_schedulers.erase(seat)
	var buffer := _buffers[seat]
	buffer.reset(buffer.epoch + int(new_epoch))

func packet(grace: Dictionary) -> Dictionary:
	var inputs := {}
	for id: int in world.players:
		var buffer := _buffers[id]
		inputs[id] = [buffer.epoch, buffer.action_ack] + buffer._last
	return {"checkpoint": world.capture(), "inputs": inputs, "grace": grace, "input_feedback": PackedByteArray()}

func feedback(seat: int) -> PackedByteArray:
	return _schedulers[seat].feedback if _schedulers.has(seat) else PackedByteArray()

func fixed_step(seat_intents: Dictionary = {}, ping_ms := 0) -> Dictionary:
	if remote:
		return _fixed_remote(seat_intents[role], ping_ms)
	var inputs := {}
	var before := {}
	for id: int in world.players:
		var actor := world.players[id]
		before[id] = [actor.life, actor.rewinding]
		inputs[id] = seat_intents[id] if seat_intents.has(id) else _buffers[id].take(world.tick + 1)
	var view := world.advance(inputs, _commands)
	_commands.clear()
	for id: int in before:
		if not world.players.has(id):
			_buffers.erase(id)
			_schedulers.erase(id)
		else:
			var actor := world.players[id]
			if actor.life != before[id][0] or (before[id][1] and not actor.rewinding):
				reset_input(id, true)
	if role == 0:
		return {}
	_previous = _current
	_current = view.sample()
	return {"previous": _previous, "current": _current}

func initial_view() -> Dictionary:
	return {"previous": _previous, "current": _current}

func close() -> void:
	world.close()

func _fixed_remote(record: Array, ping_ms: int) -> Dictionary:
	var anchor := _take_anchor()
	var update := {}
	if not anchor.is_empty():
		var started := PerformanceStats.begin()
		var old_end := world.tick
		var old_previous_tick: int = _previous["tick"]
		var old_prev: Array = _previous["players"][role]
		var old_local: Array = _current["players"][role]
		var old_life: int = latest_authority["checkpoint"]["players"][role][Actor.LIFE]
		_adopt(anchor, ping_ms)
		var auth: Array = anchor["checkpoint"]["players"][role]
		var life_changed: bool = old_life != auth[Actor.LIFE]
		var start := world.tick
		if not life_changed:
			_advance_prediction(mini(old_end, start + MAX_REPLAY))
		replay_ticks = world.tick - start
		PerformanceStats.replayed(replay_ticks)
		PerformanceStats.end(PerformanceStats.REPLAY, started)
		var new_local: Array = _current["players"][role]
		var new_prev: Array = _previous["players"][role]
		var distance := GridPathfinder.toroidal_delta_px(old_local[Actor.POS], new_local[Actor.POS], world.terrain.map_size).length()
		var previous_changed: bool = old_previous_tick == _previous["tick"] and old_prev[Actor.POS] != new_prev[Actor.POS]
		if life_changed or distance > 0.1 or previous_changed:
			update["replacement"] = [old_prev[Actor.POS], old_local[Actor.POS], new_prev[Actor.POS], new_local[Actor.POS], life_changed]
		if distance > 0.1 and PerformanceStats.is_enabled():
			var reason := "respawn" if life_changed else ("rewind" if auth[Actor.REWIND] or old_local[Actor.REWIND] else "state")
			PerformanceStats.record_correction(role, start, world.tick, reason, distance)
		update["authority"] = anchor
		PerformanceStats.end(PerformanceStats.CLIENT_AUTHORITY, started)
	_record_input(record)
	outgoing_input = [_history.slice(-InputBuffer.REDUNDANCY), _actions]
	var limit: int = latest_authority["checkpoint"]["tick"] + MAX_REPLAY
	_advance_prediction(_clock.advance(ActorStep.DT, world.tick, limit))
	update["previous"] = _previous
	update["current"] = _current
	return update

func _take_anchor() -> Dictionary:
	var adopted: int = latest_authority["checkpoint"]["tick"]
	var chosen := {}
	var newest := adopted
	for version: int in _pending:
		var frame := _pending[version]
		if world.terrain.has_authority(version) and frame["checkpoint"]["tick"] > newest:
			newest = frame["checkpoint"]["tick"]
			chosen = frame
	for version: int in _pending.keys():
		if _pending[version]["checkpoint"]["tick"] <= newest:
			_pending.erase(version)
	return chosen

func _adopt(anchor: Dictionary, ping_ms: int, initial := false) -> void:
	var state: Dictionary = anchor["checkpoint"]
	var meta: Array = anchor["inputs"][role]
	var epoch: int = meta[0]
	var action_ack: int = meta[1]
	var held := meta.slice(2)
	var seq: int = held[InputBuffer.SEQ]
	var at: int = state["tick"]
	if initial or epoch != _prediction.epoch or seq > _seq or seq < _discarded:
		_seq = maxi(seq, action_ack) if initial or epoch != _prediction.epoch else maxi(_seq, maxi(seq, action_ack))
		_history.clear()
		_actions.clear()
		_discarded = 0
		_clock.reset(at, _seq, ping_ms, anchor["input_feedback"])
	else:
		_clock.synchronize(at, _seq, anchor["input_feedback"])
		_history = _history.filter(func(row: Array) -> bool: return row[InputBuffer.SEQ] > seq)
		_actions = _actions.filter(func(row: Array) -> bool:
			return row[InputBuffer.SEQ] > action_ack and at - row[InputBuffer.TARGET_TICK] < InputBuffer.ACTION_TICKS)
	latest_authority = anchor
	_prediction.restore_authority(epoch, action_ack, held)
	world.terrain.apply_patches(state["terrain"])
	_current = world.restore(state).sample(role)
	_previous = _current

func _record_input(record: Array) -> void:
	_seq += 1
	last_input_target = _clock.sample(_seq, record)
	var epoch := _prediction.epoch
	var pressed: int = record[ActorInput.PRESSED]
	var released: int = record[ActorInput.RELEASED]
	var inst: int = record[ActorInput.WINST]
	var aim: Vector2 = record[ActorInput.AIM]
	_actions = _actions.filter(func(row: Array) -> bool:
		return _seq - row[InputBuffer.SEQ] <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS)
	if pressed != 0 or released != 0 or inst != 0:
		if inst == 0 and (pressed | released) & (ActorInput.BIT_ATTACK | ActorInput.BIT_RELOAD | ActorInput.BIT_DROP):
			inst = world.players[role].weapons.current_inst()
		_actions.append([_seq, epoch, last_input_target, pressed, released, inst, aim])
	_history.append([_seq, epoch, last_input_target, record[ActorInput.AX], record[ActorInput.HELD], aim])
	if _history.size() > KEEP:
		_discarded = _history.pop_front()[InputBuffer.SEQ]

func _advance_prediction(end: int) -> void:
	if end <= world.tick or world.rules.phase == MatchRules.Phase.MATCH_OVER:
		return
	_prediction.push([_history, _actions], world.tick)
	var checkpoint: Dictionary = latest_authority["checkpoint"]
	var at: int = checkpoint["tick"]
	var confirmed: Dictionary = latest_authority["inputs"]
	while world.tick < end and world.rules.phase != MatchRules.Phase.MATCH_OVER:
		var next := world.tick + 1
		var inputs := {role: _prediction.take(next)}
		for id: int in world.players:
			if id == role:
				continue
			var meta: Array = confirmed[id]
			var moving: bool = next <= at + InputBuffer.HOLD_TICKS and next - meta[2 + InputBuffer.TARGET_TICK] <= InputBuffer.HOLD_TICKS
			inputs[id] = [meta[2 + InputBuffer.FRAME_AX] if moving else 0.0,
				int(meta[2 + InputBuffer.FRAME_HELD]) & REMOTE_MOVEMENT if moving else 0,
				0, 0, 0, meta[2 + InputBuffer.FRAME_AIM]]
		if next == end:
			_previous = world.frame.sample(role)
		world.advance(inputs)
	_current = world.frame.sample(role)
