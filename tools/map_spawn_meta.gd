extends SceneTree

# 地图出生点数据(`# spawn` / `# teamspawn`)的校验 / 建议 / 写盘工具。★ 与游戏侧共用 SpawnPicker 判据 + MapFormatV4 编解码,
# 不另造一套几何。地图文件才是出生点的真相源:本工具只把**人手挑好**的固定坐标写进 meta,不替你生成点。
#
#   "$GODOT" --headless --path . -s res://tools/map_spawn_meta.gd -- --map res://maps/newfactory.cyrm --list
#   "$GODOT" --headless --path . -s res://tools/map_spawn_meta.gd -- --map res://maps/newfactory.cyrm \
#       --suggest 16 --clearance 25                       # 只打印候选建议(*不写盘*)
#   "$GODOT" --headless --path . -s res://tools/map_spawn_meta.gd -- --map res://maps/newfactory.cyrm \
#       --spawn "38,84;113,84;..." --team1 "..." --team2 "..." --write
# 判据:每个点必须满足所选档的地板 / 抬头 / 同层连通区门槛,且至少 MIN_SPAWN_POINTS 个。
# --write 之后自动回读校验:出生点列表等于写入值、场景层网格逐格与写入前相同(层块字节无损)。

const MIN_SPAWN_POINTS := 5
const MIN_TEAM_POINTS := 5
const FAR_CHECK := 15        # 1v1 两人最小环面距离(SpawnPicker.FAR_CELLS 的当前值;工具侧只在报告里用)
const PAIR_SEEDS := 32

# 数据合格判据的两个档(都与运行时 SpawnPicker 同一套判据,不另造几何):
#   roomy  = spawn_candidates()(地板 + 头顶 2 格 + 左右邻格空 + 同层连通区 ≥ area_threshold)
#   floor2 = 地板 + 头顶 2 格 + 同层连通区 ≥ area_threshold(放宽"左右邻格" —— PvP 图的手写出生点常是 1~2 格宽的站位)
const TIER_ROOMY := "roomy"
const TIER_FLOOR2 := "floor2"

var _fails: Array[String] = []


func _initialize() -> void:
	var opt := _parse_args(OS.get_cmdline_user_args())
	if opt.has("error"):
		print("MAP SPAWN META: FAIL —— ", opt["error"])
		print(_usage())
		quit(1)
		return
	var tier := str(opt.get("tier", TIER_ROOMY))
	if tier != TIER_ROOMY and tier != TIER_FLOOR2:
		print("MAP SPAWN META: FAIL —— 未知 --tier %s(只认 roomy / floor2)" % tier)
		quit(1)
		return
	var map_path := str(opt.get("map", ""))
	MazeGenerator.set_map_file(map_path)
	# 不用 WorldBuilder.load_grid():它静态引用 GameParameters(autoload),在 `-s` 下编译不过。本工具只需要格级网格。
	var grid := MazeGenerator.load_map_file()
	if grid.is_empty():
		print("MAP SPAWN META: FAIL —— 地图加载失败 %s" % map_path)
		quit(1)
		return
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()
	SpawnPicker.reset_cache()
	var dims := SpawnPicker.grid_dims()
	print("MAP SPAWN META: %s(%d×%d 格,tier=%s)" % [map_path, dims.x, dims.y, tier])
	if bool(opt.get("list", false)):
		_list(tier)
	if int(opt.get("suggest", 0)) > 0:
		_suggest(dims, int(opt["suggest"]), int(opt.get("clearance", FAR_CHECK)),
				int(opt.get("half", 0)), tier)
	if opt.has("inspect"):
		_inspect(_parse_cells(str(opt["inspect"])))
	var spawn_arg := str(opt.get("spawn", ""))
	var t1 := _parse_cells(str(opt.get("team1", "")))
	var t2 := _parse_cells(str(opt.get("team2", "")))
	var spawns := _parse_cells(spawn_arg)
	if spawn_arg.is_empty() and t1.is_empty() and t2.is_empty():
		quit(0 if _fails.is_empty() else 1)
		return
	_validate("spawn", spawns, MIN_SPAWN_POINTS, tier)
	if not t1.is_empty() or not t2.is_empty():
		_validate("team1", t1, MIN_TEAM_POINTS, tier)
		_validate("team2", t2, MIN_TEAM_POINTS, tier)
		_check_team_lists(t1, t2)
	_check_spawn_pairing(spawns)
	if bool(opt.get("write", false)) and _fails.is_empty():
		_write(map_path, spawns, t1, t2)
	if _fails.is_empty():
		print("MAP SPAWN META: OK")
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("MAP SPAWN META: FAIL(%d 处)" % _fails.size())
		quit(1)


func _usage() -> String:
	return "用法:-- --map <res://maps/*.cyrm> [--tier roomy|floor2] [--list] [--inspect \"x,y;...\"] " \
			+ "[--suggest N --clearance C --half 1|2] [--spawn \"x,y;...\"] [--team1 \"...\"] [--team2 \"...\"] [--write]"


func _parse_args(args: PackedStringArray) -> Dictionary:
	var opt := {}
	var i := 0
	while i < args.size():
		var a := args[i]
		if a == "--list":
			opt["list"] = true
		elif a == "--write":
			opt["write"] = true
		elif a in ["--map", "--tier", "--inspect", "--spawn", "--team1", "--team2",
				"--suggest", "--clearance", "--half"]:
			if i + 1 >= args.size():
				opt["error"] = "%s 缺参数" % a
				return opt
			i += 1
			opt[a.substr(2)] = args[i]
		else:
			opt["error"] = "未知参数 %s" % a
			return opt
		i += 1
	for k in ["suggest", "clearance", "half"]:
		if opt.has(k):
			opt[k] = int(opt[k])
	if str(opt.get("map", "")).is_empty():
		opt["error"] = "缺 --map"
	return opt


func _parse_cells(text: String) -> Array:
	var out: Array = []
	if text.strip_edges().is_empty():
		return out
	for piece in text.split(";", false):
		var p := piece.strip_edges()
		if p.is_empty():
			continue
		var xy := p.split(",", false)
		if xy.size() != 2 or not xy[0].is_valid_int() or not xy[1].is_valid_int():
			_fails.append("坐标格式非法: \"%s\"(应为 x,y)" % p)
			continue
		var c := Vector2i(int(xy[0]), int(xy[1]))
		if out.has(c):
			_fails.append("坐标重复: %s" % str(c))
			continue
		out.append(c)
	return out


# 合格判据的唯一实现(校验 / 建议 / 探测三处共用):返回失败原因;空串 = 合格。
func _bad_reason(c: Vector2i, tier: String) -> String:
	var d := SpawnPicker.grid_dims()
	if c.x < 0 or c.y < 0 or c.x >= d.x or c.y >= d.y:
		return "越界(图 %d×%d)" % [d.x, d.y]
	if not SpawnPicker.floor_cells_has(c):
		return "不是地板格(需本格空 + 正下方是墙)"
	var grid := MazeGenerator.current_grid
	var y1 := posmod(c.y - 1, d.y)
	var y2 := posmod(c.y - 2, d.y)
	if int(grid[y1][c.x]) != MazeGenerator.EMPTY or int(grid[y2][c.x]) != MazeGenerator.EMPTY:
		return "头顶净空不足 2 格"
	var sz := int(SpawnPicker.region_sizes().get(c, 0))
	if sz < SpawnPicker.area_threshold():
		return "同层连通区 %d < 门槛 %d(死角)" % [sz, SpawnPicker.area_threshold()]
	if tier == TIER_ROOMY and not SpawnPicker.roomy_floor(c):
		return "左右邻格不空(roomy 档要求 ≥3 格宽)"
	return ""


func _pool(tier: String) -> Array:
	if tier == TIER_ROOMY:
		return SpawnPicker.spawn_candidates()
	var out: Array = []
	for c in SpawnPicker.floor_cells():
		if _bad_reason(c, tier) == "":
			out.append(c)
	return out


func _list(tier: String) -> void:
	var pool := _pool(tier)
	print("  地板格 %d / 合格池 %d(门槛 area_threshold=%d)" % [
			SpawnPicker.floor_cells().size(), pool.size(), SpawnPicker.area_threshold()])
	for c in pool:
		print("  %d,%d" % [int(c.x), int(c.y)])


func _suggest(dims: Vector2i, n: int, clearance: int, half: int, tier: String) -> void:
	var pool: Array = _pool(tier).duplicate()
	if half == 1 or half == 2:
		var filt: Array = []
		for c in pool:
			var left := int(c.x) < dims.x / 2
			if (half == 1 and left) or (half == 2 and not left):
				filt.append(c)
		pool = filt
	var picked := GridPathfinder.spread_cells(pool, n, clearance, dims.x, dims.y)
	var parts: Array = []
	for c in picked:
		parts.append("%d,%d" % [int(c.x), int(c.y)])
	print("  建议(clearance=%d%s, tier=%s): %s" % [clearance,
			"" if half == 0 else ", half=%d" % half, tier, ";".join(parts)])


func _inspect(arr: Array) -> void:
	for c in arr:
		var cv: Vector2i = c
		print("  inspect %s: %s" % [str(cv), "合格" if _bad_reason(cv, TIER_FLOOR2) == ""
				else _bad_reason(cv, TIER_FLOOR2)])


func _validate(label: String, arr: Array, min_n: int, tier: String) -> void:
	if arr.size() < min_n:
		_fails.append("%s 只有 %d 个点(要求 ≥%d)" % [label, arr.size(), min_n])
	for raw in arr:
		var c: Vector2i = raw
		var why := _bad_reason(c, tier)
		if why != "":
			_fails.append("%s %s 不合格: %s" % [label, str(c), why])
	print("  %s: %d 个点,最小两两环面距离 %d" % [label, arr.size(), _min_pair_dist(arr)])


func _check_team_lists(t1: Array, t2: Array) -> void:
	for c in t1:
		if t2.has(c):
			_fails.append("点 %s 同时出现在两队列表里" % str(c))
	var min_cross := _cross_min(t1, t2)
	var max_in := maxi(_max_pair_dist(t1), _max_pair_dist(t2))
	print("  teamspawn: 跨队最小距 %d / 队内最大距 %d(要求 跨 > 内)" % [min_cross, max_in])
	if min_cross <= max_in:
		_fails.append("两队点集不够分开:跨队最小距 %d <= 队内最大距 %d" % [min_cross, max_in])


# 1v1:地图列表必须真的能选出两个相距 ≥ FAR_CHECK 的点(多轮抽样;任何一轮都不能靠"放宽"到不达标)。
func _check_spawn_pairing(arr: Array) -> void:
	var dims := SpawnPicker.grid_dims()
	var rng := RandomNumberGenerator.new()
	var bad := 0
	for s in PAIR_SEEDS:
		rng.seed = 1000 + s
		var picked := SpawnChooser.pick_many(arr, 2, rng, FAR_CHECK, dims)
		if picked.size() < 2 or GridPathfinder.toroidal_dist(picked[0], picked[1], dims.x, dims.y) < FAR_CHECK:
			bad += 1
	if bad > 0:
		_fails.append("1v1 抽样: %d/%d 轮拿不到相距 ≥%d 的一对" % [bad, PAIR_SEEDS, FAR_CHECK])
	print("  1v1 抽样: %d/%d 轮拿到相距 ≥%d 的一对" % [PAIR_SEEDS - bad, PAIR_SEEDS, FAR_CHECK])


func _min_pair_dist(arr: Array) -> int:
	var d := SpawnPicker.grid_dims()
	var best := 1 << 30
	for i in range(arr.size()):
		for j in range(i + 1, arr.size()):
			best = mini(best, GridPathfinder.toroidal_dist(arr[i], arr[j], d.x, d.y))
	return best if arr.size() >= 2 else 0


func _max_pair_dist(arr: Array) -> int:
	var d := SpawnPicker.grid_dims()
	var best := 0
	for i in range(arr.size()):
		for j in range(i + 1, arr.size()):
			best = maxi(best, GridPathfinder.toroidal_dist(arr[i], arr[j], d.x, d.y))
	return best


func _cross_min(t1: Array, t2: Array) -> int:
	var d := SpawnPicker.grid_dims()
	var best := 1 << 30
	for a in t1:
		for b in t2:
			best = mini(best, GridPathfinder.toroidal_dist(a, b, d.x, d.y))
	return best


func _write(map_path: String, spawns: Array, t1: Array, t2: Array) -> void:
	var f := FileAccess.open(map_path, FileAccess.READ)
	if f == null:
		_fails.append("打不开 %s" % map_path)
		return
	var raw := f.get_buffer(int(f.get_length()))
	f.close()
	var parsed := MapFormatV4.parse(raw)
	if not bool(parsed.get("ok", false)):
		_fails.append("v4 解析失败: %s" % str(parsed.get("error", "?")))
		return
	var grid_before := MapFormat.load_map_file(map_path)
	var lines: Array = parsed["meta_lines"]
	if not lines.is_empty() and String(lines[lines.size() - 1]) == "":
		lines.pop_back()
	var manage_teams := not t1.is_empty() or not t2.is_empty()
	var kept: Array = []
	for line in lines:
		var parts := String(line).strip_edges().substr(1).strip_edges().split(" ", false)
		var kw := parts[0] if not parts.is_empty() else ""
		if kw == "spawn":
			continue
		if manage_teams and kw == "teamspawn":
			continue
		kept.append(line)
	for c in spawns:
		kept.append("# spawn %d %d" % [int(c.x), int(c.y)])
	for c in t1:
		kept.append("# teamspawn 1 %d %d" % [int(c.x), int(c.y)])
	for c in t2:
		kept.append("# teamspawn 2 %d %d" % [int(c.x), int(c.y)])
	var out := MapFormatV4.replace_meta(raw, kept)
	if out.is_empty():
		_fails.append("replace_meta 失败(文件不是可写的 v4 / 校验不过)")
		return
	var w := FileAccess.open(map_path, FileAccess.WRITE)
	if w == null:
		_fails.append("写不开 %s" % map_path)
		return
	w.store_buffer(out)
	w.close()
	_verify_written(map_path, grid_before, spawns, t1, t2)


func _verify_written(map_path: String, grid_before: Array, spawns: Array, t1: Array, t2: Array) -> void:
	var reload := MapFormat.load_spawns(map_path)
	if not _same_cells((reload.get("spawns", []) as Array), spawns):
		_fails.append("回读 # spawn 与写入值不一致")
	var teams: Dictionary = reload.get("teamspawns", {})
	if not t1.is_empty() and not _same_cells(teams.get(1, []), t1):
		_fails.append("回读 # teamspawn 1 与写入值不一致")
	if not t2.is_empty() and not _same_cells(teams.get(2, []), t2):
		_fails.append("回读 # teamspawn 2 与写入值不一致")
	var grid_after := MapFormat.load_map_file(map_path)
	if grid_after.size() != grid_before.size():
		_fails.append("回读网格行数变了(%d→%d):层块被改写?" % [grid_before.size(), grid_after.size()])
		return
	for y in range(grid_before.size()):
		if grid_before[y] != grid_after[y]:
			_fails.append("回读网格第 %d 行与写入前不同:层块被改写?" % y)
			return
	print("  已写入 %s(spawn %d / team1 %d / team2 %d;场景层逐格未变)" % [
			map_path, spawns.size(), t1.size(), t2.size()])


func _same_cells(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true
