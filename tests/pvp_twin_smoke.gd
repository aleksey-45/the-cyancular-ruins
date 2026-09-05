extends Node
# C2 孪生冒烟(scene 模式 headless,autoload 在):证明「整态捕获/恢复」完整——
# B 每 K tick 被强行搞乱后再 restore_state(A 快照)+ 同输入继续,必须与从不被打断的 A 逐 tick 收敛。
# 漏一个 capture_state 字段 → B 重放与 A 发散 → 冒烟失败(capture/restore 见 player.gd)。
# 跑法:用户自跑(见 Tests/pvp_twin_smoke.sh / CLAUDE.md)。
# 注意:本冒烟驱动「纯移动/攀爬/游泳」输入(不开火),场景模式= autoload 已实例化(GameParameters 等)。
#
# 根因背景(docs/pvp-c2-retrospective.md):v1 回拉的根因之一是两端模拟不孪生 + 校正拉拢。
# 新 C2 把「整态 PlayerState」作为权威格式:本冒烟先钉死 capture_state 无漏,才谈网络协议。

const BIT_UP := NetworkInputSource.BIT_UP
const BIT_DOWN := NetworkInputSource.BIT_DOWN
const BIT_CHARGE := NetworkInputSource.BIT_CHARGE

# ── 合成网格(确定性,已知布局):平地底行 + 一条梯 + 一片水池 ──
const COLS := 60
const ROWS := 14
const LADDER_X := 5            # 梯列 x(rows 5..12)
const WATER_X0 := 16           # 水池列区间 x 16..24(rows 2..12)
const WATER_X1 := 24

var A = null   # 参照(Player 实例,动态类型:capture/restore 等成员在 Player.gd,不在 Node2D)
var B = null   # 被测(Player):每 K tick sabotage + restore(A.capture_state())
var _tick := 0
var _plan: Array[Dictionary] = []   # 每 tick {h(held) p(pressed) r(released) ax}
var _max_pos_dev := 0.0
var _violation := ""

const WARMUP := 40        # 无输入落地
const ACTIVE := 600       # 动作(横扫穿过梯/水池 + 周期跳/冲/蹲)
const TOTAL := WARMUP + ACTIVE
const RESTORE_EVERY := 12   # B 每 12 tick 被打断重放一次

func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	# 碰撞世界(永久墙+可破坏+攀爬条;水池/梯为 passage/liquid 无碰撞)
	var host := Node2D.new()
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	_build_plan()
	# 两个玩家,同出生点、mask 不含对方层(不互撞),各注入独立 NetworkInputSource
	var ts := GameParameters.TILE_SIZE
	var spawn := Vector2(2 * ts + ts * 0.5, 3 * ts + ts * 0.5)
	A = _make_player(host, "TwinA", spawn)
	B = _make_player(host, "TwinB", spawn)
	print("[pvp_twin] 世界 %dx%d 格;玩家出生 %s;计划 %d tick(restore every %d)" % [
		COLS, ROWS, spawn, TOTAL, RESTORE_EVERY])

func _make_player(host: Node2D, nm: String, pos: Vector2):
	var p = preload("res://scenes/Player/Player.tscn").instantiate()
	p.name = nm
	var src := NetworkInputSource.new()
	p.set_input_source(src)
	host.add_child(p)
	p.global_position = pos
	return p

func _build_grid() -> Array[Array]:
	var ts_wall := 31   # texture1 全砖(墙)
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

func _build_plan() -> void:
	for _t in range(WARMUP):
		_plan.append({})
	var prev := {"up": false, "down": false, "charge": false}
	for i in range(ACTIVE):
		var ax := 0.0
		var up := false
		var down := false
		var charge := false
		# 长距离左右横扫:保证经过梯列(x5)与水池(x16..24),触发攀爬/游泳路径
		var sw := i % 240
		if sw < 100:
			ax = 1.0
		elif sw < 112:
			ax = 0.0
		elif sw < 210:
			ax = -1.0
		else:
			ax = 0.0
		# 周期性动作(跳/跳剪/蹲/冲刺),值与横扫 tick 互质错开,制造密集状态变化
		var m := i % 41
		if m == 0 or (m >= 1 and m < 4):
			up = true
		if m >= 4 and m < 6:
			up = false
		if i % 37 == 3:
			charge = true
		var d := i % 53
		if d >= 0 and d < 3:
			down = true
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
		_plan.append({"h": h, "p": p, "r": r, "ax": ax})

func _apply_input(src: NetworkInputSource, i: int) -> void:
	src.clear_edges()
	if i >= _plan.size():
		return
	var pk: Dictionary = _plan[i]
	var ax: float = pk.get("ax", 0.0)
	# aim 常量(1,0):孪生不开火,aim 只经武器 _auto_aim 影响朝向;恒定=两端确定一致。
	src.apply_packet({
		"seq": i,
		"ax": ax,
		"held": int(pk.get("h", 0)),
		"pressed": int(pk.get("p", 0)),
		"released": int(pk.get("r", 0)),
		"weapon": 0,
		"aim": Vector2(1.0, 0.0),
	})

func _physics_process(_delta: float) -> void:
	if A == null or B == null:
		return
	var i := _tick
	if i >= TOTAL:
		_finish()
		return
	var srcA := A.input_source as NetworkInputSource
	var srcB := B.input_source as NetworkInputSource
	if srcA == null or srcB == null:
		_fail()   # 注入失败
		return
	_apply_input(srcA, i)
	_apply_input(srcB, i)
	# 每 RESTORE_EVERY tick:B 被搞乱 → 用 A 此刻(上一 tick 结果)的整态恢复 → 与 A 重跑对齐
	if i > 0 and i % RESTORE_EVERY == 0:
		var snap: Dictionary = A.capture_state()
		B.global_position = Vector2(-9999, -9999)   # 主动造成严重分歧
		B.velocity = Vector2.ZERO
		B.restore_state(snap)
		_compare(A, B, snap, true)   # 恢复后立即字段级比对(不含 pos 的 settle 微差)
	_tick += 1
	if i % RESTORE_EVERY != 0:
		_compare(A, B, {}, false)

# 字段级比对。restored=true 时本轮 B 刚 restore(A 快照),pos 允许 settle 微差;逐 tick 仍全比。
func _compare(a, b, _snap: Dictionary, restored: bool) -> void:
	if not _violation.is_empty():
		return
	var dev: float = (a.global_position - b.global_position).length()
	if dev > _max_pos_dev:
		_max_pos_dev = dev
	var tol := 3.0 if restored else 1.0
	if dev > tol:
		_violation = "pos dev %.2f px(tol %.1f, restored=%s) tick=%d  A=%s B=%s" % [
			dev, tol, restored, _tick, a.global_position, b.global_position]
		_fail()
		return
	if a.velocity.distance_to(b.velocity) > 0.5:
		_violation = "vel dev %.3f tick=%d" % [a.velocity.distance_to(b.velocity), _tick]
		_fail(); return
	# 决定下一 tick 的标量/位:漏 capture 字段会在这里现形
	var checks := {
		"coyote": absf(a.coyote_timer - b.coyote_timer) <= 0.001,
		"jbuf": absf(a.jump_buffer_timer - b.jump_buffer_timer) <= 0.001,
		"jcut": a.jump_cut_applied == b.jump_cut_applied,
		"squat": a.is_squat == b.is_squat,
		"charge": a.is_charge == b.is_charge,
		"state": a.state == b.state,
		"facing": a.facing_direction == b.facing_direction,
		"latch": a.climb._latched == b.climb._latched,
		"swim": a.swim.in_water == b.swim.in_water,
		"downed": a.combat.downed == b.combat.downed,
		"hp": a.combat.hp == b.combat.hp,
	}
	for k in checks:
		if not checks[k]:
			_violation = "字段 %s 发散 tick=%d" % [k, _tick]
			_fail()
			return

func _fail() -> void:
	print("SMOKE_TWIN FAIL: %s" % _violation)
	print("  max pos dev so far: %.3f" % _max_pos_dev)
	get_tree().quit(1)

func _finish() -> void:
	if not _violation.is_empty():
		_fail()
		return
	print("SMOKE_TWIN OK: %d ticks, max pos dev %.4f px, 0 字段发散" % [_tick, _max_pos_dev])
	get_tree().quit(0)
