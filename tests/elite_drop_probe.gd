extends Node

# 精英敌人掉落探针（场景级端到端测试，验证真实击杀流程）：击杀一只乌鸫 → 结晶特效生成 →
# 飞向怀表 HUD → 吸收后粒子数值入账 +300。
#
# 测试目的：此前针对特效单独测试无法验证“击杀事件触发 → enemy_base._begin_death →
# EnemyBlackBird._on_death → GrainCrystalFx.spawn”完整调用链路的完好性。
# 用户反馈击杀精英敌人未掉落时间粒子时，重点排查此链路。
#
# 判定标准：通过时间粒子账户余额增量验证（考虑 50/s 的自然恢复速率），确保实际入账增量 ≥ 290。
# 运行方式：godot --headless --path . res://tests/elite_drop_probe.tscn

var _fails: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _fail(m: String) -> void:
	_fails.append(m)


func _wait_phys(n: int) -> void:
	var t := get_tree()
	for i in n:
		await t.physics_frame


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	tree.root.add_child(lvl)
	for i in 12:
		await tree.process_frame
	await _wait_phys(40)
	if Level0.grain_account == null:
		print("ELITE DROP PROBE: FAIL(单机时间系统未建立)")
		tree.quit(1)
		return

	# 找到那只真乌鸫(场景 `_ready` 自带 elite 标;找不到就用备用怪并打标)
	var elite: Node2D = null
	var marked_by_probe := false
	for e in tree.get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e is Node2D and e.has_meta("elite") and not bool(e.get("is_dead")):
			elite = e
			break
	if elite == null:
		for e in tree.get_nodes_in_group("enemies"):
			if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")):
				elite = e
				marked_by_probe = true
				elite.set_meta("elite", true)
				break
	if elite == null:
		print("ELITE DROP PROBE: FAIL(场上没有可杀的怪)")
		tree.quit(1)
		return
	print("ELITE DROP PROBE: 目标 = %s(elite 标由%s提供)" % [
			elite.name, "探针补打" if marked_by_probe else "场景自带"])

	var bal0 := float(Level0.grain_account.balance)
	var fx_before := tree.get_nodes_in_group("grain_crystal").size()

	elite.call("hurt", 9999, Vector2.RIGHT, 0.0)
	# ★ 当场记击杀距离:精英死后 ~0.5s 就被释放(不入尸体保留),晚读 = use-after-free
	var pl_at_kill: Node2D = lvl.get_node_or_null("WorldViewport/Player") as Node2D
	var kill_dist := (elite.global_position - pl_at_kill.global_position).length() if pl_at_kill != null else 0.0
	await _wait_phys(2)
	var dead := bool(elite.get("is_dead"))
	var fx_after := tree.get_nodes_in_group("grain_crystal").size()
	if not dead:
		_fail("一刀没打死(用例前置)")
	if fx_after <= fx_before:
		_fail("击杀精英后没有生成结晶 FX(死亡钩子断了?_on_death → GrainCrystalFx.spawn)")

	# 结晶 0.28s 散开 + 飞向怀表:等够时间让它吸收
	var fx_node: Node = null
	for c in tree.get_nodes_in_group("grain_crystal"):
		fx_node = c
		break
	var bal_events := [0]
	Level0.grain_account.balance_changed.connect(func(_b: float) -> void: bal_events[0] += 1)
	# 逐帧盯到吸收那一刻:报告"吸收入账"发生在第几秒、以及是不是兜底那条路(HAS_ABSORB_TIMEOUT)
	var absorb_t := -1.0
	for i in 420:
		await tree.physics_frame
		if not is_instance_valid(fx_node):
			break
		if bool(fx_node.get("_absorbed")):
			absorb_t = float(fx_node.get("_t"))
			break
	print("ELITE DROP PROBE[diag]: 吸收方式=%s 发生在 t=%.2fs;入账事件=%d 余额=%.1f FX已释放=%s" % [
			GrainCrystalFx.last_absorb_kind, GrainCrystalFx.last_absorb_t,
			bal_events[0], float(Level0.grain_account.balance), str(not is_instance_valid(fx_node))])
	# 验证吸收表现：结晶碎片必须飞入怀表 HUD，而不是异常消失后仅依赖超时兜底增加余额
	# （历史缺陷曾因检测判定穿透导致无法被吸收、粒子未正确入账）。
	# 精英敌人死在近距离时（≤1500px），断言吸收方式为飞行到达（fly）。
	if kill_dist <= 1500.0 and GrainCrystalFx.last_absorb_kind != "fly":
		_fail("近距离击杀（%dpx）结晶未飞入怀表（吸收方式=%s, t=%.2fs）：碎片半路异常丢失" % [
				int(kill_dist), GrainCrystalFx.last_absorb_kind, GrainCrystalFx.last_absorb_t])
	else:
		print("ELITE DROP PROBE[diag]: 击杀距离 %dpx(>1500 不强求 fly,吸收方式=%s)" % [
				int(kill_dist), GrainCrystalFx.last_absorb_kind])
	if absorb_t >= 0.0 and absorb_t >= 0.28 + 1.6:
		_fail("吸收发生在兜底时限之后(t=%.2fs)" % absorb_t)
	await _wait_phys(60)
	var delta_bal := float(Level0.grain_account.balance) - bal0
	if delta_bal < 290.0:
		_fail("击杀精英敌人后余额未正常增加（增量 %.1f，期望值 ≥ 300 时间粒子）" % delta_bal)

	if _fails.is_empty():
		print("ELITE DROP PROBE: OK(确认击杀 → 结晶特效生成 → 吸收入账 +%.0f 粒子)" % delta_bal)
		tree.quit(0)
	else:
		print("ELITE DROP PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)
