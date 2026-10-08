class_name WeaponPickup
extends CharacterBody2D

# 地面可拾取武器实体

const GROUP := "weapon_pickup"

# 掉落物碰撞层：层 4（值 8），掩码包含地形（1）与其他掉落物（8）
const LAYER_GROUND := 8
const MASK_GROUND := 9

# 世界渲染缩放倍率
const WORLD_SCALE := 2.5

@export var type_id: int = 1
var inst: int = 0
var mag: int = 0
var drop_velocity: Vector2 = Vector2.ZERO
var _settled: bool = false
var _age: float = 0.0

# 权威坐标与渲染坐标：
# canonical_pos 维持在 [0, MAP) 规范区间内，由服务端权威计算与拾取判定读取；
# global_position 为就近副本对齐后的渲染坐标，由 set_anchor 锚定至本地视口最近副本。
var canonical_pos: Vector2 = Vector2.ZERO
var _anchor: Vector2 = Vector2.ZERO
var _has_anchor: bool = false


func set_anchor(p: Vector2) -> void:
	_anchor = p
	_has_anchor = true


# 根据规范坐标同步就近副本渲染位置
func sync_render_from_canonical() -> void:
	if not _has_anchor:
		global_position = canonical_pos
		return
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	global_position = GridPathfinder.anchor_to_nearest(canonical_pos, _anchor, w, h) if (w > 0.0 and h > 0.0) else canonical_pos


func _ready() -> void:
	add_to_group(GROUP)
	collision_layer = LAYER_GROUND
	collision_mask = MASK_GROUND
	scale = Vector2(WORLD_SCALE, WORLD_SCALE)
	rotation = 0.0
	if canonical_pos == Vector2.ZERO:
		canonical_pos = global_position
	if get_child_count() == 0:
		_build_visual()
		_build_collision()
	velocity = drop_velocity


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


func _physics_process(delta: float) -> void:
	delta = TimeField.world_delta(delta)
	_age += delta
	if _settled:
		_unstick_up()
		sync_render_from_canonical()
		return
	velocity.y += PlayerParams.weapon_fall_gravity * delta
	if is_on_floor():
		velocity.x *= exp(-PlayerParams.weapon_ground_friction * delta)
	else:
		velocity.x *= exp(-PlayerParams.weapon_air_drag * delta)
	move_and_slide()
	_recompute_canonical()
	_unstick_up()
	sync_render_from_canonical()
	if is_on_floor() and absf(velocity.x) < PlayerParams.weapon_stop_eps:
		velocity = Vector2.ZERO
		_settled = true


# 将物理位置约束折叠至环面规范坐标区间
func _recompute_canonical() -> void:
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	if w > 0.0 and h > 0.0:
		canonical_pos = Vector2(fposmod(global_position.x, w), fposmod(global_position.y, h))
	else:
		canonical_pos = global_position


# 若陷入实心瓦片中则向上弹出
func _unstick_up() -> bool:
	if not CollisionAabb.has_any(self):
		return false
	var dy := Unstick.push_up_dy(CollisionAabb.world_rect(self), GameParameters.TILE_SIZE)
	if dy <= 0.0:
		return false
	global_position.y -= dy
	velocity.y = 0.0
	_settled = false
	_recompute_canonical()
	return true


# 掉落时长（秒），用于丢弃后的防快速误拾取冷却判定
func age() -> float:
	return _age


# ── 拾取提示 ──
var _prompt: PickupPrompt = null


func set_prompt_visible(v: bool) -> void:
	if v and _prompt == null:
		_prompt = PickupPrompt.new()
		_prompt.scale = Vector2.ONE / WORLD_SCALE
		_prompt.position = Vector2(0.0, -PickupPrompt.GAP_ABOVE / WORLD_SCALE)
		add_child(_prompt)
	if _prompt != null and is_instance_valid(_prompt):
		_prompt.visible = v
