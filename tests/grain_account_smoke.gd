extends SceneTree

# 颗粒账户冒烟(-s 数据级):余额/上限/短时窗/贷款/锁定/恢复/入账 全语义。
# 用法:godot --headless --path . -s res://tests/grain_account_smoke.gd

var _fails: Array[String] = []


func _init() -> void:
	_test_basic()
	_test_window_regen()
	_test_loan_and_lock()
	_test_lock_release()
	_test_balance_floor()
	_test_deposit_cap()
	if _fails.is_empty():
		print("GRAIN ACCOUNT OK(初始/消耗/窗恢复/贷款/锁定/解锁/余额底线/入账夹上限)")
		quit(0)
	else:
		print("GRAIN ACCOUNT FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		quit(1)


func _chk(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)


func _near(got: float, want: float, eps: float, what: String) -> void:
	_chk(absf(got - want) <= eps, "%s(得 %s 期望 %s±%s)" % [what, str(got), str(want), str(eps)])


func _test_basic() -> void:
	var a := GrainAccount.new()
	_chk(a.balance == TimeParams.GRAIN_INITIAL, "初始余额错误")
	_chk(a.can_spend(), "初始应可消耗")
	var got: float = a.spend(1.0, TimeParams.COST_REWIND)
	_near(got, TimeParams.COST_REWIND, 0.01, "1 秒回溯应扣 120")
	_near(a.balance, TimeParams.GRAIN_INITIAL - TimeParams.COST_REWIND, 0.01, "余额扣减")
	_near(a.short_used, TimeParams.COST_REWIND, 0.01, "短时窗推进=消耗额")
	var a2 := GrainAccount.new(99999)
	_chk(a2.balance == TimeParams.GRAIN_CAP, "超大初始应夹上限")


func _test_window_regen() -> void:
	var a := GrainAccount.new()
	a.spend(2.0, 100.0)   # 窗用 200
	_near(a.short_used, 200.0, 0.01, "窗=200")
	a.regen(1.0)          # 50/s 回 50
	_near(a.short_used, 150.0, 0.01, "1 秒恢复 50")
	a.regen(10.0)         # 回到头不越界
	_near(a.short_used, 0.0, 0.01, "恢复不下穿 0")


func _test_loan_and_lock() -> void:
	var a := GrainAccount.new()
	var locked_fired := [0]   # 数组承载:lambda 按值捕获局部 int,直接 += 外部看不到
	a.loan_locked.connect(func() -> void: locked_fired[0] += 1)
	a.spend(4.0, 100.0)   # 窗满 400
	_near(a.short_used, TimeParams.SHORT_WINDOW, 0.01, "窗满")
	_near(a.loan_used, 0.0, 0.01, "未借入")
	a.spend(0.5, 100.0)   # 借 50
	_near(a.loan_used, 50.0, 0.01, "借入 50")
	_near(a.loan_depth(), 0.5, 0.001, "贷款深度 0.5")
	_chk(a.can_spend(), "贷中仍可耗(未满)")
	_chk(locked_fired[0] == 0, "未贷满不应锁")
	a.spend(1.0, 100.0)   # 借满 100 → 锁
	_near(a.loan_used, TimeParams.LOAN_LIMIT, 0.01, "借满 100")
	_chk(locked_fired[0] == 1, "贷满应发 loan_locked")
	_chk(a.locked, "贷满应 locked")
	_chk(not a.can_spend(), "锁定不可耗")
	var got: float = a.spend(1.0, 100.0)
	_near(got, 0.0, 0.001, "锁定消耗返回 0")
	_near(a.balance, TimeParams.GRAIN_INITIAL - 550.0, 0.01, "锁定不再扣余额")


func _test_lock_release() -> void:
	var a := GrainAccount.new()
	var unlocked := [0]   # 同上:数组承载可变计数
	a.loan_unlocked.connect(func() -> void: unlocked[0] += 1)
	a.spend(4.0, 100.0)      # 窗满
	a.spend(0.3, 100.0)      # 借 30
	a.spend(1.0, 100.0)      # 借满锁
	a.regen(1.0)             # 还贷 50 → 贷 80... 不对:先还贷 50,贷 100-50=50
	_near(a.loan_used, 50.0, 0.01, "1 秒先还贷 50")
	_chk(a.locked, "贷未清仍锁")
	a.regen(1.0)             # 再还 50 → 贷清 → 解锁;窗也开始回
	_near(a.loan_used, 0.0, 0.01, "贷款还清")
	_chk(unlocked[0] == 1, "还清应解锁一次")
	_chk(not a.locked, "解锁后 locked=false")
	_chk(a.can_spend(), "解锁后可耗")
	_near(a.short_used, 400.0, 0.5, "解锁瞬间窗应仍在满位附近(还贷优先)")
	a.regen(2.0)
	_near(a.short_used, 300.0, 0.6, "解锁后窗继续 50/s 回拨")


func _test_balance_floor() -> void:
	var a := GrainAccount.new(50)
	var got: float = a.spend(1.0, TimeParams.COST_REWIND)
	_near(got, 50.0, 0.01, "余额不足按余量扣")
	_near(a.balance, 0.0, 0.001, "余额归零")
	_chk(not a.can_spend(), "零余额不可耗")


func _test_deposit_cap() -> void:
	var a := GrainAccount.new(4950)
	var got: int = a.deposit(TimeParams.ELITE_GRAIN_DROP)
	_chk(got == 50, "入账夹上限(只进 50)")
	_near(a.balance, TimeParams.GRAIN_CAP, 0.001, "余额=上限")
	_chk(a.deposit(300) == 0, "满仓入账返回 0")
	var b := GrainAccount.new(1000)
	_chk(b.deposit(300) == 300, "正常入账 300")
	_near(b.balance, 1300.0, 0.001, "入账后余额")
