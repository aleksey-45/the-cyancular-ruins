extends SceneTree

# PvP 时间规则冒烟测试（-s 数据级）：默认参数配置、字典序列化往返、服务端数值限制、
# 账户参数映射（透支上限等于短期额度）以及环形缓冲区时长计算全流程验证。
# 用法:godot --headless --path . -s res://tests/time_rules_smoke.gd

var _fails: Array[String] = []


func _init() -> void:
	_test_defaults()
	_test_roundtrip()
	_test_clamp()
	_test_account_and_buffer()
	if _fails.is_empty():
		print("TIME RULES OK(默认值/往返/限制/账户映射/环形缓冲区时长)")
		quit(0)
	else:
		print("TIME RULES FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		quit(1)


func _chk(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)


func _test_defaults() -> void:
	var r := TimeRules.new()
	_chk(is_equal_approx(r.initial, 1000.0), "初始应 1000")
	_chk(is_equal_approx(r.cap, 1800.0), "上限应 1800")
	_chk(is_equal_approx(r.rewind_burn, 150.0), "回溯消耗速率应为 150/s")
	_chk(is_equal_approx(r.haste_burn, 70.0), "加速消耗速率应为 70/s")
	_chk(is_equal_approx(r.window, 250.0), "短期额度应为 250")
	_chk(is_equal_approx(r.regen, 50.0), "恢复速率应为 50/s")
	_chk(is_equal_approx(r.kill_ratio, 0.5), "击杀比例应 50%")
	_chk(r.block_gain == 10, "每子格破坏应 +10")
	_chk(r.damage_gain == 4, "每点伤害应 +4")
	_chk(is_equal_approx(r.haste_mult, 3.0), "加速倍率应 ×3")
	_chk(is_equal_approx(r.loan_limit(), 250.0), "透支上限应等于短期额度(250)")


func _test_roundtrip() -> void:
	var r := TimeRules.new()
	r.initial = 1200.0
	r.window = 300.0
	r.block_gain = 25
	r.kill_ratio = 0.75
	var d := r.to_dict()
	var r2 := TimeRules.from_dict(d)
	_chk(is_equal_approx(r2.initial, 1200.0) and is_equal_approx(r2.window, 300.0)
			and r2.block_gain == 25 and is_equal_approx(r2.kill_ratio, 0.75), "往返丢字段")
	# 缺字段 → 用默认值(老客户端/老包安全)
	var r3 := TimeRules.from_dict({})
	_chk(is_equal_approx(r3.initial, 1000.0) and r3.block_gain == 10, "空字典应回落默认值")


func _test_clamp() -> void:
	var r := TimeRules.new()
	r.initial = 99999.0
	r.cap = 1.0          # 比 initial 还小
	r.rewind_burn = 0.0
	r.regen = -5.0
	r.kill_ratio = 3.0
	r.block_gain = 100000
	r.damage_gain = -7
	r.haste_mult = 99.0
	r.clamp_self()
	_chk(r.initial <= TimeRules.R_INITIAL.y, "初始应被钳到上限")
	_chk(r.cap >= r.initial, "上限必须 ≥ 初始(钳制后 cap 跟着抬)")
	_chk(r.rewind_burn >= TimeRules.R_BURN.x, "消耗速率为 0 应被限制到下限")
	_chk(r.regen >= 0.0, "负数回复应被钳到 0")
	_chk(r.kill_ratio <= 1.0, "比例应被钳到 1")
	_chk(r.block_gain <= int(TimeRules.R_BLOCK.y), "破坏获取应被钳")
	_chk(r.damage_gain >= 0, "负伤害获取应被钳到 0")
	_chk(r.haste_mult <= TimeRules.R_HASTE.y, "加速倍率应被钳")


func _test_account_and_buffer() -> void:
	var r := TimeRules.new()
	var acc := r.make_account()
	_chk(is_equal_approx(acc.balance, 1000.0), "账户初始应 1000")
	_chk(is_equal_approx(acc.cap, 1800.0), "账户上限应 1800")
	_chk(is_equal_approx(acc.window, 250.0), "账户短期额度应为 250")
	_chk(is_equal_approx(acc.regen_rate, 50.0), "账户回复应 50/s")
	_chk(is_equal_approx(acc.loan_max, 250.0), "账户透支上限应等于短期额度")
	# 环形缓冲区时长：上限 / 回溯消耗速率 = 1800/150 = 12s（封顶 15s）
	_chk(is_equal_approx(r.rewind_buffer_seconds(), 12.0), "环形缓冲区应为 12s(cap/burn)")
	var slow := TimeRules.new()
	slow.cap = 1800.0
	slow.rewind_burn = 50.0
	_chk(is_equal_approx(slow.rewind_buffer_seconds(), 15.0), "环形缓冲区时长应封顶 15s")
