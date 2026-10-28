extends SceneTree

# 受击判定几何冒烟(纯逻辑 -s,不读地图、不引 autoload)。
# 最强保证:HitShape 的扫掠/环面整幅锚定/受击面取活动箱/点到框距离/最早命中/可受击过滤按设计工作;测不到几何数值与手感。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/hit_shape_smoke.gd;通过 = 结尾打 HIT SHAPE OK(n 条断言)。

const EXPECTED_CHECKS := 13
const HitShape := preload("res://core/sim/hit_shape.gd")

var _fails: Array[String] = []
var _checks := 0
var _nodes: Array[Node] = []


func _initialize() -> void:
	var box := Rect2(20.0, -10.0, 20.0, 20.0)

	# ① 线段穿过矩形:入点参数 t=0.2,入射点 (20,0)
	var t := HitShape.segment_hits_rect(Vector2(0, 0), Vector2(100, 0), box)
	var entry := HitShape.segment_entry_point(Vector2(0, 0), Vector2(100, 0), box)
	_chk(_eq(t, 0.2) and entry.is_equal_approx(Vector2(20, 0)), "线段穿框:t=0.2 且入射点=(20,0)")

	# ② 起点在框内:向任意方向出发都算命中且 t=0(高速弹在目标体内生成时不能漏)
	var inside := HitShape.segment_hits_rect(Vector2(30, 0), Vector2(100, 0), box)
	var inside_back := HitShape.segment_hits_rect(Vector2(30, 0), Vector2(-100, 0), box)
	_chk(_eq(inside, 0.0) and _eq(inside_back, 0.0), "起点在框内:正向/反向出框都 t=0")

	# ③ 完全不相交的线段返回 -1
	_chk(HitShape.segment_hits_rect(Vector2(0, 0), Vector2(100, 0), Rect2(20, 20, 20, 20)) < 0.0,
			"未相交:t=-1")

	# ④ 贴边(沿矩形上边)与角相切都算命中
	var edge := HitShape.segment_hits_rect(Vector2(0, -10), Vector2(100, -10), box)
	var corner := HitShape.segment_hits_rect(Vector2(0, 0), Vector2(40, 40), Rect2(20, 20, 10, 10))
	_chk(_eq(edge, 0.2) and _eq(corner, 0.5), "贴边/角相切:两者都算命中(0.2 / 0.5)")

	# ⑤ 环面:矩形在 994..998,线段 -10→10 穿过接缝 ⇒ 命中 0.2
	var seam_box := Rect2(994.0, -10.0, 4.0, 20.0)
	var seam_hit := HitShape.segment_hits_rect(Vector2(-10, 0), Vector2(10, 0), seam_box, 1000.0, 1000.0)
	_chk(_eq(seam_hit, 0.2), "环面接缝:整幅锚定后命中 t=0.2")

	# 反证:同一份几何不传环面尺寸 ⇒ 相对线段在 994..998,必须 miss
	_chk(HitShape.segment_hits_rect(Vector2(-10, 0), Vector2(10, 0), seam_box) < 0.0,
			"反证:不锚定环面则同一线段 miss(证明上面那条不是恒真)")

	# ⑦ rect_at 只整幅平移:中心 996 → 离 anchor(-10) 最近的副本中心 -4
	var moved := HitShape.rect_at(seam_box, Vector2(-10, 0), 1000.0, 1000.0)
	_chk(_eq(moved.get_center().x, -4.0), "rect_at:按整幅(w=1000)平移,中心 996→-4")

	# ⑧ rect_of 只并启用中的碰撞箱:禁用/启用切换后 AABB 立即变(姿态箱的旧 bug 形态)
	var body := _body_with_polys()
	var before := HitShape.rect_of(body)
	(body.get_child(0) as CollisionPolygon2D).disabled = true
	(body.get_child(1) as CollisionPolygon2D).disabled = false
	var after := HitShape.rect_of(body)
	_chk(before.size.is_equal_approx(Vector2(40, 40)) and after.size.is_equal_approx(Vector2(80, 60)),
			"rect_of:只并启用箱(40×40 → 切姿态后 80×60)")

	# ⑨ 受击面默认 = 碰撞箱 AABB;HURT_MARGIN=0 不改变平衡
	_chk(HitShape.hurt_rect_of(body).is_equal_approx(after), "hurt_rect_of = rect_of(margin 默认 0)")

	# ⑩ 点到矩形距离:框内 0;右侧 5px;对角 3-4-5
	var d_in := HitShape.distance_px_to_rect(Vector2(100, 100), Rect2(80, 80, 40, 40))
	var d_side := HitShape.distance_px_to_rect(Vector2(125, 100), Rect2(80, 80, 40, 40))
	var d_diag := HitShape.distance_px_to_rect(Vector2(123, 124), Rect2(80, 80, 40, 40))
	_chk(_eq(d_in, 0.0) and _eq(d_side, 5.0) and _eq(d_diag, 5.0), "distance:框内 0 / 侧向 5 / 对角 3-4-5")

	# ⑪ 多矩形取最早命中;全不中返回空字典
	var rects: Array[Rect2] = [Rect2(80, -10, 20, 20), Rect2(30, -10, 20, 20), Rect2(200, -10, 20, 20)]
	var first := HitShape.first_hit(Vector2(0, 0), Vector2(300, 0), rects, Vector2.ZERO, 0.0, 0.0)
	var none := HitShape.first_hit(Vector2(0, 100), Vector2(300, 100), rects, Vector2.ZERO, 0.0, 0.0)
	_chk(int(first.get("index", -1)) == 1 and _eq(float(first.get("t", -1.0)), 0.1) and none.is_empty(),
			"first_hit:取最早(index=1,t=0.1);全不中 = 空")

	# ⑫ 可受击过滤:layer 0(回溯隐藏尸体)= false;layer 4 = true;非碰撞体节点 = true
	var hidden := CharacterBody2D.new()
	hidden.collision_layer = 0
	root.add_child(hidden)
	_nodes.append(hidden)
	var live := CharacterBody2D.new()
	live.collision_layer = 4
	root.add_child(live)
	_nodes.append(live)
	var plain := Node2D.new()
	root.add_child(plain)
	_nodes.append(plain)
	_chk(not HitShape.hurtable(hidden) and HitShape.hurtable(live) and HitShape.hurtable(plain),
			"hurtable:layer0 否 / layer4 是 / 非碰撞体 是")

	var pt_in := HitShape.segment_hits_rect(Vector2(30, 0), Vector2(30, 0), box)
	var pt_out := HitShape.segment_hits_rect(Vector2(0, 0), Vector2(0, 0), box)
	_chk(_eq(pt_in, 0.0) and pt_out < 0.0, "退化线段(点):框内 t=0 / 框外 -1")

	_finish()


func _body_with_polys() -> Node2D:
	var body := Node2D.new()
	body.position = Vector2(100, 100)
	var a := CollisionPolygon2D.new()
	a.polygon = PackedVector2Array([Vector2(-20, -20), Vector2(20, -20), Vector2(20, 20), Vector2(-20, 20)])
	body.add_child(a)
	var b := CollisionPolygon2D.new()
	b.polygon = PackedVector2Array([Vector2(-40, -30), Vector2(40, -30), Vector2(40, 30), Vector2(-40, 30)])
	b.disabled = true
	body.add_child(b)
	root.add_child(body)
	_nodes.append(body)
	return body


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _eq(a: float, b: float) -> bool:
	return absf(a - b) <= 0.001


func _finish() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	# 条数闸:实跑条数对不上 = 有断言被静默跳过(脚本错误只中断当前函数,不会让进程红)。
	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("HIT SHAPE OK(%d 条断言):扫掠/环面锚定/活动箱/距离/最早命中/可受击过滤" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("HIT SHAPE FAILED: %d 处" % _fails.size())
		quit(1)
