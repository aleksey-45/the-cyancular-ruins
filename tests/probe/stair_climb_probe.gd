extends ProbeBase

const EXPECTED_CHECKS := 7

const CELL := 16
const COLS := 160
const ROWS := 120
const FLOOR_ROW := 110
const STAIR_X0 := 40
const STAIR_W := 8
const STAIRS := 10

var _player: Node = null
var _body: StaticBody2D = null
var _checks := 0


func probe_id() -> String:
	return "stair_climb"


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	_check(ok, msg)


func _ready() -> void:
	if load("res://scenes/player/player.tscn") == null:
		_chk(false, "★ 空载守卫:load(player.tscn) 为 null")
		_finish()
		return
	var sub: Array[Array] = []
	for y in ROWS:
		var row: Array[int] = []
		row.resize(COLS)
		row.fill(0)
		sub.append(row)
	for y in range(FLOOR_ROW, ROWS):
		for x in COLS:
			sub[y][x] = 1
	for i in STAIRS:
		var top := FLOOR_ROW - (i + 1)
		var x0 := STAIR_X0 + i * STAIR_W
		for y in range(top, ROWS):
			for x in range(x0, COLS):
				sub[y][x] = 1
	MazeGenerator.current_subgrid = sub
	var grid: Array[Array] = []
	for cy in ROWS / 4:
		var crow: Array[int] = []
		for cx in COLS / 4:
			var solid := true
			for dy in 4:
				for dx in 4:
					if int(sub[cy * 4 + dy][cx * 4 + dx]) == 0:
						solid = false
			crow.append(MapFormat.SOLID if solid else MapFormat.EMPTY)
		grid.append(crow)
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()

	_build_collision()

	var ts: PackedScene = load("res://scenes/player/player.tscn")
	_player = ts.instantiate()
	add_child(_player)
	var pn: Node2D = _player as Node2D
	pn.global_position = Vector2(STAIR_X0 * CELL - 200.0, (FLOOR_ROW - 1) * CELL)
	var src := PacketInputSource.new()
	_player.set_input_source(src)
	for _i in 20:
		await get_tree().physics_frame
	var floor_y: float = pn.global_position.y
	var vx_by_frame: Array[float] = []
	var dy_by_frame: Array[float] = []
	var on_floor_frames := 0
	var frames := 0
	var prev: Vector2 = pn.global_position
	while frames < 260:
		src.apply_packet({"ax": 1.0, "held": 0, "pressed": 0, "released": 0})
		await get_tree().physics_frame
		frames += 1
		var p: Vector2 = pn.global_position
		vx_by_frame.append(absf(float((pn as CharacterBody2D).velocity.x)))
		dy_by_frame.append(p.y - prev.y)
		if (pn as CharacterBody2D).is_on_floor():
			on_floor_frames += 1
		prev = p
		if p.x > (STAIR_X0 + STAIRS * STAIR_W) * CELL + 300.0:
			break
	var end_y: float = pn.global_position.y
	var climbed := floor_y - end_y
	var want_climb := float(STAIRS) * CELL
	_chk(climbed >= want_climb - 2.0,
			"① 爬完 %d 级台阶:上升 %.1fpx(至少 %.1f)" % [STAIRS, climbed, want_climb])
	var slow := 0
	for i in vx_by_frame.size():
		if i < 12:
			continue
		if vx_by_frame[i] < 0.5 * PlayerParams.move_speed:
			slow += 1
	_chk(slow == 0, "② ★ 爬台阶期间没有一帧水平速度被吃(0.5×move_speed 以下 %d 帧)" % slow)
	var dt := 1.0 / 60.0
	var expect_dx := PlayerParams.move_speed * dt
	var poor := 0
	for i in dy_by_frame.size():
		if i < 3:
			continue
		var p_now: float = vx_by_frame[i] * dt
		if p_now < expect_dx * 0.9:
			poor += 1
	_chk(poor <= 2, "③ ★ 正常帧位移占 90%%+:掉速帧 %d(≤2;起步/落地各允许 1 帧)" % poor)
	_chk(on_floor_frames >= frames - 3,
			"④ 爬台阶期间踩地 %d/%d 帧(≥ 总帧-3)" % [on_floor_frames, frames])
	var big_drop := 0
	for d in dy_by_frame:
		if float(d) > 2.0:
			big_drop += 1
	_chk(big_drop == 0, "⑤ 没有明显下坠帧(>2px 的下移 %d 帧)" % big_drop)

	var wall_x := STAIR_X0 + STAIRS * STAIR_W + 22
	var wall_top := FLOOR_ROW - STAIRS - StepJump.MAX_STEP_SUBCELLS
	_add_wall(Vector2i(wall_x, wall_top), StepJump.MAX_STEP_SUBCELLS, 8)
	var walk := {"ax": 1.0, "held": 0, "pressed": 0, "released": 0}
	var got_air := false
	for _i in 120:
		src.clear_edges()
		src.apply_packet(walk)
		await get_tree().physics_frame
		if not (pn as CharacterBody2D).is_on_floor():
			got_air = true
			break
	for _i in 3:
		src.clear_edges()
		src.apply_packet(walk)
		await get_tree().physics_frame
	var snap: Dictionary = _player.capture_state()
	var traj_a: Array[Vector4] = []
	var air_a := 0
	for _i in 18:
		src.clear_edges()
		src.apply_packet(walk)
		await get_tree().physics_frame
		traj_a.append(_pose4(pn))
		if not (pn as CharacterBody2D).is_on_floor():
			air_a += 1
	_player.restore_state(snap)
	var traj_b: Array[Vector4] = []
	var air_b := 0
	for _i in 18:
		src.clear_edges()
		src.apply_packet(walk)
		await get_tree().physics_frame
		traj_b.append(_pose4(pn))
		if not (pn as CharacterBody2D).is_on_floor():
			air_b += 1
	var diff := 0
	for i in traj_a.size():
		if traj_a[i] != traj_b[i]:
			diff += 1
	_chk(got_air and air_a == 18 and air_b == 18,
			"⑥ ★ 夹具前置:自动跳离地,且回放窗口整段在空中(第一遍 %d/18、第二遍 %d/18 帧离地)" % [air_a, air_b])
	_chk(diff == 0,
			"⑦ ★ 回放确定性:capture→18 帧→restore→同一串输入重放,逐帧 pos/vel 精确一致(%d 帧不一致)" % diff)

	if _checks != EXPECTED_CHECKS:
		_check(false, "实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上" % [_checks, EXPECTED_CHECKS])
	_finish()


func _add_wall(top_left: Vector2i, cells_high: int, cells_wide: int) -> void:
	var sub := MazeGenerator.current_subgrid as Array
	for y in range(top_left.y, top_left.y + cells_high):
		for x in range(top_left.x, top_left.x + cells_wide):
			sub[y][x] = 1
	var shape := RectangleShape2D.new()
	var w := float(cells_wide * CELL)
	var h := float((ROWS - top_left.y) * CELL)
	shape.size = Vector2(w, h)
	var cs := CollisionShape2D.new()
	cs.shape = shape
	cs.global_position = Vector2(top_left.x * CELL + w * 0.5, top_left.y * CELL + h * 0.5)
	_body.add_child(cs)


func _pose4(p: Node) -> Vector4:
	var body := p as CharacterBody2D
	var n := p as Node2D
	return Vector4(n.global_position.x, n.global_position.y, body.velocity.x, body.velocity.y)


func _build_collision() -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	_body = body
	for i in STAIRS + 1:
		var shape := RectangleShape2D.new()
		var top_row: int
		var x0_cell: int
		if i == 0:
			top_row = FLOOR_ROW
			x0_cell = 0
		else:
			top_row = FLOOR_ROW - i
			x0_cell = STAIR_X0 + (i - 1) * STAIR_W
		var w := float(COLS * CELL - x0_cell * CELL)
		var h := float((ROWS - top_row) * CELL)
		shape.size = Vector2(w, h)
		var cs := CollisionShape2D.new()
		cs.shape = shape
		cs.global_position = Vector2(x0_cell * CELL + w * 0.5, top_row * CELL + h * 0.5)
		body.add_child(cs)
