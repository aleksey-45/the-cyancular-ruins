extends SceneTree

# 宽限期表冒烟:进入/到期/续期/离开/确定性排序 + 到点后的**分派**(三个模式的答案,⑦)。
# 跑法: timeout 60 "$GODOT" --headless --path . -s res://tests/grace_window_smoke.gd
# 通过 = `GRACE_WINDOW OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 时间是**参数**不是时钟 —— 本类刻意不读 Time.get_ticks_msec(),否则冒烟只能靠 sleep,
#   既慢又不确定。这里全部用假时间推进。
# ★ 到期判据是 `now >= until`(**含边界**):边界取 > 会让"正好到点"永远不算到期,
#   而宽限期常量取 0 时那条分支就永不触发(不可反证的历史教训,同 attribute 的时效窗口)。

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


func _initialize() -> void:
	var G: GDScript = load("res://core/net/grace_window.gd")
	# ★ 空载守卫:load() 失败还往下走会抛错,而 -s 抛错走不到 quit() → 永久挂起
	if G == null:
		print("GRACE_WINDOW FAILED: 找不到 core/net/grace_window.gd")
		quit(1)
		return
	var w = G.new()

	# ── ① 没进过 → has false、expired 空 ──
	_check(not w.has(1), "没进过的 role 不应在宽限期里")
	_check(w.expired(999999) == [], "空表 expired 应为空")

	# ── ② 进入 → 到期前不 expired、到期(含边界)才 expired ──
	w.enter(1, 1000, 30.0)          # 到期 = 31000
	_check(w.has(1), "enter 后 has 应为 true")
	_check(w.size() == 1, "size = 1(实际 %d)" % w.size())
	_check(w.expired(30999) == [], "到期前不得 expired")
	var e1: Array = w.expired(31000)
	_check(e1 == [1], "★ 正好到点(now == until)必须 expired(实际 %s)" % str(e1))

	# ── ③ leave 后立刻不在表里(即使还没到期)──
	w.leave(1)
	_check(not w.has(1), "leave 后 has 应为 false")
	_check(w.size() == 0, "leave 后 size = 0")

	# ── ④ 多个 role 同时到期 → 按 role 升序返回(确定性;字典迭代顺序不保证)──
	w.enter(3, 0, 1.0)              # 到期 1000
	w.enter(1, 0, 1.0)
	w.enter(2, 0, 1.0)
	var e2: Array = w.expired(1000)
	_check(e2 == [1, 2, 3], "多个到期应按 role 升序(实际 %s)" % str(e2))

	# ── ⑤ 重新掉线 = 刷新到期时刻(不是叠加)──
	# ★ 本相只判 **role 1** 是否到期,不能写成 `expired(35000) == []`:④ 的 role 2/3 到期时刻
	#   仍是 1000,在 35000 处**本就该**到期(expired 不动表,见类注释"调用方自行 leave"),
	#   拿整表判空会被它们污染 → 任何正确实现都过不了。
	w.enter(1, 5000, 30.0)          # 到期 35000
	w.enter(1, 20000, 30.0)         # 到期 50000
	_check(not (1 in w.expired(35000)), "重复 enter 应刷新到期时刻,不是叠加/取旧(实际 %s)" % str(w.expired(35000)))
	_check(w.expired(50000) == [1, 2, 3], "新到期时刻生效(实际 %s)" % str(w.expired(50000)))

	# ── ⑥ 时长用常量默认值时也算得出(防"默认参数写错导致永不进表")──
	var w2 = G.new()
	w2.enter(7, 0)
	_check(w2.has(7), "用默认时长 enter 后也应在表里")
	_check(w2.expired(int(G.DEFAULT_SECONDS * 1000.0)) == [7], "默认时长到期应可算")
	_check(w2.expired(int(G.DEFAULT_SECONDS * 1000.0) - 1) == [], "默认时长到期前 1ms 不应 expired")

	# ── ⑦ 到点后的**分派**(三个模式的答案;2026-09-18 加,3v3 启动契约 Task 9)──
	# ★ 为什么这条在这里钉:`server_main._expire_graces` 原先只有"大乱斗 / 其余"两支,
	#   那个 `else` 把 1v1 **和 3v3** 一起吞成"收场退进程" —— 3v3 里第一个宽限到期的人会
	#   带着整局退进程,与用户裁定"该队少人继续打"**相反**。分派收成纯函数后,三个模式的
	#   答案在这里逐个钉死;production 那边只准做一次比较(room_sweep_smoke 另断言它真走这条)。
	# ★ 真链路(6 人局里真掉线 → 宽限到期 → 其余人继续打)归 **B 册的真链路探针**,不在本冒烟。
	_check(G.expire_action(false, false) == G.ACTION_TEARDOWN,
			"1v1(非大乱斗非 3v3)到点应**收场退出**")
	_check(G.expire_action(true, false) == G.ACTION_REMOVE, "大乱斗到点应**移出对局**(其余人继续打)")
	_check(G.expire_action(false, true) == G.ACTION_REMOVE, "★ 3v3 到点应**移出对局**(不是收场退进程)")
	_check(G.expire_action(true, true) == G.ACTION_REMOVE, "两个开关同时为真(不该发生)也按移出对局处理")
	# 反向:两个枚举常量必须可区分(写成同一个值 = 上面四条里至少两条恒真,分派等于没有)
	_check(G.ACTION_REMOVE != G.ACTION_TEARDOWN, "两个动作枚举必须可区分")

	# ── ⑧ 宽限期时长 + 端口归还延迟的**次要 belt**(2026-09-21,阶段 2-B)──
	# ★ 为什么钉时长:重连的重试预算直接读这个常量(`scenes/pvp_match_client.gd` 的
	#   `_on_reconnect_retry_tick` 第一条判据),单一来源不会漂;但**测试预算**是按它算出来的
	#   窗口(`reconnect_probe` 的 GRACE_MIN/MAX/FINAL_TIMEOUT、`team_match_watcher.OBSERVE_MAX`、
	#   `team_match_probe.RESULT_WAIT`),那些不会自己跟着动 → 症状是"一行 ALL-OK 都没有"
	#   (安全网先耗尽),与真失败长得一模一样。故在这里钉住这个数。
	_check(absf(G.DEFAULT_SECONDS - 60.0) < 0.001,
			"宽限期应为 60.0 秒(用户裁定:1v1 / 3v3 / 大乱斗三模式统一)。实得 %.1f" % G.DEFAULT_SECONDS)
	# ★★ 下面这条不等式**已经不是承重的那条了**(2026-09-21,显示方案落地后):
	#   承重的换成了「**worker 进程活着 ⇒ 房对象与它占的端口都还在**」—— 房活到 worker 退出,
	#   而端口只在 `teardown_room` 里归还,所以宽限期内的客户端手里那个端口一定还有效,
	#   **与延迟常量的取值无关**。真正的"这个端口还是不是我的局"由凭据里的 `worker_pid`
	#   精确回答(`RejoinRegistry.decision` 的 worker_alive 入参),不再是定时估的。
	#   保留这条 belt 的理由:它拦不住真正的病,但能在"有人把某个延迟改成荒谬的小数"时
	#   当场响一声 —— ★ 它**必须**写在注释里说明自己是 belt,否则后代会把它当承重件去优化。
	var W: GDScript = load("res://server/worker_launcher.gd")
	# ★ 空载守卫:load 失败还往下走会抛错,而 -s 抛错走不到 quit() → 进程永久挂起
	if W == null:
		print("GRACE_WINDOW FAILED: 找不到 server/worker_launcher.gd(归还延迟的 belt 无从校验)")
		quit(1)
		return
	var delays := {
		"WORKER_PORT_REUSE_DELAY(1v1)": float(W.WORKER_PORT_REUSE_DELAY),
		"ROYALE_PORT_REUSE_DELAY(大乱斗)": float(W.ROYALE_PORT_REUSE_DELAY),
		"TEAM_PORT_REUSE_DELAY(3v3)": float(W.TEAM_PORT_REUSE_DELAY),
	}
	for k in delays:
		_check(float(delays[k]) > float(G.DEFAULT_SECONDS),
				"★ %s = %.0f 应大于宽限期 %.0f(belt:worker 退出后别立刻把端口发出去)"
				% [k, delays[k], G.DEFAULT_SECONDS])

	if _fail == 0:
		print("GRACE_WINDOW OK")
		quit(0)
	else:
		print("GRACE_WINDOW FAILED: %d" % _fail)
		quit(1)
