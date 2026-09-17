extends Node
# C2 rollback 控制器 in-process 冒烟(scene 模式 headless):在无真实网络的确定环境下验证
# core/prediction_rollback.gd 的「权威锚定 + 重放」——
#   A = 权威模拟(服务器,1 输入/ tick 消费);P = 被预测玩家 + PredictionRollback。
#   ack/整态按人工 D tick 延迟投递到 P;并在 tick E 对 A 注入一个外部事件(传送=击退/换边等效),
#   断言:常态(无事件)下 P==A 无橡皮筋;事件后 ack 到期 → P 一次性 rollback 重对齐 A,随后再收敛。
# 跑法:用户自跑(见 Tests/pvp_reconcile_smoke.sh);通过 = SMOKE_RECONCILE OK。

const BIT_UP := PacketInputSource.BIT_UP
const BIT_DOWN := PacketInputSource.BIT_DOWN
const BIT_CHARGE := PacketInputSource.BIT_CHARGE

const COLS := 60
const ROWS := 14
const LADDER_X := 5
const WATER_X0 := 16
const WATER_X1 := 24
const TILE := 64

const DELAY := 8          # 权威投递延迟(tick)——模拟 ~RTT/2×60 上界,rollback 窗口
const EVENT_TICK := 200   # 服务器外部事件注入时刻
# 只改背包、**不动位置**的服务器外部事件:权威孪生给自己发一把枪。
# ★ 与 EVENT_TICK 那次瞬移刻意分开:那次改的是**被预测的量**(位置)→ 会回滚、会收敛;
#   这次改的 inv/wslot 是**非预测字段** → 既不回滚、也不落地 —— 这条正是要钉的洞。
const INV_EVENT_TICK := 320
const INV_TYPE := 3          # 重狙(任意一个与开局不同的类型即可)
const WARMUP := 30
const RUN := 520          # EVENT_TICK 之后留足 DELAY+ margin
const TOTAL := WARMUP + RUN

var A = null   # 权威(服务器模拟,手动步进,不接控制器)
var P = null   # 被预测(控制器驱动;advance 内部换 scratch 喂入)
var ctrl := PredictionRollback.new()
var srcA: PacketInputSource = PacketInputSource.new()
var _plan: Array[Dictionary] = []
var _a_hist: Array[Dictionary] = []   # tick -> A 该 tick 步进后整态(投递用)
var _tick := 0
var _max_dev := 0.0
var _max_pre_event_dev := 0.0
var _post_converged := false
var _violation := ""
var _inv_event_fired := false
var _rb_before_inv := 0
var _rb_after_inv := 0

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
	# 两边给同一个起始背包:否则"事件后两边不一致"这条判据分不清是事件造成的还是开局就有的。
	# (player.tscn 自身 _ready 给的是空背包 —— 见 CLAUDE.md「服务器玩家必须有枪」那一段)
	A.weapons.set_initial_inventory([1])
	P.weapons.set_initial_inventory([1])
	print("[reconcile] D=%d E=%d 计划 %d tick" % [DELAY, EVENT_TICK, TOTAL])

func _make_player(host: Node2D, nm: String, pos: Vector2):
	var p = preload("res://scenes/player/player.tscn").instantiate()
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
	if t == INV_EVENT_TICK:
		# 直接改权威孪生的背包(等价于服务器 `MatchGround._try_server_pickup` 的成效):
		# 位置/速度/血量一律不动,唯一的变化就是背包。
		A.weapons.set_initial_inventory([1, INV_TYPE])
		_inv_event_fired = true
		_rb_before_inv = ctrl.rollback_count()
	elif t > INV_EVENT_TICK + DELAY + 5:
		_rb_after_inv = ctrl.rollback_count()
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
	_assert_inventory_landed(t)
	if not _violation.is_empty():
		_fail()


# ★ 判据是"预测侧的背包与权威**逐条一致**",不是"预测侧背包非空" ——
#   非空可能只是它自己开局那把还在,证明不了"权威那把到了"。
# 为什么单开一条:位置/血量那些被预测的量走 ack 回滚那套,权威一变就会收敛;
# 而 inv/wslot 是**非预测字段**,`_close_enough` 的显式白名单里没有它们 ——
# 于是"预测被证实"那一支直接 return,背包**永远**不落地。这条就是把它钉成红灯。
func _assert_inventory_landed(t: int) -> void:
	if not _inv_event_fired:
		return
	# ★ 权威要走 DELAY 个 tick 才投递到预测侧(与 `_assert_state` 里那条
	#   `t > EVENT_TICK + DELAY` 同款)。不等就是拿"还没送到"当分歧 —— 必红,且红得没意义。
	if t <= INV_EVENT_TICK + DELAY:
		return
	var want: Array = A.weapons.inventory.snapshot()
	var got: Array = P.weapons.inventory.snapshot()
	if want.size() != got.size():
		_violation = "背包没落地:权威 %d 把,预测 %d 把(非预测字段在'预测被证实'那一支被跳过了)" % [
				want.size(), got.size()]
		return
	for i in want.size():
		# 只比 (type, inst):mag 是连续量、两边每帧都在各自演化,比它会把这条判据变成噪声源。
		if int(want[i]["type"]) != int(got[i]["type"]) \
				or int(want[i]["inst"]) != int(got[i]["inst"]):
			_violation = "背包内容不一致:权威 %s,预测 %s" % [str(want), str(got)]
			return
	if int(P.weapons.current_slot_int()) != int(A.weapons.current_slot_int()):
		_violation = "手持槽位没落地:权威 %d,预测 %d" % [
				A.weapons.current_slot_int(), P.weapons.current_slot_int()]
		return
	# ★ 反向断言:这条修复**不得**引入新的回滚 —— 它买的是"零回滚也能同步",
	#   不是"多回滚几次"。撤掉 Task 2 的改动时,红的是上面那条,不是这条。
	if _rb_after_inv > _rb_before_inv:
		_violation = "背包同步引入了额外回滚(%d → %d)—— 那是把它塞进 _close_enough 的写法" % [
				_rb_before_inv, _rb_after_inv]


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
