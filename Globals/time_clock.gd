class_name TimeClock
extends RefCounted

# 单钟账本(GDD v0.3 §1.2 / §12 决议 1、2):一根世界针 W,既是地图状态坐标,也是全部时间资源。
#
#   · 自然衰减 / 消费(交易·合成·封存) → W 减小(走向 T_final)
#   · 击杀回收 / 解封 / Boss 巨块       → W 增大(回拨,走向灾前)
#   · scale = 子弹时间/决策时停(0=停);flow = 区域流速场 F
#
# 所有时间收支都走本账本(§4.1),便于结算画面与二期联机(共享针)复用;
# 本类不碰任何世界状态(改瓦片/刷怪由事件执行方负责),所以 -s 探针可直接断言。

signal w_changed(w: float, applied: float, reason: String)  # applied 带符号(+回拨/−推进)
signal phase_changed(phase: int, prev: int)
signal final_reached()      # W 归零 = 走到 T_final(失败/终末)
signal pre_ruin_reached()   # W ≥ 灾前 = 真结局条件

var w0: float = TimeParams.W0_DEFAULT
var w: float = TimeParams.W0_DEFAULT
var scale: float = TimeParams.SCALE_NORMAL   # 子弹时间/决策时停
var flow: float = TimeParams.FLOW_NORMAL     # 流速场系数 F

# 结算统计(§4.8 结算画面:本局回收总量 / 消费总量 / 存活时长)
var recovered_total: float = 0.0
var spent_total: float = 0.0
var elapsed_real: float = 0.0

var _acc: float = 0.0          # 未满一个 10ms 粒度的余量(真实秒 × 倍率)
var _phase: int = 0
var _final_emitted := false
var _pre_ruin_emitted := false


func _init(start_w: float = TimeParams.W0_DEFAULT) -> void:
	w0 = clampf(start_w, 0.0, TimeParams.FINAL_SECONDS)
	w = w0
	_phase = phase()


# ── 派生量 ──────────────────────────────────────────────────

## 毁灭度 D(0=灾前,1=终末)。
func destruction() -> float:
	return clampf((TimeParams.FINAL_SECONDS - w) / TimeParams.FINAL_SECONDS, 0.0, 1.0)


## 世界阶段序号(0=灾前余晖 … 3=终末)。
func phase() -> int:
	return TimeParams.phase_of(destruction())


## 当前时间倍率 = 子弹时间 × 流速场 × 阶段衰减。elapse() 用它换算真实秒 → 世界秒。
func time_multiplier() -> float:
	return scale * flow * TimeParams.decay_multiplier_of(destruction())


func is_final() -> bool:
	return w <= 0.0


func is_pre_ruin() -> bool:
	return w >= TimeParams.PRE_RUIN_TARGET


## 表盘文本("T-14.30",百分秒)。
func label() -> String:
	return TimeParams.format_clock(w)


## 某类敌人本次击杀的回拨量(秒;已按流速场缩放)。
func kill_reward(enemy_key: String) -> float:
	return TimeParams.kill_seconds(enemy_key) * flow


# ── 收支 ────────────────────────────────────────────────────

## 推进真实时间 delta 秒(经 10ms 粒度量化 × 倍率)。返回实际作用到 W 的世界秒数(≥0)。
## 调用方用返回值做阈值跨越判定:elapsed = clock.elapse(delta); timeline.crossings(before, clock.w)。
func elapse(delta: float) -> float:
	if delta <= 0.0 or w <= 0.0:
		return 0.0
	elapsed_real += delta
	_acc += delta * time_multiplier()
	if _acc < TimeParams.GRANULARITY:
		return 0.0
	# +1e-9 防浮点下溢把正好一个粒度的推进算成 0 步
	var steps := floori((_acc + 1e-9) / TimeParams.GRANULARITY)
	var applied := float(steps) * TimeParams.GRANULARITY
	_acc -= applied
	return -_apply(-applied, "decay")


## 回拨:W 增大(击杀回收 / 解封 / Boss 巨块)。返回实际回拨量(秒,可能被灾前上限截断)。
func recover(seconds: float, reason: String = "recover") -> float:
	if seconds <= 0.0:
		return 0.0
	var got := _apply(seconds, reason)
	recovered_total += got
	return got


## 消费:W 减小(交易 / 铸造封存 / 死亡惩罚)。返回实际推进量。
func spend(seconds: float, reason: String = "spend") -> float:
	if seconds <= 0.0:
		return 0.0
	var got := -_apply(-seconds, reason)
	spent_total += got
	return got


## 击杀回收(§4.1):既是资源入袋,也是世界微恢复——同一件事。
func recover_kill(enemy_key: String) -> float:
	return recover(kill_reward(enemy_key), "kill:" + enemy_key)


## 决策时停 / 慢放(§12 决议 3):副作用只有 scale,不冻结场景树。
func set_scale(v: float) -> void:
	scale = clampf(v, 0.0, 10.0)


func set_flow(v: float) -> void:
	flow = maxf(v, 0.0)


# ── 内部 ────────────────────────────────────────────────────

## 唯一改 W 的入口:夹取 [0, FINAL]、发信号、返回带符号实际变化量。
func _apply(delta_w: float, reason: String) -> float:
	var before := w
	w = clampf(w + delta_w, 0.0, TimeParams.FINAL_SECONDS)
	if w <= 0.0:
		_acc = 0.0
	var applied := w - before
	if not is_zero_approx(applied):
		w_changed.emit(w, applied, reason)
		var p := phase()
		if p != _phase:
			var prev := _phase
			_phase = p
			phase_changed.emit(p, prev)
		if w <= 0.0 and not _final_emitted:
			_final_emitted = true
			final_reached.emit()
		if w >= TimeParams.PRE_RUIN_TARGET and not _pre_ruin_emitted:
			_pre_ruin_emitted = true
			pre_ruin_reached.emit()
	return applied
