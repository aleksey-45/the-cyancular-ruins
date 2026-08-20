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
	func hurt(damage: int, _dir: Vector2, _knock: float = 0.0) -> void:
		hp -= damage
		hits.append([damage, _dir, _knock])

# 桩玩家:入 player 组,记录 take_hit
class StubPlayer:
	extends CharacterBody2D
	var hit_log: Array = []
	func _init() -> void:
		add_to_group("player")
		collision_layer = 2
		collision_mask = 0
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
	var gp := root.get_node_or_null("GameParameters")
	if gp != null:
		gp.set("MAP_WIDTH", 400)
		gp.set("MAP_HEIGHT", 400)
	_test_aoe()
	if _failures.is_empty():
		print("GRENADE SMOKE OK")
		quit(0)
	else:
		printerr("FAILURES: " + str(_failures))
		quit(1)

func _test_aoe() -> void:
	MazeGenerator.current_grid = []  # 空网格:跳过 LOS
	# 中心满伤
	var e1 := StubEnemy.new()
	e1.global_position = Vector2(200, 200)
	root.add_child(e1)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e1.hp == 50 - 35, "AoE 中心满伤 35")
	e1.free()
	# 边缘(≈radius)→ 0 伤
	var e2 := StubEnemy.new()
	e2.global_position = Vector2(200, 200) + Vector2(127, 0)
	root.add_child(e2)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e2.hp == 50, "AoE 边缘 0 伤")
	e2.free()
	# 中段衰减: d=64, inner=44.8 → 35*(1-(64-44.8)/83.2)=26
	var e3 := StubEnemy.new()
	e3.global_position = Vector2(200, 200) + Vector2(64, 0)
	root.add_child(e3)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e3.hp == 50 - 26, "AoE 中段线性衰减")
	e3.free()
	# 冲击波向外:方向为从爆心指向目标
	var e4 := StubEnemy.new()
	e4.global_position = Vector2(200, 200) + Vector2(0, 60)
	root.add_child(e4)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(e4.hits.size() == 1 and e4.hits[0][1].y > 0.0, "冲击波方向向外(+y)")
	e4.free()
	# 友伤:玩家在范围内掉血
	var p := StubPlayer.new()
	p.global_position = Vector2(200, 200) + Vector2(20, 0)
	root.add_child(p)
	Explosion.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(p.hit_log.has(35), "玩家友伤满值 35")
	p.free()
	# LOS 遮挡:竖墙把爆心与敌人隔开 → 0 伤;同侧开阔 → 满伤
	var g: Array[Array] = []
	for _y in range(25):
		var row: Array[int] = []
		row.resize(25)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	for y in range(25):
		g[y][12] = MazeGenerator.SOLID
	MazeGenerator.current_grid = g
	var walled := StubEnemy.new()
	walled.global_position = Vector2(18 * 16, 12 * 16)  # 墙(12,*)另一侧
	root.add_child(walled)
	Explosion.apply_aoe(Vector2(5 * 16, 12 * 16), 300.0, 35, 900.0)
	_check(walled.hp == 50, "墙后敌人 0 伤(LOS 遮挡)")
	walled.free()
	var open := StubEnemy.new()
	open.global_position = Vector2(6 * 16, 12 * 16)
	root.add_child(open)
	Explosion.apply_aoe(Vector2(5 * 16, 12 * 16), 300.0, 35, 900.0)
	_check(open.hp == 50 - 35, "开阔侧满伤")
	open.free()
	MazeGenerator.current_grid = []
