extends SceneTree

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

# 带碰撞体的战斗桩玩家:入 player 组、占层2,记录 take_hit 伤害。
class StubCombatPlayer:
	extends CharacterBody2D
	var hit_log: Array = []
	func _init() -> void:
		add_to_group("player")
		collision_layer = 2
		collision_mask = 0
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(40, 40)
		shape.shape = rect
		add_child(shape)
	func take_hit(_source_pos: Vector2, damage: int) -> void:
		hit_log.append(damage)
	func is_downed() -> bool:
		return false

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _initialize() -> void:
	# ── Task 2: 纯函数 ──
	_check(MazeGenerator.toroidal_delta_px(Vector2(10, 10), Vector2(10, 10), 2400.0, 2400.0) == Vector2.ZERO, "delta 零")
	_check(MazeGenerator.toroidal_delta_px(Vector2(2380, 10), Vector2(20, 10), 2400.0, 2400.0) == Vector2(40, 0), "delta 环面 +x")
	_check(MazeGenerator.toroidal_delta_px(Vector2(20, 10), Vector2(2380, 10), 2400.0, 2400.0) == Vector2(-40, 0), "delta 环面 -x")
	_check(MazeGenerator.toroidal_delta_px(Vector2(100, 100), Vector2(150, 60), 2400.0, 2400.0) == Vector2(50, -40), "delta 普通")
	var grid: Array[Array] = []
	for y in range(10):
		var row: Array[int] = []
		row.resize(10)
		row.fill(MazeGenerator.EMPTY)
		grid.append(row)
	var cells := EnemySpawner.sample_spawn_cells(grid, Vector2i(0, 0), 5, 3)
	_check(cells.size() == 5, "spawn 取 5 格")
	var all_far := true
	for c in cells:
		if MazeGenerator.toroidal_dist(c, Vector2i(0, 0), 10, 10) < 3:
			all_far = false
	_check(all_far, "spawn 全部满足最小距离")

	# ── Task 3: EnemyBase 加载 ──
	_check(load("res://Scenes/Enemies/enemy_base.gd") != null, "EnemyBase 脚本加载")

	# ── Task 4: 敌人实例化 ──
	var scene: PackedScene = load("res://Scenes/Enemies/EnemyJumpBird.tscn")
	_check(scene != null, "JumpBird 场景加载")
	var e = scene.instantiate()
	root.add_child(e)
	await physics_frame
	_check(e.get_script() == load("res://Scenes/Enemies/enemy_jump_bird.gd"), "JumpBird 实例类型")
	const SLEEP_STATE := 0
	_check(e.get("state") == SLEEP_STATE, "初始休眠状态")
	_check(e.is_in_group("enemies"), "加入 enemies 组")
	_check(e.get_node_or_null("ContactArea") != null, "ContactArea 创建")

	# ── Task 6: 子弹 ──
	# 清掉 Task 4 遗留的敌人(在原点,碰撞层3);否则子弹出生即命中并立即消失
	e.free()
	var bscene: PackedScene = load("res://Scenes/Weapons/bullet.tscn")
	_check(bscene != null, "子弹场景加载")
	var b = bscene.instantiate()   # untyped, 不标 BulletBase 避免依赖
	root.add_child(b)
	b.setup(Vector2.RIGHT, 1000.0, 300.0, 5.0, Color(1.0, 0.95, 0.6), null)
	await physics_frame
	_check(b.global_position.x > 0.0, "子弹移动")
	var freed := false
	for i in range(40):
		await physics_frame
		if not is_instance_valid(b):
			freed = true
			break
	_check(freed, "子弹超射程消失")

	# ── Task 7: clamp_pitch(迁到 WeaponBase)──
	# 用 load()+资源调用,避免 -s 编译期解析 WeaponBase 时连带预加载 bullet_base.gd
	# (autoload 实例变量在 -s 主脚本编译期不可解析,见 bullet_base.gd 的 GameParameters.MAP_WIDTH)。
	var wb := load("res://Scenes/Weapons/weapon_base.gd")
	_check(wb != null, "WeaponBase 脚本加载")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(1, 0), 1), 0.0), "pitch 水平")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(0, -1), 1), -deg_to_rad(45.0)), "pitch 上钳制")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(0, 1), 1), deg_to_rad(45.0)), "pitch 下钳制")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(-1, 0), 1), deg_to_rad(45.0)), "pitch 身后钳制")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(0, 1), -1), deg_to_rad(45.0)), "pitch 左朝向")

	# ── Task 8: 环面锚定(敌人/子弹跟随主角取模) ──
	const W := 8640.0
	const H := 5184.0
	# 玩家在右端,实体在左端 → 搬到右端副本(探针场景2的期望行为)
	_check(MazeGenerator.anchor_to_nearest(Vector2(100, 100), Vector2(8500, 100), W, H) == Vector2(8740, 100),
			"锚定:左→右")
	# 玩家在左端,实体在右端 → 搬到左端副本
	_check(MazeGenerator.anchor_to_nearest(Vector2(8500, 100), Vector2(100, 100), W, H) == Vector2(-140, 100),
			"锚定:右→左")
	# 玩家在中部,实体同侧 → 不变
	_check(MazeGenerator.anchor_to_nearest(Vector2(4000, 100), Vector2(5000, 100), W, H) == Vector2(4000, 100),
			"锚定:同侧不变")
	# 玩家在右端,实体在右端 → 不变
	_check(MazeGenerator.anchor_to_nearest(Vector2(8500, 100), Vector2(8600, 100), W, H) == Vector2(8500, 100),
			"锚定:相邻不变")
	# y 轴同理
	_check(MazeGenerator.anchor_to_nearest(Vector2(100, 100), Vector2(8500, 5000), W, H) == Vector2(8740, 5284),
			"锚定:双轴")
	# 与玩家重合 → 不变
	_check(MazeGenerator.anchor_to_nearest(Vector2(500, 500), Vector2(500, 500), W, H) == Vector2(500, 500),
			"锚定:自身不变")

	# ── Task 9: 地图尺寸读取(map_size) ──
	_check(MazeGenerator.map_size() == Vector2i(540, 324), "map_size: 从地图文件读取列/行数")

	# ── Task: 武器场景参数 + 开火命中 ──
	var stub := StubPlayer.new()
	root.add_child(stub)
	stub.global_position = Vector2(400, 400)
	var pistol: PackedScene = load("res://Scenes/Weapons/pistol_test.tscn")
	var rifle: PackedScene = load("res://Scenes/Weapons/rifle_test.tscn")
	var sniper: PackedScene = load("res://Scenes/Weapons/m82a1.tscn")
	_check(pistol != null and rifle != null and sniper != null, "三把武器场景加载")
	var w = pistol.instantiate()
	stub.add_child(w)
	w.equip(stub)
	# 避免 -s 静态引用 WeaponBase(编译期连带预加载 bullet_base.gd 引用 autoload
	# 实例变量 GameParameters.MAP_WIDTH,而 -s 阶段 autoload 尚未实例化)→ 用运行时
	# load()+脚本比较代替 is WeaponBase。
	_check(w.get_script() == load("res://Scenes/Weapons/weapon_base.gd"), "武器继承 WeaponBase")
	_check(w.weapon_name == "Pistol", "手枪参数")
	var e_scene: PackedScene = load("res://Scenes/Enemies/EnemyJumpBird.tscn")
	# 复用上面 Task 4 已声明的 e(已 free 过,不能重复 var 声明)
	e = e_scene.instantiate()
	root.add_child(e)
	e.global_position = Vector2(520, 400)
	var hp_before: int = e.hp
	w.fire()
	for i in range(30):
		await physics_frame
		if not is_instance_valid(e):
			break
	_check(e.hp == hp_before - w.damage, "子弹命中扣血")
	_check(absf(e.velocity.x) > 0.0, "子弹命中击退")
	e.free()
	stub.free()

	# ── Task: 玩家装备/切枪 ──
	var player_scene: PackedScene = load("res://Scenes/Player.tscn")
	_check(player_scene != null, "Player 场景加载")
	var p = player_scene.instantiate()
	root.add_child(p)
	await physics_frame
	_check(p._weapon != null, "默认装备手枪")
	if p._weapon != null:
		_check(p._weapon.weapon_name == "Pistol", "默认武器是手枪")
		p._equip_weapon("res://Scenes/Weapons/rifle_test.tscn")
		await physics_frame
		_check(p._weapon.weapon_name == "Rifle", "切枪到步枪")
	p.free()

	# ── Task 1: 碰撞层重构(敌人层3, 玩家子弹不打玩家)──
	var jump2: PackedScene = load("res://Scenes/Enemies/EnemyJumpBird.tscn")
	var e2 := jump2.instantiate()
	root.add_child(e2)
	_check(e2.collision_layer == 3, "敌人占用层3")
	e2.free()
	var bm := bscene.instantiate()
	_check(bm.collision_mask == 5, "玩家子弹 mask=5(地形+敌人)")
	bm.free()
	var pc2 := player_scene.instantiate()
	root.add_child(pc2)
	await physics_frame
	_check(pc2.collision_mask == 5, "玩家 mask=5(地形+敌人)")
	pc2.free()
	# 玩家子弹穿过玩家身体(不再打自己)
	var combat := StubCombatPlayer.new()
	combat.global_position = Vector2(600, 400)
	root.add_child(combat)
	var pb := bscene.instantiate()
	root.add_child(pb)
	pb.setup(Vector2.RIGHT, 1000.0, 800.0, 1.0, Color.WHITE, null)
	pb.global_position = Vector2(400, 400)
	for i in range(15):
		await physics_frame
		if not is_instance_valid(pb):
			break
	_check(is_instance_valid(pb) and pb.global_position.x > 600.0, "玩家子弹穿过玩家不触发")
	_check(combat.hit_log.is_empty(), "玩家未被自己子弹命中")
	combat.free()

	if _failures.is_empty():
		print("SMOKE OK")
		quit(0)
	else:
		printerr("FAILURES: " + str(_failures))
		quit(1)
