extends Node
# 对手副本(`PlayerReplica`)的补间形变**行为守卫**(Task 5 Step 2b)。
# 判据:SQUASH REPLICA PROBE: ALL-OK
# 跑法:"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/squash_replica_probe.tscn
#
# 为什么必须有(2026-09-20 Task 4 复审指出):
#   Task 4 给副本加的**水查询**与**落地判据的第二半**,此前**没有任何常驻守卫** ——
#   `tests/probe/squash_host_water_probe` 只驱动**玩家本体**,`tests/probe/squash_stretch_probe` 只消费
#   `player.gd` 的 `var squash`。把 `player_replica._process` 里的 `_in_water()` 那两行删掉、
#   或把传参换回 `_vel.y`,**现有测试一条都不会红**。而副本恰恰是本特性唯一"没有物理可对照、
#   只能从快照推导"的一环,Task 4 三轮发现的问题**全部**发生在这一环。
#
# 做法:合成网格(照 tests/probe/squash_host_water_probe 的建图函数取一份)+ **真 `PlayerReplica`**
#   实例(真 tscn、真 `_ready`:真幽灵体、真 `Water.feet_offset` 脚底探针)+ **真快照字典**
#   (键与 `server/match_snapshot.gd` 的 `world["players"][role]` 逐字一致 —— -  这句话由**相⓪**
#   对着生产端源码**真的校验**,不再是靠人读:夹具键是手写的,而生产端删掉 `"vel"` 会让四相
#   测试全部通过、对局里对手的形变静默消失,那正是相⓪ 要堵的洞),
#   逐帧 `apply_snapshot()` + 显式 `_process(dt)`。
#
# - 为什么显式调 `_process` 而不是交给引擎:`_process` 的 `delta` 是**变帧率**的(headless 下
#   引擎能跑多快跑多快),而本文件的全部期望值都是从 `delta = 1/60` 推出来的。显式传固定
#   `DT` 才有确定性的读数;`set_process(false)` 关掉引擎那一份,避免同一帧被推进两次。
# - 断言一律打在**可观测的** `replica.animator.scale` 上(不打 `_impulse` 这类内部量):
#   它同时验证了"过滤/配对/抑制"整条链没被绕开。
# - 每一相都带**前提断言**,而且前提是"**把守的那一行若删掉,这一相会真的变红**"这件事本身:
#   阶段 1 前提 = `_prev_vel_y` 确实是 320(即:没有水查询的话空中连续项会真的触发);
#   阶段 2 前提 = 上一帧落速确实是 900(即:落地判据的另一半手里有值);
#   阶段 3 前提同上 + 姿态确实不是 FLY(即:pose 那一半确实为真)。
#   没有这些前提,几何一漂(例如位置挪进了水里)这相就变成"什么都没测"却照样测试全部通过的测试漏检。
#
# 注意： 相⓪ 是**双向**的:它把夹具键集与生产端(`server/match_snapshot.gd`)那张字面量表的键集
#   **互相**对账 —— 生产端**多**一个字段(或本夹具少喂一个)同样报红。故**往快照里加任何字段
#   都会让本探针变红**,那是**已知的维护动作**(照新字段给 `_snapshot_dict()` 补一行即可),
#   不是误报,更不是"生产端坏了"。反过来,这正是不加这条守卫时的失败形态:夹具与生产端各自
#   漂移、四相测试全部通过,而对局里对手的形变静默消失。

const REPLICA_SCENE := preload("res://scenes/player/player_replica.tscn")

const DT: float = 1.0 / 60.0

# ── 合成网格(确定性,与 tests/probe/squash_host_water_probe 同形状):底行实心 + 一片水池 ──
# (该文件的网格多一条梯;副本手里没有 `latched`,梯那一半本轮**刻意不补**,故本探针不需要它。
#  两地形状不同 —— 各留各的,不硬并。)
const COLS := 60
const ROWS := 14
const WATER_X0 := 16           # 水池列区间 x 16..24(rows 2..12)
const WATER_X1 := 24
const WATER_ROW0 := 2
const FLOOR_TOP_Y := float((ROWS - 1) * 64)   # 832

const DRY_X := 35 * 64 + 32                    # 干地列(在水池之外)
const AIR_Y := 400.0                           # 干地上方的空中
const REST_Y := FLOOR_TOP_Y - 57.0             # 775:站姿碰撞箱底边距原点 57px(实测)
# 水里的停位:脚底探针 = global_position.y + _water_feet_off(= 57,真幽灵体量出来的)
# 落在池子中段那一格(y 512..575) ->  probe y = 544。
const WATER_CELL_ROW := 8
const WATER_POS := Vector2((WATER_X0 + 4) * 64 + 32, float(WATER_CELL_ROW * 64 + 32) - 57.0)

# pose 枚举值,与 player.gd 的 `enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }` 一致
# (player_replica.POSE_FLY 也是这么定的 —— 参考类不继承 Player,引用不到那个枚举)。
const POSE_MOVE := 1
const POSE_FLY := 2
const POSE_CHARGE := 3

# ── 容差 ──
# 健康态在阶段 1/阶段 4 是**浮点精确**的 1.0(`1.0 - amount*0.0`),故下限只需容下浮点噪声。
# 而 ① 的鉴别信号 = `clamp(320/700)*0.30 = 0.1371`  ->  偏 0.01371(禁用水查询后实测
# scale = (0.986286, 1.013714)),是本容差的 **137 倍**。
const EPS := 1e-4
# 阶段 2 的反例门槛:落地那一帧必须压到**满幅的一半**以上。
# 推:上一帧落速 900 → k = clamp((900-220)/680) = 1 → _impulse = -1,当帧指数回归后
# v = -(1 - exp(-9/60)) = -0.86071  ->  scale = (1.086071, 0.913929)。
# 实测余量 = 0.086071 - 0.05 = +0.0361。换回 `_vel.y` 后这一帧的 vel_y 是 0(服务器在
# 落地那一拍就清零了) ->  落地项**永不触发**  ->  scale = (1.0000, 1.0000),失败余量 0.05。
const DROP_MIN_SQUASH := 0.5

# ── 相⓪ 生产端字段表对账 ──
# - 本探针传入 `apply_snapshot()` 的字典是**手写**的,文件头声称"键与 server/match_snapshot.gd
#   逐字一致" —— 补上这条守卫之前,**那句话没有任何东西在管**。后果不是抽象的:把生产端的
#   `"vel": p.velocity` 删掉/改名,四相**测试全部通过**,而对局里对手的形变**静默消失**(副本的
#   `_prev_vel_y` 恒 0  ->  空中项恒 0、落地项永不触发,一个字都不打)。
#   判据 = 夹具键集与**生产端真源码**里那张字面量表**双向相等**:生产端少了 = 探针在喂一个
#   不存在的字段(红);生产端多了 = 夹具漏喂(红 —— 说明头注的"逐字一致"已经不成立)。
#   - 这是**源码级**守卫(不是行为级):`MatchSnapshot._broadcast_snapshot()` 是"构造 + 广播"一体的,
#   载荷不外流、无法从返回值上读到,故"读真源码里那张表"是能做到的最便宜的**真**校验
#   (它读的是生产文件本身,不是本探针自己的字面量)。
# - 读不到源文件/定位不到那张表时**必须报红**而不是静默跳过 —— 源码级守卫最典型的失明方式
#   就是"文件改了名  ->  什么都没读到  ->  断言恒真"。
const SNAPSHOT_SRC := "res://server/match/match_snapshot.gd"
const SNAPSHOT_MARK := 'world["players"][str(role)] = {'

const S_WATER := 0
const S_DROP := 1
const S_AIR_DASH := 2
const S_DOWNED := 3
const S_DONE := 4

const WATER_FRAMES := 45
# 阶段 2 的读数帧 = **落地那一帧本身**(第 2 帧)。
# - 不能多跑一帧再读:落地挤压是**一次性**的,此后每帧都在按 `1 - exp(-9/60) = 0.1393`
#   向 0 回归 —— 晚一帧读到的就是 `-0.7408`(scale.x 1.0741)而不是 `-0.8607`(1.0861),
#   失败余量从 +0.0361 缩到 +0.0241。这不是"差不多",是把判据的余量白送掉三分之一。
const DROP_FRAMES := 2
const DASH_FRAMES := 3         # ≥2:第 1 帧 `_prev_vel_y` 还是 0(新组件),第 2 帧起才是 900
# 阶段 4 的判据窗口 = 倒地后**至少 8 帧**(不是 1 帧)。
# - 单帧窗口只看得见"倒地那一刻"的 scale:一个"要两帧才收敛到中性"的回归在第一帧上可能
#   已经落回容差内(或反过来,第一帧偶然中性而后面才开始漂),单帧读**两边都漏**。
#   `_max_dev` 取的是窗口内的**最大值**,故加宽是**单调更强**的判据,不会放松任何东西。
const DOWNED_FRAMES := 8
const DOWNED_ASSERT_AT := 2 + DOWNED_FRAMES   # 灌值 1 帧 + 前提读数 1 帧 + 倒地 8 帧(判据)

var _rep: Node2D = null
var _dead := false             # 空载守卫已判死(见 _begin):后续帧直接不跑
var _stage := -1
var _f := 0
var _tick := 0
var _total := 0

var _fails: Array[String] = []

# 窗口统计(每相开始时清零)
var _max_dev := 0.0
var _max_dev_frame := 0
var _last_scale := Vector2.ONE
var _water_frames := 0
var _prem_prev_vy := 0.0       # 本阶段里"喂 `_prev_vel_y` 那一帧"读到的原始上一帧落速
var _prem_ok := true


func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	print("[squash_replica] 合成世界 %dx%d 格;水池 x %d..%d y %d..;干地列 x=%d;水里停位 %s" % [
			COLS, ROWS, WATER_X0, WATER_X1, WATER_ROW0, DRY_X, str(WATER_POS)])
	_check_producer_keys()
	_begin(S_WATER)


# ── 相⓪:夹具键集 vs 生产端字段表(见 SNAPSHOT_SRC 上方那段)──
func _check_producer_keys() -> void:
	var fixture: Array = _snapshot_dict(Vector2.ZERO, POSE_MOVE, false, Vector2.ZERO).keys()
	fixture.sort()
	var producer := _producer_keys()
	if producer.is_empty():
		_record("相⓪ 前提:能从 %s 里定位到玩家载荷字典" % SNAPSHOT_SRC, false,
			"读到的字段表为空(文件改名?那张表被重写了?)—— 静默跳过会让本相退化成空转")
		return
	var missing: Array = []
	for k in fixture:
		if not producer.has(k):
			missing.append(k)
	var extra: Array = []
	for k in producer:
		if not fixture.has(k):
			extra.append(k)
	_record("相⓪ 夹具键集 == server/match_snapshot.gd 的玩家载荷字段表",
		missing.is_empty() and extra.is_empty(),
		"夹具 %d 键 / 生产端 %d 键;生产端缺 %s(探针在喂不存在的字段)、夹具漏喂 %s" % [
			fixture.size(), producer.size(), str(missing), str(extra)])


# 从生产端源码里取出那张字面量表的键(升序)。
# - 用 `code_only`(剥注释)而不是裸文本:一句提到字段名的**注释**会把被删掉的键重新误判通过。
func _producer_keys() -> Array:
	var code := ScanUtil.code_only(ScanUtil.read(SNAPSHOT_SRC))
	var at := code.find(SNAPSHOT_MARK)
	if at < 0:
		return []
	var open := at + SNAPSHOT_MARK.length() - 1        # 指向 '{'
	var close := _match_brace(code, open)
	if close < 0:
		return []
	var block := code.substr(open + 1, close - open - 1)
	# 该表的**值**全是表达式(没有字符串字面量),故 `"名":` 这个形状只会匹配到键。
	# 将来若真出现"值是字符串"的字段,这里要改成按顶层逗号切分。
	var re := RegEx.new()
	re.compile("\"([A-Za-z_][A-Za-z0-9_]*)\"\\s*:")
	var out: Array = []
	for m in re.search_all(block):
		out.append(m.get_string(1))
	out.sort()
	return out


# 与 open 处 '{' 配对的 '}' 下标(跳过字符串内的花括号;找不到返回 -1)。
# 形状照 ScanUtil.match_paren —— 那一支只认圆括号。
func _match_brace(src: String, open: int) -> int:
	var depth := 0
	var in_str := false
	var j := open
	while j < src.length():
		var ch := src[j]
		if in_str:
			if ch == "\\":
				j += 2                                  # 转义:连同下一字符一起跳过
				continue
			if ch == "\"":
				in_str = false
		elif ch == "\"":
			in_str = true
		elif ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				return j
		j += 1
	return -1


func _build_grid() -> Array[Array]:
	var ts_wall := 31            # 纹理1 全砖(墙)
	var ts_water := 21 * 16 + 15
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			var v := 0
			if y == ROWS - 1:
				v = ts_wall                       # 底行整行实心地
			elif x >= WATER_X0 and x <= WATER_X1 and y >= WATER_ROW0:
				v = ts_water                      # 水(liquid,无碰撞)
			row.append(v)
		grid.append(row)
	return grid


# ── 每相换一个**全新**的副本 ──
# `_impulse` 是组件内部累计量、没有公开复位口,复用同一实例会把上一相的余量带进本阶段测试窗口
# (指数尾巴 0.861^n,要 20+ 帧才掉到容差以下)。新实例从 0 起,窗口干净。
# (与 tests/probe/squash_host_water_probe._begin 相同机制。)
func _begin(stage: int) -> void:
	_stage = stage
	_f = 0
	_tick = 0
	_max_dev = 0.0
	_max_dev_frame = 0
	_last_scale = Vector2.ONE
	_water_frames = 0
	if _rep != null and is_instance_valid(_rep):
		_rep.queue_free()          # 延后释放:它已 set_process(false) 且本探针不再驱动它
	_rep = REPLICA_SCENE.instantiate()
	# - 空载守卫:`player_replica.gd` 一旦**解析不过**(语法错/被改坏),tscn 的根就退化成
	#   一个裸 Node2D —— 场景照样加载、`_physics_process` 照样跑,但每帧刷
	#   "Nonexistent function 'apply_snapshot'",而**一行判据都不会打印、退出码还是 0**。
	#   那正是 docs/eng/tests.md 记的"看着像功能坏了"的形态(实测踩到过:变异 ③ 的锚点写歪成语法错)。
	#   这里把它变成一条响亮的失败。
	if not _rep.has_method("apply_snapshot"):
		_dead = true
		print("SQUASH REPLICA PROBE: FAIL | PlayerReplica 脚本没加载起来(解析错?根节点是 %s)" % _rep.get_class())
		get_tree().quit(1)
		return
	add_child(_rep)
	_rep.global_position = _pos_of(stage)
	# 本探针逐帧显式调 `_process(DT)`,不交给引擎(理由见文件头)
	_rep.set_process(false)


func _pos_of(stage: int) -> Vector2:
	match stage:
		S_WATER:
			return WATER_POS
		S_DROP:
			return Vector2(DRY_X, REST_Y)
		S_AIR_DASH, S_DOWNED:
			return Vector2(DRY_X, AIR_Y)   # 干地上方的空中(水上那一栏会清零 vel_y,不能用)
	return Vector2(DRY_X, REST_Y)


# 喂一份**真快照字典**(键与 server/match_snapshot.gd 的 world["players"][role] 逐字一致),
# 然后显式跑一帧 `_process`。
# 夹具字典的**唯一构造点**(相⓪ 拿它的键集与生产端对账  ->  只有一份,不会两处各写一遍)。
# 内容刻意取"中性可过"的值:本探针只关心键的**存在性**,不关心假数据本身合不合理
# (每相真正要的值由 `_step` 的三个实参决定)。
func _snapshot_dict(vel: Vector2, pose: int, downed: bool, pos: Vector2) -> Dictionary:
	return {
		"pos": pos,
		"vel": vel,
		"facing": 1,
		"pose": pose,
		"type_id": 0,
		"hp": 100,
		"waterproof": 100.0,
		"downed": downed,
		"aim": Vector2(1.0, 0.0),
		"previewing": false,
		# - 2026-10-02 合并补充:KH 的时间玩法往每玩家载荷里加了这三个(B22/B23 的加速与回溯视效)。
		#   相⓪ 立刻把这段漂移**明确提示**了出来("夹具漏喂 [haste, rewind, trail]")—— 正如本文件
		#   注释所说:往快照里加字段会让本探针变红,那是**已知的维护动作**,不是误报。
		#   本探针四相只看位置/速度/姿态  ->  这三个给中性值即可(不影响任何一条断言)。
		"haste": false,
		"rewind": false,
		"trail": [],
	}


func _step(vel: Vector2, pose: int, downed: bool) -> void:
	var pos := _rep.global_position
	_rep.apply_snapshot(_snapshot_dict(vel, pose, downed, pos), pos, _tick)
	# - 顺序:apply_snapshot 只**记录**数据(_vel/_pose/_downed),衰减与写 scale 都在 _process。
	# (下表由 `_snapshot_dict` 唯一构造 —— 相⓪ 就是拿它的键集去与生产端对账的。)
	#   本探针在 _process 之前读一次 `_prev_vel_y` —— 那时它还是**上一帧**的值,正是 `tick()`
	#   即将消费的那一个。这是阶段 1②③ 前提断言的来源。
	_prem_prev_vy = _rep._prev_vel_y
	_tick += 1
	_rep._process(DT)
	_f += 1
	var s: Vector2 = _rep.animator.scale
	_last_scale = s
	var dev := maxf(absf(s.x - 1.0), absf(s.y - 1.0))
	if dev > _max_dev:
		_max_dev = dev
		_max_dev_frame = _f
	if _rep._in_water():
		_water_frames += 1


func _physics_process(_delta: float) -> void:
	if _dead or _rep == null or not is_instance_valid(_rep):
		return
	_total += 1
	match _stage:
		S_WATER:
			_tick_water()
		S_DROP:
			_tick_drop()
		S_AIR_DASH:
			_tick_air_dash()
		S_DOWNED:
			_tick_downed()


# ── 阶段 1 水中下沉 → 中性 ──
# 输入:pose 取本体在水里的姿态(MOVE),`vel.y` 恒为 `player_swim_down`(=320,一个常量)。
# 结果:副本的 `_in_water()` 为真  ->  传给 tick 的 vel_y 被置 0  ->  `_air == 0` 且落地项
#   (`0 > 220`)不成立  ->  逐帧精确中性。
# 变异(必做):把 `_process` 里 `if _in_water(): vel_y = 0.0` 那一段去掉  ->  本阶段必须红,
#   复现 `clamp(320/700)×0.30 = 0.1371` 的拉伸(scale = (0.986286, 1.013714))。
func _tick_water() -> void:
	_step(Vector2(0.0, PlayerParams.player_swim_down), POSE_MOVE, false)
	if _f >= WATER_FRAMES:
		_record("相① 前提:窗口内每帧都在水里", _water_frames == WATER_FRAMES,
			"water 帧 %d / %d(位置 %s)" % [_water_frames, WATER_FRAMES, str(WATER_POS)])
		_record("相① 前提:喂进去的上一帧落速确实是 player_swim_down", is_equal_approx(_prem_prev_vy, PlayerParams.player_swim_down),
			"_prev_vel_y = %.4f(需 == %.4f)—— 没有水查询时空中连续项会真的触发" % [
				_prem_prev_vy, PlayerParams.player_swim_down])
		_record("相① 水中下沉全程中性(scale == Vector2.ONE)", _max_dev <= EPS,
			"max dev %.6f(帧 %d),上限 %.6f;末值 scale=(%.6f,%.6f)" % [
				_max_dev, _max_dev_frame, EPS, _last_scale.x, _last_scale.y])
		_begin(S_DROP)


# ── 阶段 2 干地真落地 → 仍挤压(反例,必须有)──
# 没有这一相,阶段 1 可以靠"永远中性"的假实现作弊通过。
# 输入:前一帧 `vel.y = 900` + pose FLY(在空中下落),当帧 `vel.y = 0` + pose MOVE(落地)。
# 结果:`on_floor` 两半成立(pose != FLY 且 |当前 vel.y| < 1) ->  落地项用**上一帧**的 900
#   触发  ->  scale.x = 1.086071(宽矮 = 挤压)。
# 变异(必做):把 `squash.tick(delta, vel_y, ...)` 换回 `squash.tick(delta, _vel.y, ...)`
#    ->  落地那一帧 vel_y 是 0  ->  落地项**永不触发**  ->  scale.x == 1.0000,本阶段必须红。
func _tick_drop() -> void:
	if _f == 0:
		_step(Vector2(0.0, 900.0), POSE_FLY, false)     # 空中下落
		return
	_step(Vector2.ZERO, POSE_MOVE, false)               # 落地那一帧(本阶段的读数帧)
	if _f >= DROP_FRAMES:
		var want: float = 1.0 + DROP_MIN_SQUASH * PlayerParams.squash_amount
		_record("相② 反例:干地真落地必须仍挤压", _last_scale.x >= want,
			"落地帧 scale.x %.6f(需 >= %.6f = 满幅的 %d%%),余量 %+.6f;前进气值 900、当帧 0" % [
				_last_scale.x, want, int(DROP_MIN_SQUASH * 100.0), _last_scale.x - want])
		_record("相② 附:方向必须是宽矮(x>1 且 y<1,不越满幅)", _last_scale.x > 1.0 and _last_scale.y < 1.0
				and absf(_last_scale.x + _last_scale.y - 2.0) < 1e-5,
			"落地帧 scale=%s(x+y=%.6f,恒为 2)" % [str(_last_scale), _last_scale.x + _last_scale.y])
		_begin(S_AIR_DASH)


# ── 阶段 3 落地判据的**两半**都在(专门验证 Task 4 只做 pose 那一半的旧 bug)──
# 输入:pose **不是** FLY(模拟本体"下落途中起步的冲刺"—— 本体把 is_charge 判在
#   `not is_on_floor()` **之前**,故这种姿态在服务器快照里就是 on_floor 的代理),
#   但当前 `vel.y` 仍然很大(冲刺只改 velocity.x)。
# 结果:`absf(_vel.y) < LAND_VEL_EPS` 那一半为假  ->  on_floor 为假  ->  落地项**不得**触发,
#   只剩下空中连续项(拉伸:scale.x = 1 - clamp(900/700)·0.30·0.10 = 0.970000)。
# 变异(必做):把 `absf(_vel.y) < LAND_VEL_EPS` 从 on_floor 的谓词里去掉  ->  落地项每帧
#   用上一帧的 900 触发  ->  scale.x = 1.086071 > 1.0,本阶段必须红。
func _tick_air_dash() -> void:
	_step(Vector2(0.0, 900.0), POSE_CHARGE, false)
	if _f >= DASH_FRAMES:
		_record("相③ 前提:姿态确实不是 FLY 且上一帧落速确实是 900", _rep._pose != POSE_FLY and is_equal_approx(_prem_prev_vy, 900.0),
			"pose = %d(需 != %d),上一帧 vel.y = %.4f(需 == 900)—— 只看 pose 那一半的话落地项会在这里触发" % [
				_rep._pose, POSE_FLY, _prem_prev_vy])
		_record("相③ 落地项未触发(scale.x 不得越过 1.0)", _last_scale.x <= 1.0,
			"末帧 scale=%s;旧 bug(只做 pose 那一半)下这里会是 1.086071" % str(_last_scale))
		_record("相③ 附:空中连续项确实在工作(拉伸,x<1)", _last_scale.x < 1.0,
			"末帧 scale.x %.6f(< 1.0;1.0000 说明 tick 根本没在消费 vel_y)" % _last_scale.x)
		_record("相③ 附:副本此刻不在水里(否则 vel_y 被清零,本相退化成空转)",
			_water_frames == 0, "water 帧 %d / %d" % [_water_frames, DASH_FRAMES])
		_begin(S_DOWNED)


# ── 阶段 4 倒地 → 强制中性 ──
# 副本倒地时给**根节点**设 `rotation = -PI/2 * facing`,而 animator 是它的**子节点**  -> 
# 此时写 scale 会沿**转过的轴**挤压(尸体横着变宽)。故 `_downed` 必须当 suppressed 传下去。
# 断言前必须让 scale **本来是非中性的** —— 否则本阶段只是在"本来就中性"的基线上断言,
# 把 suppressed 那一行删掉也照样绿。
# - 前提态刻意取**空中连续项**(姿态 FLY、vel.y = 900  ->  `_air = 0.3`  ->  scale.x = 0.97),
#   **不取落地冲击**:落地那一对值(上一帧大、当帧 ≈0)正是 ② 号变异动的那一处 ——
#   拿它当前提,② 号变异会让**本阶段的前提**一起红,四相就不再"各自只被自己那一处变异测试失败"。
#   空中项与三个变异都不搭界(它只看 `_air`,且 `pose == FLY` 让 on_floor 恒假),互不干扰。
# - 判据窗口是**倒地后 `DOWNED_FRAMES` = 8 帧**(不是倒地那一帧):`_max_dev` 取窗口内最大值,
#   故加宽只会更严 —— 覆盖"要两帧才收敛"(第一帧偶然落在容差内)与"第一帧偶然中性、后面才漂"
#   这两种单帧读法**两边都漏**的回归。
func _tick_downed() -> void:
	if _f <= 1:
		# 第 1 帧只是把 900 灌进 `_prev_vel_y`(新组件的 `_prev_vel_y` 从 0 起,当帧还用不上);
		# 第 2 帧才是前提读数 —— 那时空中连续项成立,scale.x = 0.97。
		_step(Vector2(0.0, 900.0), POSE_FLY, false)
		if _f == 2:
			_record("相④ 前提:倒地之前 scale 确实是**非中性**的", _last_scale.x < 1.0 - 1e-3,
				"空中帧 scale=%s(把 suppressed 那一行删掉后,本相就是从这里出发的)" % str(_last_scale))
			# - 复位判据窗口:上面那一帧是**前提**用的 —— 不归零的话 `_max_dev` 会攥着它的
			#   0.03,即使 suppressed 完全失效本阶段也照样红,判据退化成"只是在读前提"。
			_max_dev = 0.0
			_max_dev_frame = 0
		return
	_step(Vector2(0.0, 900.0), POSE_FLY, true)          # downed = true
	if _f >= DOWNED_ASSERT_AT:
		_record("相④ 倒地(downed=true)强制中性(%d 帧窗口)" % DOWNED_FRAMES, _max_dev <= EPS,
			"倒地后 %d 帧的 max dev %.6f(帧 %d,上限 %.6f),末值 scale=(%.6f,%.6f);副本根节点 rotation=%.4f" % [
				DOWNED_FRAMES, _max_dev, _max_dev_frame, EPS, _last_scale.x, _last_scale.y, _rep.rotation])
		_finish()


func _record(label: String, ok: bool, detail: String) -> void:
	var line := "%s %s —— %s" % ["OK  " if ok else "FAIL", label, detail]
	print("[squash_replica] %s" % line)
	if not ok:
		_fails.append("%s(%s)" % [label, detail])


func _finish() -> void:
	if _rep != null and is_instance_valid(_rep):
		_rep.queue_free()
	if _fails.is_empty():
		print("SQUASH REPLICA PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("SQUASH REPLICA PROBE: FAIL | %d 条: %s" % [_fails.size(), "; ".join(_fails)])
		get_tree().quit(1)
