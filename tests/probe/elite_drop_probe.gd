extends Node

# 精英掉落探针(场景级,实际关卡场景,走**真实击杀路径**):打死一只乌鸫 → 结晶 FX 出现 →
# 飞向怀表 → 吸收入账 +300。
#
# - 为什么必须另有一条:B5 的 `tests/probe/grain_crystal_probe.tscn` 是**直接 spawn FX**
#   (只验 FX 自己:散开/飞行/入账/颤抖),证明不了"击杀 → `enemy_base._begin_death` →
#   `EnemyBlackBird._on_death` → `GrainCrystalFx.spawn`"这条**真路径**没被后来的改动碰断。
#   用户报"击杀精英不掉颗粒"时,可疑的正是中间这段而不是 FX 本体。
#
# 判定:入账判据用**余额增量**而不是"有没有 FX 节点" —— 余额会自动回补(50/s),故取
# "增量 ≥ 290" 这一档:真的入了 300 时增量必 ≥300(还叠回补),没入账则只有回补(~3s→150)。
# 用法:godot --headless --path . res://tests/probe/elite_drop_probe.tscn

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
	# - 当场记击杀距离:精英死后 ~0.5s 就被释放(不入尸体保留),晚读 = use-after-free
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
	# 逐帧盯到吸收那一刻:报告"吸收入账"发生在第几秒、以及是不是保底处理那条路(HAS_ABSORB_TIMEOUT)
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
	# 这条是**可视**承诺:碎片要真的飞进怀表,而不是半路消失、只靠保底处理把钱写入来
	# (2026-09-26 的 bug 正是"永远飞不进 → 保底处理也没写 → 击杀精英颗粒根本不涨")。
	# - 只对**屏幕附近的击杀**断言 fly:精英死在离玩家很远的地方时(150×100 大图上完全可能),
	#   碎片要飞的距离本来就可能超过保底处理时限 —— 那时"入账"由保底处理保证,fly 无从谈起。
	if kill_dist <= 1500.0 and GrainCrystalFx.last_absorb_kind != "fly":
		_fail("屏幕附近的击杀(%dpx)没飞到怀表(吸收方式=%s,t=%.2fs):碎片半路消失" % [
				int(kill_dist), GrainCrystalFx.last_absorb_kind, GrainCrystalFx.last_absorb_t])
	else:
		print("ELITE DROP PROBE[diag]: 击杀距离 %dpx(>1500 不强求 fly,吸收方式=%s)" % [
				int(kill_dist), GrainCrystalFx.last_absorb_kind])
	if absorb_t >= 0.0 and absorb_t >= 0.28 + 1.6:
		_fail("吸收发生在兜底时限之后(t=%.2fs)" % absorb_t)
	await _wait_phys(60)
	var delta_bal := float(Level0.grain_account.balance) - bal0
	if delta_bal < 290.0:
		_fail("击杀精英后余额没涨(增量 %.1f,期望 ≥300 颗粒;只涨回补说明没入账)" % delta_bal)

	if _fails.is_empty():
		print("ELITE DROP PROBE: OK(真击杀 → 结晶 FX 出现 → 吸收入账 +%.0f 颗粒)" % delta_bal)
		tree.quit(0)
	else:
		print("ELITE DROP PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)
