extends SceneTree

# 实例化真实 Player+武器,读真实 muzzle.global_position,核对网格对齐与 0° 弧线截断。

const TS: int = 64
const SPEED: float = 1100.0
const GRAV: float = 0.45 * 1600.0
const DT: float = 1.0 / 60.0
const RANGE: float = 2500.0

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

	var player = (load("res://scenes/Player/Player.tscn") as PackedScene).instantiate()
	root.add_child(player)
	await physics_frame
	var weapon = player.get("_weapon")
	if weapon == null:
		printerr("武器未装备")
		quit(1)
		return
	var muzzle = weapon.get_node("Muzzle")

	for tag in ["出生点(56,47)", "墙边(97,3)", "开阔(60,47)"]:
		var cell := Vector2i(56, 47)
		if tag.begins_with("墙边"):
			cell = Vector2i(97, 3)
		elif tag.begins_with("开阔"):
			cell = Vector2i(60, 47)
		player.position = Vector2(cell.x * TS + TS / 2.0, cell.y * TS + TS / 2.0)
		player.velocity = Vector2.ZERO
		await physics_frame
		var mg: Vector2 = muzzle.global_position
		var mc := MazeGenerator.cell_of(mg, TS, cols, rows)
		print("")
		print("== %s: 玩家(%d,%d)" % [tag, cell.x, cell.y])
		print("  玩家位置 %s  scale %s" % [player.global_position, player.scale])
		print("  muzzle.local %s  muzzle.global %s" % [muzzle.position, mg])
		print("  手算(player+2.5×local) %s" % (player.global_position + Vector2(2.5 * muzzle.position.x, 2.5 * muzzle.position.y)))
		print("  枪口格 %s 值 %d  blocked=%s" % [mc, grid[mc.y][mc.x], TileDefs.is_blocked(grid[mc.y][mc.x])])
		_trace(mg, Vector2.RIGHT, grid, cols, rows)

	quit(0)

func _trace(muzzle: Vector2, dir: Vector2, grid: Array, cols: int, rows: int) -> void:
	var p := muzzle
	var v := dir * SPEED
	var g := GRAV
	var t := 0.0
	var steps := 0
	var reason := "preview_time"
	# 复刻新逻辑:起点判墙 → 跳过 TILE_SIZE 段
	var escape := _disk(muzzle, grid, cols, rows)
	var skipped := 0
	while t < 3.0:
		v.y += g * DT
		p += v * DT
		t += DT
		steps += 1
		if escape and p.distance_to(muzzle) < float(TS):
			skipped += 1
			continue
		if _disk(p, grid, cols, rows):
			reason = "判墙"
			break
		if p.distance_to(muzzle) >= RANGE:
			reason = "超射程"
			break
	var cell := MazeGenerator.cell_of(p, TS, cols, rows)
	print("  0°弧线: 截断于第 %d 步 t=%.2fs 距离 %.0fpx 格 %s 值 %d → %s" %
			[steps, t, p.distance_to(muzzle), cell, grid[cell.y][cell.x], reason])

func _disk(center: Vector2, grid: Array, cols: int, rows: int) -> bool:
	var r := 4.0 * 1.5  # PREVIEW_COLLISION_RADIUS × bullet_size
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
