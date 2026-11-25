class_name GrainAccount
extends RefCounted

# 单人和 Beta 模式使用相同的时间技能消耗规则，这里保存余额、短期消耗量和透支量。

enum { BALANCE, SHORT_USED, LOAN_USED, LOCKED }

var cap: float
var window: float
var regen_rate: float
var loan_max: float

var balance: float
var short_used: float = 0.0
var loan_used: float = 0.0
var locked := false


func _init(initial: float = TimeParams.GRAIN_INITIAL, cap_: float = TimeParams.GRAIN_CAP,
		window_ := TimeParams.SHORT_WINDOW, regen_ := TimeParams.SHORT_REGEN,
		loan_max_ := TimeParams.LOAN_LIMIT) -> void:
	cap = cap_
	window = window_
	regen_rate = regen_
	loan_max = loan_max_
	balance = clampf(initial, 0.0, cap)

func capture_state() -> Array:
	return [balance, short_used, loan_used, locked]

func restore_state(values: Array) -> void:
	balance = values[BALANCE]
	short_used = values[SHORT_USED]
	loan_used = values[LOAN_USED]
	locked = values[LOCKED]

func can_spend() -> bool:
	return not locked and balance > 0.0


func loan_depth() -> float:
	if loan_max <= 0.0:
		return 0.0
	return loan_used / loan_max


## 按使用时长和每秒消耗量扣减余额。余额不足时扣完为止，返回这次实际花费的数量。
func spend(delta: float, rate: float) -> float:
	if locked or balance <= 0.0 or delta <= 0.0 or rate <= 0.0:
		return 0.0
	var got: float = minf(rate * delta, balance)
	balance -= got
	# 消耗超出短期额度的部分记为透支。透支达到上限后锁定时间技能。
	short_used += got
	if short_used > window:
		var over: float = short_used - window
		short_used = window
		loan_used += over
		if loan_used >= loan_max:
			loan_used = loan_max
			locked = true
	return got


## 恢复额度时优先偿还透支，多余的额度用于减少已有的短期消耗。透支归零后解除锁定。
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
	if locked and loan_used <= 0.0:
		locked = false


## 补充时间颗粒后返回实际到账数量。超出余额上限的部分不计入。
func deposit(amount: int) -> int:
	if amount <= 0:
		return 0
	var room: int = int(cap) - int(ceil(balance))
	var got: int = mini(amount, maxi(room, 0))
	balance += got
	return got
