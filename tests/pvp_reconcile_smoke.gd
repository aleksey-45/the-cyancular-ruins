extends Node
# C2 rollback 控制器 in-process 冒烟(scene 模式 headless):在无真实网络的确定环境下验证
# core/prediction_rollback.gd 的「权威锚定 + 重放」——
#   A = 权威模拟(服务器,1 输入/ tick 消费);P = 被预测玩家 + PredictionRollback。
#   ack/整态按人工 D tick 延迟投递到 P;并在 tick E 对 A 注入一个外部事件(传送=击退/换边等效),
#   断言:常态(无事件)下 P==A 无橡皮筋;事件后 ack 到期 → P 一次性 rollback 重对齐 A,随后再收敛。
# 跑法:用户自跑(见 Tests/pvp_reconcile_smoke.sh);通过 = SMOKE_RECONCILE OK。

const BIT_UP := NetworkInputSource.BIT_UP
const BIT_DOWN := NetworkInputSource.BIT_DOWN
const BIT_CHARGE := NetworkInputSource.BIT_CHARGE

const COLS := 60
const ROWS := 14
const LADDER_X := 5
const WATER_X0 := 16
const WATER_X1 := 24
const TILE := 64

const DELAY := 8          # 权威投递延迟(tick)——模拟 ~RTT/2×60 上界,rollback 窗口
const EVENT_TICK := 200   # 服务器外部事件注入时刻
const WARMUP := 30
const RUN := 520          # EVENT_TICK 之后留足 DELAY+ margin
const TOTAL := WARMUP + RUN

var A = null   # 权威(服务器模拟,手动步进,不接控制器)
var P = null   # 被预测(控制器驱动;advance 内部换 scratch 喂入)
var ctrl := PredictionRollback.new()
var srcA: NetworkInputSource = NetworkInputSource.new()
var _plan: Array[Dictionary] = []
var _a_hist: Array[Dictionary] = []   # tick -> A 该 tick 步进后整态(投递用)
var _tick := 0
var _max_dev := 0.0
var _max_pre_event_dev := 0.0
var _post_converged := false
var _violation := ""

func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	var host := Node2D.new()
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	_build_plan()
	var spawn := Vector2(2 * TILE + TILE * 0.5, 3 * TILE + TILE * 0.5)
	A = _make_player(host, "AuthA", spawn)
	P = _make_player(host, "PredP", spawn)
	A.set_input_source(srcA)
	# 手动步进:关掉引擎自动 _physics_process,由本冒烟逐帧驱动
	A.set_physics_process(false)
	P.set_physics_process(false)
	ctrl.bind(P)
	print("[reconcile] D=%d E=%d 计划 %d tick" % [DELAY, EVENT_TICK, TOTAL])

func _make_player(host: Node2D, nm: String, pos: Vector2):
	var p = preload("res://scenes/player/Player.tscn").instantiate()
	p.name = nm
	host.add_child(p)
	p.global_position = pos
	return p

func _build_grid() -> Array[Array]:
	var wall := 31
	var ladder := 11 * 16 + 15
	var water := 21 * 16 + 15
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			var v := 0
			if y == ROWS - 1:
				v = wall
			elif x == LADDER_X and y >= 5:
				v = ladder
			elif x >= WATER_X0 and x <= WATER_X1 and y >= 2:
				v = water
			row.append(v)
		grid.append(row)
	return grid

func _build_plan() -> void:
	for _t in range(WARMUP):
		_plan.append({})
	var prev := {"up": false, "down": false, "charge": false}
	for i in range(RUN):
		var ax := 0.0
		var up := false
		var down := false
		var charge := false
		var sw := i % 200
		if sw < 90: ax = 1.0
		elif sw < 100: ax = 0.0
		elif sw < 180: ax = -1.0
		else: ax = 0.0
		var m := i % 37
		if m == 0 or (m >= 1 and m < 4): up = true
		if i % 31 == 3: charge = true
		if i % 47 < 3: down = true
		var h := 0
		var p := 0
		var r := 0
		if up: h |= BIT_UP
		if down: h |= BIT_DOWN
		if charge: h |= BIT_CHARGE
		if up and not prev.up: p |= BIT_UP
		if not up and prev.up: r |= BIT_UP
		if down and not prev.down: p |= BIT_DOWN
		if not down and prev.down: r |= BIT_DOWN
		if charge and not prev.charge: p |= BIT_CHARGE
		prev = {"up": up, "down": down, "charge": charge}
		_plan.append({"seq": WARMUP + i, "h": h, "p": p, "r": r, "ax": ax})

func _record(i: int) -> Dictionary:
	if i >= _plan.size():
		return {"seq": i, "ax": 0.0, "h": 0, "p": 0, "r": 0}
	var pk: Dictionary = _plan[i]
	return {"seq": int(pk.get("seq", i)), "ax": pk.get("ax", 0.0),
		"held": int(pk.get("h", 0)), "pressed": int(pk.get("p", 0)),
		"released": int(pk.get("r", 0)), "weapon": 0, "aim": Vector2(1.0, 0.0)}

func _physics_process(_delta: float) -> void:
	if A == null or P == null:
		return
	var t := _tick
	if t >= TOTAL:
		_finish()
		return
	var rec: Dictionary = _record(t)
	# 1) 权威服务器步进(消费本输入)
	srcA.clear_edges(); srcA.apply_packet(rec)
	A._physics_process(1.0 / 60.0)
	if t == EVENT_TICK:
		# 服务器外部事件:传送 A(等效击退/换边),P 不知情,须由 ack rollback 采纳
		A.global_position.x -= 340.0
		A.velocity = Vector2.ZERO
	_a_hist.append(A.capture_state())
	# 2) 到期投递 ack → 控制器(reconcile 在 advance 内先处理)
	var ack_t := t - DELAY
	if ack_t >= 0 and ack_t < _a_hist.size():
		ctrl.on_authoritative(ack_t, _a_hist[ack_t])
	# 3) 被预测步进(控制器 advance = reconcile + 换 scratch 喂输入 + 步 + 记 capture)
	ctrl.advance(rec)
	# 4) 断言
	_assert_state(t)
	_tick += 1

func _assert_state(t: int) -> void:
	if not _violation.is_empty():
		return
	var dev: float = (A.global_position - P.global_position).length()
	if dev > _max_dev:
		_max_dev = dev
	if t < EVENT_TICK + DELAY:
		_max_pre_event_dev = maxf(_max_pre_event_dev, dev)
	if t > EVENT_TICK + DELAY + 2:
		if dev <= 0.5:
			_post_converged = true
	# 事件后必须已 rollback 重对齐;事件前(常态)无大分歧
	if t < EVENT_TICK and dev > 1.0:
		_violation = "常态(事件前)出现分歧 %.2f px tick=%d —— 确认路径应零橡皮筋" % [dev, t]
		_fail(); return
	if t > EVENT_TICK + DELAY and dev > 0.6:
		_violation = "事件后未收敛 dev %.2f px tick=%d(rollbacks=%d)" % [dev, t, ctrl.rollback_count()]
		_fail(); return

func _fail() -> void:
	print("SMOKE_RECONCILE FAIL: %s" % _violation)
	get_tree().quit(1)

func _finish() -> void:
	if not _violation.is_empty():
		_fail(); return
	if ctrl.rollback_count() == 0:
		print("SMOKE_RECONCILE FAIL: 外部事件未触发 rollback")
		get_tree().quit(1); return
	if not _post_converged:
		print("SMOKE_RECONCILE FAIL: 事件后未收敛")
		get_tree().quit(1); return
	print("SMOKE_RECONCILE OK: 640tick 内 rollback×%d,maxdev=%.2f px(事件前 %.2f),事件后已收敛" % [
		ctrl.rollback_count(), _max_dev, _max_pre_event_dev])
	get_tree().quit(0)
