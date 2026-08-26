extends SceneTree
# 水逻辑冒烟。用户自跑:
#   "D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/water_probe.gd
# 成功打印 WATER OK 退出 0。-s 阶段 autoload 未实例化,静态代码不得引 autoload。

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

	# v3 格式:纹理 3 位 0xx + 形状 hex(水 21/22)
	var wrow := MazeGenerator.serialize_v3_grid([[MazeGenerator.pack(21, 15), MazeGenerator.pack(22, 15), 0]])
	_check_eq(wrow[0], "021F022F0000", "v3 序列化水:021F/022F/空气")
	_check_eq(MazeGenerator._parse_v3_grid(["021F"])[0][0], MazeGenerator.pack(21, 15), "v3 解析水:021F->pack(21,15)")
	_check_eq(TileDefs.type_of(21), "liquid", "tex21 type liquid")
	_check_approx(TileDefs.explosion_decay_of(21), 0.25, 1e-6, "tex21 decay 0.25")
	_check_approx(TileDefs.explosion_decay_of(15), TileDefs.explosion_decay(), 1e-6, "落叶回落全局 0.75")

	# Water 判定(合成网格:y=5 整行水,y=6 墙)
	var surf := Vector2(5 * 64 + 32, 5 * 64 + 32)
	_check(Water.is_in_water(surf), "水格判水")
	_check(not Water.is_in_water(Vector2(5 * 64 + 32, 4 * 64 + 32)), "水面上方不是水")
	_check_eq(Water.surface_y_at(Vector2(5 * 64 + 32, 5 * 64 + 32)), 5 * 64, "水面线=第5行顶")
	_check_eq(Water.surface_y_at(Vector2(5 * 64 + 32, 4 * 64 + 32)), 4 * 64 + 32, "不在水里回传 pos.y")
	_check(Water.submerged(Vector2(5 * 64 + 32, 6 * 64), 5 * 64), "中心在水面线下=没顶")
	_check(not Water.submerged(Vector2(5 * 64 + 32, 5 * 64), 5 * 64), "中心在水面线=浮着不算")

	# 子弹水中阻力
	var f := Water.bullet_drag_factor(true, 2.0, 0.1)
	_check_approx(f, exp(-0.2), 1e-4, "水中阻力 exp(-0.2)")
	_check_approx(Water.bullet_drag_factor(false, 2.0, 0.1), 1.0, 1e-6, "岸上无阻力")

	# 爆炸:目标在水里 ×0.25,岸上 ×1.0
	var g := MazeGenerator.current_grid
	_check_approx(Water.water_mult(Vector2(5 * 64 + 32, 5 * 64 + 32), g), 0.25, 1e-6, "目标在水里 ×0.25")
	_check_approx(Water.water_mult(Vector2(5 * 64 + 32, 4 * 64 + 32), g), 1.0, 1e-6, "目标在岸上 ×1.0")

	if _failed:
		quit(1)
	else:
		print("WATER OK")
		quit(0)

# 10×10 合成网格:y=5 整行水(tex21 全砖),y=6 整行实体墙,其余空气。
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
