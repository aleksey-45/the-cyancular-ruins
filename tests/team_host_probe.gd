extends Node

# TeamHost:按队出生散点 / 按队计分 / 只复位击杀者 / 换边。场景模式。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn
# 通过 = `TEAM HOST: ALL-OK`。
#
# ═══ 为什么需要它 ═══
# ★ 这些判断错了**都不报错**:出生点算错=开局挤在一起(玩家只会觉得"怎么老出生在一块");
#   计分算错=比分不动或两边同涨(要打完一整局才发现);复位算错=把人往错的地方送。
# ★ 真建 TeamHost(role_peers 传空)+ 手工摆 6 个玩家 —— 走的是**生产代码路径**,
#   不是"调方法断言返回值"。
#
# ═══ 覆盖范围(随 A 册任务递增)═══
# ①②③ 由 Task 4 落(出生散点 / 换边点集 / 宿主接线);
# ④ 按队计分、⑥ 收局由 Task 5 落(④ 在那时被**换掉** —— Task 4 那版数值上巧合重合、
#   区分不了团队语义,见 ④ 里的说明);
# ⑤ 只复位击杀者由 Task 6 落(brief 正文里这段写作 ⑦/⑩,同一个东西);
# ⑦ 换边/终局、⑧ 掉线随 Task 7/8 追加到本探针末尾。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

var _fails: Array[String] = []
var _host = null
var _ran_to_end := false


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


# ★ 必须 `await _run()` 再 `_finish()`:`_run()` 里有 `await get_tree().physics_frame`(协程),
#   同步调 `_finish()` 会在断言跑完**之前**执行 → 所有真断言都 ok 却打出 FAIL(假红)。
func _ready() -> void:
	await _run()
	_finish()


func _place(host, role: int, at: Vector2i) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	p.collision_mask |= 2
	host.players[role] = p
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(at.x * ts + ts * 0.5, at.y * ts + ts * 0.5)
	return p


# ── ⑤(只复位击杀者)的两个小工具 ──
# 把这些人全挪到同一个"远点"。★ 不这么做的话,"没被复位"与"被送回自己的出生点"可能落在
# 同一数值上,断言就成了恒真的摆设(远点按构造 ≠ 任何出生点,故两者必然可区分)。
# 已倒地的人也能挪 —— 这里只动 `global_position`,不碰战斗状态。
func _park(host, roles: Array, at: Vector2) -> void:
	for r in roles:
		var p: Node2D = host.players.get(r)
		if p == null or not is_instance_valid(p):
			continue
		p.global_position = at


# 这些人里还有几个**不在**远点上(> 0 = 有人被复位了)。
func _moved_from(host, roles: Array, at: Vector2) -> int:
	var n := 0
	for r in roles:
		var p: Node2D = host.players.get(r)
		if p == null or not is_instance_valid(p):
			continue
		if p.global_position.distance_to(at) > 2.0:
			n += 1
	return n


func _run() -> void:
	# ★ 散点几何读的是 `MazeGenerator.current_grid`(静态池的判据),而本探针在**建宿主之前**
	#   就要算散点 —— 必须先像 `TeamHost.start_on` 那样把图选好、把网格载进来,否则
	#   `SpawnPicker.grid_dims()` 越界(空网格)、`spread_cells` 返回空表 → 6 个点全 (-1,-1),
	#   ① 恒红(实际踩到)。同时 `load_grid()` 里含 `TileDefs.load_defs()`,池子的判据才与生产一致。
	MazeGenerator.set_map_file(MAP)
	GameParameters.refresh_map_size()
	WorldBuilder.load_grid()
	var teams := TeamHost.plan_team_spawns(TEAMS)
	_check(teams.size() == 6, "6 个 role 都有出生点")
	# ★ 只数 size 分不出"6 个有效点"与"6 个 (-1,-1)"(Task 4 首次红日志就是证据:空网格下
	#   6 个点全是 (-1,-1),上面那条照样 ok)。故逐点看坐标有效性。
	var bad_pts := 0
	for r in teams:
		var pt: Vector2i = teams[r]
		if pt.x < 0 or pt.y < 0:
			bad_pts += 1
	_check(bad_pts == 0, "★ 6 个出生点都是有效格,不是 (-1,-1)(实际无效 %d 个)" % bad_pts)
	# ── ① 队内近、队间远 ──
	var d := SpawnPicker.grid_dims()
	var max_in := 0
	var min_cross := 99999
	for ra in TEAMS:
		for rb in TEAMS:
			if ra >= rb:
				continue
			var dist := MazeGenerator.toroidal_dist(teams[ra], teams[rb], d.x, d.y)
			if TEAMS[ra] == TEAMS[rb]:
				max_in = maxi(max_in, dist)
			else:
				min_cross = mini(min_cross, dist)
	# 读数(不判成败):散点每跑一次都不同(shuffle),这两个数是唯一的"为什么红"的证据
	print("  [info] 队内最大距 %d / 队间最小距 %d(格)" % [max_in, min_cross])
	# ★ 这条是**不变式**,不是"通常成立":`plan_team_spawns` 里套着 `SPAWN_MAX_TRIES` 次重试
	#   专门挑满足它的一份 —— 单次散点**达不到**(半径 30 的点云在环面上重叠,实测 61.5% 的
	#   单次结果违反它、最坏情况两队有人落在同一格)。这里不写"重试 12 次"这条实现细节,
	#   只钉契约:够了就是对的,哪天重试被删掉,这条**随机**红 —— 而断言消息里的两个数
	#   就是复现它的证据。
	_check(min_cross > max_in, "★ 队间最小距离 > 队内最大距离(实际 %d vs %d)" % [min_cross, max_in])

	# ── ①b 池子别名守卫(本任务动手前那 2 行前置修改)──
	# `SpawnPicker.cells_within` 的两条**回退**分支原先直接返回**共享优选池本身**
	# (`spawn_candidates()` 返回的就是 `_prefer_cache`),正常分支却返回新数组 —— 同一个函数
	# 两种别名语义。调用方在返回值上原地 `.shuffle()` / `.erase()`,打乱的是全局池,此后所有
	# 读它的地方(`RoyaleHost.plan_spawns` 等)顺序都变:静默、不报错。现统一成"返回新数组"。
	# ★ **没有别的断言能自然覆盖它** —— 现有唯一调用方 `GridPathfinder.spread_cells` 内部第一件
	#   事就是 `duplicate()`,所以就算这 2 行被改回去,① 照样绿。故单独钉一条。
	var alias_self := [1, 2]
	var alias_ref := alias_self
	_check(is_same(alias_self, alias_ref), "[仪器] is_same 认得出同一个 Array(否则下面两条恒绿)")
	_check(not is_same([1, 2], [1, 2]), "[仪器] is_same 不把内容相同的两份当同一份")
	var pool_now: Array = SpawnPicker.spawn_candidates()
	_check(not is_same(SpawnPicker.cells_within(Vector2i(-1, -1), 5), pool_now),
			"cells_within 回退①(center 非法)返回新数组,不是共享优选池")
	_check(not is_same(SpawnPicker.cells_within(Vector2i(0, 0), -1), pool_now),
			"cells_within 回退②(筛空)返回新数组,不是共享优选池")

	# ── ② 换边:两队点集整体对调;人数不等则不换 ──
	var swapped := TeamHost.compute_swap_spawns(teams, TEAMS)
	_check(swapped.get(1) == teams.get(4), "换边后 role1 拿 2 队的点")
	_check(swapped.get(4) == teams.get(1), "换边后 role4 拿 1 队的点")
	_check(TeamHost.compute_swap_spawns(teams, {1: 1, 2: 1, 3: 2}).is_empty(), "★ 人数不等 → 不换边")

	# ── ③ 建宿主:出生点 = 开局散点(不是复活点)──
	_host = TeamHost.new(MAP, {}, {}, [], teams, TEAMS)
	add_child(_host)
	# ★ 关掉宿主自己的物理帧:本探针**手工**调 `_match_round_tick`。
	#   不关的话 `quit(0)` 是帧末生效,中间还会跑一帧 `_physics_process` → 快照广播去读
	#   尚未摆位的 `players` —— 在断言全过之后刷一屏 SCRIPT ERROR(与
	#   royale_disconnect_count_probe 同款理由)。
	_host.set_physics_process(false)
	_check(_host.role_spawns() == teams, "role_spawns() 返回的就是广播的那一份")
	for role in TEAMS:
		_place(_host, role, teams[role])
	await get_tree().physics_frame
	_check(_host.team_of(3) == 1 and _host.team_of(6) == 2, "宿主的队伍表已就位")
	# ★ 队伍表**逐值**断言(只断言"非空/查得到"抓不到下面这一档):
	#   `_init` 给 `super._init` 传**满五个**实参时,第 5 位是 `teams` 而**不是** `spawns`
	#   (RoyaleHost 那边第 5 个参数恰好就叫 spawns,极易抄错)。传错的后果不是崩溃而是
	#   `_team_of` 被塞成 `{role: Vector2i}`:`team_of()` 里 `int(Vector2i)` 报
	#   `Nonexistent 'int' constructor` 并让该函数当场返回 0(整局子弹不穿队友、team_map 空表),
	#   而 `team_of(3) == 1` 这种断言也只看到"0 != 1"、看不出根因。这里逐值看**类型**。
	var raw_kinds := {}
	for r in _host._team_of:
		raw_kinds[typeof(_host._team_of[r])] = true
	_check(raw_kinds.size() == 1 and raw_kinds.has(TYPE_INT),
			"★ _team_of 的值必须全是 int(实际类型集合 %s;塞成 Vector2i = 整局队伍判定静默全错)"
			% str(raw_kinds.keys()))
	_check(_host.team_map() == TEAMS,
			"team_map() 就是大厅给的那份 role→队号(实际 %s)" % str(_host.team_map()))
	_check(_host._enemy_team_of(4) == 1 and _host._enemy_team_of(6) == 1, "2 队的人的对方队 = 1")
	_check(_host._enemy_team_of(1) == 2 and _host._enemy_team_of(3) == 2, "1 队的人的对方队 = 2")
	_check(_host._enemy_team_of(9) == 0, "表外的 role → 对方队 0(不是猜一个)")
	_check(_host.same_team(1, 3) and not _host.same_team(1, 4), "same_team 按队生效")

	# ── ④ 按队计分:计分键是**队号**,不是 role 号 ──
	# ★ 为什么选 role2 当受害者(这条要能区分"团队语义"与"基类 1v1 语义"):基类的
	#   `_opponent_of(role)` 返回 **players 里第一个不是它的 role** —— 在 1..6 的插入顺序下
	#   `_opponent_of(2) == 1`,而 role1 与 role2 **同属 1 队**。也就是说基类实现会把分记给
	#   **受害者的队友**(`_scores == {1: 1}`),团队语义给的是**对方队**(`_scores == {2: 1}`)
	#   —— 两者在这个 role 上分叉,正是本条断言要用的缝。
	#   (Task 4 的 ④ 用的是 role4:`_opponent_of(4)` 也返回 1,而团队语义给 1 队 —— **数值巧合
	#    重合**,坏掉队伍表也照样绿,已被 M1 反证。故换成 role2。)
	_host._round_state = MatchHost.RoundState.PLAYING
	# ★ 受害者 role **只写这一处**:下面的[仪器]自检与本段的真断言必须指向同一个 role。
	#   先前自检写死 2、受害者也写死 `players[2]`,两个 `2` 各自硬编码 —— 谁把受害者换成别的
	#   role(比如重犯 Task 4 那次换 p4 的错),自检**照样绿**而本条的区分度当场消失,
	#   输出仍是 ALL-OK(实测:改成 4 时两条真断言**全部照绿** —— 基类实现 `_opponent_of(4)`
	#   也是 1 —— 只有下面这条自检红,它确实是唯一守着这条缝的东西)。
	var victim_role := 2
	# [仪器] 前置自检:上面那条缝的前提是"第一个非己 role 与受害者同队",且它**不是**受害者本人
	# (`_opponent_of` 找不到时返回 0,而 `team_of(0)` = 0 → `same_team(0, x)` 恒 false)。
	# 插入顺序若变(比如有人重排了 ③ 里的 `_place` 循环),这条缝就没了 → 自检当场红,
	# 而不是悄悄失效。
	_check(_host.players.keys() == [1, 2, 3, 4, 5, 6],
			"[仪器] players 按 role 升序插入(实际 %s)" % str(_host.players.keys()))
	_check(_host._opponent_of(victim_role) != victim_role
			and _host.same_team(_host._opponent_of(victim_role), victim_role),
			"[仪器] 受害 role %d 的「第一个非己 role」(=%d)与它同队 —— ④ 的区分度就靠这条"
			% [victim_role, _host._opponent_of(victim_role)])
	var p2: Node2D = _host.players[victim_role]
	(p2.get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	# ★ 两个队号也从 victim_role 推(不再各写一个字面量):键、断言、消息三处同源。
	var victim_team: int = _host.team_of(victim_role)
	var enemy_team: int = _host._enemy_team_of(victim_role)
	_check(int(_host._scores.get(enemy_team, 0)) == 1,
			"★ role%d(%d 队)倒地 → **%d 队** +1(键是队号;基类实现会给键 %d。实际 %s)"
			% [victim_role, victim_team, enemy_team, _host._opponent_of(victim_role), str(_host._scores)])
	_check(int(_host._scores.get(victim_team, 0)) == 0,
			"★ 受害者本队(%d 队)**不涨分**(基类实现会在这里给 %d。实际 %s)"
			% [victim_team, _host._opponent_of(victim_role), str(_host._scores)])

	# ── ⑥ 收局:把 1 队刷到 TEAM_KILLS_TO_WIN → ROUND_OVER,局胜记在**队**上 ──
	# ★ 阈值写成 `TEAM_KILLS_TO_WIN - 1` 而**不是**字面量 8:写死 8 时把常量改成任何 ≤ 9 的值
	#   (含基类的 5)下面三条**全绿** —— 收局判据那行就没人守着了(改档位时断言自动跟随)。
	_host._scores = {1: TeamHost.TEAM_KILLS_TO_WIN - 1, 2: 0}
	var p5: Node2D = _host.players[5]
	# 5 号在 2 队 → 倒地给 1 队 +1 = TEAM_KILLS_TO_WIN → 收局
	(p5.get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(1, 0)) == TeamHost.TEAM_KILLS_TO_WIN,
			"1 队到 %d 杀(实际 %s)" % [TeamHost.TEAM_KILLS_TO_WIN, str(_host._scores)])
	_check(int(_host._round_state) == int(MatchHost.RoundState.ROUND_OVER),
			"★ 到 %d 杀收局" % TeamHost.TEAM_KILLS_TO_WIN)
	_check(int(_host._rounds_won.get(1, 0)) == 1, "局胜记在**队**上(1 队 = 1)")

	# ── ⑤ 只复位击杀者本人(Task 6;brief 正文里这段写作 ⑦/⑩,同一个东西)──
	# 语义:击杀后**只**把击杀者送回本方出生点(保留血量,不治疗),队友不动。
	# ★ 三个"不复位"的档一个都不能省:无归因 / 队友误炸 / 同归于尽。
	# ★★ 每条先把在场的人全挪到一个**统一的"远点"**(按构造 ≠ 任何出生点):
	#   否则"没被复位"与"被送回自己的出生点"可能落在同一数值上 —— 那种断言恒绿、没有区分度
	#   (brief 里 (a) 那版 `位置不变 or 已倒地` 就是这种:受害者必然已倒地 → 恒真)。
	_host._round_state = MatchHost.RoundState.PLAYING
	_host._scores = {}
	var ts := GameParameters.TILE_SIZE
	var all_roles: Array = [1, 2, 3, 4, 5, 6]
	# 远点:从 (0,0) 起取第一个**不是任何出生点**的格(避开"远点恰好等于某人出生点"的巧合)
	var spawn_taken := {}
	for r in _host._round_spawns:
		spawn_taken[_host._round_spawns[r]] = true
	var away_cell := Vector2i(0, 0)
	while spawn_taken.has(away_cell):
		away_cell.x += 1
	var away := Vector2(away_cell.x * ts + ts * 0.5, away_cell.y * ts + ts * 0.5)
	_check(not spawn_taken.has(away_cell), "[仪器] 远点 %s 确实不是任何人的出生点" % str(away_cell))
	# 六个人**全部**挪过去(含已在 ④⑥ 倒地的 2/5 号):这样"有人离开远点"与"有人被复位"
	# 就是同一件事,断言可以覆盖全体。
	_park(_host, all_roles, away)
	var alive_roles: Array = []
	for r in _host.players:
		if not (_host.players[r] as Node2D).is_downed():
			alive_roles.append(int(r))
	_check(alive_roles == [1, 3, 4, 6],
			"[仪器] ⑤ 开跑前在场的是 1/3/4/6 号(2/5 已在 ④⑥ 倒地;实际 %s)" % str(alive_roles))

	# (a) 无归因(溺水 / 自伤 / K 自杀 → killer 0):2 队的 6 号倒地 → 1 队 +1,但**无人被复位**
	# ★ 用**过期归因**构造这条早退:6 号身上留着"被 1 号(1 队)打过"的 meta,但时间戳超出
	#   `ATTRIB_WINDOW`。为什么不用"压根没有 meta":那条路上 `players.get(0)` 是 null,
	#   **任何**实现都会 return —— 断言恒绿、没有区分度(正是上面那条自检要防的失败模式)。
	#   带 meta 但过期才是真能走到 `killer_role == 0` 早退的构造:少了时效判定 → 1 号被
	#   从远点送回出生点 → 红。
	var p6: Node2D = _host.players[6]
	CombatFeedback.attribute(p6, _host.players[1])
	p6.set_meta("last_damager_time", Time.get_ticks_msec() - TeamHost.ATTRIB_WINDOW - 1000)
	(p6.get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(1, 0)) == 1 and int(_host._scores.get(2, 0)) == 0,
			"★ 无归因 · 2 队的 6 号倒地 → 1 队 +1(实际 %s)" % str(_host._scores))
	var escaped_a := _moved_from(_host, all_roles, away)
	_check(escaped_a == 0, "★ 无归因 · 无人被复位(实际有 %d 人离开了远点)" % escaped_a)

	# (b) 异队击杀:1 号(1 队)打 4 号(2 队)→ 4 号倒地,**1 号被送回本方出生点**,
	#     而同队的 3 号(1 队)一步不动 —— "只复位击杀者本人"的另一半就在这条。
	_host._scores = {}
	var p1: Node2D = _host.players[1]
	CombatFeedback.attribute(_host.players[4], p1)
	(_host.players[4].get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	var home1: Vector2i = _host._round_spawns[1]
	var want1 := Vector2(home1.x * ts + ts * 0.5, home1.y * ts + ts * 0.5)
	_check(p1.global_position.distance_to(want1) < 2.0,
			"★ 异队击杀 · 击杀者(1 号)被送回本方出生点(距目标 %.1fpx)"
			% p1.global_position.distance_to(want1))
	_check(p1.global_position.distance_to(away) > 2.0,
			"★ 异队击杀 · 击杀者确实**离开**了远点(否则上一条可能是「没动」蒙对的)")
	_check(p1.velocity.is_zero_approx(), "★ 异队击杀 · 击杀者速度清零")
	_check((_host.players[3] as Node2D).global_position.distance_to(away) < 2.0,
			"★ 异队击杀 · **同队队友(3 号)一步不动**")

	# (c) 队友误炸:3 号(1 队)炸倒 1 号(1 队)→ 分照样给**对方队**(2 队),但 3 号**不被复位**
	#     3 号此刻在远点:漏了 `same_team` 判定的话它会被送回自己的出生点 → 红。
	_host._scores = {}
	CombatFeedback.attribute(_host.players[1], _host.players[3])
	(_host.players[1].get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(2, 0)) == 1,
			"★ 队友误炸 · 分照样给**对方队**(2 队 +1;实际 %s)" % str(_host._scores))
	_check(int(_host._scores.get(1, 0)) == 0, "★ 队友误炸 · 1 队不涨分(实际 %s)" % str(_host._scores))
	_check((_host.players[3] as Node2D).global_position.distance_to(away) < 2.0,
			"★ 队友误炸 · 击杀者(3 号,与受害者同队)不被复位")

	# (d) 同归于尽:6 号(2 队,已在 (a) 倒地)是击杀者,3 号(1 队)是受害者 → 6 号**不倒第二次**
	#     漏了 `killer.is_downed()` 判定的话,6 号会被从远点送回它的出生点 → 红。
	_host._scores = {}
	CombatFeedback.attribute(_host.players[3], _host.players[6])
	(_host.players[3].get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(2, 0)) == 1,
			"★ 同归于尽 · 分照样给对方队(2 队 +1;实际 %s)" % str(_host._scores))
	_check((_host.players[6] as Node2D).global_position.distance_to(away) < 2.0,
			"★ 同归于尽 · 已倒地的击杀者不被复位(它去走自己的复活流程)")
	_ran_to_end = true


func _finish() -> void:
	if _fails.is_empty() and _ran_to_end:
		print("TEAM HOST: ALL-OK")
		get_tree().quit(0)
	else:
		print("TEAM HOST: FAIL")
		for f in _fails:
			print("  - %s" % f)
		if not _ran_to_end:
			print("  - ★ 探针没跑到末尾")
		get_tree().quit(1)
