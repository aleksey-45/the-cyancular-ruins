extends SceneTree

# 道具系统诊断(代理可跑,-s 阶段不触 autoload):
#  1) 注册表:槽位 8/9/10/11 四款道具齐全、名字齐、prop_no_reload=true、mag=2;
#     槽 8(排斥弹头,卡 pr_knockback rev2)= blast_force 9000 / 半径 260 / 全域等强斥力(FLAT)/
#     白圈外扩 + 撞实体同走满引信(hit_fuse_time 0.5);
#     槽 9(引力核心/吸力炮,卡 pr_attraction rev20)= blast_force -9000 / 半径 900 / 全域等强吸力(FLAT)/ 引信白环;
#     槽 11(投掷爆炸团,卡 pr_731505)= 6s 倒计时 / 爆炸伤满伤=满血且 LINEAR 线性衰减 /
#     轻度击退 2600 / blast_force=0(走爆炸伤,不开冲击场);
#  2) 烟雾:Smoke.spawn_zone 建区 → inside() 命中/不命中;区过期自毁由场景内 age 驱动(此处只验几何);
#  3) 无伤冲击:Explosion.apply_force_aoe 空场调用不崩;衰减模式纯函数(线性档回归+全域等强档);
#     爆炸伤-距离纯函数 _blast_falloff(LINEAR 满伤线性档 + FLAT/缺省档回归);BulletBase 冲击/白环字段齐
#     + light_fuse(计时弹出手燃引);引信白环节点(blast_ring_fx)烘焙+入树+按时自毁;
#  4) 计时引信节点(timed_bomb_fuse,-s 安全路径):holder 有效存活、holder 失效首帧自撤
#     (不在真空中起爆)、headless 不建倒计时 HUD。
# 打印 PROP PROBE: OK/FAIL 后退出。

func _initialize() -> void:
	_run()

func _run() -> void:
	# 保险:20s 未收尾强制退出(任何运行时错误都不至于挂死)
	create_timer(20.0).timeout.connect(func() -> void: quit(2))
	var fails: Array[String] = []
	var wc: GDScript = load("res://Scenes/Player/weapon_component.gd")
	var pp: GDScript = load("res://Globals/playerParams.gd")
	for s in [8, 9, 10, 11]:
		if not wc.WEAPONS.has(str(s)):
			fails.append("槽位 %d 未注册" % s)
		elif not wc.DISPLAY_NAMES.has(s):
			fails.append("槽位 %d 缺显示名" % s)
	for pair in [["8", 9000.0, 260.0], ["9", -9000.0, 900.0], ["10", 0.0, 340.0], ["11", 0.0, 260.0]]:
		var scn: PackedScene = load(wc.WEAPONS[pair[0]])
		if scn == null:
			fails.append("%s 场景加载失败" % pair[0])
			continue
		var w: Node2D = scn.instantiate()
		root.add_child(w)
		if not bool(w.get("prop_no_reload")):
			fails.append("%s prop_no_reload 未开" % pair[0])
		if int(w.get("mag_size")) != 2:
			fails.append("%s 携带数 != 2" % pair[0])
		if absf(float(w.get("blast_force")) - float(pair[1])) > 0.5:
			fails.append("%s blast_force=%s 期望 %s" % [pair[0], w.get("blast_force"), pair[1]])
		if absf(float(w.get("blast_radius")) - float(pair[2])) > 0.5:
			fails.append("%s blast_radius=%s 期望 %s" % [pair[0], w.get("blast_radius"), pair[2]])
		# 排斥弹头(pr_knockback)卡 rev2:全域等强斥力(FLAT=2)+ 白圈外扩 + 撞实体同走满引信
		if pair[0] == "8":
			if int(w.get("blast_falloff_mode")) != 2:
				fails.append("8 blast_falloff_mode=%s 期望 2(FLAT 全域等强)" % w.get("blast_falloff_mode"))
			if not bool(w.get("fuse_ring_visual")):
				fails.append("8 fuse_ring_visual 未开(卡 rev2 约定白圈外扩)")
			if absf(float(w.get("hit_fuse_time")) - 0.5) > 0.01:
				fails.append("8 hit_fuse_time=%s 期望 0.5(撞实体也走满白圈序列)" % w.get("hit_fuse_time"))
			if str(wc.DISPLAY_NAMES.get(8)) != "排斥弹头":
				fails.append("8 显示名=%s 期望 排斥弹头" % wc.DISPLAY_NAMES.get(8))
		# 吸力炮(pr_attraction)卡 rev20:全域等强吸力(FLAT=2)+ 引信白环
		if pair[0] == "9":
			if int(w.get("blast_falloff_mode")) != 2:
				fails.append("9 blast_falloff_mode=%s 期望 2(FLAT 全域等强)" % w.get("blast_falloff_mode"))
			if not bool(w.get("fuse_ring_visual")):
				fails.append("9 fuse_ring_visual 未开(卡约定引信白环)")
			if str(wc.DISPLAY_NAMES.get(9)) != "引力核心":
				fails.append("9 显示名=%s 期望 引力核心" % wc.DISPLAY_NAMES.get(9))
		# 投掷爆炸团(pr_731505)槽 11:6s 倒计时 / 满血线性爆炸伤 / 轻度击退 / 无冲击场
		if pair[0] == "11":
			if absf(float(w.get("countdown_time")) - 6.0) > 0.01:
				fails.append("11 countdown_time=%s 期望 6.0(卡:倒计时 6s)" % w.get("countdown_time"))
			if int(w.get("blast_falloff_mode")) != 1:
				fails.append("11 blast_falloff_mode=%s 期望 1(LINEAR 与爆心距离线性衰减)" % w.get("blast_falloff_mode"))
			if int(w.get("explosion_damage")) != int(pp.player_max_hp):
				fails.append("11 explosion_damage=%s 期望 满血 %d(卡:满伤=满血)" % [w.get("explosion_damage"), int(pp.player_max_hp)])
			if absf(float(w.get("explosion_knockback")) - 2600.0) > 0.5:
				fails.append("11 explosion_knockback=%s 期望 2600(轻度击退≈260px 位移)" % w.get("explosion_knockback"))
			if absf(float(w.get("blast_force"))) > 0.01:
				fails.append("11 blast_force=%s 期望 0(走爆炸伤,不开冲击场)" % w.get("blast_force"))
			if str(wc.DISPLAY_NAMES.get(11)) != "投掷爆炸团":
				fails.append("11 显示名=%s 期望 投掷爆炸团" % wc.DISPLAY_NAMES.get(11))
		w.queue_free()

	var smoke: GDScript = load("res://Globals/smoke.gd")
	var zs: GDScript = load("res://Scenes/Effects/smoke_zone.gd")
	var zone: Node2D = zs.new()
	zone.radius = 200.0
	zone.duration = 0.2
	zone.position = Vector2(100, 100)
	root.add_child(zone)
	await process_frame   # -s 的 _initialize 阶段 add_child 尚未入树,等一帧让 _ready/分组生效
	await process_frame
	if not bool(smoke.inside(Vector2(120, 110))):
		fails.append("Smoke.inside 烟雾内未命中")
	if bool(smoke.inside(Vector2(5000, 5000))):
		fails.append("Smoke.inside 烟雾外误命中")

	var ex: GDScript = load("res://Globals/explosion.gd")
	ex.apply_force_aoe(Vector2.ZERO, 300.0, 2600.0, null, null)   # 空场不崩
	# 线性档(LINEAR=1,rev18~19 历史档回归):爆心满强度、边缘归零、中点半强
	if absf(float(ex._force_falloff(0.0, 900.0, 9000.0, 1)) - 9000.0) > 0.01:
		fails.append("线性衰减爆心值错")
	if absf(float(ex._force_falloff(900.0, 900.0, 9000.0, 1))) > 0.01:
		fails.append("线性衰减边缘未归零")
	if absf(float(ex._force_falloff(450.0, 900.0, 9000.0, 1)) - 4500.0) > 0.01:
		fails.append("线性衰减中点值错")
	# 全域等强档(FLAT=2,rev20 卡约定):范围内任何距离都吃满同等力度
	if absf(float(ex._force_falloff(0.0, 900.0, 9000.0, 2)) - 9000.0) > 0.01:
		fails.append("全域等强爆心值错")
	if absf(float(ex._force_falloff(899.0, 900.0, 9000.0, 2)) - 9000.0) > 0.01:
		fails.append("全域等强贴边值错(应与爆心同等力度)")
	if absf(float(ex._force_falloff(900.0, 900.0, 9000.0, 2))) > 0.01:
		fails.append("全域等强范围外未归零")
	# 爆炸伤-距离纯函数(_blast_falloff,apply_aoe 共用;LINEAR=1 计时爆炸团线性档):
	# 爆心满伤、边缘归零、中点恰半伤(卡:「与爆炸中心距离成线性衰减」)
	if absf(float(ex._blast_falloff(0.0, 260.0, 50.0, 1)) - 50.0) > 0.01:
		fails.append("线性爆炸伤爆心值错")
	if absf(float(ex._blast_falloff(260.0, 260.0, 50.0, 1))) > 0.01:
		fails.append("线性爆炸伤边缘未归零")
	if absf(float(ex._blast_falloff(130.0, 260.0, 50.0, 1)) - 25.0) > 0.01:
		fails.append("线性爆炸伤中点值错(应恰为半伤)")
	# FLAT 档(2)回归:贴边同等强;缺省档(0=二次缓出)中远距保留不小于线性档
	if absf(float(ex._blast_falloff(259.0, 260.0, 50.0, 2)) - 50.0) > 0.01:
		fails.append("全域等强爆炸伤贴边值错")
	if float(ex._blast_falloff(200.0, 260.0, 50.0, 0)) < float(ex._blast_falloff(200.0, 260.0, 50.0, 1)) - 0.01:
		fails.append("缺省二次缓出中远距应≥线性档")
	var bb: GDScript = load("res://Scenes/Weapons/bullet_base.gd")
	var inst = bb.new()
	if not ("blast_force" in inst and "smoke_duration" in inst):
		fails.append("BulletBase 缺 blast_force/smoke_duration 字段")
	if not ("blast_falloff_mode" in inst and "fuse_ring_visual" in inst):
		fails.append("BulletBase 缺 blast_falloff_mode/fuse_ring_visual 字段")
	if not inst.has_method("light_fuse"):
		fails.append("BulletBase 缺 light_fuse(计时弹出手燃引)")
	inst.free()
	# 引信白环节点:建环入树(烘焙不崩),短时长后应按时自毁;外扩向(排斥弹头)同验
	var ringfx: GDScript = load("res://Scenes/Effects/blast_ring_fx.gd")
	var ring: Node2D = ringfx.new()
	ring.radius = 900.0
	ring.duration = 0.01
	root.add_child(ring)
	var ring_out: Node2D = ringfx.new()
	ring_out.radius = 260.0
	ring_out.duration = 0.01
	ring_out.outward = true
	root.add_child(ring_out)
	await create_timer(0.3).timeout
	if is_instance_valid(ring):
		fails.append("引信白环未按时自毁")
		ring.free()
	if is_instance_valid(ring_out):
		fails.append("外扩白圈未按时自毁")
		ring_out.free()

	# 计时引信节点(-s 安全路径:不触发 Sfx/网络/起爆):
	# a) holder 有效且在树 → 引信存活(倒计时未到点不消失);headless 下不建倒计时 HUD
	var holder := Node2D.new()
	root.add_child(holder)
	var fuse: Node = load("res://Scenes/Effects/timed_bomb_fuse.gd").new()
	fuse.holder = holder
	fuse.remaining = 5.0
	root.add_child(fuse)
	await process_frame
	await process_frame
	if not is_instance_valid(fuse):
		fails.append("引信节点被提前回收(holder 有效时应存活到倒计时结束)")
	if get_first_node_in_group("prop_countdown_hud") != null:
		fails.append("headless 下不应创建倒计时 HUD")
	# b) holder 失效(未入树)→ 首帧自撤:引信不在真空中起爆
	var fuse2: Node = load("res://Scenes/Effects/timed_bomb_fuse.gd").new()
	fuse2.holder = null
	fuse2.remaining = 5.0
	root.add_child(fuse2)
	await create_timer(0.3).timeout
	if is_instance_valid(fuse):
		fuse.free()
	if is_instance_valid(holder):
		holder.free()
	if is_instance_valid(fuse2):
		fails.append("holder 失效的引信未自撤(可能把爆炸带进退役场景)")
		fuse2.free()

	if fails.is_empty():
		print("PROP PROBE: OK(注册表/携带数/冲击方向/衰减模式/引信白环/烟雾几何/字段/计时引信)")
		quit(0)
	else:
		for f in fails:
			push_error("PROP PROBE FAIL: " + f)
		print("PROP PROBE: FAIL")
		quit(1)
