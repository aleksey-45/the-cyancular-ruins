extends Node

# 道具端到端诊断(单机真实世界):加载 Level0 → 直接驱动道具发射器 → 验证
#  ① 投掷物真的生成(bullet 组)且带 blast_force/smoke_duration;
#  ② 起效后:排斥弹头把玩家推开(knock_velocity 变化)、烟雾区真的出现(smoke_zone 组);
#  ③ T 模式装备链:equip("8"/"10") 成功且 current_weapon 是道具;
#  ④ 计时爆炸团(槽 11):拉销只点燃不生成投掷物(timed_bomb_fuse 组)→ 再按掷出
#     (剩余引信随弹走)→ 拉销后不掷,倒计时走完原地自爆(玩家在爆心吃满血伤倒地)。
# 打印 PROP E2E: OK/FAIL。

func _ready() -> void:
	_run()

func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var fails: Array[String] = []
	var lvl: Node = load("res://Scenes/Level0.tscn").instantiate()
	tree.root.add_child(lvl)
	for i in 10:
		await tree.process_frame
	for i in 5:
		await tree.physics_frame
	var player: Node = lvl.get_node_or_null("WorldViewport/Player")
	if player == null:
		print("PROP E2E: FAIL 找不到 Player")
		_finish()
		return
	var weapons: Node = player.get_node_or_null("Weapons")
	if weapons == null:
		print("PROP E2E: FAIL 找不到 Weapons")
		_finish()
		return

	# ── ① 真实路径:模拟按 T(player._unhandled_input)→ 是否进入道具模式 ──
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_T
	ev.pressed = true
	player._unhandled_input(ev)
	await tree.process_frame
	await tree.process_frame
	if not weapons.is_prop_mode():
		fails.append("按 T 未进入道具模式(仍槽位 %d)" % weapons.current_slot_int())
	var w: Node = weapons.current_weapon()
	if w == null or not w.has_method("_spawn_projectiles"):
		fails.append("T 后没有道具实例(槽位 %d)" % weapons.current_slot_int())
		print("PROP E2E: FAIL " + "; ".join(fails))
		_finish()
		return
	print("PROBE[T]: prop_mode=", weapons.is_prop_mode(), " slot=", weapons.current_slot_int(),
			" blast_force=", w.get("blast_force"))

	# ── ①b 真实开火:调 fire() 本体(与鼠标点击同路径),看弹是否生成 ──
	var n0 := tree.get_nodes_in_group("bullet").size()
	w.fire()
	for i in 6:
		await tree.physics_frame
	var n1 := tree.get_nodes_in_group("bullet").size()
	print("PROBE[fire]: bullet %d→%d (fire_cooldown=%s reload_active=%s mag=%s)" % [
			n0, n1, str(w.get("fire_cd_timer")), str(w.reload_active()), str(w.get("mag_ammo"))])
	if n1 <= n0:
		fails.append("fire() 没有生成投掷物")
	if w == null or not w.has_method("_spawn_projectiles"):
		fails.append("equip(8) 后没有道具实例")
		print("PROP E2E: FAIL " + "; ".join(fails))
		_finish()
		return
	if float(w.get("blast_force")) != 9000.0:
		fails.append("排斥弹头 blast_force=%s" % str(w.get("blast_force")))

	# ── ② 发射排斥弹头:在玩家旁边起效,验证推力 ──
	var v0: Vector2 = player.combat.knock_velocity
	var muzzle_from: Node2D = w.get_node_or_null("Muzzle") as Node2D
	var dir := Vector2.RIGHT
	if muzzle_from != null:
		dir = (Vector2.RIGHT * float(player.get("facing_direction"))).normalized()
	var vp: Viewport = (lvl as Node).get_node("WorldViewport")
	var near_player := 0
	w._spawn_projectiles(dir)
	var n_bullets := 0
	for i in 8:
		await tree.physics_frame
		n_bullets = maxi(n_bullets, tree.get_nodes_in_group("bullet").size())
		# 回归断言:出生位置必须在玩家附近(漏 muzzle 出生位 → 弹生成在世界原点)
		for b in tree.get_nodes_in_group("bullet"):
			if is_instance_valid(b) and 					((b as Node2D).global_position - (player as Node2D).global_position).length() < 400.0:
				near_player += 1
	if n_bullets < 1:
		fails.append("投掷物没有生成(bullet 组为空)")
	elif near_player < 1:
		fails.append("投掷物出生位置不在玩家附近(疑似漏设 muzzle 出生位)")
	# 直接把一颗道具弹放到玩家旁 120px 处,短引信,确定起效位置
	var bullet: CharacterBody2D = load("res://Scenes/Weapons/prop_bullet.tscn").instantiate()
	bullet.setup(Vector2.RIGHT, 1.0, 1100.0, 1.4, Color(1, 0.6, 0.25), w)   # 速度≈0:原地起爆,保证落在玩家作用半径内
	bullet.shooter = player
	bullet.explodes = true
	bullet.blast_force = 9000.0
	bullet.blast_falloff_mode = 2   # FLAT 全域等强(卡 rev2 同款)
	bullet.explosion_radius = 260.0
	bullet.fuse_time = 0.2
	bullet.hit_fuse_time = 0.2
	bullet.explosion_damage = 0
	bullet.explosion_knockback = 0
	bullet.apply_damage = true
	bullet.global_position = (player as Node2D).global_position + Vector2(120, 0)
	bullet.set_meta("scene_path", "res://Scenes/Weapons/prop_bullet.tscn")
	vp.add_child(bullet)
	await tree.physics_frame
	bullet._explode()   # 直接原地起爆(诊断:不依赖碰撞/引信时序)
	# 击退随时间指数衰减:逐帧采样峰值才算数(等 1.2s 后读只会读到衰减后的 0)
	var max_knock := 0.0
	for i in 90:
		await tree.physics_frame
		max_knock = maxf(max_knock, (player.combat.knock_velocity as Vector2).length())
	if is_instance_valid(bullet):
		bullet.queue_free()
	if max_knock < 100.0:
		fails.append("排斥弹头冲击峰值 %d px/s(<100,无冲击)" % int(max_knock))

	# ── ③ 烟雾弹 ──
	weapons.equip("10")
	var ws: Node = weapons.current_weapon()
	if ws == null:
		fails.append("equip(10) 失败")
	else:
		var zones_before := tree.get_nodes_in_group("smoke_zone").size()
		var b2: CharacterBody2D = load("res://Scenes/Weapons/prop_bullet.tscn").instantiate()
		b2.setup(Vector2.RIGHT, 1.0, 1100.0, 1.4, Color(0.75, 0.78, 0.8), ws)
		b2.shooter = player
		b2.explodes = true
		b2.smoke_duration = 6.0
		b2.explosion_radius = 340.0
		b2.explosion_damage = 0
		b2.explosion_knockback = 0
		b2.fuse_time = 0.2
		b2.hit_fuse_time = 0.2
		b2.apply_damage = true
		b2.global_position = (player as Node2D).global_position + Vector2(150, 0)
		b2.set_meta("scene_path", "res://Scenes/Weapons/prop_bullet.tscn")
		vp.add_child(b2)
		await tree.physics_frame
		b2._explode()   # 直接起爆
		await tree.create_timer(0.4).timeout
		var zones_after := tree.get_nodes_in_group("smoke_zone").size()
		if is_instance_valid(b2):
			b2.queue_free()
		if zones_after <= zones_before:
			fails.append("烟雾区没有出现(smoke_zone 组 %d→%d)" % [zones_before, zones_after])

	# ── ④ 计时爆炸团(槽 11):点燃→掷出→超时原地自爆 ──
	weapons.equip("11")
	var wb: Node = weapons.current_weapon()
	if wb == null:
		fails.append("equip(11) 失败")
	else:
		# a) 第一按 = 拉销点燃:只挂引信(timed_bomb_fuse 组),不生成投掷物
		var fuses0 := tree.get_nodes_in_group("timed_bomb_fuse").size()
		var bullets0 := tree.get_nodes_in_group("bullet").size()
		wb.countdown_time = 2.0   # 缩短倒计时:探针不干等 6 秒(仍留足掷出窗口)
		wb.fire()
		await tree.process_frame
		await tree.process_frame
		var fuses1 := tree.get_nodes_in_group("timed_bomb_fuse").size()
		if fuses1 <= fuses0:
			fails.append("fire() 未点燃引信(timed_bomb_fuse 组 %d→%d)" % [fuses0, fuses1])
		if tree.get_nodes_in_group("bullet").size() > bullets0:
			fails.append("拉销阶段不应生成投掷物")
		# b) 第二按 = 掷出:剩余引信随弹走;燃烧时间减半后弹在远处爆,不回伤玩家
		wb.fire()
		var thrown := false
		for i in 4:
			await tree.physics_frame
			if tree.get_nodes_in_group("bullet").size() > bullets0:
				thrown = true
		if not thrown:
			fails.append("第二次 fire() 未掷出投掷物")
		if int(wb.get("mag_ammo")) != 1:
			fails.append("携带量异常:点燃+掷出应只耗 1 枚(mag_ammo=%s)" % str(wb.get("mag_ammo")))
		# 掷出的弹挪到远处引爆,避免偶发弹回落回玩家身边干扰 c)(起爆点固定离玩家 1200px)
		for b in tree.get_nodes_in_group("bullet"):
			if is_instance_valid(b) and b.get("source") == wb:
				(b as Node2D).global_position = (player as Node2D).global_position + Vector2(1200, 0)
		await tree.create_timer(2.4).timeout   # 等掷出的弹在远处爆完,再回满状态做 c)
		# c) 超时惩罚:拉销后不掷,倒计时走完 → 原地自爆,玩家在爆心吃满血伤倒地
		weapons.equip("11")
		var wb2: Node = weapons.current_weapon()
		if wb2 == null:
			fails.append("equip(11) 二次装备失败")
		else:
			wb2.countdown_time = 0.3
			var hp0: int = player.combat.hp
			wb2.fire()   # 只点燃,不再掷
			var downed := false
			for i in 120:
				await tree.physics_frame
				if player.has_method("is_downed") and player.is_downed():
					downed = true
					break
			if not downed:
				fails.append("倒计时走完未原地自爆(玩家未倒地;hp %d→%d)" % [hp0, int(player.combat.hp)])

	if fails.is_empty():
		print("PROP E2E: OK(投掷物生成/击退推力/烟雾区/计时爆炸团点燃-掷出-自爆)")
	else:
		for f in fails:
			push_error("PROP E2E FAIL: " + f)
		print("PROP E2E: FAIL " + "; ".join(fails))
	_finish()

func _finish() -> void:
	get_tree().quit(0)
