extends CharacterBody2D

@export var animator : AnimatedSprite2D

# 物理基础参数配置
var gravity: float = GameParameters.gravity0
var jump_velocity: float = PlayerParams.jump_velocity
var charge_down_velocity: float = PlayerParams.charge_down_velocity
var charge_velocity: float = PlayerParams.charge_velocity   # 冲刺速度
var charge_duration: float = PlayerParams.charge_duration   # 冲刺持续时间（秒）
var charge_air_gravity_mult: float = PlayerParams.charge_air_gravity_mult  # 空中冲刺重力倍率
var move_speed: float = PlayerParams.move_speed
var crouch_walk_speed: float = PlayerParams.crouch_walk_speed  # 下蹲移动速度

# 水平加速、制动与转身平滑系数
var accel_ground: float = PlayerParams.accel_ground
var accel_air: float = PlayerParams.accel_air
var brake_ground: float = PlayerParams.brake_ground
var brake_air: float = PlayerParams.brake_air

# 跳跃控制参数：土狼时间、跳跃缓冲与可变跳跃高度
var coyote_time: float = PlayerParams.coyote_time
var jump_buffer_time: float = PlayerParams.jump_buffer_time
var jump_cut_factor: float = PlayerParams.jump_cut_factor
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var jump_cut_applied: bool = false   # 当前跳跃是否已截断

# 状态标志
var is_squat: bool = false
var is_charge: bool = false
var facing_direction: int = 1   # 朝向（1为右，-1为左）

# 冲刺计时与移动记忆
var charge_timer: float = 0.0
var _last_move_dir: int = 1            # 最近水平移动方向
var _last_move_timer: float = 0.0      # 维持最近移动方向的时间窗口

@export var weapon_slot: Node2D

@onready var climb: ClimbComponent = $Climb
@onready var weapons: WeaponComponent = $Weapons
@onready var combat: CombatComponent = $Combat
@onready var swim: SwimComponent = $Swim

# 挤压与拉伸补间形变组件，运行时动态创建，仅负责表现层渲染，不参与状态同步。
var squash: SquashStretch = null
# 执行 move_and_slide() 前的垂直速度，配合帧首地面检测用于计算着地形变。
var _pre_move_vy: float = 0.0

# 输入源：默认委托本地输入；联机服务端可注入网络输入源驱动角色。
var input_source: PlayerInput = LocalInputSource.new()

func set_input_source(src: PlayerInput) -> void:
	input_source = src

# 获取瞄准方向覆盖：本地输入使用鼠标瞄准，网络输入返回上报的瞄准方向。
func get_aim_dir_override() -> Vector2:
	return input_source.get_aim_dir_override()

# 查询当前输入源是否来自网络注入，网络驱动的角色不读取本机鼠标。
func input_is_network() -> bool:
	return input_source != null and input_source.is_network_driven()

# 攻击按键状态查询接口。
func is_attack_pressed() -> bool:
	if _controls_locked:
		return false
	return input_source.is_attack_pressed()

func is_attack_just_pressed() -> bool:
	if _controls_locked:
		return false
	return input_source.is_attack_just_pressed()

func is_attack_just_released() -> bool:
	if _controls_locked:
		return false
	return input_source.is_attack_just_released()

# 当前瞄准方向（世界坐标系）：委托武器获取实际瞄准向量，用于输入上报。
func get_current_aim_dir() -> Vector2:
	var w := weapons.current_weapon()
	if w != null:
		return w.get_current_aim_dir()
	return Vector2(float(facing_direction), 0.0)

signal hp_changed(current: int, max: int)   # 生命值变更信号，转发自 CombatComponent
signal waterproof_changed(current: int, max: int)   # 氧气值变更信号，供 HUD 刷新

# 生命值属性访问接口，底层数据由 CombatComponent 维护。
var hp: int:
	get:
		return combat.hp
var max_hp: int:
	get:
		return combat.max_hp

# 防水值（氧气）：完全没入水中时扣除，离开水体后回复，耗尽后造成溺水伤害。
var waterproof: int = PlayerParams.player_waterproof_max
var max_waterproof: int = PlayerParams.player_waterproof_max
var _waterproof_timer: float = 0.0
var _was_submerged: bool = false
var _waterproof_drown_timer: float = 0.0

# 姿态状态机
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

# 姿态切换锁：进入新姿态后保持最短停留时间，防止物理状态抖动导致高频状态切换。
var state: Pose = Pose.STAND
var state_lock_timer: float = 0.0
const STATE_LOCK_TIME := 0.15   # 切换后的最短停留时长（秒）

# 各姿态碰撞体节点映射表，Pose -> CollisionPolygon2D
var _coll_by_pose: Dictionary = {}

# 输入锁定控制：在倒计时或回合冻结阶段锁定本地移动与武器开火，保证预测状态与服务端快照一致。
var _controls_locked := false
func set_controls_locked(locked: bool) -> void:
	_controls_locked = locked
	if input_source != null:
		input_source.frozen = locked

func _ready() -> void:
	add_to_group("player")

	# 转发战斗组件的生命值与倒地信号，倒地时取消当前武器瞄准
	combat.hp_changed.connect(func(cur: int, mx: int) -> void: hp_changed.emit(cur, mx))
	combat.went_down.connect(func() -> void: weapons.cancel_aim())
	hp_changed.emit(combat.hp, combat.max_hp)

	# 缓存各姿态碰撞体节点
	for pose in Pose.values():
		_coll_by_pose[pose] = get_node(POSE_NODE[pose])

	# 初始化背包：单人模式开局为空手，多人模式由服务端分配初始武器
	weapons.set_initial_inventory([])
	# 动态创建换弹圆环指示器，根据角色根节点缩放进行反向缩放以维持世界尺寸
	_reload_ring = ReloadRing.new()
	_reload_ring.scale = Vector2.ONE / scale.x
	_reload_ring.visible = false
	add_child(_reload_ring)
	call_deferred("add_child", WaterFx.new())
	# 挂载挤压与拉伸补间形变组件
	squash = SquashStretch.new()
	# 先将形变组件加入场景树，再完成与动画精灵的绑定
	add_child(squash)
	squash.setup(animator, SquashStretch.Profile.PLAYER)


var _speed_mult := 1.0  # 时间场速度倍率

# 多人模式时间加速倍率：由服务端权威与客户端预测根据颗粒余额和输入状态写入
var pvp_haste_mult := 1.0
var _ghost_t := 0.0     # 残影生成计时器
var _ghost_flip := false  # 残影颜色交替标记


func _physics_process(delta: float) -> void:
	# 时间场逻辑：时空回溯时整帧冻结物理模拟；时间加速仅作用于水平速度目标值与冷却节奏，跳跃物理保持一致
	var tm := TimeField.player_speed_mult() if TimeField.current != null else pvp_haste_mult
	_speed_mult = tm
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	# 补间形变更新：必须在倒地状态判断前调用，保证倒地瞬间精灵缩放能够正确复位
	squash.tick(delta, _pre_move_vy, is_on_floor(), combat.is_downed())
	if combat.is_downed():
		# 倒地状态下重置垂直速度缓存，避免击杀瞬间的下坠速度影响后续复活形变计算
		_pre_move_vy = 0.0
		_tick_downed(delta)
		return
	weapons.tick(delta * tm)   # 武器逻辑步进，加速状态下按对应时间倍率缩放冷却与装填速度

	# 时间加速视觉特效：红蓝交替生成半透明残影
	if _speed_mult > 1.0:
		_ghost_t -= delta
		if _ghost_t <= 0.0:
			_ghost_t = 0.03
			var anim := animator
			if anim != null:
				var tint := Color(1.0, 0.25, 0.25, 0.55) if _ghost_flip else Color(0.3, 0.4, 1.0, 0.55)
				_ghost_flip = not _ghost_flip
				AfterImage.spawn(get_parent(), anim, tint)

	combat.update_iframe_blink(delta)

	# 武器切换输入轮询：
	# 本地输入源根据数字键按槽位下标切换；
	# 网络输入源根据上报的目标武器实例 ID 切换，避免网络延迟期间槽位下标不一致。
	var idx := input_source.get_switch_index_pressed()
	if idx > 0:
		weapons.equip_index(idx - 1)
	var winst := input_source.consume_switch_inst()
	if winst > 0:
		weapons.equip_inst(winst)

	# 装填输入轮询：同帧切枪与装填时优先切换武器，再触发新武器装填。倒地状态不执行换弹。
	if input_source.is_action_just_pressed("R"):
		var reload_w := weapons.current_weapon()
		if reload_w != null:
			reload_w.start_reload()

	# 地面武器拾取与丢弃输入轮询
	_poll_pickup_drop(delta)
	_update_reload_ring()

	var mult := weapons.movement_multiplier()

	var horizontal_input = input_source.get_axis("left", "right")

	# ── 水中与攀爬状态检测 ──
	var in_water := swim.update(self, delta, mult, input_source)
	_update_waterproof(delta)
	var latched := false
	if not in_water:
		# 攀爬逻辑处理（攀附在梯子或锁链上时不承受重力）
		climb.update(mult, delta, is_squat, input_source)
		latched = climb.is_latched()
	else:
		# 进入水中：重置冲刺与下蹲状态，解除陆地姿态锁定
		is_charge = false
		is_squat = false

	_tick_vertical(delta, latched, in_water, mult)
	_tick_crouch_and_dash(delta, latched, in_water)
	_tick_horizontal(delta, in_water, horizontal_input, mult)
	_tick_facing(delta, horizontal_input)
	_tick_pose_and_collision(delta, in_water)

	# ── 爆炸击退位移结算 ──
	# 采用独立的碰撞位移处理，避免击退速度污染角色常规移动速度
	combat.apply_knock(delta)

	# ── 执行物理移动 ──
	# 缓存 move_and_slide() 执行前的下落速度供着地形变计算，游泳与攀爬时不触发着地拉伸
	_pre_move_vy = 0.0 if (in_water or latched) else velocity.y
	move_and_slide()

	_tick_slide_reactions()
	_wrap_position()


# ── 垂直移动逻辑（土狼时间、跳跃缓冲与可变跳跃高度） ──
func _tick_vertical(delta: float, latched: bool, in_water: bool, mult: Vector2) -> void:
	if latched or in_water:
		return
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		# 空中冲刺时降低重力加速度，保持较为平直的轨迹以利于跨越障碍
		var grav_mult := charge_air_gravity_mult if is_charge else 1.0
		velocity.y += gravity * grav_mult * delta
		coyote_timer = maxf(coyote_timer - delta, 0.0)

	# 跳跃缓冲：落地前提前按跳，落地瞬间生效
	if input_source.is_action_just_pressed("up"):
		jump_buffer_timer = jump_buffer_time
	else:
		jump_buffer_timer = maxf(jump_buffer_timer - delta, 0.0)

	# 触发跳跃：有缓冲输入且在地面或土狼窗口内
	if jump_buffer_timer > 0.0 and (is_on_floor() or coyote_timer > 0.0) and not is_squat:
		# 冲刺过程中跳跃可打断冲刺并保留当前水平动量
		if is_charge:
			is_charge = false
			charge_timer = 0.0
		velocity.y = jump_velocity * mult.y
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		jump_cut_applied = false
		squash.impulse(SquashStretch.Impulse.JUMP)

	# 可变高度：上升中松开跳跃键，立即衰减上升速度（每次跳跃只截断一次）
	if not jump_cut_applied and input_source.is_action_just_released("up") and velocity.y < 0.0:
		velocity.y *= jump_cut_factor
		jump_cut_applied = true


# ── 下蹲、空中下冲与冲刺输入 ──
func _tick_crouch_and_dash(delta: float, latched: bool, in_water: bool) -> void:
	if latched or in_water:
		return
	# 空中按下方向键执行快速下冲（处于攀爬通道格除外）
	if not is_on_floor() and input_source.is_action_just_pressed("down") \
			and not climb.is_over_climb_tile():
		velocity.y = charge_down_velocity
	# 下蹲状态判定：地面状态且按住下蹲键时生效，避免空中松开按键导致的下蹲锁死
	var want_squat := is_on_floor() and input_source.is_action_pressed("down")
	if want_squat and not is_squat:
		is_charge = false   # 冲刺中按 S → 取消冲刺进蹲
	is_squat = want_squat

	# 冲刺输入
	if not is_charge and not is_squat and input_source.is_action_just_pressed("charge"):
		is_charge = true
		charge_timer = charge_duration
		squash.impulse(SquashStretch.Impulse.DASH)
		# 冲刺方向优先沿用最近移动方向，无移动输入时保持当前朝向
		if _last_move_timer > 0.0:
			facing_direction = _last_move_dir


# ── 水平速度计算 ── 
func _tick_horizontal(delta: float, in_water: bool, horizontal_input: float, mult: Vector2) -> void:
	if in_water:
		return
	if is_charge:
		velocity.x = charge_velocity * facing_direction
		charge_timer -= delta
		if charge_timer <= 0:
			is_charge = false
			# 冲刺结束时平滑过渡至常规减速流程
	else:
		# 下蹲时移动目标速度切换为蹲走速度，站立时使用常规移动速度
		var speed_target := (crouch_walk_speed if is_squat else move_speed) * _speed_mult
		var target_velocity_x = horizontal_input * speed_target * mult.x
		if horizontal_input != 0:
			if is_on_floor():
				velocity.x = MathUtil.approach(velocity.x, target_velocity_x, accel_ground, delta)
			else:
				velocity.x = MathUtil.approach(velocity.x, target_velocity_x, accel_air, delta)
		else:
			_brake_horizontal(delta)


# ── 角色朝向 ──
# 有水平移动输入时跟随移动方向，无输入时保留当前瞄准朝向
func _tick_facing(delta: float, horizontal_input: float) -> void:
	if not is_charge and horizontal_input != 0:
		facing_direction = 1 if horizontal_input > 0 else -1
		_last_move_dir = facing_direction
		_last_move_timer = PlayerParams.charge_dir_window
	else:
		_last_move_timer = maxf(_last_move_timer - delta, 0.0)


# ── 姿态切换与碰撞体管理 ──
# 根据输入与环境接触状态推导目标姿态，并通过停留锁避免高频抖动；
# 每个姿态对应专用的多边形碰撞体，运行时仅激活当前姿态的碰撞形状。
func _tick_pose_and_collision(delta: float, in_water: bool) -> void:
	# 动画翻转
	animator.flip_h = facing_direction < 0

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

	# 动画状态(跟随锁定后的姿态)
	animator.play(POSE_ANIM[state])

	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != state


# ── move_and_slide 之后的反应:冲刺撞墙 / 弹性瓦片 ── 
func _tick_slide_reactions() -> void:
	# 冲刺撞击垂直障碍物时立即结束冲刺状态
	if is_charge:
		for i in range(get_slide_collision_count()):
			var col := get_slide_collision(i)
			if col != null and absf(col.get_normal().x) > 0.5:
				is_charge = false
				charge_timer = 0.0
				velocity.x = 0.0
				break

	# 弹性瓦片检测：接触特定地块（如树叶）时提供反弹冲量
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


# 倒地状态逻辑：保持重力模拟与水平摩擦制动，但不响应玩家操作，不执行武器与姿态逻辑
func _tick_downed(delta: float) -> void:
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		velocity.y += gravity * delta
	_brake_horizontal(delta)
	combat.apply_knock(delta)
	move_and_slide()
	_wrap_position()


# 无水平输入时的摩擦减速与静止吸附，速度低于阈值时直接归零以防止微小滑移
func _brake_horizontal(delta: float) -> void:
	if is_on_floor():
		velocity.x = MathUtil.approach(velocity.x, 0.0, brake_ground, delta)
	else:
		velocity.x = MathUtil.approach(velocity.x, 0.0, brake_air, delta)
	if absf(velocity.x) < PlayerParams.stop_snap:
		velocity.x = 0.0


# 环面世界坐标规范化：超出地图边界时回卷至规范区间
func _wrap_position() -> void:
	global_position = MazeGenerator.wrap_to_range(global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)


func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# 时空回溯状态下免疫一切外部伤害，防止回放过程中因瞬移误触发受击判定
	if (TimeField.current != null and TimeField.current.is_rewinding()) or has_meta("time_rewinding"):
		return
	# 仅在实际扣除生命值时触发受击挤压形变，无敌帧或倒地状态不重复触发
	var before := combat.hp
	combat.take_hit(source_pos, damage, ignore_iframes, knockback)
	if combat.hp < before:
		squash.impulse(SquashStretch.Impulse.HURT)

func get_facing() -> int:
	return facing_direction

func set_facing(v: int) -> void:
	# 冲刺期间朝向锁定为冲刺方向，不被瞄准逻辑重写
	if is_charge:
		return
	facing_direction = 1 if v >= 0 else -1

func is_downed() -> bool:
	return combat.is_downed()

# 查询当前是否处于冲刺状态，武器据此决定枪口朝向是否受限于角色身体朝向
func is_charging() -> bool:
	return is_charge

# 检测当前物理帧是否与其他玩家碰撞体发生接触，供预测回滚模块在近身接触时自适应调整容差
func touching_player() -> bool:
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		if col == null:
			continue
		var co := col.get_collider() as CollisionObject2D
		if co != null and (co.collision_layer & ~1) != 0:
			return true
	return false

func apply_recoil(push: float) -> void:
	weapons.apply_recoil(push, is_squat, climb.is_latched())

# 应用服务端快照中的权威状态（生命值、氧气与倒地状态）
func apply_authoritative_state(hp_val: int, waterproof_val: int, downed_val: bool) -> void:
	combat.hp = clampi(hp_val, 0, combat.max_hp)
	combat.hp_changed.emit(combat.hp, combat.max_hp)
	waterproof = clampi(waterproof_val, 0, max_waterproof)
	waterproof_changed.emit(waterproof, max_waterproof)
	if downed_val and not combat.is_downed():
		combat.force_down()
	elif not downed_val and combat.is_downed():
		combat.revive()

# ── 客户端预测：完整状态捕获与恢复（capture_state / restore_state）──
# 记录决定下一物理帧模拟所需的全部关键变量，用于服务端权威快照生成与客户端预测回滚重放。
func capture_state() -> Dictionary:
	var st: Dictionary = {
		"pos": global_position,
		"vel": velocity,
		"facing": facing_direction,
		"state": state,
		"slock": state_lock_timer,
		"coyote": coyote_timer,
		"jbuf": jump_buffer_timer,
		"jcut": jump_cut_applied,
		"squat": is_squat,
		"charge": is_charge,
		"ct": charge_timer,
		"lmv_d": _last_move_dir,
		"lmv_t": _last_move_timer,
		"wp": waterproof,
		"wp_t": _waterproof_timer,
		"wp_s": _was_submerged,
		"wp_d": _waterproof_drown_timer,
		"clatch": climb._latched,
		"swim": swim.in_water,
		"hp": combat.hp,
		"ifr": combat.iframes,
		"down": combat.downed,
		"knock": combat.knock_velocity,
		"wslot": weapons._current_type,
		# 记录手持武器唯一实例 ID
		"winst": weapons.current_inst(),
	}
	# 记录背包完整数据快照
	st["inv"] = weapons.snapshot_inventory()
	var w: WeaponBase = weapons._weapon
	if w != null:
		st["fire_cd"] = w.fire_cd_timer
		st["aiming"] = w._aiming
		st["fire_buf"] = w._fire_buffered
		st["aim_f"] = w._aim_facing
		st["aim_cf"] = w._current_aim_facing
		# 记录弹药量与装填进度
		st["mag"] = w.mag_ammo
		st["rld"] = w._reloading
		st["rld_t"] = w._reload_t
	return st

func restore_state(st: Dictionary) -> void:
	# 恢复移动与姿态变量
	global_position = st.get("pos", global_position)
	velocity = st.get("vel", velocity)
	facing_direction = int(st.get("facing", facing_direction))
	state = clampi(int(st.get("state", state)), Pose.STAND, Pose.SQUAT)
	state_lock_timer = float(st.get("slock", state_lock_timer))
	coyote_timer = float(st.get("coyote", coyote_timer))
	jump_buffer_timer = float(st.get("jbuf", jump_buffer_timer))
	jump_cut_applied = bool(st.get("jcut", jump_cut_applied))
	is_squat = bool(st.get("squat", is_squat))
	is_charge = bool(st.get("charge", is_charge))
	charge_timer = float(st.get("ct", charge_timer))
	_last_move_dir = int(st.get("lmv_d", _last_move_dir))
	_last_move_timer = float(st.get("lmv_t", _last_move_timer))
	climb._latched = bool(st.get("clatch", climb._latched))
	swim.in_water = bool(st.get("swim", swim.in_water))
	# 恢复生命值、氧气与倒地状态
	var hp_v := int(st.get("hp", hp))
	if hp_v != combat.hp:
		combat.hp = clampi(hp_v, 0, combat.max_hp)
		combat.hp_changed.emit(combat.hp, combat.max_hp)
	var wp_v := int(st.get("wp", waterproof))
	if wp_v != waterproof:
		waterproof = clampi(wp_v, 0, max_waterproof)
		waterproof_changed.emit(waterproof, max_waterproof)
	var down_v := bool(st.get("down", combat.downed))
	if down_v and not combat.is_downed():
		combat.force_down()
	elif not down_v and combat.is_downed():
		combat.revive()
	combat.iframes = float(st.get("ifr", combat.iframes))
	combat.knock_velocity = st.get("knock", combat.knock_velocity)
	_waterproof_timer = float(st.get("wp_t", _waterproof_timer))
	_was_submerged = bool(st.get("wp_s", _was_submerged))
	_waterproof_drown_timer = float(st.get("wp_d", _waterproof_drown_timer))
	# 恢复武器背包、手持装备及弹药状态
	_apply_weapon_state(st)
	# 根据恢复的姿态启用对应的碰撞体，并同步动画翻转方向
	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != state
	animator.flip_h = facing_direction < 0
	# 执行微量位移以刷新地面接触检测，使下一物理帧能正确读取地面状态
	var saved := velocity
	velocity = Vector2(0.0, 0.001)
	move_and_slide()
	velocity = saved


# ── 武器与背包数据的轻量级同步 ──
# 客户端预测命中时仅同步由服务端裁决的背包与手持数据，无需回滚物理位置
func sync_soft_state(st: Dictionary) -> void:
	# 比较手持武器实例与背包结构，避免无变更时冗余刷新界面
	if int(st.get("wslot", weapons._current_type)) == weapons._current_type \
			and int(st.get("winst", weapons.current_inst())) == weapons.current_inst() \
			and _inv_structure_equal(st.get("inv", [])):
		return
	_apply_weapon_state(st)


# 校验背包中的武器类型与实例 ID 列表结构是否完全一致
func _inv_structure_equal(want: Array) -> bool:
	var held: Array = weapons.inventory.held
	if held.size() != want.size():
		return false
	for i in held.size():
		if int(held[i]["type"]) != int(want[i].get("type", 0)):
			return false
		if int(held[i]["inst"]) != int(want[i].get("inst", 0)):
			return false
	return true


# 应用服务端的武器与弹药状态，先同步背包列表，再恢复手持装备与弹药量
func _apply_weapon_state(st: Dictionary) -> void:
	var wslot := int(st.get("wslot", weapons._current_type))
	# 优先按武器实例 ID 恢复手持槽位，若无法匹配则按武器类型保底处理
	var by_inst := weapons.restore_inventory(st.get("inv", []), int(st.get("winst", 0)))
	if wslot > 0 and wslot != weapons._current_type:
		# 当前手持武器类型与权威状态不一致时重新装配对应武器
		if by_inst and weapons._current_index >= 0:
			weapons.equip_index(weapons._current_index)
		else:
			weapons.equip_type(wslot)
	var w: WeaponBase = weapons._weapon
	if w != null:
		w.fire_cd_timer = float(st.get("fire_cd", w.fire_cd_timer))
		w._aiming = bool(st.get("aiming", w._aiming))
		w._fire_buffered = bool(st.get("fire_buf", w._fire_buffered))
		w._aim_facing = int(st.get("aim_f", w._aim_facing))
		w._current_aim_facing = int(st.get("aim_cf", w._current_aim_facing))
		# 同步武器开火冷却、瞄准状态及当前弹药量
		WeaponComponent.apply_mag(w, int(st.get("mag", w.mag_ammo)))
		w._reloading = bool(st.get("rld", w._reloading))
		w._reload_t = float(st.get("rld_t", w._reload_t))

# 清理跳跃缓冲与土狼时间标记，防止攀爬跳离梯子时因残留输入触发连跳
func cancel_jump_state() -> void:
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	jump_cut_applied = false

# 受击打断冲刺状态
func cancel_charge() -> void:
	is_charge = false
	charge_timer = 0.0

# 更新角色防水值（氧气）：完全没入水面时按固定频率扣除，露出水面时回复
func _update_waterproof(delta: float) -> void:
	var submerged := false
	if swim.in_water:
		var surface_y := Water.surface_y_at(global_position)
		# 呼吸基准线位于角色胸口位置，水面高于基准线时开始消耗氧气
		var breath_point := global_position + Vector2(0.0, PlayerParams.water_breath_line_offset)
		submerged = Water.submerged(breath_point, surface_y)
	if submerged != _was_submerged:
		_was_submerged = submerged
		_waterproof_timer = 0.0  # 入水或出水状态切换时重置计时器
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


# 单人模式倒地重启：在指定出生点复位角色位置、生命值与氧气，清理物理状态残留
func restart_at(spawn_cell: Vector2i) -> void:
	var ts: int = GameParameters.TILE_SIZE
	global_position = Vector2(spawn_cell.x * ts + ts * 0.5, spawn_cell.y * ts + ts * 0.5)
	velocity = Vector2.ZERO
	is_charge = false
	charge_timer = 0.0
	is_squat = false
	cancel_jump_state()
	combat.knock_velocity = Vector2.ZERO
	combat.iframes = 0.0
	if combat.is_downed():
		combat.revive()   # 重置倒地状态并恢复屏幕渲染色彩
	else:
		combat.hp = combat.max_hp
	combat.hp_changed.emit(combat.hp, combat.max_hp)   # 同步 HUD 生命值显示
	waterproof = max_waterproof
	waterproof_changed.emit(waterproof, max_waterproof)
	_was_submerged = false
	_waterproof_timer = 0.0
	_waterproof_drown_timer = 0.0
	weapons.cancel_aim()
	# 复位当前手持武器弹药状态并同步至背包数据
	weapons.reset_mag_state()
	set_controls_locked(false)


# ── 地面武器拾取与丢弃 ──
var _reload_ring: ReloadRing = null   # 换弹圆环节点引用
var _drop_hold_t := 0.0     # 丢弃按键长按计时器
var _drop_latched := false  # 长按单次触发锁定标记


# 轮询地面拾取与丢弃输入：长按 Q 丢弃，单按 F 拾取
func _poll_pickup_drop(delta: float) -> void:
	if input_source.is_action_pressed("Q"):
		if not _drop_latched:
			_drop_hold_t += delta
			if _drop_hold_t >= PlayerParams.weapon_drop_hold_time:
				_drop_latched = true
				if Level0.pvp_mode:
					input_source.mark_drop_edge()
				else:
					_try_drop()
	else:
		_drop_hold_t = 0.0
		_drop_latched = false

	# 拾取操作：单人模式就地拾取，联机模式由服务端统一仲裁拾取权
	if input_source.is_pickup_pressed() and not Level0.pvp_mode:
		_try_pickup()


# 获取长按丢弃进度（0.0 ~ 1.0），供 HUD 丢弃进度条渲染显示
func drop_hold_progress() -> float:
	if _drop_latched:
		return 1.0
	return clampf(_drop_hold_t / PlayerParams.weapon_drop_hold_time, 0.0, 1.0)


# 获取所属的关卡根节点引用
func host_level() -> Level0:
	var n: Node = self
	while n != null:
		if n is Level0:
			return n
		n = n.get_parent()
	return null


func _try_pickup() -> void:
	var lvl := host_level()
	if lvl != null:
		lvl.try_pickup_for(self)


func _try_drop() -> void:
	if weapons.current_type_id() == 0:
		return   # 空手状态下无需丢弃
	var e: Dictionary = weapons.drop_current()
	if e.is_empty():
		return
	var lvl := host_level()
	if lvl != null:
		lvl.spawn_pickup(int(e["type"]), int(e["mag"]),
			global_position + PlayerParams.weapon_drop_offset * Vector2(float(facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * facing_direction, -PlayerParams.weapon_drop_up),
			0, true)   # 刚丢弃的武器进入短暂拾取冷却期，防止误按捡回


func _unhandled_input(event: InputEvent) -> void:
	# 滚轮切换武器：循环选择下一个已启用的武器槽位
	if Settings.wheel_switch and not combat.is_downed() \
			and event is InputEventMouseButton and event.pressed:
		var dir := 0
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dir = -1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dir = 1
		if dir != 0:
			if Level0.pvp_mode:
				weapons.request_net_cycle(dir)
			else:
				weapons.cycle_index(dir)
			return
	if combat.is_downed():
		# 联机对战由服务端权威控制复活，单人模式按 R 重置关卡
		if not Level0.pvp_mode and event.is_action_pressed("R"):
			var lvl := get_tree().current_scene
			if lvl is Level0:
				# 延迟至帧末调用重置逻辑，避免在当前输入分发调用栈内直接销毁碰撞层节点
				(lvl as Level0).restart_single.call_deferred()
		return


# 更新换弹圆环状态：根据装填进度计算倒计时并在角色后侧渲染
func _update_reload_ring() -> void:
	if _reload_ring == null or not is_instance_valid(_reload_ring):
		return
	var w := weapons.current_weapon()
	var prog := w.reload_progress() if w != null else -1.0
	_reload_ring.visible = prog >= 0.0
	if prog < 0.0:
		return
	var sc := maxf(absf(scale.x), 0.001)
	# 局部坐标偏移换算，抵消角色根节点的缩放影响
	_reload_ring.position = Vector2(-RELOAD_RING_OFFSET.x * float(facing_direction),
			RELOAD_RING_OFFSET.y) / sc
	_reload_ring.set_progress(prog, w.reload_time * (1.0 - prog))


const RELOAD_RING_OFFSET := Vector2(58.0, -44.0)   # 换弹圆环局部坐标偏移向量

# 时空回溯状态还原：恢复位置、速度、生命值、朝向与倒地状态
func rewind_restore(d: Dictionary) -> void:
	global_position = d["p"]
	if d["v"] != null:
		velocity = d["v"]
	combat.knock_velocity = Vector2.ZERO
	# 生命值变动时发送更新信号，确保 HUD 能够即时响应回溯
	var hp_before := combat.hp
	combat.hp = clampi(int(d["hp"]), 0, combat.max_hp)
	if combat.hp != hp_before:
		combat.hp_changed.emit(combat.hp, combat.max_hp)
	facing_direction = int(d["facing"])
	var downed_now := is_downed()
	# 回溯武器与弹药状态：还原背包各格弹量与手持武器
	var wc = weapons
	if wc != null and d.has("wmags"):
		var inv = wc.get("inventory")
		if inv != null:
			var held: Array = inv.get("held")
			var mags: Array = d["wmags"]
			for i in mini(held.size(), mags.size()):
				held[i]["mag"] = int(mags[i])
		if int(d.get("widx", -1)) != int(wc.get("_current_index")) and int(d.get("widx", -1)) >= 0:
			wc.call("equip_index", int(d["widx"]))
		var live2 = wc.call("current_weapon") if wc.has_method("current_weapon") else null
		if live2 != null and is_instance_valid(live2) and int(d.get("wlive", -1)) >= 0:
			live2.set("mag_ammo", int(d["wlive"]))
	if bool(d["downed"]) and not downed_now:
		combat.set_downed_by_rewind(true)
	elif not bool(d["downed"]) and downed_now:
		combat.revive()
