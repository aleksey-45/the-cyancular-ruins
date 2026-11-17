extends SceneTree

const EXPECTED_CHECKS := 6

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	if load("res://core/net/grace_window.gd") == null:
		print("GRACE DISPATCH FAILED: load(grace_window.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	_chk(GraceWindow.expire_action(false, false) == GraceWindow.ACTION_TEARDOWN,
			"1v1 宽限到点必须收场(ACTION_TEARDOWN;实得 %d)" % GraceWindow.expire_action(false, false))

	_chk(GraceWindow.expire_action(true, false) == GraceWindow.ACTION_REMOVE,
			"大乱斗到点只移出该 role(ACTION_REMOVE;实得 %d)" % GraceWindow.expire_action(true, false))

	_chk(GraceWindow.expire_action(false, true) == GraceWindow.ACTION_REMOVE,
			"3v3 到点只移出该 role(ACTION_REMOVE;实得 %d)" % GraceWindow.expire_action(false, true))

	var g := GraceWindow.new()
	g.enter(2, 1000, 1.0)
	var at_before := g.expired(1999)
	var at_exact := g.expired(2000)
	_chk(at_before.is_empty() and at_exact == [2],
			"expired 边界:早 1ms 不算到期(实得 %s)、恰到期算(实得 %s)" % [str(at_before), str(at_exact)])

	var g2 := GraceWindow.new()
	for r in [9, 2, 5]:
		g2.enter(r, 1000, 1.0)
	_chk(g2.expired(2000) == [2, 5, 9],
			"expired 按 role 升序(实得 %s)" % str(g2.expired(2000)))

	var rem := g2.remaining(2000)
	_chk(rem.has(2) and is_equal_approx(float(rem[2]), 0.0)
			and is_equal_approx(float(rem.get(5, -1.0)), 0.0),
			"remaining 到期报 0.0 且保留键(实得 %s)" % str(rem))

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("GRACE DISPATCH OK(%d 条断言):1v1 收场 · 大乱斗/3v3 移出 · 到期边界 · role 升序 · 到期报 0"
				% _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("GRACE DISPATCH FAILED: %d 处" % _fails.size())
		quit(1)
