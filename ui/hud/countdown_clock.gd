class_name CountdownClock
extends RefCounted

# 广播层那个「3 / 2 / 1」的本地走秒器(纯逻辑:不碰节点、不碰网络,时间由调用方给 delta)。

const TICK_IDLE := 0        # 没在走(倒计时已结束 / 从未开始)
const TICK_RUNNING := 1     # 本 tick 仍在走
const TICK_FINISHED := 2    # 本 tick 走到 0(只报一次)

const MIN_DISPLAY := 1      # 显示下限:0.4 秒也必须显示 "1",不能显示 "0"

var _remaining := 0.0
var _running := false


# 开始 / 重锚。★ 已在走时取 min:调用方每收到一条 COUNTDOWN 就调一次,重复调用是常态。
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
