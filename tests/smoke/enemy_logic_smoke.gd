extends SceneTree

# 主冒烟:敌人 AI / 环面数学 / 武器参数与命中 / 碰撞层 / 寻路与 LOS / 多弹丸……
# 跑法:`"$GODOT" --headless --path . -s res://tests/smoke/enemy_logic_smoke.gd`,成功打印 SMOKE OK。
#
# ★ 结构(2026-09-15 阶段 5.1 拆分):本文件原先是一个 **737 净行**的 `_initialize()`
#   —— 全仓最长函数,而本文件又是全仓改动最频繁的文件。现按原有的章节注释切成 27 个
#   `_phase_*()`,`_initialize()` 只留**顺序**。
#
# ★ **顺序是契约,不是排版**:`_initialize` 里的调用次序 = 断言输出次序,也就是本文件的
#   回归基线(`ok - <名字>` 147 条 + `SMOKE OK`)。改顺序会让读者以为断言没跑,
#   而 `await` 的有无同样属于顺序契约 —— 漏一个 `await`,该节从 await 之后的断言就会
#   与后面的节**交错执行**(拆分时实测踩到过一次,靠输出序列当场发现)。
#   ★ 跨节的夹具/中间量提升为了脚本级字段(见下方声明),首次赋值位置原样没动。

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

# 跨节复用的夹具/中间量:拆 _initialize 时由局部提升为字段(阶段 5.1)。
# 每个的**首次赋值位置原样不动** —— 顺序不变,故断言顺序也不变。
var bscene: PackedScene = null
var player_scene: PackedScene = null
var jump2: PackedScene = null
var fb_scene: PackedScene = null
var e = null
var bullet_script = null
var combat = null
var sg_scene: PackedScene = null

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)


# ── 从 EnemySpawner 搬来的测试夹具(2026-09-14,死代码清理)──
# 原先它是 `EnemySpawner.sample_spawn_cells`(生产侧):但**单机敌人早已改从地图元数据布点**
# (`MazeGenerator.load_spawns()` → `spawner.spawn_all(spawns)`,地图里没有 `# enemy` 就是 0 只),
# 它成了零调用者的死函数 —— 而它留在生产侧会让人误以为「敌人是运行时随机的」。
# 它压的算法(地板格 + 环面最小距离采样)本身仍有效,且与 `RoyaleHost.plan_spawns` / `MatchHost`
# 的散点逻辑同族,故**搬到测试侧做参考实现**继续被压,而不是连同下面 5 条断言一起删掉。
# 地板格 = EMPTY 且正下方(y+1,环面取模)非 EMPTY:敌人站立/落地要有实心表面托底。
func _sample_spawn_cells(grid: Array[Array], player_cell: Vector2i,
		count: int, min_dist_cells: int) -> Array[Vector2i]:
	var rows := grid.size()
	var cols := grid[0].size()
	var floor_cells: Array[Vector2i] = []
	for y in range(rows):
		for x in range(cols):
			if grid[y][x] == MazeGenerator.EMPTY and TileDefs.is_blocked(grid[posmod(y + 1, rows)][x]):
				floor_cells.append(Vector2i(x, y))
	var chosen: Array[Vector2i] = []
	var pool: Array[Vector2i] = floor_cells.duplicate()
	var attempts := pool.size() * 4
	while chosen.size() < count and attempts > 0 and not pool.is_empty():
		attempts -= 1
		var i := randi() % pool.size()
		var cand := pool[i]
		if MazeGenerator.toroidal_dist(cand, player_cell, cols, rows) >= min_dist_cells:
			chosen.append(cand)
			pool.remove_at(i)
	return chosen


func _initialize() -> void:
	# 本函数只留**顺序**:每节一个 _phase_*,按原有先后调用 —— 顺序本身是契约
	# (断言顺序 = 输出顺序 = 基线 oracle)。
	_phase_pure_helpers()
	_phase_spawn_metadata_player2()
	_phase_enemy_base_load()
	await _phase_enemy_instantiate()
	await _phase_bullet_free()
	_phase_clamp_pitch()
	_phase_toroidal_anchor()
	_phase_pin_map()
	_phase_map_size()
	_phase_v3_roundtrip()
	_phase_old_format_convert()
	await _phase_weapon_stats_and_hit()
	_phase_buffered_fire()
	_phase_preview_arc_probe()
	await _phase_equip_switch()
	await _phase_collision_layers()
	_phase_astar_los()
	await _phase_enemy_bullet_arc()
	await _phase_contact_damage_guard()
	await _phase_flybird_basics()
	await _phase_flybird_charge_return()
	await _phase_astar_flat_cache()
	await _phase_explosion_knockback()
	await _phase_player_knockback()
	await _phase_flybird_deadzone()
	_phase_spawn_metadata_parse()
	_phase_enemy_types_json()
	await _phase_collision_aabb()   # ★ 追加在**末尾**:既有 27 节的顺序是回归基线,不插队
	_phase_weapon_registry()        # ★ 同上,只追加在末尾
	_phase_spread_cells()           # ★ 同上,只追加在末尾
	_phase_weapon_capacity()        # ★ 同上,只追加在末尾

	if _failures.is_empty():
		print("SMOKE OK")
		quit(0)
	else:
		printerr("FAILURES: " + str(_failures))
		quit(1)



# ── Task 2: 纯函数 ──
func _phase_pure_helpers() -> void:
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
	var cells := _sample_spawn_cells(grid, Vector2i(0, 0), 5, 3)
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


# ── Task 4: 双出生点解析(# player2)──
func _phase_spawn_metadata_player2() -> void:
	var meta := MazeGenerator.parse_spawn_metadata(["# player2 3 4"])
	_check(meta.get("player2") == Vector2i(3, 4), "player2 spawn 解析")
	var meta2 := MazeGenerator.parse_spawn_metadata(["# player 1 2", "# player2 5 6"])
	_check(meta2.get("player") == Vector2i(1, 2) and meta2.get("player2") == Vector2i(5, 6), "player+player2 并存")


# ── Task 3: EnemyBase 加载 ──
func _phase_enemy_base_load() -> void:
	_check(load("res://scenes/enemies/enemy_base.gd") != null, "EnemyBase 脚本加载")


# ── Task 4: 敌人实例化 ──
func _phase_enemy_instantiate() -> void:
	var scene: PackedScene = load("res://scenes/enemies/enemy_jump_bird.tscn")
	_check(scene != null, "JumpBird 场景加载")
	e = scene.instantiate()
	root.add_child(e)
	await physics_frame
	_check(e.get_script() == load("res://scenes/enemies/enemy_jump_bird.gd"), "JumpBird 实例类型")
	const SLEEP_STATE := 0
	_check(e.get("state") == SLEEP_STATE, "初始休眠状态")
	_check(e.is_in_group("enemies"), "加入 enemies 组")
	_check(e.get_node_or_null("ContactArea") != null, "ContactArea 创建")


# ── Task 6: 子弹 ──
func _phase_bullet_free() -> void:
	# 清掉 Task 4 遗留的敌人(在原点,碰撞层3);否则子弹出生即命中并立即消失
	e.free()
	bscene = load("res://scenes/weapons/bullet.tscn")
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
func _phase_clamp_pitch() -> void:
	# 用 load()+资源调用,避免 -s 编译期解析 WeaponBase 时连带预加载 bullet_base.gd
	# (autoload 实例变量在 -s 主脚本编译期不可解析,见 bullet_base.gd 的 GameParameters.MAP_WIDTH)。
	var wb := load("res://scenes/weapons/weapon_base.gd")
	_check(wb != null, "WeaponBase 脚本加载")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(1, 0), 1), 0.0), "pitch 水平")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(0, -1), 1), -deg_to_rad(45.0)), "pitch 上钳制")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(0, 1), 1), deg_to_rad(45.0)), "pitch 下钳制")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(-1, 0), 1), deg_to_rad(45.0)), "pitch 身后钳制")
	_check(is_equal_approx(wb.clamp_pitch(Vector2(0, 1), -1), deg_to_rad(45.0)), "pitch 左朝向")


# ── Task 8: 环面锚定(敌人/子弹跟随主角取模) ──
func _phase_toroidal_anchor() -> void:
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


# ── Task 2: 钉住地图 ──
func _phase_pin_map() -> void:
	MazeGenerator.set_map_file("res://maps/demo.cyrm")
	_check(MazeGenerator.map_file_path() == "res://maps/demo.cyrm", "set_map_file 钉住地图")


# ── Task 9: 地图尺寸读取(map_size) ──
func _phase_map_size() -> void:
	# ★ 期望值**从地图自己派生**,不写死 125×75("这张图恰好多大"换图就假红)。
	#   取自 `MazeGenerator.load_map_file()` 的**整图解析维度** —— 刻意**不用**
	#   `MapFormat.map_size`:`MazeGenerator.map_size()` 就是它的一行转发(同一函数 ⇒ 自证)。
	#   两条读法各走一路(v4 头部 vs 整图解析),对不上才是真 bug。
	#   顺带仍钉住"会话选中的是哪张图"这件事(`_phase_pin_map` 刚把它钉成 demo)。
	var g := MazeGenerator.load_map_file()
	var want := Vector2i.ZERO
	if not g.is_empty():
		want = Vector2i((g[0] as Array).size(), g.size())
	_check(MazeGenerator.map_size() == want,
			"map_size: 与整图解析的维度一致(实为 %s,期望 %s)" % [str(MazeGenerator.map_size()), str(want)])


# ── v3 解析 round-trip(纹理 3 位 0xx + 形状 hex)──
func _phase_v3_roundtrip() -> void:
	var v3_rows := MapFormat.serialize_v3_grid([[0, 31, 49], [31, 0, 0]])
	_check(v3_rows[0] == "0000001F0031", "serialize_v3_grid: 空气/全砖/纹理3左上1/4")
	_check(v3_rows[1] == "001F00000000", "serialize_v3_grid: 第2行")
	_check(MapFormat.parse_v3_grid(v3_rows) == [[0, 31, 49], [31, 0, 0]], "v3 网格 round-trip")


# ── 旧格式自动转换(2×2→1,掩码+纹理)──
func _phase_old_format_convert() -> void:
	var old2 := [[0, 1], [1, 0]]
	var conv := MapFormat.convert_old_grid(old2)
	_check(conv == [[1 * 16 + 6]], "旧 2×2(右上+左下)→ 形状6 纹理1")   # 1<<1|1<<2 = 6
	var old4 := [[1, 1], [1, 1]]
	_check(MapFormat.convert_old_grid(old4) == [[31]], "旧 2×2 全实心 → 全砖 31")
	var old_mixed := [[3, 0], [7, 0]]
	_check(MapFormat.convert_old_grid(old_mixed) == [[3 * 16 + 5]], "旧混合纹理取首个实体(左上 3 → 纹理3; 左上+左下 → 形状5)")


# ── Task: 武器场景参数 + 开火命中 ──
func _phase_weapon_stats_and_hit() -> void:
	var stub := StubPlayer.new()
	root.add_child(stub)
	stub.global_position = Vector2(400, 400)
	var pistol: PackedScene = load("res://scenes/weapons/pistol_test.tscn")
	var rifle: PackedScene = load("res://scenes/weapons/rifle_test.tscn")
	var sniper: PackedScene = load("res://scenes/weapons/m82a1.tscn")
	_check(pistol != null and rifle != null and sniper != null, "三把武器场景加载")
	var w = pistol.instantiate()
	stub.add_child(w)
	w.equip(stub)
	# 避免 -s 静态引用 WeaponBase(编译期连带预加载 bullet_base.gd 引用 autoload
	# 实例变量 GameParameters.MAP_WIDTH,而 -s 阶段 autoload 尚未实例化)→ 用运行时
	# load()+脚本比较代替 is WeaponBase。
	_check(w.get_script() == load("res://scenes/weapons/weapon_base.gd"), "武器继承 WeaponBase")
	_check(w.weapon_name == "Pistol", "手枪参数")
	# 2026-09-20 用户调参:射程 900 → 1100,并**新增** `spread_deg = 0.4`(此前该 tscn 里没有这个 export,
	# 单弹丸武器同样吃散布 —— `weapon_base._spawn_projectiles` 每发都做 `randf_range(-s, s)`)。
	# 射程/散布在本文件里**只**由本档钉(后面的多弹丸/爆炸阶段不碰它们,那两把枪的 tscn 改动
	# 否则会**零覆盖**地过去)。
	# 2026-09-21 用户调参(同批两件事,一起改):腰射散布 0.4 → 0.6、**射程 1100 → 1400**。
	# 步枪同批 0.6 → 0.8 / 1400 → 1600;霰弹 4.0 → 3.0 / 700 → 1100(见下面各自那一档)。
	_check(is_equal_approx(w.bullet_range, 1400.0) and is_equal_approx(w.spread_deg, 0.6),
			"手枪射程1400/±0.6°")
	var e_scene: PackedScene = load("res://scenes/enemies/enemy_jump_bird.tscn")
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
	bullet_script = load("res://scenes/weapons/bullet_base.gd")
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
	sg_scene = load("res://scenes/weapons/s686.tscn")
	_check(sg_scene != null, "霰弹枪场景加载")
	var sg = sg_scene.instantiate()  # 无类型:访问自定义属性需要动态分派(项目惯例)
	# 2026-09-21 用户调参:散布 4.0 → 3.0、射程 700 → 1100(全中伤害仍是 5×8=40,见下一条)。
	# ★ 霰弹射程仍是三把里最短的(1100 < 手枪 1400 < 步枪 1600)—— 近战性格靠这一档保住。
	_check(sg.pellet_count == 8 and is_equal_approx(sg.spread_deg, 3.0), "霰弹枪 8 丸 ±3°")
	_check(sg.damage == 5 and is_equal_approx(sg.bullet_range, 1100.0), "霰弹枪单丸5伤/射程1100")
	# 全中伤害 = damage × pellet_count —— 用户 2026-09-20 选的就是"全中 40"那一档
	# (能红的实现:单独改 damage 或 pellet_count 而没重算这一档 —— 两者各自看着都"合理")
	_check(int(sg.damage) * int(sg.pellet_count) == 40, "霰弹枪全中伤害应为 40(5×8)")
	_check(sg.tier == 0, "霰弹枪轻武器")
	sg.queue_free()

	# 步枪:2026-09-20 用户调参(射程 1100 → 1400,并**新增** `spread_deg = 0.6`)。
	# 本档是它射程/散布的唯一守卫(该场景在本文件里此前只是"能加载",从未被实例化)。
	# 2026-09-21 用户调参:腰射散布 0.6 → 0.8、**射程 1400 → 1600**(与手枪同一批)。
	var rf = rifle.instantiate()
	_check(is_equal_approx(rf.bullet_range, 1600.0) and is_equal_approx(rf.spread_deg, 0.8),
			"步枪射程1600/±0.8°")
	rf.queue_free()


# ── Task: 缓冲开火(冷却>0.5 武器,最后 20% 按开火→冷却结束自动打)──
func _phase_buffered_fire() -> void:
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
	# 武器帧逻辑已从 idle _process 挪到所属 Player 的物理 tick(tick());stub 无 Player 驱动,
	# 这里模拟每物理帧驱动 tick() 推进冷却,验证冷却结束自动开火。fire() 会把冷却重新拉满,
	# 故「tick 后冷却反而变大」= 已自动打出一次。
	for i in range(60):
		if not is_instance_valid(buf_w):
			break
		var prev_cd: float = buf_w.fire_cd_timer
		buf_w.tick(1.0 / 60.0)
		if buf_w.fire_cd_timer > prev_cd:
			break
	var bf_after := 0
	for child in root.get_children():
		if child.get_script() == bullet_script:
			bf_after += 1
	_check(bf_after == bf_before + buf_w.pellet_count, "冷却结束自动开火")
	buf_w.queue_free()
	buf_stub.free()


# ── Task: 预瞄算子弹碰撞体积(小球判墙,中心点不穿但体积擦墙即截断)──
func _phase_preview_arc_probe() -> void:
	var gl_scene: PackedScene = load("res://scenes/weapons/grenade_launcher.tscn")
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
func _phase_equip_switch() -> void:
	player_scene = load("res://scenes/player/player.tscn")
	_check(player_scene != null, "Player 场景加载")
	var p = player_scene.instantiate()
	root.add_child(p)
	await physics_frame
	# ★ 2026-09-15(背包化):单机现在**开局空手**(武器散落在地图上,由 Level0 铺)。
	#   本节测的是"切枪/冷却继承"这件事,与开局带不带枪无关 —— 显式摆一个已知背包。
	_check(p.weapons._weapon == null, "开局空手(单机初始背包为空)")
	p.weapons.set_initial_inventory([1, 2])
	await physics_frame
	_check(p.weapons._weapon != null, "set_initial_inventory 后装备第一把")
	if p.weapons._weapon != null:
		_check(p.weapons._weapon.weapon_name == "Pistol", "默认武器是手枪")
		p.weapons.equip_type(2)   # 步枪(WEAPONS 注册表槽 2;组件化后按槽键,不再传场景路径)
		await physics_frame
		_check(p.weapons._weapon.weapon_name == "Rifle", "切枪到步枪")
		# 切枪冷却继承:旧武器剩余冷却不能被切枪刷掉。
		# equip_type() 同步执行,不 await(否则 _process 已扣掉一帧冷却)。
		p.weapons._weapon.fire_cd_timer = 0.7
		p.weapons.equip_type(1)
		_check(is_equal_approx(p.weapons._weapon.fire_cd_timer, 0.7), "切枪继承剩余冷却")
	p.free()


# ── Task 1: 碰撞层重构(敌人层3, 玩家子弹不打玩家)──
func _phase_collision_layers() -> void:
	jump2 = load("res://scenes/enemies/enemy_jump_bird.tscn")
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
	combat = StubCombatPlayer.new()
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


# ── Task 2: MazeGenerator A* + LOS ──
func _phase_astar_los() -> void:
	var g: Array[Array] = []
	for _y in range(20):
		var row: Array[int] = []
		row.resize(20)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	MazeGenerator.current_grid = g
	# 全通网格上的基本契约:不含起点、含终点(原 BFS 版断言,随 BFS 删除移植到 A*)
	var pth := MazeGenerator.astar_path_nearest(Vector2i(2, 2), Vector2i(5, 6))
	_check(not pth.is_empty() and pth[-1] == Vector2i(5, 6), "A* 全通网格有路")
	_check(pth[0] != Vector2i(2, 2), "A* 路径不含起点")
	# 两条整行墙(第 4/14 行)把环面切成隔离带;跨带必经墙行,才算"隔断"。
	# 3 格短墙在环面上有绕行路,不能证明隔断。
	for x in range(20):
		g[4][x] = MazeGenerator.SOLID
		g[14][x] = MazeGenerator.SOLID
	# 可达直达 / 墙带隔断降级 / 同格空
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
func _phase_enemy_bullet_arc() -> void:
	var bscene_e: PackedScene = load("res://scenes/enemies/enemy_bullet.tscn")
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
func _phase_contact_damage_guard() -> void:
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
func _phase_flybird_basics() -> void:
	var fb_grid: Array[Array] = []
	for _y in range(150):
		var row3: Array[int] = []
		row3.resize(300)
		row3.fill(MazeGenerator.EMPTY)
		fb_grid.append(row3)
	MazeGenerator.current_grid = fb_grid
	fb_scene = load("res://scenes/enemies/enemy_fly_bird.tscn")
	_check(fb_scene != null, "FlyBird 场景加载")
	var fb := fb_scene.instantiate()
	fb.global_position = Vector2(488, 1208)
	root.add_child(fb)
	await physics_frame
	_check(fb.get_script() == load("res://scenes/enemies/enemy_fly_bird.gd"), "FlyBird 实例类型")
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
	var eb_script := load("res://scenes/enemies/enemy_bullet.gd")
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
func _phase_flybird_charge_return() -> void:
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
func _phase_astar_flat_cache() -> void:
	# 大网格(demo 全尺寸)上跑 A*:不崩、路径逐格相邻且在界内(扁平数组索引正确)。
	var big_grid := MazeGenerator.load_map_file()
	MazeGenerator.current_grid = big_grid
	var far := MazeGenerator.astar_path_nearest(Vector2i(10, 10), Vector2i(110, 60))
	var far_valid := true
	var prev_cell := Vector2i(10, 10)
	for c in far:
		if c.x < 0 or c.x >= 125 or c.y < 0 or c.y >= 75:
			far_valid = false
			break
		var dxc := absi(c.x - prev_cell.x)
		var dyc := absi(c.y - prev_cell.y)
		dxc = mini(dxc, 125 - dxc)
		dyc = mini(dyc, 75 - dyc)
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
	var calls0: int = GridPathfinder.astar_calls
	fb_cache._repath_to(Vector2i(40, 20))
	var calls1: int = GridPathfinder.astar_calls
	_check(calls1 - calls0 == 1, "首次 repath 跑一次 A*")
	fb_cache._repath_to(Vector2i(40, 20))
	_check(GridPathfinder.astar_calls - calls1 == 0, "同目标且路径未空 → 缓存命中跳过 A*")
	fb_cache._repath_to(Vector2i(41, 20))
	_check(GridPathfinder.astar_calls - calls1 == 1, "目标变化 → 重跑 A*")
	fb_cache._repath_to(Vector2i(41, 20))
	_check(GridPathfinder.astar_calls - calls1 == 1, "同目标再跳一次")
	fb_cache.free()
	MazeGenerator.current_grid = []


# ── 爆炸独立击退向量(大冲击+迅速衰减)vs 枪击叠加 ──
func _phase_explosion_knockback() -> void:
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
func _phase_player_knockback() -> void:
	var pk := player_scene.instantiate()
	pk.global_position = Vector2(1000, 400)
	root.add_child(pk)
	await physics_frame
	pk.take_hit(Vector2(800, 400), 5, false, 800.0)
	_check(is_equal_approx(pk.combat.knock_velocity.x, 800.0), "玩家爆炸击退设独立向量")
	var pk0: float = pk.combat.knock_velocity.x
	for i in range(5):
		await physics_frame
	_check(pk.combat.knock_velocity.x < pk0, "玩家击退向量随帧衰减")
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
	_check(pk2.combat.knock_velocity.y > 0.0, "上方爆炸击退向量向下(+y)")
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
	_check(pd.combat.downed, "玩家倒地")
	_check(pd.combat.knock_velocity.x > 0.0, "倒地保留击退向量(未清零)")
	var pd0: float = pd.combat.knock_velocity.x
	for i in range(5):
		await physics_frame
	_check(pd.combat.knock_velocity.x < pd0, "倒地击退向量随帧衰减(物理未取消)")
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
func _phase_flybird_deadzone() -> void:
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


# ── Task: 地图 spawn 元数据解析 ──
func _phase_spawn_metadata_parse() -> void:
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
func _phase_enemy_types_json() -> void:
	EnemySpawner.load_types()
	_check(EnemySpawner.TYPES.has("jump_bird") and EnemySpawner.TYPES.has("fly_bird")
			and EnemySpawner.TYPES.has("black_bird") and EnemySpawner.TYPES.size() == 3,
			"EnemySpawner.TYPES 从 enemies.json 加载(含 black_bird)")

	# ── 反方向:scenes/enemies 下的**敌人** .tscn 必须都在 enemies.json 里(2026-09-29)──
	# 与 §武器注册表 的 ⑧ 同款、同理由(`data/enemies.json` → `scenes/enemies/` 那一半
	# 一直有:`_load_registry` 逐条收 `scene`,而反向靠人眼)。判据同样是**根脚本链**,
	# 不是目录清单 —— 该目录里另有 `enemy_bullet.tscn`(根脚本 `enemy_bullet.gd` extends
	# `BulletBase`),它不是敌人、本来就不该进 enemies.json。
	var ebase: GDScript = load("res://scenes/enemies/enemy_base.gd")
	_check(ebase != null, "enemy_base.gd 可加载(反方向覆盖判据依赖它)")
	var e_registered: Dictionary = {}
	for eid in EnemySpawner.TYPES:
		e_registered[str(EnemySpawner.TYPES[eid])] = str(eid)
	var e_orphans: Array = []
	for p in ScanUtil.collect(["res://scenes/enemies"]):
		if not p.ends_with(".tscn"):
			continue
		if not _script_extends(_root_script_of(p), ebase):
			continue
		if not e_registered.has(p):
			e_orphans.append(p)
	_check(e_orphans.is_empty(),
			"scenes/enemies/ 下的敌人场景必须都在 data/enemies.json 里(漏登记的是 %s)" % str(e_orphans))


# ── CollisionAabb:必须认出 CollisionPolygon2D(本作**所有**身体都用它)──
# 2026-09-15:原先 `has_any`/`world_rect` 只认 `child is CollisionShape2D`,而 Godot 4 里
# CollisionPolygon2D 与它是**并列类**(都直接继承 Node2D,不是子类关系;该文件里那句
# "CollisionPolygon2D 继承自 CollisionShape2D" 的注释是错的,已一并改正)。
# 后果不是"少算一点":敌人/玩家的身体几何**一律读不到**,三个调用方静默走兜底 ——
# 激光的判定框恒为「原点周围 36×36」(和身体大小/位置无关,实测扫偏移量 ±16 命中、
# ±24 不中),water 的脚底偏移恒 24px,飞鸟避障恒 40×40。这一节把该语义钉死。
func _phase_collision_aabb() -> void:
	var host := Node2D.new()
	root.add_child(host)
	var poly := CollisionPolygon2D.new()
	# 故意不对称:上边 -10、下边 +30 —— 中心不在原点,与敌人场景同款
	poly.polygon = PackedVector2Array([
			Vector2(-20, -10), Vector2(20, -10), Vector2(20, 30), Vector2(-20, 30)])
	host.add_child(poly)
	host.global_position = Vector2(500, 500)
	_check(CollisionAabb.has_any(host), "CollisionAabb 认出启用的 CollisionPolygon2D")
	var wr: Rect2 = CollisionAabb.world_rect(host)
	_check(wr.size == Vector2(40, 40), "多边形世界 AABB 尺寸(实际 %s)" % str(wr.size))
	_check(is_equal_approx(wr.position.y, 490.0),
			"多边形世界 AABB 保留原点偏移(实际 y=%.1f,错法是恒等于原点 y)" % wr.position.y)
	host.scale = Vector2(2.5, 2.5)     # 敌人 tscn 就是 2.5x
	_check(CollisionAabb.world_rect(host).size == Vector2(100, 100),
			"多边形 AABB 跟随节点缩放(实际 %s)" % str(CollisionAabb.world_rect(host).size))
	host.scale = Vector2.ONE
	poly.disabled = true                # 姿态箱切换语义:禁用中的不算
	_check(not CollisionAabb.has_any(host), "禁用中的多边形不算碰撞体")
	host.free()

	# 真实敌人:身体 AABB 必须远大于激光的兜底 36×36,且中心不在原点
	var e: Node2D = load("res://scenes/enemies/enemy_jump_bird.tscn").instantiate()
	root.add_child(e)
	await physics_frame
	var er: Rect2 = CollisionAabb.world_rect(e)
	_check(er.size.y > 60.0,
			"跳鸟身体 AABB 高度 %.1f —— 不该是激光兜底的 36" % er.size.y)
	_check(absf(er.get_center().y - e.global_position.y) > 4.0,
			"跳鸟身体 AABB 中心偏离原点 %.1f px(以原点为中心的写法会丢掉这个偏移)"
					% absf(er.get_center().y - e.global_position.y))
	e.free()


# ── 「注册表 json ↔ 场景目录」双向覆盖用的两个小工具(2026-09-29)──
# ★★ 为什么必须有**反方向**那一条:json → tscn 是覆盖到的(逐条 load 每个 json 的 scene),
#   而 **tscn → json 零守卫** —— 往 `scenes/weapons/` 放一个新武器场景而不写 json 条目,
#   那一把枪在菜单/散落/图标/HUD 名字里**全都不存在**,而当时三条相关测试(enemy_logic_smoke /
#   level0_weapon_scatter_probe / kh_l3_probe)**全部全绿、一条断言都不红**。
#
# `scene_path` 的**根节点脚本**(读 `PackedScene.get_state()` 的节点属性,**不实例化**)。
# 读不到(场景缺失/无根/根无 script)返回 null。
func _root_script_of(scene_path: String) -> Script:
	var ps: PackedScene = load(scene_path)
	if ps == null:
		return null
	var st := ps.get_state()
	if st == null or st.get_node_count() == 0:
		return null
	# 节点 0 = 根(引擎侧 `nodes[0]` 就是根,见 packed_scene.cpp 的 instantiate)。
	for i in st.get_node_property_count(0):
		if str(st.get_node_property_name(0, i)) != "script":
			continue
		var v: Variant = st.get_node_property_value(0, i)
		if v is Script:
			return v
		if v is String:
			return load(v) as Script
	return null


# 脚本 `scr` 是否**继承自** `base_scr`(沿 `get_base_script()` 链走,含自身)。
# ★ 走脚本链而不是「读 .tscn 文本里有没有 `weapon_base.gd`」:后者认不出
#   `extends LaserWeaponBase` 这种**间接**继承(laser_gun 就是),而它恰恰是"加新武器"的常见形状;
#   文本法还会被注释/别处的路径字符串喂绿。
func _script_extends(scr: Script, base_scr: Script) -> bool:
	var s := scr
	while s != null:
		if s == base_scr:
			return true
		s = s.get_base_script()
	return false


# 宿主函数体是否"取到了注册表的 id":直接出现 `all_ids(`;否则看它调用的**本文件内**函数里
# 有没有一层 `all_ids(`(只追一层 —— 避免把无关的调用链拉进来、也避免自引用死循环)。
# 判据问的是"这处被动地问了注册表",不钉调用链的形状(直接调 / 经一层 helper 都算数)。
func _body_reaches_registry_ids(whole: String, body: String, self_name: String) -> bool:
	if body.contains("all_ids("):
		return true
	var re := RegEx.create_from_string("\\b([A-Za-z_]\\w*)\\s*\\(")
	for m in re.search_all(body):
		var hname := m.get_string(1)
		if hname == self_name:
			continue
		if ScanUtil.func_body(whole, hname).contains("all_ids("):
			return true
	return false


const REGISTRY_SRC := "res://core/sim/weapon_registry.gd"
const REGISTRY_JSON := "res://data/weapons.json"
# json 的 tier 字符串 → 数值。★ 这是**探针自己**的一份口径,刻意不引注册表 ——
#   本相要在"注册表文件还不存在"时也跑得出干净的断言(见下面 wr 的取法)。
#   它与 WeaponBase.Tier 的对齐由本相 ③ 钉着。
const TIER_STRINGS := {"light": 0, "medium": 1, "heavy": 2}


# ── 武器注册表单一来源(data/weapons.json,2026-09-25)──
# 旧口径(三张 GDScript 常量表)下,加新武器时漏填的表现各不相同:
#   WEAPONS 漏 → 切枪时 load("") 报错(响);DISPLAY_NAMES 漏 → HUD 显示空(看得见);
#   TIERS 漏 → **容量算错**(轻武器被当成重武器,8 格只能带两把),完全不报错。
# 现在三样都在**同一份 json 的同一行**里,结构性地不可能漏一半;但"改了 json 忘了改
# tscn 的 tier export"仍然可能(两份数据刻意重复,与 `data/enemies.json` 同构),故逐条比。
#
# ★★ 为什么用 `load()` 拿到 GDScript 再调它的**静态函数**,而不直接写 `WeaponRegistry.xxx()`:
#   本文件是 `-s` 冒烟,而**全局类名在文件不存在时会让整个脚本 Parse Error** ⇒ 一条断言都
#   跑不到、进程挂死(`-s` 脚本抛错走不到 quit(),本仓踩过)。`load()` + 空守卫让"文件还没建"
#   表现为**干净的红**,而不是超时。
#   ★ 静态函数**可以**在 GDScript 对象上调:引擎 `modules/gdscript/gdscript.cpp:928-940` 的
#   `GDScript::callp` 就是查 `member_functions` 并 `ERR_FAIL` 掉非 static 的那一个。
func _phase_weapon_registry() -> void:
	var wc: GDScript = load("res://scenes/player/weapon_component.gd")
	var wi: GDScript = load("res://core/sim/weapon_inventory.gd")
	var wb: GDScript = load("res://scenes/weapons/weapon_base.gd")
	_check(wc != null and wi != null and wb != null, "武器注册表三件套可加载")
	if wc == null or wi == null or wb == null:
		return

	# ── ① 注册表文件到位 ──
	var json_text := FileAccess.get_file_as_string(REGISTRY_JSON)
	_check(not json_text.is_empty(), "读得到 " + REGISTRY_JSON + "(读不到 = 文件还没建)")
	var wr: GDScript = null
	if ResourceLoader.exists(REGISTRY_SRC):
		wr = load(REGISTRY_SRC)
	_check(wr != null, "core/sim/weapon_registry.gd 存在且可加载")

	# ── ② json ↔ 各 .tscn 的 tier export ↔ 枚举值(逐条对账)──
	var rows := {}   # id -> {name, tier, scene}
	if not json_text.is_empty():
		var parsed: Variant = JSON.parse_string(json_text)
		var ok_shape := typeof(parsed) == TYPE_DICTIONARY and (parsed.get("weapons", []) is Array)
		_check(ok_shape, "weapons.json 顶层是 {\"weapons\": [...]}")
		if ok_shape:
			for raw in parsed["weapons"]:
				if typeof(raw) != TYPE_DICTIONARY:
					_check(false, "每条都应是对象(实际 %s)" % str(raw))
					continue
				var e: Dictionary = raw
				# ★ 用 `int(...)` 归一化:JSON 的数字在 GDScript 里解析成 float,
				#   不归一化的话 `rows.has(id)` 会永远假(1.0 != 1),而 `row.size()` 却是对的 ——
				#   那种"一半对一半错"最难查。
				var id := int(e.get("id", 0))
				var tier_s := str(e.get("tier", ""))
				var scene_path := str(e.get("scene", ""))
				var wname := str(e.get("name", ""))
				_check(id > 0, "id 是正整数(实际 %s)" % str(e.get("id")))
				_check(not rows.has(id), "id %d 不重复" % id)
				_check(not wname.is_empty(), "id %d 有 name" % id)
				_check(TIER_STRINGS.has(tier_s), "id %d 的 tier 是三值之一(实际 \"%s\")" % [id, tier_s])
				var tscene: PackedScene = load(scene_path)
				_check(tscene != null, "id %d 的 scene 能 load(%s)" % [id, scene_path])
				if tscene != null:
					var inst: Node = tscene.instantiate()
					var want_tier := int(TIER_STRINGS.get(tier_s, -1))
					_check(int(inst.tier) == want_tier,
							"id %d:tscn 的 tier(%d)必须等于 json 的 \"%s\"(%d)" % [
								id, int(inst.tier), tier_s, want_tier])
					inst.free()
				rows[id] = {"name": wname, "tier": tier_s, "scene": scene_path}
	# ★ 这一条**放在 if 外面**:json 文件缺席时它也要红(否则"文件没建"这件事只有上面
	#   那一条在报,而"json 建了但一条都不合格"这条路径就没有守卫)。
	_check(rows.size() > 0, "json 至少有 1 条合格条目(实际 %d)" % rows.size())

	# ── ③ 注册表的查询结果 == 上面那份 json(防"json 对、注册表映射写错")──
	if wr != null:
		var reg_ids: Array = wr.all_ids()
		_check(reg_ids.size() == rows.size(),
				"注册表条数应等于 json 合格条数(%d vs %d)" % [reg_ids.size(), rows.size()])
		for id in rows:
			var r: Dictionary = rows[id]
			_check(int(wr.tier_of(int(id))) == int(TIER_STRINGS[r["tier"]]),
					"tier_of(%d) 应 = %d(实际 %d)" % [id, int(TIER_STRINGS[r["tier"]]), int(wr.tier_of(int(id)))])
			_check(str(wr.scene_of(int(id))) == str(r["scene"]),
					"scene_of(%d) 应 = %s(实际 %s)" % [id, str(r["scene"]), str(wr.scene_of(int(id)))])
			_check(str(wr.name_of(int(id))) == str(r["name"]),
					"name_of(%d) 应 = %s(实际 %s)" % [id, str(r["name"]), str(wr.name_of(int(id)))])
			_check(wr.has(int(id)), "has(%d) 为真" % id)
			_check(not wr.has(int(id) + 9000), "has(%d) 为假(越界 id 不该命中)" % (int(id) + 9000))
		var want_map := {}
		for id in rows:
			want_map[id] = int(TIER_STRINGS[(rows[id] as Dictionary)["tier"]])
		var got_map: Dictionary = wr.tiers_map()
		var map_ok := got_map.size() == want_map.size()
		for id in want_map:
			if int(got_map.get(id, -1)) != int(want_map[id]):
				map_ok = false
		_check(map_ok, "tiers_map() 与 json 逐条一致(实际 %s、期望 %s)" % [str(got_map), str(want_map)])

	# ── ④ WeaponInventory 的 tier 常量与 WeaponBase.Tier 数值对齐(旧版原有,一处没动)──
	#    (wi 刻意不 import weapon_base,所以这条对齐是**约定**而不是编译器保证的。
	#     WeaponRegistry.TIER_NAMES 直接复用 wi.TIER_*,故本相 ③ 的比对已覆盖它。)
	_check(int(wi.TIER_LIGHT) == int(wb.Tier.LIGHT), "TIER_LIGHT 与 WeaponBase.Tier.LIGHT 对齐")
	_check(int(wi.TIER_MEDIUM) == int(wb.Tier.MEDIUM), "TIER_MEDIUM 与 WeaponBase.Tier.MEDIUM 对齐")
	_check(int(wi.TIER_HEAVY) == int(wb.Tier.HEAVY), "TIER_HEAVY 与 WeaponBase.Tier.HEAVY 对齐")
	# ★ 下面两条**原样保留**(旧版 `:1158-1159`)。它们是"容量 8 / 把数上限 4 是游戏规则"
	#   的钉子 —— 2026-09-25 按容量/把数可配那份计划改成读默认值常量(见下)。
	# ★ 原先是 `int(wi.MAX_WEAPONS)` / `int(wi.CAPACITY)` 直取属性 —— 常量改名成字段之后
	#   那是运行时错,而本文件是 -s 冒烟 ⇒ 错在 helper 里"该函数当场结束、调用方继续"
	#   ⇒ 后面断言被静默跳过、一个字都不出现,而裁决行照打(**假绿**——
	#   只有"逐条比名字/条数"才拦得住)。故走常量表 + 哨兵默认值。
	var wconsts: Dictionary = wi.get_script_constant_map()
	_check(int(wconsts.get("DEFAULT_MAX_WEAPONS", -1)) == 4,
			"WeaponInventory.DEFAULT_MAX_WEAPONS == 4(实际 %s)" % str(wconsts.get("DEFAULT_MAX_WEAPONS")))
	_check(int(wconsts.get("DEFAULT_CAPACITY", -1)) == 8,
			"WeaponInventory.DEFAULT_CAPACITY == 8(实际 %s)" % str(wconsts.get("DEFAULT_CAPACITY")))

	# ── ⑤ 生产代码里不得再有硬编码的武器 id 列表 ──
	# 6 个字面量 / 5 个文件(weapon_component.gd 里有两处)全部改问 all_ids() 之后,本相零命中。
	# ★ 判据用**剥注释 + 去空格**的视图:`[1,2,3,4,5,6]`(无空格)也要挡住。
	# ★ 只扫生产目录(scenes/core/server/ui):tests 里的 `[1, 2, 3, 4, 5, 6]` 有合法的
	#   **role 列表**用途(`team_host_probe.gd:373,421`、`team_spawn_smoke.gd:28,36`),扫进
	#   tests 会恒红 —— 唯一例外(`kh_l3_probe.gd:187` 那处真是武器列表)由 Task 4 点名处理。
	var offenders: Array = []
	for path in ScanUtil.collect(["res://scenes", "res://core", "res://server", "res://ui"]):
		var src := ScanUtil.read(path)
		if src.is_empty():
			continue
		if ScanUtil.code_only(src).replace(" ", "").contains("[1,2,3,4,5,6]"):
			offenders.append(path)
	_check(offenders.is_empty(),
			"生产代码里不得再有硬编码的武器 id 列表(命中:%s)" % str(offenders))

	# ── ⑤b 那三张表必须**被删掉**,不是被绕过(2026-09-26 补:本相才是"本计划成败判据"的守卫)──
	# ★★ 为什么单开一条、而且它比 ⑤/⑥ 都重要:
	#   ⑤ 的判据是 `contains("[1,2,3,4,5,6]")`,而那三张表的键/值是 `"1".."6"` 与 `1..6:` ——
	#   **一个 `[1, 2, 3, 4, 5, 6]` 字面量都不含** ⇒ 表就算原样留着,⑤ 也全绿。
	#   ⑥ 只覆盖**六处循环/初始化的宿主**(`_default_weapon_types` / `_add_weapon_grid` /
	#   `_fill_sp_panel` / `_server_weapon_types` / `_init` / `set_enabled_types`);
	#   而三张表还有**五个真正的读点**不在⑥ 里 ——
	#     `scenes/player/player_replica.gd`(对手手里的枪外观)
	#     `scenes/weapons/weapon_pickup.gd`(地面武器的视觉)
	#     `ui/weapon_icons.gd`(剪影 + 选择格上的名字)
	#     `ui/hud.gd`(左下角武器名)
	#   ⇒ **只把⑥ 的六处接上注册表、留下三张表**的"半迁移"会让本计划的承诺
	#   (「加第 7 把枪只改一个 json」)**静默失效**:菜单/散落里出现了 7 号枪,
	#   而它在对手手里、在地上、在图标与 HUD 名字上**全都不存在**,且一条断言都不红。
	# ★ 为什么"断言表被删"就**足够**、不必逐点断言读点改对了:
	#   表一删,任何**没**改到注册表的读点当场是 **Parse Error**(类常量不存在)——
	#   响亮、定位精确、无法静默绕过。⇒ 这一条 + 编译器合起来就把"删干净"钉死了。
	# ★ 判据必须用 `\b…\b`,**不能**用裸 `contains()` —— 裸的会踩 `MAX_WEAPONS`:
	#   `const MAX_WEAPONS := 4` 含子串 `WEAPONS` ⇒ 恒红,而它是**该留**的常量名
	#   (计划 4 之后叫 `DEFAULT_MAX_WEAPONS`,一样含)。
	#   PCRE 的 `\w` 含下划线 ⇒ `\bWEAPONS\b` 不命中 `MAX_WEAPONS`。
	# ★ `ScanUtil.read` 读不到时返回 `""` ⇒ 这里 `continue`(跳过)。目录扫描可以接受这个形状
	#   (文件是同一次 walk 列出来的,列得出就读得到);⑥ 那 6 个**具名**文件则另有显式的
	#   "读不到就红"。
	var re_tbl := RegEx.create_from_string("\\b(WEAPONS|DISPLAY_NAMES|TIERS)\\b")
	var stale_tables: Array = []
	for path in ScanUtil.collect(["res://scenes", "res://core", "res://server", "res://ui"]):
		var code := ScanUtil.code_only(ScanUtil.read(path))
		if code.is_empty():
			continue
		for m in re_tbl.search_all(code):
			stale_tables.append("%s::%s" % [path, m.get_string(1)])
	_check(stale_tables.is_empty(),
			"那三张旧表必须**删掉**(不是绕过);命中(文件::表名)= %s" % str(stale_tables))

	# ── ⑥ 六处字面量的**宿主**确实改问了注册表 ──
	# ★ ⑤ 挡的是"还留着老写法",⑥ 挡的是"新写法没接上" —— 只有 ⑤ 时,把
	#   `_default_weapon_types` 整个删掉(或改成 `return []`)照样全绿。
	# ★ 按**函数体**判,不按整文件 contains:同一文件里别处出现 `all_ids()` 不能替这一处背书
	#   (level_0.gd 有 600+ 行)。
	var sites := [
		{"path": "res://scenes/level_0.gd", "func": "_default_weapon_types"},
		{"path": "res://scenes/lobby_page.gd", "func": "_add_weapon_grid"},
		{"path": "res://scenes/main_menu.gd", "func": "_fill_sp_panel"},
		{"path": "res://server/match/match_ground.gd", "func": "_server_weapon_types"},
		{"path": "res://scenes/player/weapon_component.gd", "func": "_init"},
		{"path": "res://scenes/player/weapon_component.gd", "func": "set_enabled_types"},
	]
	for s in sites:
		var src := ScanUtil.read(s["path"])
		if src.is_empty():
			_check(false, "读到 %s(读不到就是红,不是静默跳过)" % s["path"])
			continue
		var whole := ScanUtil.code_only(src)
		var body := ScanUtil.func_body(whole, s["func"])
		if body.is_empty():
			_check(false, "在 %s 里找到函数 %s()" % [s["path"], s["func"]])
			continue
		# ★ 2026-10-02 降精度:原钉 `body.contains("WeaponRegistry.all_ids()")` —— 把取 id
		#   包成一层**本文件内的 helper**(如 `_weapon_ids()` 自己调 all_ids())就**假红**,
		#   而接线其实是通的。改判"函数体**引用了注册表派生的取 id 调用**":直接出现 `all_ids(`,
		#   或调用了本文件里某个自己也含 `all_ids(` 的函数(只追一层)。
		# 要拦的变异:宿主不接注册表(**硬编码 id 列表**)⇒ 加第 7 把枪时新枪在这一处静默消失。
		_check(_body_reaches_registry_ids(whole, body, s["func"]),
				"%s 的 %s() 应改用注册表派生的取 id 调用(WeaponRegistry.all_ids() 或其一层 helper)"
				% [s["path"], s["func"]])

	# ── ⑦ 覆盖性:默认启用表必须**等于**注册表全部 id ──
	# 这是 spec §4.2 点名要加、而今天**没有**的那条守卫。
	# ★ 三处散落/菜单/禁用网格现在都从 all_ids() 取数 ⇒ "覆盖"是构造性的(由 ⑥ 保证);
	#   真正会漂的是**默认启用表** —— 它今天是一条硬编码的 `[1, 2, 3, 4, 5, 6]`,
	#   加第 7 把枪时漏改它,新枪**永远拿不到也开不了**,而**完全不报错**。
	if wr != null:
		var want_ids: Array = wr.all_ids()
		var comp = wc.new()
		_check(comp.enabled_types == want_ids,
				"默认启用表必须等于注册表全部 id(实际 %s、注册表 %s)" % [
					str(comp.enabled_types), str(want_ids)])
		comp.free()

	# ── ⑧ 反方向:scenes/weapons 下的**武器** .tscn 必须都有 json 条目(2026-09-29)──
	# ★ ② 只覆盖 json → tscn 这一个方向;反方向此前**零守卫**(症状与量级见 `_root_script_of`
	#   上方那段)。"加第 7 把枪 = 改 1 个 json + 加 1 个 tscn"这句承诺,**先放 tscn、忘了接
	#   json**这一半今天靠人眼 —— 本条就是那半步的安全带。
	# ★ 判据是「根脚本链上有 `weapon_base.gd`」,**不是**「scenes/weapons/ 下所有 .tscn」:
	#   该目录同时住着 `bullet` / `grenade_bullet` / `laser_beam` / `weapon_pickup` 四个
	#   **非武器**场景(它们本来就不该进 weapons.json),拿目录清单当判据会当场恒红。
	var registered: Dictionary = {}
	for rid in rows:
		registered[str((rows[rid] as Dictionary)["scene"])] = int(rid)
	var orphans: Array = []
	for p in ScanUtil.collect(["res://scenes/weapons"]):
		if not p.ends_with(".tscn"):
			continue
		if not _script_extends(_root_script_of(p), wb):
			continue
		if not registered.has(p):
			orphans.append(p)
	_check(orphans.is_empty(),
			"scenes/weapons/ 下的武器场景必须都在 %s 里(漏登记 = 菜单/散落/图标/HUD 里都不存在;" % REGISTRY_JSON
			+ " 漏登记的是 %s)" % str(orphans))


# ── 容量格子面板的派生(2026-09-25)──
# 判据分两半:① 派生公式本身(纯静态,不需要实例化 Control);
# ② **接线** —— 公式必须真的被 setup()/refresh() 用上。只有 ① 的话,把两个静态函数写出来
#    却没人调,断言照样全绿(本仓反复在删那种"加了断言之后全绿"的假证据)。
func _phase_weapon_capacity() -> void:
	var ws: GDScript = load("res://ui/hud/weapon_slots.gd")
	_check(ws != null, "ui/hud/weapon_slots.gd 可加载")
	if ws == null:
		return
	var src := ScanUtil.read("res://ui/hud/weapon_slots.gd")
	_check(not src.is_empty(), "读到 ui/weapon_slots.gd(读不到就是红,不是静默跳过)")
	# ★★ 必须先看源码文本再敢调:`ws.rows_for(...)` 在函数不存在时会**抛错**,
	#   而 -s 冒烟里 helper 抛错 ⇒ 本函数当场结束、调用方继续 ⇒ 下面那些断言
	#   被静默跳过(裁决行照打 —— **假绿**)。本函数是 helper(不是 _initialize),
	#   所以这里 `return` 是安全的、不会挂进程。
	var has_derivation := src.contains("static func rows_for") and src.contains("static func panel_h_for")
	_check(has_derivation, "★ WeaponSlots 应导出 rows_for() / panel_h_for() 两个静态派生函数")
	if not has_derivation:
		return
	# ① 派生公式
	_check(int(ws.COLS) == 4, "COLS 恒为 4(加容量只向下长,不换行宽;实际 %s)" % str(ws.COLS))
	_check(is_equal_approx(float(ws.PANEL_W), 109.0),
			"PANEL_W 与行数无关,仍是 109(实际 %s)" % str(ws.PANEL_W))
	_check(int(ws.rows_for(8)) == 2, "rows_for(8) = 2(实际 %s)" % str(ws.rows_for(8)))
	_check(int(ws.rows_for(12)) == 3, "rows_for(12) = 3(实际 %s)" % str(ws.rows_for(12)))
	_check(int(ws.rows_for(16)) == 4, "rows_for(16) = 4(实际 %s)" % str(ws.rows_for(16)))
	_check(int(ws.rows_for(1)) == 1, "rows_for(1) = 1(至少一行,不能 0;实际 %s)" % str(ws.rows_for(1)))
	_check(is_equal_approx(float(ws.panel_h_for(8)), 59.0),
			"panel_h_for(8) = 59(默认值**一个字没变**;实际 %s)" % str(ws.panel_h_for(8)))
	_check(is_equal_approx(float(ws.panel_h_for(12)), 84.0),
			"panel_h_for(12) = 84(实际 %s)" % str(ws.panel_h_for(12)))
	_check(is_equal_approx(float(ws.panel_h_for(1)), 34.0),
			"panel_h_for(1) = 34(实际 %s)" % str(ws.panel_h_for(1)))
	# ② 接线(按**函数体**判,不按整文件 contains —— 同一文件里别处出现 `_derive_layout()`
	#    不能替 `setup()` 那一处背书)
	var body_setup := ScanUtil.func_body(ScanUtil.code_only(src), "setup")
	_check(body_setup.contains("_derive_layout()"),
			"WeaponSlots.setup() 必须调 _derive_layout()(否则容量只活在公式里,格子阵不长)")
	var body_refresh := ScanUtil.func_body(ScanUtil.code_only(src), "refresh")
	_check(body_refresh.contains("_derive_layout()"),
			"WeaponSlots.refresh() 必须重取容量(容量改了之后 UI 要能跟上)")
	var body_derive := ScanUtil.func_body(ScanUtil.code_only(src), "_derive_layout")
	_check(body_derive.contains("inventory.capacity"),
			"_derive_layout() 必须从**背包**读容量(不能是另一个写死的数)")
	# ②b **画的格数必须跟着派生的 `capacity`**(2026-09-26 补:这是"半迁移"的最后一个洞)
	# ★ 洞的形状:把 `_draw` 里的 `WeaponInventory.CAPACITY`(常量被删 ⇒ 必须改)偷懒换成
	#   `DEFAULT_CAPACITY` —— 于是 `_derive_layout()` 照样被调、`panel_h` 照样对,
	#   而**格阵恒画 8 格**,容量调到 12 也不长。上面三条**全绿**。
	# ★ 判据不能只是 `contains("capacity")`:坏写法里的 `DEFAULT_CAPACITY` 也含这个词 ⇒
	#   必须**反面一起判**(不得出现 `DEFAULT_CAPACITY`)。
	var body_draw := ScanUtil.func_body(ScanUtil.code_only(src), "_draw")
	_check(body_draw.contains("capacity") and not body_draw.contains("DEFAULT_CAPACITY"),
			"★ _draw() 必须按**本实例的 capacity** 画格子,不得读 DEFAULT_CAPACITY(那是默认值,不是本实例的容量)")
	var body_empty := ScanUtil.func_body(ScanUtil.code_only(src), "_draw_empty_cells")
	_check(body_empty.contains("capacity") and not body_empty.contains("DEFAULT_CAPACITY"),
			"★ _draw_empty_cells() 同上(空背包那条路径也要跟着容量长)")


# ── 布点工具 spread_cells(2026-09-15 从 RoyaleHost.plan_spawns 抽出)──
# 三条:取满 / 两两距离达标 / 池子不够时放宽而不返回空。
func _phase_spread_cells() -> void:
	var cells: Array = []
	for y in 10:
		for x in 10:
			cells.append(Vector2i(x, y))

	var picked: Array = GridPathfinder.spread_cells(cells.duplicate(), 5, 3, 10, 10)
	_check(picked.size() == 5, "spread_cells 应取满 5 个点(实际 %d)" % picked.size())
	# 两两环面距离 ≥ clearance(10x10 的池子放 5 个点不需要放宽)
	for i in picked.size():
		for j in range(i + 1, picked.size()):
			var d := GridPathfinder.toroidal_dist(picked[i], picked[j], 10, 10)
			_check(d >= 3, "点 %d 与 %d 的距离 %d < clearance 3" % [i, j, d])

	# 池子小:clearance 逐级放宽,最终必须**凑满**而不是返回空(调用方按 count 布点)
	var few: Array = [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]
	_check(GridPathfinder.spread_cells(few.duplicate(), 3, 9, 10, 10).size() == 3,
			"池子小时应放宽 clearance 凑满 3")

	# count 超过池子大小:返回全部,不越界、不补 (-1,-1)
	var over: Array = GridPathfinder.spread_cells(few.duplicate(), 10, 3, 10, 10)
	_check(over.size() == 3, "count 超过池子应返回全部(实际 %d)" % over.size())

	# 边界:空池 / count<=0 都返回空表,不崩
	_check(GridPathfinder.spread_cells([], 3, 3, 10, 10).is_empty(), "空池应返回空表")
	_check(GridPathfinder.spread_cells(few.duplicate(), 0, 3, 10, 10).is_empty(), "count=0 应返回空表")
