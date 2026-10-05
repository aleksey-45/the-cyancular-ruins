extends Node

# 世界回溯探针(场景级,单机真世界,走**真实按键路径**):
#   Input.action_press("rewind") 模拟按住 Shift → 引擎 _process 的时间场/回放状态机全自然运转。
# 覆盖:录制 · 玩家位置与 HP 倒退 · 普通怪复活(尸体保留) · 精英不倒且不进快照 ·
#       回溯中免疫伤害 · 松开恢复录制。
# 用法:godot --headless --path . res://tests/probe/rewind_probe.tscn

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
	var t_before_rewind: float = rewind.recorded_seconds()
	var frames_before_rewind: int = rewind.frame_count()

	# ④ 按住 Shift 回溯 ~3s(真实按键路径);顺带监听 hp_changed(HUD 血条的唯一刷新通道)
	var hp_events := [0]
	player.hp_changed.connect(func(_cur: int, _mx: int) -> void: hp_events[0] += 1)
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
	if hp_events[0] <= 0:
		_fail("回溯未向 HUD 发血量通知(hp_changed 未触发 → 血条不会刷新)")
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

	# ⑦ 录像带模型(D3):磁带钟退回到回溯出口,被复写的帧被裁掉。
	#    旧实现的磁带钟只增不减,"被抹掉的未来"留在带上,第二次回溯会先倒放它。
	var t_after_rewind: float = rewind.recorded_seconds()
	if t_after_rewind > t_before_rewind - 1.0:
		_fail("磁带钟未随回溯回退(%.2f → %.2f)" % [t_before_rewind, t_after_rewind])
	if rewind.frame_count() >= frames_before_rewind:
		_fail("磁带未裁掉被复写的帧(%d → %d)" % [frames_before_rewind, rewind.frame_count()])

	# ⑧ 二次回溯:短录一段再倒回去——磁带钟不得爬回旧刻度(两次回溯互不串带)
	(player as Node2D).global_position += Vector2(150, 0)
	for i in 60:
		await tree.physics_frame
	var t_peak: float = rewind.recorded_seconds()
	Input.action_press("rewind")
	for i in 120:
		await tree.physics_frame
	Input.action_release("rewind")
	for i in 10:
		await tree.physics_frame
	if rewind.recorded_seconds() >= t_peak:
		_fail("二次回溯后磁带钟未回退(%.2f ≥ %.2f,回溯在倒放旧带)" % [t_peak, rewind.recorded_seconds()])

	# ⑩ **完成度**:回溯里每一次 `step()` 都必须让 `_apply` **与 `_apply_bullets`** 都走到底
	#    (2026-10-05 修复轮 1 来源 = 评审 C-1;修复轮 2 来源 = 评审 **N-1**)。
	#    ★ 为什么要有这一条:①-⑨ 全是**玩家域**的断言,而"这一帧的回放有没有被中止"没有任何断言问过 ——
	#    本包首版把 `d["n"] as EnemyBase` 放在了 `is_instance_valid()` **之前**,真 freed 实例上
	#    `as` 抛 `Trying to cast a freed object.` 并**中止整个 `_apply`**(同帧 `_apply_bullets()` 整段被跳过:
	#    回放弹不重建/不摆位/引信不回写,`Level0._rewind_elite_hits()` 拿到的是陈旧位置)。
	#    这个病在本支探针里**每跑 30+ 次**(实测区间 **32~37**:round-1 全批 32、其余 33/34/35/36/37 都出现过)、而判词照样打 `OK` —— 见下面那条 `freed 引用` 观测行。
	#    ★ 判据口径(★ 评审订正过:**不许**写成 `invalid_ref_count() == 0`):带子上留着 freed 实体是
	#    **改动前就存在**的条件(精英不保留尸体 + 死前帧留在 40s 带上),旧码靠 `and` 短路静默跳过 ⇒
	#    断言"必须为 0"会**永久红**(恒红的守卫与恒绿的守卫一样没用)。故断言**完成度**:
	#      `_apply` 走到底的次数 == `step()` 应当走完的次数(中止 ⇒ 分子短一截)。
	#    ★★ **两条分子是两件事,别读成一条**(修复轮 2 / 评审 N-1 实测):GDScript 的脚本错误只中止
	#    "出错的那个函数"、**调用方继续** ⇒ `_apply_bullets()` 体内中止时,`_apply()` 仍会走到末尾 +1。
	#    所以下面**必须**分两条断言:`_apply` 那条管 `_apply()` 自己的函数体;`_apply_bullets` 那条管子弹段。
	#    (N-1 的存在证明见报告:把 `_apply_bullets` 末尾那次递增删掉 ⇒ **第二**条红、第一条仍绿。)
	var started := rewind.apply_started_count()
	var done := rewind.apply_completed_count()
	var bullets_done := rewind.apply_bullets_completed_count()
	print("[rewind] 完成度: _apply %d/%d 走完、_apply_bullets %d/%d 走完;带子上 freed 引用 %d 个(观测量,不是断言)"
			% [done, started, bullets_done, started, rewind.invalid_ref_count()])
	# ★★ 判据**只有一处**:住在产品侧 `WorldRewind.replay_completion_error()`(它旁边就是计数器)。
	#    探针不再自己拼判据 —— 三支各抄一份**一轮内就漂移过**(评审 N-2:上一轮 Minor ⑤ 的"分子 > 分母"
	#    分档只落到了 1/3 支)。为什么必须搬到产品侧而不是抽个共用助手:见该函数的注释(a/b/c 三条)。
	#    ★ 这里保留上面那行 `print` 只是**观测行**;判词一律来自产品侧那一句。
	var comp_err := rewind.replay_completion_error()
	if comp_err != "":
		_fail(comp_err)

	# ⑨ 生产端契约:`WorldRewind._snapshot_player()` 产出的**武器快照逐字段 == 真值**,且
	#    **不许静默退化**。快照字典由这个函数产出,它此前用字符串反射读武器域 —— 成员名对不上
	#    时 `get` **静默返回 null** ⇒ 那次真事故里那一帧的玩家快照整体退化成**空字典**
	#    (2026-10-04 实测 `snap.size()=0 keys=[]`),而**任何断言都不会红**:引擎只在 stderr
	#    每帧报 "Nonexistent 'int' constructor"(同一跑 83 行)。事故原文与实测订正写在
	#    `core/sim/world_rewind.gd` 那段的注释里。
	#    ★ 放在**最后一步**:不扰动 ①-⑧ 的世界(本段会真装上两把枪)。
	#    ★ 开局空手时 `_current_type`=0 / `_current_index`=-1 都是**真值** ⇒ 不装枪的话
	#      "静默退化"与"真的空手"不可分,这一条就没有牙。
	var wc: WeaponComponent = player.get("weapons")
	if wc == null:
		_fail("玩家根上没有 weapons 组件(改名/被删?)—— 生产端契约无从验证")
	else:
		wc.set_initial_inventory([1, 2])
		for i in 6:
			await tree.physics_frame
		var held: Array = wc.inventory.held
		var live_w: WeaponBase = wc.current_weapon()
		if held.size() != 2 or live_w == null:
			_fail("生产端契约前置不成立(背包 %d 格 / current_weapon=%s)"
					% [held.size(), str(live_w)])
		else:
			# 三个互不相同的非 0 值:格 0=5、格 1=7、手持实弹=9 ⇒ 任一处读空/读 0 必被看出来。
			held[0]["mag"] = 5
			held[1]["mag"] = 7
			live_w.mag_ammo = 9
			var snap: Dictionary = rewind._snapshot_player(player)
			var d_wslot := int(snap.get("wslot", -99))
			var d_widx := int(snap.get("widx", -99))
			var d_wlive := int(snap.get("wlive", -99))
			var d_wmags: Array = snap.get("wmags", [])
			if d_wslot != wc._current_type or d_wslot == 0:
				_fail("生产端 wslot=%d 应等于真值 %d 且非 0(=0 即静默 null 那次事故的形态)"
						% [d_wslot, wc._current_type])
			if d_widx != wc._current_index:
				_fail("生产端 widx=%d 应等于真值 %d" % [d_widx, wc._current_index])
			if d_wlive != live_w.mag_ammo:
				_fail("生产端 wlive=%d 应等于真值 %d" % [d_wlive, live_w.mag_ammo])
			if d_wmags.size() != held.size():
				_fail("生产端 wmags 格数 %d 应等于真值 %d" % [d_wmags.size(), held.size()])
			else:
				for i in mini(held.size(), d_wmags.size()):
					if int(d_wmags[i]) != int(held[i]["mag"]):
						_fail("生产端 wmags[%d]=%d 应等于真值 %d"
								% [i, int(d_wmags[i]), int(held[i]["mag"])])

	if _fails.is_empty():
		print("REWIND PROBE: OK(录制/位置+HP倒退/怪复活/精英不倒/回溯免疫/松开恢复/磁带钟回退/二次回溯不串带/生产端快照逐字段==真值)")
		tree.quit(0)
	else:
		print("REWIND PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)
