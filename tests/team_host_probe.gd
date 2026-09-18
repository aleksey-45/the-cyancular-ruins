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
# ①②③④ 由 Task 4 落(出生散点 / 换边点集 / 宿主接线 / 计分归属的第一条);
# ⑤ 复位、⑥ 9 杀收局、⑦ 换边随 Task 5/6/7 追加到本探针末尾。

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

	# ── ④ 按队计分:role4 倒地 → **1 队** +1(不是 role 层面的对手)──
	_host._round_state = MatchHost.RoundState.PLAYING
	var p4: Node2D = _host.players[4]
	(p4.get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(1, 0)) == 1, "★ 2 队的人倒地 → 1 队 +1(实际 %s)" % str(_host._scores))
	_check(int(_host._scores.get(2, 0)) == 0, "2 队没涨分")
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
