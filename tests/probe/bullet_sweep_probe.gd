extends Node

# 子弹扫掠命中探针(场景模式:要真物理步进与真 bullet 场景)。验三件事:
#   ① 高速弹一帧跨过目标也能命中(线段扫掠,治穿透);② 擦边 2px 靠子弹体积 grow 命中;③ 尸体(is_hurtable=false)不吃弹。
# 跑法:godot --headless --path . res://tests/probe/bullet_sweep_probe.tscn;判据 grep 末行 "BULLET SWEEP PROBE: ALL-OK"。

const EXPECTED_CHECKS := 6
const MARKER := "BULLET SWEEP PROBE: ALL-OK"
const HitShape := preload("res://core/sim/hit_shape.gd")

var _fails: Array[String] = []
var _checks := 0


class StubEnemy extends Node2D:
	var hits := 0
	var hurtable_flag := true

	func hurt(_damage: int, _dir: Vector2, _knock: float = 0.0, _set_v: bool = false) -> void:
		hits += 1

	func hurt_rect() -> Rect2:
		return CollisionAabb.world_rect(self)

	func is_hurtable() -> bool:
		return hurtable_flag


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

	# ① 高速弹一帧跨过目标:50px/帧 跨过 20px 宽受击面
	var enemy := _stub_enemy(Vector2(120, 100))
	var source := StubSource.new()
	add_child(source)
	var bullet := _bullet_at(Vector2(100, 100), source)
	_check(bullet.collision_mask == 1, "bullet.tscn mask=1(物理只撞地形、受击交给扫掠)")
	await _ticks(3)
	_check(source.hits == 1, "武器 apply_hit 被调用一次(实得 %d)" % source.hits)
	_check(enemy.hits == 1, "目标受击一次(实得 %d;点采样在 50px/帧 下会漏)" % enemy.hits)
	_check(not is_instance_valid(bullet), "命中后子弹已自毁")

	# ② 擦边 2px:子弹体积 grow 生效(同一几何不 grow 必 miss)
	enemy.free()
	var graze := _stub_enemy(Vector2(120, 122))   # 受击面 y 102..142,子弹中心线 y=100 ⇒ 擦上边 2px
	var no_grow_miss := HitShape.segment_hits_rect(Vector2(100, 100), Vector2(150, 100),
			Rect2(110, 102, 20, 40)) < 0.0
	var source2 := StubSource.new()
	add_child(source2)
	_bullet_at(Vector2(100, 100), source2)
	await _ticks(3)
	_check(no_grow_miss and source2.hits == 1 and graze.hits == 1,
			"擦边 2px:不 grow miss、grow 后命中(apply_hit=%d / hurt=%d)" % [source2.hits, graze.hits])

	# ③ 尸体:is_hurtable()=false ⇒ 不吃弹、不触发命中反馈
	graze.free()
	var corpse := _stub_enemy(Vector2(120, 100))
	corpse.hurtable_flag = false
	var source3 := StubSource.new()
	add_child(source3)
	var bullet3 := _bullet_at(Vector2(100, 100), source3)
	await _ticks(2)
	_check(source3.hits == 0 and corpse.hits == 0 and is_instance_valid(bullet3),
			"尸体不可受击:不吃弹/不反馈、子弹继续飞")

	_finish()


func _stub_enemy(at: Vector2) -> StubEnemy:
	var e := StubEnemy.new()
	e.add_to_group("enemies")
	var poly := CollisionPolygon2D.new()
	poly.polygon = PackedVector2Array([Vector2(-10, -20), Vector2(10, -20), Vector2(10, 20), Vector2(-10, 20)])
	e.add_child(poly)
	add_child(e)
	e.global_position = at
	return e


func _bullet_at(at: Vector2, src: Node) -> BulletBase:
	var scene: PackedScene = load("res://scenes/weapons/bullet.tscn")
	var b: BulletBase = scene.instantiate() as BulletBase
	b.setup(Vector2.RIGHT, 3000.0, 500.0, 1.0, Color.WHITE, src)
	b.hit_damage = 1
	b.hit_impact = 10.0
	b.global_position = at
	add_child(b)
	return b


func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _finish() -> void:
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
