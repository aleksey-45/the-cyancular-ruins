extends SceneTree

# 道具系统诊断(代理可跑,-s 阶段不触 autoload):
#  1) 注册表:槽位 8/9/10 三款道具齐全、名字齐、prop_no_reload=true、mag=2;
#     槽 9(引力核心/吸力炮,卡 pr_attraction rev18)= blast_force -50 / 半径 900 / 线性衰减 / 引信白环;
#  2) 烟雾:Smoke.spawn_zone 建区 → inside() 命中/不命中;区过期自毁由场景内 age 驱动(此处只验几何);
#  3) 无伤冲击:Explosion.apply_force_aoe 空场调用不崩;线性衰减纯函数;BulletBase 冲击/白环字段齐;
#     引信白环节点(blast_ring_fx)烘焙+入树+按时自毁。
# 打印 PROP PROBE: OK/FAIL 后退出。

func _initialize() -> void:
	_run()

func _run() -> void:
	# 保险:20s 未收尾强制退出(任何运行时错误都不至于挂死)
	create_timer(20.0).timeout.connect(func() -> void: quit(2))
	var fails: Array[String] = []
	var wc: GDScript = load("res://Scenes/Player/weapon_component.gd")
	for s in [8, 9, 10]:
		if not wc.WEAPONS.has(str(s)):
			fails.append("槽位 %d 未注册" % s)
		elif not wc.DISPLAY_NAMES.has(s):
			fails.append("槽位 %d 缺显示名" % s)
	for pair in [["8", 2600.0, 260.0], ["9", -50.0, 900.0], ["10", 0.0, 230.0]]:
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
		# 吸力炮(pr_attraction)卡 rev18:线性衰减 + 引信白环
		if pair[0] == "9":
			if not bool(w.get("blast_linear_falloff")):
				fails.append("9 blast_linear_falloff 未开(卡约定按距离线性衰减)")
			if not bool(w.get("fuse_ring_visual")):
				fails.append("9 fuse_ring_visual 未开(卡约定引信白环)")
			if str(wc.DISPLAY_NAMES.get(9)) != "引力核心":
				fails.append("9 显示名=%s 期望 引力核心" % wc.DISPLAY_NAMES.get(9))
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
	# 线性衰减纯函数:爆心满强度、边缘归零、中点半强(吸力炮卡约定「按距离线性衰减」)
	if absf(float(ex._force_falloff(0.0, 900.0, 50.0, true)) - 50.0) > 0.01:
		fails.append("线性衰减爆心值错")
	if absf(float(ex._force_falloff(900.0, 900.0, 50.0, true))) > 0.01:
		fails.append("线性衰减边缘未归零")
	if absf(float(ex._force_falloff(450.0, 900.0, 50.0, true)) - 25.0) > 0.01:
		fails.append("线性衰减中点值错")
	var bb: GDScript = load("res://Scenes/Weapons/bullet_base.gd")
	var inst = bb.new()
	if not ("blast_force" in inst and "smoke_duration" in inst):
		fails.append("BulletBase 缺 blast_force/smoke_duration 字段")
	if not ("blast_linear_falloff" in inst and "fuse_ring_visual" in inst):
		fails.append("BulletBase 缺 blast_linear_falloff/fuse_ring_visual 字段")
	inst.free()
	# 引信白环节点:建环入树(烘焙不崩),短时长后应按时自毁
	var ringfx: GDScript = load("res://Scenes/Effects/blast_ring_fx.gd")
	var ring: Node2D = ringfx.new()
	ring.radius = 900.0
	ring.duration = 0.01
	root.add_child(ring)
	await create_timer(0.3).timeout
	if is_instance_valid(ring):
		fails.append("引信白环未按时自毁")
		ring.free()

	if fails.is_empty():
		print("PROP PROBE: OK(注册表/携带数/冲击方向/线性衰减/引信白环/烟雾几何/字段)")
		quit(0)
	else:
		for f in fails:
			push_error("PROP PROBE FAIL: " + f)
		print("PROP PROBE: FAIL")
		quit(1)
