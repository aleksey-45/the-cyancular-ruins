extends Node

# 出生/复活点**地图数据**探针:真实地图(要读盘,故是场景探针而不是 `-s` 冒烟)——
# ★ 2026-11-04:枚举 `res://maps/*.cyrm`(不再写死两张图);PvP 图按 `# player`+`# player2` 判,
#   行为面只在第一张 PvP 图上跑,数据面对每张图跑。

const MAPS_DIR := "res://maps"
const MARKER := "MAP SPAWN DATA PROBE: ALL-OK"
# 条数闸下界(2 张图时);实际闸 = 运行时的 `_expected`:加图不红,少图/断言跳过才红。run_all 的 GATE 栏读这个常量。
const EXPECTED_CHECKS := 20
const MIN_PER_SIDE := 5
const BUCKETS := 9
const MIN_SIDE_GAP := 5

var _fails: Array[String] = []
var _checks := 0
var _expected := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[map-spawn]   ✓ %s" % msg)
	else:
		_fails.append(msg)
		print("[map-spawn]   ✗ %s" % msg)


func _ready() -> void:
	var maps := _list_maps()
	if maps.is_empty():
		_fails.append("res://maps 下没有任何 .cyrm —— 枚举面为空")
		_finish()
		return
	var pvp_maps: Array[String] = []
	for path in maps:
		var is_pvp := _has_pvp_keys(path)
		_expected += 5 + (1 if is_pvp else 0)
		_load_map(path)
		_checks_map_data(path, is_pvp)
		if is_pvp:
			pvp_maps.append(path)
	if pvp_maps.is_empty():
		_fails.append("maps/ 里没有 PvP 图(# player / # player2 双旧键全缺)")
		_finish()
		return
	# 行为面(1v1 / 大乱斗 / 对抗取点)只需要一张 PvP 图:取排序后的第一张,行为结果与"用哪张"无关。
	_load_map(pvp_maps[0])
	_expected += 9
	_checks_duel(pvp_maps[0])
	_checks_royale()
	_checks_team()
	_finish()


# 图集枚举面:maps/ 下全部 .cyrm,排序保证行为面挑的图是确定的。
func _list_maps() -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(MAPS_DIR)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".cyrm"):
			out.append(MAPS_DIR.path_join(f))
	out.sort()
	return out


# PvP 图判据 = 旧键 `# player` + `# player2` 都在(与 MapCatalog 的 PvP 校验同源)。
func _has_pvp_keys(path: String) -> bool:
	var sp := MapFormat.load_spawns(path)
	return sp.get("player", Vector2i(-1, -1)).x >= 0 and sp.get("player2", Vector2i(-1, -1)).x >= 0


func _map_label(path: String) -> String:
	return path.get_file().get_basename()


# ★ 可达性**不做合成网格的"冒烟式"断言**(2026-11-01 用户裁定:根本不应该写这个可达的冒烟)——
#   可达性只由 `tools/map_spawn_meta.gd --check` 与真实地图的"每个复活点可抵达"数据校验守。

func _load_map(path: String) -> void:
	MazeGenerator.set_map_file(path)
	SpawnPicker.reset_cache()   # ★ static 缓存跨图不自动失效,换图必须显式清
	WorldBuilder.load_grid()


func _sides() -> Dictionary:
	var raw: Dictionary = MapFormat.load_spawns(MazeGenerator.map_file_path()).get("respawns", {})
	return {1: (raw.get(1, []) as Array), 2: (raw.get(2, []) as Array)}


# 合格判据 = 与 tools/map_spawn_meta.gd::_bad_reason 同源:地板 + 头顶 2 格 + 可抵达(跳跃感知图主可达区)。
func _valid_cell(c: Vector2i) -> bool:
	var d := SpawnPicker.grid_dims()
	if c.x < 0 or c.y < 0 or c.x >= d.x or c.y >= d.y:
		return false
	if not SpawnPicker.floor_cells_has(c):
		return false
	if int(MazeGenerator.current_grid[posmod(c.y - 2, d.y)][c.x]) != MazeGenerator.EMPTY:
		return false
	return SpawnPicker.is_reachable_spawn(c)


func _bad_points(cells: Array) -> Array[String]:
	var bad: Array[String] = []
	for raw in cells:
		var c: Vector2i = raw
		if not _valid_cell(c):
			bad.append(str(c))
	return bad


func _side_problems(side: int, cells: Array, require_buckets: bool) -> Array[String]:
	var d := SpawnPicker.grid_dims()
	var bad: Array[String] = []
	var buckets := {}
	for raw in cells:
		var c: Vector2i = raw
		if SpawnChooser.side_of(c, d) != side:
			bad.append("越侧 %s" % str(c))
			continue
		# 离本侧两条边界(接缝 / 半区中线)太近:对面半区的点在环面距离上还贴着它 ⇒ "各占半区"只在名字上成立。
		if not SpawnChooser.side_inside_margin(c, side, d):
			bad.append("贴边界 %s" % str(c))
			continue
		buckets[SpawnChooser.bucket_of(c, side, d)] = true
	if require_buckets:
		for b in BUCKETS:
			if not buckets.has(b):
				bad.append("桶 %d 空" % b)
	return bad


func _min_pair_dist(cells: Array) -> int:
	var d := SpawnPicker.grid_dims()
	var best := 1 << 30
	for i in range(cells.size()):
		for j in range(i + 1, cells.size()):
			best = mini(best, GridPathfinder.toroidal_dist(cells[i], cells[j], d.x, d.y))
	return best if cells.size() >= 2 else 0


func _sides_ok(label: String, sides: Dictionary, require_buckets: bool) -> void:
	var s1: Array = sides.get(1, [])
	var s2: Array = sides.get(2, [])
	# 去掉什么才红:某侧不足 5 个点(或两侧被塞成同一批点)⇒ 本条红。
	_chk(s1.size() >= MIN_PER_SIDE and s2.size() >= MIN_PER_SIDE,
			"%s 每侧 ≥%d(实测 %d / %d)" % [label, MIN_PER_SIDE, s1.size(), s2.size()])
	# 去掉什么才红:把点写到对面半区 / (PvP 图)均匀判据被破坏 ⇒ 本条红。
	var side_bad: Array[String] = []
	side_bad.append_array(_side_problems(1, s1, require_buckets))
	side_bad.append_array(_side_problems(2, s2, require_buckets))
	_chk(side_bad.is_empty(), "%s 每点在自己半区%s%s" % [
			label, "且 3×3 每桶 ≥1" if require_buckets else "(非 PvP 图不强制 3×3)",
			"" if side_bad.is_empty() else "(问题: %s)" % ", ".join(side_bad)])
	# 去掉什么才红:写进墙里/水里/孤立单格/不可达 ⇒ 本条红(点必须过 SpawnPicker 判据)。
	var bad: Array[String] = []
	bad.append_array(_bad_points(s1))
	bad.append_array(_bad_points(s2))
	_chk(bad.is_empty(), "%s 每点过 SpawnPicker 判据(地板+抬头 2 格+不孤立+可抵达)%s" % [
			label, "" if bad.is_empty() else "(不合格: %s)" % ", ".join(bad)])
	# 去掉什么才红:数据里有不可达点(头顶空气不在主可达区)⇒ 本条红。★ 本轮用户实报的"封闭空间复活点"就靠这条。
	var unreachable := 0
	for c in s1:
		if not SpawnPicker.is_reachable_spawn(c):
			unreachable += 1
	for c in s2:
		if not SpawnPicker.is_reachable_spawn(c):
			unreachable += 1
	_chk(unreachable == 0, "%s 每个复活点头顶空气属于主可达区(不可达 %d 个)" % [label, unreachable])
	# 去掉什么才红:两点贴在一起(同侧最小距 < 5)⇒ 本条红。
	_chk(_min_pair_dist(s1) >= MIN_SIDE_GAP and _min_pair_dist(s2) >= MIN_SIDE_GAP,
			"%s 同侧两两 ≥%d(实测 %d / %d)" % [label, MIN_SIDE_GAP, _min_pair_dist(s1), _min_pair_dist(s2)])


func _checks_map_data(path: String, is_pvp: bool) -> void:
	_sides_ok(_map_label(path), _sides(), is_pvp)
	if is_pvp:
		var sp := MapFormat.load_spawns(path)
		# 去掉什么才红:删掉 # player / # player2 行 ⇒ 本条红(MapCatalog 的 PvP 图校验与老图回退都读这两个旧键)。
		_chk(sp.get("player", Vector2i(-1, -1)).x >= 0 and sp.get("player2", Vector2i(-1, -1)).x >= 0,
				"%s 旧键 # player / # player2 保留(向后兼容)" % _map_label(path))


func _checks_duel(pvp_map: String) -> void:
	var d := SpawnPicker.grid_dims()
	var sides := _sides()
	var h := MatchHost.new(pvp_map, {1: 20001, 2: 20002})
	add_child(h)
	var p1 := _cell_of(h.state.players[1])
	var p2 := _cell_of(h.state.players[2])
	# 去掉什么才红:1v1 从全图/固定两点取 ⇒ 两人不一定各在自己半区 / 不在数据里 ⇒ 本条红。
	_chk(SpawnChooser.side_of(p1, d) == 1 and SpawnChooser.side_of(p2, d) == 2
			and (sides[1] as Array).has(p1) and (sides[2] as Array).has(p2) and p1 != p2,
			"⑥ 1v1 首次:role1 在侧 1(左半)/ role2 在侧 2(右半),都取自地图数据")
	# 复活/局内重摆:仍在本方半区,且排除自己的上一次位置。
	var new1 := h._spawn_cell(1)
	var new2 := h._spawn_cell(2)
	_chk(SpawnChooser.side_of(new1, d) == 1 and (sides[1] as Array).has(new1) and new1 != p1
			and SpawnChooser.side_of(new2, d) == 2 and (sides[2] as Array).has(new2) and new2 != p2,
			"⑦ 1v1 复活:仍在本方半区且排除上一次位置(%s→%s / %s→%s)" % [
					str(p1), str(new1), str(p2), str(new2)])
	# 换边:role1 去侧 2、role2 去侧 1(去掉 _side_swap 对侧判定的影响 ⇒ 本条红)。
	h.state._side_swap = true
	var swap1 := h._spawn_cell(1)
	var swap2 := h._spawn_cell(2)
	_chk(SpawnChooser.side_of(swap1, d) == 2 and (sides[2] as Array).has(swap1)
			and SpawnChooser.side_of(swap2, d) == 1 and (sides[1] as Array).has(swap2),
			"⑧ 1v1 换边:role1 ↔ 侧 2、role2 ↔ 侧 1")
	# match_sync 的只读取法:两次调用必须同值(去掉 role_spawns 的只读实现 ⇒ 本条红)。
	var a := h.role_spawns()
	var b := h.role_spawns()
	_chk(a == b and a.get(1, Vector2i(-1, -1)) == swap1, "⑨ role_spawns() 只读且等于最近一次落位")
	h.queue_free()


func _checks_royale() -> void:
	var sides := _sides()
	var union: Array = []
	union.append_array(sides[1])
	union.append_array(sides[2])
	var roles: Array = []
	for i in range(1, 17):
		roles.append(i)
	var plan := RoyaleHost.plan_spawns(roles)
	var cells: Array = []
	for r in plan:
		cells.append(plan[r])
	var uniq := {}
	var left_n := 0
	var right_n := 0
	var in_data := true
	for c in cells:
		uniq[c] = true
		if not union.has(c):
			in_data = false
		if SpawnChooser.side_of(c, SpawnPicker.grid_dims()) == 1:
			left_n += 1
		else:
			right_n += 1
	# 去掉什么才红:大乱斗只取单侧列表 / 走几何生成 ⇒ 出现不在并集里的点或某一侧 0 个点 ⇒ 本条红。
	_chk(cells.size() == 16 and uniq.size() == 16 and in_data and left_n > 0 and right_n > 0,
			"⑩ 大乱斗 16 人:16 个互不相同的点、全部取自两侧并集、左右两侧都有(左 %d / 右 %d)"
			% [left_n, right_n])
	# 复活:从并集里选,且排除本 role 上一次位置(空局面只剩 last 排除在起作用)。
	var first_point: Vector2i = union[0]
	var last := {1: first_point}
	var respawn := RoyaleSpawn.respawn_cell(1, {}, {}, last, union)
	_chk(respawn.x >= 0 and respawn != last[1] and union.has(respawn),
			"⑪ 大乱斗复活:取自并集且排除上一次(%s→%s)" % [str(last[1]), str(respawn)])


func _checks_team() -> void:
	var d := SpawnPicker.grid_dims()
	var sides := _sides()
	var team_of := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
	var first := TeamHost.plan_team_spawns(team_of, {}, false)
	var side_ok := true
	var uniq := {}
	for role in first:
		var c: Vector2i = first[role]
		uniq[c] = true
		if int(team_of[int(role)]) == 1:
			side_ok = side_ok and SpawnChooser.side_of(c, d) == 1 and (sides[1] as Array).has(c)
		else:
			side_ok = side_ok and SpawnChooser.side_of(c, d) == 2 and (sides[2] as Array).has(c)
	# 去掉什么才红:对抗不按队取侧 / 用几何生成 ⇒ 本条红。
	_chk(first.size() == 6 and uniq.size() == 6 and side_ok,
			"⑫ 对抗开局:队 1 取侧 1、队 2 取侧 2,6 人互不相同且都取自地图数据")
	var second := TeamHost.plan_team_spawns(team_of, first, true)
	var swap_ok := true
	var no_repeat := true
	for role in second:
		var c: Vector2i = second[role]
		if int(team_of[int(role)]) == 1:
			swap_ok = swap_ok and SpawnChooser.side_of(c, d) == 2 and (sides[2] as Array).has(c)
		else:
			swap_ok = swap_ok and SpawnChooser.side_of(c, d) == 1 and (sides[1] as Array).has(c)
		if c == first.get(int(role), Vector2i(-1, -2)):
			no_repeat = false
	# 去掉什么才红:换边不换侧 ⇒ 本条红;last 排除删掉 ⇒ 6 人在 9 点里重随机、概率与上一局同位。
	_chk(swap_ok and no_repeat, "⑬ 对抗换边:两队换用另一侧点集,且每人都不与上一局同位")
	# 局内复活:仍在本队这一局所在侧,且排除本 role 上一次位置(去掉 respawn_cell 的侧/ last 参数 ⇒ 本条红)。
	var fp: Vector2i = first[1]
	var last := {1: fp}
	var respawn := TeamSpawn.respawn_cell(1, {}, team_of, last, sides, false)
	_chk(respawn.x >= 0 and respawn != last[1] and SpawnChooser.side_of(respawn, d) == 1
			and (sides[1] as Array).has(respawn),
			"⑭ 对抗局内复活:仍在本方半区且排除上一次(%s→%s)" % [str(last[1]), str(respawn)])


func _cell_of(node: Node2D) -> Vector2i:
	return Vector2i(int(node.global_position.x) / GameParameters.TILE_SIZE,
			int(node.global_position.y) / GameParameters.TILE_SIZE)


func _finish() -> void:
	if _expected < EXPECTED_CHECKS:
		_fails.append("★ 动态条数闸 %d < 基线 %d —— 地图或断言面缩水了" % [_expected, EXPECTED_CHECKS])
	if _checks != _expected:
		_fails.append("★ 实跑 %d 条断言,与动态条数闸 %d 对不上(有断言被静默跳过?)"
				% [_checks, _expected])
	print("[map-spawn] checks = %d (动态闸 = %d / 基线 %d)" % [_checks, _expected, EXPECTED_CHECKS])
	if _fails.is_empty():
		print(MARKER)
		get_tree().quit(0)
	else:
		print("MAP SPAWN DATA PROBE: FAIL")
		for f in _fails:
			print("[map-spawn]   ✗ ", f)
		get_tree().quit(1)
