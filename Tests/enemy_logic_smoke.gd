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
	func take_hit(_source_pos: Vector2, damage: int, _ignore_iframes: bool = false) -> void:
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
	# 底部整行地板:让 y=8 成为「地板格」(正下方 SOLID),否则全 EMPTY 无格可选。
	# 环面取模后 y=8 与原点距离 ≥3 的候选仍有 9 个,距离断言不受影响。
	for x in range(10):
		grid[9][x] = MazeGenerator.SOLID
	var cells := EnemySpawner.sample_spawn_cells(grid, Vector2i(0, 0), 5, 3)
	_check(cells.size() == 5, "spawn 取 5 格")
	var all_far := true
	for c in cells:
		if MazeGenerator.toroidal_dist(c, Vector2i(0, 0), 10, 10) < 3:
			all_far = false
	_check(all_far, "spawn 全部满足最小距离")
	var all_on_floor := true
	for c in cells:
		if grid[posmod(c.y + 1, 10)][c.x] != MazeGenerator.SOLID:
			all_on_floor = false
	_check(all_on_floor, "spawn 全部位于地板上面")

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
	# 多弹丸(霰弹):fire() 按 pellet_count 生成多颗子弹
	w.pellet_count = 3
	w.spread_deg = 8.0
	var bullet_script := load("res://Scenes/Weapons/bullet_base.gd")
	var b_before := 0
	for child in root.get_children():
		if child.get_script() == bullet_script:
			b_before += 1
	w.fire()
	var b_after := 0
	for child in root.get_children():
		if child.get_script() == bullet_script:
			b_after += 1
	_check(b_after - b_before == 3, "多弹丸开火生成 3 颗子弹")
	w.queue_free()
	stub.free()

	# 霰弹枪场景加载 + 参数
	var sg_scene: PackedScene = load("res://Scenes/Weapons/s686.tscn")
	_check(sg_scene != null, "霰弹枪场景加载")
	var sg = sg_scene.instantiate()  # 无类型:访问自定义属性需要动态分派(项目惯例)
	_check(sg.pellet_count == 8 and is_equal_approx(sg.spread_deg, 8.0), "霰弹枪 8 丸 ±8°")
	_check(sg.damage == 4 and is_equal_approx(sg.bullet_range, 400.0), "霰弹枪单丸4伤/短射程")
	_check(sg.tier == 0, "霰弹枪轻武器")
	sg.queue_free()

	# ── Task: 玩家装备/切枪 ──
	var player_scene: PackedScene = load("res://Scenes/Player/Player.tscn")
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
	_check(e2.collision_layer == 4, "敌人占用层3")
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

	# ── Task 2: MazeGenerator BFS + LOS ──
	var g: Array[Array] = []
	for _y in range(20):
		var row: Array[int] = []
		row.resize(20)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	MazeGenerator.current_grid = g
	var pth := MazeGenerator.bfs_path(Vector2i(2, 2), Vector2i(5, 6))
	_check(not pth.is_empty() and pth[-1] == Vector2i(5, 6), "BFS 全通网格有路")
	_check(pth[0] != Vector2i(2, 2), "BFS 路径不含起点")
	_check(MazeGenerator.bfs_path(Vector2i(2, 2), Vector2i(2, 2)).is_empty(), "BFS 同格返回空")
	# 两条整行墙(第 4/14 行)把环面切成隔离带;跨带必经墙行,才算"隔断"。
	# 3 格短墙在环面上有绕行路,不能证明隔断。
	for x in range(20):
		g[4][x] = MazeGenerator.SOLID
		g[14][x] = MazeGenerator.SOLID
	_check(MazeGenerator.bfs_path(Vector2i(2, 2), Vector2i(2, 8)).is_empty(), "BFS 墙带隔断无路")
	_check(MazeGenerator.bfs_path(Vector2i(2, 8), Vector2i(2, 2)).is_empty(), "BFS 反向也无路")
	# 目标被隔断(BFS 无路)→ bfs_path_nearest 仍返回"最近可达格"的路径,而非空
	var pn := MazeGenerator.bfs_path_nearest(Vector2i(2, 2), Vector2i(2, 8))
	_check(not pn.is_empty(), "bfs_path_nearest 目标不可达仍有降级路径")
	_check(pn[-1] != Vector2i(2, 8), "bfs_path_nearest 终点不是被隔断的目标")
	_check(MazeGenerator.bfs_path_nearest(Vector2i(2, 2), Vector2i(2, 2)).is_empty(), "bfs_path_nearest 同格返回空")
	_check(MazeGenerator.bfs_path_nearest(Vector2i(2, 8), Vector2i(2, 12))[-1] == Vector2i(2, 12), "bfs_path_nearest 可达时直达终点")
	_check(not MazeGenerator.bfs_path(Vector2i(2, 8), Vector2i(2, 12)).is_empty(), "BFS 同带仍有路")
	# 限量预算: 同带可达、曼哈顿距离 14 > 预算 8 → 视为无路
	_check(not MazeGenerator.bfs_path(Vector2i(0, 8), Vector2i(10, 12)).is_empty(), "BFS 预算内可达")
	_check(MazeGenerator.bfs_path(Vector2i(0, 8), Vector2i(10, 12), 8).is_empty(), "BFS 超预算无路")
	# A* 版: 行为与 bfs_path_nearest 一致(可达直达 / 墙带隔断降级 / 同格空)
	var an := MazeGenerator.astar_path_nearest(Vector2i(2, 2), Vector2i(2, 8))
	_check(not an.is_empty(), "astar_path_nearest 目标不可达仍有降级路径")
	_check(an[-1] != Vector2i(2, 8), "astar_path_nearest 终点不是被隔断的目标")
	_check(MazeGenerator.astar_path_nearest(Vector2i(2, 2), Vector2i(2, 2)).is_empty(), "astar_path_nearest 同格返回空")
	_check(MazeGenerator.astar_path_nearest(Vector2i(2, 8), Vector2i(2, 12))[-1] == Vector2i(2, 12), "astar_path_nearest 可达时直达终点")
	_check(MazeGenerator.astar_path_nearest(Vector2i(0, 8), Vector2i(10, 12), 8)[-1] != Vector2i(10, 12), "astar_path_nearest 超预算到不了目标")
	_check(MazeGenerator.has_line_of_sight(Vector2i(0, 0), Vector2i(5, 0)), "LOS 直线通视")
	var g2: Array[Array] = []
	for _y in range(20):
		var row2: Array[int] = []
		row2.resize(20)
		row2.fill(MazeGenerator.EMPTY)
		g2.append(row2)
	for x in range(1, 6):
		g2[2][x] = MazeGenerator.SOLID
	MazeGenerator.current_grid = g2
	_check(not MazeGenerator.has_line_of_sight(Vector2i(0, 2), Vector2i(6, 2)), "LOS 墙阻挡")
	_check(MazeGenerator.has_line_of_sight(Vector2i(0, 0), Vector2i(6, 0)), "LOS 无墙通视")
	# LOS 斜线(旧实现的斜对角走法在 |dx|≠|dy| 时会越过目标行/列,采样到线外格子)
	var g3: Array[Array] = []
	for _y in range(20):
		var row5: Array[int] = []
		row5.resize(20)
		row5.fill(MazeGenerator.EMPTY)
		g3.append(row5)
	MazeGenerator.current_grid = g3
	_check(MazeGenerator.has_line_of_sight(Vector2i(0, 0), Vector2i(5, 3)), "LOS 斜线通视")
	g3[5][5] = MazeGenerator.SOLID  # 在旧实现越行路径上,不在直线上 → 不应阻挡
	_check(MazeGenerator.has_line_of_sight(Vector2i(0, 0), Vector2i(5, 3)), "LOS 斜线旁路墙不阻挡")
	g3[5][5] = MazeGenerator.EMPTY
	g3[2][3] = MazeGenerator.SOLID  # 直线上格(3,2) → 阻挡
	_check(not MazeGenerator.has_line_of_sight(Vector2i(0, 0), Vector2i(5, 3)), "LOS 斜线墙阻挡")
	MazeGenerator.current_grid = []

	# ── Task 3: 敌方抛物线子弹 ──
	var bscene_e: PackedScene = load("res://Scenes/Enemies/enemy_bullet.tscn")
	_check(bscene_e != null, "敌方子弹场景加载")
	var eb := bscene_e.instantiate()
	eb.global_position = Vector2(400, 400)
	root.add_child(eb)
	eb.launch(Vector2(100.0, 0.0), 2000.0, 2, 1.0)
	var start_vy: float = eb.velocity_vec.y
	for i in range(10):
		await physics_frame
	_check(eb.velocity_vec.y > start_vy, "敌方子弹受重力下坠")
	_check(is_instance_valid(eb) and eb.traveled > 0.0, "敌方子弹在飞行")
	eb.free()
	# 命中玩家组 → take_hit(damage)
	var combat2 := StubCombatPlayer.new()
	combat2.global_position = Vector2(400, 400)
	root.add_child(combat2)
	var eb2 := bscene_e.instantiate()
	eb2.global_position = Vector2(400, 400)
	root.add_child(eb2)
	eb2.launch(Vector2(300.0, 0.0), 2000.0, 2, 1.0)
	for i in range(5):
		await physics_frame
		if not is_instance_valid(eb2):
			break
	_check(not is_instance_valid(eb2), "敌方子弹命中玩家后消失")
	_check(combat2.hit_log.has(2), "敌方子弹命中造成伤害 2")
	combat2.free()

	# ── Task 4: 接触伤害守卫(contact_damage<=0 不触发)──
	var combat3 := StubCombatPlayer.new()
	combat3.global_position = Vector2(400, 400)
	root.add_child(combat3)
	var ej := jump2.instantiate()
	ej.global_position = Vector2(400, 400)
	root.add_child(ej)
	ej.contact_damage = 0
	for i in range(5):
		await physics_frame
	_check(combat3.hit_log.is_empty(), "contact_damage=0 不触发接触伤害")
	ej.contact_damage = 4
	for i in range(5):
		await physics_frame
	_check(combat3.hit_log.has(4), "contact_damage>0 触发接触伤害")
	ej.free()
	combat3.free()

	# ── Task 5: FlyBird 基础(睡眠/唤醒/起飞/射击/死亡)──
	var fb_grid: Array[Array] = []
	for _y in range(150):
		var row3: Array[int] = []
		row3.resize(300)
		row3.fill(MazeGenerator.EMPTY)
		fb_grid.append(row3)
	MazeGenerator.current_grid = fb_grid
	var fb_scene: PackedScene = load("res://Scenes/Enemies/EnemyFlyBird.tscn")
	_check(fb_scene != null, "FlyBird 场景加载")
	var fb := fb_scene.instantiate()
	fb.global_position = Vector2(488, 1208)
	root.add_child(fb)
	await physics_frame
	_check(fb.get_script() == load("res://Scenes/Enemies/enemy_fly_bird.gd"), "FlyBird 实例类型")
	_check(fb.state == 0, "FlyBird 初始休眠")
	_check(fb.is_in_group("enemies"), "FlyBird 加入 enemies 组")
	_check(fb.get_node_or_null("ContactArea") != null, "FlyBird ContactArea 创建")
	_check(fb.hp == 25, "FlyBird hp=25")
	_check(fb.contact_damage == 0, "FlyBird 无接触伤害")
	_check(fb.collision_layer == 4, "FlyBird 占层3")
	_check(is_equal_approx(fb.scale.x, 2.0), "FlyBird scale=2.0")
	# 全宽地板:让睡眠的鸟落在地板上,避免自由落体导致其低于玩家(否则平抛弹够不到);
	# 同时供死亡坠落落地。
	var floor_b := StaticBody2D.new()
	var fshape_b := CollisionShape2D.new()
	var frect_b := RectangleShape2D.new()
	frect_b.size = Vector2(5000, 40)
	fshape_b.shape = frect_b
	fshape_b.position = Vector2(0, -20)
	floor_b.add_child(fshape_b)
	floor_b.position = Vector2(2400, 1240)
	floor_b.collision_layer = 1
	floor_b.collision_mask = 0
	root.add_child(floor_b)
	# 玩家远离 → 保持睡眠
	var far_player := StubCombatPlayer.new()
	far_player.global_position = Vector2(2888, 2392)
	root.add_child(far_player)
	for i in range(30):
		await physics_frame
	_check(fb.state == 0, "玩家远处保持睡眠")
	far_player.free()
	# 玩家接近 → 苏醒→起飞→飞行→射击并命中
	var near_player := StubCombatPlayer.new()
	near_player.global_position = Vector2(600, 1208)
	root.add_child(near_player)
	var eb_script := load("res://Scenes/Enemies/enemy_bullet.gd")
	var reached_shoot := false
	var fired := false
	for i in range(240):
		await physics_frame
		if fb.state == 3:
			reached_shoot = true
		if not fired:
			for child in root.get_children():
				if child.get_script() == eb_script:
					fired = true
					break
	_check(reached_shoot, "FlyBird 进入射击状态")
	_check(fired, "FlyBird 发射过投弹")
	_check(near_player.hit_log.has(2), "投弹命中玩家造成 2 伤害")
	# 杀死 → 直接销毁(hurt 内 queue_free,同帧末释放)
	fb.hurt(99, Vector2.RIGHT)
	_check(fb.is_dead, "FlyBird 受击死亡")
	var died := false
	for i in range(180):
		await physics_frame
		if not is_instance_valid(fb):
			died = true
			break
	_check(died, "FlyBird 死亡直接销毁")
	floor_b.free()
	near_player.free()
	MazeGenerator.current_grid = []

	# ── Task 6: FlyBird 冲撞 + 返程 ──
	var fb2_grid: Array[Array] = []
	for _y in range(150):
		var row4: Array[int] = []
		row4.resize(300)
		row4.fill(MazeGenerator.EMPTY)
		fb2_grid.append(row4)
	MazeGenerator.current_grid = fb2_grid
	# 冲撞: HP<25% + LOS 通 → 撞玩家 5 伤并自毁
	var fb2 := fb_scene.instantiate()
	fb2.global_position = Vector2(488, 1208)
	root.add_child(fb2)
	await physics_frame
	fb2.hp = 4
	var charge_player := StubCombatPlayer.new()
	charge_player.global_position = Vector2(700, 1208)
	root.add_child(charge_player)
	var entered_charge := false
	for i in range(240):
		await physics_frame
		if fb2.state == 4:
			entered_charge = true
			break
	_check(entered_charge, "FlyBird 低血量进入冲撞")
	for i in range(120):
		await physics_frame
		if not is_instance_valid(fb2):
			break
	_check(charge_player.hit_log.has(5), "冲撞造成 5 伤害")
	_check(not is_instance_valid(fb2) or fb2.is_dead, "冲撞后自毁")
	if is_instance_valid(fb2):
		fb2.free()
	charge_player.free()
	# 冲撞超时: 起冲后移走玩家 → 超时自毁
	var fb3 := fb_scene.instantiate()
	fb3.global_position = Vector2(488, 1208)
	root.add_child(fb3)
	await physics_frame
	fb3.hp = 4
	var timeout_player := StubCombatPlayer.new()
	timeout_player.global_position = Vector2(700, 1208)
	root.add_child(timeout_player)
	var charged := false
	for i in range(240):
		await physics_frame
		if fb3.state == 4:
			charged = true
			break
	_check(charged, "FlyBird 再次进入冲撞")
	timeout_player.global_position = Vector2(2888, 2392)
	var timed_out := false
	for i in range(200):
		await physics_frame
		if not is_instance_valid(fb3) or fb3.is_dead:
			timed_out = true
			break
	_check(timed_out, "冲撞超时自毁")
	if is_instance_valid(fb3):
		fb3.free()
	timeout_player.free()
	# 返程: 玩家跑出追击范围 → 回家落地入睡
	var floor_r := StaticBody2D.new()
	var fshape_r := CollisionShape2D.new()
	var frect_r := RectangleShape2D.new()
	frect_r.size = Vector2(400, 40)
	fshape_r.shape = frect_r
	fshape_r.position = Vector2(0, -20)
	floor_r.add_child(fshape_r)
	floor_r.position = Vector2(488, 1256)
	floor_r.collision_layer = 1
	floor_r.collision_mask = 0
	root.add_child(floor_r)
	var fb4 := fb_scene.instantiate()
	fb4.global_position = Vector2(488, 1208)
	root.add_child(fb4)
	await physics_frame
	var ret_player := StubCombatPlayer.new()
	ret_player.global_position = Vector2(600, 1208)
	root.add_child(ret_player)
	var engaged := false
	for i in range(240):
		await physics_frame
		if fb4.state == 2 or fb4.state == 3:
			engaged = true
			break
	_check(engaged, "FlyBird 进入战斗状态")
	ret_player.global_position = Vector2(2888, 2392)
	var returned := false
	for i in range(600):
		await physics_frame
		if fb4.state == 0:
			returned = true
			break
	_check(returned, "FlyBird 返程后入睡")
	floor_r.free()
	ret_player.free()
	MazeGenerator.current_grid = []

	if _failures.is_empty():
		print("SMOKE OK")
		quit(0)
	else:
		printerr("FAILURES: " + str(_failures))
		quit(1)
