extends CharacterBody2D

@export var animator : AnimatedSprite2D

# --- 物理参数（推荐从全局读取） ---
var gravity: float = GameParameters.gravity0
var jump_velocity: float = PlayerParams.jump_velocity
var charge_down_velocity: float = PlayerParams.charge_down_velocity
var charge_velocity: float = PlayerParams.charge_velocity   # 冲刺速度
var charge_duration: float = PlayerParams.charge_duration   # 冲刺持续时间（秒）
var move_speed: float = PlayerParams.move_speed

# 水平加速/刹车/转身的指数缓动系数（越大越跟手）
var accel_ground: float = PlayerParams.accel_ground
var accel_air: float = PlayerParams.accel_air
var brake_ground: float = PlayerParams.brake_ground
var brake_air: float = PlayerParams.brake_air

# 跳跃手感：土狼时间 / 跳跃缓冲 / 可变高度
var coyote_time: float = PlayerParams.coyote_time
var jump_buffer_time: float = PlayerParams.jump_buffer_time
var jump_cut_factor: float = PlayerParams.jump_cut_factor
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var jump_cut_applied: bool = false   # 本次跳跃是否已截断（可变高度）

# 状态标志
var is_squat: bool = false
var is_charge: bool = false
var facing_direction: int = 1   # 1=右，-1=左

# 冲刺计时
var charge_timer: float = 0.0
var _last_move_dir: int = 1            # 最近水平移动方向(1右/-1左)
var _last_move_timer: float = 0.0      # 距上次水平移动的剩余窗口(>0 表示最近在走)

@export var weapon_slot: Node2D

@onready var climb: ClimbComponent = $Climb
@onready var weapons: WeaponComponent = $Weapons
@onready var combat: CombatComponent = $Combat
@onready var swim: SwimComponent = $Swim

# 输入来源(行为不变重构):默认委托真实 Input;服务器注入 NetworkInputSource 驱动远端玩家。
var input_source: InputSource = InputSource.new()

func set_input_source(src: InputSource) -> void:
	input_source = src

# 瞄准覆盖:本地返回 ZERO → 武器用鼠标;服务器注入的网络输入返回瞄准方向。
func get_aim_dir_override() -> Vector2:
	return input_source.get_aim_dir_override()

signal hp_changed(current: int, max: int)   # 转发自 CombatComponent,HUD 接口不变
signal waterproof_changed(current: int, max: int)   # 防水值(氧气)变化,HUD 更新

# 公开只读属性:HUD 直接读 hp/max_hp 建血条(hud.gd),数据在 combat,根暴露只读口。
var hp: int:
	get:
		return combat.hp
var max_hp: int:
	get:
		return combat.max_hp

# 防水值(氧气):完全浸水每 0.5s 掉 1,暴露空气每 0.3s 回 1;空后每秒扣血。
var waterproof: int = PlayerParams.player_waterproof_max
var max_waterproof: int = PlayerParams.player_waterproof_max
var _waterproof_timer: float = 0.0
var _was_submerged: bool = false
var _waterproof_drown_timer: float = 0.0

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

# 各姿态碰撞箱节点（场景里已按 POSE_NODE 命名），Pose -> CollisionPolygon2D
var _coll_by_pose: Dictionary = {}


func _ready() -> void:
	add_to_group("player")

	# 转发 combat 的生命/倒地信号到根(外部只认根上的 hp_changed;倒地 → 取消瞄准)
	combat.hp_changed.connect(func(cur: int, mx: int) -> void: hp_changed.emit(cur, mx))
	combat.went_down.connect(func() -> void: weapons.cancel_aim())
	hp_changed.emit(combat.hp, combat.max_hp)

	# 缓存各姿态碰撞箱节点
	for pose in Pose.values():
		_coll_by_pose[pose] = get_node(POSE_NODE[pose])

	weapons.equip("1")
	call_deferred("add_child", WaterFx.new())


# 指数缓动：朝目标值逼近。rate 越大越跟手；
# 起步快后渐缓、松键带滑行、转身平滑穿过 0，避免线性 move_toward 的生硬。
func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))


func _physics_process(delta: float) -> void:
	if combat.is_downed():
		# 死亡(倒地):不取消物理——重力/制动/击退照常,只是不吃输入、不结算战斗
		if is_on_floor():
			coyote_timer = coyote_time
		else:
			velocity.y += gravity * delta
		if is_on_floor():
			velocity.x = _approach(velocity.x, 0.0, brake_ground, delta)
		else:
			velocity.x = _approach(velocity.x, 0.0, brake_air, delta)
		if absf(velocity.x) < STOP_SNAP:
			velocity.x = 0.0
		combat.apply_knock(delta)
		move_and_slide()
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	combat.update_iframe_blink(delta)

	var mult := weapons.movement_multiplier()

	var horizontal_input = input_source.get_axis("left", "right")

	# ---------- 水中(浮水/游泳):速度由 swim 设置,跳过攀爬/重力/跳跃/下蹲/冲刺 ----------
	var in_water := swim.update(self, delta, mult)
	_update_waterproof(delta)
	var climbing := false
	var latched := false
	if not in_water:
		# ---------- 攀爬(梯子/锁链:攀附不受重力,按住上/下爬,锁链更快,下降更快) ----------
		climbing = climb.update(mult, delta, is_squat)
		latched = climb.is_latched()
	else:
		# 水中:清掉冲刺/下蹲残留,避免姿态锁死
		is_charge = false
		is_squat = false

	# ---------- 垂直逻辑（土狼时间 / 跳跃缓冲 / 可变高度） ----------
	if not latched and not in_water:
		if is_on_floor():
			coyote_timer = coyote_time
		else:
			velocity.y += gravity * delta
			coyote_timer = maxf(coyote_timer - delta, 0.0)

		# 跳跃缓冲：落地前提前按跳，落地瞬间生效
		if input_source.is_action_just_pressed("up"):
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
		if not jump_cut_applied and input_source.is_action_just_released("up") and velocity.y < 0.0:
			velocity.y *= jump_cut_factor
			jump_cut_applied = true

	# ---------- 下蹲 ----------
	if not latched and not in_water:
		if is_on_floor():
			if input_source.is_action_just_pressed("down"):
				velocity.x = 0
				is_charge = false
				is_squat = true
			if input_source.is_action_just_released("down"):
				is_squat = false
		else:
			if input_source.is_action_just_pressed("down"):
				velocity.y = charge_down_velocity

	# ---------- 冲刺输入 ----------
	if not latched and not is_charge and not is_squat and not in_water:
		if input_source.is_action_just_pressed("charge"):
			is_charge = true
			charge_timer = charge_duration
			# 冲刺方向沿用最近移动方向;没在走路(如刚用枪瞄)则保留当前朝向。
			if _last_move_timer > 0.0:
				facing_direction = _last_move_dir

	# ---------- 水平速度计算(垂直攀爬中已在 _update_climb 里停水平;攀附空闲可水平走离) ----------
	if not climbing and not in_water:
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
		_last_move_dir = facing_direction
		_last_move_timer = PlayerParams.charge_dir_window
	else:
		_last_move_timer = maxf(_last_move_timer - delta, 0.0)

	# ---------- 动画翻转 ----------
	if facing_direction < 0:
		animator.flip_h = true
	else:
		animator.flip_h = false

	# ---------- 姿态切换（带切换锁，禁止频繁切换） ----------
	# 期望姿态由输入/接触状态决定；进入某姿态后锁定一小段时间，
	# 避免 is_on_floor()/velocity 抖动导致 move↔fly 高频切换（走路抽搐）。
	var desired: Pose = Pose.STAND
	if in_water:
		desired = Pose.MOVE if absf(velocity.x) > 1.0 else Pose.STAND
	elif is_charge:
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

	# ---------- 爆炸击退位移:单独 move_and_collide(带碰撞),不污染 velocity ----------
	# (地面把向下击退吃掉后再减回去会把玩家弹起,改用独立位移结算)
	combat.apply_knock(delta)

	# ---------- 执行移动 ----------
	move_and_slide()

	# ---------- 弹性瓦片（如树叶）:弱反弹 ----------
	# 空网格跳过(冒烟测试会清空 current_grid;真实游戏 Level0 总会赋值)
	if not MazeGenerator.current_grid.is_empty():
		for i in range(get_slide_collision_count()):
			var sc := get_slide_collision(i)
			if sc == null:
				continue
			var ec := MazeGenerator.cell_of(sc.get_position(), GameParameters.TILE_SIZE,
					MazeGenerator.current_grid[0].size(), MazeGenerator.current_grid.size())
			var ev: int = MazeGenerator.current_grid[ec.y][ec.x]
			if ev != 0 and TileDefs.elastic(MazeGenerator.texture_of(ev)):
				velocity += sc.get_normal() * PlayerParams.elastic_bounce
				break

	# 环面回卷：玩家只能在中间副本，离开时取模送回
	global_position = MazeGenerator.wrap_to_range(global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)


func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	combat.take_hit(source_pos, damage, ignore_iframes, knockback)

func get_facing() -> int:
	return facing_direction

func set_facing(v: int) -> void:
	# 冲刺期间朝向即冲刺方向,锁定不被枪瞄改写(_auto_aim 每帧 set_facing)。
	if is_charge:
		return
	facing_direction = 1 if v >= 0 else -1

func is_downed() -> bool:
	return combat.is_downed()

func apply_recoil(push: float) -> void:
	weapons.apply_recoil(push, is_squat, climb.is_latched())

# 攀爬跳离梯顶时清跳跃缓冲/土狼/截断标记:防止残留输入造成二次起跳(由 climb 组件调用)。
func cancel_jump_state() -> void:
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	jump_cut_applied = false

# combat 命中落地时调用:冲刺被打断,否则下一帧 is_charge 分支会用冲刺速度覆盖击退。
func cancel_charge() -> void:
	is_charge = false
	charge_timer = 0.0

# 防水值(氧气):没顶(中心低于水面线)每 water_drain_interval 掉 1,暴露空气回 1;空后每秒扣血。
func _update_waterproof(delta: float) -> void:
	var submerged := false
	if swim.in_water:
		var surface_y := Water.surface_y_at(global_position)
		submerged = Water.submerged(global_position, surface_y)
	if submerged != _was_submerged:
		_was_submerged = submerged
		_waterproof_timer = 0.0  # 状态切换重置:入水满 0.5s 才扣第一次
	if submerged:
		_waterproof_timer += delta
		if _waterproof_timer >= GameParameters.water_drain_interval:
			_waterproof_timer = 0.0
			_set_waterproof(waterproof - 1)
	else:
		_waterproof_timer += delta
		if _waterproof_timer >= GameParameters.water_recover_interval:
			_waterproof_timer = 0.0
			_set_waterproof(waterproof + 1)
	if waterproof <= 0:
		_waterproof_drown_timer += delta
		if _waterproof_drown_timer >= GameParameters.water_drown_damage_interval:
			_waterproof_drown_timer = 0.0
			take_hit(global_position, PlayerParams.player_waterproof_damage, true)

func _set_waterproof(v: int) -> void:
	waterproof = clampi(v, 0, max_waterproof)
	waterproof_changed.emit(waterproof, max_waterproof)


func _unhandled_input(event: InputEvent) -> void:
	if combat.is_downed():
		if event.is_action_pressed("R"):
			get_tree().reload_current_scene()
		return
	for slot in ["1", "2", "3", "4", "5"]:
		if event.is_action_pressed(slot):
			weapons.equip(slot)
			return
