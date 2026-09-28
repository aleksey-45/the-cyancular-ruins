extends Node

# 「对局尾段的记账与判胜口径」探针(场景模式;`-s` 做不了 —— 要真建宿主,autoload 在 `-s` 里不存在)。
# 跑法:`"$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn`
# 判据:文本 `LATE MATCH PROBE: ALL-OK`(**不看退出码** —— 场景探针脚本报错时
#       `--quit-after` 到点仍 exit 0,退出码与"跑通了"不可分)。
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
# 手法照 `tests/death_drop_probe.gd`:真建宿主、**role_peers 传空**(不建玩家、不排 peer、
# 广播静默早退),玩家由本探针自己摆进 `host.players`,宿主自己的物理帧关掉(只手动推状态机)。
# 地图钉死 `factory1v1.cyrm`;出生点显式传(不走任何 shuffle ⇒ 跨进程可复现)。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
const TEAM_SPAWNS := {1: Vector2i(17, 65), 2: Vector2i(20, 65), 3: Vector2i(23, 65),
		4: Vector2i(133, 64), 5: Vector2i(136, 64), 6: Vector2i(139, 64)}
const ROYALE_SPAWNS := {1: Vector2i(17, 65), 2: Vector2i(20, 65), 3: Vector2i(23, 65)}

var _failures: Array[String] = []


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[lm]   ok   %s" % msg)
	else:
		_failures.append(msg)
		print("[lm]   FAIL %s" % msg)


func _ready() -> void:
	_phase_down_accounting("1v1", [1, 2])
	_phase_down_accounting("3v3", [1, 4])
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
func _new_host(tag: String) -> Node:
	match tag:
		"1v1":
			return MatchHost.new(MAP, {})
		"3v3":
			return TeamHost.new(MAP, {}, {}, [], TEAM_SPAWNS, TEAMS)
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


# ── ①② MATCH_OVER 之后倒地不记账(1v1 / 3v3 各一相)──────────────────────────
func _phase_down_accounting(tag: String, roles: Array) -> void:
	print("[lm] ── %s:MATCH_OVER 之后倒地不记账 ──" % tag)
	var victim: int = int(roles[0])
	var killer: int = int(roles[1])

	# ── 反向对照(必须先有):PLAYING 里**照常**记账 ──
	# 没有这一相,"把整个倒地边沿块删掉"也能让下面那条通过(恒 0 = 恒绿)。
	var h1: Node = _mount(tag, roles)
	h1._round_state = MatchHost.RoundState.PLAYING
	_down(h1, victim, killer)
	_check(_deaths(h1, victim) == 1,
			"[%s] ★ 反向对照:PLAYING 里倒地**照常**记 death(实得 %d;若为 0,说明记账路径根本没接上,"
			% [tag, _deaths(h1, victim)]
			+ "下面那条就是恒绿的摆设)")

	# ── 本项:MATCH_OVER 里倒地**不得**记账 ──
	var h2: Node = _mount(tag, roles)
	h2._round_state = MatchHost.RoundState.MATCH_OVER
	_down(h2, victim, killer)
	_check(_deaths(h2, victim) == 0,
			"[%s] ★ MATCH_OVER 之后倒地**不得**进 `_stats`(实得 deaths=%d;"
			% [tag, _deaths(h2, victim)]
			+ "终局后残留的爆炸致死会走到这条边沿 —— 它会 +1 death、再掉一次武器、并再广播一次带新 mvp 的终局载荷)")
	if tag == "1v1":
		# 1v1 的击杀计分与 deaths 是同一块里的两件事,一并不许动。
		_check(h2._scores.is_empty(),
				"[1v1] ★ MATCH_OVER 之后倒地**不得**给对方加分(实得 _scores=%s)"
				% str(h2._scores))
