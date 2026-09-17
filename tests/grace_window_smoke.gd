extends SceneTree

# 宽限期表冒烟:进入/到期/续期/离开/确定性排序。
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

	if _fail == 0:
		print("GRACE_WINDOW OK")
		quit(0)
	else:
		print("GRACE_WINDOW FAILED: %d" % _fail)
		quit(1)
