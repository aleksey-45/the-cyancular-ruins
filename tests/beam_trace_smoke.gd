extends SceneTree

# BeamTrace 纯几何冒烟:验证即时光束追踪的反射/吸收/射程收尾(无需完整游戏)。
# 用法:godot --headless --path . -s res://tests/beam_trace_smoke.gd
# 注意:直接 preload BeamTrace(无 class_name,避免 -s 全局类缓存依赖);只依赖
# MazeGenerator/TileDefs(均不引 autoload),可安全在 -s 阶段空跑。
# 网格取 20 列宽:保证撞墙反弹后剩余射程不因环面回绕再撞同一面墙(测试收尾干净)。

const BeamTrace := preload("res://core/beam_trace.gd")

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _init() -> void:
	TileDefs.load_defs()
	# ── 无墙:射程到界空停 ──
	MazeGenerator.current_grid = _make_grid(20, 6)
	var r1 := BeamTrace.trace(Vector2(150, 150), Vector2.RIGHT, 500.0, 2)
	var p1: PackedVector2Array = r1["points"]
	_check(p1.size() == 2, "无墙 2 点(起+止)")
	_check(absf(p1[1].x - 650.0) < 0.01 and absf(p1[1].y - 150.0) < 0.01, "无墙止于射程末端")

	# ── 单墙反射:竖墙 col1(像素 x 64..128),从右往左打 → 撞墙反弹后飞向空旷 ──
	var grid := _make_grid(20, 6)
	for y in range(6):
		grid[y][1] = MazeGenerator.SOLID
	MazeGenerator.current_grid = grid
	var r2 := BeamTrace.trace(Vector2(150, 150), Vector2.LEFT, 1000.0, 2)
	var p2: PackedVector2Array = r2["points"]
	var c2: Array = r2["contacts"]
	_check(p2.size() == 3, "单墙反弹 3 点(起+墙+空旷止)")
	_check(p2[1] == Vector2(128, 150), "反射点在墙表面 x=128")
	_check(p2[2].x > 128.0, "反射后继续向右(离开墙面)")
	_check(c2.size() == 1 and c2[0] == Vector2i(1, 2), "接触格 = 墙格 (1,2)")

	# ── 双墙夹道:col1+col3(夹 col2),反弹一次打回,第 3 次碰墙被吸收停住 ──
	for y in range(6):
		grid[y][3] = MazeGenerator.SOLID  # col3(x 192..256)
	MazeGenerator.current_grid = grid
	# 从 col2(x128..192)中间往左打:碰 col1(128)反→碰 col3(192)反→再碰 col1(128)吸收
	var r3 := BeamTrace.trace(Vector2(150, 150), Vector2.LEFT, 10000.0, 2)
	var p3: PackedVector2Array = r3["points"]
	var c3: Array = r3["contacts"]
	var h3: PackedVector2Array = r3["hit_points"]
	_check(p3.size() == 4, "夹道内折返 4 点(起+3碰墙)")
	_check(p3[1] == Vector2(128, 150) and p3[2] == Vector2(192, 150) and p3[3] == Vector2(128, 150),
			"折返轨迹 128→192→128")
	_check(c3.size() == 3, "3 次碰墙触点")
	_check(h3.size() == c3.size(), "hit_points 与 contacts 平行")
	_check(h3[0] == Vector2(128, 150) and h3[1] == Vector2(192, 150), "hit_points 为墙面落点")

	MazeGenerator.current_grid = _make_grid(20, 6)
	if _failures.is_empty():
		print("SMOKE OK")
		quit(0)
	else:
		printerr("SMOKE FAILURES: " + str(_failures.size()))
		quit(1)

func _make_grid(cols: int, rows: int) -> Array[Array]:
	var g: Array[Array] = []
	for y in range(rows):
		var row: Array[int] = []
		row.resize(cols)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	return g
