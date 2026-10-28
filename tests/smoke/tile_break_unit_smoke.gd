extends SceneTree

# 最小破坏单位(tile_break_unit)冒烟(纯逻辑 -s:合成 grid/subgrid,不读地图、不引 autoload)。
# 最强保证:整格单位走格级账(一次清整格 16 子格)、1/4 格单位只清 1 个子格、爆炸按单位分派且整格侧去重、
#   子格路径清空整格时两本账(hp_grid / sub_hp)在"格子已消失"上对齐、榴弹场景确实覆盖为 0.25。
# 测不到什么:实际拆砖手感/粒子观感(人眼)、真地图 cyrm v4 子格数据、网络事件链路(真链路批)。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/tile_break_unit_smoke.gd;通过 = 结尾打 TILE BREAK UNIT OK(n 条断言)。

const EXPECTED_CHECKS := 11
const CELLS := 16          # 16×16 格 = 1024×1024 px(半径 350 内不会有环面重复副本)
const LEAF := 15           # 树叶:hp 8,子弹/爆炸都可破坏
const CENTER := Vector2(504, 504)   # 一个子格中心,距四周都 > radius,扫掠结果可预测

var _fails: Array[String] = []
var _checks := 0
var _destroyed_cells: Array[Vector2i] = []


func _initialize() -> void:
	TileDefs.load_defs()

	# ① 默认单位 = 1 格;helper 的边界(1.0 整格 / 0.25 子格)
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
	probe_bullet.free()
	_chk(default_ok and quarter_ok, "默认 1.0 走整格;0.25 走子格(_tile_break_is_cell 边界)")

	# ② 场景值:榴弹显式 0.25,其余枪用的 bullet.tscn 不覆盖(= 默认 1.0)
	var grenade_txt := FileAccess.get_file_as_string("res://scenes/weapons/grenade_bullet.tscn")
	var bullet_txt := FileAccess.get_file_as_string("res://scenes/weapons/bullet.tscn")
	_chk(grenade_txt.contains("tile_break_unit = 0.25") and not bullet_txt.contains("tile_break_unit"),
			"场景:grenade_bullet=0.25 / bullet.tscn 未覆盖(其余枪 = 1.0)")

	# ③ 整格单位一次命中:格级账扣到 0 ⇒ 整格 16 子格全清 + 格级/子格账同时归 0
	_reset_world()
	var cell := Vector2i(7, 7)
	var destroyed := TileDefs.damage_tile(cell, 8, "bullet")
	_chk(destroyed and MazeGenerator.current_grid[cell.y][cell.x] == 0 \
			and TileDefs.hp_grid_at(cell) == 0 and _alive_subs(cell) == 0, "整格一次命中:16 子格全清、两本账归 0")

	# ④ 1/4 格单位:只清 1 个子格,格级账原样
	_reset_world()
	var sub := Vector2i(cell.x * 4, cell.y * 4)
	var sub_dead := TileDefs.damage_sub(sub, 8, "bullet")
	_chk(sub_dead and MazeGenerator.current_grid[cell.y][cell.x] != 0 \
			and TileDefs.hp_grid_at(cell) == 8 and _alive_subs(cell) == 15,
			"1/4 格一次命中:只清 1 个子格、格级账不动(8)")

	# ⑤ 未致死:扣血但不回调、不触发任何销毁
	_reset_world()
	var survived := not TileDefs.damage_sub(sub, 3, "bullet")
	_chk(survived and _sub_hp(sub) == 5 and _destroyed_cells.is_empty(), "未致死:子格 8→5,无销毁回调")

	# ⑥ 溢出:一次大伤害把子格打到 0(钳位,不出现负血)
	_reset_world()
	TileDefs.damage_sub(sub, 99, "bullet")
	_chk(_sub_hp(sub) == 0, "溢出:子格血量钳到 0")

	# ⑦ 两本账对齐:16 个子格逐个磨死 ⇒ current_grid 与 hp_grid 同一帧都归 0(旧实现只清 grid)
	_reset_world()
	for sy in 4:
		for sx in 4:
			TileDefs.damage_sub(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy), 8, "bullet")
	_chk(MazeGenerator.current_grid[cell.y][cell.x] == 0 and TileDefs.hp_grid_at(cell) == 0,
			"两本账对齐:子格路径清空整格时 hp_grid 同步归 0")

	# ⑧ 爆炸整格分派:每个 64px 格去重后只扣一次(格级账),子格全清
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

	# ⑨ 爆炸子格分派(unit<1):只动 sub_hp,格级账不碰、无格级销毁
	_reset_world()
	Explosion.damage_tiles(CENTER, 60.0, 4, null, 0.25)
	_chk(_destroyed_cells.is_empty() and TileDefs.hp_grid_at(cell) == 8 and _min_sub_hp() < 8,
			"爆炸 1/4 格:只磨 sub_hp(hp_grid 仍 8)、无格级销毁")

	# ⑩ 爆炸整格分派的部分损伤:只动 hp_grid(格级账),sub_hp 不动
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


# 单机 level_0._on_tile_destroyed 的同一收口:清该格 16 个子格(服务器侧走 zero_cell_sub_hp,效果同)。
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
		print("TILE BREAK UNIT OK(%d 条断言):整格/1-4 格/两本账/爆炸分派/场景值" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("TILE BREAK UNIT FAILED: %d 处" % _fails.size())
		quit(1)
