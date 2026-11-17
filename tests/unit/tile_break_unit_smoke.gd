extends SceneTree


const EXPECTED_CHECKS := 11
const CELLS := 16
const LEAF := 15
const CENTER := Vector2(504, 504)

var _fails: Array[String] = []
var _checks := 0
var _destroyed_cells: Array[Vector2i] = []


func _initialize() -> void:
	TileDefs.load_defs()

	var script: GDScript = load("res://scenes/weapons/bullet_base.gd")
	if script == null:
		_chk(false, "load bullet_base.gd 失败(-s 空载守卫:不 quit 会挂死)")
		_finish()
		return
	var probe_bullet: Node = script.new()
	var default_ok: bool = is_equal_approx(float(probe_bullet.get("tile_break_unit")), 1.0) \
			and bool(probe_bullet.call("_tile_break_is_cell"))
	probe_bullet.set("tile_break_unit", 0.25)
	var quarter_ok: bool = not bool(probe_bullet.call("_tile_break_is_cell"))
	probe_bullet.set("tile_break_unit", 0.5)
	var half_ok: bool = not bool(probe_bullet.call("_tile_break_is_cell"))
	probe_bullet.free()
	_chk(default_ok and quarter_ok and half_ok, "默认 1.0 走整格;0.25/0.5 走子格(_tile_break_is_cell 边界)")

	# 代理判据:读场景文本(不是行为)——`.tscn` 的 `tile_break_unit` 覆盖值就是数据契约本身;
	# 在 `-s` 里实例化 grenade_bullet 会连带 preload autoload 依赖,代价高于收益。行为证据见 tests/scene/bullet_pool_probe 与榴弹命中探针。
	var grenade_txt := FileAccess.get_file_as_string("res://scenes/weapons/grenade_bullet.tscn")
	var bullet_txt := FileAccess.get_file_as_string("res://scenes/weapons/bullet.tscn")
	_chk(grenade_txt.contains("tile_break_unit = 0.5") and not bullet_txt.contains("tile_break_unit"),
			"场景:grenade_bullet=0.5(32px) / bullet.tscn 未覆盖(其余枪 = 1.0)")

	_reset_world()
	var cell := Vector2i(7, 7)
	var destroyed := TileDefs.damage_tile(cell, 8, "bullet")
	_chk(destroyed and MazeGenerator.current_grid[cell.y][cell.x] == 0 \
			and TileDefs.hp_grid_at(cell) == 0 and _alive_subs(cell) == 0, "整格一次命中:16 子格全清、两本账归 0")

	_reset_world()
	var sub := Vector2i(cell.x * 4, cell.y * 4)
	var block := Vector2i(cell.x * 2, cell.y * 2)
	var n_dmg := TileDefs.damage_block32(block, 8, "bullet")
	_chk(n_dmg == 4 and MazeGenerator.current_grid[cell.y][cell.x] != 0 \
			and TileDefs.hp_grid_at(cell) == 8 and _alive_subs(cell) == 12,
			"1/2 格一次命中:清 2×2 子格(4 个)、格级账不动(8)、余 12")

	_reset_world()
	var survived := not TileDefs.damage_sub(sub, 3, "bullet")
	_chk(survived and _sub_hp(sub) == 5 and _destroyed_cells.is_empty(), "未致死:子格 8→5,无销毁回调")

	_reset_world()
	TileDefs.damage_sub(sub, 99, "bullet")
	_chk(_sub_hp(sub) == 0, "溢出:子格血量钳到 0")

	_reset_world()
	for sy in 4:
		for sx in 4:
			TileDefs.damage_sub(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy), 8, "bullet")
	_chk(MazeGenerator.current_grid[cell.y][cell.x] == 0 and TileDefs.hp_grid_at(cell) == 0,
			"两本账对齐:子格路径清空整格时 hp_grid 同步归 0")

	_reset_world()
	var subs_before := Explosion.destructible_subs(CENTER, 100.0)
	var covered_cells := _unique_cells(subs_before)
	Explosion.damage_tiles(CENTER, 100.0, 1000, null, 1.0)
	_chk(_destroyed_cells.size() == covered_cells.size() and covered_cells.size() > 1
			and covered_cells.size() < subs_before.size(),
			"爆炸整格:按格去重(格数 %d < 子格数),每格只扣一次" % [_destroyed_cells.size()])

	# ⑪ 已摧毁子格不再计入"爆炸可破坏集"(subgrid 纹理摧毁后不变,必须查 sub_hp):
	#   否则爆炸会给已经被打碎的树叶再播一遍碎片(用户实见)。去掉什么才红:destructible_subs 只查 tex。
	_reset_world()
	var before2 := Explosion.destructible_subs(CENTER, 60.0)
	Explosion.damage_tiles(CENTER, 60.0, 1000, null, 0.25)
	var after2 := Explosion.destructible_subs(CENTER, 60.0)
	var all_alive := true
	for e in after2:
		if TileDefs.sub_hp_at(e["sub"]) <= 0:
			all_alive = false
	_chk(before2.size() > after2.size() and all_alive,
			"已摧毁子格不进爆炸可破坏集(炸过的树叶不再出第二遍碎片)")

	_reset_world()
	var alive_before := _alive_subs_all()
	Explosion.damage_tiles(CENTER, 60.0, 1000, null, 0.5)
	var dead := alive_before - _alive_subs_all()
	var grid_ok := (TileDefs.hp_grid_at(cell) == 8) == (_alive_subs(cell) > 0)
	_chk(_block_uniform() and dead > 0 and dead % 4 == 0 and grid_ok,
			"爆炸 1/2 格(32px):块内 4 子格同生共死、死亡子格 %d = 4×块数、格级账只在整格全灭时归 0" % dead)

	_reset_world()
	Explosion.damage_tiles(CENTER, 100.0, 4, null, 1.0)
	_chk(TileDefs.hp_grid_at(cell) == 5 and _min_sub_hp() == 8 and _destroyed_cells.is_empty(),
			"爆炸整格部分损伤:hp_grid 8→5、sub_hp 不动")

	_finish()


func _reset_world() -> void:
	var grid: Array[Array] = []
	var sgrid: Array[Array] = []
	for y in CELLS:
		var row: Array[int] = []
		row.resize(CELLS)
		row.fill(MazeGenerator.pack(LEAF, 15))
		grid.append(row)
	for y in CELLS * 4:
		var srow: Array[int] = []
		srow.resize(CELLS * 4)
		srow.fill(LEAF)
		sgrid.append(srow)
	MazeGenerator.current_grid = grid
	MazeGenerator.current_subgrid = sgrid
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(sgrid)
	TileDefs.on_destroyed = Callable(self, "_on_cell_destroyed")
	TileDefs.on_sub_destroyed = Callable()
	_destroyed_cells.clear()


func _block_uniform() -> bool:
	for by in CELLS * 2:
		for bx in CELLS * 2:
			var dead := 0
			for sy in 2:
				for sx in 2:
					if TileDefs.sub_hp_at(Vector2i(bx * 2 + sx, by * 2 + sy)) <= 0:
						dead += 1
			if dead > 0 and dead < 4:
				return false
	return true


func _alive_subs_all() -> int:
	var n := 0
	for sy in CELLS * 4:
		for sx in CELLS * 4:
			if TileDefs.sub_hp_at(Vector2i(sx, sy)) > 0:
				n += 1
	return n


func _on_cell_destroyed(c: Vector2i) -> void:
	_destroyed_cells.append(c)
	TileDefs.destroy_cell(c)


func _alive_subs(cell: Vector2i) -> int:
	var n := 0
	for sy in 4:
		for sx in 4:
			if TileDefs.sub_alive(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)):
				n += 1
	return n


func _sub_hp(sub: Vector2i) -> int:
	return int(TileDefs.sub_hp[sub.y * TileDefs.sub_cols + sub.x])


func _min_sub_hp() -> int:
	var best := 999
	for v in TileDefs.sub_hp:
		best = mini(best, int(v))
	return best


func _unique_cells(subs: Array) -> Dictionary:
	var uniq: Dictionary = {}
	for e in subs:
		var s: Vector2i = e["sub"]
		uniq[Vector2i(s.x / 4, s.y / 4)] = true
	return uniq


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _finish() -> void:
	# 条数闸:实跑条数对不上 = 有断言被静默跳过(脚本错误只中断当前函数,不会让进程红)。
	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("TILE BREAK UNIT OK(%d 条断言):整格/32px 块/两本账/爆炸分派/场景值" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("TILE BREAK UNIT FAILED: %d 处" % _fails.size())
		quit(1)
