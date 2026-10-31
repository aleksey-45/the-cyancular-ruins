extends Node

# 出生点**地图数据**探针:真实地图(要读盘,故是场景探针而不是 `-s` 冒烟)——
#   ① 地图 meta 里真的写足了数据:`# spawn` ≥5(两张图)、`# teamspawn 1/2` 每队 ≥5(newfactory);
#   ② 每个点都过现有 SpawnPicker 判据(地板 + 头顶 2 格 + 同层连通区 ≥ area_threshold,即"不贴死角/不在水里");
#   ③ 1v1 / 大乱斗 / 团队三条接线真的在用这份数据:互不相同、≥ 环面间距、换局/复活排除上一次位置。
# 去掉什么才红:删地图里的 # spawn 行 ⇒ ①②;把 1v1 改回固定两点 ⇒ ⑦;把 respawn 的 last 排除删掉 ⇒ ⑧;
#   把 team 的 side_swap 分支删掉 ⇒ ⑬;把 plan_spawns 换成任何几何生成 ⇒ ⑩ / ⑫ 的"点在地图数据里"不成立。
# 测不到什么:出生点在"手感/观感"上是否舒服(要人眼);真实对局的 match_start 与摆位同源(真链路)。
# 跑法:"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/map_spawn_data_probe.tscn;判据 grep 末行 MARKER。

const NEWFACTORY := "res://maps/newfactory.cyrm"
const DEMO := "res://maps/demo.cyrm"
const MARKER := "MAP SPAWN DATA PROBE: ALL-OK"
const EXPECTED_CHECKS := 17
const FAR := 15            # SpawnPicker.FAR_CELLS 的当前值(1v1 两人最小环面距离)
const MIN_POINTS := 5      # 用户需求:每张地图至少 5 个合理出生点(每队同理)

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[map-spawn]   ✓ %s" % msg)
	else:
		_fails.append(msg)
		print("[map-spawn]   ✗ %s" % msg)


func _ready() -> void:
	_load_map(NEWFACTORY)
	_checks_newfactory_data()
	_checks_duel()
	_checks_royale()
	_checks_team()
	await get_tree().process_frame
	_load_map(DEMO)
	_checks_demo_data()
	_finish()


func _load_map(path: String) -> void:
	MazeGenerator.set_map_file(path)
	SpawnPicker.reset_cache()   # ★ static 缓存跨图不自动失效,换图必须显式清
	WorldBuilder.load_grid()


func _map_spawns() -> Dictionary:
	return MapFormat.load_spawns(MazeGenerator.map_file_path())


# 合格判据 = SpawnPicker 的两条地板谓词 + 连通区门槛(与运行时选点池同一套;不新造几何)。
func _valid_cell(c: Vector2i) -> bool:
	var d := SpawnPicker.grid_dims()
	if c.x < 0 or c.y < 0 or c.x >= d.x or c.y >= d.y:
		return false
	if not SpawnPicker.roomy_floor(c):
		return false
	return int(SpawnPicker.region_sizes().get(c, 0)) >= SpawnPicker.area_threshold()


func _all_valid(label: String, cells: Array) -> bool:
	var bad: Array[String] = []
	for raw in cells:
		var c: Vector2i = raw
		if not _valid_cell(c):
			bad.append(str(c))
	if not bad.is_empty():
		print("[map-spawn]   %s 不合格点: %s" % [label, ", ".join(bad)])
	return bad.is_empty()


func _checks_newfactory_data() -> void:
	var sp := _map_spawns()
	var spawns: Array = sp.get("spawns", [])
	var teams: Dictionary = sp.get("teamspawns", {})
	var t1: Array = teams.get(1, [])
	var t2: Array = teams.get(2, [])
	# 去掉什么才红:地图文件里删掉 # spawn 行 / 只剩 4 个点 ⇒ 本条红。
	_chk(spawns.size() >= MIN_POINTS, "① newfactory # spawn ≥ %d(实测 %d)" % [MIN_POINTS, spawns.size()])
	# 去掉什么才红:写进一个墙里/水里/死角格 ⇒ 本条红(点必须过 SpawnPicker 判据)。
	_chk(_all_valid("newfactory # spawn", spawns), "② newfactory # spawn 每个点都是开阔地板格 + 连通区达标")
	# 去掉什么才红:删 # teamspawn 行 / 每队不足 5 个 ⇒ 本条红。
	_chk(t1.size() >= MIN_POINTS and t2.size() >= MIN_POINTS,
			"③ newfactory # teamspawn 每队 ≥ %d(实测 %d / %d)" % [MIN_POINTS, t1.size(), t2.size()])
	_chk(_all_valid("newfactory # teamspawn1", t1) and _all_valid("newfactory # teamspawn2", t2),
			"④ newfactory # teamspawn 每个点都是开阔地板格 + 连通区达标")
	# 去掉什么才红:两队点写进同一片区域(跨队距离 ≤ 队内距离)⇒ 本条红。
	var min_cross := _cross_min(t1, t2)
	var max_in := maxi(_max_pair_dist(t1), _max_pair_dist(t2))
	_chk(min_cross > max_in, "⑤ newfactory 两队点集分开(跨队最小 %d > 队内最大 %d)" % [min_cross, max_in])
	# 去掉什么才红:把 # player / # player2 行也删了 ⇒ 本条红(MapCatalog 的 PvP 图校验与单机入口都读这两个旧键)。
	_chk(sp.get("player", Vector2i(-1, -1)).x >= 0 and sp.get("player2", Vector2i(-1, -1)).x >= 0,
			"⑥ newfactory 旧键 # player / # player2 保留(向后兼容)")


func _checks_duel() -> void:
	var sp := _map_spawns()
	var points: Array = sp.get("spawns", [])
	var h := MatchHost.new(NEWFACTORY, {1: 20001, 2: 20002})
	add_child(h)
	var p1 := _cell_of(h.players[1])
	var p2 := _cell_of(h.players[2])
	# 去掉什么才红:MatchState._spawn_cell 改回固定两点 ⇒ 两人不一定在 # spawn 里 / 不满足间距(地图上两点可能 <15)。
	_chk(points.has(p1) and points.has(p2) and p1 != p2,
			"⑦ 1v1 首次落点都取自 # spawn 且互不相同(%s / %s)" % [str(p1), str(p2)])
	_chk(GridPathfinder.toroidal_dist(p1, p2, SpawnPicker.grid_dims().x, SpawnPicker.grid_dims().y) >= FAR,
			"⑧ 1v1 首次两人相距 ≥ %d(实测 %d)" % [FAR, GridPathfinder.toroidal_dist(p1, p2,
					SpawnPicker.grid_dims().x, SpawnPicker.grid_dims().y)])
	# 复活/换局:重新随机且排除本 role 上一次位置(去掉 _duel_spawns 的排除 ⇒ 有概率与上一次同格 ⇒ 本条红)。
	var new1 := h._spawn_cell(1)
	var new2 := h._spawn_cell(2)
	_chk(new1 != p1 and points.has(new1), "⑨ 1v1 复活重随机且排除自己的上一次位置(%s → %s)" % [str(p1), str(new1)])
	_chk(new2 != p2 and points.has(new2), "⑩ 1v1 对手复活同样排除上一次位置(%s → %s)" % [str(p2), str(new2)])
	# match_sync 的只读取法:两次调用必须同值(去掉 role_spawns 的只读实现、改成再调 _spawn_cell ⇒ 本条红)。
	var a := h.role_spawns()
	var b := h.role_spawns()
	var cur: Vector2i = a.get(1, Vector2i(-1, -1))
	_chk(a == b and cur == new1, "⑪ role_spawns() 只读且等于最近一次落位")
	h.queue_free()


func _checks_royale() -> void:
	var sp := _map_spawns()
	var points: Array = sp.get("spawns", [])
	var plan := RoyaleHost.plan_spawns([1, 2, 3, 4, 5])
	var cells: Array = []
	for r in plan:
		cells.append(plan[r])
	var uniq := {}
	for c in cells:
		uniq[c] = true
	var all_in_data := true
	for c in cells:
		if not points.has(c):
			all_in_data = false
	# 去掉什么才红:plan_spawns 走几何生成(不读地图数据)⇒ 抽到的点不在 # spawn 列表里 ⇒ 本条红。
	_chk(cells.size() == 5 and uniq.size() == 5 and all_in_data,
			"⑫ 大乱斗 plan_spawns 的 5 个点互不相同且取自 # spawn(实测 %d 个)" % cells.size())
	# 复活排除上一次位置:空局面(无存活玩家)"离所有人远"这一条恒成立,只剩 last 排除在起作用。
	var first_point: Vector2i = points[0]
	var last := {1: first_point}
	var respawn := RoyaleSpawn.respawn_cell(1, {}, {}, last, points)
	# 去掉什么才红:respawn_cell 不接 last / 不排除 ⇒ 有线概率抽回 points[0] ⇒ 本条红(给固定 seed 不适用,故用"不等于"判留痕)。
	_chk(respawn.x >= 0 and respawn != last[1] and points.has(respawn),
			"⑬ 大乱斗复活排除 last(上次 %s → 本次 %s)" % [str(last[1]), str(respawn)])


func _checks_team() -> void:
	var sp := _map_spawns()
	var teams: Dictionary = sp.get("teamspawns", {})
	var t1: Array = teams.get(1, [])
	var t2: Array = teams.get(2, [])
	var team_of := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
	var first := TeamHost.plan_team_spawns(team_of, {}, false)
	var side_ok := true
	for role in first:
		var c: Vector2i = first[role]
		if int(team_of[int(role)]) == 1:
			side_ok = side_ok and t1.has(c)
		else:
			side_ok = side_ok and t2.has(c)
	var uniq := {}
	for role in first:
		uniq[first[role]] = true
	# 去掉什么才红:plan_team_spawns 不用 # teamspawn(走几何生成)或不按队分流 ⇒ 本条红。
	_chk(first.size() == 6 and uniq.size() == 6 and side_ok,
			"⑭ 团队 plan_team_spawns:6 人互不相同、队 1 取 # teamspawn 1、队 2 取 # teamspawn 2")
	var second := TeamHost.plan_team_spawns(team_of, first, true)
	var swap_ok := true
	var no_repeat := true
	for role in second:
		var c: Vector2i = second[role]
		if int(team_of[int(role)]) == 1:
			swap_ok = swap_ok and t2.has(c)
		else:
			swap_ok = swap_ok and t1.has(c)
		if c == first.get(int(role), Vector2i(-1, -2)):
			no_repeat = false
	# 去掉什么才红:side_swap 分支删掉 ⇒ 队 1 仍取 t1;last 排除删掉 ⇒ 有概率与上一局同格(6 人挤 7 点,概率不低)。
	_chk(swap_ok and no_repeat, "⑮ 团队换边:两队换用另一侧点集,且每人都不与上一局同位")


func _checks_demo_data() -> void:
	var sp := _map_spawns()
	var spawns: Array = sp.get("spawns", [])
	# 去掉什么才红:demo.cyrm 没写 # spawn / 只写 4 个 ⇒ 本条红。
	_chk(spawns.size() >= MIN_POINTS, "⑯ demo # spawn ≥ %d(实测 %d)" % [MIN_POINTS, spawns.size()])
	_chk(_all_valid("demo # spawn", spawns), "⑰ demo # spawn 每个点都是开阔地板格 + 连通区达标")


func _cell_of(node: Node2D) -> Vector2i:
	return Vector2i(int(node.global_position.x) / GameParameters.TILE_SIZE,
			int(node.global_position.y) / GameParameters.TILE_SIZE)


func _cross_min(a1: Array, a2: Array) -> int:
	var d := SpawnPicker.grid_dims()
	var best := 1 << 30
	for a in a1:
		for b in a2:
			best = mini(best, GridPathfinder.toroidal_dist(a, b, d.x, d.y))
	return best


func _max_pair_dist(arr: Array) -> int:
	var d := SpawnPicker.grid_dims()
	var best := 0
	for i in range(arr.size()):
		for j in range(i + 1, arr.size()):
			best = maxi(best, GridPathfinder.toroidal_dist(arr[i], arr[j], d.x, d.y))
	return best


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)"
				% [_checks, EXPECTED_CHECKS])
	print("[map-spawn] checks = %d (EXPECTED_CHECKS=%d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print(MARKER)
		get_tree().quit(0)
	else:
		print("MAP SPAWN DATA PROBE: FAIL")
		for f in _fails:
			print("[map-spawn]   ✗ ", f)
		get_tree().quit(1)
