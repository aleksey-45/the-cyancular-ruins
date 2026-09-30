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

# ⑨ 用:`reconnect_probe` 整跑长度里"前半段"(开机/进局/闪断/重连/相⑦)的实测量级 —— 该探针
# `FINAL_TIMEOUT` 的注释就是这个推导(取 12 让下限落在 72s)。
const RP_PREAMBLE := 12.0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


# ⑨ 用:从探针脚本的 `get_script_constant_map()` 里取一个预算常量。
# ★★ 取不到时**必须报红**:直接 `float(m["X"])` 在键名写错/常量被改名时拿到 null → 静默变 0.0,
#   而 0 永远满足"下界"那条不等式 ⇒ "取不到"会伪装成"通过"。本守卫的全部意义就是拦静默失败,
#   故这里先记账再返回 0(调用方那条不等式多半会跟着红第二条)。
func _budget(m: Dictionary, name: String, where: String) -> float:
	if not m.has(name):
		_check(false, "★ %s 里找不到常量 %s(改名/删除?)—— 本守卫已失明,别把这次运行当通过" % [where, name])
		return 0.0
	return float(m[name])


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

	# ── ⑧ 宽限期时长的**次要 belt**(2026-09-21,阶段 2-B)──
	# ★ 为什么钉时长:重连的重试预算直接读这个常量(`scenes/pvp_match_client.gd` 的
	#   `_on_reconnect_retry_tick` 第一条判据),单一来源不会漂;但**测试预算**是按它算出来的
	#   窗口(`reconnect_probe` 的 GRACE_MIN/MAX/FINAL_TIMEOUT、`team_match_watcher.OBSERVE_MAX`、
	#   `team_match_probe.RESULT_WAIT`),那些不会自己跟着动 → 症状是"一行 ALL-OK 都没有"
	#   (安全网先耗尽),与真失败长得一模一样。故在这里钉住这个数。
	_check(absf(G.DEFAULT_SECONDS - 60.0) < 0.001,
			"宽限期应为 60.0 秒(用户裁定:1v1 / 3v3 / 大乱斗三模式统一)。实得 %.1f" % G.DEFAULT_SECONDS)
	# ★★ 本相从前还有第二条 belt:load `server/worker_launcher.gd` 读三档 `*_PORT_REUSE_DELAY`
	#   并断言它们都大于宽限期。**那一段连同断言已整体删除**(单进程单端口):端口归还延迟是
	#   "每局一个 worker 子进程"那个形态的产物 —— 对局现在是同进程里的一个 `MatchSession`,
	#   端口不再按局分配,"端口还没还回来"这个窗口根本不存在了。而"这一局还在不在"改由
	#   **凭据条目上的 `alive`** 精确回答(`RejoinRegistry.end_match` 在会话结束那一刻翻它),
	#   不再靠任何定时估的常量。★ 别为它找一个替代品:那条 belt 当年拦不住真正的病。

	# ── ⑨ 按宽限期**算出来**的测试/跑批预算必须仍然跨得过它(2026-09-21,Task 3 折叠进来)──
	# ★ 为什么钉这条:三个真链路探针里有一批窗口是**按宽限期算的**(reconnect_probe 的
	#   GRACE_MIN/GRACE_MAX/FINAL_TIMEOUT/CHILD_QUIT_AFTER、team_match_watcher 的 OBSERVE_MAX、
	#   team_match_probe 的 RESULT_WAIT/FINAL_TIMEOUT/CHILD_QUIT_AFTER)。它们**不会**自己跟着
	#   常量动 —— 而落伍的后果不是"红一条断言",是**探针自己先到点**:安全网/收工上限先耗尽 ⇒
	#   探针挂住、**一行裁决都不打印**,而本仓的判据是"grep 文本 ALL-OK" ⇒ 与"真失败"长得一模一样。
	# ★★ 这个坑**已经烂过两次**(宽限期 30 → 60 时 OBSERVE_MAX 与 RESULT_WAIT 那一批同时落伍;
	#   此前还有一次把 RENDEZVOUS_MAX 记成 70 —— 实际是 100)。故每条不等式逐个钉住,
	#   **消息里点名是哪一条预算**(红了才知道该改谁)。
	# ★ 只 `load()` 读常量表,**不实例化** —— 三个探针都是场景探针(extends Node、依赖 autoload),
	#   `-s` 下既不能也不需要实例化;`--import` 也已把它们的 `class_name` 依赖解析过。
	var p_rp := "tests/reconnect_probe.gd"
	var p_wm := "tests/team_match_watcher.gd"
	var p_tp := "tests/team_match_probe.gd"
	var cst := {}    # 相对路径 → 该脚本的常量表
	for rel in [p_rp, p_wm, p_tp]:
		var s: GDScript = load("res://" + rel)
		# ★ 空载守卫:load 失败还往下走(下面那句 get_script_constant_map() 会抛错)走不到 quit() → 永久挂起
		if s == null:
			print("GRACE_WINDOW FAILED: 找不到 res://%s(按宽限期算出来的预算无从校验)" % rel)
			quit(1)
			return
		cst[rel] = s.get_script_constant_map()
	var crp: Dictionary = cst[p_rp]
	var cwm: Dictionary = cst[p_wm]
	var ctp: Dictionary = cst[p_tp]
	# `--quit-after` 的单位是**帧**,而两个探针的注释都按 `run/max_fps`(=60)折算成秒。
	var grace := float(G.DEFAULT_SECONDS)
	var fps := float(ProjectSettings.get_setting("run/max_fps", 60))
	if fps <= 0.0:
		fps = 60.0    # 不限帧(0)时按 60 估 —— 这只是一条 belt,不追求精确

	var rp_min := _budget(crp, "GRACE_MIN", p_rp)
	var rp_max := _budget(crp, "GRACE_MAX", p_rp)
	var rp_final := _budget(crp, "FINAL_TIMEOUT", p_rp)
	var rp_child_f := _budget(crp, "CHILD_QUIT_AFTER", p_rp)
	var wm_observe := _budget(cwm, "OBSERVE_MAX", p_wm)
	var tp_wait := _budget(ctp, "RESULT_WAIT", p_tp)
	var tp_final := _budget(ctp, "FINAL_TIMEOUT", p_tp)
	var tp_child_f := _budget(ctp, "CHILD_QUIT_AFTER", p_tp)
	# ④ 的求和逐项取(watcher 的常量),漏掉任何一项都会让那条判据失去意义。
	var tp_worst := (_budget(cwm, "ENTER_TIMEOUT", p_wm) + _budget(cwm, "SETTLE", p_wm)
			+ _budget(cwm, "RENDEZVOUS_MAX", p_wm) + _budget(cwm, "BRAWL_MAX", p_wm)
			+ _budget(cwm, "SETTLE", p_wm) + wm_observe
			+ _budget(cwm, "PEER_WAIT", p_wm))

	# ① `reconnect_probe` 相④ 量到的时长必须落进 [GRACE_MIN, GRACE_MAX] —— 窗口不含宽限期,
	#    就会把**正确**的服务器判红(窗口下界高于它 / 上界低于它)。
	_check(rp_min <= grace,
			"★ tests/reconnect_probe.GRACE_MIN = %.0f > 宽限期 %.0f:相④ 会把**正确**的服务器判红(窗口下界高过实际宽限)"
			% [rp_min, grace])
	_check(rp_max >= grace,
			"★ tests/reconnect_probe.GRACE_MAX = %.0f < 宽限期 %.0f:相④ 会把**正确**的服务器判红(窗口上界低于实际宽限)"
			% [rp_max, grace])
	# ② `reconnect_probe` 的收工上限必须大于整跑长度(= 相④ 要等满的宽限期 + 前半段 ~12s),
	#    而子进程的帧兜底又必须大于它(否则 actor 先退,相④ 的落点换了人)。
	_check(rp_final > grace + RP_PREAMBLE,
			"★ tests/reconnect_probe.FINAL_TIMEOUT = %.0f ≤ 宽限期 %.0f + 前半段 %.0f:收工上限先于整跑到点(探针挂住、一行裁决都没有)"
			% [rp_final, grace, RP_PREAMBLE])
	_check(rp_child_f / fps > rp_final,
			"★ tests/reconnect_probe.CHILD_QUIT_AFTER = %.0f 帧(≈%.0fs)≤ FINAL_TIMEOUT %.0fs:子进程先于本进程收工上限退出"
			% [rp_child_f, rp_child_f / fps, rp_final])
	# ③ `team_match_watcher` 相⑤ 的观察窗必须**盖过**宽限期到点那一刻(掉线者正是在那时被移出
	#    对局,而 `_expire_graces` 每秒才轮询一次 ⇒ 实际落在宽限 +0~1s)。
	_check(wm_observe > grace,
			"★ tests/team_match_watcher.OBSERVE_MAX = %.0f ≤ 宽限期 %.0f:相⑤ 在掉线者被移出对局**之前**就关窗(恒红)"
			% [wm_observe, grace])
	# ④ `team_match_probe` 等 6 份客户端结果的上限必须**逐项求和**算出来(该探针注释里那句话:
	#    这行漂过两次)。求和取**进局那一档的硬上限** `ENTER_TIMEOUT`(不是理想值 ~5s),两个 SETTLE 各一份。
	_check(tp_wait > tp_worst,
			"★ tests/team_match_probe.RESULT_WAIT = %.0f ≤ 最坏客户端时间线 %.1fs(ENTER_TIMEOUT+SETTLE+RENDEZVOUS_MAX+BRAWL_MAX+SETTLE+OBSERVE_MAX+PEER_WAIT):探针先放弃,表象是「只收到 N/6 份结果」"
			% [tp_wait, tp_worst])
	_check(tp_final > tp_wait,
			"★ tests/team_match_probe.FINAL_TIMEOUT = %.0f ≤ RESULT_WAIT = %.0f:本进程收工上限先于等结果预算到点"
			% [tp_final, tp_wait])
	_check(tp_child_f / fps > tp_final,
			"★ tests/team_match_probe.CHILD_QUIT_AFTER = %.0f 帧(≈%.0fs)≤ FINAL_TIMEOUT %.0fs:客户端子进程先于本进程收工上限退出"
			% [tp_child_f, tp_child_f / fps, tp_final])

	if _fail == 0:
		print("GRACE_WINDOW OK")
		quit(0)
	else:
		print("GRACE_WINDOW FAILED: %d" % _fail)
		quit(1)
