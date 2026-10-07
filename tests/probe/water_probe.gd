extends SceneTree
# 水体环境逻辑冒烟测试：
# 验证水体瓦片解析、水域判定、水下浸没深度计算、子弹水下阻力衰减与水下爆炸伤害衰减机制。
# 运行方式："$GODOT" --headless --path . -s res://tests/probe/water_probe.gd
# 验收标准：测试通过输出 WATER OK 并退出码为 0。以 -s 运行独立脚本时 Autoload 尚未实例化，代码中不得引用 Autoload 节点。

var _failed := false
func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failed = true
		push_error("FAIL: " + msg)
func _check_eq(a, b, msg: String) -> void:
	if a != b:
		_failed = true
		push_error("FAIL: %s (got %s want %s)" % [msg, a, b])
func _check_approx(a: float, b: float, tol: float, msg: String) -> void:
	if absf(a - b) > tol:
		_failed = true
		push_error("FAIL: %s (got %s want %s)" % [msg, a, b])

func _init() -> void:
	MazeGenerator.current_grid = _make_grid()
	TileDefs.load_defs()

	# cyrm v3 地图格式：纹理编号 3 位十六进制 (0xx) + 形状掩码 1 位十六进制 (水体纹理 21/22)
	var wrow := MapFormat.serialize_v3_grid([[MazeGenerator.pack(21, 15), MazeGenerator.pack(22, 15), 0]])
	_check_eq(wrow[0], "021F022F0000", "v3 序列化水:021F/022F/空气")
	_check_eq(MapFormat.parse_v3_grid(["021F"])[0][0], MazeGenerator.pack(21, 15), "v3 解析水:021F->pack(21,15)")
	_check_eq(TileDefs.type_of(21), "liquid", "tex21 type liquid")
	_check_approx(TileDefs.explosion_decay_of(21), 0.25, 1e-6, "tex21 decay 0.25")
	_check_approx(TileDefs.explosion_decay_of(15), TileDefs.explosion_decay(), 1e-6, "落叶回落全局 0.75")

	# 水体边界与浸没状态判定（测试网格：第 5 行为完整水体，第 6 行为实体墙）
	var surf := Vector2(5 * 64 + 32, 5 * 64 + 32)
	_check(Water.is_in_water(surf), "水格判水")
	_check(not Water.is_in_water(Vector2(5 * 64 + 32, 4 * 64 + 32)), "水面上方不是水")
	_check_eq(Water.surface_y_at(Vector2(5 * 64 + 32, 5 * 64 + 32)), 5 * 64, "水面线=第5行顶")
	_check_eq(Water.surface_y_at(Vector2(5 * 64 + 32, 4 * 64 + 32)), 4 * 64 + 32, "不在水里回传 pos.y")
	_check(Water.submerged(Vector2(5 * 64 + 32, 6 * 64), 5 * 64), "中心在水面线下=没顶")
	_check(not Water.submerged(Vector2(5 * 64 + 32, 5 * 64), 5 * 64), "中心在水面线=浮着不算")

	# 子弹水下速度阻力衰减计算
	var f := Water.bullet_drag_factor(true, 2.0, 0.1)
	_check_approx(f, exp(-0.2), 1e-4, "水中阻力 exp(-0.2)")
	_check_approx(Water.bullet_drag_factor(false, 2.0, 0.1), 1.0, 1e-6, "岸上无阻力")

	# 爆炸伤害衰减：目标处于水体中倍率为 0.25，陆地倍率为 1.0
	var g := MazeGenerator.current_grid
	_check_approx(Water.water_mult(Vector2(5 * 64 + 32, 5 * 64 + 32), g), 0.25, 1e-6, "目标在水里 ×0.25")
	_check_approx(Water.water_mult(Vector2(5 * 64 + 32, 4 * 64 + 32), g), 1.0, 1e-6, "目标在岸上 ×1.0")

	if _failed:
		quit(1)
	else:
		print("WATER OK")
		quit(0)

# 构建 10×10 测试网格：第 5 行为水体瓦片（纹理 21，完整形状），第 6 行为实体碰撞墙，其余为空气。
func _make_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(10):
		var row: Array[int] = []
		for x in range(10):
			if y == 5:
				row.append(MazeGenerator.pack(21, 15))
			elif y == 6:
				row.append(MazeGenerator.SOLID)
			else:
				row.append(MazeGenerator.EMPTY)
		grid.append(row)
	return grid
