class_name EnemyBase
extends CharacterBody2D

# 进入死亡状态时发射一次(用于击杀计数等 UI;撞人自毁同算,见 FlyBird._die_self)
signal died

# 物理基础(子类可覆写:扑击时关闭重力)
var use_gravity: bool = true

# 战斗数值(可在检查器调,场景值优先)
# 血量
@export var hp: int = 3
# 接触玩家伤害
@export var contact_damage: int = 1
# 受击击退力度
@export var knockback_strength: float = 150.0
# 爆炸专属击退向量:独立于 AI 移动速度,每帧叠加后指数衰减(大冲击+迅速衰减)
var knock_velocity: Vector2 = Vector2.ZERO
# 击退向量指数衰减率(越大停得越快;约 0.23s 衰减到 ~10%)
@export var knock_decay_rate: float = 10.0

# 环面接缝兜底:物理 Area 用欧氏距离,跨接缝不重叠,这里用环面距离补(略大于 ContactArea 半对角线)
const CONTACT_RADIUS: float = 40.0

const GROUND_FRICTION: float = 0.85  # 落地时水平速度衰减系数
const STOP_EPSILON: float = 5.0      # 水平速度低于此值直接归零,避免贴地滑行

var is_dead: bool = false
var _hit_flash_time: float = 0.0
var _death_timer: float = -1.0   # 死亡白闪剩余;<0 未死亡(受击/死亡白闪统一在基类)
var _player_overlapping: bool = false
var _turn_cooldown: float = 0.0  # 转向冷却:两次翻转朝向至少间隔 turn_min_interval
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
	_turn_cooldown = maxf(_turn_cooldown - delta, 0.0)
	if use_gravity and not is_on_floor():
		velocity.y += GameParameters.gravity0 * delta
	# 地面摩擦:落地且非冲刺(use_gravity=true)时,水平速度平滑衰减,
	# 避免跳跃/冲刺/击飞的残留速度让敌人在地面滑行。
	# 放在 _ai 之前,这样 _ai 里新设的跳跃/冲刺初速不受当帧摩擦影响。
	if use_gravity and is_on_floor():
		velocity.x *= GROUND_FRICTION
		if absf(velocity.x) < STOP_EPSILON:
			velocity.x = 0.0
	# 死亡:AI 不行动,但物理(重力/摩擦/击退/碰撞)与生前完全一致。
	if not is_dead:
		_ai(delta)
		_anim_update()
		# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离兜底
		# contact_damage<=0 时跳过:零伤也会触发玩家 take_hit 消耗 iframe 并击退。
		if contact_damage > 0 and (_player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS):
			var p := get_tree().get_first_node_in_group("player")
			if p != null and p.has_method("take_hit"):
				p.take_hit(global_position, contact_damage)
	# 受击/死亡白闪统一:计时 + 渲染(子类可覆写 _flash_update 换渲染方式,如黑鸟 silhouette)
	if _hit_flash_time > 0.0:
		_hit_flash_time = maxf(_hit_flash_time - delta, 0.0)
	if _death_timer > 0.0:
		_death_timer -= delta
		if _death_timer <= 0.0:
			queue_free()
			return
	_flash_update()
	if is_dead:
		# 尸体:基础速度也按击退速率指数衰减,滑行逐渐停住(不匀速滑到底);
		# 下落也随之变慢到"终端速度",更接近失去意识的尸体。
		velocity *= exp(-knock_decay_rate * delta)
	# 爆炸击退位移:单独 move_and_collide(带碰撞),不污染 velocity
	# (地面把向下击退吃掉后再减回去会把身体弹起);主移动 move_and_slide 最后跑,地面状态以它为准。
	move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-knock_decay_rate * delta)
	move_and_slide()
	_wrap()

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		# 尸体:不再扣血/触发死亡,但冲击波仍能推动(不吞冲击波)
		_apply_knock_only(knock_dir, knock_strength, set_velocity)
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		_begin_death()

# 受击通用逻辑:扣血、击退、白闪。子类覆写 hurt() 时也应调用本方法,避免逻辑分叉。
# knock_strength <= 0 时回落敌人自身 knockback_strength(旧两参调用行为不变)。
# set_velocity=true(爆炸):设独立击退向量 knock_velocity(封顶),不覆盖移动速度;false(枪击):叠加到原速度。
func _apply_hit(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	hp -= damage
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		# 爆炸:设独立击退向量(不封顶),不覆盖移动速度
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks
	# 死亡:击退不折入,尸体与生前一致——knock_velocity 继续独立衰减,由 _physics_process 统一结算。
	modulate = Color(3.0, 3.0, 3.0, 1.0)  # 受击白闪
	_hit_flash_time = EnemyParams.shared.hit_flash

# 尸体专用:只施加击退(爆炸=设独立向量、枪击=叠加速度),不扣血、不触发死亡/白闪。
func _apply_knock_only(knock_dir: Vector2, knock_strength: float, set_velocity: bool) -> void:
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks


# 死亡白闪统一入口:置死亡状态、发信号、起白闪计时(渲染由 _flash_update 统一处理,
# 到期在基类 _physics_process 销毁)。子类可在调用后追加专属处理(JumpBird 播 dead、
# FlyBird 清冲撞速度)。
func _begin_death() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	_death_timer = EnemyParams.shared.death_flash_time


# 白闪渲染:受击/死亡任一激活即纯白,否则恢复。默认走 modulate;黑鸟因 silhouette
# shader 覆写 COLOR 而 modulate 失效,覆写本方法改走 shader 参数。
func _flash_update() -> void:
	modulate = Color(3.0, 3.0, 3.0, 1.0) if _hit_flash_time > 0.0 or _death_timer > 0.0 else Color.WHITE


# 统一转向:两次翻转朝向至少间隔 turn_min_interval,防止敌人来回抖(看起来像 bug)。
# 朝向未变时不消耗冷却(持续面向玩家不会因此锁死)。
func _set_facing(facing_left: bool) -> void:
	if _turn_cooldown > 0.0 or _anim.flip_h == facing_left:
		return
	_turn_cooldown = EnemyParams.shared.turn_min_interval
	_anim.flip_h = facing_left


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
