extends Node

# 子弹扫掠命中探针(场景模式:要真物理步进与真 bullet 场景)。
# 验的是"高速弹一帧跨过目标也能命中"—— 一帧 50px(3000px/s@60Hz)跨过 20px 宽的受击面,点采样必漏、线段扫掠必中。
# 跑法:godot --headless --path . res://tests/probe/bullet_sweep_probe.tscn;判据 grep 末行 "BULLET SWEEP PROBE: ALL-OK"。

const EXPECTED_CHECKS := 4
const MARKER := "BULLET SWEEP PROBE: ALL-OK"

var _fails: Array[String] = []
var _checks := 0


class StubEnemy extends Node2D:
	var hits := 0

	func hurt(_damage: int, _dir: Vector2, _knock: float = 0.0, _set_v: bool = false) -> void:
		hits += 1

	func hurt_rect() -> Rect2:
		return CollisionAabb.world_rect(self)


class StubSource extends Node:
	var hits := 0

	func apply_hit(target: Node, _dir: Vector2) -> void:
		hits += 1
		if target != null and target.has_method("hurt"):
			target.hurt(1, Vector2.RIGHT)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var anchor := Node2D.new()
	anchor.add_to_group("player")
	add_child(anchor)
	var enemy := StubEnemy.new()
	enemy.name = "StubEnemy"
	# ★ 不再设 collision_layer:分离之后受击判定不靠物理层(子弹 mask=1 只撞地形),
	#   探针必须证明"没有物理层也能被打中" —— 设了反而把待验证的路径绕过去。
	enemy.add_to_group("enemies")
	var poly := CollisionPolygon2D.new()
	poly.polygon = PackedVector2Array([Vector2(-10, -20), Vector2(10, -20), Vector2(10, 20), Vector2(-10, 20)])
	enemy.add_child(poly)
	add_child(enemy)
	enemy.global_position = Vector2(120, 100)
	var source := StubSource.new()
	add_child(source)

	var scene: PackedScene = load("res://scenes/weapons/bullet.tscn")
	var bullet: BulletBase = scene.instantiate() as BulletBase
	bullet.setup(Vector2.RIGHT, 3000.0, 500.0, 1.0, Color.WHITE, source)
	bullet.hit_damage = 1
	bullet.hit_impact = 10.0
	bullet.global_position = Vector2(100, 100)
	add_child(bullet)
	_check(bullet.collision_mask == 1, "bullet.tscn mask=1(物理只撞地形、受击交给扫掠)")

	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(source.hits == 1, "武器 apply_hit 被调用一次(实得 %d)" % source.hits)
	_check(enemy.hits == 1, "目标受击一次(实得 %d;点采样在 50px/帧 下会漏)" % enemy.hits)
	_check(not is_instance_valid(bullet), "命中后子弹已自毁")

	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print(MARKER)
		get_tree().quit(0)
	else:
		print("BULLET SWEEP PROBE: FAIL")
		for f in _fails:
			print("[sweep]   ✗ %s" % f)
		get_tree().quit(1)


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[sweep]   ✓ %s" % msg)
	else:
		_fails.append(msg)
		print("[sweep]   ✗ %s" % msg)
