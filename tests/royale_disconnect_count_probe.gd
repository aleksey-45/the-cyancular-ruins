extends Node

# 大乱斗「掉线 → 终局」计数回归:剩余**玩家数** < 2 才终局,不是 peer 数。
# 另含第三相:**按分判胜的候选集合**(2026-09-17)—— 已离开但计过分的 role 也要参与比较,
# 否则 `mark_disconnected` 先把退出者 erase 掉,会导致"独行者必胜、与比分无关"。
#
# ═══ 为什么需要它 ═══
# AI 补位 role 由服务端驱动、**没有 peer**,只存在于 `players` 里(`peer_by_role` 只有真人)。
# 按 `peer_by_role` 计数时,「2 真人 + 2 AI 掉 1 真人」会看到 online=1 → 当场判 MATCH_OVER,
# 剩下 1 真人 + 2 AI 被强行收场。2026-09-14 审计发现并修掉(`server/royale_host.gd`
# `mark_disconnected` 的终局判据)。
# ★ 这个错法**只查源码文本照不出来** —— 「数 players」与「数 peer_by_role」两种写法都合法、
#   都编译得过,只有真建宿主、真调 `mark_disconnected`、真看 `_round_state` 才照得出。
#   同类的上个教训:AI 目标方向漏取负(H1)——冒烟只查成员名,照不出符号错。
#
# ═══ 做法 ═══
# 同 `match_host_hygiene_probe`:真建一个 RoyaleHost,但 **role_peers 传空** —— 不建玩家、
# 不排 peer、不发包;再手工把 `players` / `peer_by_role` 摆成「2 真人 + 2 AI」的形状。
# 跑法(场景模式,root 有 autoload/`multiplayer`):
#   "$GODOT" --headless --path . res://tests/royale_disconnect_count_probe.tscn
# 通过 = `ROYALE DISCONNECT COUNT: ALL-OK` 退出 0。

const MAP := "res://maps/factory1v1.cyrm"

var _host: RoyaleHost = null
var _fails: Array[String] = []


# 只提供 `_broadcast_round_state` 要读的两个口:is_downed / global_position。
# 其余(`queue_free`)用 Node2D 自带的。
class StubBody extends Node2D:
	var _downed := false
	func is_downed() -> bool: return _downed


func _ready() -> void:
	# role_peers 空 → 父类不摆位、不建 peer;spawns 传非空只为跳过 plan_spawns(与地图无关)
	var spawns := {1: Vector2i(10, 10), 2: Vector2i(20, 20), 3: Vector2i(30, 30), 4: Vector2i(40, 40)}
	_host = RoyaleHost.new(MAP, {}, {}, [], spawns)
	add_child(_host)
	# ★ 关掉宿主自己的物理帧:本探针**手工**调 mark_disconnected,不需要它自跑。
	#   不关的话 `quit(0)` 是帧末生效,中间还会跑一帧 `_physics_process` → 快照/光束广播去读
	#   桩对象上不存在的 `weapons` 等字段 → 在断言全过之后刷一屏 SCRIPT ERROR(实测)。
	#   探针只需要它在树上:`_broadcast_*` 要用 Node 的 `multiplayer`。
	_host.set_physics_process(false)
	_run()
	_finish()


func _run() -> void:
	# 形状:2 真人(role 1/2,**有** peer)+ 2 AI 补位(role 3/4,**无** peer)
	for r in [1, 2, 3, 4]:
		var b := StubBody.new()
		add_child(b)
		_host.players[r] = b
	_host.peer_by_role = {1: 101, 2: 102}      # AI 不在里面 —— 这正是本探针要压的那条差别
	_host._round_state = _host.RoundState.PLAYING

	# ── ① 正向:掉 1 个真人,剩 3 个玩家(1 真人 + 2 AI)→ **不得**终局 ──
	# 旧实现(数 peer_by_role)在这里 online=1 → 当场 MATCH_OVER,本断言即红。
	_host.mark_disconnected(1)
	_check(_host.players.size() == 3,
			"掉 1 真人后 players 应剩 3(实际 %d)" % _host.players.size())
	_check(_host._round_state != _host.RoundState.MATCH_OVER,
			"★ 2 真人 + 2 AI 掉 1 真人后剩 3 人,**不得**判终局(数 peer 会在这里错判)")

	# ── ② 反向:再掉到只剩 1 个玩家 → **必须**终局 ──
	# 没有这条,上面的断言可以靠「永不终局」作弊通过。
	_host._round_state = _host.RoundState.PLAYING
	_host.mark_disconnected(2)
	_check(_host._round_state != _host.RoundState.MATCH_OVER,
			"掉 2 个真人后剩 2 个玩家(0 真人 + 2 AI),仍不得终局")
	_host.mark_disconnected(3)
	_check(_host._round_state == _host.RoundState.MATCH_OVER,
			"★ 只剩 1 个玩家时必须终局(否则上面那条就成了「永不终局」的假绿)")

	# ── ③ 按分判胜:已离开者仍在候选里(2026-09-17 用户裁定)──
	# 为什么单开这一相:原实现 `_match_winner()` 只遍历 `players`,而 `mark_disconnected` 会
	# **先**把退出者 `erase` 掉 → 剩 1 人时**独行者必胜、与比分无关**(B 击杀再多,一退出就是
	# A 胜;`_scores[B]` 还在表里却没人读)。现在候选 = 还在场 ∪ 计过分的。
	# 此刻场上只剩 role 4,而已离开的 role 2 分数更高 → 必须判 2 胜。
	_host._scores = {2: 9, 4: 3}
	var w1: int = _host._match_winner()
	_check(w1 == 2, "★ 已离开但分更高者应判胜(实际 winner=%d,期望 2)" % w1)
	# 反向一:分平 → 平局 0(别把"分高者胜"实现成"已离开者恒胜")
	_host._scores = {2: 5, 4: 5}
	var w2: int = _host._match_winner()
	_check(w2 == 0, "分数打平应判平局 0(实际 %d)" % w2)
	# 反向二:在场者分高 → 在场者胜
	_host._scores = {2: 1, 4: 7}
	var w3: int = _host._match_winner()
	_check(w3 == 4, "在场者分高应判在场者胜(实际 %d,期望 4)" % w3)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _finish() -> void:
	if _fails.is_empty():
		print("ROYALE DISCONNECT COUNT: ALL-OK")
		get_tree().quit(0)
	else:
		print("ROYALE DISCONNECT COUNT: FAIL(%d 条)" % _fails.size())
		get_tree().quit(1)
