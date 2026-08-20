class_name EnemyBase
extends CharacterBody2D

# 物理基础(子类可覆写:扑击时关闭重力)
var use_gravity: bool = true

# 战斗数值(可在检查器调,场景值优先)
# 血量
@export var hp: int = 3
# 接触玩家伤害
@export var contact_damage: int = 1
# 受击击退力度
@export var knockback_strength: float = 150.0
# 死亡时尸体飞行速度上限(爆炸级击退也能保留击退感但不瞬移出屏)
@export var max_death_fly_speed: float = 900.0
# 爆炸专属击退向量:独立于 AI 移动速度,每帧叠加后指数衰减(大冲击+迅速衰减)
var knock_velocity: Vector2 = Vector2.ZERO
# 击退向量指数衰减率(越大停得越快;约 0.15s 衰减到 ~10%)
@export var knock_decay_rate: float = 15.0
# 爆炸设 knock_velocity 时的封顶(防止大击退把活怪轰出屏)
@export var max_knock_velocity: float = 2500.0

# 环面接缝兜底:物理 Area 用欧氏距离,跨接缝不重叠,这里用环面距离补(略大于 ContactArea 半对角线)
const CONTACT_RADIUS: float = 40.0

const GROUND_FRICTION: float = 0.85  # 落地时水平速度衰减系数
const STOP_EPSILON: float = 5.0      # 水平速度低于此值直接归零,避免贴地滑行

var is_dead: bool = false
var _hit_flash_time: float = 0.0
var _player_overlapping: bool = false
# 状态机与动画(子类共用)。state 用 int 承载各子类自己的 enum 常量(见 JumpBird/FlyBird 的 enum State)。
var state: int = 0
var _state_timer: float = 0.0
var _anim: AnimatedSprite2D

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
	# 爆炸击退向量叠加:独立于 AI 移动速度,叠加后 move_and_slide 再还原,指数衰减
	velocity += knock_velocity
	# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离兜底
	# contact_damage<=0 时跳过:零伤也会触发玩家 take_hit 消耗 iframe 并击退。
	if contact_damage > 0 and (_player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS):
		var p := get_tree().get_first_node_in_group("player")
		if p != null and p.has_method("take_hit"):
			p.take_hit(global_position, contact_damage)
	if _hit_flash_time > 0.0:
		_hit_flash_time = maxf(_hit_flash_time - delta, 0.0)
		if _hit_flash_time == 0.0:
			modulate = Color.WHITE
	move_and_slide()
	velocity -= knock_velocity
	knock_velocity *= exp(-knock_decay_rate * delta)
	_wrap()

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		is_dead = true
		queue_free()

# 受击通用逻辑:扣血、击退、白闪。子类覆写 hurt() 时也应调用本方法,避免逻辑分叉。
# knock_strength <= 0 时回落敌人自身 knockback_strength(旧两参调用行为不变)。
# set_velocity=true(爆炸):设独立击退向量 knock_velocity(封顶),不覆盖移动速度;false(枪击):叠加到原速度。
func _apply_hit(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	hp -= damage
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		# 爆炸:设独立击退向量(封顶),不覆盖移动速度;死亡时折入尸体速度
		knock_velocity = knock_dir.normalized() * minf(ks, max_knock_velocity)
	else:
		velocity += knock_dir.normalized() * ks
	if hp <= 0:
		velocity += knock_velocity
		knock_velocity = Vector2.ZERO
		# 死亡:限制尸体飞行速度(爆炸级击退 2500 会把尸体瞬移出屏,压到可看的速度)
		if velocity.length() > max_death_fly_speed:
			velocity = velocity.normalized() * max_death_fly_speed
	modulate = Color(3.0, 3.0, 3.0, 1.0)  # 受击白闪
	_hit_flash_time = EnemyParams.shared.hit_flash


# ── 共享工具(子类通用)──

func _set_state(s: int) -> void:
	state = s
	_state_timer = 0.0


func _anim_duration(name: String) -> float:
	if _anim == null:
		return 0.0
	var spf := _anim.sprite_frames
	return float(spf.get_frame_count(name)) / spf.get_animation_speed(name)


func _player_pos() -> Vector2:
	var p := get_tree().get_first_node_in_group("player") as Node2D
	return p.global_position if p != null else global_position


func _player_velocity() -> Vector2:
	var p := get_tree().get_first_node_in_group("player")
	if p != null and "velocity" in p:
		return p.velocity
	return Vector2.ZERO


func _cell_of(pos: Vector2) -> Vector2i:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return Vector2i.ZERO
	return MazeGenerator.cell_of(pos, GameParameters.TILE_SIZE, grid[0].size(), grid.size())


func _cell_is_solid(cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	return grid[cell.y][cell.x] == MazeGenerator.SOLID


func _toroidal_dist_to(pos: Vector2) -> float:
	return MazeGenerator.toroidal_delta_px(global_position, pos,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()


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
