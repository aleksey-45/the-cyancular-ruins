extends Node

# 加速(B13)探针 —— 用户两次反馈"感受不到加速/看不出高亮",故把两条**规则**钉成机器可验断言。
#
# 规则(用户 2026-09-26 明确):
#   ① "加速 = 主角的时间被加快"  ->  **除主角外一切实体变慢**:移动、攻击间隔、子弹都算。
#   ② 加速时主角与敌人要**高亮**;精英怪在**加速与回溯两种状态下都是极为亮眼的黄色**。
#
# 核心物理事实:`move_and_slide()` 用**引擎自己的 delta**,缩放传入的 delta 只改变重力/计时器,
# 不改变位移 —— 所以实体的"快/慢"必须作用在**速度域**(玩家速度目标 ×1.4、敌 velocity.x ×0.7);
# 而子弹走 `move_and_collide(velocity * delta)`,缩放 delta 就是真的变慢。
#
# 覆盖:倍率表(玩家/普通敌/精英 × NONE/HASTE/REWIND) · 普通敌速度 ×HASTE_WORLD ·
#       主角水平移速 ×HASTE_PLAYER(关碰撞,纯速度域) · 跳跃高度不变(重力没被带跑) ·
#       敌方子弹位移 ×HASTE_WORLD · 红蓝残影生成并自行淡出 ·
#       高亮:加速=主角+近敌、回溯=只有精英、精英两层亮黄 · 松开全部卸掉 · 回 NONE · 扣粒子。
# 用法:godot --headless --path . res://tests/probe/haste_probe.tscn
#
# - 输入走**可注入桩**(tests/probe/haste_probe_input.gd),理由见该文件头(just_pressed 的帧号问题)。

const StubInput := preload("res://tests/probe/haste_probe_input.gd")
const GhostScript := preload("res://scenes/effects/after_image.gd")
const BulletScene := preload("res://scenes/enemies/enemy_bullet.tscn")

var _fails: Array[String] = []
var _notes: Array[String] = []
var _ghost_total := 0
var _ghost_red := false
var _ghost_blue := false
var _bullet_ratio := -1.0
var _haste_frames := 0


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
	_close(TimeField.world_delta(1.0), 1.0, "NONE 世界物件 delta 应为原值")
	tf.mode = TimeField.Mode.HASTE
	_close(TimeField.player_speed_mult(), TimeParams.HASTE_PLAYER, "HASTE 玩家倍率应=%f" % TimeParams.HASTE_PLAYER)
	_close(TimeField.enemy_speed_mult(plain), TimeParams.HASTE_WORLD, "HASTE 普通敌倍率应=%f" % TimeParams.HASTE_WORLD)
	_close(TimeField.enemy_speed_mult(elite), TimeParams.HASTE_PLAYER, "HASTE 精英应与玩家同步")
	_close(TimeField.world_delta(1.0), TimeParams.HASTE_WORLD, "HASTE 世界物件 delta 应=%f" % TimeParams.HASTE_WORLD)
	tf.mode = TimeField.Mode.REWIND
	_close(TimeField.player_speed_mult(), 0.0, "REWIND 玩家应冻结")
	_close(TimeField.enemy_speed_mult(plain), 0.0, "REWIND 普通敌应冻结")
	_close(TimeField.enemy_speed_mult(elite), 1.0, "REWIND 精英不受影响")
	_close(TimeField.world_delta(1.0), 0.0, "REWIND 世界物件应冻结")
	tf.mode = TimeField.Mode.NONE
	plain.free()
	elite.free()

	# ── ② 普通敌速度(玩家还在出生点、周围怪已醒,趁这个分布测)──
	await _wait_phys(90)
	var enemy: Node2D = await _pick_moving_enemy(tree)
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
		elif eh / en > 0.65:
			_fail("加速没放慢普通敌(普通 %.2f → 加速 %.2f,比 %.2f 期望≈%.2f)" % [en, eh, eh / en, TimeParams.HASTE_WORLD])

	# ── ③ 敌方子弹:加速时必须变慢 ──
	# - EnemyBullet **整个覆写了** 基类的 _physics_process  ->  基类首行的 bullet_delta 在这条
	#   路径上永不执行,这就是"加速时子弹没变慢"的根因(修在 scenes/enemies/enemy_bullet.gd)。
	var spot := _find_open_spot(player.global_position)
	if spot.x >= 0:
		var at := Vector2(spot) * float(GameParameters.TILE_SIZE) + Vector2(32.0, 32.0)
		var d_norm := await _bullet_step(tree, player, at)
		Input.action_press("haste")
		await _wait_phys(8)
		var d_haste := await _bullet_step(tree, player, at)
		Input.action_release("haste")
		await _wait_phys(4)
		if d_norm < 1.0 or d_haste <= 0.0:
			_note("子弹位移采样不足(普通 %.2fpx / 加速 %.2fpx):对比跳过" % [d_norm, d_haste])
		else:
			var br := d_haste / d_norm
			_bullet_ratio = br
			if br < 0.35 or br > 0.65:
				_fail("加速时敌方子弹没按世界慢下来(普通 %.2fpx → 加速 %.2fpx,比 %.2f 期望≈%.2f)" % [d_norm, d_haste, br, TimeParams.HASTE_WORLD])
	else:
		_note("找不到净空格:敌方子弹对比跳过")

	# ── ④ 跳跃高度:普通 vs 加速(重力/跳跃**不该**被时间场碰)──
	# 挪到一格"上方 4 格净空 + 下方实心"的地板格:两段测量在同一几何下,高度才可比。
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

	# ── ⑤ 主角水平移速(关碰撞 = 纯速度域,无墙挡)+ 红蓝残影 ──
	var p_save: Vector2 = player.global_position
	var l_save := player.collision_layer
	var m_save := player.collision_mask
	player.collision_layer = 0
	player.collision_mask = 0
	stub.axis = 1.0
	await _wait_phys(45)
	await _settle_vx(player)
	var v_norm := await _mean_vx(player, 20)

	_ghost_total = 0
	_ghost_red = false
	_ghost_blue = false
	_haste_frames = 0
	Input.action_press("haste")
	# - 必须等速度**真正进入平台期**再采样:空中加速很温和(`accel_air`),固定等 45 帧可能还在
	#   爬坡 —— 实测同一份代码在不同地图/落点下分别量到 1.17 / 1.21 / 1.40(偶发误判"加速无效")。
	await _settle_vx(player)
	var v_haste := await _mean_vx(player, 20, true)
	var mult_seen := float(player.get("_speed_mult"))
	Input.action_release("haste")
	await _wait_phys(3)
	stub.axis = 0.0
	player.collision_layer = l_save
	player.collision_mask = m_save
	player.global_position = p_save
	player.velocity = Vector2.ZERO
	await _wait_phys(6)

	var ratio := v_haste / maxf(v_norm, 0.001)
	if v_norm < 10.0:
		_fail("普通态水平速度采样过小(%.1f):碰撞已关,不该发生" % v_norm)
	elif ratio < 1.75 or ratio > 2.25:
		_fail("加速没改变水平移速(普通 %.1f → 加速 %.1f,比 %.2f 期望≈%.2f; 采样 20 帧中处于加速态 %d 帧)" % [v_norm, v_haste, ratio, TimeParams.HASTE_PLAYER, _haste_frames])
	_close(mult_seen, TimeParams.HASTE_PLAYER, "player._speed_mult 未按加速倍率设定")
	if _ghost_total <= 0:
		_fail("加速期间未生成残影(AfterImage)")
	elif not _ghost_red or not _ghost_blue:
		_fail("残影不是红/蓝双色(red=%s blue=%s)" % [str(_ghost_red), str(_ghost_blue)])
	await _wait_phys(45)
	var left := _count_ghosts(player)
	if left > 0:
		_fail("残影未自行淡出释放(仍剩 %d 个)" % left)

	# ── ⑥ 高亮规则:加速=主角+近敌;回溯=只有精英;精英一律"两层亮黄" ──
	# - 用加色副本(TimeGlow)而不是 modulate:后者在非 HDR 2D 里被夹到 1.0,且敌人每帧的
	#   受击白闪会把 modulate 写回 WHITE/3.0 —— 用户实测"完全看不出高亮"就是这么来的。
	var probe_elite: Node2D = null
	for e in tree.get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")) and not e.has_meta("elite"):
			probe_elite = e
			break
	if probe_elite != null:
		probe_elite.set_meta("elite", true)
	else:
		_note("场上无普通怪可标精英:精英配色断言跳过")

	Input.action_press("haste")
	await _wait_phys(8)
	var g_pl := TimeGlow.on(player)
	var g_el := TimeGlow.on(probe_elite) if probe_elite != null else null
	var near_enemy_glow := false
	for e in tree.get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")) and not e.has_meta("elite"):
			if _near(player, e as Node2D) and TimeGlow.on(e) != null:
				near_enemy_glow = true
				break
	if g_pl == null:
		_fail("加速时主角没有高亮副本(TimeGlow 未挂上)")
	elif g_pl.color.b < 0.8 or g_pl.color.r > 0.6:
		_fail("加速时主角高亮配色不对(color=%s)" % str(g_pl.color))
	if probe_elite != null:
		if g_el == null:
			_fail("加速时精英没有高亮副本")
		elif not _is_elite_yellow(g_el):
			_fail("加速时精英不是两层亮黄(color=%s passes=%d)" % [str(g_el.color), g_el.passes()])
	if not near_enemy_glow:
		_note("半径 %.0fpx 内没有非精英敌:近敌高亮未验证" % Level0.GLOW_RADIUS)
	Input.action_release("haste")
	await _wait_phys(3)
	for i in 3:
		await tree.process_frame
	var leftover := _count_glows(player.get_parent())
	if leftover > 0:
		_fail("松开加速后仍有 %d 个高亮副本未卸" % leftover)

	# 回溯:只有精英亮黄,主角与普通敌都不该有高亮
	# - 精英**当场重挑**:上一段高亮检查期间那个标本可能已经被打死了(它是活物)。
	var re_elite: Node2D = null
	for e in tree.get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")):
			re_elite = e
			break
	if re_elite != null:
		re_elite.set_meta("elite", true)
	Input.action_press("rewind")
	# - 高亮挂在 `_process` 里(视效驱动),只等 `physics_frame` 会读到"还没跑 _process"的中间态
	#   —— 实测:紧接第二次读就有副本了(同一个协程切片内,中间只可能插进一帧 _process)。
	for i in 5:
		await tree.process_frame
	await _wait_phys(6)
	var re_mode := tf.mode
	# 规则断言走**集合**:回溯中每个存活精英都必须挂着"两层亮黄"副本。
	# - 单点断言(只看某个标本)会被"管理器这一帧刚 free、下一帧又 attach"的抖动骗过 ——
	#   所以再配一条**抖动检测**(3 帧内新建数),两者一起才代表规则真的成立。
	var elites: Array[Node2D] = []
	var missing := 0
	var bad := 0
	for e in tree.get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")) and e.has_meta("elite"):
			elites.append(e)
			var g := TimeGlow.on(e)
			if g == null:
				missing += 1
			elif not _is_elite_yellow(g):
				bad += 1
	var created_a := TimeGlow.total_created
	var re_pl := TimeGlow.on(player)
	var re_normal := false
	for e in tree.get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")) and not e.has_meta("elite") and TimeGlow.on(e) != null:
			re_normal = true
			break
	for i in 3:
		await tree.process_frame
	var created_b := TimeGlow.total_created
	Input.action_release("rewind")
	await _wait_phys(10)
	if re_mode != TimeField.Mode.REWIND:
		_fail("按住回溯键后时间场未进入 REWIND(mode=%d)" % re_mode)
	if elites.is_empty():
		_note("回溯段场上没有精英:精英配色断言跳过")
	elif missing > 0:
		_fail("回溯时 %d/%d 个精英没有高亮副本" % [missing, elites.size()])
	elif bad > 0:
		_fail("回溯时 %d/%d 个精英的高亮不是两层亮黄" % [bad, elites.size()])
	if created_b - created_a > 3:
		_fail("高亮副本在抖动重建(3 帧内新建 %d 个):管理器每帧 free+attach" % (created_b - created_a))
	if re_pl != null:
		_fail("回溯时主角不该有高亮(回溯是「世界倒退」,不是主角加速)")
	if re_normal:
		_fail("回溯时普通敌不该有高亮(它们的位移由回放器摆)")

	# ── ⑦ 松开回 NONE + 粒子真被扣 ──
	if tf.is_hasting() or tf.is_rewinding():
		_fail("松开后时间场未回 NONE(mode=%d)" % tf.mode)
	var bal := float(Level0.grain_account.balance)
	if bal >= float(TimeParams.GRAIN_INITIAL):
		_fail("加速没扣颗粒(余额 %.1f ≥ 初始 %d)" % [bal, TimeParams.GRAIN_INITIAL])

	var head := "HASTE PROBE: "
	if _fails.is_empty():
		print(head + "OK(倍率表/敌速×%.2f/敌弹×%.2f/玩家移速×%.2f/跳跃高度不变/红蓝残影/高亮规则/精英亮黄/松开全卸/回NONE/扣颗粒)" % [TimeParams.HASTE_WORLD, _bullet_ratio, ratio])
		if not _notes.is_empty():
			print("  notes: " + " | ".join(_notes))
		tree.quit(0)
	else:
		print(head + "FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)


# ── 小工具 ─────────────────────────────────────────────────────────

# 等到水平速度进入平台期(|Δv| < 0.5 px/s 连续 10 帧),最多等 max_frames 帧。
func _settle_vx(player: CharacterBody2D, max_frames := 240) -> void:
	var t := get_tree()
	var last := -1.0
	var stable := 0
	for i in max_frames:
		await t.physics_frame
		var v := absf(player.velocity.x)
		if absf(v - last) < 0.5:
			stable += 1
			if stable >= 10:
				return
		else:
			stable = 0
		last = v


func _wait_phys(n: int) -> void:
	var t := get_tree()
	for i in n:
		await t.physics_frame


func _is_elite_yellow(g: TimeGlow) -> bool:
	return g.color.r > 0.8 and g.color.g > 0.6 and g.color.b < 0.3 and g.passes() >= 2


func _near(a: Node2D, b: Node2D) -> bool:
	var d := MazeGenerator.toroidal_delta_px(a.global_position, b.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return d.length() <= Level0.GLOW_RADIUS


# 平均值 = "稳态速度":起手 45 帧让指数缓动收敛后再采 20 帧。
func _mean_vx(player: CharacterBody2D, frames: int, watch_ghosts := false) -> float:
	var t := get_tree()
	var sum := 0.0
	for i in frames:
		await t.physics_frame
		sum += absf(player.velocity.x)
		if watch_ghosts:
			_scan_ghosts(player)
			if TimeField.current != null and TimeField.current.is_hasting():
				_haste_frames += 1
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


# 打一颗**无重力、向上**的敌方弹,量它每帧位移的**中位数**(px)。
# 向上 + 只有地形碰撞(mask=1)+ 放在净空格  ->  不会撞墙/不会打到玩家,
# 位移 = velocity_vec × delta  ->  加速时应当恰好 ×HASTE_WORLD(比值 ~0.7)。
# - 取中位数而不是总和:撞墙/被锚副本瞬移只会让**帧数**变少,不改变单帧步长,
#   总和会被"提前死掉"污染成假失败。
func _bullet_step(tree: SceneTree, player: Node2D, at: Vector2) -> float:
	var b := BulletScene.instantiate() as EnemyBullet
	player.get_parent().add_child(b)
	b.global_position = at
	b.collision_mask = 1
	b.apply_damage = false
	b.launch(Vector2(0.0, -200.0), 400.0, 0, 0.0)
	var steps: Array[float] = []
	var prev: float = b.global_position.y
	for i in 12:
		await tree.physics_frame
		if not is_instance_valid(b):
			break
		var dy := absf(b.global_position.y - prev)
		prev = b.global_position.y
		if dy < 40.0:      # 跨接缝锚副本的瞬移帧不计
			steps.append(dy)
	if is_instance_valid(b):
		b.queue_free()
	if steps.is_empty():
		return -1.0
	steps.sort()
	return steps[steps.size() >> 1]


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


# 找一格"上方 4 格净空(跳跃/弹道要空间)+ 下方实心(有地板)"的格子,并取**离玩家环面最近**的那一格:
# ① 地形无关的确定性几何 —— 否则两次测量在不同位置,高度/弹道不可比;
# ② 离玩家近  ->  子弹不会被 `anchor_to_nearest` 锚到别的副本上瞬移。
func _find_open_spot(from: Vector2) -> Vector2i:
	var grid: Array = MazeGenerator.current_grid
	if grid.is_empty():
		return Vector2i(-1, -1)
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	var ts := float(GameParameters.TILE_SIZE)
	var best := Vector2i(-1, -1)
	var best_d := INF
	for r in range(rows - 2, 1, -1):
		for c in range(cols):
			var clear := true
			for k in 5:
				if int(grid[posmod(r - k, rows)][c]) != MazeGenerator.EMPTY:
					clear = false
					break
			if not clear or not TileDefs.is_blocked(int(grid[posmod(r + 1, rows)][c])):
				continue
			var p := Vector2(float(c) * ts + ts * 0.5, float(r) * ts + ts * 0.5)
			var d := MazeGenerator.toroidal_delta_px(p, from,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
			if d < best_d:
				best_d = d
				best = Vector2i(c, r)
	return best


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


func _count_glows(root: Node) -> int:
	var n := 0
	for c in root.get_children():
		if c is TimeGlow:
			n += 1
		n += _count_glows(c)
	return n
