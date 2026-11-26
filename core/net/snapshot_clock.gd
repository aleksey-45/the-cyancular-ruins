class_name SnapshotClock
extends RefCounted

const MAX_EXTRAPOLATION := 2.0
const HZ := 60.0
const WINDOW := 8.0 * HZ
var _origin := 0
var _elapsed := 0.0
var _delay := 4.0
var _next_sample := 0.0
var _next_update := 30.0
var _ages: Array[Vector2] = []

func start(tick: int) -> float:
	_origin = tick
	_elapsed = 0.0
	_delay = 4.0
	_next_sample = 0.0
	_next_update = 30.0
	_ages.clear()
	return tick - _delay

func advance(view: float, latest: int, delta: float) -> float:
	var dt := delta * HZ
	_elapsed += dt
	var now := _origin + _elapsed
	while not _ages.is_empty() and _ages[0].x < _elapsed - WINDOW:
		_ages.pop_front()
	if _elapsed >= _next_update and _ages.size() >= 30:
		var ages := PackedFloat64Array()
		for sample in _ages:
			ages.append(sample.y)
		ages.sort()
		var low := ages[ceili(ages.size() * 0.05) - 1]
		_delay = clampf(ages[ceili(ages.size() * 0.99) - 1] + 3.0, low + 1.0, low + 8.0)
		_next_update = _elapsed + 15.0
	if _elapsed >= _next_sample:
		_ages.append(Vector2(_elapsed, now - latest))
		# 每 0.25 个模拟帧最多记一次样本，限制高刷新率下八秒窗口内的样本数。
		_next_sample = _elapsed + 0.25
	var error := now - _delay - (view + dt)
	return minf(view + dt * clampf(1.0 + error / 6.0, 0.85, 1.10), latest + MAX_EXTRAPOLATION)
