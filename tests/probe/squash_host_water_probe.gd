extends Node
# 宿主级行为守卫(Task 2 Step 8b):player.gd 里 squash 的落地候选速度
#   _pre_move_vy = 0.0 if (in_water or latched) else velocity.y
# 是本任务唯一"改了没人会发现"的地方 —— 三条既有冒烟全都无法覆盖检测它:
#   - tests/smoke/squash_stretch_smoke.gd 自建裸 AnimatedSprite2D,**从不加载 player.gd**;
#   - tests/smoke/enemy_logic_smoke.gd 实例化真 player.tscn,但站在**干**地上;
#   - tests/smoke/pvp_twin_smoke.gd 真驱动水中物理,却比对孪生态,而 squash/_pre_move_vy
#     **刻意在 capture_state() 之外**(纯表现层)→ 结构上看不见。
# 把那个谓词改回裸 `velocity.y`,上述三条全部保持测试通过。
#
# 脚手架照 tests/smoke/pvp_twin_smoke.gd 的先例(相同机制合成网格 + 水池 + 梯 + 真 player.tscn
# + 真物理步进);**不**把断言塞进那个文件 —— 它是 C2 关键测试,混进去会把 squash 的
# 失败误报成 C2 失败。
#
# 跑法(scene 模式 headless,autoload 在;--quit-after 只作安全网,本探针自己 quit):
#   "<godot>" --headless --path . --quit-after 3600 res://tests/probe/squash_host_water_probe.tscn
# 判据是**文本** `SQUASH HOST PROBE: ALL-OK`(不看退出码:挂住时 --quit-after 也退 0)。
#
# - 断言一律打在**可观测的** `player.animator.scale` 上,不打 _pre_move_vy ——
#   前者同时验证了 suppressed/钳位链没被绕开,后者是内部量。
# - 每相另附**前提断言**(water/latch/floor 帧数):没有它,几何一漂这相就变成
#   "什么都没测"却照样测试全部通过的虚假通过（未有效测试）。
# 注意： 与 brief 预期的一处出入(实测,见 _tick_water 上方的长注释):人站在实心地面上时
#   脚底探针恒落在**支撑格自己**里,而支撑格是 wall  ->  **站定后 in_water 恒假**,
#   故"站定后每帧触发落地分支、稳态 ~9% 挤压"并不成立。谓词核心作用是覆盖并解决**水中下沉期**
#   那几十帧(健康态精确 1.0,删掉谓词后 0.9863)。梯那一相(spec 里同形的另一条)
#   才是"每帧、且钳到满幅 10%"的那条,实测复数无误。

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
# 取 0.005 = 满幅的 5%:健康态在这些相里是**逐帧精确 1.0**(_air 与 _impulse 都恒为 0,
# `1.0 - 0.10*0.0` 是浮点精确的),所以容差只需容下浮点噪声与指数尾巴(实测 <= 1e-5);
# 而删掉那个谓词后阶段 2(梯底)的真实偏离是满幅 10%(0.10,= 本容差的 20 倍)。
# - 阶段 1 的**水中帧**那一半**不走这个常量** —— 它的余量薄一档,单列 WET_EPS。
const NEUTRAL_EPS := 0.005
# 阶段 1 **水中帧**那一半的上限(比 NEUTRAL_EPS 紧一档)。阶段 1 的出生点**就在水里**,
# 窗口里没有"入池前的空中尾巴",故健康态在 in_water 帧上是**精确 1.0000**(实测 0.0000);
# 而鉴别信号 = `clamp(320/700)*0.30 = 0.1371` → 偏 0.0137。拿 NEUTRAL_EPS 当上限只有 **2.7 倍**
# 余量 —— `player_swim_down` 若被调到 ~117 以下,这一半会**静默**失去判定有效性(绿的运行
# 打印 `max dev 0.0000`,余量在输出上根本看不见)。收到 1e-3 后余量 ≈ **14 倍**;
# 健康态是浮点精确的 0.0,不会误伤。
const WET_EPS := 0.001
# 站定末态的容差(阶段 1)。比 NEUTRAL_EPS 松:入池触底那一下是**正当**的落地冲击 ——
# 玩家浮到池底前 1px 时 `in_water` 先翻假(脚底探针比碰撞箱底边低 1px,见报告),
# 随后一帧吃到重力(320 + 1600/60 = 346.7 > 落地下限 220)→ k=0.186 → 0.0185 的挤压,
# 再按 0.861^n 指数衰减。窗口末(触底后 ~30 帧)残余 ≈ 3e-4,故 0.01 有 30 倍余量。
# - 这一条**不具判定有效性**(那个冲击两个版本一模一样),它只是把 brief 的字面要求钉在文件里;
#   阶段 1 真正的鉴别点是下面按 in_water 帧取的极值。
const SETTLED_EPS := 0.01
# 反例门槛:干地高处落地必须压到**满幅的一半**以上(实测 k=1 → 满幅 0.10,再经当帧指数恢复
# 降到 scale.x = 1.0861,仍比门槛高 0.0361)。
# 注意： 极值**只取落地帧**(`_floor_max_x`),不取整个窗口 —— 本阶段是本文件**唯一的方向断言**,
#   而"方向被反过来"正是 2026-09-20 真发生过一次的缺陷,所以它的余量必须**结构性**成立、
#   而不是碰巧够宽(`1.0 → 1.0300` 差 0.02 那种)。按帧分类把两条同向写 scale.x 的路径
#   (空中连续项 / 落地冲击)拆开,互为噪声的关系就没有了:
#   - 正向(现公式):落地帧被下压到 **1.0460**(= 1 + amount·e^(−recover/60)),门槛 1.0300,
#     余量 **+0.0160**;反向则是 0.9730,余量 **−0.0570**(2026-09-21 实测)。
#   - 反向(`1.0 + _amount * v`):落地帧上全是**拉伸**(< 1.0) ->  判据红。
#    ->  空中项今天**不可能**再稀释本判据(它不对任何落地帧的读数作贡献);"整窗口取极值"那版
#     拿空中的拉伸当极值,失败余量只剩约 0.02,而 `squash_air` 一抬高就会把**反向**公式
#     顶过门槛、判据静默转绿。**那正是本阶段改用"只取落地帧"的原因。**
#   注意： 上面两条余量**随 `squash_amount` / `squash_recover` 移动**,不是常数:
#     2026-09-21 把 amount 0.10→0.06、recover 9→16 之后,正向余量从 +0.0361 缩到 +0.0160。
#     改这两个常量时**必须重跑本阶段并重算**,别照旧数字判断余量还够不够。
const DROP_MIN_SQUASH := 0.5
# 注意： 判据还只取**落地后的前 `DROP_FLOOR_FRAMES` 帧**,不是整个 floor 窗口 —— -  这一条是
#   实测迭代出来的,别"简化"回整个 floor 窗口:落地冲击是**一次性**的(只在落地那一帧写
#   满幅),此后每一帧都只是向 1.0 收敛的指数尾巴,而**尾巴两个方向都有**(公式反了同样向
#   1.0 收敛) ->  窗口越长、反向公式的极值越贴近 1.0,判据就**自动**失效。实测:本阶段落地在
#   第 ~43 帧而窗口开到 70 帧,尾巴有 27 帧,于是"整个 floor 窗口"那版的反向读数是 **0.9983**
#   (失败余量 0.0517 —— 只比"整窗口"那版的 0.02 强 2.6 倍,不达标);截到前 3 帧后反向读数
#   是 **0.9362**,失败余量 **0.1138**(5.7 倍)。
# - 取 3 帧而不是 1 帧:给"分类错开一帧"留余量(见 `_sample` 的错帧说明)——真实的落地输出
#   是首个落地帧或其下一帧,3 帧两者都盖得住,而尾巴要 5 帧以后才追上来。
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
const LADDER_LATCH_AT := 8     # 在空中按一下「上」抓住梯子(按住 S 时落地会成为蹲,蹲会解除攀附)

# ── 阶段 5(倒地)── 见 `_tick_downed` 上方那段:它一次覆盖 player.gd 里**两处**此前没人守的契约。
# 落体帧数取 30:阶段 3 实测全程落地在第 ~43 帧,故此刻人还在空中(~205px 高)、落速已 ≈ 800 ——
# 恰好是"带着落速被打倒"这个前提;再 8 帧也只落下 ~110px,窗口内始终在空中。
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

# 窗口统计(每相开始时清零)
# - 两者都只给阶段 3 用:挤压方向是 x>1(宽矮),故极值取**最大** scale.x。
#   `_floor_max_x` 是**判据**(只见落地帧,见 DROP_MIN_SQUASH);`_max_x` 是**读数**
#   (整个窗口,含空中拉伸项),留着是为了让"空中项到底有没有参与"在输出上一眼看得出。
var _max_x := -INF
var _floor_max_x := -INF
var _floor_max_x_frame := 0
var _floor_seen := 0           # 已被分类为"落地帧"的采样数(判定 DROP_FLOOR_FRAMES 窗口用)
# 上一次采样读到的 is_on_floor()。**分类专用**,见 _sample 上方的错帧说明。
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


# ── 每相换一个**全新**的玩家 ──
# squash 的 _impulse 是内部累计量、没有公开复位口,复用同一实例会把上一相的余量
# 带进本阶段测试窗口(指数尾巴 0.861^n,要 20+ 帧才掉到容差以下)。新实例从 0 起,窗口干净。
func _begin(stage: int) -> void:
	_stage = stage
	_f = 0
	_max_x = -INF
	_floor_max_x = -INF
	_floor_max_x_frame = 0
	_floor_seen = 0
	# - 必须归 false:上一相末态多半是"站在地上",留 true 会把本阶段**出生时**的空中帧
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


# 采样(本探针的 _physics_process 跑在子节点之前,故读到的是**上一帧**宿主写出的 scale;
# 窗口是按帧取的极值,错开一帧无影响 —— 但**分类**受影响,见下)。
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
		# 阶段 3 的判据只认**落地帧**(见 DROP_MIN_SQUASH / DROP_FLOOR_FRAMES):
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


# ── 阶段 3 反例(必须有):干地高处落下**必须**真的挤压 ──
# 没有它,阶段 1②可以靠"永不挤压"作弊通过。
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


# ── 阶段 1 水中按住 S 下沉到池底:水中全程中性 ──
# - 前提:窗口里必须有**在水中的帧**(否则这相退化成干地站立、恒绿)。
# - 断言按 **in_water 为真的帧**取极值,不按整个窗口:
#   删掉谓词后真实偏离出现在**下沉期** —— 空中项 `|320|/700*0.30 = 0.1371` →
#   scale.x 0.9863(健康态是 **0.0000** 的偏离)——而那几十帧全在 in_water 为真时;
#   反观"整个窗口"里最大的偏离是入池触底那一下**正当**的重力冲量(0.0185,两个版本
#   一模一样,见 SETTLED_EPS 的推导),拿它当判据会把容差撑到鉴别点之上。
# - 另记 in_water ∧ is_on_floor 的重叠帧数:本几何下它是 **0** ——
#   `Water.feet_offset` 返回的是**启用中碰撞箱的世界底边**相对原点的偏移,本探针实测 **58px**。
#   注意： 但这个 58 与"某个姿态碰撞盒"**不是一回事**,别把它们读成同一个数(本注释 2026-09-20 订正过):
#     - 58(探针实测值)= **第一帧缓存下来的合并值**。`Water.feet_offset` 按 `_feet_signature()`
#       缓存,而那个签名只累加 `CollisionShape2D` 子节点的 instance_id —— 玩家的 5 个姿态碰撞盒
#       全是 `CollisionPolygon2D`  ->  **签名恒 0  ->  缓存永不失效**,它冻结在**首次调用那一刻**
#       的几何上;那一刻 5 个姿态碰撞盒还没被 `_tick_pose_and_collision` 收敛成单一碰撞体,合并后的底边
#       = 最低的那个 = charge 的 58。
#     - 57 / 58(姿态碰撞盒自己的底边)= **两个档位**:站立/移动/蹲/飞是 **57px**,只有 charge 是 **58px**。
#   下面那条结论("脚底探针落在支撑格自己里")依赖的正是 **57 那一档**:58 > 57  ->  探针比站姿
#   身体底边**低 1px**,人站在实心地面上时它就越过格线落进**支撑格自己**,而支撑格是 wall
#    ->  站定后 in_water 恒假。故 brief 预期的"站定后每帧触发落地分支、稳态 ~9% 挤压"
#   在本作几何下**不成立**;谓词核心作用是覆盖并解决下沉期那几十帧(见报告)。
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


# ── 阶段 2 梯底按住 S:全程中性(坏了幅度最大:每帧 -0.735 直到钳位 → 满幅 10%) ──
# 推导:梯下行速度 = climb_speed 300 × tile_defs 梯 climb_descent_speed 2.0 ×
# climb_vertical_mult 1.2 = 720;落地下限 220、参考 900 → k = (720-220)/680 = 0.735,
# 每帧减 0.735 而指数恢复每帧只回 15% → 三四帧就钳到 -1.0 → scale=(1.1,0.9)。
# 攀附期间 _tick_crouch_and_dash 首行提前返回 → is_squat 永不置位 → 攀附也不解除 → **每帧**。
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


# ── 阶段 5 倒地:一次覆盖 player.gd 里**两处**此前都没人守的契约 ──
# `squash.tick(delta, _pre_move_vy, is_on_floor(), combat.is_downed())` 这一行里有两件事:
#   ① 第四参 = `combat.is_downed()`  ->  **倒地强制中性**。本地玩家不旋转,但副本会(根节点
#      `rotation = -90°`,而 animator 是它的**子节点**) ->  此时写 scale 会沿转过的轴挤压。
#      把这一参换成 `false` 后:倒地**下落期间**空中连续项照常生效  ->  屏幕上一条尸体
#      倒地翻转过程中被异常拉伸。本测试阶段专门针对刚被击倒且仍处于空中的前 8 帧进行状态校验。
#   ② 倒地分支里的 `_pre_move_vy = 0.0`  ->  缓存**归零**。不归零的话,被击杀那一刻的下坠速度
#      会**陈旧地**留满整个倒地窗口(该分支不跑 move_and_slide、没人刷新它),复活首帧一落到
#      地面上就与地面态配成一次**满幅假挤压脉冲**。删掉那一行,本阶段的第三段断言(复活后
#      6 帧)即变红 —— 而前两段照样测试全部通过,所以三段缺一不可。
# - 顺序必须"在带有下落初速度时倒地 → 落地 → 复活"整串走完:只读"倒地时中性"无法覆盖检测 ②(那一条的病只
#   在**复活那一帧**暴露异常)。本阶段的两条鉴别信号分别落在第二段与第三段,互不遮蔽。
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
			# 倒地**不取消物理**(与敌人统一):继续受重力直到落地
			_sample(0)
			if _p.is_on_floor():
				# 证据(不是判据):落地后缓存里还剩多少 —— 直接读出"归零那一行在不在"
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
