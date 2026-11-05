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
var inst: int = 0
var mag: int = 0
var drop_velocity: Vector2 = Vector2.ZERO
var _settled: bool = false
# 未实现机制的预留状态：掉落物存在时长（拾取优先级/限时消失等待接入），勿删。
var _age: float = 0.0
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
	if _world_space.is_valid():
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
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	global_position = GridPathfinder.anchor_to_nearest(canonical_pos, _anchor, w, h) if (w > 0.0 and h > 0.0) else canonical_pos
	CollisionWorld.sync_body_pose(_rid, global_transform)


func _ready() -> void:
	collision_layer = LAYER_GROUND
	collision_mask = MASK_GROUND
	_apply_layers()
	scale = Vector2(WORLD_SCALE, WORLD_SCALE)
	rotation = 0.0
	if canonical_pos == Vector2.ZERO:
		canonical_pos = global_position
	if get_child_count() == 0:
		_build_visual()
		_build_collision()
	velocity = drop_velocity
	_sync_collision()


# 配置地面武器属性（必须在加入场景树前调用，或加入后动态重建）
func configure(p_type_id: int, p_inst: int, p_mag: int, p_vel: Vector2) -> void:
	type_id = p_type_id
	inst = p_inst
	mag = p_mag
	drop_velocity = p_vel
	velocity = p_vel
	_settled = false
	if not is_inside_tree():
		return
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_build_visual()
	_build_collision()
	_sync_collision()


func _build_visual() -> void:
	var scene_path := WeaponRegistry.scene_of(type_id)
	var scene: PackedScene = load(scene_path) if not scene_path.is_empty() else null
	if scene == null:
		push_warning("WeaponPickup: 槽 %d 没有武器场景,地面掉落物将是空壳" % type_id)
		return
	var w: Node2D = scene.instantiate()
	w.name = "Visual"
	w.scale = Vector2.ONE
	w.rotation = 0.0
	add_child(w)


func _build_collision() -> void:
	var vis := get_node_or_null("Visual") as Node2D
	if vis == null:
		return
	var spr: Sprite2D = vis.get_node_or_null("Sprite2D")
	if spr == null:
		return
	var r: Rect2 = SpriteBounds.from_sprite(spr)
	if r.size == Vector2.ZERO:
		return
	# 将视觉中心居中对齐至原点，使碰撞体与交互判定中心重合
	var gun_center := vis.position + spr.position + r.position + r.size * 0.5
	vis.position -= gun_center
	var cs := CollisionShape2D.new()
	cs.name = "Shape"
	var rect := RectangleShape2D.new()
	rect.size = r.size
	cs.shape = rect
	cs.position = Vector2.ZERO
	add_child(cs)
	hulls = [cs]


func _physics_process(delta: float) -> void:
	simulate_tick(delta)

func simulate_tick(delta: float) -> void:
	delta = TimeField.world_delta(delta)
	_age += delta
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
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	if w > 0.0 and h > 0.0:
		canonical_pos = Vector2(fposmod(global_position.x, w), fposmod(global_position.y, h))
	else:
		canonical_pos = global_position


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
			_settled = false
			_recompute_canonical()
			return true
	return false


var _prompt: PickupPrompt = null


func set_prompt_visible(v: bool) -> void:
	if v and _prompt == null:
		_prompt = PickupPrompt.new()
		_prompt.scale = Vector2.ONE / WORLD_SCALE
		_prompt.position = Vector2(0.0, -PickupPrompt.GAP_ABOVE / WORLD_SCALE)
		add_child(_prompt)
	if _prompt != null and is_instance_valid(_prompt):
		_prompt.visible = v
