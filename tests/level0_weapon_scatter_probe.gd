extends Node

# 单机开局地面武器探针(场景模式;判据 grep `LEVEL0 SCATTER: ALL-OK`)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 600 res://tests/level0_weapon_scatter_probe.tscn
#
# ═══ 为什么需要它 ═══
# 这条 bug **真的漏过一次、而且所有数值断言都是绿的**:地面武器原先 `add_child(self)`
# 挂到了 Level0 自己身上,而世界(瓦片/玩家/敌人)全渲染在 `$WorldViewport`(SubViewport)里
# —— 节点存在、有视觉、有碰撞箱、`global_scale` 也对,但**屏幕上什么都看不到**。
# 只有"它到底挂在谁下面"这条断言能拦住它。

var _failures: Array[String] = []


func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)


func _ready() -> void:
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	add_child(lvl)
	for i in 120:
		await get_tree().process_frame

	var world: Node = lvl.get_node_or_null("WorldViewport")
	_check(world != null, "Level0 有 WorldViewport")
	var player: Node = lvl.get_node_or_null("WorldViewport/Player")
	_check(player != null, "Level0 有玩家")

	# 开局**携带手枪**(2026-09-15 用户要求;此前是空手)
	if player != null:
		_check(player.weapons.current_slot_int() == 1,
				"单机开局应携带手枪(实际槽 %d)" % player.weapons.current_slot_int())
		_check(player.weapons.inventory.held.size() == 1,
				"开局背包里应只有那一把(实际 %d)" % player.weapons.inventory.held.size())

	var all_pickups := get_tree().get_nodes_in_group("weapon_pickup")
	# 每种 2 把 × 6 种 = 12(没有禁用武器时)
	_check(all_pickups.size() == 12, "开局应铺 12 件地面武器(实际 %d)" % all_pickups.size())

	# ★ 核心断言:每一件都必须挂在 WorldViewport 下(而不是 Level0 自己身上)
	var wrong_parent := 0
	var no_visual := 0
	var no_shape := 0
	var types := {}
	for p in all_pickups:
		if p.get_parent() != world:
			wrong_parent += 1
		if p.get_node_or_null("Visual") == null:
			no_visual += 1
		if p.get_node_or_null("Shape") == null:
			no_shape += 1
		types[int(p.type_id)] = int(types.get(int(p.type_id), 0)) + 1
	_check(wrong_parent == 0,
			"地面武器必须挂在 WorldViewport 下(有 %d 件挂错了 —— 挂到 Level0 自己身上就**看不见**)" % wrong_parent)
	_check(no_visual == 0, "每件都要有视觉节点(缺 %d 件)" % no_visual)
	_check(no_shape == 0, "每件都要有像素碰撞箱(缺 %d 件)" % no_shape)
	# 每种 2 把
	var bad := 0
	for k in types.keys():
		if int(types[k]) != 2:
			bad += 1
	_check(bad == 0, "每种武器应恰好 2 把(有 %d 种数量不对:%s)" % [bad, str(types)])

	await _phase_pickup_prompt(player, lvl)

	# ── 有真实渲染时顺手取一张图,供**人眼**确认地上的枪真的画出来了 ──
	# (headless 下 get_image() 返回 null,跳过;断言部分两条腿都能跑。)
	# ★ 把玩家瞬移到最近的一件武器旁并冻住物理,否则他原地开始掉、枪早出画面了。
	if DisplayServer.get_name() != "headless" and player != null and not all_pickups.is_empty():
		var best: Node2D = null
		var best_d := 1e18
		for p in all_pickups:
			var d: float = (p as Node2D).global_position.distance_to((player as Node2D).global_position)
			if d < best_d:
				best_d = d
				best = p
		# ★ 偏移必须**落在拾取半径内**(PlayerParams.weapon_pickup_radius = 64):
		#   站在范围外时提示本来就不该出现。(-50,-12) 的环面距离 ≈ 51px。
		if best != null:
			(player as Node2D).global_position = best.global_position + Vector2(-50.0, -12.0)
		player.set_physics_process(false)
		for i in 90:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_png("res://.superpowers/sdd/level0_scatter.png")
			print("[scatter] 已存 level0_scatter.png(玩家身旁那件武器就是画面里的参照)")

	if _failures.is_empty():
		print("LEVEL0 SCATTER: ALL-OK")
		get_tree().quit(0)
	else:
		printerr("LEVEL0 SCATTER FAILURES: " + str(_failures))
		get_tree().quit(1)


# ── 拾取提示("靠近武器时在武器上方浮现的加粗 F",用户 2026-09-15)──
# 双向钉:范围内**必须**出现、范围外**必须**消失。只判"能出现"会把
# "永远显示"这种坏实现放过去(那就成了屏幕上一个常驻的 F)。
func _phase_pickup_prompt(player: Node, lvl: Node) -> void:
	var prompt = lvl.get("_pickup_prompt")
	_check(prompt != null, "Level0 建起了拾取提示节点")
	if prompt == null or player == null:
		return
	var pickups := get_tree().get_nodes_in_group("weapon_pickup")
	if pickups.is_empty():
		_failures.append("没有地面武器,无法验提示")
		return
	var target: Node2D = pickups[0]
	# ① 贴到范围内 → 应显示,且**贴在那把武器上方**
	(player as Node2D).global_position = target.global_position + Vector2(-40.0, 0.0)
	for i in 5:
		await get_tree().process_frame
	_check(bool(prompt.visible), "站在拾取半径内时提示应出现")
	var dy: float = target.global_position.y - (prompt as Node2D).global_position.y
	_check(dy > 20.0, "提示应浮在武器**上方**(实测高出 %.1f px)" % dy)
	var dx: float = absf(target.global_position.x - (prompt as Node2D).global_position.x)
	_check(dx < 4.0, "提示应对准武器(横向偏 %.1f px)" % dx)
	_check((prompt as Node2D).z_index > 0, "提示应压在武器之上(z_index > 0)")

	# ② 走远 → 必须消失
	(player as Node2D).global_position = target.global_position + Vector2(600.0, 0.0)
	for i in 5:
		await get_tree().process_frame
	_check(not bool(prompt.visible), "走出拾取半径后提示应消失(否则屏幕上会常驻一个 F)")
