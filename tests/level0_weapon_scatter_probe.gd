extends Node

# 单机开局地面武器探针(场景模式;判据 grep `LEVEL0 SCATTER: ALL-OK`)。
#
#   ★ 安全网给足(3600 帧):探针正常跑完会自己 quit(),这个值**只在探针挂住时**才用得上 ——
#     放宽不花任何代价。原先的 600/900 在机器负载重时可能**先耗尽**、探针来不及跑完
#     就被掐断(表现为"一行 ALL-OK 都没有",看着像功能坏了)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/level0_weapon_scatter_probe.tscn
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
	await _phase_drop_hold(player, lvl)
	await _phase_slot_placement(player, lvl)

	# ── 有真实渲染时顺手取一张图,供**人眼**确认地上的枪真的画出来了 ──
	# (headless 下 get_image() 返回 null,跳过;断言部分两条腿都能跑。)
	# ★ 把玩家瞬移到最近的一件武器旁并冻住物理,否则他原地开始掉、枪早出画面了。
	# ★ **现查组**,别用 _ready 开头抓的 `all_pickups` —— 中间的丢弃/再捡阶段会
	#   queue_free 掉其中一些,拿旧数组去 `as Node2D` 就是 "Trying to cast a freed object"
	#   (只在带渲染这条路径上炸:headless 不走这段,所以那边一直是绿的)。
	var live_pickups: Array = []
	for q in get_tree().get_nodes_in_group("weapon_pickup"):
		if is_instance_valid(q):
			live_pickups.append(q)
	if DisplayServer.get_name() != "headless" and player != null and not live_pickups.is_empty():
		var best: Node2D = null
		var best_d := 1e18
		for p in live_pickups:
			var d: float = (p as Node2D).global_position.distance_to((player as Node2D).global_position)
			if d < best_d:
				best_d = d
				best = p
		# ★ 偏移必须**落在拾取半径内**(PlayerParams.weapon_pickup_radius = 64):
		#   站在范围外时提示本来就不该出现。(-50,-12) 的环面距离 ≈ 51px。
		if best != null:
			(player as Node2D).global_position = best.global_position + Vector2(-50.0, -12.0)
		player.set_physics_process(false)
		# 取图前摆一个已知背包,好让左下角的"持有武器剪影行"出现在图里
		# (丢弃那段结束时把背包清空了)。手持第一把 → 它应当是白的、其余灰的。
		player.weapons.set_initial_inventory([1, 3, 4])
		# ★ 冻掉物理后 `_poll_pickup_drop` 不再跑,丢弃闩锁会一直挂着 → 进度条常红(探针残留)。
		#   补一拍空 delta 让它复位(真机松手自然就复位)。
		player._poll_pickup_drop(0.0)
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


# ── 容量格子贴武器面板的**实际**顶边(用户 2026-09-16:「应该根据武器的框的高度自适应 bottom」)──
# ★ 为什么值得钉:武器面板是**随内容收缩**的(有几把枪就多高),而格子原先贴在一个写死的
#   y 上 —— 那种"顺手改一个数"不会报任何错,只会在实机上表现为"只带一把枪时格子飘在半空"。
#   判据取**两边的实际边**而不是"offset 等于某个数"(后者与实现同源,等于同义反复)。
func _phase_slot_placement(player: Node, lvl: Node) -> void:
	var hud: Node = lvl.get_node_or_null("HUD")
	if hud == null:
		_check(false, "Level0 里有 HUD 节点")
		return
	# ★ 取常量走 `get_script_constant_map()`,不要 `hud.get("WEAPON_SLOTS_GAP")` ——
	#   后者在这个引擎版本上**碰巧**能取到,但本仓踩过"直接取不存在的属性抛错 → 探针挂起"
	#   的坑,查常量一律用这个口(与 kh_l3/kh_l5 同款)。
	var consts: Dictionary = (hud.get_script() as Script).get_script_constant_map()
	if not consts.has("WEAPON_SLOTS_GAP"):
		_check(false, "hud.gd 里没有 WEAPON_SLOTS_GAP 常量")
		return
	var gap_expect := float(consts["WEAPON_SLOTS_GAP"])
	# 面板高度随把数变 → 逐个把数都比一遍(1 / 3 / 4 把走的是同一条重排路径)
	for plan in [[1], [1, 3, 4], [2, 4], [1, 2, 3, 5]]:
		player.weapons.set_initial_inventory(plan)
		for i in 6:
			await get_tree().process_frame
		var slots: Control = hud.get("_slots")
		var wrap: Control = hud.get("_weapon_wrap")
		if slots == null or wrap == null:
			_check(false, "HUD 拿不到 _slots / _weapon_wrap(容量格子还贴不贴武器面板?)")
			return
		var slots_bottom: float = slots.position.y + slots.size.y
		var wrap_top: float = wrap.position.y
		var gap: float = wrap_top - slots_bottom
		_check(gap > 0.0, "%d 把枪时容量格子不得压到武器面板上(实测 %+.1fpx)" % [plan.size(), gap])
		_check(absf(gap - gap_expect) < 1.5,
				"%d 把枪时间隙恒为 %.0fpx(实测 %.1f)" % [plan.size(), gap_expect, gap])
		_check(slots_bottom > 0.0 and slots.position.y > 0.0,
				"%d 把枪时容量格子留在画面内(y=%.0f)" % [plan.size(), slots.position.y])
	# 收尾:还原一张"图里好看"的背包(下面取图那步会再摆一次,这里只是别留 4 把的乱状态)
	player.weapons.set_initial_inventory([1])
	for i in 6:
		await get_tree().process_frame


# ── 拾取提示("每把**能捡的**武器各自一个加粗 F")──
# 双向钉:能捡的**必须**出现、走远的**必须**消失。只判"能出现"会把"常驻一个 F"放过去。
func _phase_pickup_prompt(player: Node, lvl: Node) -> void:
	var pickups := get_tree().get_nodes_in_group("weapon_pickup")
	if pickups.is_empty():
		_failures.append("没有地面武器,无法验提示")
		return
	var target: Node2D = pickups[0]
	# ① 站到它身上(距离 0 必然在半径内)
	# ★ 2026-09-17 起节点原点**就是**视觉中心(视觉中心已被挪到原点,visual_offset 已删),
	#   所以直接站节点位置即可。
	(player as Node2D).global_position = target.global_position
	for i in 5:
		await get_tree().process_frame
	var prompt = target.get("_prompt")
	_check(prompt != null, "能捡的那把武器应长出提示节点(懒建)")
	if prompt == null:
		return
	if not bool(prompt.visible):
		var pw: Vector2 = (player as Node2D).global_position
		var pk := target as WeaponPickup
		print("[prompt] 玩家=%s | 目标节点=%s canonical=%s | 距节点=%.1f 距canonical=%.1f (半径 %.0f)"
				% [str(pw), str(pk.global_position), str(pk.canonical_pos),
				pw.distance_to(pk.global_position), pw.distance_to(pk.canonical_pos),
				PlayerParams.weapon_pickup_radius])
	_check(bool(prompt.visible), "站在拾取半径内时提示应出现")
	_check((prompt as Node2D).z_index > 0, "提示应压在武器之上")
	# 提示挂在武器下、反向缩放抵消 WORLD_SCALE → 用 position 换算回世界单位比
	var gap: float = absf((prompt as Node2D).position.y) * WeaponPickup.WORLD_SCALE
	_check(gap > 20.0, "提示应浮在武器**上方**(实测 %.1f 世界单位)" % gap)

	# ② 走远 → 必须消失
	(player as Node2D).global_position = target.global_position + Vector2(900.0, 0.0)
	for i in 5:
		await get_tree().process_frame
	_check(not bool(prompt.visible), "走出拾取半径后提示应消失(否则屏幕上会常驻 F)")


# ── 丢弃(长按 Q 满 2s)──
# ★ 双向钉:短按**不该**丢、长按满**必须**丢。只判"能丢"会把"碰一下 Q 就丢"放过去 ——
#   那正是联机侧真实出现过的 bug(LocalInputSource 的 drop 读口报的是"Q 按着"而不是
#   "满了的边沿",于是碰一下就丢、按住不放每 tick 丢一把)。
func _phase_drop_hold(player: Node, lvl: Node) -> void:
	var wep = player.weapons
	# ★ 先把玩家摆到**一件已落地的武器**旁边并冻住物理:地面武器都是落到地板上的,
	#   所以那个位置就是地面。不这么做的话玩家在半空、丢弃那段里会自己掉一千多像素,
	#   而枪落在上面 —— 测出来是"玩家离所有枪都很远",看着像"捡不回来"(实测踩到)。
	var picks0 := get_tree().get_nodes_in_group("weapon_pickup")
	if picks0.is_empty():
		_failures.append("丢弃前置:场上没有地面武器")
		return
	var anchor_pk: Node2D = picks0[0]
	(player as Node2D).global_position = anchor_pk.global_position
	player.set_physics_process(false)
	for i in 5:
		await get_tree().process_frame
	wep.set_initial_inventory([1, 2])
	for i in 3:
		await get_tree().process_frame
	var before: int = wep.inventory.held.size()
	if before < 2:
		_failures.append("丢弃前置:背包里应有 2 把(实际 %d)" % before)
		return
	var ground_before: int = get_tree().get_nodes_in_group("weapon_pickup").size()
	print("[drop] current_scene=%s is_Level0=%s pvp_mode=%s" % [str(get_tree().current_scene), str(get_tree().current_scene is Level0), str(Level0.pvp_mode)])

	# ★ 阈值按**参数**算,别写死秒数 —— 它改过两次(2.0 → 1.0 → 0.6),
	#   写死会让断言在改参数后静默变成"测别的东西"(实测:改成 0.6 后"短按 1.0s"
	#   反而**会**丢,三条断言一起红)。
	var hold: float = PlayerParams.weapon_drop_hold_time
	# ① 短按(阈值的一半)→ 不该丢
	Input.action_press("Q")
	for i in int(hold * 10.0 * 0.5):
		player._poll_pickup_drop(0.1)
	Input.action_release("Q")
	player._poll_pickup_drop(0.0)   # 松开一拍:复位长按计时/闩锁
	_check(wep.inventory.held.size() == before,
			"按住不足 2s 不该丢(实际 %d → %d)" % [before, wep.inventory.held.size()])

	# ② 一次长按累计 2×阈值(**中途不松手**)→ 只该丢**一把**,地上多一件。
	#    ★ "中途不松手"是关键:松手再按是新的一次长按,再丢一把是**正确行为**
	#      (第一版这里松了手,断言写成"只应丢一把",是测试自己错)。
	Input.action_press("Q")
	for i in int(hold * 10.0 * 2.0) + 2:
		player._poll_pickup_drop(0.1)
	Input.action_release("Q")
	await get_tree().process_frame
	var after: int = wep.inventory.held.size()
	var ground_after: int = get_tree().get_nodes_in_group("weapon_pickup").size()
	_check(after == before - 1,
			"长按满 2s 应丢一把、且**只丢一把**(实际 %d → %d;4s 里丢了两把 = 闩锁失效)" % [before, after])
	_check(ground_after == ground_before + 1,
			"丢下的那把应真的落到地上(实际 %d,期望 %d)" % [ground_after, ground_before + 1])

	# ③ 空手后再长按:没东西可丢,不该崩也不该凭空多出东西
	wep.set_initial_inventory([])
	for i in 3:
		await get_tree().process_frame
	Input.action_press("Q")
	for i in int(hold * 10.0 * 2.0) + 2:
		player._poll_pickup_drop(0.1)
	Input.action_release("Q")
	# ★ 松手后必须补一拍:闩锁(_drop_latched)只在"没按 Q"的那一拍复位 ——
	#   漏了它,下一段的长按会被上一段的闩锁整个吞掉(实测:表现为"按了 Q 却丢不出去")。
	player._poll_pickup_drop(0.0)
	_check(true, "空手长按 Q 不崩")

	# ④ ★ 丢下的那把**必须能再捡回来**(用户 2026-09-16 报"丢弃的武器无法再次装备")。
	#    冷却期(weapon_pickup_self_delay)过后重新按 F —— 走向 try_pickup_for 的真实链路。
	wep.set_initial_inventory([1])
	for i in 3:
		await get_tree().process_frame
	Input.action_press("Q")
	for i in int(hold * 10.0 * 2.0) + 2:
		player._poll_pickup_drop(0.1)
	Input.action_release("Q")
	player._poll_pickup_drop(0.0)
	await get_tree().process_frame
	_check(wep.inventory.held.size() == 0, "应已把唯一那把丢出去(实际 %d)" % wep.inventory.held.size())
	# 冷却 0.5s:等它过期(按帧等,别用真实时间 —— headless 帧率不定)
	for i in 90:
		await get_tree().process_frame
		player._poll_pickup_drop(0.0)   # 让 _live_self_drops 有机会过期清表
	var back_ok := false
	for attempt in 12:
		Input.action_press("F")
		player._poll_pickup_drop(0.0)
		player._try_pickup()
		Input.action_release("F")
		for i in 3:
			await get_tree().process_frame
		if not wep.inventory.held.is_empty():
			back_ok = true
			break
	if not back_ok:
		var lv = player.host_level()
		var near: Dictionary = lv.ground_weapons.nearest_within(
				(player as Node2D).global_position, PlayerParams.weapon_pickup_radius, [])
		print("[repick] 场上 %d 件 | exclude=%s | 不排 excl 的最近一件=%s | 玩家 pos=%s"
				% [lv.ground_weapons.size(), str(lv._live_self_drops()), str(near.get("pos", "-")),
				str((player as Node2D).global_position)])
		if not near.is_empty():
			var nd = (near["pos"] as Vector2) - (player as Node2D).global_position
			print("[repick] 最近那件距玩家 %.1f px(半径 %.0f)" % [nd.length(), PlayerParams.weapon_pickup_radius])
	_check(back_ok, "丢下的那把应能再次捡起(背包仍空 = 冷却永不解除,或判定中心偏了)")
