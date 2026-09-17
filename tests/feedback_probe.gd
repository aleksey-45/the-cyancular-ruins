extends Node

# 打击反馈层探针(KH-hit-feedback,场景模式):headless 验证 CombatFeedback 的
#   1) 击杀播报(PvP 侧入口 kill():文本设置 + 浮现动画)  2) 命中 X 标记显隐
#   3) 归因写端(attribute/attribute_hit:只服务大乱斗计分)
#   ★ 2026-09-17 起单机的「敌人死 → 播报」那条链已删(notify_enemy_killed/enemy_display_name
#     与 EnemySpawner.display_name_of 一起),故本探针改为断言"敌人命中只出 X 标记、身上不留
#     归因 meta"。
# 跑法: Godot_console --headless --path . --quit-after 600 res://tests/feedback_probe.tscn
#   (--quit-after 兜底:脚本若解析失败则场景无脚本、一行不打印就会挂死到超时;与兄弟探针一致)


# hoisted from locals when __ready was split (first assignment stays where it was).
var _failures: Array[String] = []
var _CF: GDScript = null
var _fx: CanvasLayer = null
var bullet_scene: PackedScene = null
var enemy_scene: PackedScene = null
var _aborted: bool = false
func _ready() -> void:
	# * each segment is followed by an _aborted check: the in-segment `_finish(...)` +
	#   `return` used to exit the WHOLE function; after the split it only exits that segment,
	#   so without this guard the later segments would run with an uninitialized _fx.
	await _mount_feedback()
	if _aborted:
		return
	await _check_marker_and_banner()
	if _aborted:
		return
	_check_e2e_direct_hit()
	if _aborted:
		return
	_check_e2e_explosion_aoe()
	if _aborted:
		return
	_check_e2e_laser()
	if _aborted:
		return
	await _check_scene_change_idempotent()
	if _aborted:
		return
	_check_attribute_entry()
	if _aborted:
		return
	_finish(_failures)

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
	_aborted = true   # 见 _ready 顶部:置位后各段之间就不再往下跑
	if failures.is_empty():
		print("FEEDBACK PROBE: ALL-OK(击杀播报/X 标记/归因/音效 全部通过)")
		get_tree().quit(0)
	else:
		print("FEEDBACK PROBE: FAIL | " + "; ".join(failures))
		get_tree().quit(1)


func _mount_feedback() -> void:
	_failures = []
	_CF = load("res://ui/combat_feedback.gd")
	# 无实例(主菜单/服务器进程):静态入口必须全部空转
	_CF.kill("无人")
	_CF.hit_marker()
	await get_tree().process_frame
	if CombatFeedback.current != null:
		_failures.append("未挂载实例时 current 应为 null")
	# 挂载实例(与 Level0/pvp_client/royale_game 同款 spawn)
	_CF.spawn(self)
	await get_tree().process_frame
	await get_tree().process_frame   # spawn 是 call_deferred,多等一帧
	_fx = CombatFeedback.current
	if _fx == null:
		_failures.append("spawn 后 current 未注册")
		_finish(_failures)
		return

func _check_marker_and_banner() -> void:
	# 命中 X 标记:调用后可见,生命周期(0.22s)后自动隐藏
	_CF.hit_marker()
	await get_tree().process_frame
	if not _fx._marker.visible:
		_failures.append("hit_marker 后 X 标记不可见")
	await get_tree().create_timer(0.3).timeout
	if _fx._marker.visible:
		_failures.append("X 标记超过存活时长仍可见")
	# 击杀播报:文本 + 浮现(alpha > 0)
	_fx._kill_label.modulate.a = 0.0
	_CF.kill("测试鸟")
	# v1.1.1 击杀播报为富文本(青色「击杀」+ 金色人名):断言前剥掉 BBCode 标签再比内容
	var kill_text: String = _fx._kill_label.text
	var bbcode_tag := RegEx.new()
	bbcode_tag.compile("\\[[^\\]]*\\]")
	kill_text = bbcode_tag.sub(kill_text, "", true)
	if kill_text != "击杀 测试鸟":
		_failures.append("击杀文本错误:「%s」" % _fx._kill_label.text)
	await get_tree().process_frame
	await get_tree().process_frame   # process_frame 信号先于节点 _process:多等一帧让动画跑起来
	if _fx._kill_label.modulate.a <= 0.0:
		_failures.append("击杀文字没有浮现动画")
	await get_tree().create_timer(1.4).timeout
	if _fx._kill_label.modulate.a != 0.0:
		_failures.append("击杀文字动画结束后未归零")
	# 击杀音效流存在(程序合成,Sfx 静态)
	if Sfx._stream("kill") == null:
		_failures.append("Sfx kill 音效流缺失")

func _check_e2e_direct_hit() -> void:
	# ── 端到端:致命一击走真实 BulletBase._direct_hit 路径 ──
	# ★ 2026-09-17 起单机击杀播报已删,判据从"播报了击杀"改成"出了命中标记 + 敌人身上
	#   **没有**归因 meta"(last_damager 是播报的产物,随播报一起消失)。
	enemy_scene = load("res://scenes/enemies/enemy_jump_bird.tscn")
	if enemy_scene == null:
		_failures.append("enemy_jump_bird.tscn 载入失败,无法验证端到端命中")
	# ★ bullet_scene 原先由 _check_writer_register_player_hit 载入(该函数已删),搬到这里。
	bullet_scene = load("res://scenes/weapons/bullet.tscn")
	if bullet_scene == null:
		_failures.append("bullet.tscn 载入失败,无法验证端到端命中")
	# 空守卫:下面要用 bullet_scene.instantiate(),若它为 null 会抛错中断 _ready() →
	# 探针一行都不打印就挂到 --quit-after 超时(失败串永远看不到)。提前收尾,失败也走正常退出码。
	if enemy_scene == null or bullet_scene == null:
		_finish(_failures)
		return
	var shooter2 := _make_player()
	var enemy: Node = enemy_scene.instantiate()
	add_child(enemy)
	enemy.set("hp", 1)                       # 保证一击致死
	var b2: Node = bullet_scene.instantiate()
	add_child(b2)
	b2.set("shooter", shooter2)
	b2.set("direct_hit_damage", 999)
	_fx._hit_age = -1.0                       # 清掉上一次的 X 标记,便于断言
	b2.call("_direct_hit", enemy)            # ← 真实命中路径(内部 hit_marker → hurt 同步判死)
	if _fx._hit_age < 0.0:
		_failures.append("致命一击未出命中标记(_direct_hit 的反馈路径断了)")
	if enemy.has_meta("last_damager"):
		_failures.append("敌人身上不该再有 last_damager meta(单机播报的产物,已随播报删除)")
	enemy.queue_free()
	b2.queue_free()

func _check_e2e_explosion_aoe() -> void:
	# ── 端到端:真实 Explosion.apply_aoe 命中敌人时出命中标记(判据见 _check_e2e_direct_hit)──
	var enemy3: Node = load("res://scenes/enemies/enemy_jump_bird.tscn").instantiate()
	add_child(enemy3)
	enemy3.set("hp", 1)
	enemy3.global_position = Vector2(400, 0)
	_fx._hit_age = -1.0
	var shooter3 := _make_player()
	shooter3.global_position = Vector2(400, 0)     # 与敌人重合,确保在半径内
	Explosion.apply_aoe(enemy3.global_position, 128.0, 999, 0.0, shooter3)
	if _fx._hit_age < 0.0:
		_failures.append("爆炸命中敌人未出命中标记(AoE 敌人分支的反馈路径断了)")
	if enemy3.has_meta("last_damager"):
		_failures.append("敌人身上不该再有 last_damager meta(单机播报的产物,已随播报删除)")
	enemy3.queue_free()
	shooter3.queue_free()

func _check_e2e_laser() -> void:
	# ── 端到端归因(激光,Task 16):走真实 LaserWeaponBase 伤害入口 _apply_beam_damage ──
	# 不 fire():fire 要读鼠标/相机/枪口并做 BeamTrace 几何,真机方向不可控;此处直接进缝2
	# (_apply_beam_damage → _damage_path_targets → _apply_to_enemy),即激光唯一的敌人伤害点,
	# 几何(缝1)不参与本断言 —— 要钉的是「伤害点写没写归因」。
	var laser_scene: PackedScene = load("res://scenes/weapons/laser_gun.tscn")
	if laser_scene == null:
		_failures.append("laser_gun.tscn 载入失败,无法验证激光归因")
	if laser_scene == null or enemy_scene == null:
		_finish(_failures)
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
	_fx._hit_age = -1.0                        # 清掉上一次的 X 标记,便于断言
	# 一条横穿敌人身体的折线(缝2 的 pts 语义:世界系折线点集)
	var beam_pts := PackedVector2Array([Vector2(200, 0), Vector2(600, 0)])
	laser.call("_apply_beam_damage", beam_pts, [], PackedVector2Array())
	if _fx._hit_age < 0.0:
		_failures.append("激光命中敌人未出命中标记(_apply_to_enemy 的反馈路径断了)")
	if enemy4.has_meta("last_damager"):
		_failures.append("敌人身上不该再有 last_damager meta(单机播报的产物,已随播报删除)")
	laser.queue_free()
	enemy4.queue_free()
	shooter4.queue_free()

func _check_scene_change_idempotent() -> void:
	# ── 换场幂等(必修复归):换场时旧世界仍在树上,新宿主仍须拿到实例 ──
	# 旧行为「存在任何 current 就 return」会让新世界拿不到实例 → 反馈层静默消失。
	var host_b := Node.new()
	add_child(host_b)
	_CF.spawn(host_b)                       # 此刻 current 仍是挂在 self 下的旧实例(正是换场那一刻)
	await get_tree().process_frame
	await get_tree().process_frame         # spawn 是 call_deferred
	if CombatFeedback.current == null or not host_b.is_ancestor_of(CombatFeedback.current):
		_failures.append("换场幂等回归: 旧实例在树上时新宿主拿不到 CombatFeedback 实例")
	# 旧实例(_exit_tree 触发)不得把新引用抹成 null
	if is_instance_valid(_fx):
		_fx.queue_free.call_deferred()
	await get_tree().process_frame
	await get_tree().process_frame
	if CombatFeedback.current == null:
		_failures.append("换场幂等回归: 旧实例退出时把 current 抹成了 null")

func _check_attribute_entry() -> void:
	# ── 归因写端统一入口(抽口后):三条语义 ──
	var v1 := _victim_killed_by(null)                 # 干净目标(该 helper 不预置 meta)
	CombatFeedback.attribute(v1, _make_player())
	if not v1.has_meta("last_damager"):
		_failures.append("attribute 未写 last_damager")
	if not v1.has_meta("last_damager_time"):
		_failures.append("attribute 未写 last_damager_time")
	var v2 := _victim_killed_by(null)
	CombatFeedback.attribute(v2, v2)                  # 自伤:不得归因给自己
	if v2.has_meta("last_damager"):
		_failures.append("attribute 在 attacker == victim 时误写")
	var v3 := _victim_killed_by(null)
	CombatFeedback.attribute(v3, null)                # 无射手:不得写
	if v3.has_meta("last_damager"):
		_failures.append("attribute 在 attacker 为 null 时误写")