class_name EnemyBase
extends CharacterBody2D

# 物理基础(子类可覆写:扑击时关闭重力)
var use_gravity: bool = true

@export_group("战斗数值(可在检查器调,场景值优先)")
@export_tooltip("血量")
@export var hp: int = 3
@export_tooltip("接触玩家伤害")
@export var contact_damage: int = 1
@export_tooltip("受击击退力度")
@export var knockback_strength: float = 150.0

# 环面接缝兜底:物理 Area 用欧氏距离,跨接缝不重叠,这里用环面距离补(略大于 ContactArea 半对角线)
const CONTACT_RADIUS: float = 40.0

const GROUND_FRICTION: float = 0.85  # 落地时水平速度衰减系数
const STOP_EPSILON: float = 5.0      # 水平速度低于此值直接归零,避免贴地滑行

var is_dead: bool = false
var _hit_flash_time: float = 0.0
var _player_overlapping: bool = false

# ── 行为钩子(子类覆写)──
func _ai(_delta: float) -> void:
	pass

func _anim_update() -> void:
	pass

func _ready() -> void:
	add_to_group("enemies")
	_setup_contact_area()

func _setup_contact_area() -> void:
	var area := Area2D.new()
	area.name = "ContactArea"
	area.collision_layer = 0
	area.collision_mask = 2  # 检测玩家(layer 2)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(44, 40)
	shape.shape = rect
	area.add_child(shape)
	add_child(area)
	area.body_entered.connect(_on_contact_body_entered)
	area.body_exited.connect(_on_contact_body_exited)

func _on_contact_body_entered(body: Node) -> void:
	if body.is_in_group("player"):
		_player_overlapping = true

func _on_contact_body_exited(body: Node) -> void:
	if body.is_in_group("player"):
		_player_overlapping = false

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if use_gravity and not is_on_floor():
		velocity.y += GameParameters.gravity0 * delta
	# 地面摩擦:落地且非冲刺(use_gravity=true)时,水平速度平滑衰减,
	# 避免跳跃/冲刺/击飞的残留速度让敌人在地面滑行。
	# 放在 _ai 之前,这样 _ai 里新设的跳跃/冲刺初速不受当帧摩擦影响。
	if use_gravity and is_on_floor():
		velocity.x *= GROUND_FRICTION
		if absf(velocity.x) < STOP_EPSILON:
			velocity.x = 0.0
	_ai(delta)
	_anim_update()
	# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离兜底
	if _player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS:
		var p := get_tree().get_first_node_in_group("player")
		if p != null and p.has_method("take_hit"):
			p.take_hit(global_position, contact_damage)
	if _hit_flash_time > 0.0:
		_hit_flash_time = maxf(_hit_flash_time - delta, 0.0)
		if _hit_flash_time == 0.0:
			modulate = Color.WHITE
	move_and_slide()
	_wrap()

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir, knock_strength)
	if hp <= 0:
		is_dead = true
		queue_free()

# 受击通用逻辑:扣血、击退、白闪。子类覆写 hurt() 时也应调用本方法,避免逻辑分叉。
# knock_strength <= 0 时回落敌人自身 knockback_strength(旧两参调用行为不变)。
func _apply_hit(damage: int, knock_dir: Vector2, knock_strength: float = 0.0) -> void:
	hp -= damage
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	velocity += knock_dir.normalized() * ks
	modulate = Color(3.0, 3.0, 3.0, 1.0)  # 受击白闪
	_hit_flash_time = EnemyParams.shared.hit_flash

func toroidal_dist_to_player() -> float:
	return toroidal_delta_to_player().length()

func toroidal_dir_to_player() -> Vector2:
	var delta := toroidal_delta_to_player()
	if delta == Vector2.INF or delta.is_zero_approx():
		return Vector2.RIGHT  # 无玩家或与玩家重叠时回退水平方向,避免 0/NaN 方向
	return delta.normalized()

func toroidal_delta_to_player() -> Vector2:
	var p := get_tree().get_first_node_in_group("player")
	if p == null:
		return Vector2.INF
	return MazeGenerator.toroidal_delta_px(global_position, (p as Node2D).global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func _wrap() -> void:
	# 环面渲染回绕:把自己锚定到离玩家最近的副本(跟着主角一起取模)。
	# 墙体按 3x3 铺贴,相机在接缝处能看到另一侧的墙副本;若敌人仍取模到
	# [0,MAP),接缝附近就渲染到远副本而「消失」。每次按玩家当前位置重算,
	# 玩家跨接缝时敌人相对位置连续,不会像之前相机方案那样累计漂移。
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if p == null:
		# 无玩家(场景切换/加载中)时退回绝对取模,防止敌人无限漂移
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
