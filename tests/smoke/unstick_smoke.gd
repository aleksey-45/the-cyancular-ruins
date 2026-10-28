extends SceneTree

# 角色嵌墙脱困算法冒烟测试：
# 验证实体意外陷入瓦片碰撞体时的渐进向上挤出定位算法。

const TS := 64

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


# 构建 rows×cols 测试网格：默认全空，将 solid_rows 指定行填为实心。
# 使用强类型 Array[Array] 与 Array[int]，避免向 MazeGenerator.current_grid 赋值时触发类型错误。
func _grid(rows: int, cols: int, solid_rows: Array) -> Array[Array]:
	var g: Array[Array] = []
	for y in range(rows):
		var row: Array[int] = []
		row.resize(cols)
		row.fill(MazeGenerator.SOLID if solid_rows.has(y) else MazeGenerator.EMPTY)
		g.append(row)
	return g


func _initialize() -> void:
	var U: GDScript = load("res://core/sim/unstick.gd")
	# 校验脚本加载状态，若加载失败立即退出
	if U == null:
		print("UNSTICK FAILED: 找不到 core/sim/unstick.gd")
		quit(1)
		return
	TileDefs.load_defs()   # is_blocked 依赖属性表,不自带惰性加载

	TileDefs.load_terrain(_grid(20, 20, [10]), [])
	var resting := Rect2(300.0, 600.0, 40.0, 40.0)
	_check(U.push_up_dy(resting, TS) == 0.0,
			"正踩在地板上沿不得判为卡住(实际 %f)" % U.push_up_dy(resting, TS))

	# 竖井 = 第 5 列(x 320..384)。矩形 x 320..384:不加内缩时 floori(384/64)=6
	# 会把第 6 列(实心)也算进去 -> 误判成卡住。这一条专门钉内缩。
	var shaft := _grid(20, 20, [])
	for y in range(20):
		shaft[y][4] = MazeGenerator.SOLID
		shaft[y][6] = MazeGenerator.SOLID
	TileDefs.load_terrain(shaft, [])
	var in_shaft := Rect2(320.0, 320.0, 64.0, 64.0)
	_check(U.push_up_dy(in_shaft, TS) == 0.0,
			"正好对齐并贴着竖井两侧墙不得判为卡住(实际 %f)" % U.push_up_dy(in_shaft, TS))

	TileDefs.load_terrain(_grid(20, 20, [10]), [])
	var sunk := Rect2(300.0, 620.0, 40.0, 40.0)     # 620..660,地板行 10 = 640..704
	_check(absf(U.push_up_dy(sunk, TS) - 20.0) < 0.01,
			"压进地板 20px 应上移 20px(实际 %f)" % U.push_up_dy(sunk, TS))

	# 矩形 500..540:覆盖行 7、8;最上实心行 = 8 -> 位移 = 540 - 8*64 = 28
	TileDefs.load_terrain(_grid(20, 20, [8, 9, 10]), [])
	var buried := Rect2(300.0, 500.0, 40.0, 40.0)
	_check(absf(U.push_up_dy(buried, TS) - 28.0) < 0.01,
			"嵌墙时推到最上实心行的上边(实际 %f)" % U.push_up_dy(buried, TS))

	TileDefs.load_terrain(_grid(20, 20, range(0, 20)), [])
	var dy_all: float = U.push_up_dy(resting, TS)
	_check(dy_all > 0.0, "全实心时也应有位移(实际 %f)" % dy_all)

	var empty: Array[Array] = []
	TileDefs.load_terrain(empty, [])
	_check(U.push_up_dy(sunk, TS) == 0.0, "空网格应返回 0")

	if _fail == 0:
		print("UNSTICK OK")
		quit(0)
	else:
		print("UNSTICK FAILED: %d" % _fail)
		quit(1)
