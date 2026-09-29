extends SceneTree

# Beta 时间经济冒烟(-s 数据级):四条结算缝的公式与过滤口径。
# 用法:godot --headless --path . -s res://tests/time_economy_smoke.gd

var _fails: Array[String] = []


func _init() -> void:
	_test_accounts_and_tick()
	_test_kill()
	_test_damage()
	_test_blocks()
	if _fails.is_empty():
		print("TIME ECONOMY OK(账户/tick/击杀/伤害/拆砖/过滤口径)")
		quit(0)
	else:
		print("TIME ECONOMY FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		quit(1)


func _chk(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)


func _near(got: float, want: float, what: String) -> void:
	_chk(absf(got - want) <= 0.001, "%s(得 %s 期望 %s)" % [what, str(got), str(want)])


func _test_accounts_and_tick() -> void:
	var e := TimeEconomy.new(TimeRules.new(), [1, 2])
	_near((e.accounts[1] as GrainAccount).balance, 1000.0, "初始账户 1000")
	_near((e.accounts[2] as GrainAccount).balance, 1000.0, "第二个 role 也有账户")
	e.tick(1.0)
	_near((e.accounts[1] as GrainAccount).short_used, 0.0, "tick 回复(无消耗时应回窗/不动)")
	var p := e.state_payload()
	_chk(p.has(1) and p[1].has("b") and p[1].has("cap"), "镜像载荷含余额与上限")


func _test_kill() -> void:
	var rules := TimeRules.new()
	var e := TimeEconomy.new(rules, [1, 2])
	(e.accounts[2] as GrainAccount).deposit(600)   # 受害者攒到 1600
	e.award_kill(1, 2)
	_near((e.accounts[1] as GrainAccount).balance, 1000.0 + 1600.0 * 0.5, "击杀得受害者余额一半")
	_near((e.accounts[2] as GrainAccount).balance, 1600.0, "被击杀者余额不减")
	# 归因不到 / 自杀:谁都不给
	var b0 := (e.accounts[1] as GrainAccount).balance
	e.award_kill(0, 2)
	e.award_kill(2, 2)
	_near((e.accounts[1] as GrainAccount).balance, b0, "无归因击杀不结算")
	_near((e.accounts[2] as GrainAccount).balance, 1600.0, "自杀不结算")


func _test_damage() -> void:
	var e := TimeEconomy.new(TimeRules.new(), [1, 2])
	e.award_damage(1, 2, 10)
	_near((e.accounts[1] as GrainAccount).balance, 1040.0, "10 点伤害 ×4 = +40")
	var b0 := (e.accounts[1] as GrainAccount).balance
	e.award_damage(0, 2, 10)      # 归因不到
	e.award_damage(2, 2, 10)      # 打自己
	e.award_damage(1, 2, 0)       # 0 伤害
	_near((e.accounts[1] as GrainAccount).balance, b0, "无归因/自伤/零伤不结算")


func _test_blocks() -> void:
	var e := TimeEconomy.new(TimeRules.new(), [1, 2])
	e.award_blocks(1, 3)
	_near((e.accounts[1] as GrainAccount).balance, 1030.0, "3 个 16px 子格 ×10 = +30")
	var b0 := (e.accounts[1] as GrainAccount).balance
	e.award_blocks(0, 5)
	e.award_blocks(1, 0)
	_near((e.accounts[1] as GrainAccount).balance, b0, "无归因/零块不结算")
	# 上限夹断
	e.award_blocks(2, 100000)
	_chk((e.accounts[2] as GrainAccount).balance <= 1800.0 + 0.001, "入账夹上限 1800")
