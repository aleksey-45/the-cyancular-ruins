class_name CountdownClock
extends RefCounted

var _remaining := 0.0

func start(seconds: float) -> int:
	_remaining = minf(_remaining, seconds) if _remaining > 0.0 else seconds
	return maxi(ceili(_remaining), 1)

func stop() -> void:
	_remaining = 0.0

func tick(delta: float) -> int:
	_remaining = maxf(0.0, _remaining - delta)
	return ceili(_remaining)
