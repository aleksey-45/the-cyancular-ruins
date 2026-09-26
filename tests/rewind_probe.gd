extends Node

# 世界回溯探针(场景级,单机真世界,走**真实按键路径**):
#   Input.action_press("rewind") 模拟按住 Shift → 引擎 _process 的时间场/回放状态机全自然运转。
# 覆盖:录制 · 玩家位置与 HP 倒退 · 普通怪复活(尸体保留) · 精英不倒且不进快照 ·
#       回溯中免疫伤害 · 松开恢复录制。
# 用法:godot --headless --path . res://tests/rewind_probe.tscn

var _fails: Array[String] = []


func _ready() -> void:
	_run.call_deferred()   # root 建子节点期直接 add_child 会失败:必须脱离 _ready 栈


func _fail(msg: String) -> void:
	_fails.append(msg)


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	tree.root.add_child(lvl)
	for i in 12:
		await tree.process_frame
	for i in 5:
		await tree.physics_frame
	var player: Node = lvl.get_node_or_null("WorldViewport/Player")
	var rewind: WorldRewind = lvl.get("_rewind")
	if player == null or rewind == null or Level0.time_field == null:
		print("REWIND PROBE: FAIL(未就绪 player=%s rewind=%s tf=%s)" % [str(player), str(rewind), str(Level0.time_field)])
		tree.quit(1)
		return

	# 选目标:一个普通怪(复活用例)、一个打精英标的(不倒用例)
	var target: Node = null
	var elite: Node = null
	for e in tree.get_nodes_in_group("enemies"):
		if not (e is Node2D) or bool(e.get("is_dead")) or e.has_meta("elite"):
			continue   # 真乌鸫(B5 起自带 elite 标)不入"普通怪"用例——它本来就不参与回溯
		if target == null:
			target = e
		elif elite == null:
			elite = e
			break
	if target == null:
		print("REWIND PROBE: FAIL(图上无活怪)")
		tree.quit(1)
		return
	if elite != null:
		elite.set_meta("elite", true)

	# ① 录制 ~2.5s(引擎自行录制;此时 hold_corpses=true)
	for i in 150:
		await tree.physics_frame
	var p0: Vector2 = (player as Node2D).global_position
	var hp0: int = int(player.get("hp"))
	var frames0: int = rewind.frame_count()
	if frames0 < 15:
		_fail("录制帧数不足(%d)" % frames0)

	# ② 改变世界:玩家瞬移 200px + 掉血;普通怪击杀;精英击杀
	(player as Node2D).global_position += Vector2(200, 0)
	player.call("take_hit", Vector2.ZERO, 20, true, 0.0)
	target.call("hurt", 9999, Vector2.RIGHT, 0.0)
	if elite != null:
		elite.call("hurt", 9999, Vector2.RIGHT, 0.0)
	for i in 8:
		await tree.physics_frame
	if not bool(target.get("is_dead")):
		_fail("目标怪未被击杀(用例前置)")
	if elite != null and not bool(elite.get("is_dead")):
		_fail("精英未被击杀(用例前置)")

	# ③ 再录 1s(让"死亡后"的时间段进缓冲)
	for i in 60:
		await tree.physics_frame

	# ④ 按住 Shift 回溯 ~3s(真实按键路径)
	Input.action_press("rewind")
	for i in 180:
		await tree.physics_frame
	if not Level0.time_field.is_rewinding():
		_fail("时间场未进入 REWIND")

	if not is_instance_valid(target):
		_fail("目标怪节点已释放(尸体保留机制失灵)")
		print("REWIND PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)
		return
	var revived: bool = not bool(target.get("is_dead"))
	if not revived:
		_fail("普通怪未被回溯复活")
	elif not (target as Node2D).visible:
		_fail("复活的怪仍不可见")
	if revived and int(target.get("hp")) <= 0:
		_fail("复活的怪 HP 未复原")
	var p_back: Vector2 = (player as Node2D).global_position
	if p_back.distance_to(p0) > 32.0:
		_fail("玩家位置未倒回(距快照 %.1fpx)" % p_back.distance_to(p0))
	if int(player.get("hp")) < hp0:
		_fail("玩家 HP 未倒回(现 %d 快照 %d)" % [int(player.get("hp")), hp0])
	if elite != null and is_instance_valid(elite) and not bool(elite.get("is_dead")):
		_fail("精英被回溯复活了(应保持死亡)")

	# ⑤ 回溯中免疫伤害
	var hp_mid: int = int(player.get("hp"))
	player.call("take_hit", Vector2.ZERO, 30, true, 0.0)
	if int(player.get("hp")) != hp_mid:
		_fail("回溯中仍吃伤害(%d→%d)" % [hp_mid, int(player.get("hp"))])

	# ⑥ 松开 Shift:退出回溯、恢复录制
	Input.action_release("rewind")
	for i in 10:
		await tree.physics_frame
	if Level0.time_field.is_rewinding():
		_fail("松开后仍处于 REWIND")
	if not WorldRewind.hold_corpses:
		_fail("退出回溯后未恢复录制态(hold_corpses)")

	if _fails.is_empty():
		print("REWIND PROBE: OK(录制/玩家位置+HP倒退/普通怪复活可见/精英不倒/回溯免疫伤害/松开恢复)")
		tree.quit(0)
	else:
		print("REWIND PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)
