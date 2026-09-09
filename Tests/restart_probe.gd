extends Node

# 临时诊断(不倒库):加载完整单机 Level0 世界 → 造成倒地 → 调 Level0.restart_single()
# 验证原地复位:场景实例不变、玩家满血回出生点、敌人按难度重刷、无脚本错误。
# 跑法: Godot_console --headless --path . res://Tests/restart_probe.tscn

func _ready() -> void:
	_run()


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var lvl: Node = load("res://Scenes/Level0.tscn").instantiate()
	tree.root.add_child(lvl)
	# 建图是 call_deferred:等它 flush 且玩家从出生点下坠到地面完全站定,再记录初始位置
	for i in 40:
		await tree.process_frame
	for i in 20:
		await tree.physics_frame
	var fails: Array[String] = []
	if not is_instance_valid(lvl):
		fails.append("Level0 加载失败(脚本解析错误?)")
		_finish(fails)
		return
	var player: Node = lvl.get_node_or_null("WorldViewport/Player")
	if player == null:
		fails.append("找不到 Player")
		_finish(fails)
		return
	var combat: Node = player.get_node_or_null("Combat")
	if combat == null:
		fails.append("找不到 Combat 组件")
		_finish(fails)
		return
	var spawn_pos: Vector2 = player.global_position
	if combat.has_method("force_down"):
		combat.force_down()
	else:
		combat.hp = 0
	await tree.process_frame
	await tree.process_frame
	# 执行原地复位(单人倒地 R 走的同一入口)
	lvl.restart_single()
	for i in 40:
		await tree.process_frame
	for i in 20:
		await tree.physics_frame
	if not is_instance_valid(lvl):
		fails.append("restart 后 Level0 实例失效")
	elif player.global_position.distance_to(spawn_pos) > 6.0:
		fails.append("玩家未回出生点: %s → %s" % [spawn_pos, player.global_position])
	if int(combat.hp) != int(combat.max_hp):
		fails.append("血量未回满: %s/%s" % [combat.hp, combat.max_hp])
	if get_tree().get_nodes_in_group("enemies").size() <= 0:
		fails.append("敌人未重刷")
	var wl: Node = lvl.get_node_or_null("WorldViewport/WallLayer")
	if wl != null and wl.get_used_cells().is_empty():
		fails.append("瓦片层为空")
	_finish(fails)


func _finish(fails: Array[String]) -> void:
	if fails.is_empty():
		print("RESTART PROBE: ALL-OK(原地复位,实例复用,玩家满血回出生点,敌人重刷,瓦片在)")
		get_tree().quit(0)
	else:
		print("RESTART PROBE: FAIL | " + "; ".join(fails))
		get_tree().quit(1)
