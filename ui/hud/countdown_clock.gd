class_name CountdownClock
extends RefCounted

# 广播层那个「3 / 2 / 1」的本地走秒器(纯逻辑:不碰节点、不碰网络,时间由调用方给 delta)。
# ★★ 两条不变量(2026-11-01 用户报「开局 3s 倒计时最后 1 秒显示不出来」):
#   ① 重复 start 绝不**回拨**:服务器在 COUNTDOWN 期间每 0.5s 重播当前剩余(它是权威锚点),客户端只在
#      「更短」时采纳 ⇒ 本地时钟只会被拉短、不会被拨回,数字因此单调不增(不会 3→2→3)。
#   ② 只有走到 0 才算结束;显示值钳到 ≥1 ⇒ 最后一秒一定以 "1" 走满,不会被提前收掉。
# 单个数字显示多久由 ceil 决定:剩余 (2,3] 显示 3、(1,2] 显示 2、(0,1] 显示 1。

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
