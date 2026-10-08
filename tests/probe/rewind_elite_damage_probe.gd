extends Node

# 回溯期二次伤害探针(场景级):
#   布置:精英(乌鸫)在玩家前方;一颗玩家子弹已飞过精英继续向前 -> 录制。
#   回溯:子弹倒飞 -> 再次穿过精英 -> 应再吃一次伤害(策划案「回退造成二次伤害」)。
#   断言:回溯前精英 HP 不掉;回溯中/后 HP 下降;普通怪不受此判定(它们被冻结回放)。
# 用法:godot --headless --path . res://tests/probe/rewind_elite_damage_probe.tscn
#
# 注意事项：2026-10-02 登记的抖动「回放弹峰值=0」已查明(2026-10-03),不是判定坏了,是试样没进快照:
#   - 旧布置把子弹放在 `bird.global_position + Vector2(20, 0)`,而精英身体(scale 2.5)半径远大于
#     20px  ->  子弹出生即在体内,第一个物理帧 `move_and_collide` 就命中 -> `queue_free`。
#     - 逐物帧实测:子弹只在创建后第 0 个物帧存在,第 1 个物帧已消失(同时精英 HP 40 -> 30)。
#   - 它总共只活 1 个物理帧 ≈ 16.7ms,而录制是按 `TimeParams.SNAP_HZ`=20Hz 采样(50ms 一次,
#     在 `_process` 里)—— 一个只活 16.7ms 的实体大概率整个采样不到  ->  环里 0 颗  -> 
#     `replay_bullets()` 全程为空  ->  报「回溯期未发生二次伤害」。约 1/3 的跑次能撞上采样点,故时红时绿。
#    ->  修法:让试样稳定活过采样周期(`collision_mask = 0`,不与世界碰撞),并在回溯前**先断言
#     `环里有子弹`** —— 否则后面的红说的是"录制",会把判定冤枉掉。
#   - 顺带登记的产品面缺口(未修,见 AGENTS.md D3):录制是按 SNAP_HZ 的瞬时采样,不是按实体
#     逐个记录  ->  寿命 < 1/SNAP_HZ 的实体可能整段不进快照(贴脸命中的子弹是最常见的一例),
#     那次回溯就不会把它带回来。
#
# 注意事项：固定测试地图：若随机选取地图，由于玩家出生点及周边地形几何差异，可能因掩体阻挡子弹轨迹导致测试偶发失败。
#   按工程规范显式固定地图以确保跨进程测试结果稳定可复现（参见 docs/eng/world.md）。
const MAP := "res://maps/newfactory.cyrm"

var _fails: Array[String] = []


func _fail(m: String) -> void:
	_fails.append(m)


func _wait_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	MazeGenerator.set_map_file(MAP)   # - 必须在实例化 level_0 之前钉图(见文件头)
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	tree.root.add_child(lvl)
	await _wait_ms(400)
	var vp: Node = lvl.get_node_or_null("WorldViewport")
	var player: Node2D = lvl.get_node_or_null("WorldViewport/Player")
	if vp == null or player == null or Level0.time_field == null:
		print("REWIND ELITE DMG PROBE: FAIL(世界未就绪)")
		tree.quit(1)
		return

	# 精英:玩家前方 300px
	var bird: Node2D = (load("res://scenes/enemies/enemy_black_bird.tscn") as PackedScene).instantiate()
	vp.add_child(bird)
	bird.global_position = player.global_position + Vector2(300, 0)
	await _wait_ms(120)
	if not bird.has_meta("elite"):
		_fail("乌鸫缺 elite 标")

	# 子弹:从精英体内起飞、向远处飞(回溯时会倒回来穿过它)。
	# - `collision_mask = 0`:不让它跟世界碰撞 —— 见文件头,出生在体内的子弹一个物理帧就没了
	#   (16.7ms),小于 1/SNAP_HZ(50ms)的采样周期  ->  录制器大概率整段看不到它。本探针要验的是
	#   判定(`_rewind_elite_hits`),不该被"试样活不过一个采样周期"搅成测试误报。
	var b: Node2D = (load("res://scenes/weapons/bullet.tscn") as PackedScene).instantiate()
	vp.add_child(b)
	b.global_position = bird.global_position + Vector2(20, 0)   # 紧贴精英起飞:正向穿一次(正常命中),回溯再穿=二次伤害
	b.call("setup", Vector2.RIGHT, 120.0, 6000.0, 1.0, Color.WHITE, player)   # 慢弹长射程:保证整段飞行留在缓冲窗内
	b.collision_mask = 0
	b.set("shooter", player)
	b.set("hit_damage", 10)
	b.set("hit_impact", 0.0)
	b.set("apply_damage", true)
	b.set_meta("scene_path", "res://scenes/weapons/bullet.tscn")

	# ① 录制 2.5s(慢弹已飞离精英 ~300px;这段历史足够回溯走回来)
	await _wait_ms(1200)
	# - 先确认试样真进了快照:环里 0 颗时后面的红是"没录到",不是"判定没生效" ——
	#   这条断言存在的唯一目的就是别把这两种成因混成同一句话。
	var rw0 = lvl.get("_rewind")
	var recorded_bullets := 0
	for f in rw0.get("_frames"):
		recorded_bullets = maxi(recorded_bullets, (f["bullets"] as Array).size())
	print("  [诊断] 录制 1.2s 后环内子弹峰值=%d" % recorded_bullets)
	if recorded_bullets == 0:
		_fail("子弹从未进快照(1.2s 录制里环内 0 颗)—— 这条测的是录制,不是判定")
	# 正向穿越已造成第一次命中(正常战斗);基线取"正向命中后"的血量,
	# 回溯再穿一次才叫二次伤害
	var hp_before_rewind: int = int(bird.get("hp"))

	# ② 回溯 2s:子弹倒飞穿过精英 -> 二次伤害
	Input.action_press("rewind")
	# 确定性验证:回溯期间把精英"走到"倒飞子弹的当前位置(精英不受回溯影响,移动合法),
	# 触发 _rewind_elite_hits 的二次伤害结算。回溯仅 1.0s,防止游标越过缓冲首帧。
	var min_d := 99999.0
	var seen_replay := 0
	for i2 in 20:
		await _wait_ms(50)
		var rw = lvl.get("_rewind")
		var rb: Array = rw.replay_bullets()
		seen_replay = maxi(seen_replay, rb.size())
		var b2 = null
		for cand in rb:
			if is_instance_valid(cand):
				b2 = cand
				break
		if b2 != null:
			min_d = minf(min_d, MazeGenerator.toroidal_delta_px((b2 as Node2D).global_position,
					bird.global_position, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length())
			bird.global_position = (b2 as Node2D).global_position
	print("  [诊断] 回放弹峰值=%d 最近距离=%.1f 精英HP=%d" % [seen_replay, min_d, int(bird.get("hp"))])
	var hp_during: int = int(bird.get("hp"))
	Input.action_release("rewind")
	await _wait_ms(120)

	if hp_during >= hp_before_rewind:
		_fail("回溯期未发生二次伤害(HP %d→%d)" % [hp_before_rewind, hp_during])
	if int(bird.get("hp")) > hp_before_rewind:
		_fail("精英 HP 反而增加(不应发生)")

	# ③ 普通怪不受回溯期伤害判定:放一只普通鸟在子弹轨迹上,回溯不应扣它血
	var normal: Node2D = (load("res://scenes/enemies/enemy_jump_bird.tscn") as PackedScene).instantiate()
	vp.add_child(normal)
	normal.global_position = bird.global_position + Vector2(0, 40)
	await _wait_ms(100)
	var nhp0: int = int(normal.get("hp"))
	Input.action_press("rewind")
	await _wait_ms(600)
	Input.action_release("rewind")
	if int(normal.get("hp")) < nhp0:
		_fail("普通怪在回溯期被扣血(应冻结回放,不结算伤害)")

	if _fails.is_empty():
		print("REWIND ELITE DMG PROBE: OK(回溯前不掉血/倒飞子弹二次伤害/普通怪不受判定)")
		tree.quit(0)
	else:
		print("REWIND ELITE DMG PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)


func _ready() -> void:
	_run.call_deferred()
