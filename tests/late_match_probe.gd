extends Node

# 「对局尾段的记账与判胜口径」探针(场景模式;`-s` 做不了 —— 要真建宿主,autoload 在 `-s` 里不存在)。
# 跑法:`"$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn`
# 判据:文本 `LATE MATCH PROBE: ALL-OK`(**不看退出码** —— 场景探针脚本报错时
#       `--quit-after` 到点仍 exit 0,退出码与"跑通了"不可分)。
#       ★ 而 `ALL-OK` 只证明"**没有任何断言失败**",**不证明"每条断言都跑过"** ——
#       本文件用 `EXPECTED_CHECKS` 那道计数闸补上后半句(权威表述见 `tests/lib/probe_base.gd` 文件头)。
#
# 收的是用户 2026-09-28 裁定要修的三条「终局/离场之后」的口径:
#   ①② MATCH_OVER 之后倒地**不再进任何记账**(1v1 / 3v3 各一相)
#   ③   3v3 离场者 ACS 的分母 = **掉线那一刻**的局号,不是宽限到点的局号
#   ④⑤  大乱斗 `_match_winner` 的并列候选集(全场 0 杀 + 有人离开 ⇒ 平局,不是幸存者独胜)
#
# ★★ 为什么大乱斗那一处**没有**对应的"MATCH_OVER 后倒地"相:三个模式的倒地边沿是
#    **同一个契约的三份落地**,但**大乱斗那一份的形状本来就不同** —— 它的整支
#    `_match_round_tick` 就是一个 `match _round_state:`,倒地边沿住在 `RoundState.PLAYING`
#    分支里 ⇒ 终局后天然不记账。1v1(`match_round.gd`)与 3v3(`team_host.gd`)那两份把边沿
#    写在 `match` **之前**,故有病。**给没有病的那一处也写一条断言 = 写一条恒绿的摆设**。
#
# ★★ 那道状态闸覆盖的**不止** `deaths` 一项。写下来是为了让后来者别把下列现象读成无关的回归 ——
#    闸写对了 ⇒ MATCH_OVER 之后倒地**不再**:① 进 `_stats`(逐人 `deaths`)、② 1v1 给对方加分
#    (`_scores`)、③ **掉武器**(`_drop_all_but_one`)、④ **把胜方瞬移回出生点**)(`_reset_survivor`)、
#    ⑤ **再广播一次带新 `mvp` 的终局载荷**(`_broadcast_kill` + `_broadcast_round_state`)。
#    下面钉住的是 ①② 与 ⑤;**③④ 是同一道闸的同一批后果**,没有独立的落点
#    (③ 由 `death_drop_probe` 在 PLAYING 侧覆盖,④ 的 MATCH_OVER 侧今天无守卫)。
#    ⇒ 终局之后**看不到**胜方被传送、也**看不到**第二次终局播报,那是**本项要的**,不是回归。
#
# 手法照 `tests/death_drop_probe.gd`:真建宿主、**role_peers 传空**(不建玩家、不排 peer、
# 广播静默早退),玩家由本探针自己摆进 `host.players`,宿主自己的物理帧关掉(只手动推状态机)。
# 地图钉死 `factory1v1.cyrm`;出生点显式传(不走任何 shuffle ⇒ 跨进程可复现)。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
const TEAM_SPAWNS := {1: Vector2i(17, 65), 2: Vector2i(20, 65), 3: Vector2i(23, 65),
		4: Vector2i(133, 64), 5: Vector2i(136, 64), 6: Vector2i(139, 64)}
const ROYALE_SPAWNS := {1: Vector2i(17, 65), 2: Vector2i(20, 65), 3: Vector2i(23, 65)}

# ★ 本文件是 Task 4/5 要接着扩的脚手架 ⇒ 更需要这道闸:helper 里的脚本错误**不会**让 `_failures`
#   非空,它只让那个函数当场结束、调用方继续 ⇒ 断言被静默跳过而 verdict 照打 `ALL-OK`
#   (权威表述见 `tests/lib/probe_base.gd` 文件头)。
# ★ 这个数**由实跑填**,不照抄别处。数法 = 逐条点**实跑**的 `_check` 次数(**不是**数源码里的
#   `_check` —— helper 里那条每具宿主跑一次,不在 `_phase_*` 的函数体里):
#     `_phase_down_accounting` 每跑一遍 = **8** 条:
#       · `_host_after_down` 的 `is_downed` 仪器 ×3(PLAYING / ROUND_OVER / MATCH_OVER 各一具新宿主)
#       · PLAYING 的 `deaths`(反向对照)+ PLAYING 的 `rpc_calls > 0`(计数器仪器)
#       · ROUND_OVER 的 `deaths`
#       · MATCH_OVER 的 `deaths` + MATCH_OVER 的 `rpc_calls == 0`
#     两个模式各一遍 ⇒ 16;1v1 那遍另加 1 条 `_scores` ⇒ **17**。
const EXPECTED_CHECKS := 17

var _failures: Array[String] = []
var _checks := 0


# ── 计数器型宿主(把"终局后不得再广播终局载荷"这条**症状**变成读数)──────────────
# `_rpc_all` 是本文件唯一能观测"到底广播了没有"的口子:本探针 `role_peers` 传空 ⇒ 它的 for 循环
# 一次都不跑 —— **不是提前 return**,也就是说"广播真的发生了、只是没有收件人"。
# ⇒ 覆写它数调用次数,就把"MATCH_OVER 之后不再广播一次带新 mvp 的终局载荷"钉住了。
# ★ 只计数、原样 `super` 转发(缺省实参一个不改)⇒ 对生产行为**零扰动**。
# ★ 为什么不复用现成的读法:这条路径上没有任何可观测的状态变化(`_scores`/`deaths` 由上面两条
#   各管各的),广播本身才是有症状的那一项。
class CountingDuelHost extends MatchHost:
	var rpc_calls := 0

	func _rpc_all(method: String, args: Array = [], except_role: int = -1,
			live_only: bool = true) -> void:
		rpc_calls += 1
		super(method, args, except_role, live_only)


class CountingTeamHost extends TeamHost:
	var rpc_calls := 0

	func _rpc_all(method: String, args: Array = [], except_role: int = -1,
			live_only: bool = true) -> void:
		rpc_calls += 1
		super(method, args, except_role, live_only)


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[lm]   ok   %s" % msg)
	else:
		_failures.append(msg)
		print("[lm]   FAIL %s" % msg)


func _ready() -> void:
	_phase_down_accounting("1v1", [1, 2])
	_phase_down_accounting("3v3", [1, 4])
	# ★ 断言计数闸:跑少了就是有断言被静默跳过(见 `EXPECTED_CHECKS` 上方的说明)。
	if _checks < EXPECTED_CHECKS:
		var short_msg := ("★ 只跑了 %d 条断言,少于 EXPECTED_CHECKS=%d —— 有断言被静默跳过"
				% [_checks, EXPECTED_CHECKS]
				+ "(helper 里的脚本错误只让那个函数当场结束、调用方照常往下走,`_failures` 不会非空)")
		_failures.append(short_msg)
		print("[lm]   FAIL %s" % short_msg)
	print("[lm] 断言计数:%d 条(EXPECTED_CHECKS = %d)" % [_checks, EXPECTED_CHECKS])
	if _failures.is_empty():
		print("LATE MATCH PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("LATE MATCH PROBE: FAIL(%d 条)" % _failures.size())
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)


# ── 脚手架(后续 Task 复用)────────────────────────────────────────────────

# 按模式造一具**新**宿主。★ 每相各用一具:`_down_counted` 闩与 `_stats` 都留在宿主上,
# 复用会让后续相直接吃 `continue`(闩已置位)⇒ 断言恒绿。
# ★ 1v1 / 3v3 走**计数器型**子类(`CountingDuelHost` / `CountingTeamHost`)—— 只多一个 `rpc_calls`
#   读数,行为逐字不变;大乱斗那支没有"终局后倒地"的病,故保持原类(Task 4/5 的 ③④⑤ 用它)。
func _new_host(tag: String) -> Node:
	match tag:
		"1v1":
			return CountingDuelHost.new(MAP, {})
		"3v3":
			return CountingTeamHost.new(MAP, {}, {}, [], TEAM_SPAWNS, TEAMS)
		"royale":
			return RoyaleHost.new(MAP, {}, {}, [], ROYALE_SPAWNS)
	push_error("unknown tag: %s" % tag)
	return null


func _mount(tag: String, roles: Array) -> Node:
	var host: Node = _new_host(tag)
	add_child(host)
	# ★ 关掉宿主自己的 `_physics_process`:本探针只**手动**推一帧状态机。不关的话帧末那一跑
	#   会让快照/复活调度来搅局(与 death_drop_probe / team_host_probe 同款理由)。
	host.set_physics_process(false)
	for r in roles:
		_place(host, int(r))
	return host


func _place(host: Node, role: int) -> Node2D:
	var p: Node2D = (preload("res://scenes/player/player.tscn") as PackedScene).instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	host.players[role] = p
	# ★ 出生点取**宿主自己那张表**(显式传 spawns ⇒ 首局 `_spawn_cell` 返回的就是那格;
	#   `death_drop_probe` 的 3v3 相已证明这条路径可用)。取到无效格时退到 (1,1) ——
	#   本文件的四条口径**都不依赖**玩家站在哪,位置只影响可读性,但 (-1,-1) 会让玩家
	#   落在世界原点、可能压在实心格里。
	var spawn: Vector2i = host._spawn_cell(role)
	if spawn.x < 0 or spawn.y < 0:
		spawn = Vector2i(1, 1)
	var ts: int = GameParameters.TILE_SIZE
	p.global_position = Vector2(float(spawn.x) * ts + ts * 0.5,
			float(spawn.y) * ts + ts * 0.5)
	p.set_physics_process(false)     # 本探针不验玩家物理
	return p


# 制造一次倒地边沿(照 team_host_probe 的 `_down`):写归因 meta → force_down → 推一帧。
func _down(host: Node, victim: int, killer: int) -> void:
	var v: Node2D = host.players[victim]
	if killer == 0:
		v.remove_meta("last_damager")
		v.remove_meta("last_damager_time")
	else:
		CombatFeedback.attribute(v, host.players[killer])
	(v.get_node("Combat") as Node).force_down()
	host._match_round_tick(0.016)


# 逐人表的原始 deaths(缺条目 = 0,与生产 `_stat_entry` 的默认值同口径)。
func _deaths(host: Node, role: int) -> int:
	var s: Dictionary = host._stats.get(int(role), {})
	return int(s.get("deaths", 0))


# ── 阶段 ①② 倒地记账的状态闸(1v1 / 3v3 各一遍)──────────────────────────────
# 三个状态各用**一具新宿主**(`_down_counted` 闩与 `_stats` 都留在宿主上,复用会让后续相恒绿):
#   PLAYING    → 照常记 death(反向对照:证明记账路径是活的;没有它,"不记"那条就是恒绿摆设)
#   ROUND_OVER → **照旧**记 death(本项**只**排除 MATCH_OVER —— 这条把这个承诺钉住。
#                ★ 它不是顺手加的:`!= PLAYING` 那种写法在 PLAYING 下**不触发**,唯一的额外抑制
#                  正是 ROUND_OVER/COUNTDOWN,而那个变体在别处**没有任何守卫**)
#   MATCH_OVER → **不得**记 death(终局后残留的爆炸致死会走到这条边沿:它会 +1 death、
#                再掉一次武器、把胜方瞬移回出生点、并再广播一次带新 mvp 的终局载荷)
func _phase_down_accounting(tag: String, roles: Array) -> void:
	print("[lm] ── %s:倒地记账的状态闸 ──" % tag)
	var victim: int = int(roles[0])
	var killer: int = int(roles[1])

	# ── PLAYING:反向对照(必须先有)+ 计数器仪器自检 ──
	# 没有反向对照,"把整个倒地边沿块删掉"也能让下面那条通过(恒 0 = 恒绿)。
	var h_playing: Node = _host_after_down(tag, roles, MatchHost.RoundState.PLAYING, victim, killer)
	var n_playing: int = _deaths(h_playing, victim)
	_check(n_playing == 1,
			"[%s] ★ 反向对照:PLAYING 里倒地**照常**记 death(实得 %d;若为 0,说明记账路径根本没接上,"
			% [tag, n_playing] + "下面那条就是恒绿的摆设)")
	_check(h_playing.rpc_calls > 0,
			"[仪器][%s] PLAYING 里倒地**确实广播了**(实得 _rpc_all 调了 %d 次;若为 0,"
			% [tag, h_playing.rpc_calls]
			+ "说明计数器根本没接上,下面那条 `== 0` 就是恒绿摆设)")

	# ── ROUND_OVER:只排除 MATCH_OVER —— 这条把这个承诺钉住 ──
	var n_round_over: int = _deaths_after_down(tag, roles, MatchHost.RoundState.ROUND_OVER, victim, killer)
	_check(n_round_over == 1,
			"[%s] ★ ROUND_OVER 期间倒地**照旧**入账(实得 %d;本项**只**排除 MATCH_OVER ——"
			% [tag, n_round_over] + "把闸写成 `!= PLAYING` 会让这条红,而其余断言一条都不会)")

	# ── MATCH_OVER:本项 ──
	var h_over: Node = _host_after_down(tag, roles, MatchHost.RoundState.MATCH_OVER, victim, killer)
	_check(_deaths(h_over, victim) == 0,
			"[%s] ★ MATCH_OVER 之后倒地**不得**进 `_stats`(实得 deaths=%d;终局后残留的爆炸致死会走到"
			% [tag, _deaths(h_over, victim)]
			+ "这条边沿 —— 它会 +1 death、再掉一次武器、把胜方瞬移回出生点、并再广播一次带新 mvp 的终局载荷)")
	_check(h_over.rpc_calls == 0,
			"[%s] ★ MATCH_OVER 之后倒地**不得**再广播终局载荷(实得 _rpc_all 调了 %d 次;"
			% [tag, h_over.rpc_calls] + "非 0 = 客户端会再收一条带新 mvp 的 round_state)")
	if tag == "1v1":
		# 1v1 的击杀计分与 deaths 是同一块里的两件事,一并不许动。
		_check(h_over._scores.is_empty(),
				"[1v1] ★ MATCH_OVER 之后倒地**不得**给对方加分(实得 _scores=%s)"
				% str(h_over._scores))


# 造一具**新**宿主、置成 `state`、制造一次倒地,返回它。
# ★ 顺手断言 `is_downed()`:没有它,"记账为 0"在**夹具根本没把玩家打倒**时也成立 ——
#   非空性就会从兄弟宿主那里借来(第一版就是这样),而 Task 4/5 的夹具彼此不同,借不得。
func _host_after_down(tag: String, roles: Array, state: int, victim: int, killer: int) -> Node:
	var host: Node = _mount(tag, roles)
	host._round_state = state
	# ★ 计数器**在置完状态之后、制造倒地之前**归零:`MatchHost._ready()` 自己会
	#   `_broadcast_round_state()` 一次(进 COUNTDOWN)⇒ 不清零的话"MATCH_OVER 相 0 次广播"
	#   会被那一次**开局**广播喂假(读数与本次倒地无关)。
	# ★ 只有 1v1 / 3v3 是计数器型宿主;大乱斗那支(Task 4/5)没有这个字段,故先判类型。
	if host is CountingDuelHost or host is CountingTeamHost:
		host.rpc_calls = 0
	_down(host, victim, killer)
	_check((host.players[victim] as Node2D).is_downed(),
			"[仪器][%s] 夹具确实把 %d 打倒地了(状态 %d)" % [tag, victim, state])
	return host


func _deaths_after_down(tag: String, roles: Array, state: int, victim: int, killer: int) -> int:
	return _deaths(_host_after_down(tag, roles, state, victim, killer), victim)
