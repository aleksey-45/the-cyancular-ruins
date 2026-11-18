class_name SnapshotBuffer
extends RefCounted

enum Sample { POS, VEL, SOURCE }
enum Frame { TICK, WORLD }
const NetPlayer := PlayerStateSchema.Network
const DELAY_TICKS := 6.0
const MAX_EXTRAPOLATION := 6.0
const KEEP := 32
const KNOCK_DECAY := exp(-PlayerParams.player_knock_decay_rate * ActorStep.DT)
var map_px := Vector2.ZERO
var frames: Array[Array] = []
var latest_tick: int:
	get: return frames[-1][Frame.TICK] if not frames.is_empty() else -1
var latest_players: Dictionary:
	get: return frames[-1][Frame.WORLD]["players"] if not frames.is_empty() else {}
var render_tick := 0.0
var _drift := 0.0
var _rate := 1.0

func reset() -> void:
	frames.clear()
	_drift = 0.0
	_rate = 1.0


func push(tick: int, world: Dictionary) -> void:
	if tick <= latest_tick:
		return
	# 记录在解码后只读，缓冲与解码帧共用同一份槽数组，插值时再复制要改动的那一条。
	frames.append([tick, world])
	if frames.size() == 1:
		render_tick = tick - DELAY_TICKS
	while frames.size() > KEEP:
		frames.pop_front()
	# 普通到包只调播放速度；严重停顿恢复才重新定位。
	if tick - render_tick > DELAY_TICKS * 2.0 or render_tick < frames[0][Frame.TICK] - DELAY_TICKS:
		render_tick = tick - DELAY_TICKS
		_drift = 0.0
	_drift = lerpf(_drift, tick - render_tick - DELAY_TICKS, 0.1)
	_rate = 1.02 if _drift > 2.0 else 0.96 if _drift < -2.0 else 1.0

func advance(delta: float, local_role: int) -> Dictionary:
	render_tick = minf(render_tick + delta * 60.0 * _rate, float(frames[-1][Frame.TICK]) + MAX_EXTRAPOLATION)
	return sample(render_tick, local_role)

func sample(tick: float, local_role := 0) -> Dictionary:
	while frames.size() > 2 and frames[1][Frame.TICK] <= tick:
		frames.pop_front()
	var from := frames[0]
	var to := frames[1] if frames.size() > 1 else from
	var ahead := minf(tick - to[Frame.TICK], MAX_EXTRAPOLATION)
	var weight := clampf((tick - from[Frame.TICK]) / maxf(1.0, to[Frame.TICK] - from[Frame.TICK]), 0.0, 1.0)
	var between := weight > 0.0 and weight < 1.0
	var source: Dictionary = from[Frame.WORLD] if weight < 1.0 else to[Frame.WORLD]
	var players := {}
	for role: int in source["players"]:
		if role == local_role: continue
		var sample: Array = source["players"][role]
		var actor: Array = sample[NetPlayer.STATE]
		var pose := [actor[PlayerStateSchema.POS], actor[PlayerStateSchema.VEL], sample]
		var next: Array = to[Frame.WORLD]["players"].get(role, [])
		if between and not next.is_empty():
			var rewinding: bool = sample[NetPlayer.REWIND] or next[NetPlayer.REWIND]
			if next[NetPlayer.EPOCH] == sample[NetPlayer.EPOCH] or (sample[NetPlayer.REWIND] and next[NetPlayer.EPOCH] == sample[NetPlayer.EPOCH] + 1):
				var next_actor: Array = next[NetPlayer.STATE]
				_interpolate(pose, next_actor[PlayerStateSchema.POS], next_actor[PlayerStateSchema.VEL], weight, rewinding)
		elif ahead > 0.0 and not sample[NetPlayer.REWIND]:
			var whole := floorf(ahead)
			var decay := pow(KNOCK_DECAY, whole)
			var knock_ticks := (1.0 - decay) / (1.0 - KNOCK_DECAY) + (ahead - whole) * decay
			var travel: Vector2 = pose[Sample.VEL] * ahead + actor[PlayerStateSchema.KNOCK_VEL] * knock_ticks
			pose[Sample.POS] = GridPathfinder.wrap_to_range(pose[Sample.POS] + travel * ActorStep.DT, map_px)
		players[role] = pose
	var pickups := {}
	for id in source["pickups"]:
		var state: Array = source["pickups"][id].duplicate()
		var next: Array = to[Frame.WORLD]["pickups"].get(id, [])
		if between and not next.is_empty():
			_interpolate(state, next[WeaponPickup.Network.POS], next[WeaponPickup.Network.VEL], weight)
		elif ahead > 0.0:
			state[WeaponPickup.Network.POS] = GridPathfinder.wrap_to_range(
					state[WeaponPickup.Network.POS] + state[WeaponPickup.Network.VEL] * ahead * ActorStep.DT, map_px)
		pickups[id] = state
	return {"players": players, "pickups": pickups, "beams": source["beams"]}

func _interpolate(state: Array, pos: Vector2, vel: Vector2, weight: float, rewinding := false) -> void:
	var movement := GridPathfinder.toroidal_delta_px(state[Sample.POS], pos, map_px)
	if rewinding or movement.length_squared() < 256.0 * 256.0:
		state[Sample.POS] = GridPathfinder.wrap_to_range(state[Sample.POS] + movement * weight, map_px)
		state[Sample.VEL] = state[Sample.VEL].lerp(vel, weight)
