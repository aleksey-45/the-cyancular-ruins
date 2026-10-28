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
	# 播放缓冲只保存表现数据，避免每个渲染帧深拷贝武器驱动状态和弹丸回滚锚点。
	var shown := {"players": {}, "pickups": world["pickups"]}
	for role in world["players"]:
		var actor: Dictionary = world["players"][role].duplicate()
		actor.erase("driver")
		actor.erase("input")
		actor.erase("rewind_path")
		shown["players"][role] = actor
	frames.append({"tick": tick, "world": shown})
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
	var result: Dictionary = from["world"].duplicate(true) if weight < 1.0 else to["world"].duplicate(true)
	for group in ["players", "pickups"]:
		for id in result[group]:
			var state: Dictionary = result[group][id]
			if from["world"][group].has(id) and to["world"][group].has(id):
				var a: Dictionary = from["world"][group][id]
				var b: Dictionary = to["world"][group][id]
				var movement := GridPathfinder.toroidal_delta_px(a["pos"], b["pos"], map_px.x, map_px.y)
				if (group != "players" or a["epoch"] == b["epoch"]) and movement.length() < 256.0:
					state["pos"] = a["pos"] + movement * weight
					state["vel"] = a["vel"].lerp(b["vel"], weight)
			if tick > to["tick"]:
				state["pos"] += state["vel"] * minf(tick - to["tick"], MAX_EXTRAPOLATION) / 60.0
			state["pos"] = GridPathfinder.wrap_to_range(state["pos"], map_px.x, map_px.y)
	return result
