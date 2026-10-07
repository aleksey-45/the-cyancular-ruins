extends Node

# 客户端状态一致性孪生比对冒烟测试：
# 通过并行动作模拟，验证 Player 全量状态捕获（capture_state）与还原（restore_state）的无损对齐能力。
# 运行方式：
#   "$GODOT" --headless --path . res://tests/smoke/pvp_twin_smoke.tscn

const BIT_UP := PacketInputSource.BIT_UP
const BIT_DOWN := PacketInputSource.BIT_DOWN
const BIT_CHARGE := PacketInputSource.BIT_CHARGE

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
	# 两个玩家,同出生点、mask 不含对方层(不互撞),各注入独立 PacketInputSource
	var ts := GameParameters.TILE_SIZE
	var spawn := Vector2(2 * ts + ts * 0.5, 3 * ts + ts * 0.5)
	A = _make_player(host, "TwinA", spawn)
	B = _make_player(host, "TwinB", spawn)
	# - 给两人一个非空且残弹非满的背包:否则 capture/restore 里的 `inv` 一节
	#   在两个空背包之间比,恒等,等于没测。下方 _compare 的 `inv` 指纹才真正有测试有效性
	#   (sabotage 会把 B 的背包清空,restore 必须把它从快照里重建回来)。
	for p in [A, B]:
		p.weapons.set_initial_inventory([1, 2, 4])
	await get_tree().physics_frame
	# - 必须等武器加入场景树再写残弹:`_equip_index` 用 `call_deferred("add_child")` 加入场景树,
	#   而 `_ready` 会把 `mag_ammo` 重置为满  ->  加入场景树前写会被静默冲掉(实测 `in=false mag=4`
	# -> 下一帧 `in=true mag=12`),"残弹非满"这个前提就没了。写完同步进背包条目 ——
	#   `_inv_key` 比的是条目,不是实例(条目默认 `MAG_FULL`,不同步则指纹恒不动)。
	for p in [A, B]:
		var w = p.weapons.current_weapon()
		# - 等待必须有上界:没有它,fixture 漂移(武器始终没装上)会让本冒烟耗尽 `--quit-after`
		#   且一行判定结果都不打印 —— 与真失败在输出上不可分(2026-09-25 评审指出,与
		#   `ammo_rollback_probe` 那条超时防御性校验同一类)。
		var waited := 0
		while w != null and not w.is_inside_tree() and waited < 120:
			await get_tree().physics_frame
			waited += 1
		if w != null and not w.is_inside_tree():
			# - 判定依据为"仍然不在树里",不是 `waited >= 120`:循环可能在那一帧刚好等到它加入场景树,
			#   而 `waited` 照样等于 120  ->  边界帧测试误报(2026-09-25 复核指出)。
			_violation = "等待武器入树超时(120 帧,current_weapon=%s)" % str(w)
			_fail()
			return
		# - `w == null` 必须报错而不是跳过:下面那句"残弹非满"是本冒烟 `inv` 指纹的唯一
		#   测试有效性来源 —— 静默跳过等于冒烟退化成永远绿(与上面那条防御性校验同一类)。
		if w == null:
			_violation = "玩家 %s 没有武器(set_initial_inventory 没装上?)—— '残弹非满'前提不成立" % p.name
			_fail()
			return
		w.mag_ammo = 4     # 残弹非满:被"切枪回满弹"或"漏字段"破坏时指纹会变
		p.weapons.reset_mag_state()
	print("[pvp_twin] 世界 %dx%d 格;玩家出生 %s;计划 %d tick(restore every %d)" % [
		COLS, ROWS, spawn, TOTAL, RESTORE_EVERY])

func _make_player(host: Node2D, nm: String, pos: Vector2):
	var p = preload("res://scenes/player/player.tscn").instantiate()
	p.name = nm
	var src := PacketInputSource.new()
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
	var prev := {"up": false, "down": false, "charge": false, "attack": false}
	for i in range(ACTIVE):
		var ax := 0.0
		var up := false
		var down := false
		var charge := false
		# - 开火:半自动手枪每 7 tick 一发,只为与 RESTORE_EVERY(12) 交错,让"回滚恢复
		#   期间开火"这个面被覆盖到。
		# - `7 与 12 互质  ->  每 84 tick 必被走到一次` 这类推论不成立(别照它推):手枪
		#   `fire_cooldown` = 0.3s 量化到 7-tick 输入网格上,有效开火周期 = 21 tick
		#   (冷却中不重置冷却) ->  开火 tick ≡ 1 (mod 3),而 restore tick ≡ 0 (mod 3)
		#    ->  永不同帧。C1 需要专门构造序列,见 `tests/probe/ammo_rollback_probe.tscn`。
		var atk := (i % 7 == 3)
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
		if atk: h |= PacketInputSource.BIT_ATTACK
		if up and not prev.up: p |= BIT_UP
		if not up and prev.up: r |= BIT_UP
		if down and not prev.down: p |= BIT_DOWN
		if not down and prev.down: r |= BIT_DOWN
		if charge and not prev.charge: p |= BIT_CHARGE
		if atk and not prev.get("attack", false): p |= PacketInputSource.BIT_ATTACK
		if not atk and prev.get("attack", false): r |= PacketInputSource.BIT_ATTACK
		prev = {"up": up, "down": down, "charge": charge, "attack": atk}
		_plan.append({"h": h, "p": p, "r": r, "ax": ax})

func _apply_input(src: PacketInputSource, i: int) -> void:
	src.clear_edges()
	if i >= _plan.size():
		return
	var pk: Dictionary = _plan[i]
	var ax: float = pk.get("ax", 0.0)
	# aim 常量(1,0):开火方向两端一致(开火本身由 pressed 里的 BIT_ATTACK 驱动),
	# aim 另经武器 _auto_aim 影响朝向;恒定=两端确定一致。
	src.apply_packet({
		"seq": i,
		"ax": ax,
		"held": int(pk.get("h", 0)),
		"pressed": int(pk.get("p", 0)),
		"released": int(pk.get("r", 0)),
		"winst": 0,
		"aim": Vector2(1.0, 0.0),
	})

func _physics_process(_delta: float) -> void:
	if A == null or B == null:
		return
	var i := _tick
	if i >= TOTAL:
		_finish()
		return
	var srcA := A.input_source as PacketInputSource
	var srcB := B.input_source as PacketInputSource
	if srcA == null or srcB == null:
		_fail()   # 注入失败
		return
	_apply_input(srcA, i)
	_apply_input(srcB, i)
	# 每 RESTORE_EVERY tick:B 被搞乱 -> 用 A 此刻(上一 tick 结果)的完整状态恢复 -> 与 A 重跑对齐
	if i > 0 and i % RESTORE_EVERY == 0:
		var snap: Dictionary = A.capture_state()
		B.global_position = Vector2(-9999, -9999)   # 主动造成严重分歧
		B.velocity = Vector2.ZERO
		# - 连背包一起搞乱:若 `inv` 没进 capture/restore,restore 后 B 会是空手,
		#   下面 _compare 的 `inv` 指纹立刻发散。这条是本轮新增字段的唯一鉴别点。
		B.weapons.set_initial_inventory([])
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
	# 决定下一 tick 的标量/位:漏 capture 字段会在这里暴露异常
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
		# 武器:当前手持类型 + 背包指纹(类型序列 + 各把残弹)。
		# - 比的是背包条目里的 mag(每条一个 inst),不是 `_weapon.mag_ammo`:前者是
		#   "这个背包记着的"、进 `capture_state` 的 `inv`,两边同源可逐 tick 比;后者是
		#   "手上这一把的",而且本冒烟抓不到它 —— 「restore 之后同帧输出的那一发会不会
		#   被帧末的延迟写回抹掉」(C1)需要把那个序列构造出来才走得进去,靠"开火 tick 与
		#   restore tick 交错"碰不到(理由见 _build_plan 那段注释)。C1 由
		#   `tests/probe/ammo_rollback_probe.tscn` 专门覆盖,这里刻意不比手持实例的弹数。
		"wslot": a.weapons.current_type_id() == b.weapons.current_type_id(),
		"inv": _inv_key(a) == _inv_key(b),
	}
	for k in checks:
		if not checks[k]:
			_violation = "字段 %s 发散 tick=%d" % [k, _tick]
			_fail()
			return


# 背包指纹:类型序列 + 各条残弹。顺序错、少一条、残弹串位都会让它不等。
func _inv_key(p) -> String:
	var out := ""
	if p.weapons == null or p.weapons.inventory == null:
		return "<?>"
	for e in p.weapons.inventory.held:
		out += "%d:%d;" % [int(e["type"]), int(e["mag"])]
	return out

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
