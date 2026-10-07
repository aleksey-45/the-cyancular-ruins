class_name GrainAccount
extends RefCounted

# 时间颗粒账户（怀表系统核心状态机）：总量余额 + 短期额度 + 透支状态机。纯逻辑零场景依赖。
#
# 模型结构：
#   - balance     总余额（0..GRAIN_CAP，白短针一圈；结晶入账仅增加此处）
#   - short_used  短期窗口已消耗额度（0..SHORT_WINDOW，红长针主圈；消耗顺时针推进，恢复逆时针回拨）
#   - loan_used   已透支额度（0..LOAN_LIMIT，红长针额外 1/4 圈；短期时间窗口满后继续消耗即计入透支）
#   - loan_depth  = loan_used / LOAN_LIMIT ∈ [0, 1]，作为视觉特效与敌人时间流速倍率的驱动变量
#   - locked      透支达到上限后的强制锁定：透支达到上限 LOAN_LIMIT 触发，透支额度逐步偿还完毕前锁定技能
#
# 操作接口：
#   - 消耗：同时扣除总余额与短期额度；超出短期额度后计入透支；透支达上限时锁定。
#   - 恢复：以固定速率恢复，优先偿还透支额度，还清透支后解除锁定并恢复短期额度。
#   - 吸收结晶：结晶吸收增加总余额（不超过上限）。

signal balance_changed(balance: float)
signal window_changed(short_used: float, loan_used: float)
signal loan_depth_changed(depth: float)
signal loan_locked
signal loan_unlocked

# ── 参数配置（单人模式使用 TimeParams 默认值；多人对战可通过参数自定义）──
var initial := TimeParams.GRAIN_INITIAL
var cap := TimeParams.GRAIN_CAP
var window := TimeParams.SHORT_WINDOW
var regen_rate := TimeParams.SHORT_REGEN
var loan_max := TimeParams.LOAN_LIMIT

var balance: float = TimeParams.GRAIN_INITIAL
var short_used: float = 0.0
var loan_used: float = 0.0
var locked := false


func _init(initial_ := TimeParams.GRAIN_INITIAL, cap_ := TimeParams.GRAIN_CAP,
		window_ := TimeParams.SHORT_WINDOW, regen_ := TimeParams.SHORT_REGEN,
		loan_max_ := TimeParams.LOAN_LIMIT) -> void:
	initial = initial_
	cap = cap_
	window = window_
	regen_rate = regen_
	loan_max = loan_max_
	balance = clampf(initial, 0.0, cap)


func can_spend() -> bool:
	return not locked and balance > 0.0


func loan_depth() -> float:
	if loan_max <= 0.0:
		return 0.0
	return loan_used / loan_max


## 消耗 delta 秒 × rate 颗粒/秒。返回实际扣掉的颗粒数(余额/锁定不足时 < rate·delta)。
func spend(delta: float, rate: float) -> float:
	if locked or balance <= 0.0 or delta <= 0.0 or rate <= 0.0:
		return 0.0
	var got: float = minf(rate * delta, balance)
	balance -= got
	# 指针推进与消耗同额:短期时间窗口满 → 溢出进透支;透支达到上限 → 强制锁定
	short_used += got
	if short_used > window:
		var over: float = short_used - window
		short_used = window
		loan_used += over
		if loan_used >= loan_max:
			loan_used = loan_max
			_emit_window()
			if not locked:
				locked = true
				loan_locked.emit()
	_emit_window()
	balance_changed.emit(balance)
	return got


## 每帧恢复(无论是否在消耗都照走):50/s,优先偿还透支，还清后恢复短期额度;锁定中还清透支额度 → 解锁。
func regen(delta: float) -> void:
	if delta <= 0.0:
		return
	var pay: float = regen_rate * delta
	if loan_used > 0.0:
		var pay_loan: float = minf(pay, loan_used)
		loan_used -= pay_loan
		pay -= pay_loan
		if is_equal_approx(loan_used, 0.0) or loan_used < 0.0001:
			loan_used = 0.0
	if pay > 0.0:
		short_used = maxf(short_used - pay, 0.0)
	var was_locked := locked
	if locked and loan_used <= 0.0:
		locked = false
		_emit_window()
		loan_unlocked.emit()
		was_locked = false
	if not is_equal_approx(pay, 0.0) or was_locked:
		_emit_window()


## 结晶入账(乌鸫击杀 300 等):只进总余额,夹上限。返回实际入账量。
func deposit(amount: int) -> int:
	if amount <= 0:
		return 0
	var room: int = int(cap) - int(ceil(balance))
	var got: int = mini(amount, maxi(room, 0))
	balance += got
	balance_changed.emit(balance)
	return got


func _emit_window() -> void:
	window_changed.emit(short_used, loan_used)
	loan_depth_changed.emit(loan_depth())
