extends Node

# 「对局尾段的记账与判胜口径」探针(场景模式;`-s` 做不了 —— 要实际创建宿主实例,autoload 在 `-s` 里不存在)。
# 运行方式：`"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/late_match_probe.tscn`
# 验收标准：文本 `LATE MATCH PROBE: ALL-OK`(不看退出码 —— 场景探针脚本报错时
#       `--quit-after` 到点仍 exit 0,退出码与"测试通过"不可分)。
#       - 而 `ALL-OK` 只证明"没有任何断言失败",不证明"每条断言都跑过" ——
#       本文件用 `EXPECTED_CHECKS` 那道断言计数门禁补上后半句(权威表述见 `tests/lib/probe_base.gd` 文件头)。
#
# 收的是用户 2026-09-28 裁定要修的三条「终局/离场之后」的口径:
#   ①② MATCH_OVER 之后倒地不再进任何记账(1v1 / 3v3 各一相)
#   ③   3v3 离场者 ACS 的分母 = 掉线那一刻的局号,不是宽限到点的局号
#   ③b  同一条的写入端:`_enter_grace` 真的把局号记了下来(③ 只验读端 —— 删掉写入端那一行,
#       原 bug 逐字复活而 ③ 照旧全部断言通过;见 `_phase_grace_writer` 上方的长注释)
#   ④⑤  大乱斗 `_match_winner` 的并列候选集(全场 0 杀 + 有人离开  ->  平局,不是幸存者独胜)
#
# 注意事项：为什么大乱斗那一处没有对应的"MATCH_OVER 后倒地"相:三个模式的倒地边沿是
#    同一规范的三种具体实现,但大乱斗那一份的形状本来就不同 —— 它的整支
#    `_match_round_tick` 就是一个 `match _round_state:`,倒地边沿住在 `RoundState.PLAYING`
#    分支里  ->  终局后天然不记账。1v1(`match_round.gd`)与 3v3(`team_host.gd`)那两份把边沿
#    写在 `match` 之前导致缺陷暴露。给无缺陷的分支添加断言则属于缺乏测试意义的无效断言。
#
# 注意事项：那道状态闸覆盖的不止 `deaths` 一项。写下来是为了让后来者别把下列现象读成无关的回归 ——
#    闸写对了  ->  MATCH_OVER 之后倒地不再:① 进 `_stats`(逐人 `deaths`)、② 给对方/对方队加分
#    (`_scores`,三模式各有一份自己的写法)、③ 掉武器(`_drop_all_but_one`)、
#    ④ 把胜方瞬移回出生点 —— -  ④ 是 1v1 独有:`_reset_survivor` 住
#    `server/match_round.gd`,而 3v3 那份对应的 `_reset_killer_only` 已按用户要求于
#    2026-09-21 整体删除(它今天的 `_match_round_tick` 里没有"复位谁"这回事)、
#    ⑤ 再广播一次带新 `mvp` 的终局载荷(`_broadcast_kill` + `_broadcast_round_state`)。
#    下面固定绑定的是 ①② 与 ⑤;③④ 是同一道闸的同一批后果,没有独立的落点
#    (③ 由 `death_drop_probe` 在 PLAYING 侧覆盖,④ 的 MATCH_OVER 侧今天无防御性校验)。
#     ->  终局之后看不到胜方被传送、也看不到第二次终局播报,那是本项要的,不是回归。
#
# 注意事项：两条已登记的残留(照实,别读成已覆盖):
#    (i) 计数器型宿主的 `_rpc_all` 覆写把基类的缺省实参又写了一遍
#        (`CountingDuelHost` / `CountingTeamHost` 的 `args: Array = []` / `except_role: int = -1` /
#        `live_only: bool = true`)。基类将来改了缺省值而这里没跟着改  ->  本探针数到的是
#        另一个形状的广播,与生产不是同一次调用,而断言保持测试通过。
#        今天无害(两个覆写与 `server/match_host.gd` 逐字一致),但它是复制而非派生。
#    (ii) 3v3 那条带外链 `_on_peer_left -> _enter_grace` 没有 3v3 专属的端到端覆盖。
#        本文件只覆盖了 `_enter_grace` 本体(③b 手工喂 `_host`);那行共享条件
#        (`if _royale or _team_mode:`)的真实网络链路验证走的是大乱斗那一支,3v3 侧实际没有被
#        跑过一次 —— 而唯一覆盖 3v3 真实网络链路的 `tests/probe/team_match_probe` 是既有的 FAIL
#        (见 docs/eng/tests.md)。 ->  这一格今天没有可信的防御性校验。
#
# 手法照 `tests/probe/death_drop_probe.gd`:实际创建宿主实例、role_peers 传空(不建玩家、不排 peer、
# 广播静默提前返回),玩家由本探针自己摆进 `host.players`,宿主自己的物理帧关掉(只手动推状态机)。
# 地图严格约束 `newfactory.cyrm`;出生点显式传(不走任何 shuffle  ->  跨进程可复现)。

const MAP := "res://maps/newfactory.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
# - 出生格从地图自己的 spawn 元数据派生(`MapFormat.load_spawns(MAP)` 的
#   `player` / `player2`),不写死坐标:旧值 (17,65)/(133,64) 是上一版 PvP 图的出生点,
#   本图的出生点是 (23,43)/(26,9)。同队内错开 3 格只是可读性 —— 本文件四条口径**都不依赖
#   玩家站在哪**(`_place` 只把它当落点,物理帧全关)。派生收在 `_init_spawns()`:
#   `const` 调不了函数,故这两个是 `var`,由 `_ready()` 在挂任何宿主之前填好。
var TEAM_SPAWNS := {}
var ROYALE_SPAWNS := {}

# - 本文件是 Task 4/5 要接着扩的脚手架  ->  更需要该校验门禁:helper 里的脚本错误不会让 `_failures`
#   非空,它只让那个函数当场结束、调用方继续  ->  断言被静默跳过而 verdict 照打 `ALL-OK`
#   (权威表述见 `tests/lib/probe_base.gd` 文件头)。
# - 这个数由实跑填,不照抄别处。数法 = 逐条点实跑的 `_check` 次数(不是数源码里的
#   `_check` —— helper 里那条每具宿主跑一次,不在 `_phase_*` 的函数体里):
#     `_phase_down_accounting` 单次完整执行包含 10 条断言:
#       - `_host_after_down` 的 `is_downed` 仪器 ×4(PLAYING / ROUND_OVER / COUNTDOWN / MATCH_OVER
#         各一具新宿主)
#       - PLAYING 的 `deaths`(反向对照)+ PLAYING 的 `rpc_calls > 0`(计数器仪器)
#       - ROUND_OVER 的 `deaths` / COUNTDOWN 的 `deaths`(-  两格合起来 = 「只排除 MATCH_OVER」
#         这条承诺的整个差集,见 `_phase_down_accounting` 上方那段)
#       - MATCH_OVER 的 `deaths` + MATCH_OVER 的 `rpc_calls == 0`
#     两个模式各一遍  ->  20;1v1 那遍另加 1 条 `_scores`  ->  21。
#   `_phase_disconnect_round`(Task 4)单次执行包含 3 条断言:
#       - 掉线时局号的 `[仪器]`(`_round_num == 1`)
#       - 切换局后的局号仪器校验（`_round_num == 2`；证明阶段状态确实已推进）
#       - 主断言 `_rounds_for(1) == 1`
#   `_phase_grace_writer`(Task 4 补;经真 `_enter_grace`)单次执行包含 2 条断言:
#       - `[仪器]` 调用前 `_leave_round` 为空
#       - 主断言 `_leave_round[1] == _round_num`
#   `_phase_royale_winner`(Task 5)单次执行包含 6 条断言:
#       - ④ 的 `_scores` 为空(仪器)+ ④ 的「全场 0 杀 + 有人离开  ->  平局 0」
#       - ⑤ 的反向对照(有分差判高者)+ ⑤b(离开者有分仍按分判胜)
#       - ⑤c 的幸存者数仪器 + ⑤c(只身幸存者且有分  ->  判他胜;堵住退化实现的覆盖上限)
#    ->  合计 21 + 3 + 2 + 6 = 32(与实跑输出的那行「断言计数:32 条」逐字相符)。
const EXPECTED_CHECKS := 32

var _failures: Array[String] = []
var _checks := 0


# ── 计数器型宿主(把"终局后不得再广播终局载荷"这条症状变成读数)──────────────
# `_rpc_all` 是本文件唯一能观测"到底广播了没有"的口子:本探针 `role_peers` 传空  ->  它的 for 循环
# 一次都不跑 —— 不是提前 return,也就是说"广播真的发生了、只是没有收件人"。
#  ->  覆写它数调用次数,就把"MATCH_OVER 之后不再广播一次带新 mvp 的终局载荷"固定绑定了。
# - 只计数、原样 `super` 转发(缺省实参一个不改) ->  对生产行为零扰动。
# - 为什么不复用现成的读法:这条路径上没有任何可观测的状态变化(`_scores`/`deaths` 由上面两条
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


# 两个模式的出生格:从地图自己那张 spawn 元数据派生(理由见 `TEAM_SPAWNS` 上方那段)。
# - 期望值取自 `MapFormat.load_spawns(MAP)` —— 与 `MatchBootstrap` / 两个宿主读的是同一份
#   meta(它们也走 `MazeGenerator.load_spawns()`)。缺出生点是夹具坏了,不兜底保护、直接断言失败。
# - 改写后仍拦得住的变异:出生格与地图脱钩(夹具摆在与断言无关的点上)—— 写死的旧坐标在
#   换图之后正是这一档,而它一行报错都不会有。
# - 此处刻意不调用 `_check` 记录：避免增加 `_checks` 计数而干扰 `EXPECTED_CHECKS` 门禁
#   （否则门禁失败提示会误导为断言未登记，掩盖夹具缺失的根本原因）。
func _init_spawns() -> void:
	var sp := MapFormat.load_spawns(MAP)
	var p1: Vector2i = sp.get("player", Vector2i(-1, -1))
	var p2: Vector2i = sp.get("player2", Vector2i(-1, -1))
	if p1.x < 0 or p2.x < 0:
		var why := "地图 %s 需同时有 `# player` 与 `# player2`(本文件的出生格取自它们)" % MAP
		_failures.append(why)
		print("[lm]   FAIL %s" % why)
	TEAM_SPAWNS = {1: p1, 2: p1 + Vector2i(3, 0), 3: p1 + Vector2i(6, 0),
			4: p2, 5: p2 + Vector2i(3, 0), 6: p2 + Vector2i(6, 0)}
	ROYALE_SPAWNS = {1: p1, 2: p1 + Vector2i(3, 0), 3: p1 + Vector2i(6, 0)}


func _ready() -> void:
	_init_spawns()
	_phase_down_accounting("1v1", [1, 2])
	_phase_down_accounting("3v3", [1, 4])
	_phase_disconnect_round()
	_phase_grace_writer()
	_phase_royale_winner()
	# - 断言断言计数门禁:跑少了就是有断言被静默跳过(见 `EXPECTED_CHECKS` 上方的说明)。
	# 注意事项：判定依据采用双向严格比对 `!=`（而非单向 `<`）：执行超出预期同样判定门禁失败 ——
	#    表明 `EXPECTED_CHECKS` 门禁与实际执行脱节，无法有效覆盖后续新增的断言
	#    （与 `tests/smoke/room_sweep_smoke.gd` 中的严格对账逻辑一致，杜绝新增检查未登记入门禁）。
	if _checks != EXPECTED_CHECKS:
		var short_msg := ("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上 —— 要么有断言被静默跳过、"
				% [_checks, EXPECTED_CHECKS]
				+ "要么有新断言没登记进 EXPECTED_CHECKS(helper 里的脚本错误只让那个函数当场结束、"
				+ "调用方照常往下走,`_failures` 不会非空)")
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

# 按模式造一具新宿主。-  每相各用一具:`_down_counted` 闩与 `_stats` 都留在宿主上,
# 复用会导致后续阶段直接命中 continue 提前跳过，使断言沦为无意义的伪通过。
# - 1v1 / 3v3 走计数器型子类(`CountingDuelHost` / `CountingTeamHost`)—— 只多一个 `rpc_calls`
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
	# - 禁用宿主自身的 `_physics_process`：本探针仅由测试手动单步推进状态机。若不禁用，帧末
	#   引擎自动调度的物理帧会引入快照与复活逻辑的干扰（与 death_drop_probe / team_host_probe 设计一致）。
	host.set_physics_process(false)
	for r in roles:
		_place(host, int(r))
	return host


func _place(host: Node, role: int) -> Node2D:
	var p: Node2D = (preload("res://scenes/player/player.tscn") as PackedScene).instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	host.players[role] = p
	# - 出生点取宿主自己那张表(显式传 spawns  ->  首局 `_spawn_cell` 返回的就是那格;
	#   `death_drop_probe` 的 3v3 相已证明这条路径可用)。取到无效格时退到 (1,1) ——
	#   本文件的四条口径都不依赖玩家站在哪,位置只影响可读性,但 (-1,-1) 会让玩家
	#   落在世界原点、可能压在实心格里。
	var spawn: Vector2i = host._spawn_cell(role)
	if spawn.x < 0 or spawn.y < 0:
		spawn = Vector2i(1, 1)
	var ts: int = GameParameters.TILE_SIZE
	p.global_position = Vector2(float(spawn.x) * ts + ts * 0.5,
			float(spawn.y) * ts + ts * 0.5)
	p.set_physics_process(false)     # 本探针不验玩家物理
	return p


# 制造一次倒地边沿(照 team_host_probe 的 `_down`):写归因 meta -> force_down -> 推一帧。
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
# 四个状态各用一具新宿主（`_down_counted` 闩与 `_stats` 保留在宿主实例上，复用会导致后续阶段产生假阳性通过）:
#   PLAYING -> 照常记录 death（反向对照：验证记账链路处于活跃状态；若缺少该对照，不记账断言将退化为无效断言）
#   ROUND_OVER -> 照旧记 death
#   COUNTDOWN -> 照旧记 death(-  见下面那条「差集」注释:它与 ROUND_OVER 合起来才把
#                "只排除 MATCH_OVER"这条承诺钉完整)
#   MATCH_OVER -> 不得记 death(终局后残留的爆炸致死会走到这条边沿:它会 +1 death、
#                再掉一次武器、并再广播一次带新 mvp 的终局载荷;-  1v1 还会把胜方瞬移回出生点)
func _phase_down_accounting(tag: String, roles: Array) -> void:
	print("[lm] ── %s:倒地记账的状态闸 ──" % tag)
	var victim: int = int(roles[0])
	var killer: int = int(roles[1])

	# ── PLAYING:反向对照(必须先有)+ 计数器仪器自检 ──
	# 若缺少反向对照，即使完全移除倒地边沿逻辑也会错误通过测试（恒为 0 导致的假阳性）。
	var h_playing: Node = _host_after_down(tag, roles, MatchHost.RoundState.PLAYING, victim, killer)
	var n_playing: int = _deaths(h_playing, victim)
	_check(n_playing == 1,
			"[%s] ★ 反向对照:PLAYING 里倒地**照常**记 death(实得 %d;若为 0,说明记账路径根本没接上,"
			% [tag, n_playing] + "下面那条就是恒绿的摆设)")
	_check(h_playing.rpc_calls > 0,
			"[仪器][%s] PLAYING 里倒地**确实广播了**(实得 _rpc_all 调了 %d 次;若为 0,"
			% [tag, h_playing.rpc_calls]
			+ "说明计数器根本没接上,下面那条 `== 0` 就是恒绿摆设)")

	# ── ROUND_OVER / COUNTDOWN:只排除 MATCH_OVER —— 这两格合起来才把承诺钉完整 ──
	# 注意事项：差集(本项真正的边):`== MATCH_OVER` 与 `== PLAYING` 两种写法的差别不是 PLAYING,
	#   而是 `{ROUND_OVER, COUNTDOWN}` —— `PLAYING` 下 `== MATCH_OVER` 为假  ->  `continue` 不走
	#    ->  记账照常(这正是当初把"`!= PLAYING` 会让 PLAYING 也不记账"推反的那一处)。
	#    ->  只钉 ROUND_OVER 是半个承诺:把闸写成 `if _round_state != PLAYING: continue`
	#   (语义等价于"只放行 PLAYING")时,ROUND_OVER 那条会红、而 COUNTDOWN 那一格没人测。
	#   故两个状态分别配置独立断言，错误信息中明确注明边界差集（清晰呈现判定逻辑，避免误读）。
	var n_round_over: int = _deaths_after_down(tag, roles, MatchHost.RoundState.ROUND_OVER, victim, killer)
	_check(n_round_over == 1,
			"[%s] ★ ROUND_OVER 期间倒地**照旧**入账(实得 %d)。本项钉的是「**除 MATCH_OVER 与"
			% [tag, n_round_over]
			+ " COUNTDOWN 之外**照旧入账」;ROUND_OVER 与 COUNTDOWN 两格已各有一条断言"
			+ "(闸写成 `!= PLAYING` 会让这两条红,而其余断言一条都不会)")
	var n_countdown: int = _deaths_after_down(tag, roles, MatchHost.RoundState.COUNTDOWN, victim, killer)
	_check(n_countdown == 1,
			"[%s] ★ COUNTDOWN 期间倒地**照旧**入账(实得 %d)。本项钉的是「**除 MATCH_OVER 与"
			% [tag, n_countdown]
			+ " COUNTDOWN 之外**照旧入账」;ROUND_OVER 与 COUNTDOWN 两格已各有一条断言"
			+ "(只钉 ROUND_OVER 时,这一格是那道闸唯一没人测的差)")

	# ── MATCH_OVER:本项 ──
	var h_over: Node = _host_after_down(tag, roles, MatchHost.RoundState.MATCH_OVER, victim, killer)
	_check(_deaths(h_over, victim) == 0,
			"[%s] ★ MATCH_OVER 之后倒地**不得**进 `_stats`(实得 deaths=%d;终局后残留的爆炸致死会走到"
			% [tag, _deaths(h_over, victim)]
			+ "这条边沿 —— 它会 +1 death、再掉一次武器、并再广播一次带新 mvp 的终局载荷;"
			+ "1v1 还会把胜方瞬移回出生点)")
	_check(h_over.rpc_calls == 0,
			"[%s] ★ MATCH_OVER 之后倒地**不得**再广播终局载荷(实得 _rpc_all 调了 %d 次;"
			% [tag, h_over.rpc_calls] + "非 0 = 客户端会再收一条带新 mvp 的 round_state)")
	if tag == "1v1":
		# 1v1 的击杀计分与 deaths 是同一块里的两项关键逻辑,一并不许动。
		_check(h_over._scores.is_empty(),
				"[1v1] ★ MATCH_OVER 之后倒地**不得**给对方加分(实得 _scores=%s)"
				% str(h_over._scores))


# 造一具新宿主、置成 `state`、制造一次倒地,返回它。
# - 额外断言校验 `is_downed()`:没有它,"记账为 0"在夹具根本没把玩家打倒时也成立 ——
#   非空性就会从兄弟宿主那里借来(第一版就是这样),而 Task 4/5 的夹具彼此不同,借不得。
func _host_after_down(tag: String, roles: Array, state: int, victim: int, killer: int) -> Node:
	var host: Node = _mount(tag, roles)
	host._round_state = state
	# - 计数器在置完状态之后、制造倒地之前归零:`MatchHost._ready()` 自己会
	#   `_broadcast_round_state()` 一次(进 COUNTDOWN) ->  不清零的话"MATCH_OVER 相 0 次广播"
	#   会被那一次开局广播喂假(读数与本次倒地无关)。
	# - 只有 1v1 / 3v3 是计数器型宿主;大乱斗那支(Task 4/5)没有这个字段,故先判类型。
	if host is CountingDuelHost or host is CountingTeamHost:
		host.rpc_calls = 0
	_down(host, victim, killer)
	_check((host.players[victim] as Node2D).is_downed(),
			"[仪器][%s] 夹具确实把 %d 打倒地了(状态 %d)" % [tag, victim, state])
	return host


func _deaths_after_down(tag: String, roles: Array, state: int, victim: int, killer: int) -> int:
	return _deaths(_host_after_down(tag, roles, state, victim, killer), victim)


# ── ③ 3v3:离场者 ACS 的分母 = 掉线那一刻的局号 ─────────────────────────────
# 病根:`mark_disconnected` 由 `server_main._expire_graces` 在宽限期(60s)到点时调,
# 而它写的是那一刻的 `_round_num`。这 60s 若跨过一次换局,离开者的分母就多算一局
#  ->  ACS 被压低,与「已离开者分母更小  ->  更容易胜出」(设计约定的取向)恰好相反。
func _phase_disconnect_round() -> void:
	print("[lm] ── 3v3:离场者的局数分母 = 掉线那一刻 ──")
	# - 三个人:1、2 同队、4 敌队 —— 掉 1 之后两队都还有人,不会触发"走光即弃权"那条收场。
	var host: Node = _mount("3v3", [1, 2, 4])
	host._round_state = MatchHost.RoundState.PLAYING
	_check(host._round_num == 1,
			"[仪器] 掉线时局号 == 1(实得 %d)" % host._round_num)

	# 掉线当场记一笔 —— 生产里由 `server_main._enter_grace` 调本函数。
	host.note_disconnect_round(1)

	# 宽限期内换了一局(-  与 team_host_probe 的 `_next_round_clean` 相同处理逻辑:
	#   `_start_next_round` 见到 `_rounds_won` 达标会直接进 MATCH_OVER 并 return)。
	host._rounds_won = {}
	host._start_next_round()
	_check(host._round_num == 2,
			"[仪器] 换局后局号 == 2(实得 %d;若仍是 1,说明 `_start_next_round` 没走到换局那一支,本相白测)"
			% host._round_num)

	# 宽限到期,正式移出
	host.mark_disconnected(1)
	_check(host._rounds_for(1) == 1,
			"★ 离场者的局数分母应是**掉线那一刻**的 1,不是宽限到点的 2(实得 %d)"
			% host._rounds_for(1))


# ── ③b 写入端:`_enter_grace` 真的把掉线局号记下来了 ───────────────────────────
# 注意事项：为什么必须单独有该测试阶段:③ 自己注入那一笔(`host.note_disconnect_round(1)`) ->  它验的是
#    读端 + `MatchState` 新 API + 兜底保护,而生产里那一笔的唯一写入口是
#    `server_main._enter_grace`。删掉那里的一行,`_leave_round` 就永远为空、
#    `mark_disconnected` 静默退回 `_round_num` 兜底保护  ->  **原 bug 逐字复活,而 ③ 与全仓其它
#    测试照旧全部断言通过**(与本批 `duel_spawn_timeout_smoke` 钉 `set_process(false)` 位置、
#    `room_sweep_smoke` 钉 `_expire_graces` 含 `mark_disconnected(role)` 是同一种形状)。
#
# - 手法照 `tests/probe/team_host_probe.gd` ⑫ / ⑫d:`server_main.gd` 的实例不进树
#    (`_ready` 会 `NetBus.start_server(7777)` 并启动大厅 —— 那是真端口,探针绝不能碰),
#    手工填它需要的字段后直接调 `_enter_grace`。该函数体不依赖树,故"不进树"不影响判定条件。
#
# - 夹具字段集是读代码确认的,不是假设。`_enter_grace` 一路读到的:`_grace`
#    (var 声明处即 `GraceWindow.new()`  ->  out-of-tree 实例天然有)、`_host`;进了
#    `if _host != null` 之后读 `_host.input_sources`(`src != null` 防御性校验:本探针 role_peers 传空
#     ->  表是空的  ->  防御性校验跳过)、`_host._pending_input`(字典,直接赋值)、
#    `_host.note_disconnect_round`、`_host.peer_by_role`(空表  ->  erase 是 no-op)、
#    `_host._broadcast_round_state()`(空 `peer_by_role`  ->  `_rpc_all` 的循环一次都不跑 = no-op,
#    本文件所有相都靠这条)。-  `_sync_grace_snapshot` / `grace_snapshot` 是同文件内的
#    调用与被子类继承的字段,不需要夹具额外摆位。
#
# 注意事项：本条的变异反证登记为"未做":删掉 `server_main.gd` 那一行、看本阶段变红 —— 那次实跑
#    没有做,因为另一个会话当时正占着该文件在写(改它会让两份未提交改动互相卷入,
#    而丢失的那一侧不会有任何报错)。 ->  "写入端没有防御性校验"这个判断是靠读代码确立的,
#    本条断言的有效性未经变异实测。后来者若单独占着该文件,补跑那一次即可。
func _phase_grace_writer() -> void:
	print("[lm] ── 3v3:写入端(`_enter_grace`)真的记了掉线局号 ──")
	var host: Node = _mount("3v3", [1, 2, 4])
	host._round_state = MatchHost.RoundState.PLAYING
	# - 仪器:调用之前必须是空的 —— 否则下面那条会被"表里先前就有的某个值"误判通过,
	#   而写入端接没接上根本照不出来(那正是本条要防的那种扫描失效（未读取到源文件）)。
	_check(host._leave_round.is_empty(),
			"[仪器] 调 `_enter_grace` 之前 `_leave_round` 是空的(实得 %s;非空 ⇒ 下面那条没有区分度)"
			% str(host._leave_round))
	# - 用无类型变量接实例:`var srv: Node = …` 会让 `srv._host` 在编译期就报
	#   "Node 上没有该属性"(同 team_host_probe ⑫ 的理由)。
	var srv = load("res://server/server_main.gd").new()
	srv._host = host
	srv._enter_grace(1)
	# - 判定条件用哨兵 `-1`:写成 `_leave_round.get(1, host._round_num)` 会因缺省值与期望值相同而测试漏报
	#   （缺省值与期望值同源，若写入端被移除仍会错误通过测试，造成假阳性漏报）。
	_check(int(host._leave_round.get(1, -1)) == int(host._round_num),
			"★ `_enter_grace` 当场记下**掉线那一刻**的局号(期望 %d,实得 %s;"
			% [host._round_num, str(host._leave_round)]
			+ "删掉 server_main.gd 里 `_host.note_disconnect_round(role)` 那一行 ⇒ 本表恒空、"
			+ "读写两半一起退回原 bug)")
	srv.free()


# ── ④⑤ 大乱斗:`_match_winner` 的并列候选集 ────────────────────────────────────
# 病根:候选 = `players ∪ _scores`。一个0 杀的离开者两边都不在(`mark_disconnected` 把他从
# `players` 里 erase,`_scores` 里也没有他的条目) ->  少一个并列候选  ->  全场 0 杀时
# "多人并列  ->  平局"被翻转成幸存者独胜。
# - `scenes/royale_game.gd` 那道 `and not _match_ended` 门正是为挡这次翻转而立的
#   (它的注释写着「要删先修 `_match_winner`」)—— 但删它不在本批范围(peer 的层 + 需要用户点头)。
func _phase_royale_winner() -> void:
	print("[lm] ── 大乱斗:_match_winner 的并列候选集 ──")
	# ── ④ 全场 0 杀 + 离开者  ->  平局 ──
	# 注意事项：与 brief 的差异(实测订正,见报告):brief 写的是「3 人里走 1 人  ->  平局」,但
	#   3 人走 1 人还剩 2 人,那两个幸存者彼此就在 0 杀上并列  ->  `tie` 照样为真、恒返回 0
	#   —— 实测在修复前即可错误通过测试，导致用例 ④ 退化为无法检出缺陷的假阳性断言。
	#   `tie` 要成立得有 ≥2 个候选共享最高分,故病只在「幸存者只剩一个」时暴露异常:
	#   他是唯一候选  ->  没有第二个候选能置 `tie`  ->  独胜,而那个 0 杀离开者本该让他无法独胜。
	#   这正是 docs/eng/modes.md 记的那句「从 `0`(平局)翻成幸存的那个 role」。
	#   故 ④ 让 3 人里走 2 人(第二次退出才会 `players.size() < 2`  ->  真走 `_finish_match`,
	#   与生产里"最后一个对手离开触发终局"是同一条路径)。
	var h1: Node = _mount("royale", [1, 2, 3])
	h1._round_state = MatchHost.RoundState.PLAYING
	h1.mark_disconnected(3)
	h1.mark_disconnected(2)
	_check(h1._scores.is_empty(),
			"[仪器] 全场 0 杀(实得 _scores=%s;若非空,下面这条测的就不是「并列」)" % str(h1._scores))
	_check(h1._match_winner() == 0,
			"★ 全场 0 杀 + 有人离开 ⇒ 平局 0,不是幸存者独胜(实得 %d)" % h1._match_winner())

	# ── ⑤ 反向对照:有分差时仍判分高者 ──
	# 没有它,"恒返回 0"也能让 ④ 通过。
	var h2: Node = _mount("royale", [1, 2, 3])
	h2._round_state = MatchHost.RoundState.PLAYING
	h2._scores[1] = 2
	h2._scores[2] = 1
	h2.mark_disconnected(3)
	_check(h2._match_winner() == 1,
			"★ 反向对照:有分差时判分高者(期望 1,实得 %d)" % h2._match_winner())

	# ── ⑤b 得分者离开后,他的分仍参与比较(既有语义,防被本次改动破坏)──
	var h3: Node = _mount("royale", [1, 2, 3])
	h3._round_state = MatchHost.RoundState.PLAYING
	h3._scores[3] = 5
	h3.mark_disconnected(3)
	_check(h3._match_winner() == 3,
			"★ 离开者**有分**时仍按分判胜(期望 3,实得 %d)" % h3._match_winner())

	# ── ⑤c 只身幸存者且他有分  ->  判他胜(补住"退化实现"那条覆盖上限)──
	# - 为什么必须补这一格:本阶段(以及 ④)原先唯一走到"只剩一人"的路径是全场 0 杀  -> 
	#   一个假想的退化实现 `if players.size() < 2: return 0` 能全部断言通过(0 杀那格本来就期望 0)。
	#   这里让唯一的幸存者带着分 —— 真实现返回他的 role,退化实现返回 0,两者当场分开。
	# - 它与 ⑤b 的区别就在这一格上:⑤b 里离开者走后还剩两人(`players.size() == 2`),
	#   退化实现的该校验门禁根本不点火,discriminating 不了。
	var h4: Node = _mount("royale", [1, 2, 3])
	h4._round_state = MatchHost.RoundState.PLAYING
	h4._scores[3] = 4
	h4.mark_disconnected(1)
	h4.mark_disconnected(2)
	_check(h4.players.size() == 1,
			"[仪器] ⑤c 的夹具确实只剩一个幸存者(实得 players=%s;若 ≥2,本格对退化实现没有鉴别力)"
			% str(h4.players.keys()))
	_check(h4._match_winner() == 3,
			"★ 只身幸存者**有分**时应判他胜(期望 3,实得 %d;退化成 `players.size() < 2 ⇒ 0` 会返回 0)"
			% h4._match_winner())
