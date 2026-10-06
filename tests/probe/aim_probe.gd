extends SceneTree

# 复刻 _aim_world_dir + _clamped_aim_dir + _sample_arc_points + _disk_overlaps_solid,
# 用真实常数(窗口1920×1440 / SubViewport2496×1872 / crop=0.769 / cam_zoom=0.75 /
# cam_y_bias=-100 / 榴弹 speed1100 g=0.45×1600 pitch_clamp=60°)在纯开阔带(只有地板)里,
# 扫不同鼠标位置,看弧线在哪截断。

const WIN := Vector2(1920, 1440)
const VP := Vector2(2496, 1872)
const ZOOM := 0.75
const BIAS_Y := -100.0
const SPEED := 1100.0
const GRAV := 0.45 * 1600.0
const DT := 1.0 / 60.0
const RANGE := 2500.0
const PITCH := 60.0
const TS := 64

func _initialize() -> void:
	# 纯开阔:50×50,除 y>=40 为地板(SOLID)外全 EMPTY
	var grid: Array[Array] = []
	for _y in range(50):
		var row: Array[int] = []
		row.resize(50)
		row.fill(MazeGenerator.EMPTY)
		grid.append(row)
	for x in range(50):
		for y in range(40, 50):
			grid[y][x] = MazeGenerator.SOLID
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()

	# 地板在 y=40*64=2560;让枪口离地 27px(与真实探针一致)
	var muzzle := Vector2(25 * TS + 32 + 2.5 * 31.0, 40 * TS - 27.0)
	var player := Vector2(muzzle.x - 2.5 * 31.0, muzzle.y - 2.5 * 8.0)
	var rows := grid.size()
	var cols := grid[0].size()
	print("玩家 %s 枪口 %s 枪口距地板 %.0fpx" % [player, muzzle, (40 * TS) - muzzle.y])

	# 细扫鼠标位置:屏幕中线 720,玩家在屏上 ~y=820
	var mouse_rows: Array[float] = []
	for my in range(640, 1450, 20):
		mouse_rows.append(float(my))
	for my in mouse_rows:
		for mx in [900.0, 1100.0, 1500.0]:
			var dir := _aim_dir(mx, my)
			var ang := rad_to_deg(dir.angle())
			var res := _trace(muzzle, dir, grid, cols, rows)
			print("鼠标(%4.0f,%4.0f) 方向角%+6.1f° → 截断 %s" % [mx, my, ang, res])

	quit(0)

# 复刻 _auto_aim 的 facing 判定 + _clamped_aim_dir 的 clamp 与还原。
func _aim_dir(mx: float, my: float) -> Vector2:
	var cam_center := Vector2(0, BIAS_Y)  # 相对玩家原点的相机偏移
	var world_mouse := cam_center + (Vector2(mx, my) - WIN * 0.5) / ZOOM  # 相机 zoom 换算
	var dir := world_mouse - Vector2.ZERO  # origin=player(原点)
	if dir.length_squared() < 0.0001:
		return Vector2.RIGHT
	dir = dir.normalized()
	# _auto_aim:鼠标明显偏一侧 → 朝向翻转
	var facing := 1
	if absf(dir.x) > 0.1:
		facing = 1 if dir.x > 0.0 else -1
	var local := Vector2(dir.x * facing, dir.y)
	var pitch := clampf(local.angle(), deg_to_rad(-PITCH), deg_to_rad(PITCH))
	var loc := Vector2.from_angle(pitch)
	return Vector2(loc.x * facing, loc.y)

func _trace(muzzle: Vector2, dir: Vector2, grid: Array, cols: int, rows: int) -> String:
	var p := muzzle
	var v := dir * SPEED
	var g := GRAV
	var t := 0.0
	var steps := 0
	var escape := _disk(muzzle, grid, cols, rows)
	var reason := "preview_time(3s)"
	while t < 3.0:
		v.y += g * DT
		p += v * DT
		t += DT
		steps += 1
		if escape and p.distance_to(muzzle) < float(TS):
			continue
		if _disk(p, grid, cols, rows):
			reason = "判墙(地板)"
			break
		if p.distance_to(muzzle) >= RANGE:
			reason = "超射程"
			break
	return "第%d步 t=%.2fs 距离%.0fpx → %s" % [steps, t, p.distance_to(muzzle), reason]

func _disk(center: Vector2, grid: Array, cols: int, rows: int) -> bool:
	var r := 4.0 * 1.5
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
