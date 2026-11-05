class_name SnapshotBuffer
extends RefCounted

const DELAY_TICKS := 6.0
const MAX_EXTRAPOLATION := 6.0
const KEEP := 32
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
	var weight := clampf((tick - from["tick"]) / maxf(1.0, to["tick"] - from["tick"]), 0.0, 1.0)
	var source: Dictionary = from["world"] if weight < 1.0 else to["world"]
	var result := {"players": {}, "pickups": {}}
	for group in ["players", "pickups"]:
		# 玩家与掉落物都是槽记录，位置、速度与纪元各占固定下标。
		var pos_slot: int = PlayerStateSchema.slot("pos") if group == "players" else PickupState.POS
		var vel_slot: int = PlayerStateSchema.slot("vel") if group == "players" else PickupState.VEL
		var epoch_slot: int = PlayerStateSchema.slot("epoch") if group == "players" else -1
		for id in source[group]:
			# 只改位置与速度；其余槽保持只读，不递归复制。
			var state: Array = source[group][id].duplicate()
			result[group][id] = state
			if from["world"][group].has(id) and to["world"][group].has(id):
				var a: Array = from["world"][group][id]
				var b: Array = to["world"][group][id]
				var movement := GridPathfinder.toroidal_delta_px(a[pos_slot], b[pos_slot], map_px.x, map_px.y)
				if (epoch_slot < 0 or a[epoch_slot] == b[epoch_slot]) and movement.length() < 256.0:
					state[pos_slot] = a[pos_slot] + movement * weight
					state[vel_slot] = a[vel_slot].lerp(b[vel_slot], weight)
			if tick > to["tick"]:
				state[pos_slot] += state[vel_slot] * minf(tick - to["tick"], MAX_EXTRAPOLATION) / 60.0
			state[pos_slot] = GridPathfinder.wrap_to_range(state[pos_slot], map_px.x, map_px.y)
	return result
