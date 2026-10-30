extends SceneTree
# 宽限到点分派守卫(G-02:到点分派写反不会红 ⇒ 3v3 第一个到点的人带走整局 / 1v1 该收场却只移出)。
# 守卫对象 = GraceWindow(纯逻辑:无 autoload / 无 Node ⇒ 本文件能 `-s` 跑)的三件事:
#   ① expire_action 三态:1v1 → ACTION_TEARDOWN(收场退进程);royale / team → ACTION_REMOVE(移出对局继续打)。
#   ② expired() 边界:`now >= until` 算到期(含等号),早 1ms 不算。
#   ③ expired() 按 role 升序;remaining() 到期报 0.0(键保留,不是省略 —— 省略会让 HUD 闪回「无掉线」)。
# 去掉什么才红:把 ACTION_REMOVE / ACTION_TEARDOWN 的值对调 ⇒ ①②③ 全红;`>=` 改成 `>` ⇒ ④ 红;
#   删 `out.sort()` ⇒ ⑤ 红;remaining() 到期 `erase` 掉键 ⇒ ⑥ 红。
# 测不到什么:① 到点之后的真动作(移出对局 / 通知对手 / 退进程)在 server_main._expire_graces;
#   ② `tools/room_sweep_lint.gd` 只判"某人有没有写这段分派"的源码形态,不是行为。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/grace_dispatch_smoke.gd;通过 = GRACE DISPATCH OK(n 条断言)。

const EXPECTED_CHECKS := 6

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/net/grace_window.gd") == null:
		print("GRACE DISPATCH FAILED: load(grace_window.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	# ① 1v1(二者皆 false)= 收场:对手不会回来了,worker 退进程把房与端口交回回收梯
	_chk(GraceWindow.expire_action(false, false) == GraceWindow.ACTION_TEARDOWN,
			"1v1 宽限到点必须收场(ACTION_TEARDOWN;实得 %d)" % GraceWindow.expire_action(false, false))

	# ② 大乱斗 = 只移出该 role,整局继续
	_chk(GraceWindow.expire_action(true, false) == GraceWindow.ACTION_REMOVE,
			"大乱斗到点只移出该 role(ACTION_REMOVE;实得 %d)" % GraceWindow.expire_action(true, false))

	# ③ 3v3 = 只移出该 role(★ 分派写反的现场:第一个到点的人带走整局)
	_chk(GraceWindow.expire_action(false, true) == GraceWindow.ACTION_REMOVE,
			"3v3 到点只移出该 role(ACTION_REMOVE;实得 %d)" % GraceWindow.expire_action(false, true))

	# ④ 边界:enter(2, t=1000ms, 1s) ⇒ until=2000;1999 未到期(不含),2000 到期(含等号)
	var g := GraceWindow.new()
	g.enter(2, 1000, 1.0)
	var at_before := g.expired(1999)
	var at_exact := g.expired(2000)
	_chk(at_before.is_empty() and at_exact == [2],
			"expired 边界:早 1ms 不算到期(实得 %s)、恰到期算(实得 %s)" % [str(at_before), str(at_exact)])

	# ⑤ 按 role 升序(乱序 enter 也要升序返回;调用方按返回顺序 leave / 打印,顺序漂了日志就不可对账)
	var g2 := GraceWindow.new()
	for r in [9, 2, 5]:
		g2.enter(r, 1000, 1.0)
	_chk(g2.expired(2000) == [2, 5, 9],
			"expired 按 role 升序(实得 %s)" % str(g2.expired(2000)))

	# ⑥ 到期后 remaining 报 0.0 且**键还在**(已到期的 role 不能被省略成「无掉线」)
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
