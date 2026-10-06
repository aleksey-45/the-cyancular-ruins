extends Node

# `MatchHost.destroyed_cells()` 探针(场景模式:root 有 autoload/`multiplayer`)。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/destroyed_cells_probe.tscn
# 通过 = `DESTROYED CELLS: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 这个方法喂的是"重连后补破坏态"的载荷。它算错的表现是**静默**的:客户端少补几格墙
#   (留下幻影墙 → 预测分歧)或多补几格(凭空拆墙)。两种都不报错,只有真比对才照得出来。
# ★ 确定性:顺序必须是"按 y 升序、同 y 按 x 升序",否则同样的地图会给出不同的数组,
#   载荷无法逐字比对(联机侧要能复现)。
# 做法同 match_host_hygiene_probe:真建 MatchHost,但 **role_peers 传空** —— 不建玩家、不排 peer、不发包。

const MAP := "res://maps/newfactory.cyrm"

var _fails: Array[String] = []
var _host = null
# ★ 为什么需要它(实测踩到):`_run()` 里任何**运行期**脚本错误(如调了不存在的方法)会让
#   GDScript 当场从 `_run()` 返回,而 `_ready()` 接着照常调 `_finish()` —— 此时 `_fails` 是空的,
#   探针会**打印 `ALL-OK` 并退出 0**(本任务 Step 3 的真实现象)。这与本仓"判据是 grep ALL-OK"
#   的约定冲突:`ALL-OK` 必须真的意味着"跑完了且全过"。故记一个跑完闩。
var _ran_to_end := false


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_host = MatchHost.new(MAP, {}, {}, [])
	add_child(_host)
	# ★ 关掉宿主自己的物理帧:本探针手工摆 `grid`,不需要它自跑(不关的话 `quit(0)` 是帧末生效,
	#   中间还会跑一帧 `_physics_process` 去读桩对象 → 在断言全过之后刷一屏 SCRIPT ERROR)。
	_host.set_physics_process(false)
	_run()
	_finish()


func _run() -> void:
	var rows: int = _host.grid.size()
	var cols: int = _host.grid[0].size()
	_check(rows > 0 and cols > 0, "宿主建局后有网格(%d×%d)" % [rows, cols])

	# ── ① 未动过 → 空数组 ──
	_check(_host.destroyed_cells().is_empty(), "刚建局的网格差异应为空")

	# ── ② 拆 3 格 → 恰好 3 个,且**顺序确定**(按 y 升序、同 y 按 x 升序)──
	# 故意逆序拆,看返回是否仍按序。
	# ★ 三格必须**保证**在基线里是实心,否则"把空气改成空气"= 零差异,这条断言恒红
	#   (实测:newfactory 的 100×150 网格顶部几行是空气,原样写这三格就是 0 个差异)。
	#   故先在本探针里把基线那三格钉成实心 —— 场景不依赖具体地图内容。
	#   挑 (7,5)/(1,5) 同行(验"同 y 按 x 升序")+ (3,2) 另一行(验"按 y 升序")。
	for c in [Vector2i(7, 5), Vector2i(3, 2), Vector2i(1, 5)]:
		_host._base_grid[c.y][c.x] = MazeGenerator.SOLID
	_host.grid[5][7] = MazeGenerator.EMPTY
	_host.grid[2][3] = MazeGenerator.EMPTY
	_host.grid[5][1] = MazeGenerator.EMPTY
	var d: Array = _host.destroyed_cells()
	_check(d.size() == 3, "拆 3 格应报 3 个(实际 %d)" % d.size())
	# ★ 括号是必需的:`d == [...] as Array` 会被解析成 `(d == [...]) as Array` → 编译期
	#   "Invalid cast. Cannot convert from bool to Array"(整个探针脚本加载失败,连红都跑不出来)。
	# ★ 期望值按 **(y 升序、同 y 按 x 升序)** 写:(3,2) 在 y=2 独行 → 最前;y=5 那行按 x 升序是
	#   (1,5)、(7,5)。别写成按 x 升序的 `[(1,5),(3,2),(7,5)]` —— 那是 x-major,与本方法
	#   (外围 y、内层 x 的双层循环)和契约文字都不符。
	_check(d == ([Vector2i(3, 2), Vector2i(1, 5), Vector2i(7, 5)] as Array),
			"★ 顺序必须是「按 y 升序、同 y 按 x 升序」(实际 %s)" % str(d))

	# ── ③ 反向:只改回一格 → 只剩 2 个(证明它比的是**差异**不是"非实心")──
	_host.grid[2][3] = _host._base_grid[2][3]
	_check(_host.destroyed_cells().size() == 2, "改回一格后应剩 2 个")

	# ── ④ 反向:凭空**加**一格实心(基线是空的地方填实心)也要报 ──
	# ★ 不能只比"当前是不是 EMPTY" —— 服务器理论上不会加砖,但契约是"与基线不同",
	#   写成"当前为空"会在将来加砖时静默漏报。
	var ey := -1
	var ex := -1
	for y in range(rows):
		for x in range(cols):
			if int(_host._base_grid[y][x]) == MazeGenerator.EMPTY and int(_host.grid[y][x]) == MazeGenerator.EMPTY:
				ey = y
				ex = x
				break
		if ey >= 0:
			break
	# ★ 2026-10-02:原先这里是一条恒真的 `_check(ey >= 0, …)`(任何有效地图都有空气格)。
	#   按"说不出真实变异就删"的判据它不该占一条断言 ⇒ 改成**早退报错**:既不占断言数,
	#   又不让下面那条在"前置不成立"时被**静默跳过**(那正是本仓反复在删的形状)。
	if ey < 0:
		_fails.append("地图里找不到基线为空的位置(前置不成立 ⇒ 下面那条无从判)")
		print("  FAIL 地图里找不到基线为空的位置(前置不成立 ⇒ 下面那条无从判)")
	else:
		_host.grid[ey][ex] = MazeGenerator.SOLID
		var d4: Array = _host.destroyed_cells()
		_check(d4.has(Vector2i(ex, ey)), "★ 与基线不同就该报(不管变空还是变实心)(实际 %s)" % str(d4))
		_host.grid[ey][ex] = MazeGenerator.EMPTY

	_ran_to_end = true   # ← 只有走到这里才算"跑完"(见 _finish 的假绿守卫)


func _finish() -> void:
	if not _ran_to_end:
		print("DESTROYED CELLS: FAIL")
		print("  - _run() 没跑完(中途脚本错误?)—— 无失败项的 `ALL-OK` 在这情况下是假绿")
		get_tree().quit(1)
		return
	if _fails.is_empty():
		print("DESTROYED CELLS: ALL-OK")
		get_tree().quit(0)
	else:
		print("DESTROYED CELLS: FAIL")
		for f in _fails:
			print("  - %s" % f)
		get_tree().quit(1)
