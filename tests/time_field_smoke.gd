extends SceneTree

# 时间场冒烟(-s 数据级):模式切换/倍率/贷款敌速/账户结算 全语义。
# 用法:godot --headless --path . -s res://tests/time_field_smoke.gd

var _fails: Array[String] = []


func _init() -> void:
	_test_null_field()
	_test_none_mode()
	_test_haste_mode()
	_test_loan_enemy_speed()
	_test_rewind_mode()
	_test_account_gating()
	if _fails.is_empty():
		print("TIME FIELD OK(空场恒1/加速相对2x/贷款敌速/回溯冻结+精英豁免/账户闸门)")
		quit(0)
	else:
		print("TIME FIELD FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		quit(1)


func _chk(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)


func _near(got: float, want: float, eps: float, what: String) -> void:
	_chk(absf(got - want) <= eps, "%s(得 %s 期望 %s)" % [what, str(got), str(want)])


func _mk_enemy(elite: bool) -> Node:
	var n := Node.new()
	if elite:
		n.set_meta("elite", true)
	return n


func _test_null_field() -> void:
	TimeField.current = null
	_near(TimeField.player_delta(1.0), 1.0, 0.001, "空场玩家×1")
	_near(TimeField.enemy_delta(1.0, _mk_enemy(false)), 1.0, 0.001, "空场敌人×1")
	_near(TimeField.bullet_delta(1.0, null), 1.0, 0.001, "空场子弹×1")


func _test_none_mode() -> void:
	var f := TimeField.new(GrainAccount.new())
	TimeField.current = f
	f.update(1.0 / 60.0, false, false)
	_chk(f.mode == TimeField.Mode.NONE, "无按键应为 NONE")
	_near(TimeField.player_delta(1.0), 1.0, 0.001, "NONE 玩家×1")
	TimeField.current = null


func _test_haste_mode() -> void:
	var f := TimeField.new(GrainAccount.new())
	TimeField.current = f
	f.update(0.1, false, true)
	_chk(f.mode == TimeField.Mode.HASTE, "Ctrl 应为 HASTE")
	_near(TimeField.player_delta(1.0), TimeParams.HASTE_PLAYER, 0.001, "HASTE 玩家×2")
	_near(TimeField.enemy_delta(1.0, _mk_enemy(false)), TimeParams.HASTE_WORLD, 0.001, "HASTE 普通敌×1")
	_near(TimeField.enemy_delta(1.0, _mk_enemy(true)), TimeParams.HASTE_PLAYER, 0.001, "HASTE 精英与玩家同步")
	# -s 阶段 autoload 不存在,bullet_base 载不动(会引用 GameParameters)→ 用内联桩脚本,
	# 只保留 shooter 这一个被查询的属性(真弹的发射方归属判定与此完全同形)
	var stub := GDScript.new()
	stub.source_code = "extends Node
var shooter: Node = null
"
	stub.reload()
	var pb = stub.new()
	var pl := Node.new()
	pl.add_to_group("player")
	pb.shooter = pl
	_near(TimeField.bullet_delta(1.0, pb), TimeParams.HASTE_PLAYER, 0.001, "HASTE 我方弹随玩家")
	var eb = stub.new()
	_near(TimeField.bullet_delta(1.0, eb), TimeParams.HASTE_WORLD, 0.001, "HASTE 敌方弹放慢")
	TimeField.current = null


func _test_loan_enemy_speed() -> void:
	var acc := GrainAccount.new()
	var f := TimeField.new(acc)
	TimeField.current = f
	acc.spend(4.0, 100.0)   # 窗满
	acc.spend(0.5, 100.0)   # 借 50 → 深度 0.5
	_near(f.loan_depth(), 0.5, 0.001, "深度 0.5")
	f.update(1.0 / 60.0, false, false)
	var want: float = 1.0 * (1.0 + TimeParams.LOAN_ENEMY_SPEED_BONUS * 0.5)
	_near(TimeField.enemy_delta(1.0, _mk_enemy(false)), want, 0.01, "贷款 0.5:普通敌 ×1.25")
	_near(TimeField.enemy_delta(1.0, _mk_enemy(true)), 1.0, 0.001, "贷款不影响精英")
	TimeField.current = null


func _test_rewind_mode() -> void:
	var f := TimeField.new(GrainAccount.new())
	TimeField.current = f
	f.update(0.1, true, false)
	_chk(f.mode == TimeField.Mode.REWIND, "Shift 应为 REWIND")
	_near(TimeField.player_delta(1.0), 0.0, 0.001, "回溯玩家冻结×0")
	_near(TimeField.enemy_delta(1.0, _mk_enemy(false)), 0.0, 0.001, "回溯普通敌冻结×0")
	_near(TimeField.enemy_delta(1.0, _mk_enemy(true)), 1.0, 0.001, "回溯精英照常×1")
	_near(TimeField.bullet_delta(1.0, null), 0.0, 0.001, "回溯子弹冻结×0")
	_chk(f.rewind_time > 0.0, "回溯计时累加")
	f.update(0.1, false, false)
	_chk(f.mode == TimeField.Mode.NONE and is_equal_approx(f.rewind_time, 0.0), "松开恢复且计时清零")
	TimeField.current = null


func _test_account_gating() -> void:
	var acc := GrainAccount.new(50)
	var f := TimeField.new(acc)
	TimeField.current = f
	f.update(0.05, true, false)   # 余额只够半拍
	_chk(f.mode == TimeField.Mode.REWIND, "余额未尽仍可回溯")
	f.update(1.0, true, false)    # 余额耗尽
	_chk(f.mode == TimeField.Mode.NONE, "余额耗尽回溯应停")
	# 锁定闸门:贷满后两键都按不出
	var acc2 := GrainAccount.new()
	var f2 := TimeField.new(acc2)
	TimeField.current = f2
	acc2.spend(4.0, 100.0)
	acc2.spend(1.0, 100.0)   # 贷满锁
	f2.update(0.1, true, false)
	_chk(f2.mode == TimeField.Mode.NONE, "锁定中 Shift 空转")
	f2.update(0.1, false, true)
	_chk(f2.mode == TimeField.Mode.NONE, "锁定中 Ctrl 空转")
	TimeField.current = null
