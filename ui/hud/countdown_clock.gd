class_name CountdownClock
extends RefCounted

# 开局倒计时收到新的剩余时间时取较小值，避免服务器重复通知使显示数字回跳。

const TICK_IDLE := 0
const TICK_RUNNING := 1
const TICK_FINISHED := 2

const MIN_DISPLAY := 1

var _remaining := 0.0
var _running := false


func start(seconds: float) -> void:
	if _running:
		_remaining = minf(_remaining, seconds)
		return
	_remaining = maxf(seconds, 0.0)
	_running = true


func stop() -> void:
	_running = false
	_remaining = 0.0


func running() -> bool:
	return _running


func remaining() -> float:
	return _remaining


func text() -> String:
	return str(maxi(ceili(_remaining), MIN_DISPLAY))


func tick(delta: float) -> int:
	if not _running:
		return TICK_IDLE
	_remaining -= delta
	if _remaining > 0.0:
		return TICK_RUNNING
	stop()
	return TICK_FINISHED
