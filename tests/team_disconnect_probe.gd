extends Node

# TeamHost.mark_disconnected:**整队走光才终局**(双向断言)。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/team_disconnect_probe.tscn
# 通过 = `TEAM DISCONNECT: ALL-OK`。
#
# ═══ 为什么需要它(照 royale_disconnect_count_probe 的先例)═══
# ★ 只断言"掉 1 人不终局"的话,一个**永不终局**的实现也能全绿 —— 本探针另配一条反向断言
#   (整队走光**必须**终局),两条一起才说明判据是"按队"而不是"恒 false"。
# ★ 这条判据错了的表现同样是静默的:要么"掉一个就结束"(玩家白打),要么"永远不结束"
#   (worker 僵持占端口)。
# ★★ 第二批(④⑤⑥):**走光即弃权** —— 胜者 = 存活的对方队(不是 `_match_winner` 那条
#   "局胜高者、并列偏 1 队"的兜底),两队都走光 = 平局 0;而**正常收局**(三局两胜)那条路
#   一字不受影响(⑥,含"冠军队赛后离场不得被改判")。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

var _fails: Array[String] = []
var _ran_to_end := false


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


# ★ 必须 `await _run()` 再 `_finish()`:`_run()` 里有 `await get_tree().physics_frame`(协程),
#   同步调 `_finish()` 会在断言跑完**之前**执行 → 所有真断言都 ok 却打出 FAIL(假红)。
#   (本仓 `destroyed_cells_probe` 那份没有 await,照抄那个模板就会踩这个坑。)
func _ready() -> void:
	await _run()
	_finish()


func _place(host, role: int) -> void:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	host.players[role] = p


func _run() -> void:
	# spawns 传空 → 宿主自己算一份(`plan_team_spawns`);角色靠 `_place` 手工摆位。
	var host = TeamHost.new(MAP, {}, {}, [], {}, TEAMS)
	add_child(host)
	# ★ 关掉宿主自己的物理帧:本探针**手工**调 `mark_disconnected`(生产上由
	#   `server_main._expire_graces` 每秒轮询触发)。
	#   不关的话 `quit(0)` 是帧末生效,中间还会跑一帧 `_physics_process` → 快照广播去读
	#   尚未摆位的对象 —— 在断言全过之后刷一屏 SCRIPT ERROR(与 royale_disconnect_count_probe 同款)。
	host.set_physics_process(false)
	for role in TEAMS:
		_place(host, role)
	await get_tree().physics_frame

	# ── ① 掉 1 人(1 队的 3 号)→ **不得**终局 ──
	host.mark_disconnected(3)
	_check(int(host._round_state) != int(MatchHost.RoundState.MATCH_OVER),
			"★ 掉 1 人不终局(该队少人继续打)")
	_check(host.players.size() == 5, "掉线者已移出 players")
	# ── ② 同队再掉一人(1 号)→ 仍不终局 ──
	host.mark_disconnected(1)
	_check(int(host._round_state) != int(MatchHost.RoundState.MATCH_OVER), "★ 同队掉 2 人仍不终局")
	# ── ③ 1 队最后一人也走 → **必须**终局 ──
	# ★ 这条是反向验证的**区分点**:此刻场上还剩 2 队的 4/5/6 共 **3 人**,
	#   royale 那条 `players.size() < 2` 判据在这里**不会**终局 —— 两条判据答案相反。
	host.mark_disconnected(2)
	_check(host.players.size() == 3, "场上还剩 2 队的 3 个人")
	_check(int(host._round_state) == int(MatchHost.RoundState.MATCH_OVER),
			"★ 整队走光 → 必须终局(反向断言:royale 那条判据在这里给 false)")

	# ── ④ 走光即弃权:胜者 = **存活的对方队** ──
	# ★ 这条是"弃权判据"的手臂:此刻两队都是 0 局胜,`_match_winner` 的兜底("局胜高者",
	#   并列偏 1 队)会返回 **1** —— 也就是**刚刚走光的那一队**。不修的话下面这条红。
	_check(host._match_winner() == 2,
			"★ 1 队走光 → 胜者 = 2 队(弃权。旧兜底的并列偏 1 队会返回 1 = 走光那队;实际 %d)"
			% host._match_winner())

	# ── ⑤ 两队都走光 → **平局 0**(场上一个队都不剩,没有胜者可报)──
	host.mark_disconnected(4)
	host.mark_disconnected(5)
	_check(host._match_winner() == 2,
			"★ 还剩 1 队时胜者仍是 2 队(判据单调收缩,不是'最后一个走的输';实际 %d)"
			% host._match_winner())
	host.mark_disconnected(6)
	_check(host.players.size() == 0, "六个 role 全部走光")
	_check(host._match_winner() == 0,
			"★ 两队都走光 → 平局 0(实际 %d)" % host._match_winner())

	# ── ⑥ 反向:正常收局(三局两胜)仍走"按局胜"那条路,弃权判据**不污染**它 ──
	# ⑥a 正常打完:1 队先到 `TEAM_ROUNDS_TO_WIN` 局胜 → MATCH_OVER,胜者 = 1 队
	var h2 = TeamHost.new(MAP, {}, {}, [], {}, TEAMS)
	add_child(h2)
	h2.set_physics_process(false)
	for role in TEAMS:
		_place(h2, role)
	await get_tree().physics_frame
	_check(h2._endgame_winner == TeamHost.ENDGAME_NONE,
			"正常路径从不写弃权字段(实际 %d)" % h2._endgame_winner)
	h2._round_over(1)
	h2._round_over(1)
	h2._round_state = MatchHost.RoundState.ROUND_OVER
	h2._round_timer = 0.0
	h2._match_round_tick(0.016)     # ROUND_OVER 到期 → `_start_next_round` → 局胜先到阈值
	_check(int(h2._round_state) == int(MatchHost.RoundState.MATCH_OVER),
			"⑥a 局胜先到阈值 → MATCH_OVER(实际 state=%d)" % int(h2._round_state))
	_check(h2._match_winner() == 1,
			"★ ⑥a 正常收局走**按局胜**:胜者 = 1 队(实际 %d)" % h2._match_winner())
	# ⑥b 冠军队**赛后离场**:结果**不得**被改判成对方胜(否则"赢了的队走人 = 改判负")。
	# ★ 这条钉的是 `_decided_by_rounds()` 那道闸:少了它,三个 role 走完 → `alive_teams` 只剩
	#   {2} → 弃权判据把胜者写成 2,而这一局是**按局胜打完的**。
	h2.mark_disconnected(1)
	h2.mark_disconnected(2)
	h2.mark_disconnected(3)
	_check(h2._match_winner() == 1,
			"★ ⑥b 已按局胜收场后冠军队离场:胜者**不得**改判(实际 %d)" % h2._match_winner())
	_ran_to_end = true


func _finish() -> void:
	if _fails.is_empty() and _ran_to_end:
		print("TEAM DISCONNECT: ALL-OK")
		get_tree().quit(0)
	else:
		print("TEAM DISCONNECT: FAIL")
		for f in _fails:
			print("  - %s" % f)
		if not _ran_to_end:
			print("  - ★ 探针没跑到末尾")
		get_tree().quit(1)
