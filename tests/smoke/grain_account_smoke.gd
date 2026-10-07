extends SceneTree

# 时间颗粒账户状态机冒烟测试：
# 验证 GrainAccount 纯逻辑状态机：初始额度、消耗扣除、自动恢复速率、
# 透支惩罚深度计算、强制锁定与偿还解锁，以及 PvP 自定义参数支持。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/grain_account_smoke.gd

var _fails: Array[String] = []


func _init() -> void:
	_test_basic()
	_test_window_regen()
	_test_loan_and_lock()
	_test_lock_release()
	_test_balance_floor()
	_test_deposit_cap()
	_test_custom_params()
	if _fails.is_empty():
		print("GRAIN ACCOUNT OK(初始/消耗/窗恢复/贷款/锁定/解锁/余额底线/入账夹上限/自定义参数(PvP))")
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
	a.spend(1.0, 100.0)   # 借满 100 -> 锁
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
	a.regen(1.0)             # 偿还透支 50 -> 贷 80... 不对:先偿还透支 50,贷 100-50=50
	_near(a.loan_used, 50.0, 0.01, "1 秒先还贷 50")
	_chk(a.locked, "贷未清仍锁")
	a.regen(1.0)             # 再还 50 -> 贷清 -> 解锁;窗也开始回
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


# ── 自定义参数组(PvP 语义,2026-09-28):初始/上限/短期时间窗口/回复/透支额全由构造参数传入 ──
# 断言的是"参数真的生效"而不是"单机的默认值还在":
#   - PvP 的透支上限 = 短期额度(账户本身不透支);
#   - 余额永不为负(透支只发生在短期时间窗口那一档);
#   - 透支达到上限锁定 -> 回复先偿还透支 -> 还清解锁。
func _test_custom_params() -> void:
	var a := GrainAccount.new(1000.0, 1800.0, 250.0, 50.0, 250.0)
	_near(a.balance, 1000.0, 1e-3, "自定义初始值")
	_near(a.cap, 1800.0, 1e-3, "自定义上限")
	_near(a.window, 250.0, 1e-3, "自定义短时窗")
	_near(a.regen_rate, 50.0, 1e-3, "自定义回复")
	_near(a.loan_max, 250.0, 1e-3, "贷款上限 = 短时额度")
	# 烧满短期时间窗口(250) -> 继续消耗进透支;透支上限 250 -> 透支达到上限后立即锁定
	a.spend(250.0 / 150.0, 150.0)          # 正好用完短期时间窗口
	_near(a.short_used, 250.0, 1e-3, "短时窗应正好用满")
	_near(a.loan_used, 0.0, 1e-3, "此时不该有贷款")
	a.spend(250.0 / 150.0, 150.0)          # 再烧一个窗的量 -> 全进透支并透支达到上限
	_near(a.loan_used, 250.0, 1e-3, "贷款应到上限(250)")
	_near(a.loan_depth(), 1.0, 1e-3, "贷满时深度应为 1")
	_chk(a.locked, "贷满应强制锁定")
	_chk(not a.can_spend(), "锁定期间不可耗(两键空转)")
	# 余额底线:无论如何不透支(继续 spend 只会被挡)
	var bal_before := a.balance
	_chk(a.spend(10.0, 150.0) == 0.0, "锁定期间 spend 应返回 0")
	_near(a.balance, bal_before, 1e-6, "锁定期间余额不变")
	_chk(a.balance >= 0.0, "余额永不为负")
	# 回复先偿还透支:250/50 = 5s 还清 -> 解锁
	a.regen(5.0)
	_near(a.loan_used, 0.0, 1e-3, "回补应先还清贷款")
	_chk(not a.locked, "还清后应解锁")
	_chk(a.can_spend(), "解锁后恢复可耗")
	# 余额被烧到 0 时:透支只发生在短期时间窗口那一档,余额本身不越过 0
	var b := GrainAccount.new(10.0, 1800.0, 250.0, 50.0, 250.0)
	b.spend(10.0 / 150.0, 150.0)
	_near(b.balance, 0.0, 1e-3, "余额烧空应停在 0")
	_chk(not b.can_spend(), "余额为 0 不可耗")
