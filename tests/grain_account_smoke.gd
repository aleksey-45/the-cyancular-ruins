extends SceneTree

# 时间粒子账户冒烟测试（-s 数据级）：余额、上限、短期额度、透支、锁定、恢复与入账全流程验证。
# 用法:godot --headless --path . -s res://tests/grain_account_smoke.gd

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
		print("GRAIN ACCOUNT OK(初始/消耗/短期额度恢复/透支/锁定/解锁/余额下限/入账限制/自定义参数)")
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
	_near(a.short_used, TimeParams.COST_REWIND, 0.01, "短期额度使用量应等于消耗量")
	var a2 := GrainAccount.new(99999)
	_chk(a2.balance == TimeParams.GRAIN_CAP, "超大初始应夹上限")


func _test_window_regen() -> void:
	var a := GrainAccount.new()
	a.spend(2.0, 100.0)   # 短期额度消耗 200
	_near(a.short_used, 200.0, 0.01, "短期已使用 200")
	a.regen(1.0)          # 50/s 回复 50
	_near(a.short_used, 150.0, 0.01, "1 秒恢复 50")
	a.regen(10.0)         # 恢复至初始状态不越界
	_near(a.short_used, 0.0, 0.01, "恢复不下穿 0")


func _test_loan_and_lock() -> void:
	var a := GrainAccount.new()
	var locked_fired := [0]   # 数组承载:lambda 按值捕获局部 int,直接 += 外部看不到
	a.loan_locked.connect(func() -> void: locked_fired[0] += 1)
	a.spend(4.0, 100.0)   # 耗尽短期额度 400
	_near(a.short_used, TimeParams.SHORT_WINDOW, 0.01, "短期额度耗尽")
	_near(a.loan_used, 0.0, 0.01, "未产生透支")
	a.spend(0.5, 100.0)   # 透支 50
	_near(a.loan_used, 50.0, 0.01, "透支额度累计 50")
	_near(a.loan_depth(), 0.5, 0.001, "透支深度 0.5")
	_chk(a.can_spend(), "透支状态下未达上限时仍可消耗")
	_chk(locked_fired[0] == 0, "未达透支上限时不应触发锁定")
	a.spend(1.0, 100.0)   # 透支达上限 100 触发锁定
	_near(a.loan_used, TimeParams.LOAN_LIMIT, 0.01, "透支达上限 100")
	_chk(locked_fired[0] == 1, "达到透支上限应触发 loan_locked 信号")
	_chk(a.locked, "达到透支上限应进入锁定状态")
	_chk(not a.can_spend(), "锁定状态下禁止消耗")
	var got: float = a.spend(1.0, 100.0)
	_near(got, 0.0, 0.001, "锁定消耗返回 0")
	_near(a.balance, TimeParams.GRAIN_INITIAL - 550.0, 0.01, "锁定不再扣余额")


func _test_lock_release() -> void:
	var a := GrainAccount.new()
	var unlocked := [0]   # 同上:数组承载可变计数
	a.loan_unlocked.connect(func() -> void: unlocked[0] += 1)
	a.spend(4.0, 100.0)      # 短期额度耗尽
	a.spend(0.3, 100.0)      # 透支 30
	a.spend(1.0, 100.0)      # 透支满额触发锁定
	a.regen(1.0)             # 优先偿还透支：1.0 秒恢复 50 单位透支额度
	_near(a.loan_used, 50.0, 0.01, "1 秒优先偿还透支 50")
	_chk(a.locked, "透支未完全偿还时保持锁定")
	a.regen(1.0)             # 再次恢复 50，透支还清并解除锁定，短期额度开始恢复
	_near(a.loan_used, 0.0, 0.01, "透支额度已还清")
	_chk(unlocked[0] == 1, "透支还清应触发解除锁定信号")
	_chk(not a.locked, "解锁后 locked=false")
	_chk(a.can_spend(), "解锁后恢复可消耗状态")
	_near(a.short_used, 400.0, 0.5, "解除锁定瞬间短期额度仍处于满位状态（优先偿还透支）")
	a.regen(2.0)
	_near(a.short_used, 300.0, 0.6, "解除锁定后短期额度以 50/s 速率继续恢复")


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


# ── 自定义参数组（PvP 时间规则，2026-09-28）：初始值、上限、短期额度、恢复率、透支额度全由构造参数传入 ──
# 验证自定义参数正确生效：
#   · PvP 模式透支上限等于短期额度（账户总余额不透支至负数）；
#   · 余额永不为负（透支仅发生在短期额度层级）；
#   · 达到透支上限锁定 → 恢复时优先偿还透支 → 还清后解除锁定。
func _test_custom_params() -> void:
	var a := GrainAccount.new(1000.0, 1800.0, 250.0, 50.0, 250.0)
	_near(a.balance, 1000.0, 1e-3, "自定义初始值")
	_near(a.cap, 1800.0, 1e-3, "自定义上限")
	_near(a.window, 250.0, 1e-3, "自定义短期额度")
	_near(a.regen_rate, 50.0, 1e-3, "自定义恢复速率")
	_near(a.loan_max, 250.0, 1e-3, "透支上限应等于短期额度")
	# 消耗完短期额度（250）→ 继续消耗进入透支；透支达到上限 250 → 触发锁定
	a.spend(250.0 / 150.0, 150.0)          # 正好耗尽短期额度
	_near(a.short_used, 250.0, 1e-3, "短期额度应正好用满")
	_near(a.loan_used, 0.0, 1e-3, "此时尚未产生透支")
	a.spend(250.0 / 150.0, 150.0)          # 再次消耗相应额度 → 全部进入透支并达到上限
	_near(a.loan_used, 250.0, 1e-3, "透支应达到上限(250)")
	_near(a.loan_depth(), 1.0, 1e-3, "达到透支上限时深度应为 1.0")
	_chk(a.locked, "达到透支上限应强制锁定")
	_chk(not a.can_spend(), "锁定期间禁止继续消耗")
	# 余额底线：无论如何不透支至负数
	var bal_before := a.balance
	_chk(a.spend(10.0, 150.0) == 0.0, "锁定期间 spend 应返回 0")
	_near(a.balance, bal_before, 1e-6, "锁定期间余额不变")
	_chk(a.balance >= 0.0, "余额永不为负")
	# 恢复优先清偿透支：250/50 = 5s 还清后解除锁定
	a.regen(5.0)
	_near(a.loan_used, 0.0, 1e-3, "恢复应优先清偿透支额度")
	_chk(not a.locked, "透支还清后应解除锁定")
	_chk(a.can_spend(), "解除锁定后恢复可消耗状态")
	# 余额消耗至 0 时：透支仅发生在短期额度层级，账户余额自身保持在 0
	var b := GrainAccount.new(10.0, 1800.0, 250.0, 50.0, 250.0)
	b.spend(10.0 / 150.0, 150.0)
	_near(b.balance, 0.0, 1e-3, "余额耗尽应保持在 0")
	_chk(not b.can_spend(), "余额为 0 时禁止消耗")
