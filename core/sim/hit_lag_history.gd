extends RefCounted


const CAPACITY := 24

var _ticks: Array[int] = []
var _frames: Dictionary = {}


func push(tick: int, entries: Dictionary) -> void:
	var frame: Dictionary = {}
	for role in entries:
		var e: Dictionary = entries[role]
		frame[int(role)] = {"p": e["p"], "r": e["r"]}
	if _frames.has(tick):
		_frames[tick] = frame
		return
	_frames[tick] = frame
	if _ticks.is_empty() or tick > _ticks[_ticks.size() - 1]:
		_ticks.append(tick)
	else:
		var i := _ticks.size() - 1
		while i >= 0 and _ticks[i] > tick:
			i -= 1
		_ticks.insert(i + 1, tick)
	while _ticks.size() > CAPACITY:
		_frames.erase(_ticks[0])
		_ticks.remove_at(0)


func latest_tick() -> int:
	return _ticks[_ticks.size() - 1] if not _ticks.is_empty() else 0


func nearest_tick(t: int) -> int:
	if _ticks.is_empty():
		return -1
	if t <= _ticks[0]:
		return _ticks[0]
	if t >= _ticks[_ticks.size() - 1]:
		return _ticks[_ticks.size() - 1]
	var lo := 0
	var hi := _ticks.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if _ticks[mid] <= t:
			lo = mid
		else:
			hi = mid - 1
	return _ticks[lo]


func pos_for(role: int, t: int) -> Vector2:
	var frame := _frame_at(t)
	if frame.is_empty() or not frame.has(int(role)):
		return Vector2.ZERO
	var e: Dictionary = frame[int(role)]
	var p: Vector2 = e["p"]
	return p


func rect_for(role: int, t: int) -> Rect2:
	var frame := _frame_at(t)
	if frame.is_empty() or not frame.has(int(role)):
		return Rect2()
	var e: Dictionary = frame[int(role)]
	var p: Vector2 = e["p"]
	var r: Rect2 = e["r"]
	return Rect2(p + r.position, r.size)


func clear() -> void:
	_ticks.clear()
	_frames.clear()


func size() -> int:
	return _ticks.size()


func _frame_at(t: int) -> Dictionary:
	var tick := nearest_tick(t)
	if tick < 0:
		return {}
	var frame: Dictionary = _frames.get(tick, {})
	return frame
