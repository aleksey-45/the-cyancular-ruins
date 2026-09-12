extends SceneTree

# 道具系统诊断(代理可跑,-s 阶段不触 autoload):
#  1) 注册表:槽位 8/9/10 三款道具齐全、名字齐、prop_no_reload=true、mag=2;
#  2) 烟雾:Smoke.spawn_zone 建区 → inside() 命中/不命中;区过期自毁由场景内 age 驱动(此处只验几何);
#  3) 无伤冲击:Explosion.apply_force_aoe 空场调用不崩;BulletBase 有 blast_force/smoke_duration 字段。
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
	for pair in [["8", 2600.0], ["9", -2600.0], ["10", 0.0]]:
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
	var bb: GDScript = load("res://Scenes/Weapons/bullet_base.gd")
	var inst = bb.new()
	if not ("blast_force" in inst and "smoke_duration" in inst):
		fails.append("BulletBase 缺 blast_force/smoke_duration 字段")
	inst.free()

	if fails.is_empty():
		print("PROP PROBE: OK(注册表/携带数/冲击方向/烟雾几何/字段)")
		quit(0)
	else:
		for f in fails:
			push_error("PROP PROBE FAIL: " + f)
		print("PROP PROBE: FAIL")
		quit(1)
