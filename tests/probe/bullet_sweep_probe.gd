extends Node

# 子弹扫掠命中探针(场景模式:要真物理步进与真 bullet 场景)。验两类事:

const EXPECTED_CHECKS := 15
const MARKER := "BULLET SWEEP PROBE: ALL-OK"
const HitShape := preload("res://core/sim/hit_shape.gd")

# 等价性用例的固定种子:随机断言必须可复现(同配置跑两次结论要一样)。
const EQ_SEED := 0x5EED0A11
const EQ_RANDOM_CASES := 400
const EQ_RANDOM_TICKS := 200
const EQ_W := 1920.0
const EQ_H := 1440.0

var _fails: Array[String] = []
var _checks := 0


class EqCase:
	var label: String
	var a: Vector2
	var b: Vector2
	var rect: Rect2
	var grow: Vector2

	func _init(p_label: String, p_a: Vector2, p_b: Vector2, p_rect: Rect2, p_grow: Vector2) -> void:
		label = p_label
		a = p_a
		b = p_b
		rect = p_rect
		grow = p_grow


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

	func apply_hit(target: Node, _dir: Vector2, _shot_damage: int) -> void:
		hits += 1
		if target != null and target.has_method("hurt"):
			target.hurt(1, Vector2.RIGHT)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_equivalence_block()

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


# ── A. 宽相位等价性(O1)───────────────────────────────────────────────────────────────────────
func _equivalence_block() -> void:
	# 构造用例:覆盖"必须放过"的四种边缘 + 一个"必须否掉"的反例。
	var crossing := EqCase.new("高速跨过", Vector2(100, 100), Vector2(150, 100), Rect2(110, 82, 20, 40), Vector2(5, 2))
	# ★ 相切:线段恰好压在受击面上边缘(y=120)。精确判中(贴边算中),粗筛若不把边界算进来就会漏 ——
	#   这也是 Rect2.intersects 默认(排斥边界)与 Rect2.encloses(更强)不能用来做粗筛的原因。
	var tangent := EqCase.new("贴边相切", Vector2(100, 120), Vector2(150, 120), Rect2(110, 120, 20, 40), Vector2.ZERO)
	# ★ 擦边:不 grow 必 miss(y=100 对 y=103..143),靠 grow.y=4 才命中 ⇒ 粗筛漏 grow 就红。
	var grow_edge := EqCase.new("擦边靠grow", Vector2(100, 100), Vector2(150, 100), Rect2(110, 103, 20, 40), Vector2(0, 4))
	# ★ 跨环面缝:子弹在 x=1900→1940(w=1920),受击面在 x=5..25 ⇒ 精确用"离 a 最近的副本"(x=1925..1945)。
	#   粗筛不先 rect_at 对齐就会拿 x=5..25 去比,把真命中筛掉。
	var seam := EqCase.new("跨环面缝", Vector2(1900, 700), Vector2(1940, 700), Rect2(5, 680, 20, 40), Vector2(2, 2))
	var inside := EqCase.new("起点在框内", Vector2(115, 120), Vector2(200, 120), Rect2(110, 120, 20, 40), Vector2.ZERO)
	var far := EqCase.new("明显不中", Vector2(100, 100), Vector2(150, 100), Rect2(400, 400, 20, 40), Vector2(5, 5))
	var cases := [crossing, tangent, grow_edge, seam, inside, far]

	var mismatches := 0
	var false_negatives := 0
	for c in cases:
		var exact: bool = HitShape.candidate_hits(c.a, c.b, c.rect, EQ_W, EQ_H, c.grow, true)
		var coarse: bool = HitShape.candidate_hits(c.a, c.b, c.rect, EQ_W, EQ_H, c.grow, false)
		if exact != coarse:
			mismatches += 1
			print("[sweep]     ! 构造用例不一致:%s exact=%s coarse=%s" % [c.label, exact, coarse])
		# 反向:粗筛单独看(不走精确)是否否掉了一个真命中。
		if exact and not HitShape.sweep_may_hit(c.a, c.b, c.rect, EQ_W, EQ_H, c.grow):
			false_negatives += 1
			print("[sweep]     ! 粗筛否掉真命中:%s" % c.label)

	_check(mismatches == 0, "构造 %d 例:粗筛路径与直接精确路径判决逐例一致(不一致 %d)" % [cases.size(), mismatches])
	_check(false_negatives == 0, "构造 %d 例:粗筛从未否掉精确判中的候选(否掉 %d)" % [cases.size(), false_negatives])
	# 下面三条是逐条"哪一处写错会红"的定点:改坏粗筛判据时它们会先于上面的汇总断言叫出来。
	_check(HitShape.sweep_may_hit(tangent.a, tangent.b, tangent.rect, EQ_W, EQ_H, tangent.grow),
			"贴边相切:粗筛放行(AABB 比较必须含边界,不能用 intersects/encloses)")
	_check(HitShape.sweep_may_hit(grow_edge.a, grow_edge.b, grow_edge.rect, EQ_W, EQ_H, grow_edge.grow),
			"擦边:粗筛把 grow 算进扫掠框(漏 grow ⇒ 真命中被筛掉)")
	_check(HitShape.sweep_may_hit(seam.a, seam.b, seam.rect, EQ_W, EQ_H, seam.grow),
			"跨环面缝:粗筛按「离子弹最近的那份副本」对齐(不 rect_at 必红)")
	_check(not HitShape.sweep_may_hit(far.a, far.b, far.rect, EQ_W, EQ_H, far.grow),
			"明显不可能的候选被粗筛否掉(证明粗筛不是恒真)")

	# 随机用例:位置/长度/方向/grow 全随机,受击面**绕过缝**(fposmod 回 [0,MAP))以覆盖环面副本选取。
	var rng := RandomNumberGenerator.new()
	rng.seed = EQ_SEED
	var rand_mismatches := 0
	var rand_hits := 0
	var rand_rejected := 0
	for i in EQ_RANDOM_CASES:
		var a := Vector2(rng.randf_range(-40.0, EQ_W + 40.0), rng.randf_range(0.0, EQ_H))
		var ang := rng.randf_range(-PI, PI)
		var b := a + Vector2(cos(ang), sin(ang)) * rng.randf_range(0.0, 80.0)
		var center := Vector2(fposmod(a.x + rng.randf_range(-40.0, 40.0), EQ_W),
				fposmod(a.y + rng.randf_range(-40.0, 40.0), EQ_H))
		var sz := Vector2(rng.randf_range(4.0, 40.0), rng.randf_range(4.0, 40.0))
		var rect := Rect2(center - sz * 0.5, sz)
		var grow := Vector2(rng.randf_range(0.0, 6.0), rng.randf_range(0.0, 6.0))
		var exact: bool = HitShape.candidate_hits(a, b, rect, EQ_W, EQ_H, grow, true)
		var coarse: bool = HitShape.candidate_hits(a, b, rect, EQ_W, EQ_H, grow, false)
		if exact != coarse:
			rand_mismatches += 1
			print("[sweep]     ! 随机用例不一致:a=%s b=%s rect=%s grow=%s exact=%s coarse=%s"
					% [a, b, rect, grow, exact, coarse])
		if exact:
			rand_hits += 1
		if not HitShape.sweep_may_hit(a, b, rect, EQ_W, EQ_H, grow):
			rand_rejected += 1
	_check(rand_mismatches == 0, "随机 %d 例(种子固定):两路径判决一致(不一致 %d)" % [EQ_RANDOM_CASES, rand_mismatches])
	# 防"全 miss 空转":样本里必须既有真命中、也有被粗筛否掉的候选,上面那条一致断言才有内容。
	_check(rand_hits > 0 and rand_rejected > 0,
			"随机用例分布有效:真命中 %d 例 / 粗筛否掉 %d 例(都不为 0)" % [rand_hits, rand_rejected])

	# tick 模拟:一颗子弹 × 有序候选列表(顺序 = 生产里 players 的插入序),取**首个**命中 —— 就是裁决的 break 语义。
	# 命中集合(=每颗弹的命中与否)与命中顺序(=首个命中的索引序列)必须完全相同。
	var seq_coarse: Array[int] = []
	var seq_exact: Array[int] = []
	var tick_hits := 0
	for t in EQ_RANDOM_TICKS:
		var aa := Vector2(rng.randf_range(0.0, EQ_W), rng.randf_range(0.0, EQ_H))
		var bb := aa + Vector2(rng.randf_range(-60.0, 60.0), rng.randf_range(-60.0, 60.0))
		var gg := Vector2(rng.randf_range(0.0, 5.0), rng.randf_range(0.0, 5.0))
		var rects: Array[Rect2] = []
		var ncand := rng.randi_range(1, 5)
		for k in ncand:
			var at: Vector2
			if rng.randf() < 0.5:
				at = aa.lerp(bb, rng.randf()) + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0))
			else:
				at = Vector2(rng.randf_range(0.0, EQ_W), rng.randf_range(0.0, EQ_H))
			rects.append(Rect2(at - Vector2(10, 20), Vector2(20, 40)))
		var ci := _first_hit_index(rects, aa, bb, gg, false)
		var ei := _first_hit_index(rects, aa, bb, gg, true)
		seq_coarse.append(ci)
		seq_exact.append(ei)
		if ci >= 0:
			tick_hits += 1
	_check(seq_coarse == seq_exact and tick_hits > 0,
			"tick 模拟 %d 颗弹:命中集合与命中顺序(首个命中索引序列)一致,命中 %d 颗" % [EQ_RANDOM_TICKS, tick_hits])


# 生产裁决的 break 语义:按 candidates 顺序找第一个命中的下标;全不中返回 -1。
func _first_hit_index(rects: Array[Rect2], a: Vector2, b: Vector2, grow: Vector2, exact_only: bool) -> int:
	for i in rects.size():
		if HitShape.candidate_hits(a, b, rects[i], EQ_W, EQ_H, grow, exact_only):
			return i
	return -1


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
