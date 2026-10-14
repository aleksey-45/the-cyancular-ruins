extends Node

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

# ── 合成网格(确定性,与 pvp_twin_smoke 同形状):底行实心 + 一条梯 + 一片水池 ──
const COLS := 60
const ROWS := 14
const LADDER_X := 5            # 梯列 x(rows 5..12)
const WATER_X0 := 16           # 水池列区间 x 16..24(rows 2..12)
const WATER_X1 := 24

const FLOOR_TOP_Y := float((ROWS - 1) * 64)   # 832:底行墙的顶面
# 775: 站姿碰撞体底边距节点原点 57px (对应 Water.feet_offset 取值)
const REST_Y := FLOOR_TOP_Y - 57.0
const DRY_X := 35 * 64 + 32                   # 干地列(在水池与梯之外)
const LADDER_X_PX := LADDER_X * 64 + 32
const WATER_X_PX := (WATER_X0 + 4) * 64 + 32

# ── 容差配置 ──
# 参考 PlayerParams.squash_amount = 0.10(满冲击形变量)
const NEUTRAL_EPS := 0.005
# 水中帧容差阈值
const WET_EPS := 0.001
# 触底静止容差
const SETTLED_EPS := 0.01
const DROP_MIN_SQUASH := 0.5
# 落地判定取前 3 帧
const DROP_FLOOR_FRAMES := 3

const S_STAND := 0
const S_DROP := 1
const S_WATER := 2
const S_LADDER := 3
const S_DOWNED := 4
const S_DONE := 5

const STAND_FRAMES := 45
const DROP_FRAMES := 70
const WATER_FRAMES := 60
const LADDER_SETTLE := 12      # 抓梯/下落过程不计入窗口(那几帧的空中项是正当的)
const LADDER_FRAMES := 75
const LADDER_LATCH_AT := 8
const DOWN_AT := 30
const DOWNED_FRAMES := 8       # 与副本探针的阶段 4 同宽:单帧窗口"两边都漏"(见那边的推导)
const REVIVE_FRAMES := 6
const DOWN_SUB_FALL := 0
const DOWN_SUB_WINDOW := 1
const DOWN_SUB_LAND := 2
const DOWN_SUB_REVIVE := 3

var _host: Node2D = null
var _p = null
var _src: PacketInputSource = null
var _stage := -1
var _f := 0
var _total := 0

var _fails: Array[String] = []
var _lines: Array[String] = []

# 窗口统计数据(每阶段开始时重置)
# _floor_max_x 用于阶段 3 落地帧极值判定，_max_x 用于整窗口采样读数
var _max_x := -INF
var _floor_max_x := -INF
var _floor_max_x_frame := 0
var _floor_seen := 0
var _prev_on_floor := false
var _max_dev := 0.0
var _max_dev_frame := 0
var _last_scale := Vector2.ONE
var _final_dev := 0.0          # 末次采样的偏离(只有它才配叫"站定末态")
var _water_frames := 0
var _floor_frames := 0
var _latch_frames := 0
var _wet_floor_frames := 0     # in_water ∧ is_on_floor 的帧数(证据用,见报告)
# 只在 in_water 为真的帧上取的极值 —— 阶段 1 真正的鉴别点
var _wet_max_dev := 0.0
var _wet_dev_frame := 0
# 阶段 5(倒地)
var _sub := 0
var _pre_down_vy := 0.0
var _downed_air_frames := 0


func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	_host = Node2D.new()
	_host.name = "Host"
	add_child(_host)
	WorldBuilder.build_sim(_host, MazeGenerator.current_grid)
	print("[squash_host] 合成世界 %dx%d 格;梯列 x=%d;水池 x %d..%d;底行实心 y=%d" % [
		COLS, ROWS, LADDER_X, WATER_X0, WATER_X1, int(FLOOR_TOP_Y)])
	_begin(S_STAND)


func _build_grid() -> Array[Array]:
	var ts_wall := 31            # 纹理1 全砖(墙)
	var ts_ladder := 11 * 16 + 15
	var ts_water := 21 * 16 + 15
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			var v := 0
			if y == ROWS - 1:
				v = ts_wall                       # 底行整行实心地
			elif x == LADDER_X and y >= 5:
				v = ts_ladder                     # 梯(通道,无碰撞)
			elif x >= WATER_X0 and x <= WATER_X1 and y >= 2:
				v = ts_water                      # 水(liquid,无碰撞)
			row.append(v)
		grid.append(row)
	return grid


# ── 每相换一个全新的玩家 ──
# squash 的 _impulse 是内部累计量、没有公开复位口,复用同一实例会把上一相的余量
# 带进本阶段测试窗口(指数尾巴 0.861^n,要 20+ 帧才掉到容差以下)。新实例从 0 起,窗口干净。
func _begin(stage: int) -> void:
	_stage = stage
	_f = 0
	_max_x = -INF
	_floor_max_x = -INF
	_floor_max_x_frame = 0
	_floor_seen = 0
	# - 必须归 false:上一相末态多半是"站在地上",留 true 会把本阶段出生时的空中帧
	#   当成落地帧(正是本阶段最怕的那类误分类)。
	_prev_on_floor = false
	_max_dev = 0.0
	_max_dev_frame = 0
	_last_scale = Vector2.ONE
	_water_frames = 0
	_floor_frames = 0
	_latch_frames = 0
	_wet_floor_frames = 0
	_wet_max_dev = 0.0
	_wet_dev_frame = 0
	_sub = DOWN_SUB_FALL
	_pre_down_vy = 0.0
	_downed_air_frames = 0
	if _p != null and is_instance_valid(_p):
		_p.queue_free()
	_p = PLAYER_SCENE.instantiate()
	_src = PacketInputSource.new()
	_p.set_input_source(_src)
	_host.add_child(_p)
	_p.global_position = _spawn_of(stage)
	_p.velocity = Vector2.ZERO


func _spawn_of(stage: int) -> Vector2:
	match stage:
		S_STAND:
			return Vector2(DRY_X, REST_Y)
		S_DROP:
			return Vector2(DRY_X, REST_Y - 400.0)
		S_WATER:
			return Vector2(WATER_X_PX, REST_Y - 160.0)
		S_LADDER:
			return Vector2(LADDER_X_PX, REST_Y - 120.0)
		S_DOWNED:
			# 与阶段 3 同一起点(干地高处):本阶段要的就是"落地前手上先攥着一个真落速"
			return Vector2(DRY_X, REST_Y - 400.0)
	return Vector2(DRY_X, REST_Y)


func _apply_input(held: int, pressed: int) -> void:
	_src.clear_edges()
	_src.apply_packet({
		"seq": _total,
		"ax": 0.0,
		"held": held,
		"pressed": pressed,
		"released": 0,
		"winst": 0,
		"aim": Vector2(1.0, 0.0),
	})


# 采样(本探针的 _physics_process 跑在子节点之前,故读到的是上一帧宿主写出的 scale;
# 窗口是按帧取的极值,错开一帧无影响 —— 但分类受影响,见下)。
func _sample(from_frame: int) -> void:
	var s: Vector2 = _p.animator.scale
	var wet: bool = _p.swim.in_water
	var on_floor: bool = _p.is_on_floor()
	if _f >= from_frame:
		_last_scale = s
		var dev := maxf(absf(s.x - 1.0), absf(s.y - 1.0))
		_final_dev = dev
		if dev > _max_dev:
			_max_dev = dev
			_max_dev_frame = _f
		if s.x > _max_x:
			_max_x = s.x
		# 阶段 3 的判定条件只认落地帧(见 DROP_MIN_SQUASH / DROP_FLOOR_FRAMES):
		# 空中项与落地冲击都往最大方向写 scale.x,不分开的话公式一旦反向,空中拉伸就会
		# 替代落地挤压作为极值(实测过)。
		if _prev_on_floor:
			_floor_seen += 1
			if _floor_seen <= DROP_FLOOR_FRAMES and s.x > _floor_max_x:
				_floor_max_x = s.x
				_floor_max_x_frame = _f
		if wet:
			_water_frames += 1
			if dev > _wet_max_dev:
				_wet_max_dev = dev
				_wet_dev_frame = _f
		if on_floor:
			_floor_frames += 1
		if wet and on_floor:
			_wet_floor_frames += 1
		if _p.climb.is_latched():
			_latch_frames += 1
	_prev_on_floor = on_floor


func _physics_process(_delta: float) -> void:
	if _p == null or not is_instance_valid(_p):
		return
	_total += 1
	match _stage:
		S_STAND:
			_tick_stand()
		S_DROP:
			_tick_drop()
		S_WATER:
			_tick_water()
		S_LADDER:
			_tick_ladder()
		S_DOWNED:
			_tick_downed()


# ── 阶段 4 干地静止(正向对照):不挤压 ──
func _tick_stand() -> void:
	_f += 1
	_apply_input(0, 0)
	_sample(1)
	if _f >= STAND_FRAMES:
		_record("相④ 干地静止", _max_dev <= NEUTRAL_EPS,
			"max dev %.4f(帧 %d)末值 scale=(%.4f,%.4f) floor 帧 %d" % [
				_max_dev, _max_dev_frame, _last_scale.x, _last_scale.y, _floor_frames])
		_check_floor()
		_begin(S_DROP)


# ── 阶段 3 反例(必须有):干地高处落下必须真的挤压 ──
# 若缺少该反例对照，阶段 1② 可能会因未触发挤压逻辑而产生假阳性通过。
func _tick_drop() -> void:
	_f += 1
	_apply_input(0, 0)
	_sample(1)
	if _f >= DROP_FRAMES:
		_check_floor()
		var want := 1.0 + DROP_MIN_SQUASH * PlayerParams.squash_amount
		_record("相③ 干地高处落下的反例", _floor_max_x >= want,
			"落地后前 %d 帧上最大 scale.x %.4f(需 >= %.4f,即至少压到满幅的 %d%%),余量 %+.4f;floor 帧共 %d;整个窗口最大 %.4f(含空中拉伸项,不参与判据)" % [
				DROP_FLOOR_FRAMES, _floor_max_x, want, int(DROP_MIN_SQUASH * 100.0),
				_floor_max_x - want, _floor_frames, _max_x])
		_begin(S_WATER)


func _tick_water() -> void:
	_f += 1
	_apply_input(PacketInputSource.BIT_DOWN, 0)
	_sample(1)
	if _f >= WATER_FRAMES:
		_record("相① 前提:窗口内有水中帧", _water_frames >= 10,
			"water 帧 %d / %d" % [_water_frames, WATER_FRAMES])
		_check_floor()
		_record("相① 水中(下沉期)全程中性", _wet_max_dev <= WET_EPS,
			"in_water 帧上 max dev %.4f(帧 %d),上限 %.4f;in_water∧on_floor 重叠 %d 帧;末值 scale=(%.4f,%.4f)" % [
				_wet_max_dev, _wet_dev_frame, WET_EPS, _wet_floor_frames,
				_last_scale.x, _last_scale.y])
		_record("相① 站定末态中性(brief 字面要求)", _final_dev <= SETTLED_EPS,
			"末帧 dev %.4f,上限 %.4f(窗口内瞬时峰值 %.4f,是触底那一下正当的重力冲量)" % [
				_final_dev, SETTLED_EPS, _max_dev])
		_begin(S_LADDER)


# ── 阶段 2 梯底按住 S:全程中性(坏了幅度最大:每帧 -0.735 直到钳位 -> 满幅 10%) ──
# 推导:梯下行速度 = climb_speed 300 × tile_defs 梯 climb_descent_speed 2.0 ×
# climb_vertical_mult 1.2 = 720;落地下限 220、参考 900 -> k = (720-220)/680 = 0.735,
# 每帧减 0.735 而指数恢复每帧只回 15% -> 三四帧就钳到 -1.0 -> scale=(1.1,0.9)。
# 攀附期间 _tick_crouch_and_dash 首行提前返回 -> is_squat 永不置位 -> 攀附也不解除 -> 每帧。
func _tick_ladder() -> void:
	_f += 1
	_apply_input(PacketInputSource.BIT_DOWN,
		PacketInputSource.BIT_UP if _f == LADDER_LATCH_AT else 0)
	_sample(LADDER_SETTLE + 1)
	if _f >= LADDER_FRAMES:
		_record("相② 前提:窗口内持续攀附且在梯底地面上", _latch_frames >= 40 and _floor_frames >= 40,
			"latch 帧 %d / floor 帧 %d(窗口 %d 帧)" % [
				_latch_frames, _floor_frames, LADDER_FRAMES - LADDER_SETTLE])
		_record("相② 梯底按住 S 全程中性", _max_dev <= NEUTRAL_EPS,
			"max dev %.4f(帧 %d)末值 scale=(%.4f,%.4f)" % [
				_max_dev, _max_dev_frame, _last_scale.x, _last_scale.y])
		_begin(S_DOWNED)


func _tick_downed() -> void:
	_f += 1
	_apply_input(0, 0)
	match _sub:
		DOWN_SUB_FALL:
			_sample(0)
			if _f >= DOWN_AT:
				# 前提:此刻手上真有"这一帧要消费的"那个缓存值,且人还在空中
				_pre_down_vy = _p._pre_move_vy
				_p.combat.force_down()
				_record("相⑤ 前提:倒地那一刻手上有真落速且仍在空中",
					_pre_down_vy >= 700.0 and not _p.is_on_floor(),
					"_pre_move_vy = %.1f(需 >= 700)、on_floor = %s(需 false)" % [
						_pre_down_vy, str(_p.is_on_floor())])
				_sub = DOWN_SUB_WINDOW
				_f = 0
				_max_dev = 0.0
				_max_dev_frame = 0
				_downed_air_frames = 0
		DOWN_SUB_WINDOW:
			_sample(1)
			if not _p.is_on_floor():
				_downed_air_frames += 1
			if _f >= DOWNED_FRAMES:
				# 前提:窗口里确实有够多的帧仍在空中 —— 全在地上时第四参换不换都一样(退化成无效操作)
				_record("相⑤ 前提:倒地窗口里有足够多帧仍在空中", _downed_air_frames >= 6,
					"倒地 ∧ 空中 %d / %d 帧" % [_downed_air_frames, DOWNED_FRAMES])
				_record("相⑤ 倒地 %d 帧强制中性(tick 的第四参 = is_downed)" % DOWNED_FRAMES,
					_max_dev <= NEUTRAL_EPS,
					"max dev %.4f(帧 %d),上限 %.4f,末值 scale=(%.4f,%.4f)" % [
						_max_dev, _max_dev_frame, NEUTRAL_EPS, _last_scale.x, _last_scale.y])
				_sub = DOWN_SUB_LAND
				_f = 0
		DOWN_SUB_LAND:
			# 倒地不取消物理(与敌人统一):继续受重力直到落地
			_sample(0)
			if _p.is_on_floor():
				# 证据(不是判定条件):落地后缓存里还剩多少 —— 直接读出"归零那一行在不在"
				var stale: float = _p._pre_move_vy
				_max_dev = 0.0
				_max_dev_frame = 0
				_p.combat.revive()
				_sub = DOWN_SUB_REVIVE
				_f = 0
				_record("相⑤ 证据:倒地期间落地后缓存已被归零(下一段的因)", absf(stale) <= 5.0,
					"落地后 _pre_move_vy = %.1f(需 ≈ 0;!= 0 ⇒ 复活首帧会把它当成落速用)" % stale)
		DOWN_SUB_REVIVE:
			_sample(1)
			if _f >= REVIVE_FRAMES:
				_record("相⑤ 复活后 %d 帧内中性(倒地分支的 _pre_move_vy = 0.0)" % REVIVE_FRAMES,
					_max_dev <= NEUTRAL_EPS,
					"max dev %.4f(帧 %d),上限 %.4f,末值 scale=(%.4f,%.4f)" % [
						_max_dev, _max_dev_frame, NEUTRAL_EPS, _last_scale.x, _last_scale.y])
				_begin(S_DONE)
				_finish()


func _check_floor() -> void:
	_record("  下落/静止后确实踩在地面上", _floor_frames > 0, "floor 帧 %d" % _floor_frames)


func _record(label: String, ok: bool, detail: String) -> void:
	var line := "%s %s —— %s" % ["OK  " if ok else "FAIL", label, detail]
	_lines.append(line)
	print("[squash_host] %s" % line)
	if not ok:
		_fails.append("%s(%s)" % [label, detail])


func _finish() -> void:
	if _fails.is_empty():
		print("SQUASH HOST PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("SQUASH HOST PROBE: FAIL | %d 条: %s" % [_fails.size(), "; ".join(_fails)])
		get_tree().quit(1)
