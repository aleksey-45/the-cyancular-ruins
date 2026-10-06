extends SceneTree

# cyrm v4 子格破坏探针(-s 数据级):选项 A 的核心语义 ——
#   破坏/碰撞按 **16px 子格**算;格级 `current_grid` 在**整格 16 个子格全部死光**时才清零。
# 覆盖:① v4 真图的子格表尺寸与装填;② 子格 HP 初始化;③ 单子格摧毁(碰撞子格随之变空,
#       所属格级网格**保持**非零);④ 全 16 子格死光 → 格级网格清零;⑤ restore_sub 写回。
# (爆炸的子格扫描 `Explosion.destructible_subs` 引用 autoload,-s 编译不了 —— 由场景级
#   探针与实机覆盖;它的几何就是"以爆心为圆心的 16px 子格圆扫"。)
# 用法:godot --headless --path . -s res://tests/probe/subcell_probe.gd

const DEMO := "res://maps/demo.cyrm"

var _fails: Array[String] = []


func _init() -> void:
	TileDefs.load_defs()   # -s 没有 autoload 链路,数据表要显式加载(否则全走缺省:hp1/不可破坏)
	_test_real_subgrid()
	_test_damage_model()
	if _fails.is_empty():
		print("SUBCELL PROBE: OK(子格表装填/子格HP/单子格摧毁不清格/全灭清格/还原)")
		quit(0)
	else:
		print("SUBCELL PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		quit(1)


func _chk(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)


func _test_real_subgrid() -> void:
	var sgrid := MapFormat.load_subgrid(DEMO)
	_chk(not sgrid.is_empty(), "demo 的子格表不应为空")
	if sgrid.is_empty():
		return
	var cell_grid := MapFormat.load_map_file(DEMO)
	# ★ 期望值 = **格级网格维度 × 每格子格数**,不写死 500×300("这张图恰好多大"换图就假红)。
	#   每格子格数取 `CollisionBuilder` 的两个公开尺度常量(格 64px / 子格 16px ⇒ 4),
	#   而不是魔数。期望值取自 `MapFormat.load_map_file`(整图解析)—— 与 `load_subgrid`
	#   **是两条读法**(后者在 v4 下直接吃头部的 sub_cols/sub_rows)⇒ 头部与 body 对不上当场红。
	var per_cell: int = CollisionBuilder.TILE_TS / CollisionBuilder.SUB_TS
	var want := Vector2i.ZERO
	if not cell_grid.is_empty():
		want = Vector2i((cell_grid[0] as Array).size() * per_cell, cell_grid.size() * per_cell)
	_chk(Vector2i((sgrid[0] as Array).size(), sgrid.size()) == want,
			"demo 子格表应 = 格级维度 × %d(期望 %s,实为 %s)"
			% [per_cell, str(want), str(Vector2i((sgrid[0] as Array).size(), sgrid.size()))])
	# 子格表与格级网格必须同源:抽查三格,"格空⇔16 子格全空"
	var ok_pair := true
	for probe in [Vector2i(60, 40), Vector2i(10, 10), Vector2i(100, 60)]:
		var v := int(cell_grid[probe.y][probe.x])
		var sub_count := 0
		for sy in per_cell:
			for sx in per_cell:
				if sgrid[probe.y * per_cell + sy][probe.x * per_cell + sx] != 0:
					sub_count += 1
		if (v == 0) != (sub_count == 0):
			ok_pair = false
	_chk(ok_pair, "子格表与格级网格不同源")


func _test_damage_model() -> void:
	# 合成 3×3 格:中间一格 = 树叶(纹理 15,可爆炸破坏),其余空气
	var grid: Array[Array] = []
	for y in 3:
		var row: Array[int] = []
		row.resize(3)
		grid.append(row)
	grid[1][1] = MazeGenerator.pack(15, 15)
	MazeGenerator.current_grid = grid
	MazeGenerator.current_subgrid = MapFormat.expand_cells_to_subgrid(grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)

	var cell := Vector2i(1, 1)
	var sub0 := Vector2i(4, 4)   # 该格的第一个子格
	# ① 碰撞子格:整格 16 子格都是树叶 → build_sub(可破坏侧)全 SOLID
	var sub := CollisionBuilder.build_sub(grid, true)
	_chk(sub[4][4] == MazeGenerator.SOLID, "树叶格子格应进可破坏碰撞")
	# ② 打死一个子格:碰撞子格变空,但**格级网格保持非零**(其它 15 个还活着)
	_chk(TileDefs.damage_sub(sub0, 9999, "explosion"), "树叶子格应可被爆炸摧毁")
	_chk(not TileDefs.sub_alive(sub0), "被摧毁的子格应不再存活")
	_chk(int(MazeGenerator.current_grid[cell.y][cell.x]) != 0,
			"只死 1 个子格时,格级网格不应清零(选项 A 的核心)")
	var sub2 := CollisionBuilder.build_sub(grid, true)
	_chk(sub2[4][4] == MazeGenerator.EMPTY, "被摧毁子格的碰撞应消失")
	_chk(sub2[5][5] == MazeGenerator.SOLID, "相邻子格的碰撞应保留")
	# ③ 空气子格不可"摧毁"
	_chk(not TileDefs.damage_sub(Vector2i(0, 0), 9999, "explosion"), "空气子格不可摧毁")
	# ④ 全部 16 子格死光 → 格级网格才清零
	for sy in 4:
		for sx in 4:
			TileDefs.damage_sub(Vector2i(4 + sx, 4 + sy), 9999, "explosion")
	_chk(int(MazeGenerator.current_grid[cell.y][cell.x]) == 0,
			"16 个子格全部死光后,格级网格应清零")
	# ⑤ restore_sub 写回(回溯用;格级网格的复活是 level_0 的职责,-s 不验)
	TileDefs.restore_sub(sub0, 3)
	_chk(TileDefs.sub_alive(sub0), "restore_sub 后子格应复活")
	# 清场
	MazeGenerator.current_grid = []
	MazeGenerator.current_subgrid = []
