class_name SnapshotBuffer
extends RefCounted

const DELAY_TICKS := 6.0
const MAX_EXTRAPOLATION := 6.0
const KEEP := 32
const KNOCK_DECAY := exp(-PlayerParams.player_knock_decay_rate * ActorStep.DT)
var map_px := Vector2.ZERO
var frames: Array = []
var render_tick := 0.0
var _drift := 0.0
var _rate := 1.0

func reset() -> void:
	frames.clear()
	_drift = 0.0
	_rate = 1.0


func push(tick: int, world: Dictionary) -> void:
	if not frames.is_empty() and tick <= frames[-1]["tick"]:
		return
	# 记录在解码后只读，缓冲与解码帧共用同一份槽数组，插值时再复制要改动的那一条。
	frames.append({"tick": tick, "world": world})
	if frames.size() == 1:
		render_tick = tick - DELAY_TICKS
	while frames.size() > KEEP:
		frames.pop_front()
	# 普通到包只调播放速度；严重停顿恢复才重新定位。
	if tick - render_tick > DELAY_TICKS * 2.0 or render_tick < frames[0]["tick"] - DELAY_TICKS:
		render_tick = tick - DELAY_TICKS
		_drift = 0.0
	_drift = lerpf(_drift, tick - render_tick - DELAY_TICKS, 0.1)
	_rate = 1.02 if _drift > 2.0 else 0.96 if _drift < -2.0 else 1.0

func advance(delta: float) -> Dictionary:
	render_tick = minf(render_tick + delta * 60.0 * _rate, float(frames[-1]["tick"]) + MAX_EXTRAPOLATION)
	return sample(render_tick)

func sample(tick: float) -> Dictionary:
	while frames.size() > 2 and frames[1]["tick"] <= tick:
		frames.pop_front()
	var from: Dictionary = frames[0]
	var to: Dictionary = frames[1] if frames.size() > 1 else from
	var ahead := minf(tick - to["tick"], MAX_EXTRAPOLATION)
	var weight := clampf((tick - from["tick"]) / maxf(1.0, to["tick"] - from["tick"]), 0.0, 1.0)
	var between := weight > 0.0 and weight < 1.0
	var source: Dictionary = from["world"] if weight < 1.0 else to["world"]
	var players := {}
	for role in source["players"]:
		var sample: Dictionary = source["players"][role]
		var actor: Array = sample["state"]["actor"]
		var pose := [actor[PlayerStateSchema.POS], actor[PlayerStateSchema.VEL]]
		var next: Dictionary = to["world"]["players"].get(role, {})
		if between and not next.is_empty() and sample["epoch"] == next["epoch"]:
			var next_actor: Array = next["state"]["actor"]
			_interpolate(pose, [next_actor[PlayerStateSchema.POS], next_actor[PlayerStateSchema.VEL]], weight)
		elif ahead > 0.0 and not sample["rewind"]:
			var whole := floorf(ahead)
			var decay := pow(KNOCK_DECAY, whole)
			var knock_ticks := (1.0 - decay) / (1.0 - KNOCK_DECAY) + (ahead - whole) * decay
			var travel: Vector2 = pose[1] * ahead + actor[PlayerStateSchema.KNOCK_VEL] * knock_ticks
			pose[0] = GridPathfinder.wrap_to_range(pose[0] + travel * ActorStep.DT, map_px)
		players[role] = {"pos": pose[0], "vel": pose[1], "actor": actor, "aim": sample["aim"], "rewind": sample["rewind"]}
	var pickups := {}
	for id in source["pickups"]:
		var state: Array = source["pickups"][id].duplicate()
		var next: Array = to["world"]["pickups"].get(id, [])
		if between and not next.is_empty():
			_interpolate(state, next, weight)
		elif ahead > 0.0:
			state[PickupState.POS] = GridPathfinder.wrap_to_range(
					state[PickupState.POS] + state[PickupState.VEL] * ahead * ActorStep.DT, map_px)
		pickups[id] = state
	return {"players": players, "pickups": pickups}

func _interpolate(state: Array, next: Array, weight: float) -> void:
	var movement := GridPathfinder.toroidal_delta_px(state[0], next[0], map_px)
	if movement.length() < 256.0:
		state[0] = GridPathfinder.wrap_to_range(state[0] + movement * weight, map_px)
		state[1] = state[1].lerp(next[1], weight)
