class_name MatchSession
extends RefCounted

const KEEP := 64
const MAX_REPLAY := InputBuffer.FUTURE_TICKS
const POSITION_TOLERANCE_PX := 0.1
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
var _terrain_patches: Dictionary[int, Dictionary] = {}
var _confirmed_terrain := 0
var _prediction := InputBuffer.new()
var _predicted_player: Dictionary[int, Array] = {}
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
			session._current = session.world.sample()
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
	_terrain_patches.clear()
	var terrain := world.terrain
	terrain.reset()
	_confirmed_terrain = terrain.apply_at(terrain.version, baseline["sub_hp"])
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
	_terrain_patches[patch["version"]] = patch["cells"]

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

func fixed_step(seat_intents: Dictionary = {}) -> Dictionary:
	var inputs := {}
	var before := {}
	for id: int in world.players:
		var actor := world.players[id]
		before[id] = [actor.life, actor.rewinding]
		inputs[id] = seat_intents[id] if seat_intents.has(id) else _buffers[id].take(world.tick + 1)
	world.advance(inputs, _commands)
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
	_current = world.sample()
	return view()

func view() -> Dictionary:
	return {"previous": _previous, "current": _current}

func close() -> void:
	world.close()

func predict(record: Array) -> Dictionary:
	_record_input(record)
	outgoing_input = [_history.slice(-InputBuffer.REDUNDANCY), _actions]
	var limit: int = latest_authority["checkpoint"]["tick"] + MAX_REPLAY
	_advance_prediction(_clock.advance(ActorStep.DT, world.tick, limit))
	return view()

## 用最新可用的权威快照校正预测。回滚后重放仍有效的未确认输入，复活时从新状态开始。
func reconcile(ping_ms: int) -> Dictionary:
	replay_ticks = 0
	var anchor := _take_anchor()
	if anchor.is_empty():
		return {}
	var started := PerformanceStats.begin()
	var update := {"authority": anchor}
	var old_end := world.tick
	var old_prev: Array = _previous["players"][role]
	var old_local: Array = _current["players"][role]
	var auth: Array = anchor["checkpoint"]["players"][role]
	var life_changed: bool = auth[Actor.LIFE] != latest_authority["checkpoint"]["players"][role][Actor.LIFE]
	if _adopt(anchor, ping_ms):
		var start := world.tick
		if not life_changed:
			_advance_prediction(old_end)
		replay_ticks = world.tick - start
		PerformanceStats.replayed(replay_ticks)
		PerformanceStats.end(PerformanceStats.REPLAY, started)
		var new_local: Array = _current["players"][role]
		var new_prev: Array = _previous["players"][role]
		var current_changed: bool = old_local[Actor.POS] != new_local[Actor.POS]
		if life_changed or current_changed or old_prev[Actor.POS] != new_prev[Actor.POS]:
			update["replacement"] = [old_prev[Actor.POS], old_local[Actor.POS], new_prev[Actor.POS], new_local[Actor.POS], life_changed]
		if current_changed and old_end == world.tick and PerformanceStats.is_enabled():
			var distance := ToroidalGrid.toroidal_delta_px(old_local[Actor.POS], new_local[Actor.POS], world.terrain.map_size).length()
			var reason := "respawn" if life_changed else ("rewind" if auth[Actor.REWIND] or old_local[Actor.REWIND] else "state")
			PerformanceStats.record_correction(role, start, world.tick, reason, distance)
	PerformanceStats.end(PerformanceStats.CLIENT_AUTHORITY, started)
	return update

func _take_anchor() -> Dictionary:
	var adopted: int = latest_authority["checkpoint"]["tick"]
	var confirmed_version: int = latest_authority["checkpoint"]["terrain"]
	var chosen := {}
	var newest := adopted
	for version: int in _pending:
		var frame := _pending[version]
		if (version == confirmed_version or _terrain_patches.has(version)) and frame["checkpoint"]["tick"] > newest:
			newest = frame["checkpoint"]["tick"]
			chosen = frame
	for version: int in _pending.keys():
		if _pending[version]["checkpoint"]["tick"] <= newest:
			_pending.erase(version)
	return chosen

## 返回是否从快照恢复了模拟。
func _adopt(anchor: Dictionary, ping_ms: int, initial := false) -> bool:
	var state: Dictionary = anchor["checkpoint"]
	var meta: Array = anchor["inputs"][role]
	var epoch: int = meta[0]
	var action_ack: int = meta[1]
	var held := meta.slice(2)
	var seq: int = held[InputBuffer.SEQ]
	var at: int = state["tick"]
	var reset := initial or epoch != _prediction.epoch or seq > _seq or seq < _discarded
	if reset:
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
	var cells := {}
	for version: int in _terrain_patches.keys():
		if version > state["terrain"]:
			break
		cells.merge(_terrain_patches[version], true)
		_terrain_patches.erase(version)
	var rules: Array = state["rules"]
	var keep: bool = not reset and cells.is_empty() and world.terrain.version == _confirmed_terrain \
			and rules[MatchRules.State.PHASE] == world.rules.phase \
			and rules[MatchRules.State.NUMBER] == world.rules.round_number \
			and state["players"].size() == world.players.size() \
			and _player_matches(at, state["players"][role])
	latest_authority = anchor
	if keep:
		_prediction.acknowledge(action_ack, held)
		for tick: int in _predicted_player.keys():
			if tick <= at:
				_predicted_player.erase(tick)
		return false
	_predicted_player.clear()
	_prediction.restore_authority(epoch, action_ack, held)
	var terrain := world.terrain
	_confirmed_terrain = terrain.apply_at(_confirmed_terrain, cells)
	terrain.forget_before(_confirmed_terrain)
	var local_state := state.duplicate()
	local_state["terrain"] = _confirmed_terrain
	world.restore(local_state)
	_current = world.sample(role)
	_previous = _current
	return true

func _player_matches(at: int, actual: Array) -> bool:
	var predicted: Array = _predicted_player.get(at, [])
	if predicted.is_empty():
		return false
	var offset := ToroidalGrid.toroidal_delta_px(predicted[Actor.POS], actual[Actor.POS], world.terrain.map_size)
	if offset.length_squared() > POSITION_TOLERANCE_PX * POSITION_TOLERANCE_PX:
		return false
	for field in range(Actor.POS + 1, Actor.SIZE):
		if predicted[field] != actual[field]:
			return false
	return true

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
			_previous = _current if _current["tick"] == world.tick else world.sample(role)
		world.advance(inputs)
		if next < end:
			_predicted_player[next] = world.players[role].capture_state()
	_current = world.sample(role)
	_predicted_player[world.tick] = _current["players"][role]
