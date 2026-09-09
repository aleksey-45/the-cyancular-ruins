extends SceneTree

# 激光枪移植诊断(代理可跑,-s 阶段 autoload 未实例化,本探针不触 autoload):
# 1) 加载并实例化 laser_gun.tscn → 验证 LaserWeaponBase/WeaponBase 解析、Muzzle 节点齐、
#    武器实例有 collect_pending_beam_report(基类上报接口)。
# 2) BeamTrace.trace 空网格 → 直线两点;再喂一块实心格 → 首段遇墙出拐点/触点。
#    打印 LASER PROBE: OK/FAIL 后退出。

func _initialize() -> void:
	_run()

func _run() -> void:
	var fails: Array[String] = []
	var gun_scene: PackedScene = load("res://Scenes/Weapons/laser_gun.tscn")
	if gun_scene == null:
		fails.append("laser_gun.tscn 加载失败")
	else:
		var gun: Node2D = gun_scene.instantiate()
		root.add_child(gun)
		if gun.get_node_or_null("Muzzle") == null:
			fails.append("找不到 Muzzle 节点")
		if gun.get_node_or_null("Sprite2D") == null:
			fails.append("找不到 Sprite2D 节点")
		if not gun.has_method("collect_pending_beam_report"):
			fails.append("LaserWeaponBase 上报接口缺失(类解析失败?)")
		if not gun.has_method("_spawn_projectiles"):
			fails.append("WeaponBase._spawn_projectiles 钩子缺失")
		gun.queue_free()

	var bt: GDScript = load("res://Globals/beam_trace.gd")
	if bt == null:
		fails.append("beam_trace.gd 加载失败")
	else:
		var r: Dictionary = bt.trace(Vector2.ZERO, Vector2.RIGHT, 1000.0, 0)
		var pts: PackedVector2Array = r["points"]
		if pts.size() != 2:
			fails.append("空网格直线应 2 点,实际 %d" % pts.size())
		if r["contacts"].size() != 0:
			fails.append("空网格不应有触点")

	if fails.is_empty():
		print("LASER PROBE: OK(激光场景实例化/钩子/光束几何基础)")
		quit(0)
	else:
		for f in fails:
			push_error("LASER PROBE FAIL: " + f)
		print("LASER PROBE: FAIL")
		quit(1)
