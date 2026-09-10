extends Node

# 打击反馈层探针(KH-hit-feedback,场景模式):headless 验证 CombatFeedback 的
#   1) 击杀播报(文本设置 + 浮现动画)  2) 命中 X 标记显隐  3) 击杀归因
#   (玩家 last_damager meta 才播报;环境死/无实例时安静空转,不崩不误报)
# 跑法: Godot_console --headless --path . res://tests/feedback_probe.tscn

func _ready() -> void:
	var failures: Array[String] = []
	var CF: GDScript = load("res://scenes/effects/combat_feedback.gd")
	# 无实例(主菜单/服务器进程):静态入口必须全部空转
	CF.kill("无人")
	CF.hit_marker()
	CF.notify_enemy_killed(_victim_killed_by(null))
	await get_tree().process_frame
	if CombatFeedback.current != null:
		failures.append("未挂载实例时 current 应为 null")
	# 挂载实例(与 Level0/pvp_client/royale_game 同款 spawn)
	CF.spawn(self)
	await get_tree().process_frame
	await get_tree().process_frame   # spawn 是 call_deferred,多等一帧
	var fx: CanvasLayer = CombatFeedback.current
	if fx == null:
		failures.append("spawn 后 current 未注册")
		_finish(failures)
		return
	# 命中 X 标记:调用后可见,生命周期(0.22s)后自动隐藏
	CF.hit_marker()
	await get_tree().process_frame
	if not fx._marker.visible:
		failures.append("hit_marker 后 X 标记不可见")
	await get_tree().create_timer(0.3).timeout
	if fx._marker.visible:
		failures.append("X 标记超过存活时长仍可见")
	# 击杀播报:文本 + 浮现(alpha > 0)
	fx._kill_label.modulate.a = 0.0
	CF.kill("测试鸟")
	# v1.1.1 击杀播报为富文本(青色「击杀」+ 金色人名):断言前剥掉 BBCode 标签再比内容
	var kill_text: String = fx._kill_label.text
	var bbcode_tag := RegEx.new()
	bbcode_tag.compile("\\[[^\\]]*\\]")
	kill_text = bbcode_tag.sub(kill_text, "", true)
	if kill_text != "击杀 测试鸟":
		failures.append("击杀文本错误:「%s」" % fx._kill_label.text)
	await get_tree().process_frame
	await get_tree().process_frame   # process_frame 信号先于节点 _process:多等一帧让动画跑起来
	if fx._kill_label.modulate.a <= 0.0:
		failures.append("击杀文字没有浮现动画")
	await get_tree().create_timer(1.4).timeout
	if fx._kill_label.modulate.a != 0.0:
		failures.append("击杀文字动画结束后未归零")
	# 击杀音效流存在(程序合成,Sfx 静态)
	if Sfx._stream("kill") == null:
		failures.append("Sfx kill 音效流缺失")
	# 归因:玩家击杀 → 播报(scene_file_path 为空回落空名,文本仍以「击杀」开头)
	# 先清空文本:上面 CF.kill("测试鸟") 留下的旧文本会让本条断言假绿(只查前缀,不清便是永真)
	fx._kill_label.text = ""
	var victim := _victim_killed_by(_make_player())
	CF.notify_enemy_killed(victim)
	if not fx._kill_label.text.begins_with("击杀"):
		failures.append("玩家击杀未播报(文本:「%s」)" % fx._kill_label.text)
	# 归因:环境死(无 last_damager meta)→ 文本不变(安静销毁)
	fx._kill_label.text = ""
	CF.notify_enemy_killed(Node2D.new())
	if fx._kill_label.text != "":
		failures.append("环境死误播报(文本:「%s」)" % fx._kill_label.text)
	# 归因:射手不是玩家组 → 不播报
	fx._kill_label.text = ""
	CF.notify_enemy_killed(_victim_killed_by(Node2D.new()))
	if fx._kill_label.text != "":
		failures.append("非玩家击杀误播报(文本:「%s」)" % fx._kill_label.text)
	# 显示名对照表
	if CF.ENEMY_NAMES.get("FlyBird", "") != "飞鸟":
		failures.append("敌人显示名对照表缺失")
	# ── 写入方覆盖(Task 12 闭环):真实 BulletBase._register_player_hit 必须落 last_damager ──
	var bullet_scene: PackedScene = load("res://scenes/weapons/bullet.tscn")
	if bullet_scene == null:
		failures.append("bullet.tscn 载入失败,无法验证写入方")
	else:
		var shooter := _make_player()
		# 正例:射手 ≠ 目标 → 必须写 meta 且值就是射手
		var b: Node = bullet_scene.instantiate()
		add_child(b)
		b.set("shooter", shooter)
		var victim_ok := _victim_killed_by(null)     # 注意:这个 helper 不设 meta
		b.call("_register_player_hit", victim_ok)
		if not victim_ok.has_meta("last_damager"):
			failures.append("_register_player_hit 未写入 last_damager(写端缺失/写错)")
		elif victim_ok.get_meta("last_damager") != shooter:
			failures.append("last_damager 写的不是射手")
		# 反例:射手 == 目标 → 不得写 meta(自伤不应归因给自己)
		var self_hit := _victim_killed_by(null)
		b.set("shooter", self_hit)
		b.call("_register_player_hit", self_hit)
		if self_hit.has_meta("last_damager"):
			failures.append("射手==目标时不应写 last_damager")
		b.queue_free()
	# ── 端到端归因(Task 15):致命一击必须能播报——走真实 BulletBase._direct_hit 路径 ──
	var enemy_scene: PackedScene = load("res://scenes/enemies/EnemyJumpBird.tscn")
	if enemy_scene == null:
		failures.append("EnemyJumpBird.tscn 载入失败,无法验证端到端归因")
	# 空守卫(Task 16):下面要用 bullet_scene.instantiate(),若它为 null 会抛错中断 _ready() →
	# 探针一行都不打印就挂到 --quit-after 超时(失败串永远看不到)。提前收尾,失败也走正常退出码。
	if enemy_scene == null or bullet_scene == null:
		_finish(failures)
		return
	var shooter2 := _make_player()
	var enemy: Node = enemy_scene.instantiate()
	add_child(enemy)
	enemy.set("hp", 1)                       # 保证一击致死
	var b2: Node = bullet_scene.instantiate()
	add_child(b2)
	b2.set("shooter", shooter2)
	b2.set("direct_hit_damage", 999)
	fx._kill_label.text = ""                 # 清掉前面的播报,便于断言
	b2.call("_direct_hit", enemy)            # ← 这就是真实命中路径(内部 hurt → 同步判死 → 播报)
	if not fx._kill_label.text.begins_with("击杀"):
		failures.append("致命一击未播报击杀(归因 meta 写晚了? 文本:「%s」)" % fx._kill_label.text)
	enemy.queue_free()
	b2.queue_free()
	# ── 端到端归因(爆炸 AoE,Task 16):真实 Explosion.apply_aoe 必须让致命一击能播报 ──
	var enemy3: Node = load("res://scenes/enemies/EnemyJumpBird.tscn").instantiate()
	add_child(enemy3)
	enemy3.set("hp", 1)
	enemy3.global_position = Vector2(400, 0)
	fx._kill_label.text = ""
	var shooter3 := _make_player()
	shooter3.global_position = Vector2(400, 0)     # 与敌人重合,确保在半径内
	Explosion.apply_aoe(enemy3.global_position, 128.0, 999, 0.0, shooter3)
	if not fx._kill_label.text.begins_with("击杀"):
		failures.append("爆炸致命一击未播报击杀(AoE 分支归因未生效? 文本:「%s」)" % fx._kill_label.text)
	enemy3.queue_free()
	shooter3.queue_free()
	# ── 端到端归因(激光,Task 16):走真实 LaserWeaponBase 伤害入口 _apply_beam_damage ──
	# 不 fire():fire 要读鼠标/相机/枪口并做 BeamTrace 几何,真机方向不可控;此处直接进缝2
	# (_apply_beam_damage → _damage_path_targets → _apply_to_enemy),即激光唯一的敌人伤害点,
	# 几何(缝1)不参与本断言 —— 要钉的是「伤害点写没写归因」。
	var laser_scene: PackedScene = load("res://scenes/weapons/laser_gun.tscn")
	if laser_scene == null:
		failures.append("laser_gun.tscn 载入失败,无法验证激光归因")
	if laser_scene == null or enemy_scene == null:
		_finish(failures)
		return
	var shooter4 := _make_player()
	shooter4.global_position = Vector2(0, 0)
	var laser: Node = laser_scene.instantiate()
	add_child(laser)                          # _ready 建好 muzzle/_laser 才能 equip
	laser.call("equip", shooter4)             # 建立射手(player)→ _apply_to_enemy 的归因来源
	var enemy4: Node = enemy_scene.instantiate()
	add_child(enemy4)
	enemy4.set("hp", 1)                       # 保证一击致死(laser_gun damage=6)
	enemy4.global_position = Vector2(400, 0)
	fx._kill_label.text = ""                  # 清掉前面的播报,便于断言
	# 一条横穿敌人身体的折线(缝2 的 pts 语义:世界系折线点集)
	var beam_pts := PackedVector2Array([Vector2(200, 0), Vector2(600, 0)])
	laser.call("_apply_beam_damage", beam_pts, [], PackedVector2Array())
	if not fx._kill_label.text.begins_with("击杀"):
		failures.append("激光致命一击未播报击杀(激光伤害点未写归因 meta? 文本:「%s」)" % fx._kill_label.text)
	laser.queue_free()
	enemy4.queue_free()
	shooter4.queue_free()
	_finish(failures)

func _make_player() -> Node2D:
	var p := Node2D.new()
	add_child(p)
	p.add_to_group("player")
	return p

func _victim_killed_by(killer: Node) -> Node2D:
	var v := Node2D.new()
	add_child(v)
	if killer != null:
		v.set_meta("last_damager", killer)
		v.set_meta("last_damager_time", Time.get_ticks_msec())   # 归因时效戳(Task 15 起为必需)
	return v

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("FEEDBACK PROBE: ALL-OK(击杀播报/X 标记/归因/音效 全部通过)")
		get_tree().quit(0)
	else:
		print("FEEDBACK PROBE: FAIL | " + "; ".join(failures))
		get_tree().quit(1)
