extends Node

# 加速(B12)探针 —— 用户两次反馈"感受不到加速",故把"加速究竟改了哪个物理量"钉成机器可验断言。
#
# 核心物理事实:`move_and_slide()` 用的是**引擎自己的 delta**,缩放传进去的 delta 只改变重力/
# 计时器/AI 节拍,不改变位移。所以"快/慢"必须落在**速度域**,否则手感就是用户实测描述的
# "只有坠落变快、跳跃变低、移速没变"。本探针测的就是这条。
#
# 覆盖:倍率表(玩家/普通敌/精英 × NONE/HASTE/REWIND) · 普通敌速度 ×HASTE_WORLD ·
#       主角水平移速 ×HASTE_PLAYER(关碰撞,纯速度域) · 跳跃高度不变(证重力没被 delta 带跑) ·
#       红蓝残影生成并自行淡出 · 主角与敌人高亮 modulate 及复位 · 松开回 NONE · 颗粒真被扣。
# 用法:godot --headless --path . res://tests/haste_probe.tscn
#
# ★ 输入走**可注入桩**(tests/haste_probe_input.gd),理由见该文件头(just_pressed 的帧号问题)。

const StubInput := preload("res://tests/haste_probe_input.gd")
const GhostScript := preload("res://scenes/effects/afterimage.gd")

var _fails: Array[String] = []
var _notes: Array[String] = []
var _ghost_total := 0
var _ghost_red := false
var _ghost_blue := false


func _ready() -> void:
	_run.call_deferred()   # root 建子节点期直接 add_child 会失败:必须脱离 _ready 栈


func _fail(msg: String) -> void:
	_fails.append(msg)


func _note(msg: String) -> void:
	_notes.append(msg)


func _close(a: float, b: float, msg: String, eps := 1e-5) -> void:
	if absf(a - b) > eps:
		_fail("%s(实为 %f 期望 %f)" % [msg, a, b])


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	tree.root.add_child(lvl)
	for i in 12:
		await tree.process_frame
	await _wait_phys(30)

	var player: CharacterBody2D = lvl.get_node_or_null("WorldViewport/Player") as CharacterBody2D
	var tf: TimeField = Level0.time_field
	if player == null or tf == null or Level0.grain_account == null:
		print("HASTE PROBE: FAIL(未就绪 player=%s tf=%s acc=%s)" % [str(player), str(tf), str(Level0.grain_account)])
		tree.quit(1)
		return

	var stub := StubInput.new()
	player.set_input_source(stub)

	# ── ① 倍率表:纯函数,先把"该是多少"钉住(后面全是"有没有真的生效")──
	var plain := Node2D.new()
	var elite := Node2D.new()
	elite.set_meta("elite", true)
	tf.mode = TimeField.Mode.NONE
	_close(TimeField.player_speed_mult(), 1.0, "NONE 玩家倍率应为 1")
	_close(TimeField.enemy_speed_mult(plain), 1.0, "NONE 普通敌倍率应为 1")
	_close(TimeField.enemy_speed_mult(elite), 1.0, "NONE 精英倍率应为 1")
	tf.mode = TimeField.Mode.HASTE
	_close(TimeField.player_speed_mult(), TimeParams.HASTE_PLAYER, "HASTE 玩家倍率应=%f" % TimeParams.HASTE_PLAYER)
	_close(TimeField.enemy_speed_mult(plain), TimeParams.HASTE_WORLD, "HASTE 普通敌倍率应=%f" % TimeParams.HASTE_WORLD)
	_close(TimeField.enemy_speed_mult(elite), TimeParams.HASTE_PLAYER, "HASTE 精英应与玩家同步")
	tf.mode = TimeField.Mode.REWIND
	_close(TimeField.player_speed_mult(), 0.0, "REWIND 玩家应冻结")
	_close(TimeField.enemy_speed_mult(plain), 0.0, "REWIND 普通敌应冻结")
	_close(TimeField.enemy_speed_mult(elite), 1.0, "REWIND 精英不受影响")
	tf.mode = TimeField.Mode.NONE
	plain.free()
	elite.free()

	# ── ② 普通敌速度(玩家还在出生点、周围怪已醒,趁这个分布测)──
	await _wait_phys(90)
	var enemy := await _pick_moving_enemy(tree)
	if enemy == null:
		_note("场上无可测普通怪(全睡/无怪):敌速对比跳过")
	else:
		var estart: Vector2 = enemy.global_position
		var en := await _mean_enemy_vx(enemy, 60)
		enemy.global_position = estart
		enemy.velocity = Vector2.ZERO
		Input.action_press("haste")
		await _wait_phys(8)
		var eh := await _mean_enemy_vx(enemy, 60)
		Input.action_release("haste")
		await _wait_phys(4)
		if en < 5.0 or eh < 0.5:
			_note("敌速采样不足(普通 %.2f / 加速 %.2f):对比跳过" % [en, eh])
		elif eh / en > 0.85:
			_fail("加速没放慢普通敌(普通 %.2f → 加速 %.2f,比 %.2f 期望≈%.2f)" % [en, eh, eh / en, TimeParams.HASTE_WORLD])

	# ── ③ 跳跃高度:普通 vs 加速(重力/跳跃**不该**被时间场碰)──
	# 先挪到一格"上方 4 格净空 + 下方实心"的地板格:两段测量在同一几何下,高度才可比。
	var spot := _find_jump_spot()
	if spot.x >= 0:
		player.global_position = Vector2(spot) * float(GameParameters.TILE_SIZE) + Vector2(32.0, 32.0)
		player.velocity = Vector2.ZERO
		await _wait_phys(30)
		var h_norm := await _jump_apex(player, stub, tree)
		Input.action_press("haste")
		await _wait_phys(8)
		var hasting_seen := tf.is_hasting()
		var h_haste := await _jump_apex(player, stub, tree)
		Input.action_release("haste")
		await _wait_phys(4)
		if not hasting_seen:
			_fail("按住加速键后时间场未进入 HASTE(mode=%d)" % tf.mode)
		if h_norm > 4.0 and h_haste > 4.0:
			var d := absf(h_haste - h_norm)
			var tol := maxf(8.0, h_norm * 0.10)
			if d > tol:
				_fail("加速改变了跳跃高度(普通 %.1fpx → 加速 %.1fpx,差 %.1fpx > %.1fpx):重力被 delta 缩放带跑了" % [h_norm, h_haste, d, tol])
		else:
			_note("跳跃高度取样不足(普通 %.1fpx / 加速 %.1fpx):高度对比跳过" % [h_norm, h_haste])
	else:
		_note("地图上找不到 4 格净空的地板格:跳跃高度对比跳过")

	# ── ④ 主角水平移速(关碰撞 = 纯速度域,no 墙挡)──
	var p_save: Vector2 = player.global_position
	var l_save := player.collision_layer
	var m_save := player.collision_mask
	player.collision_layer = 0
	player.collision_mask = 0
	stub.axis = 1.0
	await _wait_phys(45)
	var v_norm := await _mean_vx(player, 20)

	_ghost_total = 0
	_ghost_red = false
	_ghost_blue = false
	Input.action_press("haste")
	await _wait_phys(6)
	var v_haste := await _mean_vx(player, 20, true)
	var mult_seen := float(player.get("_speed_mult"))
	var hl_player := player.modulate
	var hl_enemy := Color.WHITE
	var enemy_seen := false
	for e in tree.get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e is Node2D and not e.has_meta("elite"):
			hl_enemy = (e as Node2D).modulate
			enemy_seen = true
			break
	Input.action_release("haste")
	await _wait_phys(3)
	for i in 3:
		await tree.process_frame
	var hl_after := player.modulate
	stub.axis = 0.0
	player.collision_layer = l_save
	player.collision_mask = m_save
	player.velocity = Vector2.ZERO

	var ratio := v_haste / maxf(v_norm, 0.001)
	if v_norm < 10.0:
		_fail("普通态水平速度采样过小(%.1f):碰撞已关,不该发生" % v_norm)
	elif ratio < 1.25 or ratio > 1.55:
		_fail("加速没改变水平移速(普通 %.1f → 加速 %.1f,比 %.2f 期望≈%.2f)" % [v_norm, v_haste, ratio, TimeParams.HASTE_PLAYER])
	_close(mult_seen, TimeParams.HASTE_PLAYER, "player._speed_mult 未按加速倍率设定")

	# ── ⑤ 高亮与残影(用户点名"很明显")──
	if hl_player.r < 1.2:
		_fail("加速时主角未高亮(modulate=%s)" % str(hl_player))
	if enemy_seen and hl_enemy.r < 1.2:
		_fail("加速时敌人未高亮(modulate=%s)" % str(hl_enemy))
	if hl_after.r > 1.05 or hl_after.g > 1.05:
		_fail("松开后主角高亮未复位(modulate=%s)" % str(hl_after))
	if _ghost_total <= 0:
		_fail("加速期间未生成残影(AfterImage)")
	elif not _ghost_red or not _ghost_blue:
		_fail("残影不是红/蓝双色(red=%s blue=%s)" % [str(_ghost_red), str(_ghost_blue)])
	await _wait_phys(45)
	var left := _count_ghosts(player)
	if left > 0:
		_fail("残影未自行淡出释放(仍剩 %d 个)" % left)

	# ── ⑥ 松开回 NONE + 颗粒真被扣 ──
	if tf.is_hasting() or tf.is_rewinding():
		_fail("松开后时间场未回 NONE(mode=%d)" % tf.mode)
	var bal := float(Level0.grain_account.balance)
	if bal >= float(TimeParams.GRAIN_INITIAL):
		_fail("加速没扣颗粒(余额 %.1f ≥ 初始 %d)" % [bal, TimeParams.GRAIN_INITIAL])

	var head := "HASTE PROBE: "
	if _fails.is_empty():
		print(head + "OK(倍率表/敌速×%.2f/玩家移速×%.2f/跳跃高度不变/红蓝残影/高亮与复位/松开回NONE/扣颗粒)" % [TimeParams.HASTE_WORLD, ratio])
		if not _notes.is_empty():
			print("  notes: " + " | ".join(_notes))
		tree.quit(0)
	else:
		print(head + "FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)


# ── 小工具 ─────────────────────────────────────────────────────────

func _wait_phys(n: int) -> void:
	var t := get_tree()
	for i in n:
		await t.physics_frame


# 平均值 = "稳态速度":起手 45 帧让指数缓动收敛后再采 20 帧。
func _mean_vx(player: CharacterBody2D, frames: int, watch_ghosts := false) -> float:
	var t := get_tree()
	var sum := 0.0
	for i in frames:
		await t.physics_frame
		sum += absf(player.velocity.x)
		if watch_ghosts:
			_scan_ghosts(player)
	return sum / float(frames)


# 只采"在走"的帧(|vx|>4),避开悬停/射击帧把均值拉向 0;无样本返回 0。
func _mean_enemy_vx(enemy: Node2D, frames: int) -> float:
	var t := get_tree()
	var sum := 0.0
	var n := 0
	for i in frames:
		await t.physics_frame
		if not is_instance_valid(enemy):
			break
		var vx := absf((enemy as CharacterBody2D).velocity.x)
		if vx > 4.0:
			sum += vx
			n += 1
	return sum / float(n) if n > 0 else 0.0


# 观察一小段时间,挑"平均水平速度最大"的普通怪(睡着的、悬停的都没样本)。
func _pick_moving_enemy(tree: SceneTree) -> Node2D:
	var acc: Dictionary = {}
	for e in tree.get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")) and not e.has_meta("elite"):
			acc[e] = 0.0
	if acc.is_empty():
		return null
	for i in 40:
		await tree.physics_frame
		for e in acc.keys():
			if is_instance_valid(e):
				acc[e] = float(acc[e]) + absf((e as CharacterBody2D).velocity.x)
	var best: Node2D = null
	var best_v := 0.0
	for e in acc.keys():
		var m := float(acc[e]) / 40.0
		if m > best_v:
			best_v = m
			best = e
	if not is_instance_valid(best):
		return null
	return best if best_v > 4.0 else null


func _jump_apex(player: CharacterBody2D, stub, tree: SceneTree) -> float:
	stub.jump = false
	var guard := 0
	while not player.is_on_floor() and guard < 300:
		await tree.physics_frame
		guard += 1
	if not player.is_on_floor():
		return -1.0
	await _wait_phys(6)
	var y0: float = player.global_position.y
	stub.jump = true
	var apex := y0
	var airborne := false
	for i in 75:
		await tree.physics_frame
		apex = minf(apex, player.global_position.y)
		if player.velocity.y < -60.0:
			airborne = true
	stub.jump = false
	await _wait_phys(20)
	return (y0 - apex) if airborne else -1.0


# 找一格"上方 4 格净空(跳跃要空间)+ 下方实心(有地板)"的格子:
# 走到地形无关的确定性几何 —— 否则两次跳跃在不同位置、高度不可比。
func _find_jump_spot() -> Vector2i:
	var grid: Array = MazeGenerator.current_grid
	if grid.is_empty():
		return Vector2i(-1, -1)
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	for r in range(rows - 2, 1, -1):
		for c in range(cols):
			var clear := true
			for k in 5:
				if int(grid[posmod(r - k, rows)][c]) != MazeGenerator.EMPTY:
					clear = false
					break
			if clear and TileDefs.is_blocked(int(grid[posmod(r + 1, rows)][c])):
				return Vector2i(c, r)
	return Vector2i(-1, -1)


func _scan_ghosts(player: Node) -> void:
	var host := player.get_parent()
	if host == null:
		return
	for c in host.get_children():
		if c.get_script() != GhostScript:
			continue
		_ghost_total += 1
		for g in c.get_children():
			if g is Sprite2D:
				var m := (g as Sprite2D).modulate
				if m.r > 0.7 and m.b < 0.6:
					_ghost_red = true
				if m.b > 0.7 and m.r < 0.6:
					_ghost_blue = true


func _count_ghosts(player: Node) -> int:
	var n := 0
	var host := player.get_parent()
	if host == null:
		return 0
	for c in host.get_children():
		if c.get_script() == GhostScript:
			n += 1
	return n
