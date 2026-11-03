extends SceneTree

# 地图「按阵营半区的复活点」数据(`# respawn <1|2> <col> <row>`)的校验 / 建议 / 写盘工具。

const MIN_PER_SIDE := 5      # 每侧最少点数(对抗每队最多 5 人 ⇒ 够 5 人取点且不重复的前提)
const BUCKETS := 9           # 半区内 3 列 × 3 行
const MIN_SIDE_GAP := 5      # 同侧两两最小环面距离(格)

var _fails: Array[String] = []


func _initialize() -> void:
	var opt := _parse_args(OS.get_cmdline_user_args())
	if opt.has("error"):
		print("MAP SPAWN META: FAIL —— ", opt["error"])
		print(_usage())
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
	var is_pvp := MapFormat.load_spawns(map_path).has("player2")
	var dims := SpawnPicker.grid_dims()
	var sizes := SpawnPicker.reachable_component_sizes()
	var top: Array = []
	for i in mini(5, sizes.size()):
		top.append(int(sizes[i]))
	print("MAP SPAWN META: %s(%d×%d 格;侧 1 = 左半 x<%d / 侧 2 = 右半;可达主区 %d 个可站格;分量 %d 个,前几大 %s)" % [
			map_path, dims.x, dims.y, dims.x / 2, SpawnPicker.main_reachable_size(),
			sizes.size(), str(top)])
	if bool(opt.get("list", false)):
		_list(dims)
	if opt.has("inspect"):
		_inspect(_parse_cells(str(opt["inspect"])))
	if bool(opt.get("suggest", false)):
		_suggest(dims, int(opt.get("side", 0)))
	var has_lists := opt.has("respawn1") or opt.has("respawn2")
	var r1: Array = _parse_cells(str(opt.get("respawn1", "")))
	var r2: Array = _parse_cells(str(opt.get("respawn2", "")))
	if has_lists:
		_check_side(1, r1, dims, is_pvp)
		_check_side(2, r2, dims, is_pvp)
	elif bool(opt.get("check", false)):
		var raw: Dictionary = MapFormat.load_spawns(map_path).get("respawns", {})
		_check_side(1, raw.get(1, []), dims, is_pvp)
		_check_side(2, raw.get(2, []), dims, is_pvp)
	if bool(opt.get("write", false)) and has_lists and _fails.is_empty():
		_write(map_path, r1, r2)
	if _fails.is_empty():
		print("MAP SPAWN META: OK")
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("MAP SPAWN META: FAIL(%d 处)" % _fails.size())
		quit(1)


func _usage() -> String:
	return "用法:-- --map <res://maps/*.cyrm> [--check] [--suggest --side 1|2] [--list] [--inspect \"x,y;...\"] " \
			+ "[--respawn1 \"x,y;...\"] [--respawn2 \"x,y;...\"] [--write]"


func _parse_args(args: PackedStringArray) -> Dictionary:
	var opt := {}
	var i := 0
	while i < args.size():
		var a := args[i]
		if a == "--check":
			opt["check"] = true
		elif a == "--write":
			opt["write"] = true
		elif a == "--list":
			opt["list"] = true
		elif a == "--suggest":
			opt["suggest"] = true
		elif a in ["--map", "--inspect", "--respawn1", "--respawn2", "--side"]:
			if i + 1 >= args.size():
				opt["error"] = "%s 缺参数" % a
				return opt
			i += 1
			opt[a.substr(2)] = args[i]
		else:
			opt["error"] = "未知参数 %s" % a
			return opt
		i += 1
	if opt.has("side"):
		opt["side"] = int(opt["side"])
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


# 合格判据的唯一实现(校验 / 建议共用):返回失败原因;空串 = 合格。
# 判据全部来自 SpawnPicker(不另造几何):地板格(本格空 + 正下方挡路 + 头顶 1 格净空)+ 头顶 2 格净空
# + **可抵达**(跳跃感知图的主连通分量,防四面是墙的小密室 —— 上一轮"连通区 ≥2"挡不住它)。
func _bad_reason(c: Vector2i) -> String:
	var d := SpawnPicker.grid_dims()
	if c.x < 0 or c.y < 0 or c.x >= d.x or c.y >= d.y:
		return "越界(图 %d×%d)" % [d.x, d.y]
	if not SpawnPicker.floor_cells_has(c):
		return "不是地板格(需本格空 + 正下方是墙 + 头顶 1 格空)"
	var grid := MazeGenerator.current_grid
	if int(grid[posmod(c.y - 2, d.y)][c.x]) != MazeGenerator.EMPTY:
		return "头顶净空不足 2 格"
	if not SpawnPicker.is_reachable_spawn(c):
		return "不可抵达(不在跳跃感知图的主可达区:封闭空间 / 跳/落/爬都到不了)"
	return ""


func _check_side(side: int, arr: Array, dims: Vector2i, is_pvp: bool) -> void:
	if arr.size() < MIN_PER_SIDE:
		_fails.append("侧 %d 只有 %d 个点(要求 ≥%d)" % [side, arr.size(), MIN_PER_SIDE])
	var buckets := {}
	var bad := 0
	for raw in arr:
		var c: Vector2i = raw
		var why := _bad_reason(c)
		if why != "":
			_fails.append("侧 %d 点 %s 不合格: %s" % [side, str(c), why])
			bad += 1
			continue
		if SpawnChooser.side_of(c, dims) != side:
			_fails.append("侧 %d 点 %s 不在自己半区(侧 1 = 左半 x<%d)" % [side, str(c), dims.x / 2])
			bad += 1
			continue
		if not SpawnChooser.side_inside_margin(c, side, dims):
			_fails.append("侧 %d 点 %s 贴半区边界(要求离接缝/中线都 ≥%d 格)" % [
					side, str(c), SpawnChooser.SIDE_EDGE_MARGIN])
			bad += 1
			continue
		buckets[SpawnChooser.bucket_of(c, side, dims)] = true
	# 3×3 桶覆盖只对 PvP 图(有 # player2)强制:单机 demo 图的多房间主可达区只覆盖部分桶,无法满足也无法用于 PvP。
	if bad == 0 and is_pvp:
		for b in BUCKETS:
			if not buckets.has(b):
				_fails.append("侧 %d 的 3×3 桶 #%d 没有点(均匀判据:每桶 ≥1)" % [side, b])
	var min_gap := _min_pair_dist(arr)
	if arr.size() >= 2 and min_gap < MIN_SIDE_GAP:
		_fails.append("侧 %d 两两最小距离 %d < %d" % [side, min_gap, MIN_SIDE_GAP])
	print("  侧 %d: %d 个点 / 桶覆盖 %d/9%s / 最小两两距 %d" % [
			side, arr.size(), buckets.size(), "" if is_pvp else "(非 PvP 图,不强制)", min_gap])


func _list(dims: Vector2i) -> void:
	for side in [1, 2]:
		var pool := _side_pool(side, dims)
		print("  侧 %d 合格格 %d 个(判据 = 地板 + 头顶 2 格 + 连通区 ≥2)" % [side, pool.size()])
		for c in pool:
			print("  %d,%d" % [int(c.x), int(c.y)])


func _inspect(arr: Array) -> void:
	for raw in arr:
		var c: Vector2i = raw
		print("  inspect %s: 侧 %d / %s" % [str(c), SpawnChooser.side_of(c, SpawnPicker.grid_dims()),
				"合格" if _bad_reason(c) == "" else _bad_reason(c)])


func _side_pool(side: int, dims: Vector2i) -> Array:
	var out: Array = []
	for y in dims.y:
		for x in dims.x:
			var c := Vector2i(x, y)
			if SpawnChooser.side_of(c, dims) != side:
				continue
			if not SpawnChooser.side_inside_margin(c, side, dims):
				continue
			if _bad_reason(c) == "":
				out.append(c)
	return out


# 均匀撒点建议:每个 3×3 桶挑 1 个「离已选点最远」的合格格(贪心最远点、确定性)——天然均匀且互不靠近。
# ★ 只打印、不写盘:确认后用同一串坐标 `--respawn1/--respawn2` 写死进地图(数据仍是人手确认的固定值)。
func _suggest(dims: Vector2i, only_side: int) -> void:
	for side in [1, 2]:
		if only_side != 0 and only_side != side:
			continue
		var pool := _side_pool(side, dims)
		var picked: Array = []
		for b in BUCKETS:
			var best := Vector2i(-1, -1)
			var best_score := -1
			for c in pool:
				if SpawnChooser.bucket_of(c, side, dims) != b or picked.has(c):
					continue
				var score := 1 << 30 if picked.is_empty() else _min_dist_to(c, picked, dims)
				if score > best_score:
					best_score = score
					best = c
			if best.x >= 0:
				picked.append(best)
		var parts: Array = []
		for c in picked:
			parts.append("%d,%d" % [int(c.x), int(c.y)])
		print("  侧 %d 建议(%d 点,最小两两距 %d): %s" % [
				side, picked.size(), _min_pair_dist(picked), ";".join(parts)])


func _min_dist_to(c: Vector2i, picked: Array, dims: Vector2i) -> int:
	var best := 1 << 30
	for p in picked:
		best = mini(best, GridPathfinder.toroidal_dist(c, p, dims.x, dims.y))
	return best


func _min_pair_dist(arr: Array) -> int:
	var d := SpawnPicker.grid_dims()
	var best := 1 << 30
	for i in range(arr.size()):
		for j in range(i + 1, arr.size()):
			best = mini(best, GridPathfinder.toroidal_dist(arr[i], arr[j], d.x, d.y))
	return best if arr.size() >= 2 else 0


func _write(map_path: String, r1: Array, r2: Array) -> void:
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
	var kept: Array = []
	for line in lines:
		var parts := String(line).strip_edges().substr(1).strip_edges().split(" ", false)
		var kw := parts[0] if not parts.is_empty() else ""
		if kw in ["respawn", "spawn", "teamspawn"]:   # 本轮管理的关键字(旧两轮的 # spawn / # teamspawn 一并清掉)
			continue
		kept.append(line)
	for c in r1:
		kept.append("# respawn 1 %d %d" % [int(c.x), int(c.y)])
	for c in r2:
		kept.append("# respawn 2 %d %d" % [int(c.x), int(c.y)])
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
	_verify_written(map_path, grid_before, r1, r2)


func _verify_written(map_path: String, grid_before: Array, r1: Array, r2: Array) -> void:
	var reload: Dictionary = MapFormat.load_spawns(map_path).get("respawns", {})
	if not _same_cells(reload.get(1, []), r1) or not _same_cells(reload.get(2, []), r2):
		_fails.append("回读 # respawn 与写入值不一致")
	var grid_after := MapFormat.load_map_file(map_path)
	if grid_after.size() != grid_before.size():
		_fails.append("回读网格行数变了(%d→%d):层块被改写?" % [grid_before.size(), grid_after.size()])
		return
	for y in range(grid_before.size()):
		if grid_before[y] != grid_after[y]:
			_fails.append("回读网格第 %d 行与写入前不同:层块被改写?" % y)
			return
	print("  已写入 %s(侧 1 = %d 点 / 侧 2 = %d 点;场景层逐格未变)" % [map_path, r1.size(), r2.size()])


func _same_cells(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true
