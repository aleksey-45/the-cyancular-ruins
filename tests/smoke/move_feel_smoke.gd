extends Node
# 下蹲/冲刺手感冒烟(scene 模式 headless):手动喂 PacketInputSource 逐帧驱动单个 Player,
# 断言:
#  1) 卡蹲修复:地面按住 S 蹲 → 被抬到空中(仍按 S)is_squat 随离地清除 → 空中松开 S 落地不再蹲。
#  2) 蹲走:蹲态喂水平轴,速度收敛到 crouch_walk_speed 附近且远小于 move_speed。
#  3) 冲刺按跳打断:is_charge=false 且保留水平动量(velocity.x 仍大)。
#  4) 冲刺撞水平墙:is_charge 提前清 false(未冲满 0.4s)且 velocity.x≈0。
#  5) 空中冲刺重力削减:空中单 tick 的 vy 增量 ≈ gravity*charge_air_gravity_mult*dt,
#     明显小于不冲刺时的 gravity*dt。
# 跑法:见 move_feel_smoke.sh(测试怎么跑先问用户,见 CLAUDE.md 的约定)。通过 = SMOKE_MOVE_FEEL OK。

const BIT_UP := PacketInputSource.BIT_UP
const BIT_DOWN := PacketInputSource.BIT_DOWN
const BIT_CHARGE := PacketInputSource.BIT_CHARGE

const COLS := 40
const ROWS := 14
const TILE := 64
const WALL_X := 8            # 竖直墙列(x=8,px 512..576):测试冲刺撞墙停
const DT := 1.0 / 60.0

var p = null                 # Player(手动步进)
var src: PacketInputSource = PacketInputSource.new()
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
	p = preload("res://scenes/player/player.tscn").instantiate()
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
		"pressed": pressed, "released": released, "winst": 0, "aim": Vector2(1.0, 0.0)})
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
	# ★ 必须**显式**重置朝向(2026-09-26 修):本冒烟此前一直没写这一行,靠的是一个**副作用** ——
	#   当年 `player._ready` 会发一把手枪 ⇒ 武器每帧跑 `_auto_aim()` ⇒ 它顺带
	#   `player.set_facing(+1)`(本冒烟喂的 aim 是 (1,0)),把朝向按回 +1。
	#   后来那次改动把"发手枪"换成空背包 ⇒ 副作用消失 ⇒ 冲刺方向翻成 -1 ⇒
	#   `_test_dash_jump_cancel` 的 `absf(velocity.x) < 900` 红成 `vx=-877.0`
	#   (= 冲刺向左后地面加速缓动一帧,分毫不差),**红了 10 天**。
	#   ★ 别用"把 900 调低"来消它:877 与 900 只差 2.5%,调低会让"朝反方向冲"也算通过。
	p.facing_direction = 1
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
	# ★★ 2026-10-08(测试经济 **D3**):**把绝对阈值 900 换成关系式**。
	#   原判据 `absf(vx) < 900` 抓的其实是**方向被冲反**(该文件 75-81 行记的那次事故:`vx=-877.0`
	#   —— 冲刺被冲成向左,与 900 只差 2.5%),而那个注释**明确禁止**"把 900 调低"来消它。
	#   绝对数既表达不出"方向对不对",又会随调参过期 ⇒ 拆成两问,两条都**跟着产品常量走**:
	#     ① 方向 = 本场景的意图方向(喂的是 `ax=+1`、`_reset_ground` 又把 `facing_direction` 置 +1);
	#     ② 幅度仍在**冲刺区间**(比走路速度 `p.move_speed` 大)。
	if p.velocity.x <= 0.0:
		_fail = "打断后冲刺被冲反了(vx=%.1f;本场景意图方向是 +1)" % p.velocity.x; return
	if absf(p.velocity.x) < p.move_speed:
		_fail = "打断后水平动量掉到走路速度以下(vx=%.1f < move_speed %.0f)" % [p.velocity.x, p.move_speed]; return

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
	# ★★ 2026-10-08(测试经济 **D3**):**魔数 22 → 从产品常量推出来的上限**。
	#   原来的 22 是从"满时长 0.4s = 24 tick、留 2 tick 余量"**手抄**来的 ⇒ `charge_duration`
	#   一改它就过期,而且过期方式是**静默变松或变紧**(不报错)。现在直接算:
	#   满时长 tick 数 = `charge_duration / DT`,要求**明显早于**它(留 2 tick 余量)。
	var full_ticks := int(ceil(p.charge_duration / DT))
	# ★ 阈值取**满时长的 0.8**(比值,不是手抄的 tick 数):撞墙停必须**显著早于**满时长。
	#   ★★ 照实记本条的边界:它的形态是"停得**太晚**",所以 —— 与下面那两条(`vx` 清没清、
	#   位置越没越墙)**冗余**:若"墙没停住",冲刺会在**自然满时长**停(≈full−3),而默认满时长下
	#   full−3 ≤ 用旧魔数 22 那条 ⇒ **旧判据抓不到它**;改成 0.8 比值后 full−3(≈21) > 0.8·full(≈19)
	#   ⇒ 能抓到。**但真正的墙判据仍是下面那两条**(位置越过墙 / vx 未清),别把这条当墙守卫。
	if stopped_at > int(full_ticks * 0.8):
		_fail = "冲刺停得太晚(tick %d;满时长 %d tick 的 0.8 = %d ⇒ 疑似冲满而非撞墙停)" % [stopped_at, full_ticks, int(full_ticks * 0.8)]; return
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
