class_name CountdownClock
extends RefCounted

# 开局倒计时走秒器(纯逻辑,不碰 UI/节点):接口与 main 的 countdown_clock.gd 逐字一致,
# 供 Broadcast 一类宿主复制计数逻辑时直接 new + tick。三条硬规则:
#   · 重复 start 只采纳**更短**的剩余、绝不回拨(服务器 0.5s 重播当前剩余,数字单调不增);
#   · 显示 ceil(剩余) 且钳到至少 1 ⇒ 3→2→1 一个不落;
#   · 停表(tick 到 <=0)只发一次 TICK_FINISHED,之后是 TICK_IDLE。

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
