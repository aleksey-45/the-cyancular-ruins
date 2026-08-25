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
