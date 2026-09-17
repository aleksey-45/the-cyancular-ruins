extends SceneTree

# 解卡(向上挤)冒烟:对齐贴墙不算卡 / 最小位移 / 嵌墙 / 上方也堵 / 空网格。
# 跑法: timeout 60 "$GODOT" --headless --path . -s res://tests/unstick_smoke.gd
# 通过 = `UNSTICK OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 最容易错的一条是**"正贴着墙/地"不得判为卡住**:TileQuery 的格范围是
#   floori(rect.end / ts) 且**含端点**,一个正好 64 宽、正好对齐格线的矩形会多算进
#   右边那一列 —— 若那一列是墙,它每帧都会"解卡"往上弹一下(而且不报错)。
#   `PROBE_INSET` 内缩就是为了这条。

const TS := 64

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


# rows×cols 的网格:默认全空,再把 solid_rows 里的行填成实心砖。
# ★ 必须用**带类型**的 Array[Array] / Array[int]:MazeGenerator.current_grid 是
#   `static var current_grid: Array[Array]`,把无类型的 Array 赋给它会在运行期报类型错。
#   同款写法见 tests/beam_trace_smoke.gd 的 _make_grid。
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
	# ★ 空载守卫:load() 失败还往下走会抛错,而 -s 抛错走不到 quit() → 永久挂起
	if U == null:
		print("UNSTICK FAILED: 找不到 core/sim/unstick.gd")
		quit(1)
		return
	TileDefs.load_defs()   # is_blocked 依赖属性表,不自带惰性加载

	# ── ① 正踩在地板上沿(600..640,地板行 10 从 640 起)→ 不卡 ──
	MazeGenerator.current_grid = _grid(20, 20, [10])
	var resting := Rect2(300.0, 600.0, 40.0, 40.0)
	_check(U.push_up_dy(resting, TS) == 0.0,
			"正踩在地板上沿不得判为卡住(实际 %f)" % U.push_up_dy(resting, TS))

	# ── ② 正好 64 宽、正好对齐格线地嵌在 1 格宽竖井里(左右都是墙)→ 不卡 ──
	# 竖井 = 第 5 列(x 320..384)。矩形 x 320..384:不加内缩时 floori(384/64)=6
	# 会把第 6 列(实心)也算进去 → 误判成卡住。这一条专门钉内缩。
	var shaft := _grid(20, 20, [])
	for y in range(20):
		shaft[y][4] = MazeGenerator.SOLID
		shaft[y][6] = MazeGenerator.SOLID
	MazeGenerator.current_grid = shaft
	var in_shaft := Rect2(320.0, 320.0, 64.0, 64.0)
	_check(U.push_up_dy(in_shaft, TS) == 0.0,
			"正好对齐并贴着竖井两侧墙不得判为卡住(实际 %f)" % U.push_up_dy(in_shaft, TS))

	# ── ③ 压进地板 20px → **刚好**擦出去 20px(不是整格 64)──
	MazeGenerator.current_grid = _grid(20, 20, [10])
	var sunk := Rect2(300.0, 620.0, 40.0, 40.0)     # 620..660,地板行 10 = 640..704
	_check(absf(U.push_up_dy(sunk, TS) - 20.0) < 0.01,
			"压进地板 20px 应上移 20px(实际 %f)" % U.push_up_dy(sunk, TS))

	# ── ④ 嵌在 8/9/10 三行实心里 → 推到最上行(8)的上边 ──
	# 矩形 500..540:覆盖行 7、8;最上实心行 = 8 → 位移 = 540 - 8*64 = 28
	MazeGenerator.current_grid = _grid(20, 20, [8, 9, 10])
	var buried := Rect2(300.0, 500.0, 40.0, 40.0)
	_check(absf(U.push_up_dy(buried, TS) - 28.0) < 0.01,
			"嵌墙时推到最上实心行的上边(实际 %f)" % U.push_up_dy(buried, TS))

	# ── ⑤ 全实心 → 迭代到上限仍返回累计值,不崩不挂 ──
	MazeGenerator.current_grid = _grid(20, 20, range(0, 20))
	var dy_all: float = U.push_up_dy(resting, TS)
	_check(dy_all > 0.0, "全实心时也应有位移(实际 %f)" % dy_all)

	# ── ⑥ 空网格 → 0(TileQuery 的空网格语义:一律"没压到东西")──
	var empty: Array[Array] = []
	MazeGenerator.current_grid = empty
	_check(U.push_up_dy(sunk, TS) == 0.0, "空网格应返回 0")

	if _fail == 0:
		print("UNSTICK OK")
		quit(0)
	else:
		print("UNSTICK FAILED: %d" % _fail)
		quit(1)
