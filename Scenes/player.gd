extends CharacterBody2D

@export var animator : AnimatedSprite2D

# --- 物理参数（推荐从全局读取） ---
var gravity: float = GameParameters.gravity0
var jump_velocity: float = GameParameters.jump_velocity
var charge_down_velocity: float = GameParameters.charge_down_velocity
var charge_velocity: float = GameParameters.charge_velocity   # 冲刺速度
var charge_duration: float = GameParameters.charge_duration   # 冲刺持续时间（秒）
var move_speed: float = GameParameters.move_speed

# 水平加速/刹车/转身的指数缓动系数（越大越跟手）
var accel_ground: float = GameParameters.accel_ground
var accel_air: float = GameParameters.accel_air
var brake_ground: float = GameParameters.brake_ground
var brake_air: float = GameParameters.brake_air

# 跳跃手感：土狼时间 / 跳跃缓冲 / 可变高度
var coyote_time: float = GameParameters.coyote_time
var jump_buffer_time: float = GameParameters.jump_buffer_time
var jump_cut_factor: float = GameParameters.jump_cut_factor
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var jump_cut_applied: bool = false   # 本次跳跃是否已截断（可变高度）

# 状态标志
var is_squat: bool = false
var is_charge: bool = false
var facing_direction: int = 1   # 1=右，-1=左

# 冲刺计时
var charge_timer: float = 0.0

# ── 战斗 ──
var max_hp: int = GameParameters.player_max_hp
var hp: int = GameParameters.player_max_hp
var iframes: float = 0.0
var downed: bool = false

@export var weapon_slot: Node2D

# 武器注册表:动作名 -> 场景路径(与 project.godot 输入动作 1/2/3 对应)。
const WEAPONS: Dictionary = {
	"1": "res://Scenes/Weapons/pistol_test.tscn",
	"2": "res://Scenes/Weapons/rifle_test.tscn",
	"3": "res://Scenes/Weapons/m82a1.tscn",
}

var _weapon: WeaponBase = null

signal hp_changed(current: int, max: int)

# 姿态状态机（与 JumpBird 的枚举风格统一）。
enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }
const POSE_ANIM: Dictionary = {
	Pose.STAND: "idle", Pose.MOVE: "move", Pose.FLY: "fly",
	Pose.CHARGE: "charge", Pose.SQUAT: "squat",
}
const POSE_NODE: Dictionary = {
	Pose.STAND: "CollisionShape2D_stand", Pose.MOVE: "CollisionShape2D_move",
	Pose.FLY: "CollisionShape2D_fly", Pose.CHARGE: "CollisionShape2D_charge",
	Pose.SQUAT: "CollisionShape2D_squat",
}

# 姿态切换锁：进入某姿态后锁定一小段时间，防止 is_on_floor()/velocity
# 抖动导致 move↔fly 等高频切换（走路抽搐）。
var state: Pose = Pose.STAND
var state_lock_timer: float = 0.0
const STATE_LOCK_TIME := 0.15   # 秒，切换后的最短停留时长

const STOP_SNAP := 1.0              # 水平速度低于此值直接归零，避免贴地滑行
const IFRAME_BLINK_RATE := 20.0     # 无敌帧闪烁频率（每秒明暗切换次数）

# 各姿态碰撞箱节点（场景里已按 POSE_NODE 命名），Pose -> CollisionPolygon2D
var _coll_by_pose: Dictionary = {}


func _ready() -> void:
	add_to_group("player")

	# 缓存各姿态碰撞箱节点
	for pose in Pose.values():
		_coll_by_pose[pose] = get_node(POSE_NODE[pose])

	hp_changed.emit(hp, max_hp)

	_equip_weapon(WEAPONS["1"])


# 指数缓动：朝目标值逼近。rate 越大越跟手；
# 起步快后渐缓、松键带滑行、转身平滑穿过 0，避免线性 move_toward 的生硬。
func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))


func _physics_process(delta: float) -> void:
	if downed:
		velocity = Vector2.ZERO
		move_and_slide()
		return
	iframes = maxf(iframes - delta, 0.0)
	# 无敌帧闪烁
	if iframes > 0.0:
		modulate.a = 0.4 if int(iframes * IFRAME_BLINK_RATE) % 2 == 0 else 1.0
	else:
		modulate.a = 1.0

	var mult := _movement_multiplier()

	var horizontal_input = Input.get_axis("left", "right")

	# ---------- 垂直逻辑（土狼时间 / 跳跃缓冲 / 可变高度） ----------
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		velocity.y += gravity * delta
		coyote_timer = maxf(coyote_timer - delta, 0.0)

	# 跳跃缓冲：落地前提前按跳，落地瞬间生效
	if Input.is_action_just_pressed("up"):
		jump_buffer_timer = jump_buffer_time
	else:
		jump_buffer_timer = maxf(jump_buffer_timer - delta, 0.0)

	# 触发跳跃：有缓冲输入且在地面或土狼窗口内
	if jump_buffer_timer > 0.0 and (is_on_floor() or coyote_timer > 0.0) and not is_squat:
		velocity.y = jump_velocity * mult.y
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		jump_cut_applied = false

	# 可变高度：上升中松开跳跃键，立即衰减上升速度（每次跳跃只截断一次）
	if not jump_cut_applied and Input.is_action_just_released("up") and velocity.y < 0.0:
		velocity.y *= jump_cut_factor
		jump_cut_applied = true

	# ---------- 下蹲 ----------
	if is_on_floor():
		if Input.is_action_just_pressed("down"):
			velocity.x = 0
			is_charge = false
			is_squat = true
		if Input.is_action_just_released("down"):
			is_squat = false
	else:
		if Input.is_action_just_pressed("down"):
			velocity.y = charge_down_velocity

	# ---------- 冲刺输入 ----------
	if not is_charge and not is_squat:
		if Input.is_action_just_pressed("charge"):
			is_charge = true
			charge_timer = charge_duration
			if animator.flip_h:
				facing_direction = -1
			else:
				facing_direction = 1

	# ---------- 水平速度计算 ----------
	if is_charge:
		velocity.x = charge_velocity * facing_direction
		charge_timer -= delta
		if charge_timer <= 0:
			is_charge = false
			velocity.x -= charge_velocity * facing_direction * 0.5
	else:
		var target_velocity_x = horizontal_input * move_speed * mult.x
		if horizontal_input != 0 and not is_squat:
			if is_on_floor():
				velocity.x = _approach(velocity.x, target_velocity_x, accel_ground, delta)
			else:
				velocity.x = _approach(velocity.x, target_velocity_x, accel_air, delta)
		else:
			if is_on_floor():
				velocity.x = _approach(velocity.x, 0.0, brake_ground, delta)
			else:
				velocity.x = _approach(velocity.x, 0.0, brake_air, delta)
			# 指数缓动逼近不到 0，接近 0 时直接吸附，避免贴地滑行
			if absf(velocity.x) < STOP_SNAP:
				velocity.x = 0.0

	# ---------- 面朝方向更新 ----------
	# 移动输入非零时朝向跟随移动;零输入时保留(枪瞄准设置的)当前朝向
	if not is_charge and horizontal_input != 0:
		facing_direction = 1 if horizontal_input > 0 else -1

	# ---------- 动画翻转 ----------
	if facing_direction < 0:
		animator.flip_h = true
	else:
		animator.flip_h = false

	# ---------- 姿态切换（带切换锁，禁止频繁切换） ----------
	# 期望姿态由输入/接触状态决定；进入某姿态后锁定一小段时间，
	# 避免 is_on_floor()/velocity 抖动导致 move↔fly 高频切换（走路抽搐）。
	var desired: Pose = Pose.STAND
	if is_charge:
		desired = Pose.CHARGE
	elif is_squat:
		desired = Pose.SQUAT
	elif not is_on_floor():
		desired = Pose.FLY
	elif velocity.x != 0:
		desired = Pose.MOVE

	if state_lock_timer > 0.0:
		state_lock_timer -= delta
	elif state != desired:
		state = desired
		state_lock_timer = STATE_LOCK_TIME

	# ---------- 动画状态（跟随锁定后的姿态） ----------
	animator.play(POSE_ANIM[state])

	# ---------- 碰撞箱切换 ----------
	# 每个姿态对应一个 CollisionPolygon2D（多边形可在编辑器里分别调整），
	# 运行时只启用当前姿态对应的碰撞箱。
	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != state

	# ---------- 执行移动 ----------
	move_and_slide()

	# 环面回卷：玩家只能在中间副本，离开时取模送回
	global_position = MazeGenerator.wrap_to_range(global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)


func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false) -> void:
	# ignore_iframes: 特殊攻击(如冲撞)穿透无敌帧,但命中后照常刷新 iframes。
	if downed or (iframes > 0.0 and not ignore_iframes):
		return
	# 冲刺被打断:否则下一帧 is_charge 分支会用冲刺速度覆盖本次击退
	is_charge = false
	charge_timer = 0.0
	hp -= damage
	iframes = GameParameters.iframes_time
	var away := (global_position - source_pos).normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(facing_direction), 0.0)
	velocity.x = away.x * GameParameters.player_hit_knockback
	velocity.y = away.y * GameParameters.player_hit_knockback - GameParameters.player_hit_knockback_up
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		_downed()

func get_facing() -> int:
	return facing_direction

func set_facing(v: int) -> void:
	facing_direction = 1 if v >= 0 else -1

func is_downed() -> bool:
	return downed

func _equip_weapon(scene_path: String) -> void:
	if _weapon != null:
		_weapon.queue_free()
	var scene: PackedScene = load(scene_path)
	if scene == null:
		push_error("weapon scene not found: " + scene_path)
		return
	if weapon_slot == null:
		push_error("weapon_slot not assigned")
		return
	_weapon = scene.instantiate() as WeaponBase
	weapon_slot.add_child(_weapon)
	_weapon.equip(self)

func _movement_multiplier() -> Vector2:
	if _weapon == null:
		return Vector2.ONE
	return _weapon.get_movement_multiplier()

func apply_recoil(push: float) -> void:
	if is_squat:
		return
	velocity.x -= facing_direction * push

func _downed() -> void:
	downed = true
	if _weapon != null:
		_weapon.cancel_aim()
	velocity = Vector2.ZERO
	rotation = -PI / 2.0 * float(facing_direction)
	if animator != null:
		animator.stop()
	var tree := get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("set_downed"):
			pp.set_downed(true)

func _unhandled_input(event: InputEvent) -> void:
	if downed:
		if event.is_action_pressed("R"):
			get_tree().reload_current_scene()
		return
	for slot in ["1", "2", "3"]:
		if event.is_action_pressed(slot):
			_equip_weapon(WEAPONS[slot])
			return
