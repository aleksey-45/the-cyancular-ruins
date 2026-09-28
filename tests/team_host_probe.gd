extends Node

# TeamHost:按队出生散点 / 按队计分 / 击杀后**不复位任何人** / 换边。场景模式。
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
# ⑤ 击杀后不复活/不传送任何人由 Task 6 落(brief 正文里这段写作 ⑦/⑩,同一个东西);
#   ★ **2026-09-21 整体反转**:用户要求删掉「把击杀者送回本方出生点」那条规则,本段据此把
#   断言改成反面(击杀者**原地不动**)。详见 ⑤ 段首的说明。
# ⑧ 换边/终局由 Task 7 落(⑧ = 直接调 `_start_next_round`,⑨ = 把状态机**推过** ROUND_OVER
#    —— 后者才验得到"虚分派落在覆写上",见 ⑨ 的说明);
# ⑪ match_sync 应答带 teams(源码级:路由在 server_main 的私有方法里,探针跑不到那条路)由
#   Task 10 落 —— brief 正文里这段写作 ⑨,但 ⑨/⑩ 已被 Task 7/11 占用,故顺延为 ⑪。
#   ★ 同段另有两条:**只在非空时带该键**(源码级)与 **`teams` 不进 `round_state`**(反向:
#   取 `_broadcast_round_state` 的函数体断言不含它)—— 全支最终审查的"合并前必修"两条。
# ⑫ 自杀脱困(K 键)由全支最终审查的修复批落:真起一个 `server_main` 实例(不进树)调
#   `_on_suicide_request`,验闸放行 + 无归因档(对方队 +1 / 无人被复位);⑫b 是
#   `_respawn_player` 清归因 meta 的对等性。编号顺延(⑩/⑪ 已被占用)。
# ⑬ 逐人数据 + ACS/MVP 由 **B 册 Task 10** 落(只做数据面):⑬a 伤害 1:1 / ⑬i 子弹那一路的
#   归因(`_on_bullet_hit`,★ 它不走爆炸/榴弹那两条写端)/ ⑬b 队友误炸不计 `kills`(用户裁定 ②)/
#   ⑬b2 队友的爆炸**不计 dealt**(用户裁定 2026-09-19,走真爆炸路径)/
#   ⑬b3 **敌方**爆炸照常计入 dealt 且**数值对得上**(与 ⑬b2 互为对照 —— 少了它,「恒不记」的坏实现
#   能让 ⑬b2 全绿)/ ⑬c 自伤不记
#   (**专钉归因新鲜度** `ATTRIB_FRESH_MS`)/ ⑬d 击杀分**不看敌方存活人数** /
#   ⑬e **无多杀加成** / ⑬f MVP 与确定性 /
#   ⑬g 载荷**形状与数值**(含**伤害只被计入一次**的增量断言;★ **投递**那一半 2026-09-26 已挪到
#      `tests/stats_delivery_probe` ⑥ —— 这里原先那三条 `contains` 文本断言已证明是假绿)/ ⑬h 离开者的局数口径 /
#   ⑬j **已离开者仍参与 MVP**(用户裁定)。
#   ★ 同段另有一条源码级:**受击接线必须由生产持有** —— 探针调的是 `MatchHost._wire_hit_feedback`,
#     不是自己抄的 `connect`(抄件会让"生产的接线断了"静默通过,同 `_apply_team_layers`)。
# 掉线终局(整队走光才终局 + 走光判胜)归 **Task 8 的独立探针** `tests/team_disconnect_probe.tscn`,
# **不**追加到本文件 —— 别在这里再抄一份(两份真相:改了判据只有一份会红)。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

# 玩家层(层位 2)。生产侧写在 `player.tscn`(碰撞层)与 `MatchHost._init`(`mask |= 2`)里,
# 这里不为它另立常量源,只是给 ⑩ 的断言一个可读名字。
const LAYER_PLAYER := 2

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


# ── ⑤(击杀后无人被移动)的两个小工具 ──
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


# ── ⑬(逐人数据 + ACS/MVP)的小工具 ──
# 读一个人的**原始计数**(缺条目 = 0,与生产 `_stat_entry` 的默认值同口径)。
# ★ 原始条目里**没有** `kscore` 这个键(它是读时推导出来的)⇒ 积分一律走 `_kscore`。
func _stat(host, role: int, key: String) -> int:
	var s: Dictionary = host._stats.get(int(role), {})
	return int(s.get(key, 0))


# 逐人积分 / 场均:**读生产载荷**(推导值),别自己重算公式 —— 重算就是第二份真相。
# ★ 这条读法在"改生产之前"也能跑(`stats_payload` 两个世界都有),故本 Task 的红是**干净的值不匹配**,
#   而不是"方法不存在 ⇒ SCRIPT ERROR + 一个由 null 派生的空读数"。
func _kscore(host, role: int) -> int:
	return int(host.stats_payload()[int(role)]["kscore"])


func _acs(host, role: int) -> float:
	return float(host.stats_payload()[int(role)]["acs"])


# 助攻表读数(表: victim_role -> {attacker_role: 时刻ms})。
# ★★ 走 `host.get("_assist_times")` 而**不是** `host._assist_times`:字段在本 Task 的红阶段
#   还不存在,直接取会抛 `Invalid get index '_assist_times'`(一条 SCRIPT ERROR + 一个由 null
#   派生的空读数,断言里看不出"表里到底有什么");`Object.get()` 对不存在的属性静默返回 null
#   ⇒ 这里能把它归一成"空表",调用方的 `_check` 因而打出一条**带真实表状态**的值不匹配。
# ★★ 但**别把这条读法说成"防假绿"** —— 实测(读数见 `_age_assist` 注释):访问不存在的属性
#   只结束**出错的那个函数**,调用方照常往下跑、后面的断言照跑、`_ran_to_end` 照常置位,
#   受影响的那条 `_check` 因拿到 null/空值而**红** ⇒ verdict 是干净的 FAIL,不是 ALL-OK。
func _assist_table(host, victim_role: int) -> Dictionary:
	var t: Variant = host.get("_assist_times")
	if not (t is Dictionary):
		return {}
	var sub: Variant = (t as Dictionary).get(int(victim_role))
	return sub if sub is Dictionary else {}


# 把表里那一笔的时刻往前挪(等 3s 不现实)。返回 false = 表/条目还不存在。
# ★ 与 `_assist_table` 同款理由:字段不存在时**什么都不做**,由调用方的 `_check` 把它变成
#   一条干净的红。
# ★★ 保留 `Object.get()` 的收益是**可读的诊断**,不是"拦住假绿" —— 实测,一个辅助函数里
#   访问不存在的属性只结束**那个函数**,调用方继续、其后的断言照跑、`_ran_to_end` **照样到达**;
#   受影响的 `_check` 因拿到 null/空值而**失败** ⇒ verdict 是干净的 FAIL。实测读数:
#     SCRIPT ERROR: Invalid access to property or key '_no_such_field_at_all' on a base object of type 'Node'.
#        at: _bad_read (...)
#     TMP check FAILED: A 解引用返回值
#     TMP ran_to_end=true fails=1
#     TMP: FAIL
#   即:不这么写得到的是一条 SCRIPT ERROR 加一个由 null 派生的、看不懂的读数;这么写得到的
#   是一句"表还没落地"的值不匹配。别"简化"成直接取属性。
func _age_assist(host, victim_role: int, attacker_role: int, ago_ms: int) -> bool:
	var t: Variant = host.get("_assist_times")
	if not (t is Dictionary):
		return false
	var outer: Variant = (t as Dictionary).get(int(victim_role))
	if not (outer is Dictionary):
		return false
	(outer as Dictionary)[int(attacker_role)] = Time.get_ticks_msec() - int(ago_ms)
	return true


# 把**除 `keep` 之外**的全部在场玩家挪到远点(⑬m/⑬n/⑬n2 的爆炸半径 100 ⇒ 只打得到爆心那一人)。
# ★ 判据用"遍历 `players` 减掉例外"而**不是**写死 role 列表:⑬h 已经把 role 6 从 `players`
#   摘掉(`team_host.gd:582` 的 `players.erase`),写死列表既会漏掉新 role,又会取到不存在的
#   6 号 —— 后者是 `Invalid get index '6' on Dictionary` ⇒ `_run()` 中断(⑬j 之后的三段
#   全在这个坑上,而探针里既有的 `[2,3,4,5,6]` 写法是**在 ⑬h 之前**跑的,照抄会踩)。
func _park_all_but(host, keep: Array, at: Vector2) -> void:
	for r in host.players:
		var role := int(r)
		if keep.has(role):
			continue
		var p: Node2D = host.players[r]
		if p != null and is_instance_valid(p):
			p.global_position = at


# 真打倒一个人:**走生产的归因写端 + 倒地路径**(与 ⑤ 那一段同一手法),然后推一帧状态机。
# `killer == 0` = 无归因档(先把 meta 清掉 —— 否则上一段留下的归因会让这条退化成"有归因")。
func _down(host, victim: int, killer: int) -> void:
	var v: Node2D = host.players[victim]
	if killer == 0:
		v.remove_meta("last_damager")
		v.remove_meta("last_damager_time")
	else:
		CombatFeedback.attribute(v, host.players[killer])
	(v.get_node("Combat") as Node).force_down()
	host._match_round_tick(0.016)


# 某一队还站着几个(⑬d 的前提读数:加成取到几,就看这个数)。
func _team_alive(host, team: int) -> int:
	var n := 0
	for r in host.players:
		if host.team_of(int(r)) == team and not (host.players[r] as Node2D).is_downed():
			n += 1
	return n


# 把对局推到**干净的一局**:用生产那条换局路径(`_start_next_round`)—— 它清 `_scores` /
# `_down_counted` / `_respawn_pending`,并把六个人满血摆回出生点。
# ★ 它**不清** `_stats`(整场累计,正是本段要的:量的是**增量**)。
# ★ `_rounds_won` 必须先清:⑨b 留了 {2: 2}(已达 `TEAM_ROUNDS_TO_WIN`)→ 不清的话
#   `_start_next_round` 直接进 MATCH_OVER,后面每一段的读数全部作废。
func _next_round_clean(host) -> void:
	host._rounds_won = {}
	host._start_next_round()
	host._round_state = MatchHost.RoundState.PLAYING


# 手摆逐人表(⑬f/⑬g/⑬h 要的是**精确相等**的读数,靠真打摆不出来)。
# rows = [[role, kills, deaths, assists, dealt, taken], …];惩罚三键一律 0(那是计划 2 的面),
# 于是读数完全由前五项 + 局数决定,手算得出(`acs` 走生产 `_acs_of`)。
func _set_stats(host, rows: Array) -> void:
	host._stats = {}
	for row in rows:
		host._stats[int(row[0])] = {
			"kills": int(row[1]), "deaths": int(row[2]), "assists": int(row[3]),
			"dealt": int(row[4]), "taken": int(row[5]),
			"team_damage": 0, "self_damage": 0, "team_kills": 0}


# 该玩家 `Combat` 上 `took_hit` 的接线条数(⑬ 的[仪器]前提:手工摆位路径必须显式补调
# 生产的 `_wire_hit_feedback()`,为 0 的话下面所有伤害断言都测不到东西)。
func _hit_conn_count(p: Node2D) -> int:
	var c: Object = p.get_node("Combat")
	return c.get_signal_connection_list("took_hit").size()


# ⑬b3 的落点:全图扫第一个**不在水里**的格中心。
# ★ 为什么非要干格:水格会把爆炸伤害 ×`explosion_decay`(0.25)⇒ 期望值就得把水因子也乘进去
#   —— 而本条的判据是"数值对得上",带一个环境因子会让它变成"看运气"。扫一格干的,
#   期望值就恰好是 `max_damage`(见 `⑬b3` 里"为什么把受害者摆在爆心"那段)。
# 找不到返回 (-1,-1) → 调用方回落到受害者当前位置 + 断言水因子前提(绝不静默跳过)。
func _find_dry_point() -> Vector2:
	var grid: Array = MazeGenerator.current_grid
	var ts := GameParameters.TILE_SIZE
	var d := SpawnPicker.grid_dims()
	for y in range(1, d.y - 1):
		for x in range(1, maxi(d.x - 1, 2)):
			var pos := Vector2(float(x) * ts + ts * 0.5, float(y) * ts + ts * 0.5)
			if Water.water_mult(pos, grid) >= 1.0:
				return pos
	return Vector2(-1, -1)


# rect 覆盖到的格子里有几个是**实心**(判据走 `TileDefs.is_blocked` —— 全仓"挡路"的单一来源)。
# ★ 右/下两端各内缩 0.001px:格是半开区间,`floori(end / ts)` 会把**正好贴边**的那一列/行
#   也算进来(与 `Unstick.PROBE_INSET` 同一条理由,见 core/sim/unstick.gd)。
func _solid_cells_in(rect: Rect2) -> int:
	var grid: Array = MazeGenerator.current_grid
	var ts := GameParameters.TILE_SIZE
	var n := 0
	for cy in range(floori(rect.position.y / ts), floori((rect.end.y - 0.001) / ts) + 1):
		for cx in range(floori(rect.position.x / ts), floori((rect.end.x - 0.001) / ts) + 1):
			if cy < 0 or cx < 0 or cy >= grid.size() or cx >= (grid[0] as Array).size():
				continue
			if TileDefs.is_blocked(grid[cy][cx]):
				n += 1
	return n


# ⑩ 的净空带:全图扫一条 **5 列 × 3 行全空气** 的格子,且**当前没有任何玩家原点**落在它
# 外扩 2 格的范围内(外扩 2 格 = 128px,足够把 80×107 的身体箱隔在带外)。
# 返回带的左上角格;找不到返回 (-1,-1)(调用方据此 FAIL,绝不静默跳过 —— 静默跳过会让
# "⑩ 通过"变成一句空话)。
func _find_clear_strip() -> Vector2i:
	var grid: Array = MazeGenerator.current_grid
	var d := SpawnPicker.grid_dims()
	var ts := GameParameters.TILE_SIZE
	for y0 in range(1, d.y - 3):
		for x0 in range(1, d.x - 5):
			var ok := true
			for j in range(3):
				for i in range(5):
					if grid[y0 + j][x0 + i] != MapFormat.EMPTY:
						ok = false
						break
				if not ok:
					break
			if not ok:
				continue
			var near := Rect2i(x0 - 2, y0 - 2, 9, 7)
			var intrude := 0
			for r in _host.players:
				var p: Node2D = _host.players[r]
				if p == null or not is_instance_valid(p):
					continue
				var c := Vector2i(floori(p.global_position.x / ts), floori(p.global_position.y / ts))
				if near.has_point(c):
					intrude += 1
			if intrude == 0:
				return Vector2i(x0, y0)
	return Vector2i(-1, -1)


func _run() -> void:
	# ★ 散点几何读的是 `MazeGenerator.current_grid`(静态池的判据),而本探针在**建宿主之前**
	#   就要算散点 —— 必须先像 `TeamHost.start_on` 那样把图选好、把网格载进来,否则
	#   `SpawnPicker.grid_dims()` 越界(空网格)、`spread_cells` 返回空表 → 6 个点全 (-1,-1),
	#   ① 恒红(实际踩到)。同时 `load_grid()` 里含 `TileDefs.load_defs()`,池子的判据才与生产一致。
	MazeGenerator.set_map_file(MAP)
	GameParameters.refresh_map_size()
	WorldBuilder.load_grid()
	# ★★ 固定随机源(在**调散点之前**):`plan_team_spawns` 内部走 `GridPathfinder.spread_cells`,
	#   而它 `shuffle()` 读的是**全局 RNG** —— 不播种的话 ① 那条不变式是**随机红**的:
	#   实现侧的 `SPAWN_MAX_TRIES` 重试把单次违反率从 61.5% 压到 ~0.3%/次,而 0.3% 不是 0 ——
	#   验收探针不该有随机失败模式(红一次就得整轮重跑、还分不清是真坏了还是运气)。
	#   播种同时让**整跑可复现**:任何一条断言红,照这个种子能原地再跑出同一份散点。
	#   ★ 种子值的选取没有含义,只是一个固定的任意数;改它就是换一份散点(scene 的语义不变)。
	seed(20260918)
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
	# ★ 手工摆位路径必须**显式**补调生产那一份配层逻辑(⑩ 的断言验的就是它):
	#   生产上这一步由 `TeamHost._init` 在 `super._init` 之后调,那时 `players` 已满;
	#   本探针 `role_peers` 传空 → `_init` 那一刻 `players` 还是空的 → 不补调的话
	#   `_place` 里那句 `mask |= 2` 就是**唯一**的配层来源,⑩ 验的也就成了探针自己抄的那份。
	_host._apply_team_layers()
	await get_tree().physics_frame
	# ★★ [仪器] 把 `_spawned_once` 补成**生产状态** —— 没有这一步,⑧/⑨ 会退化成弱断言。
	#   生产的 `TeamHost._init` 是先 `plan_team_spawns` 再 `super._init(role_peers 非空)`,
	#   父类会为每个 role 建玩家并**调一次 `_spawn_cell`** → 进第一局时 `_spawned_once` 已是
	#   满表。而本探针 `role_peers` 传空(玩家靠 `_place` 手工摆位)→ 那张表**是空的**,
	#   于是 `_start_next_round` 里那句 `_spawned_once.clear()` 成了**空操作**:
	#   ★ 实测(M1 变异反证):删掉 `clear()` 后 ⑧ 的两条**全部照绿**(第一次换边根本走不到
	#     "动态复活点"分支),红的只有 ⑨ —— 也就是说"⑧ 会抓到它"这个预期**只在第二次换边起**
	#     才成立。补上这一步,⑧ 才真的守住 `clear()`。
	for role in TEAMS:
		_host._spawned_once[role] = true
	# [仪器] 前提验证:填满之后 `_spawn_cell` **真的**改走动态复活点分支。
	#   不验这条的话上面那步可能是个空动作(比如 `_spawn_cell` 哪天不再看 `_spawned_once`),
	#   而 ⑧/⑨ 的"位置落回出生点"断言就恒绿 —— 正是本仓反复在删的那种形状。
	var diverted := 0
	for role in TEAMS:
		if _host._spawn_cell(int(role)) != _host._round_spawns[role]:
			diverted += 1
	_check(diverted >= 5,
			"[仪器] 填满 `_spawned_once` 后 `_spawn_cell` 走动态复活点分支(6 个里 %d 个偏离出生点)"
			% diverted)
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

	# ── ⑤ 击杀后**不**复位任何人(★ 2026-09-21 按用户要求把本段整体**反转**)──
	#
	# ★★ 本条**曾经断言的是反面**:「击杀后只把击杀者送回本方出生点(保留血量,不治疗),
	#    队友不动」+ 三个"不复位"档。那条规则已整体删除(`team_host.gd` 的 `_reset_killer_only`
	#    连同它**唯一的调用点**一起没了)。本段据此**反转**,不是删掉断言、也不是放宽它 ——
	#    反转后的断言照样能红:把那次调用加回去,(b) 立刻报"人又被传送了"(已实测,见交接报告)。
	# ★ 保留下来的形状:(a)(c)(d) 三条的**计分**半句(无归因 / 队友误炸 / 同归于尽 → 分照样
	#   给对方队)与复位规则无关、原样有效;**它们各自的"无人移动"半句现在是同一条主张的三个
	#   实例**(击杀不移动任何人),故 (b) 才是核心 —— 它是唯一"旧规则下真会移动人"的档。
	# ★★ 每条先把在场的人全挪到一个**统一的"远点"**(按构造 ≠ 任何出生点):
	#   否则"没被复位"与"被送回自己的出生点"可能落在同一数值上 —— 那种断言恒绿、没有区分度
	#   (brief 里 (a) 那版 `位置不变 or 已倒地` 就是这种:受害者必然已倒地 → 恒真)。
	_host._round_state = MatchHost.RoundState.PLAYING
	_host._scores = {}
	var ts := GameParameters.TILE_SIZE
	var all_roles: Array = [1, 2, 3, 4, 5, 6]
	# ★ 「每个在场 role 都有出生点」这条**不变量**。它原先是为了钉住 `_reset_killer_only` 里
	#   那条 `spawn.x < 0` 早退**不可达**(而那个分支本身是 `push_error` + return,覆盖它每次都
	#   会刷一行 ERROR —— 与本仓"杂散 ERROR 会淹掉真失败"的纪律冲突,故不去覆盖那个分支)。
	#   ★ 2026-09-21 那个函数已删除,但这条断言**照样有主**:`_round_spawns` 缺项会把
	#     `_spawn_cell` / `_respawn_player` 的 `(-1,-1)` 兜底值喂成 `(-32,-32)`(人凭空消失),
	#     而"每个在场 role 都有出生点"是真会先坏的东西,且它**响**(不是静默)。
	for r in _host.players:
		var sp: Vector2i = _host._round_spawns.get(r, Vector2i(-1, -1))
		_check(sp.x >= 0 and sp.y >= 0,
				"每个在场 role 都有出生点(早退分支的前提;role %d → %s)" % [r, str(sp)])
	# 远点:从 (0,0) 起取第一个**不是任何出生点**的格(避开"远点恰好等于某人出生点"的巧合)
	var spawn_taken := {}
	for r in _host._round_spawns:
		spawn_taken[_host._round_spawns[r]] = true
	var away_cell := Vector2i(0, 0)
	while spawn_taken.has(away_cell):
		away_cell.x += 1
	var away := Vector2(away_cell.x * ts + ts * 0.5, away_cell.y * ts + ts * 0.5)
	# ★ 这里原先是一条 `_check`:`_check(not spawn_taken.has(away_cell), …)` —— 而 `away_cell`
	#   正是上面 `while spawn_taken.has(away_cell)` 退出时的那一格,退出条件**就是**这条断言,
	#   它**永远不可能红**(连 `_round_spawns` 为空都不会红)。那种形状只会把断言计数撑大、
	#   让后来的读者以为这里被覆盖了。它真正的价值是把那个点写进日志 —— 故降级成 print。
	print("  [info] 远点 %s(按构造不是任何人的出生点)" % str(away_cell))
	# 六个人**全部**挪过去(含已在 ④⑥ 倒地的 2/5 号):这样"有人离开远点"与"有人被复位"
	# 就是同一件事,断言可以覆盖全体。
	_park(_host, all_roles, away)
	var alive_roles: Array = []
	for r in _host.players:
		if not (_host.players[r] as Node2D).is_downed():
			alive_roles.append(int(r))
	_check(alive_roles == [1, 3, 4, 6],
			"[仪器] ⑤ 开跑前在场的是 1/3/4/6 号(2/5 已在 ④⑥ 倒地;实际 %s)" % str(alive_roles))

	# (a) 无归因(溺水 / 自伤 / K 自杀 → killer 0):2 队的 6 号倒地 → 1 队 +1(规则 7 不分死因),
	#     且**无人被移动**。
	# ★ 用**过期归因**构造这条早退:6 号身上留着"被 1 号(1 队)打过"的 meta,但时间戳超出
	#   `ATTRIB_WINDOW`。为什么不用"压根没有 meta":那条路上 `players.get(0)` 是 null,
	#   **任何**实现都会 return —— 断言恒绿、没有区分度(正是上面那条自检要防的失败模式)。
	# ★ 这条构造原先还兼着"让 `_reset_killer_only` 走到 `killer_role == 0` 早退"的职责;
	#   复位规则删除后那个职责消失,它剩下的价值是"无归因档的**计分**照旧"这一半
	#   (另一半 —— 无归因的 `kill_event` 射手为 0 —— 在 ⑬ 里)。
	var p6: Node2D = _host.players[6]
	CombatFeedback.attribute(p6, _host.players[1])
	p6.set_meta("last_damager_time", Time.get_ticks_msec() - TeamHost.ATTRIB_WINDOW - 1000)
	(p6.get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(1, 0)) == 1 and int(_host._scores.get(2, 0)) == 0,
			"★ 无归因 · 2 队的 6 号倒地 → 1 队 +1(实际 %s)" % str(_host._scores))
	var escaped_a := _moved_from(_host, all_roles, away)
	_check(escaped_a == 0, "★ 无归因 · 无人被移动(实际有 %d 人离开了远点)" % escaped_a)

	# (b) ★★ **核心**:异队击杀 —— 1 号(1 队)打 4 号(2 队)→ 4 号倒地,**1 号原地不动**。
	#     这正是旧规则里唯一会移动人的那一档(它曾经断言 1 号被送回出生点),故反转后的断言
	#     落在这里:哪天有人把那次复位调用加回来,下面第一条立刻红。
	_host._scores = {}
	var p1: Node2D = _host.players[1]
	# ★ 除了位置,击杀者的**战斗状态也不得被动过** —— 位置断言抓不到"顺手补血/补弹/掉武器"
	#   那类变体:把实现改写成 `_respawn_player(killer_role)` 会满血 + 掉武器(位置照样对得上)。
	#   故把血量、残弹、背包、速度都设成**可辨认的非默认值**再断言原样。
	#   (旧规则下这几条写的是"复位**保留**血量";现在它们是"击杀者**完全不受影响**"的一部分。)
	var low_hp := 30                      # PlayerParams.player_max_hp = 50,30 是非满值
	p1.apply_authoritative_state(low_hp, p1.max_waterproof, false)
	p1.weapons.set_initial_inventory([1, 2])
	p1.weapons.current_weapon().mag_ammo = 3
	p1.velocity = Vector2(123.0, -45.0)   # 非零:旧的复位会把它清成 ZERO
	CombatFeedback.attribute(_host.players[4], p1)
	(_host.players[4].get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	var home1: Vector2i = _host._round_spawns[1]
	var want1 := Vector2(home1.x * ts + ts * 0.5, home1.y * ts + ts * 0.5)
	# ★ 反向对照:远点按构造 ≠ 出生点(开跑前那个 `while spawn_taken.has(away_cell)` 保证),
	#   故"人还在远点"这条**不可能**靠"远点恰好就是 1 号出生点"蒙对。把那个前提变成读数。
	_check(away.distance_to(want1) > 2.0,
			"[仪器] 远点与 1 号出生点确实不同(相距 %.1fpx;相同则下一条恒绿)"
			% away.distance_to(want1))
	_check(p1.global_position.distance_to(away) < 2.0,
			"★★ 异队击杀 · 击杀者(1 号)**原地不动**(距远点 %.1fpx;非 0 = 人又被传送了 ——"
			% p1.global_position.distance_to(away)
			+ " 2026-09-21 已按用户要求删掉「击杀后把击杀者送回出生点」那条规则)")
	_check(p1.hp == low_hp,
			"★ 异队击杀 · 击杀者血量不被改(实际 %d,期望 %d)" % [p1.hp, low_hp])
	_check(p1.weapons.current_weapon() != null and p1.weapons.current_weapon().mag_ammo == 3,
			"★ 异队击杀 · 击杀者不补弹(实际 %s)"
			% str(p1.weapons.current_weapon().mag_ammo if p1.weapons.current_weapon() != null else "空手"))
	_check(p1.weapons.inventory.held.size() == 2,
			"★ 异队击杀 · 击杀者不掉武器(背包仍 2 把,实际 %d)"
			% p1.weapons.inventory.held.size())
	_check(p1.velocity.is_equal_approx(Vector2(123.0, -45.0)),
			"★ 异队击杀 · 击杀者速度不被清零(实际 %s)" % str(p1.velocity))
	_check((_host.players[3] as Node2D).global_position.distance_to(away) < 2.0,
			"★ 异队击杀 · **同队队友(3 号)同样一步不动**")

	# (c) 队友误炸:3 号(1 队)炸倒 1 号(1 队)→ 分照样给**对方队**(2 队)。计分这半句与复位
	#     规则无关、原样有效;3 号不被移动那半句现在是"击杀不移动任何人"的一个实例。
	_host._scores = {}
	CombatFeedback.attribute(_host.players[1], _host.players[3])
	(_host.players[1].get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(2, 0)) == 1,
			"★ 队友误炸 · 分照样给**对方队**(2 队 +1;实际 %s)" % str(_host._scores))
	_check(int(_host._scores.get(1, 0)) == 0, "★ 队友误炸 · 1 队不涨分(实际 %s)" % str(_host._scores))
	_check((_host.players[3] as Node2D).global_position.distance_to(away) < 2.0,
			"★ 队友误炸 · 击杀者(3 号)原地不动")

	# (d) 同归于尽:6 号(2 队,已在 (a) 倒地)是击杀者,3 号(1 队)是受害者 —— 分照样给对方队;
	#     而 6 号(已倒地)一步不动(旧规则这一档靠 `killer.is_downed()` 早退)。
	_host._scores = {}
	CombatFeedback.attribute(_host.players[3], _host.players[6])
	(_host.players[3].get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(2, 0)) == 1,
			"★ 同归于尽 · 分照样给对方队(2 队 +1;实际 %s)" % str(_host._scores))
	_check((_host.players[6] as Node2D).global_position.distance_to(away) < 2.0,
			"★ 同归于尽 · 击杀者原地不动(它去走自己的复活流程)")

	# ── ⑧ 换边:第 2 局开局后,role1 站在原 role4 的出生点上 ──
	var before1: Vector2i = _host._round_spawns[1]
	var before4: Vector2i = _host._round_spawns[4]
	_host._rounds_won = {}     # 清成 0:0,保证这一局是"下一局"而不是终局
	_host._start_next_round()
	_check(_host._round_spawns[1] == before4 and _host._round_spawns[4] == before1,
			"★ 换边:两队出生点整体对调")
	var ts2 := GameParameters.TILE_SIZE
	var swap_want1 := Vector2(before4.x * ts2 + ts2 * 0.5, before4.y * ts2 + ts2 * 0.5)
	_check((_host.players[1] as Node2D).global_position.distance_to(swap_want1) < 2.0,
			"★ 换边后玩家真的站在新的一侧(不是只在表里对调)")

	# ── ⑨ 过渡态已消失:ROUND_OVER → 下一局走的是**本类覆写**,不是基类 ──
	#
	# 背景(Task 5/6 期间登记在案):`_match_round_tick` 的 ROUND_OVER 分支此前虚分派到
	# **基类** `MatchRound._start_next_round` —— 它按 **role** 查 `_rounds_won`,而本模式的
	# `_rounds_won` 键早已是**队号**。队号 {1,2} 与 role 1/2 **字面撞号** ⇒ "1 队赢 2 局"被读成
	# "role 1 赢 2 局"进 MATCH_OVER:**结果碰巧对,但语义不对齐**(且基类那条**不换边**)。
	# 在那之前 3v3 **不要真跑** —— 本段就是"这条撞号已经消失"的守卫。
	#
	# ★ 为什么不直接调 `_start_next_round`(⑧ 那种):那样在**两种实现下都跑得动**
	#   (⑧ 断言的红靠的是"表没对调",但基类那条仍会被算成"函数存在")。要验的是
	#   "**虚分派落在覆写上**",唯一可靠的入口就是**把状态机推过 ROUND_OVER**。
	#
	# 三条证据合起来才是完整的:
	#   ① 源码级 —— 本类自己声明了 `_start_next_round`(声明在基类上就一切照旧);
	#   ② `_side_swap` **一路未被翻** —— 基类那条每局必翻它,这是"走的是本类那条"的直接证据;
	#   ③ 出生点**已对调** + 玩家**已在新一侧** —— 基类那条两样都做不到。
	var tbody := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/team_host.gd")), "_start_next_round")
	var bbody := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/match_round.gd")), "_start_next_round")
	_check(not tbody.is_empty() and not bbody.is_empty(),
			"⑨ **本类自己声明了** `_start_next_round`(覆写),且基类那份也读得到"
			+ "(本类 %d 字符 / 基类 %d 字符;读不到 = 下面的行为断言恒真)"
			% [tbody.length(), bbody.length()])
	# ★ 判据**刻意不再**落在"本类体里出现 `_round_spawns`、基类体里不出现"这种**实现形状**上
	#   (Task 7 评审留的 Minor):那把"把换点集抽成具名 helper"这类**正当重构**变成红灯,
	#   而真正证明"虚分派落在覆写上"的是下面那三条**行为**证据 —— `_side_swap` 一路未被翻、
	#   出生点已对调、玩家真站在新一侧。形状只留一行读数(不进断言账本)。
	print("  [info] ⑨ 函数体读数:本类 %d 字符 / 基类 %d 字符;本类体含 `_round_spawns` = %s"
			% [tbody.length(), bbody.length(), str(tbody.contains("_round_spawns"))])
	var swap_a: Vector2i = _host._round_spawns[1]
	var swap_b: Vector2i = _host._round_spawns[4]
	var side_swap_before: bool = _host._side_swap
	var round_before: int = _host._round_num
	_host._rounds_won = {}
	_host._round_state = MatchHost.RoundState.ROUND_OVER
	_host._round_timer = 0.0
	_host._match_round_tick(0.016)     # ROUND_OVER 到期 → `_start_next_round()`
	_check(int(_host._round_state) == int(MatchHost.RoundState.COUNTDOWN),
			"⑨ ROUND_OVER 到期 → 下一局 COUNTDOWN(实际 state=%d)" % int(_host._round_state))
	_check(_host._round_num == round_before + 1, "⑨ 局号 +1(实际 %d)" % _host._round_num)
	_check(_host._round_spawns[1] == swap_b and _host._round_spawns[4] == swap_a,
			"★ ⑨ 状态机推过 ROUND_OVER 后两队出生点**已对调**(基类那条不换边 → 这里必红)")
	_check(_host._side_swap == side_swap_before,
			"★ ⑨ `_side_swap` 一路**未被翻**(基类那条每局都翻它 —— 这条是「走的是本类那条」的直接证据)")
	var ts3 := GameParameters.TILE_SIZE
	var swap_want2 := Vector2(swap_b.x * ts3 + ts3 * 0.5, swap_b.y * ts3 + ts3 * 0.5)
	_check((_host.players[1] as Node2D).global_position.distance_to(swap_want2) < 2.0,
			"★ ⑨ 推过状态机后玩家**真的站在新一侧**(距目标 %.1fpx)"
			% (_host.players[1] as Node2D).global_position.distance_to(swap_want2))

	# ⑨b 终局路径:`_rounds_won` 由**真实产者** `_round_over(team)` 写下 → MATCH_OVER + 队号
	# ★ 为什么**不**手工塞 `_rounds_won = {2: 2}`:那样"键集 ⊆ {1,2}"就是"我塞的键 ⊆ 我塞的键",
	#   恒真、没有区分度(正是上面刚从 ⑤ 删掉的那种形状)。走真实产者,这条才验得到东西。
	# ★ 也**不**用"基类会被骗"来构造区分度 —— 那恰恰是"碰巧对"那一档(`{2: 2}` 在基类下按
	#   role 2 查也是 2,两边都进 MATCH_OVER)。所以本段钉的是**契约**:
	#   键是队号 / `match_winner()` 返回队号 / MATCH_OVER 不推进局号。
	# ★★ 本段的 ★ 已按 Task 7 评审摘掉(Task 11 顺手):`_round_over(2)` 在**两种实现下都写键 2**,
	#   MATCH_OVER 两条路也都到得了 —— 它们是**契约**断言(队号与 role 今天字面撞号、区分不了),
	#   不是像 ⑨ 那三条一样的**区分性**证据。留着 ★ 会让后来的读者把它们当成后者。
	var round_at_match_over: int = _host._round_num
	_host._rounds_won = {}
	_host._round_over(2)
	_host._round_over(2)
	_check(_host._rounds_won.size() == 1 and int(_host._rounds_won.get(2, 0)) == TeamHost.TEAM_ROUNDS_TO_WIN,
			"★ ⑨b `_round_over` 写下的键是**队号**(2 队 ×%d;实际 %s)"
			% [TeamHost.TEAM_ROUNDS_TO_WIN, str(_host._rounds_won)])
	_host._round_state = MatchHost.RoundState.ROUND_OVER
	_host._round_timer = 0.0
	_host._match_round_tick(0.016)
	_check(int(_host._round_state) == int(MatchHost.RoundState.MATCH_OVER),
			"⑨b 队号键先到 %d 局胜 → MATCH_OVER(契约,不区分队号 vs role)"
			% TeamHost.TEAM_ROUNDS_TO_WIN)
	_check(_host._match_winner() == 2,
			"⑨b `match_winner` 是**队号** 2(契约,不区分队号 vs role)")
	var keys_ok := true
	for k in _host._rounds_won:
		if int(k) != 1 and int(k) != 2:
			keys_ok = false
	_check(keys_ok and _host._rounds_won.size() > 0,
			"⑨b `_rounds_won` 的键集 ⊆ {1,2}(契约,不区分队号 vs role;实际 %s)"
			% str(_host._rounds_won.keys()))
	_check(_host._round_num == round_at_match_over,
			"★ ⑨b MATCH_OVER **不推进局号**(实际 %d,期望 %d)" % [_host._round_num, round_at_match_over])

	# ── ⑩ 队友不互挡:层/掩码**按队**分开(Task 11)──
	# 用户裁定"完全穿透":队友之间既不挡路、也不推挤。
	# ★ 机制**必须**是"分队位"而不是"改掩码":Godot 的碰撞按**节点**配,没有"按对"的开关 ——
	#   全员同在第 2 层时,掩码含 2 就是"与所有玩家碰撞",无法只豁免队友。把 2 队挪到层位 5
	#   (值 16)后,两队掩码**互指对方的位** ⇒ A↔B 挡、A↔A 与 B↔B 穿。
	# ★ 契约(B 册 Task 6 的客户端一半照此实现):
	#   1 队 layer=2 / mask=1|4|16(=21);2 队 layer=16 / mask=1|2|4(=7)。
	var pa: Node2D = _host.players[1]     # 1 队
	var pb: Node2D = _host.players[4]     # 2 队
	_check(pa.collision_layer == LAYER_PLAYER and pb.collision_layer == TeamHost.TEAM_ENEMY_LAYER,
			"⑩ 两队的身体层分开(1 队=%d / 2 队=%d;实际 %d / %d)"
			% [LAYER_PLAYER, TeamHost.TEAM_ENEMY_LAYER, pa.collision_layer, pb.collision_layer])
	_check((pa.collision_mask & LAYER_PLAYER) == 0, "★ ⑩ 1 队掩码**不含**玩家层(否则队友会互挡)")
	_check((pa.collision_mask & TeamHost.TEAM_ENEMY_LAYER) != 0, "⑩ 1 队掩码含敌队层")
	_check((pb.collision_mask & LAYER_PLAYER) != 0, "⑩ 2 队掩码含玩家层")
	_check((pb.collision_mask & TeamHost.TEAM_ENEMY_LAYER) == 0, "★ ⑩ 2 队掩码**不含**敌队层(同上)")
	# ★ 上面五条**替代不了**这一条:`mask = TEAM_ENEMY_LAYER` 这种"整体覆盖"式实现五条全绿,
	#   而它会让该队**穿墙**(丢掉地形位)、也不再被敌人挡 —— 静默,且要玩到才发现。
	_check((pa.collision_mask & 1) != 0 and (pa.collision_mask & 4) != 0
			and (pb.collision_mask & 1) != 0 and (pb.collision_mask & 4) != 0,
			"★ ⑩ 两队掩码都**保留**地形(1)与敌人(4)(抹玩家位时把它们一起丢 = 该队穿墙;"
			+ "实际 1 队 %d / 2 队 %d)" % [pa.collision_mask, pb.collision_mask])

	# ★★ 位对了不等于物理对:再用 `test_move` 验一次**真行为**(它读的是物理空间,不是掩码值)。
	# 三条前提,一条都不能省:
	#   ① 净空带里**没有墙** —— 否则 test_move 因为**地形**返回 true,那就成了"测的是墙不是人"
	#      (故用 [仪器] 断言把这条前提钉住,而不是靠"我挑的格子应该没问题");
	#   ② 六个玩家的物理帧**全关掉** —— 否则 `await physics_frame` 那一帧里他们会下坠/被推挤,
	#      几何就不再由本探针决定(⑩ 是纯几何断言,不需要任何物理仿真);玩家箱 80×107 世界像素
	#      比一格还高,站着时脚底会嵌进地板 25px,那点位移足够让两条断言的边界条件漂移;
	#   ③ `test_move` 的第二参是**相对位移向量**(不是目标位置):`Vector2(ts, 0)` = 试着向右走一格。
	for r in _host.players:
		var fp: Node2D = _host.players[r]
		if fp != null and is_instance_valid(fp):
			fp.set_physics_process(false)
	var ts4 := GameParameters.TILE_SIZE
	var strip_cell := _find_clear_strip()
	_check(strip_cell.x >= 0,
			"⑩ 找到一条 5 列 × 3 行全空气、且远离其他玩家的净空带(实际左上角 %s)" % str(strip_cell))
	if strip_cell.x < 0:
		_ran_to_end = true
		return
	print("  [info] ⑩ 净空带左上角 %s(a 站第 2 列中行,对手/队友站它右边 2 格)" % str(strip_cell))
	var o := Vector2(strip_cell.x * ts4 + ts4 * 1.5, strip_cell.y * ts4 + ts4 * 1.5)
	# 被试者(role1)与陪练(role3,同队)与对手(role4,敌队)。★ role4 原来的位置由
	# `_find_clear_strip` 保证在带外 ≥2 格 —— 下面把队友/对手**在这两个位置间对调**,
	# 于是"两位里没上场的那位"永远在带外,不需要额外找地方停。
	var p3: Node2D = _host.players[3]
	var pb_home: Vector2 = pb.global_position
	# 相 A:朝**队友**(role3,1 队)走一格 → 应当穿过去
	pa.global_position = o
	p3.global_position = o + Vector2(2.0 * ts4, 0.0)
	# ★ 这一帧不只是"让物理空间看到新位置":它同时让上面关掉的物理帧之后的几何**定住** ——
	#   删掉它 test_move 读到的是挪位之前的旧状态,断言就成了随机的(brief 的控制者补充)。
	await get_tree().physics_frame
	# [仪器] 前提:净空带里没有实心格、也没有第三者在场(判据全走 `CollisionAabb.world_rect`
	#   —— 与激光命中/水脚底偏移同一份几何来源,不是"我以为的箱子大小")。
	#   ★ 必须在 `pa` 落到 `o` **之后**算:它先前站在出生点的地板上,那时的箱子当然压着地板。
	var strip := CollisionAabb.world_rect(pa).grow_individual(0.0, 0.0, 2.0 * ts4, 0.0)
	var solids := _solid_cells_in(strip)
	_check(solids == 0,
			"[仪器] ⑩ 净空带里没有实心格(有的话下面两条测的是**地形**;实际 %d 格)" % solids)
	var intruders := 0
	for r in _host.players:
		if int(r) == 1 or int(r) == 3 or int(r) == 4:
			continue
		var other: Node2D = _host.players[r]
		if other != null and is_instance_valid(other) and CollisionAabb.world_rect(other).intersects(strip):
			intruders += 1
	_check(intruders == 0, "[仪器] ⑩ 净空带里没有别的玩家身体(实际 %d 个)" % intruders)
	_check(not pa.test_move(pa.global_transform, Vector2(ts4, 0.0)),
			"★ ⑩ 行为:朝**队友**走一格 —— 不被挡(完全穿透)")
	# 相 B:同一位换成**敌人**(role4,2 队)→ 应当被挡(证明上一条不是"什么都挡不住")
	pb.global_position = o + Vector2(2.0 * ts4, 0.0)
	p3.global_position = pb_home
	await get_tree().physics_frame
	_check(pa.test_move(pa.global_transform, Vector2(ts4, 0.0)),
			"★ ⑩ 行为:朝**敌人**走一格 —— 被挡")

	# ── ⑪ 源码级:match_sync 的应答里必须带 teams,且来自 team_map() ──
	# ★ 为什么只能源码级:`_on_match_sync` 是 server_main(Node2D)的私有方法,要让它真跑一遍得
	#   有真 cmdline + 真 claim + 真 peer(且 `_host` 是 TeamHost)—— 探针照不到那条路。
	# ★ 判据走**去注释视图**(`code_only`):注释里提到这两个串不算数(本仓反复踩过的"注释喂饱断言")。
	# ★ 两条缺一不可:第一条保证键在,第二条保证**来源是宿主的只读取法** —— 就地推导(比如按
	#   role 奇偶分队)同样能满足第一条,而那正是"第二份真相"(客户端与宿主各算一份)。
	# ★ 与 `destroyed`/`ground_weapons` 同款纪律:**只在非空时带该键**(不带队时旧客户端忽略
	#   未知键、新客户端拿到空)。
	var sm := ScanUtil.code_only(ScanUtil.read("res://server/server_main.gd"))
	_check(sm.contains('data["teams"] = teams'), "★ ⑪ match_sync 应答带 teams")
	_check(sm.contains('has_method("team_map")'), "★ ⑪ teams 来自宿主的只读取法(不是就地推导)")
	# ★ 「**只在非空时带该键**」也是契约的一条(与 `destroyed` 同款:不带队时旧客户端忽略
	#   未知键、新客户端拿到空),但只验"键在"照不到它 —— 无条件 `data["teams"] = teams`
	#   同样满足上面那条,却会给 1v1/大乱斗的每一份 match_sync 白搭一个空字典。
	#   ★ 判据串 `if not teams.is_empty():` 在 server_main.gd 里**唯一**(其余 `is_empty()`
	#   读的是 `_role_set` / `_claims` / `ips` / `destroyed`),故它不会靠别的分支蒙对。
	_check(sm.contains("if not teams.is_empty():"),
			"★ ⑪ teams **只在非空时**带该键(无条件赋值照样满足上面那条)")
	# ★★ 反向断言:`teams` 不进 `round_state`。上面三条只验"该来的来了",这条验"不该来的
	#   没来" —— 两条投递路径(自检 B2 那类事故的形状)正是"顺手把队伍表塞进每帧广播"的产物。
	#   ★ 判据取 `_broadcast_round_state` 的**函数体**(不是整个文件):`teams` 这个词在本文件
	#   别处满地都是(`plan_team_spawns(teams)` / `team_map()`),拿整文件判会恒红。
	var rbody := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/team_host.gd")), "_broadcast_round_state")
	_check(not rbody.is_empty(),
			"⑪ 读得到 `TeamHost._broadcast_round_state` 的函数体(读不到 = 下面那条恒真)")
	_check(not rbody.contains("teams"),
			"★ ⑪ `teams` **不进** `round_state`(队伍表只走 match_sync 一条投递路径)")

	# ── ⑫ 自杀脱困(K 键):3v3 也接这条闸,落「无归因」档 ──
	#
	# 为什么钉它:3v3 的 K 键自救此前**被静默丢掉** —— `server_main._on_suicide_request` 首行
	# 是 `if not _royale or _host == null: return`(闸只认大乱斗),于是卡死的玩家在三局两胜里
	# 只能干等对局被别人打完,而且**一个字的日志都没有**。设计 §4.5 的"三态化清单"列了四处、
	# 漏了这第五处;而规则 7 是"不分死因"、§10 也把"自杀"列进 3v3 的死亡成因。
	#
	# ★ 手法:让 `server_main.gd` 的那个函数**真跑一遍** —— 起一个它的实例,手工填
	#   `_team_mode` / `_royale` / `_host` / `_claims` 四个字段后直接调 `_on_suicide_request`。
	#   ★ 实例**不进树**:`_ready` 会去 `NetBus.start_server(7777)` 并拉起大厅(那是真端口,
	#     探针绝不能碰)。本函数体不依赖树,故"不进树"不影响这条判据的有效性。
	#   ★ 这是本探针唯一能照到那条**闸**的角度(`role_peers` 传空建宿主的技术在这里用不上 ——
	#     闸在 `server_main`,不在宿主上);`TeamHost.request_suicide_role` 本身另被
	#     kh_l5_probe 的"禁入基类名单"钉着归属。
	#
	# ★ 四条断言各管一件事,缺一条都留一个洞:
	#   ① 闸放行(改回 `not _royale` → 红)② 真倒地 ③ 对方队 +1、本队不涨 ④ 无人被复位。
	# ★ 变异反证:把 `server_main.gd` 那条闸改回 `if not _royale or _host == null:` → ① 红。
	#   把 `request_suicide_role` 里那段清 meta 的循环删掉 → ④ 红(见下面 meta 的构造说明)。
	_host._round_state = MatchHost.RoundState.PLAYING
	_host._scores = {}
	_host._down_counted = {}
	_host._respawn_pending = {}
	_park(_host, all_roles, away)
	var suicide_role := 3                       # 1 队
	var suicide_team: int = _host.team_of(suicide_role)
	var suicide_enemy: int = _host._enemy_team_of(suicide_role)
	var suicide_peer := 424242                  # 哨兵:不与任何真 peer 撞号
	# ★★ meta 的构造是这条判据的**全部区分度**所在:归因刻意指向一名**敌人**(role 4,2 队)
	#   且时间戳新鲜。少了"自杀先清 meta"的实现会把它读成"4 号杀了 3 号" → 4 号被送回出生点
	#   → ④ 红。指向**队友**或干脆不写 meta 都照不到(前者被 `same_team` 挡、后者恒早退 ——
	#   两种实现都能过,正是本仓反复在删的"恒绿断言")。
	CombatFeedback.attribute(_host.players[suicide_role], _host.players[4])
	_check(not (_host.players[suicide_role] as Node2D).is_downed(),
			"[仪器] ⑫ 自杀前 %d 号是活的(否则「倒地」那条验的是它本来就有的状态)" % suicide_role)
	# ★ 用**无类型**变量接实例:`var srv: Node = …` 会让 `srv._team_mode` 在编译期就报
	#   "Node 上没有该属性"(同 team_table_probe 里 `var _host = null` 的理由)。
	var srv = load("res://server/server_main.gd").new()
	srv._team_mode = true
	srv._royale = false
	srv._host = _host
	srv._claims = {suicide_role: suicide_peer}
	srv._on_suicide_request(suicide_peer)
	_check((_host.players[suicide_role] as Node2D).is_downed(),
			"★ ⑫ 3v3 的 suicide_request **接上了**(闸放行 → force_down();闸只认 _royale 时这条红)")
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(suicide_enemy, 0)) == 1
			and int(_host._scores.get(suicide_team, 0)) == 0,
			"★ ⑫ 自杀落「无归因」档:%d 队 +1、%d 队不涨(规则 7 不分死因;实际 %s)"
			% [suicide_enemy, suicide_team, str(_host._scores)])
	var escaped_suicide := _moved_from(_host, all_roles, away)
	_check(escaped_suicide == 0,
			"★ ⑫ 自杀 · **无人被移动**(实际有 %d 人离开了远点;无归因档不再有专属语义 ——"
			% escaped_suicide
			+ " 2026-09-21 起任何归因下都无人被移动)")

	# ── ⑫b 复活清归因 meta(与 `RoyaleHost._respawn_player` 对等)──
	# `TeamHost._respawn_player` 的 6 行覆写:复活后的环境死亡(溺水等)不再记到复活前最后
	# 射手头上。★ 判据用 `has_meta`,**不**用"复活后再来一次自杀看分给谁" —— `request_suicide_role`
	# 自己就先 `remove_meta` 了 `last_damager`,那条路**无论复活清不清都看不出差别**(换了个形状的
	# 恒绿断言)。★ 原文把这条掩蔽归给 `_reset_killer_only` 的 `is_downed()` 早退;那个函数已随
	# 「击杀者复位」一起删除(2026-09-21),掩蔽成因改成上面那条(它一直成立,只是当时没写)。
	CombatFeedback.attribute(_host.players[1], _host.players[4])
	_check((_host.players[1] as Node2D).has_meta("last_damager"),
			"[仪器] ⑫b 复活前 meta 确实在(否则下面那条恒绿)")
	_host._respawn_player(1)
	_check(not (_host.players[1] as Node2D).has_meta("last_damager")
			and not (_host.players[1] as Node2D).has_meta("last_damager_time"),
			"★ ⑫b 复活时清掉 last_damager / last_damager_time(对齐 RoyaleHost._respawn_player)")

	# ── ⑫c 未知队号不得被静默划进 2 队(`_apply_team_layers` 的穷举分支)──
	# ★ 原先写的是 `if team_of(role) == 1 … else …` —— 于是**队号 0 / 表外 role** 会落进
	#   `else`,被配成 **2 队的身体层**:它与 1 队互挡、与 2 队互穿 = **非对称碰撞**,而且
	#   不报错。今天 `players` 的键都被 `--teams` 覆盖着,走不到那条路;但"走不到"是靠
	#   **上游一个校验**维持的,不是本函数的性质 —— `_apply_team_layers` 是公有的
	#   (手工摆位路径会显式调它,见 `_place` 上方注释),把不变量写进函数本身才对。
	# ★ 预期会打一行 `ERROR: TeamHost: role 99 的队号是 0…`(那是**判据本身**,不是故障)。
	print("  [info] 下面那行 ERROR 是**预期**的(⑫c 故意喂一个表外 role 给 _apply_team_layers)")
	# ★ 必须是 `CollisionObject2D` 的子类(裸 `Node2D` 没有 `collision_layer` ——
	#   实测会当场 "Invalid assignment of property 'collision_layer'")。`_apply_team_layers`
	#   只读这两个属性,`StaticBody2D` 足够,不必为一个假身起一整个 Player。
	var stray := StaticBody2D.new()
	stray.collision_layer = LAYER_PLAYER
	stray.collision_mask = 7          # `super._init` 给玩家的默认(1|2|4)
	_host.add_child(stray)
	_host.players[99] = stray
	_host._apply_team_layers()
	_check(stray.collision_layer == LAYER_PLAYER and (stray.collision_mask & LAYER_PLAYER) != 0,
			"★ ⑫c 表外 role(队号 0)保持 super 的默认配层,不被划进 2 队"
			+ "(划进去 = 与 1 队互挡、与 2 队互穿;**实际 layer %d / mask %d**)"
			% [stray.collision_layer, stray.collision_mask])
	_host.players.erase(99)
	stray.free()

	# ── ⑫d `_begin_match` 帧末复核满员(3v3 满员才开、不降级)──
	# ★ 收齐判据由**最后一个** claim 满足 → 开局延到帧末,而那一帧里 claim 集可能缩小
	#   (有人刚 claim 完就掉线)。不复核的话 **5 个人也能开** —— 一边 3 打 2,整局胜负从
	#   第一秒就是假的,且不报错。
	# ★ 只断言 `_match_started` ——**别**让它跑到 `TeamHost.start_on`(那会重载全局网格)。
	#   故先把 `srv._host` 置空(否则第一条守卫 `_host != null` 会提前返回,这条就恒绿了 ——
	#   实测:不置空时正确实现与**删掉复核**的实现都会从这里返回,断言没有区分度)。
	# ★ 变异反证:把 `_begin_match` 里那三行复核删掉 → 下面这条红。
	srv._host = null
	srv._claims = {1: 11, 2: 12, 3: 13, 4: 14, 5: 15}   # 5/6:过得了"≥2"那道闸,过不了满员
	srv._team_of_role = TEAMS
	srv._begin_match()
	_check(not srv._match_started,
			"★ ⑫d 3v3 帧末复核未满员(5/6)→ **不开局**(`_match_started` 必须仍为 false;"
			+ "让 30s 超时梯去收尾)" + ("—— ★ 它已经开了,变异复现成功" if srv._match_started else ""))
	if srv._host != null:
		(srv._host as Node).free()   # 只可能出现在"复核被删掉"的那次变异跑里
	srv.free()                       # 实例不进树(见 ⑫ 上方:`_ready` 会去 bind 7777)

	# ══ ⑬ 逐人数据 + ACS / MVP(B 册 Task 10;**只做数据面**)══
	#
	# 覆盖 brief 那六条:⑬a 伤害 1:1 / ⑬b 队友误炸不计击杀(用户裁定 ②)/ ⑬c 自伤不记
	# (专钉"归因新鲜度"判据)/ ⑬d 击杀分不看敌方存活人数 / ⑬e 无多杀加成 /
	# ⑬f MVP 与确定性;另加 ⑬g 载荷与口径(含"伤害只被计入一次")、⑬h 离开者的局数口径。
	#
	# ★★ 先把对局整体重置成"第 1 局、六人满血、逐人表清零":不重置的话上面各段的残余
	#   (`_rounds_won = {2: 2}`、若干人倒地、`_stats` 里的旧伤害)会让读数无法手算 ——
	#   而**手算不出来的断言就是恒绿断言**。
	_host._round_state = MatchHost.RoundState.PLAYING
	_host._rounds_won = {}
	_host._round_num = 1
	_host._scores = {}
	_host._stats = {}
	_host._left = {}
	_host._left_round = {}
	for st_r in _host.players:
		_host._respawn_player(int(st_r))
	# ★ 受击接线走**生产那一份**:本探针 `role_peers` 传空 → `_ready` 那一刻 `players` 还是
	#   空的 → 不补调就一条线都没有。自己抄一句 `connect(...)` 的话验的是抄件(生产的接线
	#   哪天断了照样绿)—— 与 `_place` 里那句 `_apply_team_layers()` 同一条纪律。
	_host._wire_hit_feedback()
	_check(_hit_conn_count(_host.players[1]) == 1,
			"[仪器] ⑬ 受击信号已按生产接线接上(实际 %d 条;为 0 则下面所有伤害断言都测不到东西)"
			% _hit_conn_count(_host.players[1]))

	# ── ⑬a 伤害 1:1 记到**攻击者**的 dealt ──
	var st_atk := 1
	var st_vic := 4
	var st_dmg0 := _stat(_host, st_atk, "dealt")
	CombatFeedback.attribute(_host.players[st_vic], _host.players[st_atk])
	(_host.players[st_vic] as Node2D).take_hit(Vector2.ZERO, 7)
	_check(_stat(_host, st_atk, "dealt") - st_dmg0 == 7,
			"★ ⑬a 一次已知伤害(7)的命中 → 攻击者 dealt 恰好 +7(实际 +%d)"
			% (_stat(_host, st_atk, "dealt") - st_dmg0))
	_check(_stat(_host, st_vic, "dealt") == 0,
			"★ ⑬a 受害者的 dealt 不涨(伤害记给攻击者,不是受伤者)")

	# ── ⑬i 子弹那一路的归因(★ 它**不走**爆炸/榴弹那两条写端)──
	# 为什么要单独一条:基础实现对**玩家**的子弹直击**不写归因**(只有 `RoyaleHost` 覆写补了),
	# `TeamHost` 原先没有那份覆写 ⇒ 枪杀既不进逐人 dealt、也不进击杀归属(两处都静默:
	# ACS 漏掉最主要的伤害来源,且 `kill_event` 的射手恒 0)。
	# ★ 判据走**生产的裁决入口** `_adjudicate_bullets`(不是直接调 `_on_bullet_hit`):
	#   把子弹贴到受害者身上 → 一次裁决 → 伤害与归因同时落定,走的是服务器真实那一遍。
	var st_bshooter := 3          # 1 队
	var st_bvictim := 4           # 2 队
	var st_bdmg0 := _stat(_host, st_bshooter, "dealt")
	var st_hp0: int = int(_host.players[st_bvictim].hp)
	# ★ 字段一律走 `set()`:子弹的 `shooter`/`hit_damage` 是**脚本**变量,静态类型上看不到
	#   (与 `_place` 上方那句 `var srv: Node = …` 同一个坑)。
	var st_b: Node = preload("res://scenes/weapons/bullet.tscn").instantiate()
	st_b.set("shooter", _host.players[st_bshooter])
	st_b.set("hit_damage", 11)
	st_b.set("velocity_vec", Vector2.ZERO)
	st_b.set("max_range", 1000.0)
	_host.add_child(st_b)
	st_b.set_physics_process(false)   # 只借它当"一次子弹命中",不让它自己飞/撞墙
	(st_b as Node2D).global_position = (_host.players[st_bvictim] as Node2D).global_position
	_host._adjudicate_bullets()
	_check(_stat(_host, st_bshooter, "dealt") - st_bdmg0 == 11,
			"★ ⑬i 子弹直击:伤害记到**射手** dealt(实际 +%d,期望 +11)"
			% (_stat(_host, st_bshooter, "dealt") - st_bdmg0))
	_check(int(_host.players[st_bvictim].hp) == st_hp0 - 11,
			"★ ⑬i [仪器] 子弹真的打中了(受害者 hp %d → %d,期望 -11)"
			% [st_hp0, int(_host.players[st_bvictim].hp)])
	_check(_host._attributed_killer(_host.players[st_bvictim]) == st_bshooter,
			"★ ⑬i 子弹命中也写了**击杀归因**(`kill_event` 的射手与逐人 `kills` 都读它;"
			+ "少了 `_on_bullet_hit` 这一层,两者在枪杀这条路上都是 0)")

	# ── ⑬b 反向断言:队友误炸 → 受害者 deaths +1,但**谁都不涨 kills**(用户裁定 ②)──
	var st_k3 := _stat(_host, 3, "kills")
	var st_k1 := _stat(_host, 1, "kills")
	var st_d1 := _stat(_host, 1, "deaths")
	_down(_host, 1, 3)          # 3 号(1 队)炸倒 1 号(1 队)
	_check(_stat(_host, 1, "deaths") == st_d1 + 1, "★ ⑬b 队友误炸:受害者 deaths 照计(+1)")
	_check(_stat(_host, 3, "kills") == st_k3,
			"★ ⑬b 队友误炸**不计入击杀者 kills**(实际 %d,期望 %d;去掉 same_team 判定这里就红)"
			% [_stat(_host, 3, "kills"), st_k3])
	_check(_stat(_host, 1, "kills") == st_k1, "★ ⑬b 也不计给受害者自己")

	# ── ⑬b2 队友伤害**不计入 dealt**(用户裁定 2026-09-19,与"只算异队击杀"同口径)──
	# ★ 走**真爆炸**(`Explosion.apply_aoe`,生产路径),不是手写归因:子弹本来就穿队友,
	#   唯一打得到队友的就是爆炸 —— "朝队友扔雷刷 ACS"正是这条规则要堵的口子。
	# 布景:`apply_aoe` 按 `player` 组遍历、半径 100 —— 故把受害者(1 号)单独放一处,
	#   其余五个人(**含扔雷的 3 号**)摆到 600px 外,于是它只打得到 1 号一个。
	_host._respawn_player(1)     # ⑬b 把 1 号打倒了,先复活(顺带清归因 meta)
	var st_e_dmg3 := _stat(_host, 3, "dealt")
	var st_e_k3 := _stat(_host, 3, "kills")
	var st_e_d1 := _stat(_host, 1, "deaths")
	var st_e_hp1: int = int(_host.players[1].hp)
	(_host.players[1] as Node2D).global_position = Vector2(320.0, 320.0)
	for st_e_r in [2, 3, 4, 5, 6]:
		(_host.players[st_e_r] as Node2D).global_position = Vector2(920.0, 320.0)
	Explosion.apply_aoe((_host.players[1] as Node2D).global_position, 100.0, 60, 400.0,
			_host.players[3])
	_check(int(_host.players[1].hp) < st_e_hp1,
			"★ ⑬b2 [仪器] 队友的爆炸**真的打中了**(hp %d → %d;没打中的话下面那条恒绿)"
			% [st_e_hp1, int(_host.players[1].hp)])
	_check(_stat(_host, 3, "dealt") == st_e_dmg3,
			("★ ⑬b2 队友的爆炸**不计入 dealt**(3 号 dealt 实际 %d,期望 %d;去掉异队过滤就是"
			+ "「朝队友扔雷刷 ACS」那个口子)") % [_stat(_host, 3, "dealt"), st_e_dmg3])
	_host._match_round_tick(0.016)      # 60 伤 > 满血 50 → 必然打死,顺带走一遍倒地边沿
	_check(_stat(_host, 1, "deaths") == st_e_d1 + 1,
			"★ ⑬b2 队友的爆炸**照计 deaths**(实际 %d,期望 %d)"
			% [_stat(_host, 1, "deaths"), st_e_d1 + 1])
	_check(_stat(_host, 3, "kills") == st_e_k3,
			"★ ⑬b2 队友的爆炸**不计入 kills**(实际 %d,期望 %d)"
			% [_stat(_host, 3, "kills"), st_e_k3])

	# ── ⑬b3 敌方爆炸**照常计入 dealt 且数值对得上**(裁定 ① 的**正向对照**)──
	# ★★ 为什么必须有这一条:⑬b2 是**纯负向**断言("队友的爆炸 ⇒ dealt 不变")—— 一个
	#   "什么都记不上分"的坏实现会让它**全绿**(本册一路在清的那种"看起来在测、其实恒真")。
	#   两条合起来才是"按异队过滤"的完整证据:负向管"队友不算",正向管"**敌人照算**"。
	#   (变异 H 就是这一对的反证:把累计整个拿掉 ⇒ ⑬b2 仍绿、⑬b3 红。)
	# 布景与 ⑬b2 **逐字同款**,只把受害者换成**敌方**:扔雷者 1 号(1 队)、受害者 4 号(2 队)。
	# ★ 受害者摆在**爆心**(d == 0)是刻意的:d < 内圈(`radius × 0.4`)⇒ `_falloff` 返回满值、
	#   `cover_multiplier` **免疫遮挡** ⇒ 期望值恰好是 `max_damage`,与衰减曲线/墙/视线**全都无关**
	#   (断言的值由布景确定,不靠运气)。唯一还要控的环境因子是水 —— 故用 `_find_dry_point()`。
	var st_f_victim := 4        # 2 队(与扔雷者异队)
	var st_f_thrower := 1       # 1 队
	var st_f_max := 30          # 爆心满伤 = 期望的 dealt 增量
	_host._respawn_player(st_f_victim)     # ⑬i 打过它(32 血),先满血复活(顺带清归因)
	var st_f_dmg0 := _stat(_host, st_f_thrower, "dealt")
	var st_f_hp0: int = int(_host.players[st_f_victim].hp)
	var st_f_pt := _find_dry_point()
	if st_f_pt.x < 0:
		st_f_pt = (_host.players[st_f_victim] as Node2D).global_position
	_check(Water.water_mult(st_f_pt, MazeGenerator.current_grid) >= 1.0,
			"★ ⑬b3 [仪器] 落点是**干格**(水格会把伤害 ×0.25,期望值就得带上水因子;实际落点 %s)"
			% str(st_f_pt))
	(_host.players[st_f_victim] as Node2D).global_position = st_f_pt
	for st_f_r in [1, 2, 3, 5, 6]:
		(_host.players[st_f_r] as Node2D).global_position = st_f_pt + Vector2(600.0, 0.0)
	Explosion.apply_aoe(st_f_pt, 100.0, st_f_max, 400.0, _host.players[st_f_thrower])
	_check(int(_host.players[st_f_victim].hp) == st_f_hp0 - st_f_max,
			"★ ⑬b3 [仪器] 敌方的爆炸**真的打中了**(hp %d → %d,期望 -%d;没打中的话下面那条恒绿)"
			% [st_f_hp0, int(_host.players[st_f_victim].hp), st_f_max])
	_check(_stat(_host, st_f_thrower, "dealt") - st_f_dmg0 == st_f_max,
			("★ ⑬b3 敌方爆炸**照常计入 dealt 且数值对得上**(实际 +%d,期望 +%d;"
			+ "与 ⑬b2 互为对照 —— 少了正向这条,「恒不记」的坏实现能让 ⑬b2 全绿)")
			% [_stat(_host, st_f_thrower, "dealt") - st_f_dmg0, st_f_max])

	# ── ⑬c 自伤不记给任何人(★ 这条专钉"归因新鲜度"判据)──
	# 构造:1 号身上留着"被 4 号(2 队)打过"的归因,时间戳**往前挪 200ms** —— 仍在击杀窗口
	# (`ATTRIB_WINDOW` = 3s)之内,但已超出新鲜阈值(`ATTRIB_FRESH_MS`)。
	# ★ 这正是真实自伤的形状:写端 `CombatFeedback.attribute(p, p)` 因 `attacker == victim` 被
	#   **静默跳过**,meta 停在**上一名敌人**身上(真对局里那一下通常发生在数百 ms~数秒前)。
	# ★ 200ms 是保守下界:榴弹引信 0.4s、开火间隔也是几百 ms —— 任何**合理**的新鲜阈值都必须
	#   拒绝 200ms 前的归因。**去掉那条判据**(改用 3s 窗口),这里立刻红。
	_host._respawn_player(1)     # ⑬b 把 1 号打倒了,先复活(顺带清掉归因 meta)
	var st_d4 := _stat(_host, 4, "dealt")
	var st_d1b := _stat(_host, 1, "dealt")
	CombatFeedback.attribute(_host.players[1], _host.players[4])
	_host.players[1].set_meta("last_damager_time", Time.get_ticks_msec() - 200)
	CombatFeedback.attribute(_host.players[1], _host.players[1])   # 自伤:写端静默跳过
	var st_age := Time.get_ticks_msec() - int(_host.players[1].get_meta("last_damager_time"))
	_check(st_age > TeamHost.ATTRIB_FRESH_MS and st_age < TeamHost.ATTRIB_WINDOW,
			"[仪器] ⑬c 归因年龄 %dms 落在(新鲜阈值 %d, 击杀窗口 %d)**之间** —— 本条的区分度就靠它"
			% [st_age, TeamHost.ATTRIB_FRESH_MS, TeamHost.ATTRIB_WINDOW])
	(_host.players[1] as Node2D).take_hit(Vector2.ZERO, 9)
	_check(_stat(_host, 4, "dealt") == st_d4,
			"★ ⑬c 自伤**不记给上一名敌人**(4 号 dealt 实际 %d,期望 %d;去掉新鲜阈值这里就红)"
			% [_stat(_host, 4, "dealt"), st_d4])
	_check(_stat(_host, 1, "dealt") == st_d1b, "★ ⑬c 自伤也不记给自己")

	# ── ⑬d 击杀分不再依赖敌方存活人数(旧 `kill_bonus_score` 那张表已删)──
	# ★ 旧口径按"倒下瞬间的敌方存活人数"加权(70/90/110),在**局内复活**的规则下语义反转
	#   (spec §1.3:败方每个击杀更值钱)。新公式里一个击杀恒为 `ScoreRules.KILL_SCORE`。
	# ★ 本段的期望值写**字面量**、不从生产函数取 —— 两张一起才既钉住"权重是多少上下文无关"、
	#   又钉住"生产真的走了这条"。
	var st_want_kill := 100
	# (d1) 敌方 3 人全在时击杀 → +100
	_next_round_clean(_host)
	_check(_team_alive(_host, 2) == 3,
			"[仪器] ⑬d 阶段①:2 队 3 人全在(实际 %d)" % _team_alive(_host, 2))
	var st_ks1 := _kscore(_host, 1)
	_down(_host, 4, 1)
	var st_gain1 := _kscore(_host, 1) - st_ks1
	_check(st_gain1 == st_want_kill,
			"★ ⑬d 敌方 3 人全在时击杀 → kscore +%d(实际 +%d)" % [st_want_kill, st_gain1])
	# (d2) 敌方只剩 1 人(= 受害者本人)时击杀 → **同样** +100
	_next_round_clean(_host)
	_down(_host, 5, 0)          # 无归因:不计任何人的击杀(deaths 照计)
	_down(_host, 6, 0)
	_check(_team_alive(_host, 2) == 1,
			"[仪器] ⑬d 阶段②:2 队只剩 1 人(实际 %d)" % _team_alive(_host, 2))
	var st_ks3 := _kscore(_host, 3)
	_down(_host, 4, 3)
	var st_gain3 := _kscore(_host, 3) - st_ks3
	_check(st_gain3 == st_want_kill,
			("★ ⑬d 敌方只剩 1 人时击杀 → **同为 +%d**(实际 +%d)—— 两档增量必须**相等**;"
			+ "按存活人数加权的旧实现给出 110 与 70") % [st_want_kill, st_gain3])
	# (d3) 源码级负向断言:旧公式那一族在生产目录里**零命中**(删干净了,不是"还在但没人调")
	var st_old_needles := ["kill_bonus" + "_score", "_enemy_alive" + "_including_victim",
			"MULTI_KILL" + "_BONUS"]
	for st_nd in st_old_needles:
		var st_hits: Array[String] = []
		for st_f in ScanUtil.collect(["res://server", "res://core"]):
			if ScanUtil.code_only(ScanUtil.read(st_f)).contains(st_nd):
				st_hits.append(st_f)
		_check(st_hits.is_empty(),
				"★ ⑬d 旧公式残留:%s 命中 %s(新公式没有多杀加成、也不看敌方存活人数)"
				% [st_nd, ", ".join(st_hits)])

	# ── ⑬e 不再有多杀加成:同一局内第 2 杀的增量与第 1 杀**相同**──
	# ★ 2026-09-25:旧的「同一局内第 2、3… 个击杀各 +50」已随加权公式一起删除
	#   (`MULTI_KILL_BONUS` / `_round_kills`)。本段留着是因为"加成被悄悄加回来"**不会有别处变红**。
	_next_round_clean(_host)
	var st_m0 := _kscore(_host, 1)
	_down(_host, 4, 1)          # 第 1 杀
	var st_m1 := _kscore(_host, 1) - st_m0
	_down(_host, 5, 1)          # 第 2 杀(旧口径:90 + 50 多杀加成 = 140)
	var st_m2 := _kscore(_host, 1) - st_m0 - st_m1
	_check(st_m1 == 100, "★ ⑬e 第 1 杀 = 100(实际 +%d)" % st_m1)
	_check(st_m2 == 100,
			"★ ⑬e 同一局内第 2 杀**同为 100**(实际 +%d;旧实现是 140)" % st_m2)

	# ── ⑬f MVP 与确定性 ──
	# 读法:`_round_num = 1` ⇒ 手算 `kscore = kills×100 + dealt/5 − deaths×50`(协助与惩罚为 0),
	# `acs` 就是它 —— 每一档的期望值都手算得出(**手算不出来的断言就是恒绿断言**)。
	# ★ acs 读**生产载荷**(`_acs`),kills/deaths 读同一份载荷;不自己重算公式(第二份真相)。
	_next_round_clean(_host)
	_host._round_num = 1
	var st_pay := {}
	# (f1) 分差 → 指向 ACS 高者
	_set_stats(_host, [[1, 0, 0, 0, 300, 0], [3, 0, 0, 0, 100, 0]])
	_check(_host.mvp_role() == 1, "★ ⑬f 分差:MVP = ACS 最高者(1 号,60 vs 20)")
	# (f2) 完全并列 → **role 号升序**
	_set_stats(_host, [[3, 0, 0, 0, 300, 0], [5, 0, 0, 0, 300, 0]])
	_check(_acs(_host, 3) == _acs(_host, 5),
			"[仪器] ⑬f 前提:3 号与 5 号 ACS 确实**并列**(实际 %f vs %f)—— 不并列的话下面验的不是并列规则"
			% [_acs(_host, 3), _acs(_host, 5)])
	_check(_host.mvp_role() == 3, "★ ⑬f 完全并列 → **role 号升序**(3 号,不是 5 号)")
	# (f3) ACS 并列 → 击杀多者
	# ★ 新公式下"ACS 并列"要**手工配平**:kills 2 vs 5 差 `3×100 = 300` 分 ⇒ 伤害项补 300 分
	#   ⇒ **dealt 差 1500**(1500 vs 0)。两边 kscore 都是 500。
	#   ★ 旧夹具的 `dealt 300/300` 只在**旧**公式下"并列"(两边都取不到 dealt),新公式下
	#   是 `260 vs 560` —— 那样这一档自己的 `[仪器]` 前提会红。
	_set_stats(_host, [[3, 2, 0, 0, 1500, 0], [5, 5, 0, 0, 0, 0]])
	st_pay = _host.stats_payload()
	_check(_acs(_host, 3) == _acs(_host, 5),
			"[仪器] ⑬f 前提(f3):两人 ACS 并列(实际 %f vs %f)"
			% [_acs(_host, 3), _acs(_host, 5)])
	_check(_host.mvp_role() == 5, "★ ⑬f ACS 并列 → 击杀多者(5 号 5 杀 > 3 号 2 杀)")
	# (f4) ACS 与击杀都并列 → 阵亡少者
	# ★ 配平:kills 同为 2、deaths 5 vs 1 差 `4×50 = 200` 分 ⇒ 伤害项补 200 分 ⇒
	#   **dealt 差 1000**(1300 vs 300)。两边 kscore 都是 210 ⇒ 并列成立、阵亡才有得比。
	_set_stats(_host, [[3, 2, 5, 0, 1300, 0], [5, 2, 1, 0, 300, 0]])
	st_pay = _host.stats_payload()
	_check(_acs(_host, 3) == _acs(_host, 5)
			and int(st_pay[3]["kills"]) == int(st_pay[5]["kills"]),
			"[仪器] ⑬f 前提(f4):两人 ACS 与 kills 都并列(实际 %f/%d vs %f/%d)"
			% [_acs(_host, 3), int(st_pay[3]["kills"]),
				_acs(_host, 5), int(st_pay[5]["kills"])])
	_check(_host.mvp_role() == 5, "★ ⑬f ACS 与击杀都并列 → 阵亡少者(5 号 1 死 < 3 号 5 死)")
	# (f5) **全并列 + 反序插入** → 仍必须是 role 号升序(3 号)。
	# ★ 为什么这一档的并列必须是"**全**"的(ACS/kills/deaths 全同):上面 f2~f4 每一档都留着
	#   一个**严格更优**的候选,于是"不排序、按遍历顺序取严格更优"的实现会给出**同一个**答案
	#   ⇒ 那三档照不到"按插入顺序"这一类。全并列时答案只能来自**遍历顺序**。
	# ★★ 改法说明(2026-09-20 评审):旧版这一档是 `[[5,2,1,300],[3,2,5,300]]`(ACS 并列、
	#   **阵亡数不同**)—— 那一档里 5 号**真的更优**,反序插入后快照式实现照样给 5 ⇒ 它其实
	#   是个空断言。全并列 + 反序才把"顺序"变成唯一变量:按 `_stats` **插入顺序**遍历的实现
	#   (生产中即"首次记分的先后")会先遇到 5 号并锁住它,正确实现(`roles.sort()` + 严格更优)
	#   给 3 号。**变异反证**:把 `mvp_role` 的候选集换成 `_stats.keys()`(不排序)—— 本档红。
	# ★ 如实登记的边界:换 `_roster()` 但不 sort 的实现**照不到** —— 本探针按 role 升序摆人,
	#   故 roster 的插入序恰好也是升序,两种写法在这一档上同答案。要照到它得让 players 的
	#   插入序非升序,那会动到 ⑧/⑨ 依赖的摆位,不在本次范围。
	_set_stats(_host, [[5, 2, 1, 0, 300, 0], [3, 2, 1, 0, 300, 0]])   # 全同,插入顺序颠倒
	st_pay = _host.stats_payload()
	_check(_acs(_host, 3) == _acs(_host, 5)
			and int(st_pay[3]["kills"]) == int(st_pay[5]["kills"])
			and int(st_pay[3]["deaths"]) == int(st_pay[5]["deaths"]),
			("[仪器] ⑬f 前提(f5):3 号与 5 号 ACS/kills/deaths **全并列**(实际 %f/%d/%d vs %f/%d/%d)"
			+ " —— 不全并列的话本档退化成空断言,验的不是「顺序」")
			% [_acs(_host, 3), int(st_pay[3]["kills"]), int(st_pay[3]["deaths"]),
				_acs(_host, 5), int(st_pay[5]["kills"]), int(st_pay[5]["deaths"])])
	_check(_host.mvp_role() == 3,
			("★ ⑬f 全并列且**反序插入** → 仍取 role 升序(3 号,不是 5 号);"
			+ "按 `_stats` 插入顺序遍历的实现会给出 5 号"))
	_check(_host.mvp_role() == _host.mvp_role() and _host.mvp_role() == 3,
			"★ ⑬f 同一状态连续三次调用给出同一个 MVP(确定性)")

	# ── ⑬g 载荷与口径 ──
	_set_stats(_host, [[1, 3, 1, 0, 300, 0]])
	_host._round_num = 1
	var st_pay2: Dictionary = _host.stats_payload()
	var st_shape_bad: Array[String] = []
	# ★★ 顺序是 `dealt` **在 `deaths` 之前** —— 别"顺手纠正"回去:
	#   Godot 的 `Array.sort()` 对 String 走**逐码点**比较(`Variant::operator<` →
	#   `String::operator<` → `str_compare`),而不是按字母表直觉 —— `dealt` 与 `deaths`
	#   第 4 个字符是 `l`(0x6C) vs `t`(0x74) ⇒ `dealt < deaths`。`String.to_lower()` 也好、
	#   "字典序看着像错"也好,都不影响这条;写成 `[…, deaths, dealt, …]` 会让**生产改对了
	#   形状断言照样红**,而错误的修法(放宽成"包含这七个键就行")会把"载荷字段集"这条
	#   真契约拆掉 —— 所以这里必须是**逐码点升序**。
	var st_want_keys := ["acs", "assists", "dealt", "deaths", "kills", "kscore", "taken"]
	for st_k in _host.players:
		var st_row: Dictionary = st_pay2.get(int(st_k), {})
		if st_row.is_empty():
			st_shape_bad.append("role %d 缺行" % int(st_k))
			continue
		var st_keys: Array = st_row.keys()
		st_keys.sort()
		if st_keys != st_want_keys:
			st_shape_bad.append("role %d 的键 %s" % [int(st_k), str(st_keys)])
	_check(st_shape_bad.is_empty(),
			"★ ⑬g 载荷形状:在场者**人人一行**、键恰好七个(问题:%s)" % str(st_shape_bad))
	# 手算:kscore = 3 kills×100 + 300 dealt/5 − 1 death×50 = 300 + 60 − 50 = 310;acs = 310/1
	_check(absf(float(st_pay2[1]["acs"]) - 310.0) < 0.0001,
			("★ ⑬g acs = kscore / 局数 = (3×100 + 300/5 − 1×50)/1 = 310(实际 %f)"
			+ ";★ 反证:把 ScoreRules 的死亡项删掉这里会变成 360)")
			% float(st_pay2[1]["acs"]))
	_check(int(st_pay2[1]["kills"]) == 3 and int(st_pay2[1]["deaths"]) == 1
			and int(st_pay2[1]["dealt"]) == 300,
			"★ ⑬g kills/deaths/dealt 原样带出(实际 %d/%d/%d)"
			% [int(st_pay2[1]["kills"]), int(st_pay2[1]["deaths"]), int(st_pay2[1]["dealt"])])
	# ★★ 伤害**只被计入一次**(spec §1.4):把 `_acs_of` 写成 `acs(kscore + dealt, 局数)` 是
	#   **不报错**的双计 —— 所有排名一起静默偏移(本计划点名的头号风险)。
	#   上面那条单点读数(310)也照得到它,但那是"数值对不对";本条的判据是**增量** ——
	#   构造"只把伤害翻倍、其余全同"的两个状态,断言 ACS 增量**恰好**是
	#   `100 ÷ DAMAGE_PER_POINT ÷ 局数`(= 10 × 2 局… 这里 1 局 ⇒ 20),而不是它再加上那 100 点伤害。
	#   ★ 双计实现给出 6 倍增量(120 vs 20),当场红。
	_set_stats(_host, [[1, 0, 0, 0, 100, 0]])
	var st_dc0 := _acs(_host, 1)
	_set_stats(_host, [[1, 0, 0, 0, 200, 0]])
	var st_dc1 := _acs(_host, 1)
	var st_dc_want := 100.0 / float(ScoreRules.DAMAGE_PER_POINT) / 1.0
	_check(absf((st_dc1 - st_dc0) - st_dc_want) < 0.0001,
			("★ ⑬g 伤害**只被计入一次**:dealt 100 → 200(其余全同)⇒ ACS 增量恰好 %f,实得 %f"
			+ "(差得更大就是调用方双计:`acs(kscore + dealt, …)` 给出 6 倍增量)")
			% [st_dc_want, st_dc1 - st_dc0])
	# ★★ 这里**原先还有三条**文本共现断言(`st_rbody.contains('data["stats"]')` /
	#   `contains('data["mvp"]')` / `contains("if not table.is_empty():")`)—— **2026-09-26
	#   终审后整体删除**,理由是它们**已证明是假绿**:把 `TeamHost._broadcast_round_state` 的
	#   `_rpc_all("round_state", [data])` 提到挂载 `stats`/`mvp` **之前**(真要发出去的字典里
	#   一个键都不带 ⇒ 3v3 结算页两节皆空、没有 MVP 星)时,那三条**照样全绿** —— 实测
	#   `TEAM HOST: ALL-OK`(175 ok)/`STATS DELIVERY: ALL-OK`(34 ok)/`KH HUD PROBE: ALL-OK`。
	#   ★ 它们问的"次序无关的文本在不在"**不是**投递承诺(承诺是"发出去的那份里有这个键"),
	#     故一律改到**行为面**:`tests/stats_delivery_probe.tscn` 的 **⑥**(子类覆写 `_rpc_all`、
	#     在**调用时刻** `duplicate(true)` 截获载荷,与 1v1/大乱斗那两半同款)。
	#   ★ 本段保留的是它真正有牙的那一半:**载荷形状与数值**(`stats_payload()` 的键集、
	#     kscore/acs 的手算读数、"伤害只被计入一次"的增量断言)。★ 别再按"源码里有没有那句话"
	#     给投递加断言 —— 要加就加到 `stats_delivery_probe` ⑥。
	# 接线归属:探针那句 `_wire_hit_feedback()` 调的必须是**生产那一份**(基类持有、`_ready` 调它)。
	var st_mh := ScanUtil.code_only(ScanUtil.read("res://server/match_host.gd"))
	_check(st_mh.contains("func _wire_hit_feedback(") and st_mh.contains("_wire_hit_feedback()"),
			"★ ⑬g 受击接线由生产持有(`MatchHost._ready` 调 `_wire_hit_feedback`),探针只是调它")

	# ── ⑬h 离开者的 ACS 分母 = 他**实际参与**的局数 ──
	# 口径理由:离开者没打的那几局不该稀释他(brief 明写)。代价是分母比在场者小 —— 有意的。
	_host._round_num = 2
	_set_stats(_host, [[1, 0, 0, 0, 500, 0], [6, 0, 0, 0, 300, 0]])
	_host._left = {}
	_host._left_round = {}
	_host.mark_disconnected(6)          # ⑥ 号在第 2 局离场(顺带验它对逐人表无副作用)
	_check(int(_host._left_round.get(6, -1)) == 2,
			"★ ⑬h 离场时把局号**冻结**下来(实际 %s;不记的话分母会跟着对局继续涨)"
			% str(_host._left_round.get(6, -1)))
	_host._round_num = 5                # 对局又打了几局
	var st_pay3: Dictionary = _host.stats_payload()
	_check(absf(float(st_pay3[6]["acs"]) - 30.0) < 0.0001,
			("★ ⑬h 离开者:分母 = 他实际参与的局数(kscore 60 ÷ 2 局 = 30,实际 %f;"
			+ "按全场 5 局算会是 12)") % float(st_pay3[6]["acs"]))
	_check(absf(float(st_pay3[1]["acs"]) - 20.0) < 0.0001,
			"★ ⑬h 在场者:分母仍是**全场局数**(kscore 100 ÷ 5 = 20,实际 %f)" % float(st_pay3[1]["acs"]))
	_check(st_pay3.has(6), "★ ⑬h 已离开者的逐人数据**不消失**(面板仍要展示他的成绩)")

	# ── ⑬j 已离开者**照样参与 MVP 评选**(用户裁定 2026-09-19;**不是遗漏**)──
	# 取向与大乱斗 `_match_winner` 的"已离开但计过分的也算"一致;且他的 ACS 分母是
	# **实际参与局数**(更小)⇒ 更容易胜出 —— 那也是有意的口径。
	# 构造(接着 ⑬h 的状态):6 号计过分(dealt 300 ⇒ kscore 60)之后在第 2 局离场,对局又打到
	#   第 5 局 ⇒ 他的 ACS = 60/2 = 30,**高于**在场者 1 号(100/5 = 20)。
	# ★ 判据必须是"MVP **指向他**":把离开者从候选里滤掉的实现会给出 1 号 ——
	#   只断言"他还在逐人表里"(⑬h 那条)验的是载荷,验不到**候选集**,故必须让他赢一次。
	_host._round_state = MatchHost.RoundState.MATCH_OVER
	_host._broadcast_round_state()   # 终局那一份载荷真的走一遍(无 peer ⇒ 只是不发包)
	_check(_host.mvp_role() == 6,
			("★ ⑬j **已离开者仍是 MVP 候选**(用户裁定;MVP 实际 %d,期望 6 —— "
			+ "把 `_left` 从候选里滤掉就会变成 1 号)") % _host.mvp_role())

	# ── ⑬k 助攻:甲打乙 20、丁再打乙 60、丙补掉乙 ⇒ 丙记击杀、**甲与丁各记一次助攻**;
	#   窗口外不记 (k2) / 队友误伤不算 (k3) / 队友击杀谁都不算 (k4) ──
	# ★ spec §6.2 的三档;★ (k1) 放两位攻击者是刻意的(评审 F6-1)、(k4) 是评审 F6-2 的补丁;
	#   ★ (k2) 后半档是**鉴别点** —— 只断言"甲记了助攻"的话,把窗口判据删掉也能过。
	# ★ 助攻表住在 `_assist_times`(role -> role -> 时刻),写入点是生产的
	#   `MatchCombat._on_player_hit`(所有伤害路径的唯一汇聚点),本段**不手写表** ——
	#   甲/丁那两枪(20 + 60)都是走真归因写端 + 真 `take_hit` 落进去的。
	_host._round_state = MatchHost.RoundState.PLAYING
	_host._scores = {}
	_host._left = {}
	_host._left_round = {}
	# ★ 逐人原始表也清一次:⑬k/⑬m/⑬n 有几条读数是**增量**(不怕残余),但把表清空能让
	#   它们与 ⑬l 的绝对读数(「队伍表为空 ⇒ 助攻恒 0」)都建立在可手算的基线上。
	_host._stats = {}
	for st_kr in _host.players:
		_host._respawn_player(int(st_kr))
	# (k1) 甲(1 号,1 队)打乙(4 号,2 队)20,丁(3 号,1 队)再打乙 60 ⇒ **两位攻击者各记一次助攻**
	# ★★ 放**两位**攻击者是刻意的(评审 F6-1):原夹具里受害者表**最多只有一个候选** ⇒
	#   "只给第一个/最后一个 attacker 记一次"、"每次倒地最多记一次助攻"这类实现**全绿**。
	# ★★ 两枪的顺序不能反:乙满血 50,而后打的那一枪是 60 ⇒ 乙**当场倒地**,而 `take_hit`
	#   在 `downed` 时早退(`scenes/player/combat_component.gd:43`)⇒ 先打 60 再补第二枪会
	#   **静默不入表**。故 20 点的甲必须走在 60 点的丁前面(50 → 30 → -30,两枪都进表)。
	var st_a_k1 := _stat(_host, 1, "assists")
	var st_a_k1b := _stat(_host, 3, "assists")
	var st_a_k2 := _stat(_host, 2, "assists")
	CombatFeedback.attribute(_host.players[4], _host.players[1])   # 甲(1 号,1 队)
	(_host.players[4] as Node2D).take_hit(Vector2.ZERO, 20)
	# ★★ `st_a_ks1` 必须在**甲那一枪之后**读:这一枪本身就给甲 `dealt += 20` ⇒ kscore 已 +4
	#   (`ScoreRules.kscore(0, 0, 20, 0) == 4`)。在伤害**之前**读的话,下面那条"助攻进 kscore"
	#   要断的就是 **(50 + 20/5) = 54** 而不是 +50 ⇒ **实现正确也不会绿**。移到伤害之后读,
	#   这条就只量助攻那一项(与甲这一枪打几点无关)。
	var st_a_ks1 := _kscore(_host, 1)
	CombatFeedback.attribute(_host.players[4], _host.players[3])   # 丁(3 号,1 队)
	(_host.players[4] as Node2D).take_hit(Vector2.ZERO, 60)
	_check(_assist_table(_host, 4).has(1),
			"★ ⑬k [仪器] 甲的那一枪必须进了助攻表(否则下面两条恒真;表=%s)"
			% str(_assist_table(_host, 4)))
	_check(_assist_table(_host, 4).has(3),
			"★ ⑬k [仪器] 丁的那一枪也必须进了助攻表(否则'第二位也记'那条恒真;表=%s)"
			% str(_assist_table(_host, 4)))
	# 丙(2 号,1 队)补掉乙 —— `_down` 会先把归因写成丙,再走倒地边沿
	_down(_host, 4, 2)
	_check(_stat(_host, 2, "kills") == 1, "★ ⑬k 丙(补刀的)记击杀(实际 %d)" % _stat(_host, 2, "kills"))
	_check(_stat(_host, 1, "assists") - st_a_k1 == 1,
			"★ ⑬k 甲**记一次助攻**(实际 +%d,期望 +1)"
			% (_stat(_host, 1, "assists") - st_a_k1))
	_check(_stat(_host, 3, "assists") - st_a_k1b == 1,
			("★ ⑬k 丁(**第二位**攻击者)**也**各记一次助攻(实际 +%d,期望 +1;"
			+ "整个循环只给一位候选记账的实现在这里红)")
			% (_stat(_host, 3, "assists") - st_a_k1b))
	_check(_kscore(_host, 1) - st_a_ks1 == 50,
			"★ ⑬k 助攻进 kscore(+50,实际 +%d)" % (_kscore(_host, 1) - st_a_ks1))
	_check(_stat(_host, 2, "assists") - st_a_k2 == 0,
			"★ ⑬k 击杀者本人**不**记助攻(实际 +%d)" % (_stat(_host, 2, "assists") - st_a_k2))
	# ★ 清空点是**复活**而不是倒地 ⇒ 倒地之后、复活之前表**还在**。
	#   ★ 这两条是**一对**:只断"复活后是空的"的话,"从来就没有这张表"也全绿。
	_check(not _assist_table(_host, 4).is_empty(),
			"★ ⑬k [仪器] 复活**之前**表还在(证下面那条清空不是恒真)")
	_host._respawn_player(4)
	_check(_assist_table(_host, 4).is_empty(),
			"★ ⑬k 复活时清空该受害者的助攻表(不清的话上一条命的命中会算进下一条命)")

	# (k2) 窗口外不记助攻 —— 把表里那一笔的时刻往前挪出 3s
	# ★ 这里是**直接改表**(唯一一处手写表):等 3s 不现实,而窗口判据必须被验到。
	#   `_age_assist` 的防御写法见它的注释(字段不存在时返回 false,由下面这条断言红出来)。
	# ★★ 但改表**之前必须先重打一枪**:清空点是**复活**,而 (k1) 末尾刚复活过 4 号 ⇒ 此刻
	#   `_assist_times[4]` 整张子表已被 `_clear_assist_table` 抹掉。少了这一枪,`_age_assist` 会因
	#   "条目不存在"返回 false ⇒ 那条 [仪器] 断言在**正确实现下也会红**(它守的是"窗口判据真的
	#   被验到",而不是"表是空的")。★ 与 (k1) 同理,必须在 (k1) 的**复活之后**、且是**新的**一枪。
	CombatFeedback.attribute(_host.players[4], _host.players[1])
	(_host.players[4] as Node2D).take_hit(Vector2.ZERO, 5)
	_check(_assist_table(_host, 4).has(1), "[仪器] ⑬k 前提:重打的那一枪进了表")
	_check(_age_assist(_host, 4, 1, TeamHost.ATTRIB_WINDOW + 1000)
			and Time.get_ticks_msec() - int(_assist_table(_host, 4).get(1, 0)) > TeamHost.ATTRIB_WINDOW,
			"[仪器] ⑬k 前提:表里那一笔确实**已超窗**(否则下面那条验的不是窗口判据)")
	var st_a_k3 := _stat(_host, 1, "assists")
	_down(_host, 4, 2)
	_check(_stat(_host, 1, "assists") - st_a_k3 == 0,
			("★ ⑬k 甲的最后一次命中在窗口(3s)外 ⇒ **不记助攻**(实际 +%d);"
			+ "删掉窗口判据这里会变成 +1") % (_stat(_host, 1, "assists") - st_a_k3))

	# (k3) 队友误伤 **不算**助攻:乙的队友(5 号,2 队)炸过乙,随后敌人补掉乙
	# ★★ 这是本段最要紧的一条:没有 `same_team(attacker, killer_role)` 那道过滤,
	#   5 号会**因为打死自己人**拿到一次助攻。
	# ★★ **2026-09-28 全文改写**(旧文写的是一套**两合取项**的矩阵,而那个 `or` 已被
	#   `6244865` 整体删除 —— 照旧文读会去找一个**不存在**的后半句):
	#   过滤**今天只有一条**:`if not same_team(attacker, killer_role): continue`。
	#   ⇒ 变异矩阵只剩两格,**两格都已实测**(判据 = 本探针的 `FAIL` 行 + `ok` 计数,
	#   基线 `TEAM HOST: ALL-OK` / **172 ok**):
	#     · **删掉那一条过滤**(即整条队伍过滤都不留)⇒ **2 条红**:本条 (k3) 的
	#       5 号断言(实际 +1)+ ⑬l「队伍表为空 ⇒ 没有任何助攻」(实际 1);170 ok。
	#       ★ **旧文说"只删前半句只有 ⑬l 红、本条 (k3) 仍绿(后半句照样挡住 5 号)"——
	#       那句在 `6244865` 之后是错的**:后半句没了,5 号当场就漏过去。
	#     · **只把助攻块挪到同队早退之前**(过滤行原样保留)⇒ **1 条红**:只有 (k4) 的
	#       3 号断言(见下面那段实测表);171 ok,**本条 (k3) 仍绿**(它的击杀者与受害者
	#       异队,挪不挪块都走同一条路)。
	#   ⇒ "必须与击杀者同队"这条规则今天由 **(k3) 的 5 号断言 + (k4) 的 3 号断言 + ⑬l**
	#     三者共同咬住,**不是**某一处独有 —— 别照旧文推鉴别力。
	_host._respawn_player(4)
	var st_a_k4 := _stat(_host, 5, "assists")
	var st_a_k5 := _stat(_host, 1, "assists")
	CombatFeedback.attribute(_host.players[4], _host.players[5])   # 队友(5 号,2 队)打乙(4 号,2 队)
	(_host.players[4] as Node2D).take_hit(Vector2.ZERO, 10)
	_check(_assist_table(_host, 4).has(5),
			"[仪器] ⑬k 前提:队友那一枪**确实进了表**(没进的话下面那条是空转)")
	_down(_host, 4, 1)          # 敌人(1 号,1 队)补掉乙
	_check(_stat(_host, 5, "assists") - st_a_k4 == 0,
			("★ ⑬k 受害者的**队友**误伤之后、敌人补刀 ⇒ 那位队友**不得**记助攻"
			+ "(实际 +%d);删掉 `if not same_team(attacker, killer_role): continue`"
			+ "(今天就**这一条**过滤)这里就变 +1 —— 实测那一格共红 2 条)")
			% (_stat(_host, 5, "assists") - st_a_k4))
	_check(_stat(_host, 1, "assists") - st_a_k5 == 0,
			"★ ⑬k [仪器] 击杀者本人仍不记助攻(实际 +%d)" % (_stat(_host, 1, "assists") - st_a_k5))

	# (k4) **队友击杀不给任何人助攻**(评审 F6-2):乙(2 号,1 队)先被两人打过 —— **敌人**
	#   (4 号,2 队)与**队友**(3 号,1 队)—— 随后乙的**队友**(1 号,1 队)补掉乙 ⇒ **谁都不记助攻**。
	# ★ 换受害者(用 2 号而不是 4 号)是为了拿到**队友攻击者**:乙的队友只有 1/3 两个 role
	#   (6 号已在 ⑬h 被移出 `players`),击杀者占掉一个(1 号)⇒ 另一位(3 号)才当得上攻击者。
	# ★★ 两位攻击者**不是重复**,各钉一条实现路径(**2026-09-28 重测的鉴别力矩阵**;旧文那套
	#   "挪块 ± 删前半句/后半句"的四格已随 `6244865`(删掉 `or` 后半句)作废 —— 今天只有
	#   **一条**过滤行,故只剩下面两格。判据 = `FAIL` 行 + `ok` 计数,基线 **172 ok** /
	#   `TEAM HOST: ALL-OK` / 零 FAIL):
	#   · **只**挪块(助攻块移到同队早退之前,过滤行原样保留)⇒ **只有队友那条红**(3 号 +1),
	#     敌人那条**仍绿**(4 号与击杀者异队,仍被过滤行挡掉);**171 ok** / `TEAM HOST: FAIL`。
	#     ★ 旧文说这一格"两条都绿、整跑 ALL-OK(156 ok)" —— **不再成立**:当年挡住 3 号的是
	#     那条 `or same_team(attacker, victim)`,它已删。**"早退与后半句互为保险带"那句一并作废。**
	#   · **只**删过滤行(助攻块位置不动)⇒ **本条 (k4) 两条都仍绿**(同队击杀走早退、助攻块
	#     根本到不了),而 **(k3) 的 5 号断言 + ⑬l 红 2 条**;**170 ok**。
	#   ⇒ 两格**互不重复**:一格打 (k4) 的 3 号,另一格打 (k3) 的 5 号 + ⑬l。
	#     "队友击杀 ⇒ 谁都不记助攻"由 **(k4) 的 3 号**(挡"挪块"回归)+
	#     **(k3) 的 5 号与 ⑬l**(挡"删过滤行"回归)**共同**咬住。
	# ★ (k4) 的**敌人 4 号**那一条**今天没有独立变异**:能让它红的写法是"挪块**且**删过滤行",
	#   而那一格本批**未跑** —— 照本仓纪律(变异声明要有实测)这里**不写数**。
	_host._respawn_player(2)
	var st_d_k4 := _stat(_host, 2, "deaths")
	var st_a_k4a := _stat(_host, 4, "assists")     # 敌人(4 号,2 队)
	var st_a_k4b := _stat(_host, 3, "assists")     # 队友(3 号,1 队)
	# ★ 顺手把 `team_kills` 也钉住(评审 F2 的免费补丁):本段**恰好制造了一次队友击杀**。
	#   ★ 2026-09-26 订正:旧注释写"那一笔在别处**没有任何断言**、⑬m 要到 Task 2 才有" ——
	#     **已过期**:⑬m(`_stat(_host, 1, "team_kills")`)今天也是一条值断言 ⇒ 这条规则
	#     现在是**两处**守卫(本段 (k4) 的队友击杀支 + ⑬m 的爆炸致死支),不是一处。
	#   取**增量**更稳(不怕前面几段的残余)。
	var st_tk_k4 := _stat(_host, 1, "team_kills")  # 补刀的队友(1 号,1 队)
	CombatFeedback.attribute(_host.players[2], _host.players[4])   # 敌人打乙
	(_host.players[2] as Node2D).take_hit(Vector2.ZERO, 10)
	CombatFeedback.attribute(_host.players[2], _host.players[3])   # 队友(误伤)打乙
	(_host.players[2] as Node2D).take_hit(Vector2.ZERO, 10)
	_check(_assist_table(_host, 2).has(4) and _assist_table(_host, 2).has(3),
			"[仪器] ⑬k 前提:两位攻击者都进了表(没进的话下面两条恒真;表=%s)"
			% str(_assist_table(_host, 2)))
	_down(_host, 2, 1)          # 乙的**队友**(1 号,1 队)补掉乙 ⇒ 走队友击杀分支
	_check(_stat(_host, 2, "deaths") - st_d_k4 == 1,
			"[仪器] ⑬k 前提:这一下**真的走完了倒地边沿**"
			+ "(deaths 没 +1 = `_record_down` 没跑,下面两条恒真)")
	_check(_stat(_host, 1, "team_kills") - st_tk_k4 == 1,
			("★ ⑬k 队友击杀给**肇事者**记一次 `team_kills`(实际 +%d,期望 +1)"
			+ " —— 惩罚公式靠它;另一处守卫是 ⑬m(爆炸致死那一支))")
			% (_stat(_host, 1, "team_kills") - st_tk_k4))
	_check(_stat(_host, 4, "assists") - st_a_k4a == 0,
			("★ ⑬k 乙被**自己队友**补掉 ⇒ 之前打过乙的**敌人**(4 号)**不得**记助攻"
			+ "(实际 +%d);**本批未跑出**能让它单独变红的变异(挪块只打 3 号那条;见上面的两格表)")
			% (_stat(_host, 4, "assists") - st_a_k4a))
	_check(_stat(_host, 3, "assists") - st_a_k4b == 0,
			("★ ⑬k 乙被**自己队友**补掉 ⇒ 误伤过乙的**队友**(3 号)**也不得**记助攻"
			+ "(实际 +%d);**挪块**(助攻块移到同队早退之前)就会给 +1 —— 实测那一格红 1 条")
			% (_stat(_host, 3, "assists") - st_a_k4b))

	# ── ⑬m 惩罚之一:炸死队友 ──
	# ★ spec §6.3:甲的 kscore **减少**、deaths 不变、kills 不变;
	#   ★ 并且**不进** `dealt`(伤害那一列只算敌人)—— 与 `taken`(受害者那一侧)同样不进。
	# 布景与 ⑬b3 同款:受害者摆在**爆心**(d == 0 ⇒ 内圈满伤、免疫遮挡),其余人摆到 600px 外。
	_host._respawn_player(2)     # 队友乙:2 号(1 队)
	var st_p_pt := _find_dry_point()
	if st_p_pt.x < 0:
		st_p_pt = (_host.players[2] as Node2D).global_position
	(_host.players[2] as Node2D).global_position = st_p_pt
	# ★ 其余人(在场的**全部**,含扔雷的 1 号)一律挪到 600px 外 ⇒ 半径 100 的爆炸只够得到 2 号。
	#   ★ 用 `_park_all_but` 而不是写死 role 列表:⑬h 已把 6 号摘出 `players`(见助手注释)。
	_park_all_but(_host, [2], st_p_pt + Vector2(600.0, 0.0))
	var st_p_ks0 := _kscore(_host, 1)
	var st_p_kills := _stat(_host, 1, "kills")
	var st_p_deaths := _stat(_host, 1, "deaths")
	var st_p_dealt := _stat(_host, 1, "dealt")
	var st_p_taken := _stat(_host, 2, "taken")
	var st_p_team := _stat(_host, 1, "team_damage")
	var st_p_tkill := _stat(_host, 1, "team_kills")
	var st_p_hp2: int = int(_host.players[2].hp)
	Explosion.apply_aoe(st_p_pt, 100.0, 60, 400.0, _host.players[1])
	_host._match_round_tick(0.016)      # 倒地边沿(60 > 满血 50 ⇒ 必然死)
	_check(int(_host.players[2].hp) < st_p_hp2 or (_host.players[2] as Node2D).is_downed(),
			"★ ⑬m [仪器] 那一下爆炸**真的打中了队友**(否则下面所有读数恒 0)")
	# ★ 读数一律取**增量**:座位表可能带着前面几段的残余(本档只关心"这一下记了什么"),
	#   而"`dealt` 增量必须是 0"同时兼任**布景仪器** —— 若有别的队在爆区里被蹭到,
	#   `dealt` 会涨(它按队伍分账),这条就会红。
	_check(_stat(_host, 1, "team_damage") - st_p_team == 60,
			"★ ⑬m 对队友造成的伤害进 team_damage(实际 +%d,期望 +60)"
			% (_stat(_host, 1, "team_damage") - st_p_team))
	_check(_stat(_host, 1, "team_kills") - st_p_tkill == 1,
			"★ ⑬m 击杀队友记一次(实际 +%d,期望 +1)"
			% (_stat(_host, 1, "team_kills") - st_p_tkill))
	_check(_kscore(_host, 1) - st_p_ks0 == -(60 / 5 + 100),
			("★ ⑬m 炸死队友 ⇒ kscore **减少** %d(实际 %d)—— 伤害 ÷5 与击杀队友 ×100 两项")
			% [-(60 / 5 + 100), _kscore(_host, 1) - st_p_ks0])
	_check(_stat(_host, 1, "kills") == st_p_kills and _stat(_host, 1, "deaths") == st_p_deaths,
			"★ ⑬m 肇事者的 kills / deaths **不变**(实际 %d/%d)"
			% [_stat(_host, 1, "kills"), _stat(_host, 1, "deaths")])
	_check(_stat(_host, 1, "dealt") == st_p_dealt and _stat(_host, 2, "taken") == st_p_taken,
			("★ ⑬m 惩罚**不进** dealt / taken(实际 %d/%d;伤害那两列只算敌人)"
			+ " —— 惩罚是**另一笔账**,与 dealt/taken 不共用(spec §3.5)")
			% [_stat(_host, 1, "dealt"), _stat(_host, 2, "taken")])

	# ── ⑬n 惩罚之二:**自伤**同样扣 ──
	# ★★ 本档是"自伤标记通道"的**唯一**守卫(spec §3.5 说"不需要新机制",实测**需要**:
	#   `attribute()` 对 attacker == victim 静默跳过 ⇒ 自伤与"归因不到"在 `_on_player_hit`
	#   里完全不可区分)。把 `Explosion` 里那笔 `note_self_hit` 删掉,本档立刻红。
	# ★ 20 伤 < 满血 50 ⇒ 故意**不打死**,只量伤害账。
	_host._respawn_player(1)
	var st_s_pt := _find_dry_point()
	if st_s_pt.x < 0:
		st_s_pt = (_host.players[1] as Node2D).global_position
	(_host.players[1] as Node2D).global_position = st_s_pt
	_park_all_but(_host, [1], st_s_pt + Vector2(600.0, 0.0))
	var st_s_ks0 := _kscore(_host, 1)
	var st_s_deaths := _stat(_host, 1, "deaths")
	var st_s_self := _stat(_host, 1, "self_damage")
	var st_s_hp1: int = int(_host.players[1].hp)
	Explosion.apply_aoe(st_s_pt, 100.0, 20, 400.0, _host.players[1])   # 投掷者 = 受害者本人
	_check(int(_host.players[1].hp) == st_s_hp1 - 20,
			"★ ⑬n [仪器] 自己那一下**真的炸到自己了**(hp %d → %d,期望 -20;`apply_aoe` 不排除投掷者)"
			% [st_s_hp1, int(_host.players[1].hp)])
	_check(_stat(_host, 1, "self_damage") - st_s_self == 20,
			("★ ⑬n 自伤进 self_damage(实际 +%d,期望 +20);★ 删掉 `Explosion` 里那笔 "
			+ "`note_self_hit` 这条就变 0")
			% (_stat(_host, 1, "self_damage") - st_s_self))
	_check(_kscore(_host, 1) - st_s_ks0 == -(20 / 5),
			"★ ⑬n 自伤 ⇒ kscore 减少 %d(实际 %d)" % [-(20 / 5), _kscore(_host, 1) - st_s_ks0])
	_check(_stat(_host, 1, "deaths") == st_s_deaths,
			"★ ⑬n 没打死 ⇒ deaths 不变(实际 %d)" % _stat(_host, 1, "deaths"))

	# ── ⑬n2 正向对照:同一个爆炸打在**敌人**身上照常进 dealt / taken,且不进惩罚 ──
	# ★ 与 ⑬m/⑬n 互为一组:少了它,"什么都记不上"的坏实现能让那两条全绿(本仓反复清的那种假绿)。
	# ★ 布景与 ⑬m 逐字同款,只把受害者换成**敌方**(4 号,2 队),且投掷者(1 号)自己远远站着
	#   —— 远到不在爆区内 ⇒ **不会**写出自伤标记(半径 100 < 600)。
	_host._respawn_player(4)
	var st_n2_pt := _find_dry_point()
	if st_n2_pt.x < 0:
		st_n2_pt = (_host.players[4] as Node2D).global_position
	(_host.players[4] as Node2D).global_position = st_n2_pt
	_park_all_but(_host, [4], st_n2_pt + Vector2(600.0, 0.0))
	var st_n2_dealt := _stat(_host, 1, "dealt")
	var st_n2_taken := _stat(_host, 4, "taken")
	var st_n2_team := _stat(_host, 1, "team_damage")
	var st_n2_self := _stat(_host, 1, "self_damage")
	Explosion.apply_aoe(st_n2_pt, 100.0, 30, 400.0, _host.players[1])
	_check(_stat(_host, 1, "dealt") - st_n2_dealt == 30
			and _stat(_host, 4, "taken") - st_n2_taken == 30,
			"★ ⑬n2 敌方爆炸照常进 dealt/taken(实际 +%d/+%d,期望 +30/+30)"
			% [_stat(_host, 1, "dealt") - st_n2_dealt, _stat(_host, 4, "taken") - st_n2_taken])
	_check(_stat(_host, 1, "team_damage") == st_n2_team
			and _stat(_host, 1, "self_damage") == st_n2_self,
			"★ ⑬n2 敌方伤害**不进**惩罚那两笔账(实际 %d/%d)"
			% [_stat(_host, 1, "team_damage"), _stat(_host, 1, "self_damage")])

	# ── ⑬n3 同帧两响,**自伤在前、敌方爆炸在后** ⇒ 敌方那一下不得被自伤标记吞掉 ──
	# ★★ 被钉的缺陷:自伤标记是一个**时刻标量**且**从来没人清**(`note_self_hit` 只写、
	#   `is_fresh_self_hit` 只读),窗口又宽达 8ms —— 而同一物理帧里两次 `apply_aoe`
	#   (各在自己的 `bullet._physics_process` 里跑)之间隔 **0ms**。于是"自己那颗先炸、
	#   敌人那颗后炸"时,第二下会同时看见 `stat_self == true` **与** 新鲜的 `stat_attacker`,
	#   惩罚那一支按**自伤**记 ⇒ 玩家**因为被敌人打中而扣自己的分**。
	# ★ 修法在**写端**(`CombatFeedback.attribute` 落地真实归因时把标记作废),读端的优先级
	#   (`if stat_self:` 优先)一个字符都不动 —— 那一支正是 ⑬n4 要的语义。
	# ★ 布景与 ⑬n2 逐字同款:受害者(1 号)站爆心干格、其余人 600px 外(半径 100 ⇒ 只够得到 1 号)。
	#   两响都取 20 伤 ⇒ 合计 40 < 满血 50,**故意不打死**(只量伤害账)。
	# ★ 两响之间**不 await**(本段整体在同一个物理帧里跑)—— 那正是"同帧"的构造本身。
	_host._respawn_player(1)
	var st_n3_pt := _find_dry_point()
	if st_n3_pt.x < 0:
		st_n3_pt = (_host.players[1] as Node2D).global_position
	(_host.players[1] as Node2D).global_position = st_n3_pt
	_park_all_but(_host, [1], st_n3_pt + Vector2(600.0, 0.0))
	# ★ 先把上一段(⑬n)留在 1 号身上的自伤标记清掉:本段要量的是**本段自己**写下的那一个,
	#   否则读数会带上 ⑬n 的残余(整段 ⑬ 都在同一个物理帧里,标记不会自然过期)。
	(_host.players[1] as Node2D).remove_meta("last_self_hit_time")
	var st_n3_self := _stat(_host, 1, "self_damage")
	var st_n3_dealt := _stat(_host, 4, "dealt")
	var st_n3_taken := _stat(_host, 1, "taken")
	var st_n3_team := _stat(_host, 1, "team_damage")
	var st_n3_hp: int = int(_host.players[1].hp)
	Explosion.apply_aoe(st_n3_pt, 100.0, 20, 400.0, _host.players[1])   # ① 自己那颗,先炸
	Explosion.apply_aoe(st_n3_pt, 100.0, 20, 400.0, _host.players[4])   # ② 敌人那颗,同帧后炸
	_check(int(_host.players[1].hp) == st_n3_hp - 40,
			("★ ⑬n3 [仪器] 两响**都真的炸到了**(hp %d → %d,期望 -40)"
			+ " —— 少了这条,下面的读数可能因为「根本没打中」而恒真")
			% [st_n3_hp, int(_host.players[1].hp)])
	_check(_stat(_host, 4, "dealt") - st_n3_dealt == 20
			and _stat(_host, 1, "taken") - st_n3_taken == 20,
			"★ ⑬n3 敌方那一下(②)照常进 dealt/taken(实际 +%d/+%d,期望 +20/+20)"
			% [_stat(_host, 4, "dealt") - st_n3_dealt, _stat(_host, 1, "taken") - st_n3_taken])
	_check(_stat(_host, 1, "self_damage") - st_n3_self == 20,
			("★ ⑬n3 敌方那一下(②)**不得**被①留下的自伤标记吞掉"
			+ "(实际 +%d,期望 +20 —— 只有①那一响是自伤);"
			+ "★ 写端不清标记时实际是 +40 = 玩家被敌人打中还扣自己的分")
			% (_stat(_host, 1, "self_damage") - st_n3_self))
	_check(_stat(_host, 1, "team_damage") == st_n3_team,
			"★ ⑬n3 ②进的是**敌方**账,不是队友账(实际 %d)" % _stat(_host, 1, "team_damage"))

	# ── ⑬n4 ⑬n3 的**另一半**(只差顺序:敌方先、自己后)⇒ 自伤**仍须**记进 self_damage ──
	# ★★ 为什么非要有它(评审 M3 订正 —— 旧措辞举的变异**经实测不成立**,别照它念):
	#   旧稿说"少了 ⑬n4,把标记**整个作废**的实现能让 ⑬n3 全绿" —— **假的**:实测删掉
	#   `note_self_hit` 那一笔 ⇒ ⑬n **自己就红两条**(加上 ⑬n3/⑬n4 共 4 红)⇒ 那一族由 ⑬n 兜住。
	#   ★ ⑬n4 **独有**覆盖的是**另一族**实现:**在读端**以"存在新鲜攻击者"为前置去清标记
	#   (而不是在写端 `attribute()` 里清)—— 那一族下 ⑬n 与 ⑬n3 **都绿**,只有 ⑬n4 红
	#   (`+0,期望 +20`)。⇒ 两条一起才钉住"标记只在**真实归因落地**时作废"这条不变量。
	# ★ 这一序是**计划明文选择的**语义(`server/match_state.gd` 的 `_fresh_attacker_role` 上方
	#   那段"已知边界"):那时 `stat_self` 与 `stat_attacker` **同时**为真,惩罚那一支按**自伤**记。
	#   修法(在 `attribute` 里清标记)对这个序**没有任何影响** —— `attribute(pp, pp)` 在
	#   `attacker == victim` 时早退,标记根本走不到被清的那一行。这一条把它钉成契约。
	# ★ 布景与 ⑬n3 逐字同款,只把两响**对调**。
	# ★★ 顺带登记(不修,也不是本条的判据):②那一下会**同时**记进 4 号的 `dealt`(meta 还是他、
	#   年龄 ≈ 0)与 1 号的 `self_damage` —— 两个不同的账户,`acs` 只读 kscore,不是双计。
	#   那是 `ATTRIB_FRESH_MS` 那条既有边界的形状,见 `match_state.gd` 的登记。
	_host._respawn_player(1)
	var st_n4_pt := _find_dry_point()
	if st_n4_pt.x < 0:
		st_n4_pt = (_host.players[1] as Node2D).global_position
	(_host.players[1] as Node2D).global_position = st_n4_pt
	_park_all_but(_host, [1], st_n4_pt + Vector2(600.0, 0.0))
	(_host.players[1] as Node2D).remove_meta("last_self_hit_time")
	var st_n4_self := _stat(_host, 1, "self_damage")
	var st_n4_hp: int = int(_host.players[1].hp)
	Explosion.apply_aoe(st_n4_pt, 100.0, 20, 400.0, _host.players[4])   # ① 敌人先
	Explosion.apply_aoe(st_n4_pt, 100.0, 20, 400.0, _host.players[1])   # ② 自己后(同帧)
	_check(int(_host.players[1].hp) == st_n4_hp - 40,
			"★ ⑬n4 [仪器] 两响**都真的炸到了**(hp %d → %d,期望 -40)"
			% [st_n4_hp, int(_host.players[1].hp)])
	_check(_stat(_host, 1, "self_damage") - st_n4_self == 20,
			("★ ⑬n4 同帧内**敌方先、自己后** ⇒ 自伤照样记进 self_damage(实际 +%d,期望 +20);"
			+ "★ 把标记的作废写进 `attribute()` 的**早退之前**(或整个作废标记)这条就变 0 "
			+ "—— 惩罚会漏掉这一下")
			% (_stat(_host, 1, "self_damage") - st_n4_self))

	# ── ⑬l 队伍表为空(1v1 / 大乱斗的形状)⇒ **拿不到任何助攻**,而击杀照记 ──
	# ★ 这是 spec §3.4「免费的正确性」的守卫:`same_team(0,0)` 恒 false ⇒ 助攻过滤天然不成立。
	#   ★ 正向对照(击杀照记)不可省:只断言"assists == 0"的话,一个**什么都没接**的宿主
	#   (或"助攻永远不记"的坏实现)照样全绿。
	# ★★ 覆盖范围的口径(评审 F4 订正;★ 2026-09-26 与 2026-09-28 各再订正一次,**别照旧读**):
	#   · 旧注释写"`_record_down` 的**唯一调用点**是 `team_host.gd`、**1v1 与 royale 根本不调它**"
	#     —— **今天三模式都调**:1v1 `match_round.gd` 的 `_match_round_tick`、大乱斗
	#     `royale_host.gd`、3v3 `team_host.gd`(各一行,`grep -n _record_down\\( server/` 为准)。
	#   · 那两个模式的宿主(`MatchBootstrap` 直接建的 `MatchHost` / `RoyaleHost`)**队伍表恒空**
	#     ⇒ 本段这个夹具(队伍表为空的宿主)就是它们的**生产形状本身**,不是"生产里不存在的配置"。
	#   · 旧注释写"它是**为将来接线预留**的性质,等 1v1/大乱斗接上统计投递(下一份计划)才成为
	#     真正的生产守卫" —— **那份计划已落地(2026-09-26)**,故本条**今天就是**生产守卫。
	#   ⇒ 结论(空表 ⇒ 无助攻)逐字不变,变的只是**理由**:它守的是 1v1/大乱斗那两具宿主当下的
	#     实际行为(`same_team` 恒 false ⇒ 助攻过滤天然不成立),不是未来某天才成立的性质。
	#   ★★ **2026-09-28 重测订正**:旧文说它"是**唯一**咬住「必须与击杀者同队」的断言
	#     ((k1)~(k4) 全绿、只有本段红)" —— **不再成立**。今天那条过滤只有**一行**
	#     (`if not same_team(attacker, killer_role): continue`;`or same_team(attacker, victim)`
	#     那半句已随 `6244865` 删除)⇒ 删掉它时**本段红 + (k3) 的 5 号断言红**,共 **2 条**、
	#     **170 ok**(实测)。⇒ 那条规则由**本段 + (k3) 的 5 号 + (k4) 的 3 号**共同咬住
	#     (三处各管自己的变异格,见 (k3)/(k4) 那两段的两格表)。
	#   ★ 本段**最后**跑:新建宿主会重载全局网格,前面几段(尤其 ⑬b3 的 `_find_dry_point`)
	#   依赖它保持不动。
	#   ★ 实参个数是**编译期**核的:多给一个实参(写成 7 个)当场是 Parse Error ——
	#     `SCRIPT ERROR: Parse Error: Too many arguments for "new()" call. Expected at most 6 but received 7.`
	#     (紧跟着还有一条 `Invalid argument for "new()" function: argument 5 should be "Dictionary" but is "Array".`
	#      —— 多出来的那个 `[]` 顶掉了第 5 个实参的位置,是同一次写错的第二条诊断)
	#     `ERROR: Failed to load script "res://tests/team_host_probe.gd" with error "Parse error".`
	#   ⇒ 场景根**没有脚本** ⇒ **一行都不打印**(实测整跑 **8 行**输出、`TEAM HOST:` 零命中)、
	#   `--quit-after` 到点照常 `EXIT=0` —— 正是 CLAUDE.md 记的那档"与超时在退出码上不可分"。
	#   ★ 它**不是假绿**(判据是 grep `TEAM HOST: ALL-OK`,拿不到就判红),但**150 条断言一条都跑不到**;
	#   而 `_ran_to_end` 那道闸**兜不住它** —— 那道闸只管 `_run()` 里的**运行期**中断,管不了脚本加载失败。
	#   ★ 上面这段来自**故意写成 7 个实参**的一次试跑(不是 brief 的缺陷:brief 与计划里原文都
	#   是 6 个实参,与 `TeamHost._init(map_path, role_peers, options, ai_roles, spawns, teams)` 对得上)。
	#   按同文件既有的 `TeamHost.new(MAP, {}, {}, [], teams, TEAMS)` 补正。
	var st_plain = TeamHost.new(MAP, {}, {}, [],
			{1: Vector2i(5, 10), 2: Vector2i(9, 10), 4: Vector2i(30, 10)}, {})
	add_child(st_plain)
	st_plain.set_physics_process(false)
	for st_pr in [1, 2, 4]:
		_place(st_plain, st_pr, {1: Vector2i(5, 10), 2: Vector2i(9, 10), 4: Vector2i(30, 10)}[st_pr])
	st_plain._wire_hit_feedback()
	st_plain._round_state = MatchHost.RoundState.PLAYING
	CombatFeedback.attribute(st_plain.players[4], st_plain.players[1])
	(st_plain.players[4] as Node2D).take_hit(Vector2.ZERO, 60)
	_down(st_plain, 4, 2)
	_check(_stat(st_plain, 2, "kills") == 1,
			"★ ⑬l [正向对照] 队伍表为空时**击杀照记**(实际 %d)" % _stat(st_plain, 2, "kills"))
	_check(_stat(st_plain, 1, "assists") == 0,
			"★ ⑬l 队伍表为空 ⇒ **没有任何助攻**(实际 %d)" % _stat(st_plain, 1, "assists"))
	# ★ 这里**不能**用 `free()`:`_run()` 是在 `physics_frame` 的发射里跑的,同步 `free()` 会把
	#   `WaterFx` 那类 deferred 子节点添加与渲染器的 RID 释放队列一起卡在队列里,
	#   进程结束时多出一串 texture / CanvasItem / ObjectDB 泄漏警告(实测读数见报告)。
	st_plain.queue_free()

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
