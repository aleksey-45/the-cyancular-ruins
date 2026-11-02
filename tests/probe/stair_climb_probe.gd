extends ProbeBase

# 上台阶卡顿探针(用户 2026-11-01 第四轮:「为什么我还是感觉上台阶卡顿」)。
#
# 要钉的是**旧实现的剩余缺陷**:旧的迈台阶是"先撞上台阶(这一帧水平位移被墙吃掉)、下一帧才抬身体",
# 700px/s ≈ 11.7px/帧 ⇒ 每级台阶固定丢一帧位移(顿一下)。新版改成"移动前 test_move 先探这一帧的位移,
# 被矮台阶挡住就先抬到台面、同一帧 move_and_slide 直接迈上去"。
#
# 夹具:合成 16px 子格 + 真实 StaticBody2D 台阶 + 真 player.tscn + PacketInputSource(ax=1 一直向右),
# 逐物理帧记录 velocity.x / 位移 / is_on_floor。
# 最强保证:真实玩家的 `_physics_process`(含 move_and_slide / 姿态切换)在真实碰撞上跑;只量"移动有没有被台阶吃掉"。
# 测不到什么:镜头观感(相机探针另有)、真人按方向键的输入时序、以及经网络预测/回放的观感(需真链路)。
# 去掉什么才红:把 `_try_step_or_jump` 改回"只在 is_on_wall 时抬"(即旧的一帧顿挫)⇒ ②③ 红;
#   把 `apply_floor_snap()` 删掉 ⇒ ④ 红(每级台阶腾空一帧)。
# ★ 2026-11-01(R1):⑤ 之后追加 ⑥⑦ **回放确定性**——夹具另造一格高的墙,走到墙前触发**自动跳**,
#   在跳起的空中窗口 capture_state → 跑 18 帧记轨迹 → restore_state → 用同一串输入重放 18 帧 ⇒ 逐帧 pos/vel 必须**精确相等**。
#   去掉什么才红:把 `_auto_jump_assist`(0.25s 强制满速窗口)加回去 ⇒ ⑦ 红。理由:它不在 `capture_state()` 里,
#   第一遍空中 18 帧把它从 0.25 衰减到 0,`restore_state` 不会把它恢复 ⇒ 第二遍走 `approach_air` 而不是强制满速,
#   横移速度从第 1 帧起就不同(这也正是联机回滚重放分歧的来源)。⑥ 是 ⑦ 的非空转前提(必须真的在空中)。
const EXPECTED_CHECKS := 7

const CELL := 16                      # 子格像素(与游戏一致:TILE_SIZE 64 / SUB_PER_CELL 4)
const COLS := 160
const ROWS := 120
const FLOOR_ROW := 110                # 地板顶面所在子格行(px = 1760)
const STAIR_X0 := 40                  # 第一级台阶起点(子格列)
const STAIR_W := 8                    # 每级台阶宽(子格)= 128px
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
	# 世界尺寸(px):小图、不触发环面回绕
	GameParameters.MAP_WIDTH = COLS * CELL
	GameParameters.MAP_HEIGHT = ROWS * CELL
	var sub: Array[Array] = []
	for y in ROWS:
		var row: Array[int] = []
		row.resize(COLS)
		row.fill(0)
		sub.append(row)
	# 地板
	for y in range(FLOOR_ROW, ROWS):
		for x in COLS:
			sub[y][x] = 1
	# 台阶:第 i 级顶面在 FLOOR_ROW - (i+1) 行,从 STAIR_X0 + i*STAIR_W 往右都是它
	for i in STAIRS:
		var top := FLOOR_ROW - (i + 1)
		var x0 := STAIR_X0 + i * STAIR_W
		for y in range(top, ROWS):
			for x in range(x0, COLS):
				sub[y][x] = 1
	MazeGenerator.current_subgrid = sub
	# 格级网格(64px):4×4 子格全实 ⇒ 该格是实体(其它逻辑如水/姿态会读它)
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

	# 玩家:放在第一级台阶左边的地板上,一直按住右
	var ts: PackedScene = load("res://scenes/player/player.tscn")
	_player = ts.instantiate()
	add_child(_player)
	var pn: Node2D = _player as Node2D
	pn.global_position = Vector2(STAIR_X0 * CELL - 200.0, (FLOOR_ROW - 1) * CELL)
	var src := PacketInputSource.new()
	_player.set_input_source(src)
	for _i in 20:   # 先落稳
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
	# ② 卡顿的直接判据:climb 期间不能出现"水平速度被打到 ≈0"的帧(旧实现每级台阶一帧)
	var slow := 0
	for i in vx_by_frame.size():
		if i < 12:
			continue   # 起步加速段:0 → 满速是 _tick_horizontal 的正常缓动,不算台阶卡顿
		if vx_by_frame[i] < 0.5 * PlayerParams.move_speed:
			slow += 1
	_chk(slow == 0, "② ★ 爬台阶期间没有一帧水平速度被吃(0.5×move_speed 以下 %d 帧)" % slow)
	# ③ 每帧位移不能掉出"一帧正常位移"的 90% 以下(顿一下 = 某几帧位移接近 0)
	var dt := 1.0 / 60.0
	var expect_dx := PlayerParams.move_speed * dt
	var poor := 0
	for i in dy_by_frame.size():
		if i < 3:
			continue   # 起步加速段不算
		var p_now: float = vx_by_frame[i] * dt
		if p_now < expect_dx * 0.9:
			poor += 1
	_chk(poor <= 2, "③ ★ 正常帧位移占 90%%+:掉速帧 %d(≤2;起步/落地各允许 1 帧)" % poor)
	# ④ 不腾空:爬台阶期间应始终踩地(旧实现抬完离地 1px ⇒ is_on_floor 抖动)
	_chk(on_floor_frames >= frames - 3,
			"④ 爬台阶期间踩地 %d/%d 帧(≥ 总帧-3)" % [on_floor_frames, frames])
	# ⑤ 不掉回去:每帧竖直位移只有"抬升/1px 吸地",不允许明显下坠
	var big_drop := 0
	for d in dy_by_frame:
		if float(d) > 2.0:
			big_drop += 1
	_chk(big_drop == 0, "⑤ 没有明显下坠帧(>2px 的下移 %d 帧)" % big_drop)

	# ── ⑥⑦ 回放确定性:一格高的墙 ⇒ 自动跳 ⇒ 空中窗口 capture/restore/重放 ──
	# 刻意排在 ①~⑤ 之后:自动跳必然腾空一段,混进上面那段测量会让 ④ 恒不成立。
	var wall_x := STAIR_X0 + STAIRS * STAIR_W + 22          # 子格列:台阶终点右侧 22 子格(352px)
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
	# 离地那一帧的接触解算让过去,再 capture(整段窗口都在空中 ⇒ is_on_floor 缓存两遍一致)
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


# 一格高的墙:同时写进 16px 子格数据(自动跳判据读它)与真实碰撞(物理读它)。
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


# 回放比对的采样:位置 + 速度(精确相等,不做容差 —— 这里的差异由"整态漏字段"造成,量级远大于浮点噪声)
func _pose4(p: Node) -> Vector4:
	var body := p as CharacterBody2D
	var n := p as Node2D
	return Vector4(n.global_position.x, n.global_position.y, body.velocity.x, body.velocity.y)


# 混凝土碰撞:地板 + 每级台阶各一个矩形(与子格几何一致),碰撞层 1 = 玩家 mask 覆盖的层。
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
