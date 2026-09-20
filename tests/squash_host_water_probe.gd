extends Node
# 宿主级行为守卫(Task 2 Step 8b):player.gd 里 squash 的落地候选速度
#   _pre_move_vy = 0.0 if (in_water or latched) else velocity.y
# 是本任务唯一"改了没人会发现"的地方 —— 三条既有冒烟全都照不到它:
#   · tests/squash_stretch_smoke.gd 自建裸 AnimatedSprite2D,**从不加载 player.gd**;
#   · tests/enemy_logic_smoke.gd 实例化真 player.tscn,但站在**干**地上;
#   · tests/pvp_twin_smoke.gd 真驱动水中物理,却比对孪生态,而 squash/_pre_move_vy
#     **刻意在 capture_state() 之外**(纯表现层)→ 结构上看不见。
# 把那个谓词改回裸 `velocity.y`,上述三条全部照绿。
#
# 脚手架照 tests/pvp_twin_smoke.gd 的先例(同款合成网格 + 水池 + 梯 + 真 player.tscn
# + 真物理步进);**不**把断言塞进那个文件 —— 它是 C2 关键测试,混进去会把 squash 的
# 失败误报成 C2 失败。
#
# 跑法(scene 模式 headless,autoload 在;--quit-after 只作安全网,本探针自己 quit):
#   "<godot>" --headless --path . --quit-after 3600 res://tests/squash_host_water_probe.tscn
# 判据是**文本** `SQUASH HOST PROBE: ALL-OK`(不看退出码:挂住时 --quit-after 也退 0)。
#
# ★ 断言一律打在**可观测的** `player.animator.scale` 上,不打 _pre_move_vy ——
#   前者同时验证了 suppressed/钳位链没被绕开,后者是内部量。
# ★ 每相另附**前提断言**(water/latch/floor 帧数):没有它,几何一漂这相就变成
#   "什么都没测"却照样全绿的假绿。
# ★★ 与 brief 预期的一处出入(实测,见 _tick_water 上方的长注释):人站在实心地面上时
#   脚底探针恒落在**支撑格自己**里,而支撑格是 wall ⇒ **站定后 in_water 恒假**,
#   故"站定后每帧触发落地分支、稳态 ~9% 挤压"并不成立。谓词真正买下的是**水中下沉期**
#   那几十帧(健康态精确 1.0,删掉谓词后 1.0137)。梯那一相(spec 里同形的另一条)
#   才是"每帧、且钳到满幅 -10%"的那条,实测复数无误。

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

# ── 合成网格(确定性,与 pvp_twin_smoke 同形状):底行实心 + 一条梯 + 一片水池 ──
const COLS := 60
const ROWS := 14
const LADDER_X := 5            # 梯列 x(rows 5..12)
const WATER_X0 := 16           # 水池列区间 x 16..24(rows 2..12)
const WATER_X1 := 24

const FLOOR_TOP_Y := float((ROWS - 1) * 64)   # 832:底行墙的顶面
# 775:站姿碰撞箱底边距节点原点 57px(实测;该 57 也是 `Water.feet_offset` 的取值来源)
const REST_Y := FLOOR_TOP_Y - 57.0
const DRY_X := 35 * 64 + 32                   # 干地列(在水池与梯之外)
const LADDER_X_PX := LADDER_X * 64 + 32
const WATER_X_PX := (WATER_X0 + 4) * 64 + 32

# ── 容差 ──
# 参照 `PlayerParams.squash_amount = 0.10`(满冲击形变量,即"满挤压"时 scale.x 偏离 1.0 的量)。
# 取 0.005 = 满幅的 5%:健康态在这两相里是**逐帧精确 1.0**(_air 与 _impulse 都恒为 0,
# `1.0 + 0.10*0.0` 是浮点精确的),所以容差只需容下浮点噪声与指数尾巴(实测 <= 1e-5);
# 而删掉那个谓词后最小的真实偏离是水中下沉期的空中项
# `clamp(320/700)*0.30 = 0.1371` → scale.x 偏 0.0137 = 满幅的 13.7%,是容差的 2.7 倍。
const NEUTRAL_EPS := 0.005
# 站定末态的容差(相①)。比 NEUTRAL_EPS 松:入池触底那一下是**正当**的落地冲击 ——
# 玩家浮到池底前 1px 时 `in_water` 先翻假(脚底探针比碰撞箱底边低 1px,见报告),
# 随后一帧吃到重力(320 + 1600/60 = 346.7 > 落地下限 220)→ k=0.186 → 0.0185 的挤压,
# 再按 0.861^n 指数衰减。窗口末(触底后 ~30 帧)残余 ≈ 3e-4,故 0.01 有 30 倍余量。
# ★ 这一条**不具鉴别力**(那个冲击两个版本一模一样),它只是把 brief 的字面要求钉在文件里;
#   相① 真正的鉴别点是下面按 in_water 帧取的极值。
const SETTLED_EPS := 0.01
# 反例门槛:干地高处落地必须压到**满幅的一半**以上(实测 k=1 → 满幅 0.10 → scale.x 0.90)。
const DROP_MIN_SQUASH := 0.5

const S_STAND := 0
const S_DROP := 1
const S_WATER := 2
const S_LADDER := 3
const S_DONE := 4

const STAND_FRAMES := 45
const DROP_FRAMES := 70
const WATER_FRAMES := 60
const LADDER_SETTLE := 12      # 抓梯/下落过程不计入窗口(那几帧的空中项是正当的)
const LADDER_FRAMES := 75
const LADDER_LATCH_AT := 8     # 在空中按一下「上」抓住梯子(按住 S 时落地会成为蹲,蹲会解除攀附)

var _host: Node2D = null
var _p = null
var _src: PacketInputSource = null
var _stage := -1
var _f := 0
var _total := 0

var _fails: Array[String] = []
var _lines: Array[String] = []

# 窗口统计(每相开始时清零)
var _min_x := INF
var _max_dev := 0.0
var _max_dev_frame := 0
var _last_scale := Vector2.ONE
var _final_dev := 0.0          # 末次采样的偏离(只有它才配叫"站定末态")
var _water_frames := 0
var _floor_frames := 0
var _latch_frames := 0
var _wet_floor_frames := 0     # in_water ∧ is_on_floor 的帧数(证据用,见报告)
# 只在 in_water 为真的帧上取的极值 —— 相① 真正的鉴别点
var _wet_max_dev := 0.0
var _wet_dev_frame := 0


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


# ── 每相换一个**全新**的玩家 ──
# squash 的 _impulse 是内部累计量、没有公开复位口,复用同一实例会把上一相的余量
# 带进本相窗口(指数尾巴 0.861^n,要 20+ 帧才掉到容差以下)。新实例从 0 起,窗口干净。
func _begin(stage: int) -> void:
	_stage = stage
	_f = 0
	_min_x = INF
	_max_dev = 0.0
	_max_dev_frame = 0
	_last_scale = Vector2.ONE
	_water_frames = 0
	_floor_frames = 0
	_latch_frames = 0
	_wet_floor_frames = 0
	_wet_max_dev = 0.0
	_wet_dev_frame = 0
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
	return Vector2(DRY_X, REST_Y)


func _apply_input(held: int, pressed: int) -> void:
	_src.clear_edges()
	_src.apply_packet({
		"seq": _total,
		"ax": 0.0,
		"held": held,
		"pressed": pressed,
		"released": 0,
		"weapon": 0,
		"aim": Vector2(1.0, 0.0),
	})


# 采样(本探针的 _physics_process 跑在子节点之前,故读到的是**上一帧**宿主写出的 scale;
# 窗口是按帧取的极值,错开一帧无影响)。
func _sample(from_frame: int) -> void:
	if _f < from_frame:
		return
	var s: Vector2 = _p.animator.scale
	_last_scale = s
	var dev := maxf(absf(s.x - 1.0), absf(s.y - 1.0))
	_final_dev = dev
	if dev > _max_dev:
		_max_dev = dev
		_max_dev_frame = _f
	if s.x < _min_x:
		_min_x = s.x
	var wet: bool = _p.swim.in_water
	var on_floor: bool = _p.is_on_floor()
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


# ── 相④ 干地静止(正向对照):不挤压 ──
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


# ── 相③ 反例(必须有):干地高处落下**必须**真的挤压 ──
# 没有它,相①②可以靠"永不挤压"作弊通过。
func _tick_drop() -> void:
	_f += 1
	_apply_input(0, 0)
	_sample(1)
	if _f >= DROP_FRAMES:
		_check_floor()
		var want := 1.0 - DROP_MIN_SQUASH * PlayerParams.squash_amount
		_record("相③ 干地高处落下的反例", _min_x <= want,
			"窗口最小 scale.x %.4f(需 <= %.4f,即至少压到满幅的 %d%%);floor 帧 %d" % [
				_min_x, want, int(DROP_MIN_SQUASH * 100.0), _floor_frames])
		_begin(S_WATER)


# ── 相① 水中按住 S 下沉到池底:水中全程中性 ──
# ★ 前提:窗口里必须有**在水中的帧**(否则这相退化成干地站立、恒绿)。
# ★ 断言按 **in_water 为真的帧**取极值,不按整个窗口:
#   删掉谓词后真实偏离出现在**下沉期** —— 空中项 `|320|/700*0.30 = 0.1371` →
#   scale.x 1.0137(健康态是 **0.0000**)——而那几十帧全在 in_water 为真时;
#   反观"整个窗口"里最大的偏离是入池触底那一下**正当**的重力冲量(0.0185,两个版本
#   一模一样,见 SETTLED_EPS 的推导),拿它当判据会把容差撑到鉴别点之上。
# ★ 另记 in_water ∧ is_on_floor 的重叠帧数:本几何下它是 **0** ——
#   `Water.feet_offset` 取的是**碰撞箱底边**(58px;站立/移动/蹲/飞都是 57px,仅 charge 58),
#   而人站在实心地面上时底边正好压在支撑格顶面 ⇒ 脚底探针永远落在**支撑格自己**里,
#   而支撑格是 wall ⇒ 站定后 in_water 恒假。故 brief 预期的"站定后每帧触发落地分支、
#   稳态 ~9% 挤压"在本作几何下**不成立**;谓词真正买下的是下沉期那几十帧(见报告)。
func _tick_water() -> void:
	_f += 1
	_apply_input(PacketInputSource.BIT_DOWN, 0)
	_sample(1)
	if _f >= WATER_FRAMES:
		_record("相① 前提:窗口内有水中帧", _water_frames >= 10,
			"water 帧 %d / %d" % [_water_frames, WATER_FRAMES])
		_check_floor()
		_record("相① 水中(下沉期)全程中性", _wet_max_dev <= NEUTRAL_EPS,
			"in_water 帧上 max dev %.4f(帧 %d),上限 %.4f;in_water∧on_floor 重叠 %d 帧;末值 scale=(%.4f,%.4f)" % [
				_wet_max_dev, _wet_dev_frame, NEUTRAL_EPS, _wet_floor_frames,
				_last_scale.x, _last_scale.y])
		_record("相① 站定末态中性(brief 字面要求)", _final_dev <= SETTLED_EPS,
			"末帧 dev %.4f,上限 %.4f(窗口内瞬时峰值 %.4f,是触底那一下正当的重力冲量)" % [
				_final_dev, SETTLED_EPS, _max_dev])
		_begin(S_LADDER)


# ── 相② 梯底按住 S:全程中性(坏了幅度最大:每帧 -0.735 直到钳位 → 满幅 -10%) ──
# 推导:梯下行速度 = climb_speed 300 × tile_defs 梯 climb_descent_speed 2.0 ×
# climb_vertical_mult 1.2 = 720;落地下限 220、参考 900 → k = (720-220)/680 = 0.735,
# 每帧减 0.735 而指数恢复每帧只回 15% → 三四帧就钳到 -1.0 → scale=(0.9,1.1)。
# 攀附期间 _tick_crouch_and_dash 首行早退 → is_squat 永不置位 → 攀附也不解除 → **每帧**。
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
