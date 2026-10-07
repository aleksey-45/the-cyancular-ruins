extends Node

# 回溯引信探针(B17):引信/射程状态必须进快照,并在重建时还原。
#
# - 用户 2026-09-27 报"回溯之后被之前击发的榴弹炮炸死":根因是快照没记引信,重建出来的
#   榴弹退回"未点燃" -> ① 它会在错误的时刻爆炸(不再是它所属那个世界状态的那颗引信);
#   ② 松手那一帧 `_check_player_contact()` 重新生效,只要它跟你重叠就走 0.1s 触碰引信
#   贴脸起爆 —— 于是"回溯救不了命"。
#
# 覆盖:①读写入接口往返 ②回溯中的重建弹带着 fa/fe/fd/traveled ③引信随回溯倒退(不是冻结在
#       按下那一刻)④松手后仍是"已点燃"并从还原值继续计时(不再走触碰引信那条路)。
# 用法:godot --headless --path . res://tests/probe/rewind_fuse_probe.tscn

const GRENADE := "res://scenes/weapons/grenade_bullet.tscn"
const FUSE := 5.0   # 长引信:整个用例期间都不该炸(真炸了说明引信被清掉后又重新起算)

var _fails: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _fail(m: String) -> void:
	_fails.append(m)


func _wait(n: int) -> void:
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
	await _wait(40)
	var rewind: WorldRewind = lvl.get("_rewind")
	var player: Node2D = lvl.get_node_or_null("WorldViewport/Player") as Node2D
	if Level0.time_field == null or rewind == null or player == null:
		print("REWIND FUSE PROBE: FAIL(单机时间系统/玩家未就绪)")
		tree.quit(1)
		return
	var world: Node = lvl.get_node("WorldViewport")

	# ── ① 读写入接口往返(纯数据;不加入场景树的实例只当数据容器)──
	var dummy: Node = (load(GRENADE) as PackedScene).instantiate()
	dummy.call("_start_fuse", 0.4)
	dummy.set("_fuse_elapsed", 0.25)
	dummy.set("traveled", 123.0)
	# 模拟"开火时由武器注入"的那几个值,再存快照
	dummy.set("max_range", 777.0)
	dummy.set("gravity_factor", 2.5)
	var st: Dictionary = dummy.call("rewind_state")
	dummy.call("apply_rewind_state", {"fa": false, "fe": 0.0, "fd": 0.0, "tr": 0.0, "mr": 0.0, "gf": 0.0})
	dummy.call("apply_rewind_state", st)
	if not st.has("mr") or not st.has("gf"):
		_fail("快照字典缺开火时注入的字段(mr/gf):重建弹会带着场景默认值")
	elif absf(float(dummy.get("max_range")) - 777.0) > 1e-3 or absf(float(dummy.get("gravity_factor")) - 2.5) > 1e-3:
		_fail("max_range/gravity_factor 往返失败(%.1f / %.2f)" % [float(dummy.get("max_range")), float(dummy.get("gravity_factor"))])
	if not bool(dummy.get("_fuse_active")) or absf(float(dummy.get("_fuse_elapsed")) - 0.25) > 1e-4 \
			or absf(float(dummy.get("_fuse_duration")) - 0.4) > 1e-4 \
			or absf(float(dummy.get("traveled")) - 123.0) > 1e-4:
		_fail("引信/射程读写口往返丢字段(active=%s fe=%.3f fd=%.3f tr=%.1f)" % [
				str(dummy.get("_fuse_active")), float(dummy.get("_fuse_elapsed")),
				float(dummy.get("_fuse_duration")), float(dummy.get("traveled"))])
	dummy.free()

	# ── 部署一颗真榴弹:就放在玩家身边(= 用户踩到的那个位置),水平慢飘,长引信已点燃 ──
	var g: Node2D = (load(GRENADE) as PackedScene).instantiate()
	# - 必须补 scene_path:它是武器出弹时(weapon_base.fire)打的标记,回溯重建靠它
	#   instantiate 出节点。手工放的弹少了这条 meta 就建不出来(表现为"回溯里没有重放弹")。
	g.set_meta("scene_path", GRENADE)
	world.add_child(g)
	g.global_position = player.global_position + Vector2(-110.0, -70.0)
	g.set("gravity_factor", 0.0)          # 不落地方向可预判
	g.set("velocity_vec", Vector2(120.0, 0.0))
	g.set("max_range", 100000.0)          # 别让它因为"超射程"提前炸
	g.call("_start_fuse", FUSE)
	await _wait(60)                       # ~1s:引信走到 ~1.0s,射程累计 ~120px
	if not bool(g.get("_fuse_active")):
		_fail("前置失败:榴弹引信没点燃")
	var fe_live := float(g.get("_fuse_elapsed"))
	var tr_live := float(g.get("traveled"))
	if fe_live < 0.8:
		_fail("前置失败:引信走得不对(%.2fs)" % fe_live)

	# ── ②③ 回溯 ~0.6s:重建弹必须带着引信,且引信随回溯倒退 ──
	Input.action_press("rewind")
	await _wait(12)
	var rb: Node2D = null
	for b in rewind.replay_bullets():
		if is_instance_valid(b) and bool(b.get("explodes")):
			rb = b
			break
	if rb == null:
		_fail("回溯里没有重放中的榴弹(快照子弹表为空?)")
	else:
		if not bool(rb.get("_fuse_active")):
			_fail("回溯重建的榴弹退回「未点燃」—— 引信没进快照(修前就是这个症状)")
		if absf(float(rb.get("_fuse_duration")) - FUSE) > 1e-4:
			_fail("回溯重建的榴弹引信时长不对(%.3f 应为 %.3f)" % [float(rb.get("_fuse_duration")), FUSE])
		var fe_re := float(rb.get("_fuse_elapsed"))
		if fe_re <= 0.0:
			_fail("回溯重建的榴弹引信剩余量没还原(%.3f)" % fe_re)
		elif fe_re >= fe_live - 0.02:
			_fail("引信没有随回溯倒退(回溯中 %.3f 应 < 按下时 %.3f)" % [fe_re, fe_live])
		var tr_re := float(rb.get("traveled"))
		if tr_re >= tr_live - 1.0:
			_fail("射程累计没有随回溯倒退(回溯中 %.1f 应 < 按下时 %.1f)" % [tr_re, tr_live])
		# - 第二条真凶:max_range 也是"开火时注入"的,不还原  ->  重建弹 max_range=场景默认 0
		#    ->  一松手就 `traveled >= max_range` 当场爆炸(正好炸在回溯落点)。
		if absf(float(rb.get("max_range")) - 100000.0) > 1.0:
			_fail("重建弹的 max_range 没还原(%.1f,应为 100000)= 一松手就会超射程爆炸" % float(rb.get("max_range")))
		if absf(float(rb.get("gravity_factor")) - 0.0) > 1e-4:
			_fail("重建弹的 gravity_factor 没还原(%.2f 应为 0)" % float(rb.get("gravity_factor")))
		print("REWIND FUSE PROBE[diag]: 按下时 fe=%.3f tr=%.1f → 回溯中 fe=%.3f tr=%.1f" % [
				fe_live, tr_live, fe_re, tr_re])

	Input.action_release("rewind")
	await _wait(3)

	# ── ④ 松手后:仍是"已点燃",且从还原值继续计时(不再走触碰引信贴脸起爆那条路)──
	if not is_instance_valid(rb):
		_fail("松手后重建弹就没了(应当留在场上继续飞)")
	else:
		if not bool(rb.get("_fuse_active")):
			_fail("松手后榴弹又变回「未点燃」")
		var after := float(rb.get("_fuse_elapsed"))
		await _wait(12)
		if is_instance_valid(rb):
			var later := float(rb.get("_fuse_elapsed"))
			if later <= after:
				_fail("松手后引信没有继续走(%.3f → %.3f)" % [after, later])
		else:
			_fail("松手后榴弹被销毁(引信 %.3f 秒时不该炸)" % after)

	if _fails.is_empty():
		print("REWIND FUSE PROBE: OK(读写口往返/回溯重建带引信/引信随回溯倒退/松手后继续计时)")
		tree.quit(0)
	else:
		print("REWIND FUSE PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)
