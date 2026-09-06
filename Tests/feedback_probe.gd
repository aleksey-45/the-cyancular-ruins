extends Node

# 打击反馈层探针(KH-hit-feedback,场景模式):headless 验证 CombatFeedback 的
#   1) 击杀播报(文本设置 + 浮现动画)  2) 命中 X 标记显隐  3) 击杀归因
#   (玩家 last_damager meta 才播报;环境死/无实例时安静空转,不崩不误报)
# 跑法: Godot_console --headless --path . res://Tests/feedback_probe.tscn

func _ready() -> void:
	var failures: Array[String] = []
	var CF: GDScript = load("res://Scenes/Effects/combat_feedback.gd")
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
	if fx._kill_label.text != "击杀 测试鸟":
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
	return v

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("FEEDBACK PROBE: ALL-OK(击杀播报/X 标记/归因/音效 全部通过)")
		get_tree().quit(0)
	else:
		print("FEEDBACK PROBE: FAIL | " + "; ".join(failures))
		get_tree().quit(1)
