extends SceneTree

# 子弹对象池冒烟(纯逻辑 -s,不实例化场景树、不引 autoload):池的账本 + 复用复位清单。

const EXPECTED_CHECKS := 5
const BULLET_PATH := "res://scenes/weapons/bullet.tscn"
const GRENADE_PATH := "res://scenes/weapons/grenade_bullet.tscn"
const POOL_PATH := "res://core/present/bullet_pool.gd"
# 复位清单(tests 侧独立抄一份:从 BulletBase 里读字段名 = 让被测方自己出题,漏一项永远测不出来)。
const RESET_FIELDS: Array[String] = [
	"global_position", "prev_pos", "velocity_vec", "speed", "traveled", "max_range", "size",
	"rotation", "gravity_factor", "breaks_terrain", "has_aoe", "bullet_color",
	"source", "shooter", "hit_damage", "hit_impact", "apply_damage",
	"explodes", "direct_hit_damage", "fuse_time", "hit_fuse_time",
	"explosion_radius", "explosion_damage", "explosion_knockback", "explosion_visual",
	"tile_break_unit", "visible", "modulate",
	"_fuse_active", "_fuse_elapsed", "_fuse_duration", "_settle_frames",
]

var _fails: Array[String] = []
var _checks := 0
var _stub := Node.new()   # source / shooter 的类型是 Node:脏化时得给它一个真节点(SceneTree 本身不是 Node)


func _initialize() -> void:
	# 空载守卫:任何一项 load 失败都立刻 quit —— 否则下面抛错走不到 quit(),进程永久挂起。
	var pool_script: GDScript = load(POOL_PATH) as GDScript
	var bullet_scene: PackedScene = load(BULLET_PATH) as PackedScene
	var grenade_scene: PackedScene = load(GRENADE_PATH) as PackedScene
	if pool_script == null or bullet_scene == null or grenade_scene == null or not pool_script.can_instantiate():
		printerr("BULLET POOL SMOKE: 空载 —— load() 失败(%s / %s / %s)" % [POOL_PATH, BULLET_PATH, GRENADE_PATH])
		quit(1)
		return
	var pool = pool_script.new()
	var cap: int = pool.MAX_PER_SCENE

	# ① 复用后的状态与"新建一颗"逐字段等价(每轮先把每个字段写成垃圾值:漏复位的那一项就对不上)
	var fresh = bullet_scene.instantiate()
	var reused = pool.acquire(BULLET_PATH)
	var reused_id: int = reused.get_instance_id()
	for round in 3:
		_dirty(reused)
		pool.release(reused)
		await physics_frame
		reused = pool.acquire(BULLET_PATH)
	var bad: Array[String] = []
	for f in RESET_FIELDS:
		if not _same(fresh.get(f), reused.get(f)):
			bad.append("%s(新建 %s / 复用 %s)" % [f, str(fresh.get(f)), str(reused.get(f))])
	# ★ 稳定性判据:必须是**同一个实例**走过 3 轮 —— 否则"与新建等价"对一颗真新建的实例恒真(空转)
	var same_instance: bool = reused.get_instance_id() == reused_id
	if bad.is_empty() and same_instance:
		_chk(true, "同一实例复用 3 次后与新建一颗逐字段等价(逐项 %d 字段)" % RESET_FIELDS.size())
	else:
		_chk(false, "复用后与新建一颗不等价(同一实例=%s / 不等价字段:%s)" % [same_instance, ", ".join(bad)])

	# ② 场景 @export 初值还原的是 .tscn 那份,不是代码默认值(榴弹写回默认值 = 不爆炸的直弹)
	var grenade = pool.acquire(GRENADE_PATH)
	var grenade_id: int = grenade.get_instance_id()
	grenade.explodes = false
	grenade.fuse_time = 9.0
	grenade.explosion_radius = 1.0
	grenade.tile_break_unit = 1.0
	pool.release(grenade)
	await physics_frame
	grenade = pool.acquire(GRENADE_PATH)
	_chk(grenade.explodes and is_equal_approx(grenade.fuse_time, 0.3)
			and is_equal_approx(grenade.explosion_radius, 350.0) and is_equal_approx(grenade.tile_break_unit, 0.5)
			and grenade.get_instance_id() == grenade_id,
			"榴弹复用后仍是场景初值(explodes=%s fuse=%s radius=%s unit=%s 同一实例=%s)"
					% [grenade.explodes, grenade.fuse_time, grenade.explosion_radius, grenade.tile_break_unit,
					grenade.get_instance_id() == grenade_id])

	# ③ meta 清零(它们是跨发累积的玩法闩,不是缓存):grenade_direct_hit 留着 = 复用后的榴弹永不结算直击
	var m = pool.acquire(BULLET_PATH)
	var m_id: int = m.get_instance_id()
	m.set_meta("grenade_direct_hit", true)
	m.set_meta("damage_subsidy", true)
	m.set_meta("rw_hit_ids", [1, 2, 3])
	pool.release(m)
	await physics_frame
	m = pool.acquire(BULLET_PATH)
	var leftover: Array = []
	for k in m.get_meta_list():
		if String(k) != "scene_path":
			leftover.append(String(k))
	_chk(leftover.is_empty() and String(m.get_meta("scene_path", "")) == BULLET_PATH
			and m.get_instance_id() == m_id,
			"复用后只剩池写的 scene_path(残留=%s / scene_path=%s / 同一实例=%s)"
					% [str(leftover), str(m.get_meta("scene_path", "")), m.get_instance_id() == m_id])

	# ④ 双 release 幂等:同一实例不许在池里排两次(否则会被两个调用方同时拿到)。
	# ★ 必须排在上限检查之前:池满时归还的实例会被立刻销毁(见 ⑤),那就测不到"排两次"了。
	var dup = pool.acquire(BULLET_PATH)
	pool.release(dup)
	pool.release(dup)
	await physics_frame
	var d2 = pool.acquire(BULLET_PATH)
	var d3 = pool.acquire(BULLET_PATH)
	_chk(d2 != d3 and (d2 == dup or d3 == dup),
			"双 release 幂等:两次借出拿到不同实例,且其中一个是刚归还的那颗")

	# ⑤ 池上限:超出的闲置实例被销毁(不攒节点),借出时回落 instantiate 且每次拿到不同实例
	var held: Array = []
	var ids: Dictionary = {}
	for i in cap + 1:
		var b = pool.acquire(BULLET_PATH)
		held.append(b)
		ids[b.get_instance_id()] = true
	for b in held:
		pool.release(b)
	# 归还 cap+1 个而闲置仍是 cap ⇒ 多出来的那个真的被销毁了(不是攒在池里)
	_chk(ids.size() == cap + 1 and pool.idle_count(BULLET_PATH) == cap,
			"池上限 %d:超出的回落 instantiate(实得 %d 个不同实例)且闲置封顶(实得 %d)"
					% [cap, ids.size(), pool.idle_count(BULLET_PATH)])

	for n in [fresh, reused, grenade, m, d2, d3]:
		if is_instance_valid(n):
			n.free()
	# 池里留着的孤儿节点必须在退出前释放:否则 -s 退出时打一串 RID 泄漏 ERROR,而那些行落在判词之后,
	# 聚合入口会把它读成 NO-VERDICT(等于把一支绿的闸变成红的)。每轮跨一帧,免得撞上"压一帧不借"。
	await _drain(pool)
	_stub.free()
	_finish()


func _drain(pool) -> void:
	var guard := 0
	while pool.idle_count(BULLET_PATH) > 0 and guard < 200:
		guard += 1
		await physics_frame
		var b = pool.acquire(BULLET_PATH)
		if b != null:
			b.free()


# 把每一个复位项都写成"不可能来自场景初值"的值:漏复位的那一项就会和新建的那颗对不上。
func _dirty(b) -> void:
	b.global_position = Vector2(777, 888)
	b.prev_pos = Vector2(-1, -2)
	b.velocity_vec = Vector2(3, 4)
	b.speed = 1234.0
	b.traveled = 5678.0
	b.max_range = 9.0
	b.size = 3.0
	b.scale = Vector2(3, 3)
	b.rotation = 1.5
	b.gravity_factor = 2.0
	b.breaks_terrain = true
	b.has_aoe = true
	b.bullet_color = Color.RED
	b.source = _stub
	b.shooter = _stub
	b.hit_damage = 99
	b.hit_impact = 999.0
	b.apply_damage = false
	b.explodes = true
	b.direct_hit_damage = 77
	b.fuse_time = 8.0
	b.hit_fuse_time = 7.0
	b.explosion_radius = 6.0
	b.explosion_damage = 55
	b.explosion_knockback = 5.0
	b.explosion_visual = load(BULLET_PATH)
	b.tile_break_unit = 4.0
	b.visible = false
	b.modulate = Color.BLUE
	b.set("_fuse_active", true)
	b.set("_fuse_elapsed", 0.9)
	b.set("_fuse_duration", 0.8)
	b.set("_settle_frames", 3)


func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return is_equal_approx(a, b)   # 复位写的是字面量,容差只为吃掉 -0.0 这类表示噪声
	return a == b


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
		print("BULLET POOL SMOKE OK(%d checks)" % _checks)
		quit(0)
	else:
		print("BULLET POOL SMOKE FAIL")
		for f in _fails:
			print("[bullet_pool] FAIL: %s" % f)
		quit(1)
