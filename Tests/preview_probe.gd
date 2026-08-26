extends SceneTree

# 诊断:预瞄弧线截断位置探查。
# 在真实地图上复刻 _sample_arc_points + _disk_overlaps_solid,
# 从出生点枪口沿多个方向采样,打印每步落点所在格、是否判墙、以及截断原因/距离。

const TS: int = 64
const SPEED: float = 1100.0
const GRAV: float = 0.45 * 1600.0  # bullet_gravity * gravity0
const DT: float = 1.0 / 60.0
const RANGE: float = 2500.0
const DISC_R: float = 4.0 * 1.5    # PREVIEW_COLLISION_RADIUS * bullet_size

func _initialize() -> void:
	MazeGenerator._picked_map = "res://map/demo.cyrm"
	var grid: Array[Array] = MazeGenerator.load_map_file()
	if grid.is_empty():
		printerr("地图加载失败")
		quit(1)
		return
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()

	var rows := grid.size()
	var cols := grid[0].size()
	var spawn := _find_spawn(grid)
	print("地图 %d×%d,出生格 %s" % [cols, rows, spawn])
	if spawn.x < 0:
		printerr("无出生格")
		quit(1)
		return

	var player_pos := Vector2(spawn.x * TS + TS / 2.0, spawn.y * TS + TS / 2.0)
	# 武器挂在 WeaponSlot(玩家原点),枪口本地 (31,8),玩家 scale 2.5 → 世界偏移
	var muzzle := player_pos + Vector2(2.5 * 31.0, 2.5 * 8.0)
	var muzzle_cell := MazeGenerator.cell_of(muzzle, TS, cols, rows)
	var mc_v: int = grid[muzzle_cell.y][muzzle_cell.x]
	print("玩家世界坐标 %s,枪口世界 %s" % [player_pos, muzzle])
	print("枪口所在格 %s,格值 %d,is_blocked=%s" %
			[muzzle_cell, mc_v, TileDefs.is_blocked(mc_v)])
	print("")

	# 以枪口为中心盘查它周围 3×3(含判墙盘逻辑覆盖范围,保守放大)
	var blocked_neighbors: Array[Vector2i] = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := Vector2i(posmod(muzzle_cell.x + dx, cols), posmod(muzzle_cell.y + dy, rows))
			if TileDefs.is_blocked(grid[c.y][c.x]):
				blocked_neighbors.append(c)
	if blocked_neighbors.is_empty():
		print("枪口周围 3×3 无墙格 → 开阔,起点不可能立即截断")
	else:
		print("枪口周围 3×3 有墙格: " + str(blocked_neighbors))
	print("")

	var angles: Array[float] = [0.0, 15.0, 30.0, 45.0, 60.0, -30.0, -60.0]
	for a in angles:
		var dir := Vector2.RIGHT.rotated(deg_to_rad(a))
		_trace(muzzle, dir, a, grid, cols, rows)

	# ── 全图扫描:每个可站立格(EMPTY 且下方 SOLID)作为玩家中心,算枪口世界坐标,
	# 统计枪口判墙(6px 盘)的格子占比 —— 枪口插墙/贴墙会导致弧线起点即断。──
	var walkable: int = 0
	var degenerate: int = 0
	var examples: Array[String] = []
	for y in range(rows):
		for x in range(cols):
			if grid[y][x] != MazeGenerator.EMPTY:
				continue
			if y + 1 >= rows or grid[y + 1][x] == MazeGenerator.EMPTY:
				continue  # 不是地板(脚下无支撑),跳过
			walkable += 1
			var pcenter := Vector2(x * TS + TS / 2.0, y * TS + TS / 2.0)
			for facing in [1, -1]:
				var muzz := pcenter + Vector2(2.5 * 31.0 * facing, 2.5 * 8.0)
				if _disk_overlaps_solid(muzz, grid, cols, rows):
					degenerate += 1
					if examples.size() < 5:
						examples.append("玩家格(%d,%d) 面向%s 枪口(%d,%d)" %
								[x, y, "右" if facing > 0 else "左",
								int(muzz.x / TS), int(muzz.y / TS)])
					break  # 任一面插墙即算
	print("")
	print("全图可站立格 %d,其中枪口判墙(起点即断)格 %d (%.1f%%)" %
			[walkable, degenerate, 100.0 * degenerate / maxf(walkable, 1)])
	for e in examples:
		print("  例: " + e)

	quit(0)

# 复刻 _sample_arc_points 的采样 + _disk_overlaps_solid,打印截断位置与原因。
func _trace(muzzle: Vector2, dir: Vector2, ang: float,
		grid: Array, cols: int, rows: int) -> void:
	var v := dir * SPEED
	var p := muzzle
	var g := GRAV
	var t := 0.0
	var steps := 0
	var stop_reason := "preview_time(3.0s)"
	while t < 3.0:
		v.y += g * DT
		p += v * DT
		t += DT
		steps += 1
		if _disk_overlaps_solid(p, grid, cols, rows):
			stop_reason = "判墙"
			break
		if p.distance_to(muzzle) >= RANGE:
			stop_reason = "超射程"
			break
	var cell := MazeGenerator.cell_of(p, TS, cols, rows)
	var cell_v: int = grid[cell.y][cell.x]
	print("仰角 %+4.0f°: 截断于第 %3d 步(t=%.2fs,距离 %.0fpx,格 %s 值 %d) → %s" %
			[ang, steps, t, p.distance_to(muzzle), cell, cell_v, stop_reason])

func _disk_overlaps_solid(center: Vector2, grid: Array, cols: int, rows: int) -> bool:
	var r := DISC_R
	var min_c := MazeGenerator.cell_of(center - Vector2(r, r), TS, cols, rows)
	var max_c := MazeGenerator.cell_of(center + Vector2(r, r), TS, cols, rows)
	var span_x := max_c.x - min_c.x
	if span_x < 0:
		span_x += cols
	var span_y := max_c.y - min_c.y
	if span_y < 0:
		span_y += rows
	for dy in range(span_y + 1):
		var y := posmod(min_c.y + dy, rows)
		for dx in range(span_x + 1):
			var x := posmod(min_c.x + dx, cols)
			if TileDefs.is_blocked(grid[y][x]):
				return true
	return false

func _find_spawn(grid: Array) -> Vector2i:
	var path := MazeGenerator.map_file_path()
	var f := FileAccess.open(path, FileAccess.READ)
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	f.close()
	var meta := MazeGenerator.parse_spawn_metadata(lines)
	if meta.has("player"):
		return meta["player"]
	# 兜底:第一个空格
	for y in range(grid.size()):
		for x in range(grid[y].size()):
			if grid[y][x] == MazeGenerator.EMPTY:
				return Vector2i(x, y)
	return Vector2i(-1, -1)
