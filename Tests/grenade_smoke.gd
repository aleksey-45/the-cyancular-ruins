extends SceneTree

# 桩敌人:入 enemies 组,记录 hurt
class StubEnemy:
	extends CharacterBody2D
	var hp: int = 50
	var hits: Array = []
	func _init() -> void:
		add_to_group("enemies")
		collision_layer = 4
		collision_mask = 0
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(40, 40)
		shape.shape = rect
		add_child(shape)
	func hurt(damage: int, _dir: Vector2, _knock: float = 0.0, _set_velocity: bool = false) -> void:
		hp -= damage
		hits.append([damage, _dir, _knock])

# 桩玩家:入 player 组,记录 take_hit
class StubPlayer:
	extends CharacterBody2D
	var hit_log: Array = []
	var knock_log: float = -1.0
	func _init() -> void:
		add_to_group("player")
		collision_layer = 2
		collision_mask = 0
	func take_hit(_source_pos: Vector2, damage: int, _ignore_iframes: bool = false, knockback: float = -1.0) -> void:
		hit_log.append(damage)
		knock_log = knockback
	func is_downed() -> bool:
		return false

# 桩武器:带真实 apply_hit 方法(has_method 只认方法,不认动态属性)
class StubWeapon:
	extends Node2D
	var damage: int = 5
	func apply_hit(target: Node, _dir: Vector2) -> void:
		if target.has_method("hurt"):
			target.hurt(damage, _dir, 0.0)

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _initialize() -> void:
	var gp := root.get_node_or_null("GameParameters")
	if gp != null:
		gp.set("MAP_WIDTH", 400)
		gp.set("MAP_HEIGHT", 400)
	await _test_aoe()
	await _test_fuse()
	await _test_non_explosive_default()
	if _failures.is_empty():
		print("GRENADE SMOKE OK")
		quit(0)
	else:
		printerr("FAILURES: " + str(_failures))
		quit(1)

func _test_aoe() -> void:
	MazeGenerator.current_grid = []  # 空网格:跳过 LOS
	# Explosion 经 load 运行时解析:其内部引用 autoload,-s 静态引用会连带编译失败
	var exp = load("res://Globals/explosion.gd")
	# 中心满伤
	var e1 := StubEnemy.new()
	e1.global_position = Vector2(200, 200)
	root.add_child(e1)
	await physics_frame
	exp.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e1.hp == 50 - 35, "AoE 中心满伤 35")
	e1.free()
	# 边缘(≈radius)→ 0 伤
	var e2 := StubEnemy.new()
	e2.global_position = Vector2(200, 200) + Vector2(127, 0)
	root.add_child(e2)
	await physics_frame
	exp.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e2.hp == 50, "AoE 边缘 0 伤")
	e2.free()
	# 中段衰减: d=64, inner=44.8 → 35*(1-(64-44.8)/83.2)=26
	var e3 := StubEnemy.new()
	e3.global_position = Vector2(200, 200) + Vector2(64, 0)
	root.add_child(e3)
	await physics_frame
	exp.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e3.hp == 50 - 26, "AoE 中段线性衰减")
	e3.free()
	# 冲击波向外:方向为从爆心指向目标
	var e4 := StubEnemy.new()
	e4.global_position = Vector2(200, 200) + Vector2(0, 60)
	root.add_child(e4)
	await physics_frame
	exp.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e4.hits.size() == 1 and e4.hits[0][1].y > 0.0, "冲击波方向向外(+y)")
	e4.free()
	# 友伤:玩家在范围内掉血
	var p := StubPlayer.new()
	p.global_position = Vector2(200, 200) + Vector2(20, 0)
	root.add_child(p)
	await physics_frame
	exp.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(p.hit_log.has(35), "玩家友伤满值 35")
	_check(is_equal_approx(p.knock_log, 900.0), "玩家受击收到满值击退 900")
	p.free()
	# LOS 遮挡:墙列 x=4 挡住「向左绕行的环面最短路径」→ 0 伤;右侧开阔 → 满伤
	var g: Array[Array] = []
	for _y in range(25):
		var row: Array[int] = []
		row.resize(25)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	for y in range(25):
		g[y][4] = MazeGenerator.SOLID
	MazeGenerator.current_grid = g
	# 爆心(5,12)→(1,12):环面最短走左弧 5→4(墙)→3→2→1,被 x=4 墙挡
	var walled := StubEnemy.new()
	walled.global_position = Vector2(1 * 16, 12 * 16)
	root.add_child(walled)
	await physics_frame
	exp.apply_aoe(Vector2(5 * 16, 12 * 16), 300.0, 35, 900.0)
	_check(walled.hp == 50 - 17, "墙后敌人减半伤(17)")
	walled.free()
	# 爆心(5,12)→(8,12):右弧 5→6→7→8 无墙 → 满伤
	var open := StubEnemy.new()
	open.global_position = Vector2(8 * 16, 12 * 16)
	root.add_child(open)
	await physics_frame
	exp.apply_aoe(Vector2(5 * 16, 12 * 16), 300.0, 35, 900.0)
	_check(open.hp == 50 - 35, "开阔侧满伤")
	open.free()
	MazeGenerator.current_grid = []

func _test_fuse() -> void:
	MazeGenerator.current_grid = []
	# ── 基类重力:gravity_factor>0 时 velocity_vec.y 每帧增大(重力上移验证)──
	var bg = _make_bullet()
	bg.set("explodes", false)
	root.add_child(bg)
	bg.global_position = Vector2(100, 100)
	bg.setup(Vector2.RIGHT, 500.0, 2000.0, 1.0, Color.WHITE, null)
	bg.set("gravity_factor", 0.5)
	await physics_frame
	_check(bg.velocity_vec.y > 0.0, "基类重力生效(gravity_factor>0)")
	bg.free()
	# ── 直接命中敌人:10 直接伤立即 + 反弹 + 引信 hit_fuse_time(0.1s)短延时爆炸 ──
	var b = _make_bullet()
	b.set("hit_fuse_time", 0.1)
	root.add_child(b)
	var enemy := StubEnemy.new()
	enemy.global_position = Vector2(300, 200)
	root.add_child(enemy)
	b.global_position = Vector2(200, 200)
	b.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, null)
	# 命中瞬间:直接伤 10 立扣,子弹反弹(速度方向反转)未销毁
	var hit_seen := false
	var bounced := false
	for i in range(60):
		await physics_frame
		if is_instance_valid(enemy) and enemy.hp == 50 - 10:
			hit_seen = true
			if is_instance_valid(b) and b.velocity_vec.x < 0.0:
				bounced = true
				break
	_check(hit_seen and bounced, "命中敌人:10 直接伤立即,子弹反弹(方向反转)不销毁")
	# 短引信:命中后约 0.1s(≈6 帧)爆炸,不是长 fuse_time(默认 0.5s)——15 帧内必须炸
	var exploded2 := false
	for i in range(15):
		await physics_frame
		if not is_instance_valid(b):
			exploded2 = true
			break
	_check(exploded2, "命中敌人反弹后约 0.1s 短引信爆炸")
	enemy.free()
	# ── 撞墙 → 停驻 → 0.5s 后才爆(飞行中不炸)──
	var wall := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(20, 300)
	shape.shape = rect
	wall.add_child(shape)
	wall.position = Vector2(300, 200)
	wall.collision_layer = 1
	wall.collision_mask = 0
	root.add_child(wall)
	var far := StubEnemy.new()
	far.global_position = Vector2(200, 400)  # 远离爆点,不受伤
	root.add_child(far)
	var b2 = _make_bullet()
	root.add_child(b2)
	b2.global_position = Vector2(200, 200)
	b2.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, null)
	var stopped := false
	for i in range(12):
		await physics_frame
		if b2.global_position.x >= 280.0 and is_instance_valid(b2):
			stopped = true
			break
	_check(stopped and is_instance_valid(b2), "撞墙后反弹且未销毁")
	var exploded := false
	for i in range(60):
		await physics_frame
		if not is_instance_valid(b2):
			exploded = true
			break
	_check(exploded, "撞墙后约 0.5s 爆炸")
	far.free()
	wall.free()

func _test_non_explosive_default() -> void:
	MazeGenerator.current_grid = []
	var b = _make_bullet()
	b.set("explodes", false)
	root.add_child(b)
	var enemy := StubEnemy.new()
	enemy.global_position = Vector2(300, 200)
	root.add_child(enemy)
	b.global_position = Vector2(200, 200)
	var gun := StubWeapon.new()
	root.add_child(gun)
	b.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, gun)
	for i in range(60):
		await physics_frame
		if not is_instance_valid(b):
			break
	_check(enemy.hp == 50 - 5, "非爆炸弹直击走 apply_hit(武器 damage=5)")
	enemy.free()

# 直接 new bullet_base.gd,补碰撞体;返回已设 explodes=true、关特效的子弹。
# 无类型返回:setup/explodes/gravity_factor 都是脚本自定义成员,须动态分派。
func _make_bullet():
	var b = (load("res://Scenes/Weapons/bullet_base.gd") as GDScript).new()
	var cshape := CollisionShape2D.new()
	var circ := CircleShape2D.new()
	circ.radius = 6.0
	cshape.shape = circ
	b.add_child(cshape)
	b.set("collision_layer", 0)
	b.set("collision_mask", 5)  # 地形+敌人,与真实榴弹场景一致
	b.set("explodes", true)
	b.set("explosion_visual", null)
	return b
