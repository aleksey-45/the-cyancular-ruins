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
	_check(MazeGenerator.map_size() == Vector2i(250, 150), "map_size: 从地图文件读取列/行数")

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
	_check(sg.pellet_count == 8 and is_equal_approx(sg.spread_deg, 5.0), "霰弹枪 8 丸 ±5°")
	_check(sg.damage == 4 and is_equal_approx(sg.bullet_range, 700.0), "霰弹枪单丸4伤/射程700")
	_check(sg.tier == 0, "霰弹枪轻武器")
	sg.queue_free()

	# ── Task: 缓冲开火(冷却>0.5 武器,最后 20% 按开火→冷却结束自动打)──
	# 先清掉前面测试遗留的弹丸,避免污染弹丸计数
	var bf_leftovers: Array = []
	for child in root.get_children():
		if child.get_script() == bullet_script:
			bf_leftovers.append(child)
	for bl in bf_leftovers:
		bl.free()
	var buf_stub := StubPlayer.new()
	root.add_child(buf_stub)
	buf_stub.global_position = Vector2(400, 400)
	var buf_w = sg_scene.instantiate()   # s686 fire_cooldown 0.75 > 0.5
	buf_stub.add_child(buf_w)
	buf_w.equip(buf_stub)
	buf_w.fire_cd_timer = 0.1   # 0.75*0.2=0.15 窗口内(最后 20%)
	var bf_before := 0
	for child in root.get_children():
		if child.get_script() == bullet_script:
			bf_before += 1
	buf_w.try_fire()
	_check(buf_w._fire_buffered, "冷却末尾按开火→缓冲")
	var bf_mid := 0
	for child in root.get_children():
		if child.get_script() == bullet_script:
			bf_mid += 1
	_check(bf_mid == bf_before, "缓冲期不立即开火")
	for i in range(30):
		await physics_frame
		if not is_instance_valid(buf_w):
			break
	var bf_after := 0
	for child in root.get_children():
		if child.get_script() == bullet_script:
			bf_after += 1
	_check(bf_after == bf_before + buf_w.pellet_count, "冷却结束自动开火")
	buf_w.queue_free()
	buf_stub.free()

	# ── Task: 预瞄算子弹碰撞体积(小球判墙,中心点不穿但体积擦墙即截断)──
	var gl_scene: PackedScene = load("res://Scenes/Weapons/grenade_launcher.tscn")
	_check(gl_scene != null, "榴弹场景加载")
	var grid_arc: Array[Array] = []
	for y in range(20):
		var row: Array[int] = []
		row.resize(20)
		row.fill(MazeGenerator.EMPTY)
		grid_arc.append(row)
	# 水平墙:第 8 行、列 10..14(墙左缘 x=10·ts,墙行下缘 y=9·ts)。
	# 枪口本地 y 偏移 +8(Muzzle Marker2D),枪口放墙行下缘下方 3px,小球擦墙。
	for x in range(10, 15):
		grid_arc[8][x] = MazeGenerator.SOLID
	MazeGenerator.current_grid = grid_arc
	var arc_stub := StubPlayer.new()
	root.add_child(arc_stub)
	arc_stub.global_position = Vector2(100, 9 * GameParameters.TILE_SIZE + 3.0 - 8.0)
	var arc_w = gl_scene.instantiate()
	arc_stub.add_child(arc_w)
	arc_w.equip(arc_stub)
	arc_w.bullet_gravity = 0.0   # 直线水平,便于定位;枪口在墙行下缘下方 3px,小球擦墙
	var arc_pts: PackedVector2Array = arc_w._sample_arc_points()
	_check(arc_pts.size() > 1, "预瞄小球:弧线未空")
	var arc_last: Vector2 = arc_w.to_global(arc_pts[arc_pts.size() - 1])
	_check(arc_last.x < 10.0 * GameParameters.TILE_SIZE, "预瞄小球:体积擦墙即截断,落点在墙前")
	arc_w.queue_free()
	arc_stub.free()
	MazeGenerator.current_grid = []

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
		# 切枪冷却继承:旧武器剩余冷却不能被切枪刷掉。
		# equip() 同步执行,不 await(否则 _process 已扣掉一帧冷却)。
		p._weapon.fire_cd_timer = 0.7
		p._equip_weapon("res://Scenes/Weapons/pistol_test.tscn")
		_check(is_equal_approx(p._weapon.fire_cd_timer, 0.7), "切枪继承剩余冷却")
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
	# 杀死 → 直接销毁(白闪计时后销毁,物理走 super 统一路径)
	fb.hurt(99, Vector2.RIGHT)
	_check(fb.is_dead, "FlyBird 受击死亡")
	var died := false
	for i in range(180):
		await physics_frame
		if not is_instance_valid(fb):
			died = true
			break
	_check(died, "FlyBird 死亡直接销毁")
	# 死亡物理与生前一致:爆炸式击退在尸体上不折入,knock_velocity 仍独立衰减
	var fb_d := fb_scene.instantiate()
	fb_d.global_position = Vector2(1000, 400)
	root.add_child(fb_d)
	await physics_frame
	fb_d.hurt(99, Vector2.RIGHT, 1000.0, true)  # 爆炸式击退
	_check(fb_d.is_dead, "飞鸟受击死亡(爆炸)")
	_check(is_equal_approx(fb_d.knock_velocity.x, 1000.0), "尸体保留独立击退向量(未折入)")
	var fd0: float = fb_d.knock_velocity.x
	for i in range(5):
		await physics_frame
	_check(fb_d.knock_velocity.x < fd0, "尸体击退向量随帧衰减(与生前同物理)")
	fb_d.free()
	# 吞冲击波回归:先打死尸体,后续爆炸仍能推动尸体(只吃击退不吃伤)
	var fd2 := fb_scene.instantiate()
	fd2.set("hp", 5)
	fd2.global_position = Vector2(1000, 400)
	root.add_child(fd2)
	await physics_frame
	fd2.hurt(99, Vector2.RIGHT)  # 直接打死
	_check(fd2.is_dead, "飞鸟尸体已死")
	fd2.hurt(1, Vector2.LEFT, 1500.0, true)  # 爆炸式冲击推尸体
	_check(fd2.knock_velocity.x < 0.0, "尸体被后续爆炸推动(吞冲击波回归)")
	fd2.free()
	# 尸体基础速度也衰减(死后滑行逐渐停住,不匀速滑到底)
	var fd3 := fb_scene.instantiate()
	fd3.global_position = Vector2(1000, 400)
	root.add_child(fd3)
	await physics_frame
	fd3.hurt(99, Vector2.RIGHT)  # 打死,velocity += 200
	_check(fd3.velocity.x > 100.0, "尸体有基础滑行速度")
	var vx0: float = fd3.velocity.x
	for i in range(10):
		await physics_frame
	_check(fd3.velocity.x < vx0, "尸体基础速度随帧衰减(不匀速滑到底)")
	fd3.free()
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
	# 冲撞中被射杀(未撞到东西): 清冲撞速度, 尸体白闪期间不再续冲
	var fb4 := fb_scene.instantiate()
	fb4.global_position = Vector2(488, 1208)
	root.add_child(fb4)
	await physics_frame
	fb4.hp = 4
	var charge_kill_player := StubCombatPlayer.new()
	charge_kill_player.global_position = Vector2(700, 1208)
	root.add_child(charge_kill_player)
	var charged2 := false
	for i in range(240):
		await physics_frame
		if fb4.state == 4:
			charged2 = true
			break
	_check(charged2, "冲撞中被射杀前置:进入冲撞")
	fb4.hurt(99, Vector2.RIGHT)
	_check(fb4.is_dead, "冲撞中被射杀死亡")
	_check(fb4.velocity.x == 0.0, "冲撞死清水平速度,不再续冲")
	for i in range(5):
		await physics_frame
	_check(fb4.velocity.x == 0.0, "尸体白闪期间持续无水平续冲")
	charge_kill_player.free()
	if is_instance_valid(fb4):
		fb4.free()
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
	var fb5 := fb_scene.instantiate()
	fb5.global_position = Vector2(488, 1208)
	root.add_child(fb5)
	await physics_frame
	var ret_player := StubCombatPlayer.new()
	ret_player.global_position = Vector2(600, 1208)
	root.add_child(ret_player)
	var engaged := false
	for i in range(240):
		await physics_frame
		if fb5.state == 2 or fb5.state == 3:
			engaged = true
			break
	_check(engaged, "FlyBird 进入战斗状态")
	ret_player.global_position = Vector2(2888, 2392)
	var returned := false
	for i in range(600):
		await physics_frame
		if fb5.state == 0:
			returned = true
			break
	_check(returned, "FlyBird 返程后入睡")
	floor_r.free()
	ret_player.free()
	MazeGenerator.current_grid = []

	# ── Task 7: A* 扁平数组 + 路径缓存 ──
	# 大网格(demo 全尺寸)上跑 A*:不崩、路径逐格相邻且在界内(扁平数组索引正确)。
	var big_grid := MazeGenerator.load_map_file()
	MazeGenerator.current_grid = big_grid
	var far := MazeGenerator.astar_path_nearest(Vector2i(10, 10), Vector2i(240, 120))
	var far_valid := true
	var prev_cell := Vector2i(10, 10)
	for c in far:
		if c.x < 0 or c.x >= 250 or c.y < 0 or c.y >= 150:
			far_valid = false
			break
		var dxc := absi(c.x - prev_cell.x)
		var dyc := absi(c.y - prev_cell.y)
		dxc = mini(dxc, 250 - dxc)
		dyc = mini(dyc, 150 - dyc)
		if not (dxc + dyc == 1):
			far_valid = false
			break
		prev_cell = c
	_check(far_valid, "大网格 A* 路径逐格相邻且在界内")
	# 路径缓存:目标格未变且路径还在 → 不重跑 A*(astar_calls 不涨)
	var cache_grid: Array[Array] = []
	for _y in range(60):
		var row_c: Array[int] = []
		row_c.resize(60)
		row_c.fill(MazeGenerator.EMPTY)
		cache_grid.append(row_c)
	MazeGenerator.current_grid = cache_grid
	var fb_cache := fb_scene.instantiate()
	fb_cache.global_position = Vector2(2000, 400)  # 远离 Task6 遗留的睡眠鸟(488,1208),不被当障碍
	root.add_child(fb_cache)
	await physics_frame
	# 无玩家在组:鸟保持睡眠(不自己 repath),且 _collect_obstacles 只对 ≤600px 的实体收障碍
	var calls0: int = MazeGenerator.astar_calls
	fb_cache._repath_to(Vector2i(40, 20))
	var calls1: int = MazeGenerator.astar_calls
	_check(calls1 - calls0 == 1, "首次 repath 跑一次 A*")
	fb_cache._repath_to(Vector2i(40, 20))
	_check(MazeGenerator.astar_calls - calls1 == 0, "同目标且路径未空 → 缓存命中跳过 A*")
	fb_cache._repath_to(Vector2i(41, 20))
	_check(MazeGenerator.astar_calls - calls1 == 1, "目标变化 → 重跑 A*")
	fb_cache._repath_to(Vector2i(41, 20))
	_check(MazeGenerator.astar_calls - calls1 == 1, "同目标再跳一次")
	fb_cache.free()
	MazeGenerator.current_grid = []

	# ── 爆炸独立击退向量(大冲击+迅速衰减)vs 枪击叠加 ──
	var ov_grid: Array[Array] = []
	for _y in range(60):
		var row_o: Array[int] = []
		row_o.resize(60)
		row_o.fill(MazeGenerator.EMPTY)
		ov_grid.append(row_o)
	MazeGenerator.current_grid = ov_grid
	var ov := fb_scene.instantiate()
	ov.global_position = Vector2(1000, 400)
	root.add_child(ov)
	await physics_frame
	# 枪击(默认叠加):原速度 500 + 击退 300 = 800
	ov.velocity = Vector2(500, 0)
	ov.hurt(1, Vector2.RIGHT, 300.0)
	_check(is_equal_approx(ov.velocity.x, 800.0), "枪击击退叠加 500+300=800")
	# 爆炸(set_velocity=true):设独立击退向量,不覆盖移动速度
	ov.velocity = Vector2(500, 0)
	ov.hurt(1, Vector2.RIGHT, 300.0, true)
	_check(is_equal_approx(ov.knock_velocity.x, 300.0), "爆炸设独立击退向量 300")
	_check(is_equal_approx(ov.velocity.x, 500.0), "爆炸不覆盖移动速度(500 保留)")
	_check(is_equal_approx(ov.knock_velocity.y, 0.0), "爆炸击退纯径向(y=0)")
	# 击退向量随帧指数衰减
	var ov0: float = ov.knock_velocity.x
	for i in range(5):
		await physics_frame
	_check(ov.knock_velocity.x < ov0, "爆炸击退向量随帧衰减")
	ov.free()
	MazeGenerator.current_grid = []

	# ── 玩家爆炸击退独立向量:take_hit 传击退 → 向量生效并衰减 ──
	var pk := player_scene.instantiate()
	pk.global_position = Vector2(1000, 400)
	root.add_child(pk)
	await physics_frame
	pk.take_hit(Vector2(800, 400), 5, false, 800.0)
	_check(is_equal_approx(pk.knock_velocity.x, 800.0), "玩家爆炸击退设独立向量")
	var pk0: float = pk.knock_velocity.x
	for i in range(5):
		await physics_frame
	_check(pk.knock_velocity.x < pk0, "玩家击退向量随帧衰减")
	pk.free()
	# 上方爆炸:玩家站在地面时应被往下压(不产生向上速度)——回归:旧"叠加再减回"实现会把玩家弹起
	var pk_floor := StaticBody2D.new()
	var pk_fshape := CollisionShape2D.new()
	var pk_frect := RectangleShape2D.new()
	pk_frect.size = Vector2(500, 40)
	pk_fshape.shape = pk_frect
	pk_fshape.position = Vector2(0, -20)
	pk_floor.add_child(pk_fshape)
	pk_floor.position = Vector2(1000, 430)
	pk_floor.collision_layer = 1
	pk_floor.collision_mask = 0
	root.add_child(pk_floor)
	var pk2 := player_scene.instantiate()
	pk2.global_position = Vector2(1000, 400)
	root.add_child(pk2)
	for i in range(5):
		await physics_frame
	pk2.take_hit(Vector2(1000, 200), 5, false, 800.0)  # 爆心在玩家上方
	_check(pk2.knock_velocity.y > 0.0, "上方爆炸击退向量向下(+y)")
	for i in range(3):
		await physics_frame
	_check(pk2.velocity.y > -100.0, "玩家不被上方爆炸弹起(velocity.y 无显著上跳)")
	pk2.free()
	pk_floor.free()
	# 玩家倒地不取消物理:保留击退向量并随帧衰减(与敌人统一)
	var pd := player_scene.instantiate()
	pd.global_position = Vector2(1000, 400)
	root.add_child(pd)
	await physics_frame
	pd.take_hit(Vector2(800, 400), 999, false, 1000.0)  # 爆炸式击退 + 秒杀
	_check(pd.downed, "玩家倒地")
	_check(pd.knock_velocity.x > 0.0, "倒地保留击退向量(未清零)")
	var pd0: float = pd.knock_velocity.x
	for i in range(5):
		await physics_frame
	_check(pd.knock_velocity.x < pd0, "倒地击退向量随帧衰减(物理未取消)")
	pd.free()
	# 死亡保留碰撞(与飞鸟统一):JumpBird 死亡后碰撞箱不清空
	var jdc := jump2.instantiate()
	jdc.global_position = Vector2(1000, 800)
	root.add_child(jdc)
	await physics_frame
	jdc.hurt(99, Vector2.RIGHT)
	_check(jdc.is_dead, "JumpBird 受击死亡")
	_check(jdc.collision_layer == 4, "JumpBird 死亡保留碰撞层")
	_check(jdc.collision_mask == 7, "JumpBird 死亡保留碰撞掩码")
	jdc.free()

	# ── Task 7: FlyBird 死区先下飞(逐行下探)──
	# 宽天花板:行 10..12 全实心横跨 300 列。鸟被压到行 13,该行按飞行高度判全撞墙
	# (A* 空路径)。旧逃逸只在当前行左右扫,找不到列就原地悬停;新逻辑逐行下探到
	# 行 17(箱体 y∈[218,272],全在天花板 208 之下)取可走格,鸟真正下潜。
	var esc_grid: Array[Array] = []
	for _y in range(30):
		var row_e: Array[int] = []
		row_e.resize(300)
		row_e.fill(MazeGenerator.EMPTY)
		esc_grid.append(row_e)
	for _r in range(10, 13):
		for _c in range(300):
			esc_grid[_r][_c] = MazeGenerator.SOLID
	MazeGenerator.current_grid = esc_grid
	var esc := fb_scene.instantiate()
	esc.global_position = Vector2(2400, 13 * 16 + 8)
	root.add_child(esc)
	await physics_frame
	var esc_t: Vector2 = esc._find_escape_column()
	_check(esc_t.y > esc.global_position.y, "死区逃逸先下飞(目标在鸟下方)")
	var esc_cell := MazeGenerator.cell_of(esc_t, 16, 300, 30)
	_check(esc._bird_can_pass(esc_cell), "下潜目标格可走(A* 可起路)")
	# 下潜运动:_follow_path 逃逸分支应给向下的速度(旧实现锁 y,只水平飞)。
	# _path 新实例本为空,不必(也不能)赋 untyped [](_path 是 Array[Vector2i])。
	esc._escape_target = esc_t
	esc._follow_path(0.01, Vector2.ZERO)
	_check(esc.velocity.y > 0.0, "死区逃逸对角下潜(velocity.y>0)")
	# 窄檐回归:天花板只覆盖部分列,鸟仍能逃到可走格,不原地卡死
	var esc2_grid: Array[Array] = []
	for _y in range(30):
		var row_e2: Array[int] = []
		row_e2.resize(300)
		row_e2.fill(MazeGenerator.EMPTY)
		esc2_grid.append(row_e2)
	for _r in range(10, 13):
		for _c in range(80):
			esc2_grid[_r][_c] = MazeGenerator.SOLID
	MazeGenerator.current_grid = esc2_grid
	var esc2 := fb_scene.instantiate()
	esc2.global_position = Vector2(640, 13 * 16 + 8)
	root.add_child(esc2)
	await physics_frame
	var esc2_t: Vector2 = esc2._find_escape_column()
	_check(esc2_t != esc2.global_position, "窄檐仍能逃逸(不停在原地)")
	var esc2_cell := MazeGenerator.cell_of(esc2_t, 16, 300, 30)
	_check(esc2._bird_can_pass(esc2_cell), "窄檐逃逸目标格可走")
	esc.free()
	esc2.free()
	MazeGenerator.current_grid = []

	# ── Task: BlackBird(绕背瞬移刺客)──
	var bk_grid: Array[Array] = []
	for _y in range(60):
		var row_bk: Array[int] = []
		row_bk.resize(120)
		row_bk.fill(MazeGenerator.EMPTY)
		bk_grid.append(row_bk)
	for _x in range(120):
		bk_grid[58][_x] = MazeGenerator.SOLID  # 地板
	MazeGenerator.current_grid = bk_grid
	# 物理地板:网格只用于寻路/LOS,不产生物理碰撞;没它鸟会一直下落远离玩家醒不来。
	var bk_floor := StaticBody2D.new()
	var bkshape := CollisionShape2D.new()
	var bkrect := RectangleShape2D.new()
	bkrect.size = Vector2(4000, 40)
	bkshape.shape = bkrect
	bkshape.position = Vector2(0, -20)
	bk_floor.add_child(bkshape)
	bk_floor.position = Vector2(1920, 1896)  # 地板顶面 y=1856(row58 顶),覆盖 [-80,3920]
	bk_floor.collision_layer = 1
	bk_floor.collision_mask = 0
	root.add_child(bk_floor)
	var bk_scene: PackedScene = load("res://Scenes/Enemies/EnemyBlackBird.tscn")
	_check(bk_scene != null, "BlackBird 场景加载")
	var bk = bk_scene.instantiate()
	bk.global_position = Vector2(60, 57 * 32 + 16)  # 地板格(row57, 下方 row58 实心)
	root.add_child(bk)
	await physics_frame
	_check(bk.get_script() == load("res://Scenes/Enemies/enemy_black_bird.gd"), "BlackBird 实例类型")
	_check(bk.state == 0, "BlackBird 初始休眠")
	_check(bk.hp == 30, "BlackBird hp=30")
	_check(bk.contact_damage == 0, "BlackBird 无接触伤害")
	_check(bk.collision_layer == 4, "BlackBird 占层3")
	_check(is_equal_approx(bk.scale.x, 2.0), "BlackBird scale=2.0")
	_check(bk.get_node("AnimatedSprite2D").texture_filter == 1, "BlackBird 像素滤镜(nearest)")
	# 玩家远处 → 保持睡眠
	var bk_far := StubCombatPlayer.new()
	bk_far.global_position = Vector2(60, 200)
	root.add_child(bk_far)
	for _i in range(20):
		await physics_frame
	_check(bk.state == 0, "黑鸟玩家远处保持睡眠")
	bk_far.free()
	# 玩家接近 → 苏醒 → 游走(验证游走速度,再等瞬移判定)
	var bk_player := StubCombatPlayer.new()
	bk_player.global_position = Vector2(400, 57 * 32 + 16)
	root.add_child(bk_player)
	var bk_reached_wander := false
	var bk_wander_vx := 0.0
	for _i in range(120):
		await physics_frame
		if bk.state == 2:  # WANDER
			await physics_frame  # 转换帧速度还是旧的,多等一帧让 WANDER 分支设过速度
			bk_reached_wander = true
			bk_wander_vx = bk.velocity.x
			break
	_check(bk_reached_wander, "黑鸟进入游走")
	_check(absf(bk_wander_vx) == EnemyParams.BlackBird.wander_speed, "黑鸟游走速度")
	# 瞬移判定成功 → 起飞 → 落地 → 冲锋命中 6 伤(穿透无敌帧)
	var bk_sil_mat := bk.get_node("AnimatedSprite2D").material as ShaderMaterial
	var bk_reached_takeoff := false
	var bk_takeoff_jumping := false
	var bk_arrival_flashing := false
	var bk_got_hit := false
	for _i in range(360):
		await physics_frame
		if bk.state == 3:  # TAKE_OFF
			bk_reached_takeoff = true
			if bk.velocity.y < 0.0:
				bk_takeoff_jumping = true
		elif bk.state == 4:  # CHARGE(含瞬移后落地停顿)
			if bk_sil_mat != null and bk_sil_mat.get_shader_parameter("silhouette") > 0.5:
				bk_arrival_flashing = true
		if bk_player.hit_log.has(6):
			bk_got_hit = true
			break
	_check(bk_reached_takeoff, "黑鸟进入起飞动作")
	_check(bk_takeoff_jumping, "黑鸟起飞竖直上跳")
	_check(bk_arrival_flashing, "黑鸟瞬移后白闪(到达)")
	_check(bk_got_hit, "黑鸟冲锋命中玩家 6 伤")
	_check(bk.state == 5, "黑鸟命中后大后跳")  # BACK_HOP
	# 后跳落地 → 回游走
	var bk_wandered_again := false
	for _i in range(240):
		await physics_frame
		if bk.state == 2:
			bk_wandered_again = true
			break
	_check(bk_wandered_again, "黑鸟后跳落地回游走")
	# 玩家远离 → 入睡
	bk_player.global_position = Vector2(60, 3500)
	var bk_slept := false
	for _i in range(240):
		await physics_frame
		if bk.state == 0:
			bk_slept = true
			break
	_check(bk_slept, "黑鸟玩家远离入睡")
	bk_player.free()
	bk.free()
	# 死亡:白闪闪烁后销毁,物理与生前一致
	var bk_dead = bk_scene.instantiate()
	bk_dead.global_position = Vector2(300, 57 * 32 + 16)
	root.add_child(bk_dead)
	await physics_frame
	bk_dead.hurt(99, Vector2.RIGHT)
	_check(bk_dead.is_dead, "黑鸟受击死亡")
	var bk_died := false
	for _i in range(180):
		await physics_frame
		if not is_instance_valid(bk_dead):
			bk_died = true
			break
	_check(bk_died, "黑鸟死亡白闪后销毁")
	# 落点判定反例:理想落点区被整列墙堵死(无地板 + LOS 被挡) → 不瞬移,仍游走
	var bk2_grid: Array[Array] = []
	for _y in range(60):
		var row2_bk: Array[int] = []
		row2_bk.resize(120)
		row2_bk.fill(MazeGenerator.EMPTY)
		bk2_grid.append(row2_bk)
	for _x in range(120):
		bk2_grid[58][_x] = MazeGenerator.SOLID
	MazeGenerator.current_grid = bk2_grid
	var bk2 = bk_scene.instantiate()
	bk2.global_position = Vector2(60 * 32 + 16, 57 * 32 + 16)
	root.add_child(bk2)
	await physics_frame
	var bk2_player := StubCombatPlayer.new()
	bk2_player.global_position = Vector2(60 * 32 + 16, 57 * 32 + 16)
	root.add_child(bk2_player)
	# 玩家面朝右(默认 facing=1),理想落点 = 玩家格 − flank_distance/32 列;把整个搜索半径的列墙堵死
	var bk_ideal_x := posmod(60 - int(EnemyParams.BlackBird.flank_distance / 32), 120)
	var bk_radius := EnemyParams.BlackBird.flank_search_cells
	var bk_wall_c0 := posmod(bk_ideal_x - bk_radius, 120)
	for _c in range(bk_wall_c0, bk_wall_c0 + 2 * bk_radius + 1):
		for _y in range(58):
			bk2_grid[_y][posmod(_c, 120)] = MazeGenerator.SOLID
	MazeGenerator.current_grid = bk2_grid
	var bk_flanked := false
	for _i in range(240):
		await physics_frame
		if bk2.state == 3:  # TAKE_OFF
			bk_flanked = true
			break
	_check(not bk_flanked, "黑鸟背墙不瞬移(仍游走)")
	# 拆墙 → 应能瞬移
	for _c in range(bk_wall_c0, bk_wall_c0 + 2 * bk_radius + 1):
		for _y in range(58):
			bk2_grid[_y][posmod(_c, 120)] = MazeGenerator.EMPTY
	MazeGenerator.current_grid = bk2_grid
	var bk_flanked2 := false
	for _i in range(240):
		await physics_frame
		if bk2.state == 3:
			bk_flanked2 = true
			break
	_check(bk_flanked2, "黑鸟拆墙后可瞬移")
	bk2_player.free()
	bk2.free()
	# 落点清空判定(瞬移不穿墙):碰撞箱压到实心格返回 false
	var clr_grid: Array[Array] = []
	for _y in range(20):
		var row_clr: Array[int] = []
		row_clr.resize(40)
		row_clr.fill(MazeGenerator.EMPTY)
		clr_grid.append(row_clr)
	clr_grid[10][10] = MazeGenerator.SOLID  # 单墙
	MazeGenerator.current_grid = clr_grid
	var bk_clr = bk_scene.instantiate()
	root.add_child(bk_clr)
	await physics_frame
	_check(not bk_clr._body_clear_at(Vector2(10 * 32 + 16, 10 * 32 + 16)), "黑鸟落点压墙判定(墙内 false)")
	_check(bk_clr._body_clear_at(Vector2(5 * 32 + 16, 15 * 32 + 16)), "黑鸟落点压墙判定(空地 true)")
	bk_clr.free()
	bk_floor.free()
	MazeGenerator.current_grid = []

	# ── Task: 地图 spawn 元数据解析 ──
	_check(MazeGenerator.parse_spawn_metadata([
			"# demo_2", "# player 12 34",
			"# enemy jump_bird 100 50", "# enemy fly_bird 200 60",
			"00110"]).get("player") == Vector2i(12, 34),
			"parse_spawn_metadata: player 解析")
	var meta_enemies: Array = MazeGenerator.parse_spawn_metadata([
			"# enemy jump_bird 100 50", "# enemy fly_bird 200 60"]).get("enemies", [])
	_check(meta_enemies.size() == 2 and meta_enemies[0]["type"] == "jump_bird"
			and meta_enemies[0]["cell"] == Vector2i(100, 50)
			and meta_enemies[1]["type"] == "fly_bird",
			"parse_spawn_metadata: enemies 列表")
	_check(MazeGenerator.parse_spawn_metadata(["# 纯注释", "000"]).is_empty(),
			"parse_spawn_metadata: 无 spawn 指令返回空")
	_check(MazeGenerator.parse_spawn_metadata(
			["# player 12 34", "# player 56 78"]).get("player") == Vector2i(56, 78),
			"parse_spawn_metadata: player 最后一行生效")

	# ── Task: EnemySpawner.TYPES 从 enemies.json 加载 ──
	EnemySpawner.load_types()
	_check(EnemySpawner.TYPES.has("jump_bird") and EnemySpawner.TYPES.has("fly_bird")
			and EnemySpawner.TYPES.has("black_bird") and EnemySpawner.TYPES.size() == 3,
			"EnemySpawner.TYPES 从 enemies.json 加载(含 black_bird)")

	if _failures.is_empty():
		print("SMOKE OK")
		quit(0)
	else:
		printerr("FAILURES: " + str(_failures))
		quit(1)
