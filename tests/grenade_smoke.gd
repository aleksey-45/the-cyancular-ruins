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
	await _test_player_contact()
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
	var exp = load("res://core/explosion.gd")
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
	# 中段衰减(1-t²): d=64, inner=51.2 → t=(64-51.2)/76.8=0.167, 35*(1-0.028)=34
	var e3 := StubEnemy.new()
	e3.global_position = Vector2(200, 200) + Vector2(64, 0)
	root.add_child(e3)
	await physics_frame
	exp.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e3.hp == 50 - 34, "AoE 中段平缓衰减")
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
	# ⚠ 分格单位坑:遮挡判定按 TILE_SIZE=64 分格(Explosion._has_los → MazeGenerator.cell_of),
	# 而本文件其它几何是按「16px 一格」写的。x=4 那根整列墙的世界范围其实是 [256,320)。
	# 所以爆心放第 5 格(x=5*64+32=352)、目标放第 3 格(x=3*64=192):墙**真的**夹在两者之间,
	# 环面最短路径 5→4(墙列)→3 被挡。d=160px 也在 radius×INNER_FRACTION=120px 内圈之外 ——
	# 内圈按设计免疫遮挡,贴脸目标测不出掩护(旧几何 (5,12)→(1,12) 两格都在墙同侧且落在内圈,断言恒红)。
	var blast := Vector2(5 * 64 + 32, 12 * 16)
	var walled := StubEnemy.new()
	walled.global_position = Vector2(3 * 64, 12 * 16)
	root.add_child(walled)
	await physics_frame
	exp.apply_aoe(blast, 300.0, 35, 900.0)
	# 墙后掩护衰减:实际伤害应低于同距离无遮挡的理论值
	# (用已加载的 exp 句柄取 _dist/_falloff,不用全局类名 Explosion —— -s 阶段解析全局类会拿不到 autoload)
	var d_walled: float = exp._dist(blast, walled.global_position)
	_check(walled.hp > 50 - int(exp._falloff(d_walled, 300.0, 35)),
			"墙后敌人伤害应低于同距离无遮挡(d=%.0f, 实际 hp=%d)" % [d_walled, walled.hp])
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

# ── 榴弹碰玩家:短引信(hit_fuse_time)+ 「首次碰撞决定引信时长、不刷新」的纪律 ──
# 判定在 BulletBase._check_player_contact(两端同源:服务器/客户端视觉副本共用),
# 权威的直接伤在 server/match_host.gd 的 _adjudicate_grenade(不在本 -s 冒烟覆盖范围,
# 它要整局 MatchHost;这里钉的是引信侧)。
func _test_player_contact() -> void:
	MazeGenerator.current_grid = []
	# 场景值兜底:本冒烟全程手写 0.4/0.15,若 grenade_bullet.tscn 被改成别的数,这里先报
	var scene = (load("res://scenes/weapons/grenade_bullet.tscn") as PackedScene).instantiate()
	_check(is_equal_approx(float(scene.fuse_time), 0.4) \
			and is_equal_approx(float(scene.hit_fuse_time), 0.15),
			"grenade_bullet.tscn 引信值仍是 撞墙0.4s / 命中玩家0.15s")
	scene.free()

	# ① 飞行中碰到玩家 → 起 hit_fuse_time 短引信(而不是撞墙的 fuse_time)
	var p := StubPlayer.new()
	p.global_position = Vector2(300, 200)
	root.add_child(p)
	var b = _make_bullet()
	b.set("fuse_time", 0.4)
	b.set("hit_fuse_time", 0.15)
	root.add_child(b)
	b.global_position = Vector2(200, 200)
	b.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, null)
	var dur := 0.0
	for _i in range(20):
		await physics_frame
		if bool(b.get("_fuse_active")):
			dur = float(b.get("_fuse_duration"))
			break
	_check(is_equal_approx(dur, 0.15), "榴弹碰到玩家 → 起短引信 0.15s(实测 %.3f)" % dur)
	var exploded := false
	for _i in range(15):
		await physics_frame
		if not is_instance_valid(b):
			exploded = true
			break
	_check(exploded, "短引信在 0.25s 内爆炸(明显早于撞墙的 0.4s)")
	p.free()

	# ② 视觉副本(apply_damage=false,对手端那份)按同款判定同样起短引信
	var p2 := StubPlayer.new()
	p2.global_position = Vector2(300, 200)
	root.add_child(p2)
	var bv = _make_bullet()
	bv.set("apply_damage", false)
	bv.set("fuse_time", 0.4)
	bv.set("hit_fuse_time", 0.15)
	root.add_child(bv)
	bv.global_position = Vector2(200, 200)
	bv.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, null)
	var vdur := 0.0
	for _i in range(20):
		await physics_frame
		if bool(bv.get("_fuse_active")):
			vdur = float(bv.get("_fuse_duration"))
			break
	_check(is_equal_approx(vdur, 0.15), "视觉副本(apply_damage=false)同样起短引信 0.15s(实测 %.3f)" % vdur)
	bv.free()
	p2.free()

	# ③ 射手自己不算"碰到玩家"(否则自己的榴弹一出膛就在身上起短引信)
	var selfp := StubPlayer.new()
	selfp.global_position = Vector2(300, 200)
	root.add_child(selfp)
	var bs = _make_bullet()
	bs.set("fuse_time", 0.4)
	bs.set("hit_fuse_time", 0.15)
	root.add_child(bs)
	bs.shooter = selfp
	bs.global_position = Vector2(200, 200)
	bs.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, null)
	for _i in range(20):
		await physics_frame
	_check(not bool(bs.get("_fuse_active")), "射手自己不触发短引信(排除 shooter)")
	bs.free()
	selfp.free()

	# ④ 纪律:首次碰撞决定引信时长,之后不刷新 —— 已因撞墙起 0.4s 长引信的榴弹碰到玩家
	#    **不会**缩短(直接伤是另一个独立的闩,不受此限,由 MatchHost 结算)。
	var b2 = _make_bullet()
	root.add_child(b2)
	b2.set("fuse_time", 0.4)
	b2.set("hit_fuse_time", 0.15)
	b2._start_fuse(0.4)        # 撞墙
	b2.start_player_fuse()     # 再碰到玩家
	_check(is_equal_approx(float(b2.get("_fuse_duration")), 0.4),
			"已起 0.4s 长引信后再碰玩家不缩短(仍 %.3f)" % float(b2.get("_fuse_duration")))
	b2.free()

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
	# 切枪后 source 失效:在途子弹用自带 damage/impact 兜底仍造成伤害(回归)
	var b3 = _make_bullet()
	b3.set("explodes", false)
	root.add_child(b3)
	var enemy3 := StubEnemy.new()
	enemy3.global_position = Vector2(300, 200)
	root.add_child(enemy3)
	b3.global_position = Vector2(200, 200)
	b3.set("hit_damage", 5)
	b3.set("hit_impact", 0.0)
	b3.setup(Vector2.RIGHT, 1000.0, 2000.0, 1.0, Color.WHITE, null)  # source=null 模拟切枪后失效
	for i in range(60):
		await physics_frame
		if not is_instance_valid(b3):
			break
	_check(enemy3.hp == 50 - 5, "切枪后子弹仍造成伤害(source失效兜底)")
	enemy3.free()

# 直接 new bullet_base.gd,补碰撞体;返回已设 explodes=true、关特效的子弹。
# 无类型返回:setup/explodes/gravity_factor 都是脚本自定义成员,须动态分派。
func _make_bullet():
	var b = (load("res://scenes/weapons/bullet_base.gd") as GDScript).new()
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
