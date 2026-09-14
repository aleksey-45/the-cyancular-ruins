extends SceneTree

# 开山砍刀(卡 wp_machete 评审稿)最小自测,-s 探针。覆盖:
#   场景加载/继承 → 无弹夹(reload_active=false、开火不耗弹)→ 扇形横扫命中敌人(伤/击退/归因)
#   → 命中其他玩家(take_hit 路径)→ 挥空硬直(冷却延长 + 移/跳惩罚)→ 扇形拆树叶(bullet 语义,
#   拆砖算命中不算挥空)。网格/瓦片用合成数据,不读地图文件。
# -s 纪律同 enemy_logic_smoke:主脚本零 autoload 静态引用,运行期 load() + 动态分派。
# 跑法: Godot_console --headless --path . -s res://Tests/machete_probe.gd

class StubPlayer:
	extends Node2D
	var facing: int = 1
	func get_facing() -> int:
		return facing
	func set_facing(v: int) -> void:
		facing = 1 if v >= 0 else -1
	func is_downed() -> bool:
		return false
	func apply_recoil(_push: float) -> void:
		pass

# 入 player 组、带 take_hit 记录的桩(签名对齐 player.take_hit 四参)。
class StubCombatPlayer:
	extends Node2D
	var hit_log: Array = []
	func _init() -> void:
		add_to_group("player")
	func take_hit(_source_pos: Vector2, damage: int, _ignore_iframes: bool = false,
			_knockback: float = -1.0) -> void:
		hit_log.append(damage)
	func is_downed() -> bool:
		return false

var _fails := 0

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  OK  " + name)
	else:
		_fails += 1
		printerr("FAIL  " + name)

func _initialize() -> void:
	await physics_frame
	var holder := StubPlayer.new()
	root.add_child(holder)
	holder.global_position = Vector2(400, 400)

	var scene: PackedScene = load("res://Scenes/Weapons/machete.tscn")
	_check(scene != null, "machete.tscn 加载")
	var w = scene.instantiate()
	holder.add_child(w)
	w.equip(holder)
	_check(w.get_script() == load("res://Scenes/Weapons/machete.gd"), "继承 machete.gd")
	_check(is_equal_approx(w.fire_cooldown, 0.5) and w.damage == 30 and is_equal_approx(w.impact, 120.0),
			"卡数值落位(间隔0.5/伤30/击退120)")
	_check(is_equal_approx(w.arc_deg, 130.0) and is_equal_approx(w.melee_range, 90.0),
			"kind_params 落位(弧130°/半径90)")
	_check(not w.reload_active(), "无弹夹无换弹(reload_active=false)")
	_check(w.sprite != null and w.sprite.texture != null, "刀身贴图就位(人工/兜底其一)")

	# ── 扇形横扫:敌人(+70px,弧内)+ 其他玩家(+45px,弧内)各吃一刀 ──
	var e_scene: PackedScene = load("res://Scenes/Enemies/EnemyJumpBird.tscn")
	var e = e_scene.instantiate()
	root.add_child(e)
	e.global_position = Vector2(470, 400)
	var hp_before: int = e.hp
	var mate := StubCombatPlayer.new()
	root.add_child(mate)
	mate.global_position = Vector2(445, 400)
	w.fire()
	_check(e.hp == hp_before - 30, "弧内敌人扣 30 伤")
	_check(e.velocity.x > 0.0, "敌人被向右击退(径向推离)")
	_check(e.get_meta("last_damager") == holder, "击杀归因 meta 写入")
	_check(mate.hit_log == [30], "弧内其他玩家吃 take_hit 30")
	_check(is_equal_approx(w.fire_cd_timer, 0.5), "命中后冷却=攻击间隔0.5")
	var mag_before = w.mag_ammo
	w.fire_cd_timer = 0.0

	# ── 挥空硬直:弧内清空 → 冷却延长 + 移/跳惩罚 ──
	e.global_position = Vector2(3400, 400)   # 远离弧(尸体也在 enemies 组,必须挪走)
	mate.global_position = Vector2(3400, 400)
	w.fire()
	_check(is_equal_approx(w.fire_cd_timer, 0.85), "挥空冷却延长 0.5+0.35")
	_check(w.get_movement_multiplier().is_equal_approx(Vector2(0.5, 0.6)),
			"硬直期间移/跳惩罚 0.5/0.6")
	w._whiff_t = 0.0
	_check(w.get_movement_multiplier().is_equal_approx(Vector2.ONE), "硬直结束惩罚解除")
	w.fire_cd_timer = 0.0
	_check(w.mag_ammo == mag_before, "开火不耗弹(近战无弹药)")

	# ── 扇形拆树叶:合成 3×3 网格,(2,1) 放纹理15(树叶,hp8,bullet 可破)──
	TileDefs.load_defs()
	var grid := []
	for y in range(3):
		var row := []
		for x in range(3):
			row.append(0)
		grid.append(row)
	grid[1][2] = 15 * 16 + 15   # 树叶全砖
	MazeGenerator.current_grid = grid
	holder.global_position = Vector2(96, 96)    # (1,1) 格中心;树叶格中心在正右 64px
	w.fire()
	_check(MazeGenerator.current_grid[1][2] == 0, "扇形内树叶被砍碎(bullet 语义)")
	_check(is_equal_approx(w.fire_cd_timer, 0.5), "砍中砖=接触,不算挥空")
	MazeGenerator.current_grid = []
	w.queue_free()
	holder.free()
	e.free()
	mate.free()

	if _fails == 0:
		print("MACHETE PROBE OK")
	else:
		printerr("MACHETE PROBE FAILED: %d 项" % _fails)
		quit(1)
