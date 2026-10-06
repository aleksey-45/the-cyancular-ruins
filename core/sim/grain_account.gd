class_name GrainAccount
extends RefCounted

# 时间粒子账户核心逻辑：包含总余额管理、短期可用额度与透支状态机。纯逻辑实现，不依赖场景（支持 -s 独立测试）。
#
# 数值模型（怀表系统设计）：
#   · balance     总余额（0..GRAIN_CAP，怀表白色短指针指示满圈；结晶充值只计入此处）
#   · short_used  短期已用额度（0..SHORT_WINDOW，红色长指针主圈；消耗时顺时针增加，恢复时逆时针回退）
#   · loan_used   已透支额度（0..LOAN_LIMIT，红色长指针额外 1/4 圈；短期额度耗尽后继续消耗转入透支）
#   · loan_depth  = loan_used / LOAN_LIMIT ∈ [0,1]，驱动环境反馈（画面提亮、色差分离、敌人相对加速、音调升高）
#   · locked      透支耗尽后的锁定状态：借满 LOAN_LIMIT 时触发，长指针随自动恢复逐步还清；
#                 锁定期间无法使用任何时间技能。
#
# 消耗（spend）：每次扣减同步扣除总余额与短期额度；短期额度耗尽后溢出部分计入透支额度；透支达到上限后触发锁定。
# 恢复（regen）：默认 50/s，优先偿还透支额度，还清后再恢复短期额度（还款过程中保持锁定，完全还清后解锁）。
# 充值（deposit）：吸收结晶时直接增加总余额（不超过上限），不影响指针当前位置。

signal balance_changed(balance: float)
signal window_changed(short_used: float, loan_used: float)
signal loan_depth_changed(depth: float)
signal loan_locked
signal loan_unlocked

# ── 参数配置（单机使用 TimeParams 默认值；PvP 使用 TimeRules.make_account()，透支上限支持按局调整）──
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


## 消耗粒子：时长 delta（秒）× rate（粒子/秒）。返回实际扣除的粒子数（余额不足或处于锁定状态时小于预期值）。
func spend(delta: float, rate: float) -> float:
	if locked or balance <= 0.0 or delta <= 0.0 or rate <= 0.0:
		return 0.0
	var got: float = minf(rate * delta, balance)
	balance -= got
	# 短期额度耗尽后，溢出部分转入透支额度；透支达到上限触发强制锁定
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


## 每帧自动恢复：优先偿还透支额度，还清后恢复短期额度；若处于锁定状态，还清透支瞬间触发解锁。
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


## 结晶充值（如击杀乌鸫获得 300 粒子）：直接增加总余额，不超过上限。返回实际充值量。
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
