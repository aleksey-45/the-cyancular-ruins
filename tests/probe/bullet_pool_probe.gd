extends Node

# 子弹对象池场景探针(真场景树:走 _ready / 物理帧 / 组查询)。验六件事:

const EXPECTED_CHECKS := 9
const MARKER := "BULLET POOL PROBE: ALL-OK"
const BULLET_PATH := "res://scenes/weapons/bullet.tscn"
const RIFLE_PATH := "res://scenes/weapons/rifle_test.tscn"

var _fails: Array[String] = []
var _checks := 0


# 受击面替身:只提供 HitShape 需要的三件(hurt_rect / is_hurtable / 在 enemies 组),不结算伤害。
class _StubEnemy extends Node2D:
	func hurt_rect() -> Rect2:
		return Rect2(global_position - Vector2(10, 20), Vector2(20, 40))

	func is_hurtable() -> bool:
		return true


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var pool := BulletPool.shared()
	# ① 客户端出弹路径(weapon._spawn_projectiles,Level0.pvp_mode=true 即"本地视觉弹"):
	var weapon: WeaponBase = (load(RIFLE_PATH) as PackedScene).instantiate() as WeaponBase
	add_child(weapon)
	Level0.pvp_mode = true
	var laser_before := _weapon_fx_count(weapon)
	weapon._spawn_projectiles(Vector2.RIGHT)
	var b1 := _only_bullet()
	var b1_id := b1.get_instance_id() if b1 != null else 0
	var from_pool := b1 != null and String(b1.get_meta("scene_path", "")) == BULLET_PATH
	if b1 != null:
		b1.despawn()
	await _ticks(1)   # 池对"本帧刚归还"的实例压一帧不借(见 ⑨),所以复用至少隔一帧
	weapon._spawn_projectiles(Vector2.RIGHT)
	var b2 := _only_bullet()
	var reused_same := b2 != null and b2.get_instance_id() == b1_id
	if b2 != null:
		b2.despawn()
	_chk(from_pool and reused_same and _weapon_fx_count(weapon) == laser_before,
			"武器出弹走池(第二发复用同一实例=%s)且武器侧 _laser/_explosion_marker 不增长(%d→%d)"
					% [reused_same, laser_before, _weapon_fx_count(weapon)])

	# ② 客户端"他人子弹"入口(PvpMatchClient._take_visual_bullet):借出未进树,且池外被 free 的陈旧条目不借出
	var client := PvpMatchClient.new()
	var v1: BulletBase = client._take_visual_bullet(BULLET_PATH)
	var v1_ok := v1 != null and v1.get_parent() == null
	var v1_id := v1.get_instance_id() if v1 != null else 0
	if v1 != null:
		v1.free()   # 没进树就直接 free = 模拟"池外的某个持有者把闲置实例弄没了"
	var v2: BulletBase = client._take_visual_bullet(BULLET_PATH)
	_chk(v1_ok and v1_id != 0 and v2 != null and v2.get_parent() == null
			and v2.get_instance_id() != v1_id,
			"他人子弹入口走池(借出未进树;池外 free 的陈旧实例不再借出)")
	if v2 != null:
		v2.free()
	client.free()

	# ③ 归还后:离树 / 不在 bullet 组 / 物理关 / 不再移动
	var r: BulletBase = pool.acquire(BULLET_PATH)
	r.setup(Vector2.RIGHT, 600.0, 5000.0, 1.0, Color.WHITE, null)
	r.apply_damage = false
	r.global_position = Vector2(300, 300)
	add_child(r)
	await _ticks(2)   # 先真的动起来(证明下面"不动"不是恒真)
	var moved_before := r.global_position != Vector2(300, 300)
	r.despawn()
	var pos_after := r.global_position
	var out_of_group := not get_tree().get_nodes_in_group("bullet").has(r)
	await _ticks(5)
	_chk(moved_before and r.get_parent() == null and not r.is_physics_processing()
			and out_of_group and r.global_position == pos_after,
			"归还后离树 / 不在 bullet 组 / 物理关 / 5 帧不移动(实得 parent=%s physics=%s moved=%s)"
					% [str(r.get_parent()), r.is_physics_processing(), r.global_position != pos_after])

	# ④ 撞墙延迟销毁的旧定时器不许误伤"已被复用的一发"
	var d: BulletBase = pool.acquire(BULLET_PATH)
	d.setup(Vector2.ZERO, 0.0, 5000.0, 1.0, Color.WHITE, null)
	d.apply_damage = false
	d.global_position = Vector2(500, 500)
	add_child(d)
	d._despawn_after(0.05)   # 撞地形分支排的那个延迟销毁
	d.despawn()              # 立刻归还(= 50ms 内被复用)
	var d2: BulletBase = pool.acquire(BULLET_PATH)
	d2.setup(Vector2.ZERO, 0.0, 5000.0, 1.0, Color.WHITE, null)
	d2.apply_damage = false
	d2.global_position = Vector2(700, 700)
	add_child(d2)
	await _ticks(12)   # 0.2s > 0.05s:旧定时器早该到点了
	_chk(is_instance_valid(d2) and d2.is_inside_tree() and d2.global_position == Vector2(700, 700),
			"复用后旧定时器不误伤新的一发(0.2s 后仍在树:%s)" % [is_instance_valid(d2) and d2.is_inside_tree()])
	d2.despawn()

	# ⑤ 复用 3 次后子节点不增长(拖尾只建一次;Sprite2D / CollisionShape2D 来自场景,也不该多)
	var counts: Array[String] = []
	for i in 3:
		var c: BulletBase = pool.acquire(BULLET_PATH)
		c.setup(Vector2.RIGHT, 600.0, 5000.0, 1.0, Color.WHITE, null)
		c.apply_damage = false
		c.global_position = Vector2(200 + 40 * i, 800)
		add_child(c)
		await _ticks(2)
		if is_instance_valid(c):
			counts.append("%d/%d/%d" % [_count_of(c, "Sprite2D"), _count_of(c, "CollisionShape2D"), _count_of(c, "trail")])
			c.despawn()
		else:
			counts.append("gone")   # 被上一次使用的延迟回调收掉了:直接点名,别让下面抛类型错把整支探针带停
	_chk(counts[0] == "1/1/1" and counts[0] == counts[2],
			"复用 3 次后子节点不增长(Sprite2D/CollisionShape2D/拖尾 = %s → %s)" % [counts[0], counts[2]])

	# ⑥ 复用后拖尾点集被清、颜色跟上新一发(不同弹色跨枪复用)
	var t: BulletBase = pool.acquire(BULLET_PATH)
	t.setup(Vector2.RIGHT, 600.0, 5000.0, 1.0, Color.RED, null)
	t.apply_damage = false
	t.global_position = Vector2(1200, 200)
	add_child(t)
	await _ticks(4)
	t.despawn()
	var t2: BulletBase = pool.acquire(BULLET_PATH)
	t2.setup(Vector2.RIGHT, 600.0, 5000.0, 1.0, Color.CYAN, null)
	t2.apply_damage = false
	t2.global_position = Vector2(1600, 900)
	add_child(t2)
	await _ticks(1)
	var trail := _trail_of(t2)
	var first_pt_ok: bool = trail != null and trail.get_point_count() > 0 \
			and trail.get_point_position(0).distance_to(Vector2(1600, 900)) < 40.0
	var color_ok: bool = trail != null and trail.default_color.is_equal_approx(
			Color(Color.CYAN.r, Color.CYAN.g, Color.CYAN.b, trail.default_color.a))
	_chk(first_pt_ok and color_ok,
			"复用后拖尾点集清空且弹色跟新一发(拖尾=%s 点数=%d 首点=%s 颜色对=%s)"
					% [str(trail != null), trail.get_point_count() if trail != null else -1,
					str(trail.get_point_position(0)) if trail != null and trail.get_point_count() > 0 else "n/a", color_ok])
	t2.despawn()

	# ⑦ 复用后首帧的扫掠起点 = 出膛位置(_ready 只在首次入树时跑;不 request_ready 就会停在上一次的值,
	#    服务器拿 prev_pos→global_position 这条线段裁决 = 凭空横穿全图的一枪)
	var p: BulletBase = pool.acquire(BULLET_PATH)
	p.setup(Vector2.RIGHT, 600.0, 5000.0, 1.0, Color.WHITE, null)
	p.apply_damage = false
	p.global_position = Vector2(2400, 1500)
	add_child(p)
	var prev_ok := p.prev_pos == Vector2(2400, 1500)
	_chk(prev_ok, "复用后首帧扫掠起点 = 出膛位置(prev_pos=%s)" % str(p.prev_pos))
	p.despawn()

	# ⑧ 池化弹在自己的 _physics_process 里命中目标 → despawn 回池(离树发生在物理回调内,最容易踩"节点正忙")
	var enemy := _stub_enemy(Vector2(600, 400))
	var hitb: BulletBase = pool.acquire(BULLET_PATH)
	hitb.setup(Vector2.RIGHT, 6000.0, 5000.0, 1.0, Color.WHITE, null)
	hitb.apply_damage = false
	hitb.global_position = Vector2(400, 400)
	var idle_before_hit := pool.idle_count(BULLET_PATH)
	add_child(hitb)
	await _ticks(4)
	_chk(is_instance_valid(hitb) and hitb.get_parent() == null
			and pool.idle_count(BULLET_PATH) == idle_before_hit + 1,
			"命中自毁走 despawn:物理回调内离树并回池(实例仍有效=%s / 闲置 %d→%d)"
					% [is_instance_valid(hitb), idle_before_hit, pool.idle_count(BULLET_PATH)])
	enemy.free()

	# ⑨ 同一物理帧归还的实例不再借出(服务器的"这颗弹广播过没有"按实例 id 记账 —— 同帧复用会被判成同一颗)
	var q1: BulletBase = pool.acquire(BULLET_PATH)
	var q1_id := q1.get_instance_id()
	q1.despawn()
	var q2: BulletBase = pool.acquire(BULLET_PATH)
	var blocked := q2 != null and q2.get_instance_id() != q1_id
	if q2 != null:
		q2.despawn()
	await _ticks(1)
	var q3: BulletBase = pool.acquire(BULLET_PATH)
	_chk(blocked and q3 != null and (q3.get_instance_id() == q1_id or q3.get_instance_id() == q2.get_instance_id()),
			"同帧归还的实例不借出、隔一帧才复用(同帧被挡=%s)" % blocked)
	if q3 != null:
		q3.despawn()

	weapon.free()
	Level0.pvp_mode = false
	await _cleanup(pool)
	_finish()


# 池里留下的闲置实例会变成退出时的 RID 泄漏噪声,而噪声行落在判词之后会被聚合入口读成 NO-VERDICT。
func _cleanup(pool: BulletPool) -> void:
	var guard := 0
	while pool.idle_count(BULLET_PATH) > 0 and guard < 200:
		guard += 1
		await _ticks(1)   # 跨一帧,免得撞上"压一帧不借"把新实例借出来
		var b: BulletBase = pool.acquire(BULLET_PATH)
		if b == null:
			return
		b.free()


func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _only_bullet() -> BulletBase:
	var arr := get_tree().get_nodes_in_group("bullet")
	return arr[0] as BulletBase if arr.size() == 1 else null


func _weapon_fx_count(w: WeaponBase) -> int:
	return int(w.get("_laser") != null) + int(w.get("_explosion_marker") != null)


func _stub_enemy(at: Vector2) -> Node2D:
	var e := _StubEnemy.new()
	e.add_to_group("enemies")
	add_child(e)
	e.global_position = at
	return e


func _trail_of(n: Node) -> BulletTrail:
	for child in n.get_children():
		var t := child as BulletTrail
		if t != null:
			return t
	return null


func _count_of(n: Node, kind: String) -> int:
	if not is_instance_valid(n):
		return -1
	var c := 0
	for child in n.get_children():
		match kind:
			"Sprite2D":
				c += int(child is Sprite2D)
			"CollisionShape2D":
				c += int(child is CollisionShape2D)
			"trail":
				c += int(child is BulletTrail)
	return c


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[bullet_pool]   ✓ %s" % msg)
	else:
		_fails.append(msg)
		print("[bullet_pool]   ✗ %s" % msg)


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print(MARKER)
		get_tree().quit(0)
	else:
		print("BULLET POOL PROBE: FAIL")
		for f in _fails:
			print("[bullet_pool] FAIL: %s" % f)
		get_tree().quit(1)
