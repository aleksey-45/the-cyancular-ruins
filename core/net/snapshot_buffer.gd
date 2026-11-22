class_name SnapshotBuffer
extends RefCounted

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

enum Sample { POS, VEL, SOURCE }
enum Frame { TICK, WORLD }
const NetPlayer := PlayerStateSchema.Network
const KEEP := 32
static var KNOCK_DECAY := exp(-CFG.player_knock_decay_rate * ActorStep.DT)
var map_px := Vector2.ZERO
var frames: Array[Array] = []
var latest_tick: int:
	get: return frames[-1][Frame.TICK] if not frames.is_empty() else -1
var latest_players: Dictionary:
	get: return frames[-1][Frame.WORLD]["players"] if not frames.is_empty() else {}
var render_tick := 0.0
var _clock := SnapshotClock.new()

func reset() -> void:
	frames.clear()


func push(tick: int, world: Dictionary) -> void:
	if tick <= latest_tick:
		return
	# 插值以原始服务器快照为端点。相邻渲染帧可以从相同快照得到不同的显示位置。
	if frames.is_empty() or tick - latest_tick > 2 * KEEP:
		frames.clear()
		render_tick = _clock.start(tick)
	frames.append([tick, world])
	while frames.size() > KEEP:
		frames.pop_front()
		if render_tick < frames[0][Frame.TICK]:
			render_tick = _clock.start(tick)

func advance(delta: float, local_role: int) -> Dictionary:
	render_tick = _clock.advance(render_tick, latest_tick, delta)
	return sample(render_tick, local_role)

func sample(tick: float, local_role := 0) -> Dictionary:
	while frames.size() > 2 and frames[1][Frame.TICK] <= tick:
		frames.pop_front()
	var from := frames[0]
	var to := frames[1] if frames.size() > 1 else from
	var ahead := minf(tick - to[Frame.TICK], SnapshotClock.MAX_EXTRAPOLATION)
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
