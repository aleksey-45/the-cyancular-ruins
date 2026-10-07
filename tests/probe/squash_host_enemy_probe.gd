extends Node
# 敌鸟侧宿主接线的自动化测试探针(Task 3 那份临时探针转正为常驻回归网)。
# 验收标准：SQUASH HOST ENEMY PROBE: ALL-OK
# 运行方式："$GODOT" --headless --path . --quit-after 3600 res://tests/probe/squash_host_enemy_probe.tscn
# 判定依据为文本(不看退出码:阻塞挂起时 --quit-after 也退 0)。
#
# 为什么必须有:`tests/` 下引用 `squash` 的只有四个 squash 文件,而它们全都不碰敌人 ——
#   于是 `enemy_base.gd` 这一整面接线"删得掉、且删了不会有任何测试变红":
#     - `_physics_process` 最首行的 `squash.tick(...)`
#       - 位置也是契约:必须在 `_is_far_sleeping()` 提前返回之前,否则睡眠中的鸟卡住形变
#     - 睡眠分支里的 `_pre_move_vy = 0.0`(醒来首帧满幅重触发的唯一修法)
#     - `_pre_move_vy = velocity.y`(裸值,敌人侧刻意不过滤,见 spec §2.4)
#     - `_apply_hit` 里的 `SquashStretch.Impulse.HURT`
#     - `_set_state` -> `_on_state_entered(s)` 派发本身 + 三只鸟各自的 5 处状态映射
#   —— 而这恰恰是本特性唯一真出过 bug 的面(2026-09-20,`b89420c`:睡眠提前返回让鸟永久变形、
#   醒来首帧的满幅挤压把起飞拉伸抵消成压扁)。断言清单照
#   `.superpowers/sdd/task-3-report.md` 第 3 节里那份临时探针的输出逐条恢复 ——
#   那份探针已删,它的输出是这些断言的唯一留存。
#
# - 极性照现在的组件读:正 v = 拉伸 = 窄高(scale.x < 1)、负 v = 挤压 = 宽矮(scale.x > 1)。
#   task-3 报告里那几行 `拉伸(scale.x > 1)` 是 `b89420c` 之前那份反转公式下的读数,别照抄。
# - 状态号不写死:从每个子类脚本的 `enum State` 现取(见 `_state_of`)。写死枚举号会让
#   "有人往枚举中间插了一个状态"变成静默测错状态;取不到名字则报红,不静默跳过。
# - 变量一律不静态定型(`var b = …` 而不是 `:=`):本探针按名字摸 `squash` / `_pre_move_vy`
#   这类成员,而它们不在 `Node2D` 的类签名上 —— 静态定型会让这些行解析期就报错。
# - 阶段 1②③ 一律 `_set_state(...)` / `_apply_hit(...)` 之后手动 `squash.tick(...)`,并把鸟的
#   自驱物理关掉:宿主真帧里 tick 就在最首行、参数由宿主给,这里要的是事件映射本身,
#   不是重跑一遍 AI。阶段 4 相反 —— 它必须走真的 `_physics_process`,因为要验的正是
#   "tick 的调用位置 + 缓存清零 + 醒来首帧"这三件事的协作,单看任何一个都测不出来。

const FLY := preload("res://scenes/enemies/enemy_fly_bird.tscn")
const BLACK := preload("res://scenes/enemies/enemy_black_bird.tscn")
const JUMP := preload("res://scenes/enemies/enemy_jump_bird.tscn")

const DT: float = 1.0 / 60.0

# ── 阶段 4 的合成网格(确定性):只有底行是墙,其余全空(不抄另两个探针的梯/水池,用不上)──
const COLS := 60
const ROWS := 14
const FLOOR_TOP_Y := float((ROWS - 1) * 64)   # 832:底行墙的顶面
const DROP_X := 40 * 64 + 32                  # 落点列(离阶段 1②③ 那些鸟很远,互不打扰)
const DROP_SPAWN_Y := FLOOR_TOP_Y - 200.0     # 空中,靠重力自己落地
const DROP_VY := 900.0                        # 落地前先给它一个真落速

# 健康态的容差。阶段 4 的"中性"是浮点精确的 1.0(`1.0 - amount*0.0`),故只需容下指数尾巴;
# 而鉴别信号(睡着的鸟每帧重触发落地项)是满幅 10%,是本容差的 1000 倍。
const EPS := 1e-4
# 落地那一刻 `_pre_move_vy` 的下限(前提断言):低于它这条相就退化成"什么都没灌进去"。
const MIN_LANDING_VY := 500.0
# 睡眠窗口帧数:指数尾巴要 `exp(-9·n/60) < EPS`  ->  n ≥ 62;取 100 留一倍余量。
const SLEEP_FRAMES := 100

const S_FINDING_B := 0
const S_DONE := 1

# ── 阶段 1 的断言表(数据驱动,加新敌人照抄一行)──
const STATE_CASES := [
	["FlyBird", FLY, "TAKE_OFF"],
	["FlyBird", FLY, "CHARGE"],
	["BlackBird", BLACK, "TAKE_OFF"],
	["BlackBird", BLACK, "CHARGE"],
	["JumpBird", JUMP, "LUNGE_DASH"],
	["JumpBird", JUMP, "BACK_HOP"],
]

var _stage := -1
var _f := 0
var _total := 0
var _fails: Array[String] = []
var _lines: Array[String] = []

# 阶段 4 的读数(变量不静态定型,理由见文件头)
var _bird = null                    # 被测鸟(真物理)
var _landing_vy := 0.0              # 落地那一刻缓存里的 `_pre_move_vy`(前提读数)
var _first_sleep_x := 1.0           # 第一个睡眠帧的 scale.x(应 > 1:吸收清除了历史下坠速度)
var _last_sleep_x := 1.0            # 睡眠窗口末尾的 scale.x(应 == 1.0)
var _sleep_frames := 0


func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	var host := Node2D.new()
	host.name = "World"
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	print("[squash_enemy] 合成世界 %dx%d 格;底行实心 y=%d;相④ 落点列 x=%d" % [
			COLS, ROWS, int(FLOOR_TOP_Y), DROP_X])
	_probe_events()
	_begin_finding_b()


func _build_grid() -> Array[Array]:
	var ts_wall := 31            # 纹理1 全砖(墙)
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(ts_wall if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


# 造一只实际游戏场景的鸟,挂进树(`_ready` 走完整条链:真 animator、真 ContactArea、真姿态碰撞箱),
# 然后关掉它自己的物理 —— 阶段 1②③ 手动 tick,不让 AI 掺进来。
func _mk_enemy(scene: PackedScene):
	var b = scene.instantiate()
	add_child(b)
	b.set_physics_process(false)
	return b


# 子类脚本里的 `enum State`(名字 -> 号)。取不到就返回空字典,由调用方报红。
func _state_of(b) -> Dictionary:
	var scr := b.get_script() as GDScript
	if scr == null:
		return {}
	return scr.get_script_constant_map().get("State", {})


func _physics_process(_delta: float) -> void:
	_total += 1
	if _stage == S_FINDING_B:
		_tick_finding_b()


func _begin(stage: int) -> void:
	_stage = stage
	_f = 0


# ── 阶段 1②③:状态映射 / 睡眠不挂钩 / 受击挤压(全部手动 tick,确定性)──
func _probe_events() -> void:
	# 阶段 1 五处状态映射 -> 拉伸(窄高,scale.x < 1)
	for c in STATE_CASES:
		var b = _mk_enemy(c[1])
		var label: String = c[0]
		var sname: String = c[2]
		var states := _state_of(b)
		if not states.has(sname):
			_record(false, "相① 前提:%s 的 enum State 里有 `%s`" % [label, sname],
				"取到 %s —— 状态名改了就必须改这里,不能静默跳过" % str(states.keys()))
			b.queue_free()
			continue
		b._set_state(int(states[sname]))
		b.squash.tick(DT, 0.0, true, false)
		var sx := _scale_x(b)
		_record(sx < 1.0, "相① %s 进 %s → 拉伸(窄高)" % [label, sname],
			"scale.x %.4f(需 < 1.0;== 1.0 说明这条映射根本没挂上钩子)" % sx)
		b.queue_free()

	# 阶段 1 附:SLEEP 不挂钩 —— 三只鸟都不该在状态 0 上产生事件。
	# (挂了的话睡眠中的鸟会一直顶着形变,而那正是 `b89420c` 修掉的那类问题。)
	for c in [["FlyBird", FLY], ["BlackBird", BLACK], ["JumpBird", JUMP]]:
		var b = _mk_enemy(c[1])
		var states := _state_of(b)
		if not states.has("SLEEP"):
			_record(false, "相① 前提:%s 有 SLEEP 状态" % c[0], str(states.keys()))
			b.queue_free()
			continue
		b._set_state(int(states["SLEEP"]))
		b.squash.tick(DT, 0.0, true, false)
		var sx := _scale_x(b)
		_record(absf(sx - 1.0) <= EPS, "相① %s 进 SLEEP 不产生任何事件" % c[0],
			"scale.x %.6f(需 == 1.0)" % sx)
		b.queue_free()

	# 阶段 3 受击 -> 挤压(宽矮,scale.x > 1);且钩子在 `_apply_hit` 而不是 `hurt` ——
	# 尸体走 `_apply_knock_only`,不该再吃一次形变(唯一会重复触发的挂法)。
	for c in [["FlyBird", FLY], ["BlackBird", BLACK], ["JumpBird", JUMP]]:
		var b = _mk_enemy(c[1])
		b._apply_hit(1, Vector2.RIGHT)
		b.squash.tick(DT, 0.0, true, false)
		var sx := _scale_x(b)
		_record(sx > 1.0, "相③ %s 受击(_apply_hit)→ 挤压(宽矮)" % c[0],
			"scale.x %.4f(需 > 1.0)" % sx)
		b.queue_free()

		var d = _mk_enemy(c[1])
		d.is_dead = true
		d.hurt(1, Vector2.RIGHT)          # 尸体:走 _apply_knock_only,不碰 squash
		d.squash.tick(DT, 0.0, true, false)
		var dsx := _scale_x(d)
		_record(absf(dsx - 1.0) <= EPS, "相③ %s 尸体 hurt 不产生事件(钩子在 _apply_hit)" % c[0],
			"scale.x %.6f(需 == 1.0)" % dsx)
		d.queue_free()


func _scale_x(b) -> float:
	var spr := b.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if spr == null:
		_record(false, "前提:鸟的 animator 节点名仍是 AnimatedSprite2D", "查不到节点")
		return 1.0
	return spr.scale.x


# ── 阶段 4 Finding-B:真物理的"睡 -> 醒"整条链 ──
# 复现路径就是代码注释里那条自然路径(不需要人工灌值):
#   鸟带着一个真落速落地(落地帧把 900+ 写进 `_pre_move_vy`) -> 玩家不可达(dist = INF)
#    ->  下一帧起 `_is_far_sleeping()` 为真、走睡眠分支。
# 三条断言把"缓存清零"那行前后夹住:
#   ① 第一个睡眠帧必须被压一次(scale.x > 1)—— 证明 tick 实际运行了、且吃的是那个陈旧落速
#      (-  删掉 `squash.tick(...)` 就地变红:scale 恒 1.0,连"没跑"都看得见)
#   ② 睡眠窗口末尾必须回到中性 —— -  删掉睡眠分支里的 `_pre_move_vy = 0.0` 即变红:
#      陈旧的 900+ 每帧重触发落地项,而指数恢复每帧只回 14%  ->  定点 ≈ -6.19k  ->  永久 (1.10, 0.90)
#   ③ 醒来首帧(挂上 TAKE_OFF)必须落在拉伸侧(scale.x < 1)—— 这是 Finding-B 的正身:
#      缓存没清的话那一帧的 -1.0 会把 TAKE_OFF 的 +0.80 拦截屏蔽,拉伸被抵消甚至反向成压扁
func _begin_finding_b() -> void:
	# - 用 BlackBird 而不是 FlyBird —— 这不是随手挑的:
	#   `enemy_fly_bird.tscn` 的根是 `motion_mode = 1`(floating),而 floating 模式下
	#   `CharacterBody2D.is_on_floor()` 恒为 false(引擎语义:浮空体没有地板概念)。
	#   于是 `_is_far_sleeping()` 对 FlyBird 永远为 false  ->  睡眠提前返回那一支对 FlyBird
	#   根本不可达(实测:落在地面上、位置冻住、velocity.y 一路涨到 9 万多,
	#   `is_on_floor()` 仍是 false)。这是本特性之前就存在的既有事实(与 squash 无关,
	#   也没人要求改),但 Finding-B 必须在真的会睡的鸟身上复现  ->  换 BlackBird
	#   (默认 grounded、同样有 SLEEP 与 TAKE_OFF)。
	_bird = _mk_enemy(BLACK)
	_bird.global_position = Vector2(DROP_X, DROP_SPAWN_Y)
	_bird.velocity = Vector2(0.0, DROP_VY)
	var states := _state_of(_bird)
	if not states.has("SLEEP") or not states.has("TAKE_OFF"):
		print("SQUASH HOST ENEMY PROBE: FAIL | BlackBird 的 enum State 里缺 SLEEP/TAKE_OFF")
		get_tree().quit(1)
		return
	_bird._set_state(int(states["SLEEP"]))
	_landing_vy = 0.0
	_first_sleep_x = 1.0
	_last_sleep_x = 1.0
	_sleep_frames = 0
	_begin(S_FINDING_B)


func _tick_finding_b() -> void:
	if _bird == null or not is_instance_valid(_bird):
		return
	# 固定 DT 逐帧驱动(与另两个 squash 探针相同处理逻辑:delta 必须确定性)
	_bird._physics_process(DT)
	_f += 1
	if _landing_vy == 0.0:
		if not _bird.is_on_floor():
			return                                   # 还在空中
		# 刚落地:此刻缓存里就是这次落地的落速 —— 下一个睡眠帧要消费的正是它
		_landing_vy = _bird._pre_move_vy
		return
	_sleep_frames += 1
	if _sleep_frames == 1:
		_first_sleep_x = _scale_x(_bird)
		_record(_bird._is_far_sleeping(), "相④ 前提:落地后**真的**进了远处睡眠分支",
			"state=%d on_floor=%s vx=%.2f vy=%.2f dist=%.1f" % [
				_bird.state, str(_bird.is_on_floor()), _bird.velocity.x,
				_bird.velocity.y, _bird.toroidal_dist_to_player()])
		_record(_landing_vy >= MIN_LANDING_VY, "相④ 前提:落地那帧的 `_pre_move_vy` 确实是落速",
			"_pre_move_vy = %.1f(需 >= %.1f)—— 低于它这相就成了空转(什么都没灌进去)" % [
				_landing_vy, MIN_LANDING_VY])
		return
	if _sleep_frames < SLEEP_FRAMES:
		return
	_last_sleep_x = _scale_x(_bird)
	_record(_first_sleep_x > 1.0, "相④ 首个睡眠帧吃掉陈旧落速 → 挤压(证明 tick 真在跑)",
		"scale.x %.6f(需 > 1.0;== 1.0 ⇒ `squash.tick(...)` 那一行没了,或被挪到早退之后)" % _first_sleep_x)
	_record(absf(_last_sleep_x - 1.0) <= EPS, "相④ 睡眠 %d 帧后回到中性(缓存确实被清零)" % SLEEP_FRAMES,
		"scale.x %.8f(需 |dev| <= %s;停在 1.10 就是睡眠分支里那句 `_pre_move_vy = 0.0` 被删了)" % [
			_last_sleep_x, str(EPS)])
	# 醒来首帧:挂 TAKE_OFF,再跑一帧真物理
	var states := _state_of(_bird)
	_bird._set_state(int(states["TAKE_OFF"]))
	_bird._physics_process(DT)
	var wake_x := _scale_x(_bird)
	_record(wake_x < 1.0, "相④ 醒来首帧必须是**拉伸**(起飞那一下没被抵消)",
		"scale.x %.6f(需 < 1.0;> 1.0 = 陈旧落速在醒来首帧重触发,把 TAKE_OFF 的 +0.80 吃掉了)" % wake_x)
	_begin(S_DONE)
	_finish()


func _record(ok: bool, label: String, detail: String) -> void:
	var line := "%s %s —— %s" % ["OK  " if ok else "FAIL", label, detail]
	_lines.append(line)
	print("[squash_enemy] %s" % line)
	if not ok:
		_fails.append("%s(%s)" % [label, detail])


func _finish() -> void:
	if _fails.is_empty():
		print("SQUASH HOST ENEMY PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("SQUASH HOST ENEMY PROBE: FAIL | %d 条: %s" % [_fails.size(), "; ".join(_fails)])
		get_tree().quit(1)
