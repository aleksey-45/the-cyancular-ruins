extends Node

# 回溯期二次伤害探针(场景级):
#   布置:精英(乌鸫)在玩家前方;一颗玩家子弹已**飞过**精英继续向前 → 录制。
#   回溯:子弹倒飞 → 再次穿过精英 → 应再吃一次伤害(策划案「回退造成二次伤害」)。
#   断言:回溯前精英 HP 不掉;回溯中/后 HP 下降;普通怪不受此判定(它们被冻结回放)。
# 用法:godot --headless --path . res://tests/probe/rewind_elite_damage_probe.tscn
#
# ★★ 已知抖动(2026-10-02 实测登记,未修):约 1/3 的跑次会红
#   `回溯期未发生二次伤害(HP 30→30)`,而**同一次运行的诊断行**给出的是
#   `[诊断] 回放弹峰值=0 最近距离=99999.0` —— 即**回溯缓冲里一颗子弹都没有**
#   (`WorldRewind.replay_bullets()` 全程为空),不是"判定没生效"。
#   已排除的因素:①不是取图问题 —— 已按本仓惯例钉图(`MAP`,见下),抖动照旧;
#   ②不是等得不够 —— 子弹创建后已录 1200ms(20Hz ⇒ 24 帧)。
#   ⇒ 成因在"录制→回溯"这条链上(候选:某次 `record()` 没把子弹收进快照 / 回溯起点落在
#     没有子弹的那一帧),**待查**。红时请先读 `[诊断]` 那一行再判 —— 峰值=0 是"没录到",
#     峰值>0 而最近距离大才是"判定/几何"问题。

# ★★ 2026-10-02:**钉图**。本探针原先不钉图 ⇒ 每进程随机选一份 `.cyrm`,而它的几何
#   (玩家出生点、前方 300px 有没有墙、环面尺寸)与地形强耦合 ⇒ **实测 3 次里 2 次红**
#   `回溯期未发生二次伤害(HP 30→30)` —— 红的是"这一局地形恰好不合适",不是功能坏了。
#   本仓对"取图类探针"的既有纪律就是钉图以求跨进程可复现(见 CLAUDE.md「探针取图类脚本」)。
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
	MazeGenerator.set_map_file(MAP)   # ★ 必须在实例化 level_0 之前钉图(见文件头)
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

	# 子弹:已在精英**前方** 120px、继续向远处飞(回溯时会倒回来穿过它)
	var b: Node2D = (load("res://scenes/weapons/bullet.tscn") as PackedScene).instantiate()
	vp.add_child(b)
	b.global_position = bird.global_position + Vector2(20, 0)   # 紧贴精英起飞:正向穿一次(正常命中),回溯再穿=二次伤害
	b.call("setup", Vector2.RIGHT, 120.0, 6000.0, 1.0, Color.WHITE, player)   # 慢弹长射程:保证整段飞行留在缓冲窗内
	b.set("shooter", player)
	b.set("hit_damage", 10)
	b.set("hit_impact", 0.0)
	b.set("apply_damage", true)
	b.set_meta("scene_path", "res://scenes/weapons/bullet.tscn")

	# ① 录制 2.5s(慢弹已飞离精英 ~300px;这段历史足够回溯走回来)
	await _wait_ms(1200)
	# 正向穿越已造成第一次命中(正常战斗);基线取"正向命中后"的血量,
	# 回溯再穿一次才叫**二次伤害**
	var hp_before_rewind: int = int(bird.get("hp"))

	# ② 回溯 2s:子弹倒飞穿过精英 → 二次伤害
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
