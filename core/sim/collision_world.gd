class_name CollisionWorld
extends RefCounted

# 提供二维物理空间的位移检测、射线查询和形状查询。跨地图边缘的查询可从另一侧接续。

const LAYER_TERRAIN := 1
const LAYER_TEAM_A := 2
const LAYER_ENEMY := 4
const LAYER_TEAM_B := 16

## 未分队的玩家沿用 A 队的碰撞层。B 队有自己的碰撞层。
static func team_layer(team: int) -> int:
	return LAYER_TEAM_B if team == 2 else LAYER_TEAM_A

# 将地图两侧的地形碰撞各延伸这么多像素，便于跨越边缘时仍能检测碰撞。
const SEAM_REACH := 192.0
# 站立或蹲伏时，角色碰撞形状任一边到原点的最大距离，单位为像素。
const MIRROR_MARGIN := 57.0

# 移动检测时，两个形状在此距离内就会尝试分开。数值取自 CharacterBody2D.safe_margin 的默认值。
const MOTION_MARGIN := 0.08

# 这套移动检测在同一线程依次执行，因此各次查询共用参数对象。
static var _motion_params := PhysicsTestMotionParameters2D.new()
static var _rectangles: Dictionary[Vector2, RectangleShape2D] = {}

static func rectangle(size: Vector2) -> RectangleShape2D:
	var shape: RectangleShape2D = _rectangles.get(size)
	if shape == null:
		shape = RectangleShape2D.new()
		shape.size = size
		_rectangles[size] = shape
	return shape

## 通过物理服务器创建静态物理体，并设置碰撞层与碰撞遮罩。
static func create_body(layer: int, mask: int) -> RID:
	var rid := PhysicsServer2D.body_create()
	PhysicsServer2D.body_set_mode(rid, PhysicsServer2D.BODY_MODE_STATIC)
	PhysicsServer2D.body_set_collision_layer(rid, layer)
	PhysicsServer2D.body_set_collision_mask(rid, mask)
	return rid

## 从给定起点检测位移。可通过 result 读取允许的位移和接触信息，物理体仍在原位。
## 开启 recovery_as_collision 后，为解除初始重叠而发生的接触也会被报告为碰撞。
static func probe_body(rid: RID, from: Transform2D, motion: Vector2,
		result: PhysicsTestMotionResult2D = null, margin: float = MOTION_MARGIN,
		recovery_as_collision := false) -> bool:
	_motion_params.from = from
	_motion_params.motion = motion
	_motion_params.margin = margin
	_motion_params.recovery_as_collision = recovery_as_collision
	return PhysicsServer2D.body_test_motion(rid, _motion_params, result)

## 沿某一轴的移动未达到预期距离，或碰撞法线沿该轴指向移动的反方向时，算作受阻。
## 距离比较容许 0.001 像素的误差。这一判断也用于角色的台阶检测。
static func axis_blocked(result: PhysicsTestMotionResult2D, axis: int, distance: float) -> bool:
	return absf(result.get_travel()[axis]) + 0.001 < absf(distance) \
			or result.get_collision_normal()[axis] * distance < 0.0

var world := World2D.new()
var map_size: Vector2

var _ray := PhysicsRayQueryParameters2D.create(Vector2.ZERO, Vector2.ZERO, 0)
var _shape := PhysicsShapeQueryParameters2D.new()
var _circle := CircleShape2D.new()
var _corridor := RectangleShape2D.new()

func _init(size: Vector2) -> void:
	map_size = size

## 计算当前角色碰撞形状跨边缘的平移偏移量。
## 第一项为零偏移，表示当前位置。靠近角落时，还包括沿两轴平移的偏移量。
func mirror_offsets(position: Vector2) -> PackedVector2Array:
	var size := map_size
	var reach := (size * 0.5).min(Vector2.ONE * (SEAM_REACH + MIRROR_MARGIN))
	var x := 0.0
	var y := 0.0
	if position.x < reach.x:
		x = size.x
	elif position.x > size.x - reach.x:
		x = -size.x
	if position.y < reach.y:
		y = size.y
	elif position.y > size.y - reach.y:
		y = -size.y
	var out := PackedVector2Array([Vector2.ZERO])
	if x != 0.0:
		out.append(Vector2(x, 0.0))
	if y != 0.0:
		out.append(Vector2(0.0, y))
	if x != 0.0 and y != 0.0:
		out.append(Vector2(x, y))
	return out

## 查询结果中的形状原点转换为世界坐标。
static func shape_origin(rid: RID, index: int) -> Vector2:
	var body := PhysicsServer2D.body_get_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM) as Transform2D
	return (body * PhysicsServer2D.body_get_shape_transform(rid, index)).origin

func ray_hit(from: Vector2, to: Vector2, mask: int, hit_from_inside := false) -> Dictionary:
	_ray.from = from
	_ray.to = to
	_ray.collision_mask = mask
	_ray.hit_from_inside = hit_from_inside
	return world.direct_space_state.intersect_ray(_ray)

func circle_overlaps(center: Vector2, radius: float, mask: int, exclude: Array = []) -> Array:
	_circle.radius = radius
	return shape_overlaps(_circle, Transform2D(0.0, center), mask, exclude)

## 查找与指定形状重叠的物体，结果中的形状索引可区分同一物理体上的不同碰撞形状。
func shape_overlaps(shape: Shape2D, from: Transform2D, mask: int, exclude: Array = []) -> Array:
	_shape.shape = shape
	_shape.transform = from
	_shape.motion = Vector2.ZERO
	_shape.collision_mask = mask
	_shape.exclude = exclude
	_shape.collide_with_bodies = true
	_shape.collide_with_areas = false
	_shape.margin = 0.0
	return world.direct_space_state.intersect_shape(_shape)

enum CorridorContact { TARGET, POINT }

## 光束起点用圆形检测，路径各段用矩形检测，用于找出整个光束宽度范围内接触的物体。
## 路径越过地图边缘时拆开查询。同一物理体即使被多段光束碰到，也只算一次。
func corridor_contacts(points: PackedVector2Array, radius: float, mask: int, exclude: Array = []) -> Array:
	var out: Array = []
	if points.size() < 2 or radius <= 0.0:
		return out
	var size := map_size
	var seen := {}
	var first := GridPathfinder.wrap_to_range(points[0], size)
	_corridor_at(first, first, radius, mask, exclude, points[0] - first, seen, out)
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var motion := b - a
		var length := motion.length()
		if length <= 0.0:
			continue
		var dir := motion / length
		var p := GridPathfinder.wrap_to_range(a, size)
		var remaining := length
		while remaining > 0.0:
			var run := seam_run(p, dir, size, remaining)
			# 先在地图范围内检测这一段，再把命中位置换回绘制光束时所用的坐标。
			_corridor_at(p, p + dir * run, radius, mask, exclude,
					a + dir * (length - remaining) - p, seen, out)
			p = GridPathfinder.wrap_to_range(p + dir * run, size)
			remaining -= run
	return out

func _corridor_at(from: Vector2, to: Vector2, radius: float, mask: int, exclude: Array,
		offset: Vector2, seen: Dictionary, out: Array) -> void:
	var motion := to - from
	var length := motion.length()
	if length <= 0.0:
		_collect(circle_overlaps(from, radius, mask, exclude), from, from, offset, seen, out)
		return
	_corridor.size = Vector2(length + 0.5, radius * 2.0)
	_collect(shape_overlaps(_corridor, Transform2D(motion.angle(), (from + to) * 0.5), mask, exclude),
			from, to, offset, seen, out)

# 用离碰撞形状原点最近的线段点来估算光束接触位置。
func _collect(entries: Array, from: Vector2, to: Vector2, offset: Vector2,
		seen: Dictionary, out: Array) -> void:
	for entry: Dictionary in entries:
		var target := entry["collider"] as ActorBody
		var rid: RID = entry["rid"]
		if target == null or seen.has(rid):
			continue
		seen[rid] = true
		var point := from + offset
		if to.distance_squared_to(from) > 1e-6:
			point = Geometry2D.get_closest_point_to_segment(
					shape_origin(rid, int(entry["shape"])), from, to) + offset
		out.append([target, point])

## 沿移动方向找第一个地图边缘，最远只检查到剩余位移的终点。
## 起点恰好在边缘时，至少前进一小段，防止重复检测同一位置。
static func seam_run(p: Vector2, d: Vector2, size: Vector2, remaining: float) -> float:
	var run := remaining
	if d.x > 0.0:
		run = minf(run, (size.x - p.x) / d.x)
	elif d.x < 0.0:
		run = minf(run, -p.x / d.x)
	if d.y > 0.0:
		run = minf(run, (size.y - p.y) / d.y)
	elif d.y < 0.0:
		run = minf(run, -p.y / d.y)
	return minf(remaining, maxf(run, 1e-3))
