extends Node
# 下蹲/冲刺手感冒烟(scene 模式 headless):手动喂 NetworkInputSource 逐帧驱动单个 Player,
# 断言:
#  1) 卡蹲修复:地面按住 S 蹲 → 被抬到空中(仍按 S)is_squat 随离地清除 → 空中松开 S 落地不再蹲。
#  2) 蹲走:蹲态喂水平轴,速度收敛到 crouch_walk_speed 附近且远小于 move_speed。
#  3) 冲刺按跳打断:is_charge=false 且保留水平动量(velocity.x 仍大)。
#  4) 冲刺撞水平墙:is_charge 提前清 false(未冲满 0.4s)且 velocity.x≈0。
#  5) 空中冲刺重力削减:空中单 tick 的 vy 增量 ≈ gravity*charge_air_gravity_mult*dt,
#     明显小于不冲刺时的 gravity*dt。
# 跑法:用户自跑(见 move_feel_smoke.sh / CLAUDE.md)。通过 = SMOKE_MOVE_FEEL OK。

const BIT_UP := NetworkInputSource.BIT_UP
const BIT_DOWN := NetworkInputSource.BIT_DOWN
const BIT_CHARGE := NetworkInputSource.BIT_CHARGE

const COLS := 40
const ROWS := 14
const TILE := 64
const WALL_X := 8            # 竖直墙列(x=8,px 512..576):测试冲刺撞墙停
const DT := 1.0 / 60.0

var p = null                 # Player(手动步进)
var src: NetworkInputSource = NetworkInputSource.new()
var _fail := ""
var _spawn := Vector2(2 * TILE + TILE * 0.5, 3 * TILE + TILE * 0.5)

func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	var host := Node2D.new()
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	p = preload("res://scenes/player/Player.tscn").instantiate()
	p.name = "MoveFeel"
	p.set_input_source(src)
	host.add_child(p)
	p.global_position = _spawn
	p.set_physics_process(false)
	print("[move_feel] 卡蹲/蹲走/跳打断/撞墙停/空中重力 场景就绪")

func _build_grid() -> Array[Array]:
	var wall := 31
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			var v := 0
			if y == ROWS - 1:
				v = wall                       # 底行地面
			elif x == WALL_X:
				v = wall                       # 竖直墙列(0..12)
			row.append(v)
		grid.append(row)
	return grid

# 喂一帧:清边沿 → apply(held/pressed/released/ax)→ 手动步进
func _feed(held: int, pressed: int, released: int, ax: float) -> void:
	src.clear_edges()
	src.apply_packet({"seq": 0, "ax": ax, "held": held,
		"pressed": pressed, "released": released, "weapon": 0, "aim": Vector2(1.0, 0.0)})
	p._physics_process(DT)

func _idle(n: int) -> void:
	for _i in range(n):
		_feed(0, 0, 0, 0.0)

func _reset_ground() -> void:
	p.global_position = _spawn
	p.velocity = Vector2.ZERO
	p.is_charge = false
	p.is_squat = false
	p.charge_timer = 0.0
	src.reset_state()
	_idle(70)   # 落回地面站稳

func _reset_air() -> void:
	# 摆到空中高处,等 is_on_floor 清 false、进入自由落体
	p.global_position = Vector2(2 * TILE + TILE * 0.5, 3 * TILE + TILE * 0.5)
	p.velocity = Vector2.ZERO
	p.is_charge = false
	p.is_squat = false
	p.charge_timer = 0.0
	src.reset_state()
	_idle(6)

func _physics_process(_delta: float) -> void:
	if p == null or not _fail.is_empty():
		return
	_run_all()

func _run_all() -> void:
	_test_crouch_air_release()
	if not _fail.is_empty(): _finish(); return
	_test_crouch_walk_speed()
	if not _fail.is_empty(): _finish(); return
	_test_dash_jump_cancel()
	if not _fail.is_empty(): _finish(); return
	_test_dash_wall_stop()
	if not _fail.is_empty(): _finish(); return
	_test_air_dash_gravity()
	_finish()

# 1) 卡蹲:地面蹲 → 抬到空中(仍按 S)离地清除 → 空中松开 S 落地不蹲。
func _test_crouch_air_release() -> void:
	_reset_ground()
	# 地面按住 S → 蹲
	for _i in range(6):
		_feed(BIT_DOWN, BIT_DOWN, 0, 0.0)
	if not p.is_squat:
		_fail = "地面按住 S 未下蹲"; return
	if not p.is_on_floor():
		_fail = "测试前置失败:按 S 前未落地"; return
	# 抬到空中(等效击飞),仍按住 S(不再发 just_pressed,避免触发空中下冲)
	p.global_position.y -= 300.0
	p.velocity = Vector2.ZERO
	for _i in range(4):
		_feed(BIT_DOWN, 0, 0, 0.0)
	if p.is_squat:
		_fail = "离地仍蹲(is_squat 未随地面条件清除)" ; return
	if p.is_on_floor():
		_fail = "抬离后 is_on_floor 仍 true(测试无效)"; return
	# 空中松开 S(旧 bug 的 release 分支在 if is_on_floor 内不执行)
	for _i in range(4):
		_feed(0, 0, BIT_DOWN, 0.0)
	# 落地(松开 S):应不蹲
	_idle(90)
	if not p.is_on_floor():
		_fail = "松开 S 后未落回地面(测试无效)"; return
	if p.is_squat:
		_fail = "落地后仍蹲(卡蹲未修)"; return

# 2) 蹲走:蹲态朝左(远离 x=8 墙)走,速度收敛到 crouch_walk_speed 附近。
func _test_crouch_walk_speed() -> void:
	_reset_ground()
	for _i in range(6):
		_feed(BIT_DOWN, BIT_DOWN, 0, 0.0)
	if not p.is_squat:
		_fail = "crouch_walk:未进入蹲态"; return
	for _i in range(60):
		_feed(BIT_DOWN, 0, 0, -1.0)
	var vx: float = absf(p.velocity.x)
	var expect: float = p.crouch_walk_speed
	if vx > expect * 1.25:
		_fail = "蹲走速度超预期: %.1f > %.0f×1.25" % [vx, expect]; return
	if vx < expect * 0.5:
		_fail = "蹲走速度过小: %.1f < %.0f×0.5(加速窗不足或未走)" % [vx, expect]; return
	if vx > p.move_speed * 0.6:
		_fail = "蹲走疑似用了 full move_speed: %.1f > %.0f×0.6" % [vx, p.move_speed]; return

# 3) 冲刺按跳打断:is_charge 清 false 且保留水平动量。
func _test_dash_jump_cancel() -> void:
	_reset_ground()
	# 面朝右(远离墙方向为左,但出生 x 在墙左侧,向右会撞墙;跳打断只需 3 帧不撞墙即可)
	for _i in range(3):
		_feed(BIT_CHARGE, BIT_CHARGE, 0, 1.0)
	if not p.is_charge:
		_fail = "未进入冲刺"; return
	for _i in range(3):
		_feed(BIT_CHARGE, 0, 0, 1.0)
	# 按跳打断(本帧 held 带 up,pressed=up)
	_feed(BIT_UP | BIT_CHARGE, BIT_UP, 0, 1.0)
	if p.is_charge:
		_fail = "按跳后仍 is_charge(未打断)"; return
	if p.velocity.y >= 0.0:
		_fail = "按跳后未起跳 vy=%.1f" % p.velocity.y; return
	if absf(p.velocity.x) < 900.0:
		_fail = "打断后水平动量丢失 vx=%.1f(<900)" % p.velocity.x; return

# 4) 冲刺撞水平墙停:出生在墙左侧,向右冲,~13 tick 撞墙,应提前停(0.4s=24 tick)。
func _test_dash_wall_stop() -> void:
	_reset_ground()
	for _i in range(3):
		_feed(BIT_CHARGE, BIT_CHARGE, 0, 1.0)
	if not p.is_charge:
		_fail = "wall_stop:未进入冲刺"; return
	var stopped_at := -1
	for i in range(30):
		_feed(BIT_CHARGE, 0, 0, 1.0)
		if not p.is_charge:
			stopped_at = i
			break
	if stopped_at < 0:
		_fail = "30 tick 内冲刺未停(撞墙停未生效)"; return
	if stopped_at > 22:
		_fail = "冲刺停得太晚(tick %d,疑似冲满 0.4s 而非撞墙停)" % stopped_at; return
	if absf(p.velocity.x) > 50.0:
		_fail = "撞墙停后 vx 未清: %.1f" % p.velocity.x; return
	if p.global_position.x > (WALL_X * TILE) + TILE:
		_fail = "位置越过墙: x=%.1f > %d" % [p.global_position.x, WALL_X * TILE + TILE]; return

# 5) 空中冲刺重力削减:对比同一起点自由落体 vs 空中冲刺的单 tick vy 增量。
func _test_air_dash_gravity() -> void:
	_reset_air()
	# 不冲刺的自由落体单 tick vy 增量
	var vy0: float = p.velocity.y
	_feed(0, 0, 0, 0.0)
	var dvy_normal: float = p.velocity.y - vy0
	if dvy_normal <= 0.0:
		_fail = "空中自由落体 vy 未增(测试无效) dvy=%.2f" % dvy_normal; return
	# 空中冲刺:重新摆空,按住 X 进入冲刺后再测单 tick vy 增量
	_reset_air()
	_feed(BIT_CHARGE, BIT_CHARGE, 0, 0.0)   # 进入冲刺(本帧 is_charge 置 true)
	if not p.is_charge:
		_fail = "空中冲刺未进入 is_charge"; return
	var vy1: float = p.velocity.y
	_feed(BIT_CHARGE, 0, 0, 0.0)
	var dvy_charge: float = p.velocity.y - vy1
	if dvy_charge <= 0.0:
		_fail = "空中冲刺 vy 未增(测试无效) dvy=%.2f" % dvy_charge; return
	var ratio: float = dvy_charge / dvy_normal
	var mult: float = p.charge_air_gravity_mult
	if absf(ratio - mult) > 0.2:
		_fail = "空中冲刺重力倍率不符: 实测 %.2f 期望 %.2f(±0.2)" % [ratio, mult]; return

func _finish() -> void:
	if not _fail.is_empty():
		print("SMOKE_MOVE_FEEL FAIL: %s" % _fail)
		get_tree().quit(1)
		return
	print("SMOKE_MOVE_FEEL OK: 卡蹲/蹲走/跳打断/撞墙停/空中重力 全过")
	get_tree().quit(0)
