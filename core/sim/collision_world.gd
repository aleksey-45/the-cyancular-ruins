class_name CollisionWorld
extends RefCounted

# Godot 物理空间的薄适配层：碰撞层常量、统一的 RID 体运动求解、复用的
# ray/shape 查询参数、环面接缝几何与光束走廊接触采集。实体都是自管 RID 体，
# 命中归属经 body_attach_object_instance_id 反查，不维护 RID→role 注册表，
# 也不保存伤害、地形 HP 或历史世界副本。

# 物理层：地形、两支队伍的玩家、敌人、地面掉落物。
const LAYER_TERRAIN := 1
const LAYER_TEAM_A := 2
const LAYER_ENEMY := 4
const LAYER_TEAM_B := 16

## 队伍对应的玩家层；0 表示无队伍，与 A 队共用中性层。
static func team_layer(team: int) -> int:
	return LAYER_TEAM_B if team == 2 else LAYER_TEAM_A

# 一次 tick 的最大位移加上形状半径与 safe margin；接缝镜像只覆盖这个带宽。
const SEAM_REACH := 192.0
# 站姿和蹲姿箱各轴的外沿距原点最多 57 px。
const MIRROR_MARGIN := 57.0

# 统一运动求解的 margin：沿用 CharacterBody2D 的默认值，台阶与命中分类阈值都按它调校。
const MOTION_MARGIN := 0.08

static var _by_space: Dictionary = {}
# 串行模拟无重入，运动参数与结果对象全局复用；调用方在同一次调用内取走全部字段。
static var _motion_params := PhysicsTestMotionParameters2D.new()
static var _motion_result := PhysicsTestMotionResult2D.new()
# 槽位占位形状：body_add_shape 必须带形状，槽位补建后随即被 body_set_shape 覆盖。
# 静态成员保住引用——Shape2D 是引用计数资源，局部变量出函数即释放，体上形状随之消失。
static var placeholder := RectangleShape2D.new()

## 创建自管静态 RID 体。静态模式与地形一致：形状或位姿改动后重设本体变换即可同帧进宽相。
static func create_body(layer: int, mask: int) -> RID:
	var rid := PhysicsServer2D.body_create()
	PhysicsServer2D.body_set_mode(rid, PhysicsServer2D.BODY_MODE_STATIC)
	PhysicsServer2D.body_set_collision_layer(rid, layer)
	PhysicsServer2D.body_set_collision_mask(rid, mask)
	return rid

## 统一的实体运动求解：服务端、预测端、角色、弹丸与敌人走同一条 body_test_motion 路径。
## 返回 [hit, result]；result.travel 永远包含恢复推出量，调用方必须按 travel 前进自身数据位姿，
## 服务器变换由本函数直接写（其他实体的查询靠它同帧看到新位置）。
static func move_body(rid: RID, from: Transform2D, motion: Vector2) -> Array:
	var hit := probe_body(rid, from, motion, _motion_result)
	from.origin += _motion_result.get_travel()
	PhysicsServer2D.body_set_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM, from)
	return [hit, _motion_result]

## 只读探测（test_move 等价物）：不移动、不写变换。传入 result 可取得实际位移与接触信息。
## 显式开启 recovery_as_collision 可将恢复推出产生的接触也计为碰撞。
static func probe_body(rid: RID, from: Transform2D, motion: Vector2,
		result: PhysicsTestMotionResult2D = null, margin: float = MOTION_MARGIN,
		recovery_as_collision := false) -> bool:
	_motion_params.from = from
	_motion_params.motion = motion
	_motion_params.margin = margin
	_motion_params.recovery_as_collision = recovery_as_collision
	return PhysicsServer2D.body_test_motion(rid, _motion_params, result)

## 轴向阻挡判定：行程明显缩短或命中法线逆向都算被挡；
## 0.001 容差吸收恢复推出量。move_body_axes 与角色台阶路径共用同一判据。
static func axis_blocked(result: PhysicsTestMotionResult2D, axis: int, distance: float) -> bool:
	return absf(result.get_travel()[axis]) + 0.001 < absf(distance) \
			or result.get_collision_normal()[axis] * distance < 0.0

## X/Y 两轴依次推进的通用求解：命中即停，返回 {blocked, hits, position, ground}。
## blocked[axis] 非零表示该轴被挡（行程明显缩短或法线逆向）；hits 为 [{"rid", "id", "normal", "point"}]；
## ground 是向下被挡时的命中法线 y（未发生为 0），供调用方做着地判定。
static func move_body_axes(rid: RID, from: Transform2D, motion: Vector2) -> Dictionary:
	var blocked := Vector2.ZERO
	var hits: Array = []
	var ground := 0.0
	var current := from
	for axis in 2:
		var distance := motion[axis]
		if distance == 0.0:
			continue
		var travel := Vector2.ZERO
		travel[axis] = distance
		var out := move_body(rid, current, travel)
		var result: PhysicsTestMotionResult2D = out[1]
		current.origin += result.get_travel()
		if bool(out[0]) and axis_blocked(result, axis, travel[axis]):
			var normal: Vector2 = result.get_collision_normal()
			hits.append({"rid": result.get_collider_rid(), "id": result.get_collider_id(),
					"normal": normal, "point": result.get_collision_point()})
			blocked[axis] = signf(distance)
			if axis == 1 and distance > 0.0:
				ground = normal.y
	return {"blocked": blocked, "hits": hits, "position": current.origin, "ground": ground}

## 把形状载体（CollisionShape2D / CollisionPolygon2D）同步到 RID 体的服务器槽位。
## 载体只是形状与局部变换的只读来源，实体不再是节点物理体；active 槽之外的槽位全部停用。
## 结尾重设本体变换：自管体的形状改动必须踢一次才进宽相，同帧查询才可见。
static func sync_body_shapes(rid: RID, carriers: Array, pose: Transform2D, active: int = -1) -> void:
	if not rid.is_valid():
		return
	var count := carriers.size()
	while PhysicsServer2D.body_get_shape_count(rid) < count:
		PhysicsServer2D.body_add_shape(rid, placeholder)
	for i in count:
		var carrier: Node2D = carriers[i]
		var shape := carrier_shape(carrier)
		var disabled: bool = shape == null or (active >= 0 and i != active)
		PhysicsServer2D.body_set_shape_disabled(rid, i, disabled)
		if not disabled:
			PhysicsServer2D.body_set_shape(rid, i, shape)
			PhysicsServer2D.body_set_shape_transform(rid, i, carrier.transform)
	PhysicsServer2D.body_set_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM, pose)

# 载体的物理形状：矩形/基础形状直接用；多边形凸包化后缓存到节点 meta，运行期不重建。
static func carrier_shape(carrier: Node2D) -> Shape2D:
	if carrier is CollisionShape2D:
		return (carrier as CollisionShape2D).shape
	if carrier is CollisionPolygon2D:
		if carrier.has_meta("rid_shape"):
			return carrier.get_meta("rid_shape")
		var points := (carrier as CollisionPolygon2D).polygon
		if points.size() < 3:
			return null
		var convex := ConvexPolygonShape2D.new()
		convex.points = Geometry2D.convex_hull(points)
		carrier.set_meta("rid_shape", convex)
		return convex
	return null

## 只写位姿：形状槽位不变时（敌人/拾取物被 AI 或回放直接摆位）用这个轻量入口。
static func sync_body_pose(rid: RID, pose: Transform2D) -> void:
	if rid.is_valid():
		PhysicsServer2D.body_set_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM, pose)


var space := RID()
var terrain: Terrain

var _ray := PhysicsRayQueryParameters2D.create(Vector2.ZERO, Vector2.ZERO, 0)
var _shape := PhysicsShapeQueryParameters2D.new()
var _circle := CircleShape2D.new()
var _corridor := RectangleShape2D.new()

static func world_of(node: Node) -> World2D:
	var viewport := node as Viewport
	if viewport == null and node != null and node.is_inside_tree():
		viewport = node.get_viewport()
	return viewport.world_2d if viewport != null else null

## 取该节点所在物理空间的适配层；首次使用时创建并登记，场景树之外的节点由调用方保证已挂载。
static func acquire(node: Node) -> CollisionWorld:
	return for_space(world_of(node).space)

## 按空间取适配层；空间尚未绑定时登记新的适配层。
static func for_space(space_rid: RID) -> CollisionWorld:
	var id := space_rid.get_id()
	var existing: CollisionWorld = _by_space.get(id)
	if existing != null:
		return existing
	var created := CollisionWorld.new()
	created.space = space_rid
	_by_space[id] = created
	return created

static func release_terrain(space_rid: RID, owner: Terrain) -> void:
	var world: CollisionWorld = _by_space.get(space_rid.get_id())
	if world != null and world.terrain == owner:
		world.terrain = null
		_by_space.erase(space_rid.get_id())

# 直接空间状态必须在查询时取：跨物理帧缓存会拿到过期对象。
func direct() -> PhysicsDirectSpaceState2D:
	return PhysicsServer2D.space_get_direct_state(space)

## 规范位置在接缝覆盖带内时补出必要副本；中部位置只有一份。
## 索引 0 是本体，其余是 X/Y 镜像与角落镜像。
func mirror_offsets(position: Vector2) -> PackedVector2Array:
	if terrain == null:
		return PackedVector2Array([Vector2.ZERO])
	var size := terrain.map_size
	var reach := SEAM_REACH + MIRROR_MARGIN
	var x := 0.0
	var y := 0.0
	if position.x < reach:
		x = size.x
	elif position.x > size.x - reach:
		x = -size.x
	if position.y < reach:
		y = size.y
	elif position.y > size.y - reach:
		y = -size.y
	var out := PackedVector2Array([Vector2.ZERO])
	if x != 0.0:
		out.append(Vector2(x, 0.0))
	if y != 0.0:
		out.append(Vector2(0.0, y))
	if x != 0.0 and y != 0.0:
		out.append(Vector2(x, y))
	return out

## 形状在世界中的中心：普通物理体的位姿写在刚体变换上，镜像形状写在形状变换上。
static func shape_origin(rid: RID, index: int) -> Vector2:
	if not rid.is_valid():
		return Vector2.ZERO
	var body := PhysicsServer2D.body_get_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM) as Transform2D
	if index < 0 or index >= PhysicsServer2D.body_get_shape_count(rid):
		return body.origin
	return (body * PhysicsServer2D.body_get_shape_transform(rid, index)).origin

func ray_hit(from: Vector2, to: Vector2, mask: int, hit_from_inside := false) -> Dictionary:
	_ray.from = from
	_ray.to = to
	_ray.collision_mask = mask
	_ray.hit_from_inside = hit_from_inside
	return direct().intersect_ray(_ray)

func circle_overlaps(center: Vector2, radius: float, mask: int, exclude: Array = []) -> Array:
	_circle.radius = radius
	return shape_overlaps(_circle, Transform2D(0.0, center), mask, exclude)

## 任意形状重叠查询；返回 [{collider, collider_id, rid, shape}]。
func shape_overlaps(shape: Shape2D, from: Transform2D, mask: int, exclude: Array = []) -> Array:
	_shape.shape = shape
	_shape.transform = from
	_shape.motion = Vector2.ZERO
	_shape.collision_mask = mask
	_shape.exclude = exclude
	_shape.collide_with_bodies = true
	_shape.collide_with_areas = false
	_shape.margin = 0.0
	return direct().intersect_shape(_shape)

## 起点用圆形查询，线段用矩形查询，跨接缝先拆段。每个实体 RID 保留第一次接触。
func corridor_contacts(points: PackedVector2Array, radius: float, mask: int, exclude: Array = []) -> Array:
	var out: Array = []
	if points.size() < 2 or radius <= 0.0:
		return out
	var size := terrain.map_size
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
			# 规范坐标只用于物理查询；接触点必须回到连续光束坐标，否则跨接缝会推到错误端点。
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

# 把规范空间内的命中形状投影到连续的攻击路径上。
func _collect(entries: Array, from: Vector2, to: Vector2, offset: Vector2,
		seen: Dictionary, out: Array) -> void:
	for entry: Dictionary in entries:
		var target := entry["collider"] as Node2D
		var rid: RID = entry["rid"]
		if target == null or seen.has(rid):
			continue
		seen[rid] = true
		var point := from + offset
		if to.distance_squared_to(from) > 1e-6:
			point = Geometry2D.get_closest_point_to_segment(
					shape_origin(rid, int(entry["shape"])), from, to) + offset
		out.append({"target": target, "point": point})

## 环面查询位置：本体加上查询半径够得着的镜像副本中心，避免接缝另一侧的实体漏检。
func toroidal_centers(center: Vector2, reach: float) -> PackedVector2Array:
	var size := terrain.map_size
	var xs: Array = []
	if center.x < reach:
		xs.append(size.x)
	elif center.x > size.x - reach:
		xs.append(-size.x)
	var ys: Array = []
	if center.y < reach:
		ys.append(size.y)
	elif center.y > size.y - reach:
		ys.append(-size.y)
	var out := PackedVector2Array([center])
	for x: float in xs:
		out.append(center + Vector2(x, 0.0))
	for y: float in ys:
		out.append(center + Vector2(0.0, y))
	for x: float in xs:
		for y: float in ys:
			out.append(center + Vector2(x, y))
	return out

## 当前位置就在接缝且朝外时，走一小段进入下一份地图。
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
