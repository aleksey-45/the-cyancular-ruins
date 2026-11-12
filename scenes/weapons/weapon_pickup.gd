class_name WeaponPickup
extends ServerBody

# 地面可拾取武器实体：自管 RID 物理体，掉落与静止由显式逐步移动求解。

# 掉落物碰撞层：层 4（值 8），掩码包含地形（1）与其他掉落物（8）
const LAYER_GROUND := 8
const MASK_GROUND := 9

# 世界渲染缩放倍率
const WORLD_SCALE := 2.5

@export var type_id: int = 1
var locked_role := 0
var unlock_tick := 0
var solo_unlock_ms := 0
var time_field: TimeField
var inst: int = 0
var carried: int = 0
var _settled: bool = false
# 自管 RID 体生命周期在 ServerBody；着地状态与形状槽在此补充。
var velocity := Vector2.ZERO
var _grounded := false
# 形状载体（_build_collision 建出的 "Shape" 节点）
var hulls: Array = []


func _enter_tree() -> void:
	super()   # 空间挂接、层掩码提交与归属挂载
	# 此时 hulls 还没填充（_ready 才建形状），只提交当前位姿。
	CollisionWorld.sync_body_pose(_rid, global_transform)

func _sync_collision() -> void:
	if _physics != null:
		CollisionWorld.sync_body_shapes(_rid, hulls, global_transform)

# 逻辑坐标与渲染坐标：
# canonical_pos 保持在 [0, MAP) 逻辑区间内，供服务端物理模拟与拾取判定使用；
# global_position 为渲染坐标，通过 set_anchor 映射到距离本地视口最近的可视副本位置。
var canonical_pos: Vector2 = Vector2.ZERO
var _anchor: Vector2 = Vector2.ZERO
var _has_anchor: bool = false


func set_anchor(p: Vector2) -> void:
	_anchor = p
	_has_anchor = true


# 根据逻辑坐标更新最近可视副本的渲染位置；每帧渲染路径，槽位不变只写位姿。
func sync_render_from_canonical() -> void:
	if not _has_anchor:
		global_position = canonical_pos
		CollisionWorld.sync_body_pose(_rid, global_transform)
		return
	global_position = GridPathfinder.anchor_to_nearest(canonical_pos, _anchor, terrain.map_size)
	CollisionWorld.sync_body_pose(_rid, global_transform)


func _ready() -> void:
	collision_layer = LAYER_GROUND
	collision_mask = MASK_GROUND
	_apply_layers()
	scale = Vector2(WORLD_SCALE, WORLD_SCALE)
	rotation = 0.0
	if canonical_pos == Vector2.ZERO:
		canonical_pos = global_position
	var spec := WeaponRegistry.definition(type_id)
	var bounds: Rect2 = spec["pickup_bounds"]
	if DisplayServer.get_name() != "headless":
		add_child(make_view(spec))
	var hull := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = bounds.size
	hull.shape = rect
	add_child(hull)
	hulls = [hull]
	_sync_collision()

static func make_view(spec: Dictionary) -> Sprite2D:
	var sprite := WeaponBase.make_sprite(spec["region"])
	var bounds: Rect2 = spec["pickup_bounds"]
	sprite.offset = -bounds.get_center()
	return sprite

func configure(p_type_id: int, p_inst: int, p_carried: int, p_vel: Vector2) -> void:
	type_id = p_type_id
	inst = p_inst
	carried = p_carried
	velocity = p_vel


## 地图散布点是地板上方的格心。让碰撞箱底部从下方格的上沿向下寻找落脚面。
func settle_on_spawn_floor() -> void:
	if hulls.is_empty():
		return
	var hull := hulls[0] as CollisionShape2D
	var height := (hull.shape as RectangleShape2D).size.y * global_transform.y.length()
	var from := global_transform
	from.origin.y += (GameParameters.TILE_SIZE - height) * 0.5 - CollisionWorld.MOTION_MARGIN
	var result := PhysicsTestMotionResult2D.new()
	# 换局时旧拾取物可能还在等待释放，预置武器以地形为支撑。
	var previous_mask := collision_mask
	collision_mask = CollisionWorld.LAYER_TERRAIN
	_apply_layers()
	var hit := CollisionWorld.probe_body(_rid, from, Vector2(0.0, GameParameters.TILE_SIZE),
			CollisionWorld.MOTION_MARGIN, false, result)
	collision_mask = previous_mask
	_apply_layers()
	if not hit or result.get_collision_normal().y >= -0.5:
		return
	global_position = from.origin + result.get_travel()
	_recompute_canonical()
	sync_render_from_canonical()
	velocity = Vector2.ZERO
	_grounded = true
	_settled = true


func _physics_process(delta: float) -> void:
	simulate_tick(time_field.world_delta(delta) if time_field != null else delta)

func simulate_tick(delta: float) -> void:
	if _settled:
		_unstick_up()
		sync_render_from_canonical()
		return
	velocity.y += PlayerParams.weapon_fall_gravity * delta
	if _grounded:
		velocity.x *= exp(-PlayerParams.weapon_ground_friction * delta)
	else:
		velocity.x *= exp(-PlayerParams.weapon_air_drag * delta)
	_move(velocity * delta)
	_recompute_canonical()
	_unstick_up()
	sync_render_from_canonical()
	if _grounded and absf(velocity.x) < PlayerParams.weapon_stop_eps:
		velocity = Vector2.ZERO
		_settled = true


# 两轴推进、命中即停；向下被挡且法线朝上即着地。axis_move 已写回位姿，槽位不动。
func _move(motion: Vector2) -> void:
	var out := axis_move(motion)
	var blocked: Vector2 = out["blocked"]
	_grounded = false
	if blocked.x != 0.0:
		velocity.x = 0.0
	if blocked.y > 0.0:
		velocity.y = 0.0
		_grounded = float(out["ground"]) < -0.5


# 将物理位置约束折叠至环面规范坐标区间
func _recompute_canonical() -> void:
	canonical_pos = GridPathfinder.wrap_to_range(global_position, terrain.map_size)


# 生成或重建时若与实心地形重叠：零位移重叠检测，逐格向上推出。
func _unstick_up() -> bool:
	if not CollisionWorld.probe_body(_rid, global_transform, Vector2.ZERO, 0.0, true):
		return false
	for i in 8:
		global_position.y -= float(GameParameters.TILE_SIZE)
		# 顶起过程只挪位姿；形状槽不变。
		CollisionWorld.sync_body_pose(_rid, global_transform)
		if not CollisionWorld.probe_body(_rid, global_transform, Vector2.ZERO, 0.0, true):
			velocity.y = 0.0
			_grounded = false # 推出后要重新落地。
			_settled = false
			_recompute_canonical()
			return true
	return false
