extends CharacterBody2D

@export var animator : AnimatedSprite2D

# --- 物理参数（推荐从全局读取） ---
var gravity: float = GameParameters.gravity0
var jump_velocity: float = PlayerParams.jump_velocity
var charge_down_velocity: float = PlayerParams.charge_down_velocity
var charge_velocity: float = PlayerParams.charge_velocity   # 冲刺速度
var charge_duration: float = PlayerParams.charge_duration   # 冲刺持续时间（秒）
var charge_air_gravity_mult: float = PlayerParams.charge_air_gravity_mult  # 冲刺滞空重力削减
var move_speed: float = PlayerParams.move_speed
var crouch_walk_speed: float = PlayerParams.crouch_walk_speed

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

# 攻击查询:weapon_base 经 has_method 守卫调用(本地委托真实 Input;服务器注入网络输入)。
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

# 当前瞄准方向(世界坐标系):委托当前武器的实际瞄准(本地=鼠标,服务器=注入方向)。
# PvP 客户端每 tick 打包上报用。
func get_current_aim_dir() -> Vector2:
	var w := weapons.current_weapon()
	if w != null:
		return w.get_current_aim_dir()
	return Vector2(float(facing_direction), 0.0)

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

# ── PvP 服务器渲染模式:本地玩家不跑移动物理,位置/姿态/朝向由 30Hz 快照驱动 ──
# 根因:C2(客户端预测)对梯子等"边沿+位置敏感"机制与服务器权威模拟打架 → 大量回拉。
# 根治:本地玩家完全由快照驱动(与远端副本同款最短路径插值),只保留武器/瞄准/受击反馈。
var server_rendered: bool = false
var _server_target := Vector2.ZERO   # 服务器 canonical 位置(本地玩家恒在中间副本)
var _server_have_target := false
var _server_pose: int = 0            # Pose 枚举值,见 POSE_ANIM
var _server_facing: int = 1
const SERVER_INTERP_RATE := 30.0     # 紧跟踪服务器位置(60Hz 快照下滞后约 1 帧;接缝不爬行)

func set_server_rendered(enabled: bool) -> void:
	server_rendered = enabled

# PvP COUNTDOWN 冻结:锁住本地武器开火查询(避免倒计时里打空枪)。
# 移动冻结由服务器权威(不喂输入)完成,本地玩家是服务器渲染、自然不动。
var _controls_locked := false
func set_controls_locked(locked: bool) -> void:
	_controls_locked = locked
	# C2:本地预测必须与服务器冻结同款——服务器 COUNTDOWN/换局不喂输入,客户端若照常读真实
	# Input 会自己走动 → PLAYING 起 ack 跳变 → 大回滚。冻结读口等效于"双端都不动"。
	input_source.frozen = locked

# PvP 客户端每帧喂服务器快照:存目标/姿态/朝向 + 权威采纳血量/防水/倒地。
func apply_server_snapshot(data: Dictionary) -> void:
	_server_target = data.get("pos", _server_target)
	_server_have_target = true
	_server_pose = int(data.get("pose", _server_pose))
	_server_facing = int(data.get("facing", facing_direction))
	velocity = data.get("vel", velocity)   # 供 water_fx 等读速度做视觉
	# 武器槽位以服务器权威为准(本地切枪已在 _update_server_rendered 即时反馈,这里防脱同步)
	var wslot := int(data.get("weapon", 0))
	if wslot > 0 and wslot != weapons.current_slot_int():
		weapons.equip(str(wslot))
	var hp := int(data.get("hp", self.hp))
	var wp := int(data.get("waterproof", waterproof))
	var downed := bool(data.get("downed", combat.is_downed()))
	if hp != self.hp or wp != waterproof or downed != combat.is_downed():
		apply_authoritative_state(hp, wp, downed)


# ── C2(客户端预测 rollback)整态快照:只抓影响模拟判定的关键量 ──
# 由 server/match_host 每 tick 采集随快照下发;客户端 PredictionRollback 比对/回滚重放用。
# 不含:相机/后处理/音效/特效/HUD 等纯视觉量,避免纠偏时画面抖。
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
		"wslot": weapons._current_slot,
	}
	var w: WeaponBase = weapons._weapon
	if w != null:
		st["fire_cd"] = w.fire_cd_timer
		st["aiming"] = w._aiming
		st["fire_buf"] = w._fire_buffered
		st["aim_f"] = w._aim_facing
		st["aim_cf"] = w._current_aim_facing
	return st

func restore_state(st: Dictionary) -> void:
	# 纯移动/姿态变量直接写回
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
	# 血量/防水/倒地走权威采纳路径(处理倒地转体/复活副作用;数值无变化时不重复 emit)
	apply_authoritative_state(int(st.get("hp", combat.hp)),
			int(st.get("wp", waterproof)), bool(st.get("down", combat.is_downed())))
	combat.iframes = float(st.get("ifr", combat.iframes))
	combat.knock_velocity = st.get("knock", combat.knock_velocity)
	_waterproof_timer = float(st.get("wp_t", _waterproof_timer))
	_was_submerged = bool(st.get("wp_s", _was_submerged))
	_waterproof_drown_timer = float(st.get("wp_d", _waterproof_drown_timer))
	# 武器:槽位变了重建,否则直接覆盖内部决定态
	var wslot := int(st.get("wslot", weapons._current_slot))
	if wslot > 0 and wslot != weapons._current_slot:
		weapons.equip(str(wslot))
	var w: WeaponBase = weapons._weapon
	if w != null:
		w.fire_cd_timer = float(st.get("fire_cd", w.fire_cd_timer))
		w._aiming = bool(st.get("aiming", w._aiming))
		w._fire_buffered = bool(st.get("fire_buf", w._fire_buffered))
		w._aim_facing = int(st.get("aim_f", w._aim_facing))
		w._current_aim_facing = int(st.get("aim_cf", w._current_aim_facing))
	# 姿态碰撞箱按恢复的 state 启用 + 翻转同步(下帧 move_and_slide 用对的碰撞外形)
	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != state
	animator.flip_h = facing_direction < 0
	# CharacterBody2D 的 is_on_floor 是上次 move_and_slide 的内部结果、无法直接赋值;
	# 恢复位置后做一次微位移 move_and_slide(向下 0.001px,可忽略)让它在恢复位置重判接触,
	# 供恢复后第一个物理 tick 的逻辑读到正确的地面状态。
	var saved := velocity
	velocity = Vector2(0.0, 0.001)
	move_and_slide()
	velocity = saved


func _ready() -> void:
	add_to_group("player")

	# 转发 combat 的生命/倒地信号到根(外部只认根上的 hp_changed;倒地 → 取消瞄准)
	combat.hp_changed.connect(func(cur: int, mx: int) -> void: hp_changed.emit(cur, mx))
	combat.went_down.connect(func() -> void: weapons.cancel_aim())
	hp_changed.emit(combat.hp, combat.max_hp)

	# 缓存各姿态碰撞箱节点
	for pose in Pose.values():
		_coll_by_pose[pose] = get_node(POSE_NODE[pose])

	weapons.equip(weapons.default_slot())
	call_deferred("add_child", WaterFx.new())


# 指数缓动：朝目标值逼近。rate 越大越跟手；
# 起步快后渐缓、松键带滑行、转身平滑穿过 0，避免线性 move_toward 的生硬。
func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))


func _physics_process(delta: float) -> void:
	if server_rendered:
		_update_server_rendered(delta)
		return
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

	# 切枪走 input_source 轮询(本地=Input 事件,网络=注入包)。放移动逻辑前,先装备再算移动惩罚。
	var wslot := input_source.get_weapon_slot_pressed()
	if wslot > 0 and not weapons.is_prop_mode():
		weapons.equip(str(wslot))
	# R 换弹请求(网络玩家):输入包携带 rl 边沿,服务器权威玩家在此消费
	if input_source.has_method("consume_reload_request") and input_source.consume_reload_request():
		weapons.start_reload()

	var mult := weapons.movement_multiplier()

	var horizontal_input = input_source.get_axis("left", "right")

	# ---------- 水中(浮水/游泳):速度由 swim 设置,跳过攀爬/重力/跳跃/下蹲/冲刺 ----------
	var in_water := swim.update(self, delta, mult, input_source)
	_update_waterproof(delta)
	var climbing := false
	var latched := false
	if not in_water:
		# ---------- 攀爬(梯子/锁链:攀附不受重力,按住上/下爬,锁链更快,下降更快) ----------
		climbing = climb.update(mult, delta, is_squat, input_source)
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
			# 空中冲刺重力削减:冲刺那几帧重力×charge_air_gravity_mult(变平,可跨沟)。
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
			# 冲刺中按跳 = 打断冲刺转跳跃,保留当前水平速度作动量(下方 accel/air-brake 平滑接管)。
			if is_charge:
				is_charge = false
				charge_timer = 0.0
			velocity.y = jump_velocity * mult.y
			jump_buffer_timer = 0.0
			coyote_timer = 0.0
			jump_cut_applied = false
			Sfx.play("jump")

		# 可变高度：上升中松开跳跃键，立即衰减上升速度（每次跳跃只截断一次）
		if not jump_cut_applied and input_source.is_action_just_released("up") and velocity.y < 0.0:
			velocity.y *= jump_cut_factor
			jump_cut_applied = true

	# ---------- 下蹲 / 空中下冲 ----------
	if not latched and not in_water:
		# 空中按 S 下冲(不在梯/链格上,否则跳上去按↓可直接穿梯/链,只能抓住爬)。
		if not is_on_floor() and input_source.is_action_just_pressed("down") \
				and not climb.is_over_climb_tile():
			velocity.y = charge_down_velocity
		# 下蹲 = 在地面 且 按住 S,逐帧推导——不用 just_pressed/just_released 边沿。
		# 旧实现 release 分支套在 if is_on_floor() 内:空中松开 S 不执行 → 落地仍蹲(卡蹲)。
		var want_squat := is_on_floor() and input_source.is_action_pressed("down")
		if want_squat and not is_squat:
			is_charge = false   # 冲刺中按 S → 取消冲刺进蹲
		is_squat = want_squat

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
				# 收尾交回下方 accel/air-brake 平滑减速,不做 1500→750 突变半刹。
		else:
			# 蹲走:蹲态目标换成 crouch_walk_speed(可小幅左右移动);非蹲态走 move_speed。
			var speed_target := crouch_walk_speed if is_squat else move_speed
			var target_velocity_x = horizontal_input * speed_target * mult.x
			if horizontal_input != 0:
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

	# ---------- 冲刺撞水平墙 → 立即结束(不再顶着墙冲满) ----------
	if is_charge:
		for i in range(get_slide_collision_count()):
			var col := get_slide_collision(i)
			if col != null and absf(col.get_normal().x) > 0.5:
				is_charge = false
				charge_timer = 0.0
				velocity.x = 0.0
				break

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

# 是否冲刺中(武器判断用):冲刺锁身体朝向(见 set_facing),但枪口应保持鼠标瞄准侧不跟随翻转。
func is_charging() -> bool:
	return is_charge

func is_downed() -> bool:
	return combat.is_downed()


## 无伤冲击(击退炮/吸力炮):strength 带符号,>0 推离爆心 / <0 吸向爆心。
## 走爆炸同款独立击退向量(combat.knock_velocity),不扣血不触发无敌帧。
func apply_blast_force(center: Vector2, strength: float) -> void:
	var dir := MazeGenerator.toroidal_delta_px(center, global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var away := dir.normalized() if not dir.is_zero_approx() else Vector2.RIGHT
	combat.knock_velocity = away * strength

func apply_recoil(push: float) -> void:
	weapons.apply_recoil(push, is_squat, climb.is_latched())

# 服务器快照权威状态:血量/防水/倒地直接采纳(本地 hit 事件只做视觉,血量以快照为准)。
func apply_authoritative_state(hp_val: int, waterproof_val: int, downed_val: bool) -> void:
	combat.hp = clampi(hp_val, 0, combat.max_hp)
	combat.hp_changed.emit(combat.hp, combat.max_hp)
	waterproof = clampi(waterproof_val, 0, max_waterproof)
	waterproof_changed.emit(waterproof, max_waterproof)
	if downed_val and not combat.is_downed():
		combat.force_down()
	elif not downed_val and combat.is_downed():
		combat.revive()

# PvP 服务器渲染:位置最短路径插值 + 姿态/朝向由快照驱动(不跑本地物理,服务器权威)。
func _update_server_rendered(delta: float) -> void:
	combat.update_iframe_blink(delta)   # 受击无敌闪烁仍本地播放
	# 切枪:服务器渲染模式跳过移动路径里的切枪轮询,这里补(本地即时反馈;服务器从输入包同切)。
	var wslot := input_source.get_weapon_slot_pressed()
	if wslot > 0 and not weapons.is_prop_mode():
		weapons.equip(str(wslot))
	if not _server_have_target:
		return
	# 当前 canonical 位置 → 服务器 canonical 位置的最短向量,指数插值(跨接缝连续)
	var d := MazeGenerator.toroidal_delta_px(global_position, _server_target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	global_position += d * (1.0 - exp(-SERVER_INTERP_RATE * delta))
	# 回中间副本:插值可能跨接缝进入邻副本,取模回 canonical(本地玩家恒在中间副本)
	global_position = MazeGenerator.wrap_to_range(global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# 朝向 + 姿态动画(倒地由 combat 停动画/转体,这里不覆盖)
	facing_direction = 1 if _server_facing >= 0 else -1
	animator.flip_h = facing_direction < 0
	if not combat.is_downed():
		animator.play(POSE_ANIM[clampi(_server_pose, Pose.STAND, Pose.SQUAT)])

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
		# 呼吸按「大部分没入」扣:参考线比中心低 water_breath_line_offset(≈胸口下沿),
		# 水面到这条线就扣,要浮到水面低于它才回气(头能露出仍扣)。
		var breath_point := global_position + Vector2(0.0, PlayerParams.water_breath_line_offset)
		submerged = Water.submerged(breath_point, surface_y)
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


# 单人「倒地按 R 重启」(Level0.restart_single 调):满血满氧回出生点,清倒地/冲刺/跳跃
# 残留,武器切回首个启用槽并把残弹回满(装填中留给计时器收尾,不挡复位)。
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
		combat.revive()   # 复位倒地 + PostProcess 变灰复位(PvP 回合复活同款)
	else:
		combat.hp = combat.max_hp
	combat.hp_changed.emit(combat.hp, combat.max_hp)   # 兜底同步 HUD 血条(revive 本身不发射)
	waterproof = max_waterproof
	waterproof_changed.emit(waterproof, max_waterproof)
	_was_submerged = false
	_waterproof_timer = 0.0
	_waterproof_drown_timer = 0.0
	weapons.cancel_aim()
	weapons.exit_prop_mode()
	weapons.equip(weapons.default_slot())
	weapons.refill_all()   # 道具"每次复活只能携带 N 枚"由此回满
	var w := weapons.current_weapon()
	if w != null and w.reload_active() and not w.is_reloading():
		w.mag_ammo = w.mag_size
	set_controls_locked(false)


func _unhandled_input(event: InputEvent) -> void:
	# 滚轮切枪(设置开启时):循环跳到下一个启用槽位;倒地时不切。
	# PvP:滚轮事件不在输入包协议里,只本地切会被快照防脱同步切回 → 走
	# request_net_cycle(本地即时切 + 目标槽位打包进输入包由服务器权威同步)。
	# ── T = 道具模式开关(单机/PvP 通用;倒地不可用)────────────────────────
	# 进入:手上切到第一个可用道具(隐藏槽位 8/9/10),PvP 经槽位同步通道让服务器跟随;
	# 退出:回到进入前的武器槽。道具模式内:数字 1/2/3 直选道具,滚轮循环。
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_T and not combat.is_downed():
		if weapons.is_prop_mode():
			weapons.exit_prop_mode()
		else:
			weapons.enter_prop_mode()
		return
	if weapons.is_prop_mode() and not combat.is_downed():
		if event is InputEventKey and event.pressed and not event.echo:
			var pi := -1
			match event.physical_keycode:
				KEY_1:
					pi = 0
				KEY_2:
					pi = 1
				KEY_3:
					pi = 2
			if pi >= 0:
				weapons.select_prop_index(pi)
				return
		if event is InputEventMouseButton and event.pressed:
			var pd := 0
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				pd = -1
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				pd = 1
			if pd != 0:
				weapons.cycle_prop(pd)
				return
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
				weapons.cycle_slot(dir)
			return
	if combat.is_downed():
		# PvP 倒地不重载场景(服务器权威管复活/回合,阶段4);单人照旧。
		if not Level0.pvp_mode and event.is_action_pressed("R"):
			# 单人重启:原地复位,不重建世界(重建会偶发原生段错误→重启后蓝屏/地图未加载)。
			# 只在当前场景确为 Level0 时生效(主菜单演示世界不误触发)。
			var lvl := get_tree().current_scene
			if lvl is Level0:
				(lvl as Level0).restart_single()
		return
	# R 换弹(实验性,单机):给当前武器上弹(倒地时 R 是重载场景,见上)
	if event.is_action_pressed("R") and Settings.reload_enabled and not Level0.pvp_mode:
		var w := weapons.current_weapon()
		if w != null:
			w.start_reload()
