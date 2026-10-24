extends CharacterBody2D

@export var animator : AnimatedSprite2D

var gravity: float = GameParameters.gravity0
var jump_velocity: float = PlayerParams.jump_velocity
var charge_down_velocity: float = PlayerParams.charge_down_velocity
var charge_velocity: float = PlayerParams.charge_velocity   # 冲刺速度
var charge_duration: float = PlayerParams.charge_duration   # 冲刺持续时间(秒)
var charge_air_gravity_mult: float = PlayerParams.charge_air_gravity_mult  # 空中冲刺重力倍率
var move_speed: float = PlayerParams.move_speed
var crouch_walk_speed: float = PlayerParams.crouch_walk_speed  # 蹲走水平速度

# 水平加速/刹车/转身的指数缓动系数(越大越跟手)
var accel_ground: float = PlayerParams.accel_ground
var accel_air: float = PlayerParams.accel_air
var brake_ground: float = PlayerParams.brake_ground
var brake_air: float = PlayerParams.brake_air

var coyote_time: float = PlayerParams.coyote_time
var jump_buffer_time: float = PlayerParams.jump_buffer_time
var jump_cut_factor: float = PlayerParams.jump_cut_factor
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var jump_cut_applied: bool = false   # 本次跳跃是否已截断(可变高度)

var is_squat: bool = false
var is_charge: bool = false
var facing_direction: int = 1   # 1=右，-1=左

var charge_timer: float = 0.0
var _last_move_dir: int = 1            # 最近水平移动方向(1右/-1左)
var _last_move_timer: float = 0.0      # 距上次水平移动的剩余窗口(>0 表示最近在走)

@export var weapon_slot: Node2D

@onready var climb: ClimbComponent = $Climb
@onready var weapons: WeaponComponent = $Weapons
@onready var combat: CombatComponent = $Combat
@onready var swim: SwimComponent = $Swim

# 补间形变(squash & stretch):运行期创建、不进 capture_state()/restore_state()、不碰碰撞箱。
var squash: SquashStretch = null
# ★ move_and_slide() 之前的 velocity.y,只喂 squash 的无状态落地推导;不得进 capture_state()、不得被模拟逻辑读。
var _pre_move_vy: float = 0.0

# 输入来源:默认委托真实 Input;服务器注入 PacketInputSource 驱动远端玩家。
var input_source: PlayerInput = LocalInputSource.new()

func set_input_source(src: PlayerInput) -> void:
	input_source = src

# 瞄准覆盖:本地返回 ZERO 时武器用鼠标;服务器注入的网络输入返回瞄准方向。
func get_aim_dir_override() -> Vector2:
	return input_source.get_aim_dir_override()

# 网络注入输入源:武器瞄准据此决定不读宿主机 OS 鼠标(见 weapon_base)。
func input_is_network() -> bool:
	return input_source != null and input_source.is_network_driven()

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

# 当前瞄准方向(世界坐标系):委托当前武器的实际瞄准(本地=鼠标,服务器=注入方向);PvP 客户端每 tick 打包上报用。
func get_current_aim_dir() -> Vector2:
	var w := weapons.current_weapon()
	if w != null:
		return w.get_current_aim_dir()
	return Vector2(float(facing_direction), 0.0)

signal hp_changed(current: int, max: int)   # 转发自 CombatComponent,HUD 接口不变
signal waterproof_changed(current: int, max: int)   # 防水值(氧气)变化,HUD 更新

var hp: int:
	get:
		return combat.hp
var max_hp: int:
	get:
		return combat.max_hp

# 防水值(氧气):没顶按 water_drain_interval 掉 1、暴露空气按 water_recover_interval 回 1;归零后每秒扣血。
var waterproof: int = PlayerParams.player_waterproof_max
var max_waterproof: int = PlayerParams.player_waterproof_max
var _waterproof_timer: float = 0.0
var _was_submerged: bool = false
var _waterproof_drown_timer: float = 0.0

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

# 姿态锁:进入某姿态后锁定一小段时间,防止 is_on_floor()/velocity 抖动导致 move↔fly 等高频切换(走路抽搐)。
var state: Pose = Pose.STAND
var state_lock_timer: float = 0.0
const STATE_LOCK_TIME := 0.15   # 秒，切换后的最短停留时长


var _coll_by_pose: Dictionary = {}

# PvP COUNTDOWN/局间冻结:锁住本地玩家输入(武器开火查询 + 移动),并把输入源一并冻结 ——
# 否则本地预测在服务器权威冻结的倒计时里照常移动,PLAYING 起 ack 跳变 → 大 rollback。
var _controls_locked := false
func set_controls_locked(locked: bool) -> void:
	_controls_locked = locked
	if input_source != null:
		input_source.frozen = locked

func _ready() -> void:
	add_to_group("player")

	combat.hp_changed.connect(func(cur: int, mx: int) -> void: hp_changed.emit(cur, mx))
	combat.went_down.connect(func() -> void: weapons.cancel_aim())
	hp_changed.emit(combat.hp, combat.max_hp)

	for pose in Pose.values():
		_coll_by_pose[pose] = get_node(POSE_NODE[pose])

	# 单机开局空手:武器全部散落在地图上,由 Level0._ready 铺;联机由 MatchHost 调 set_initial_inventory 发随机一把。
	weapons.set_initial_inventory([])
	# 换弹圆环挂在玩家自己身上(一个接入点覆盖单机/PvP/大乱斗):反向缩放抵消玩家根的 scale,位置每帧按朝向贴到后侧。
	_reload_ring = ReloadRing.new()
	_reload_ring.scale = Vector2.ONE / scale.x
	_reload_ring.visible = false
	add_child(_reload_ring)
	call_deferred("add_child", WaterFx.new())
	# 补间形变:挂在玩家自己身上(与 _reload_ring 同款的一个接入点覆盖单机/PvP/大乱斗);animator 是 @export 引用,场景实例化时就已就位。
	squash = SquashStretch.new()
	# ★ 先 add_child() 再 setup(),与另两个宿主(敌鸟/对手副本)统一。两种序今天等价 —— SquashStretch 没有 _ready,入树不触发按参数建出来的东西。
	# ★ 本仓另有一条相反规矩:WeaponPickup.configure() 必须先于 add_child()。将来给本组件加 _ready 时,这三处要一起倒过来。
	add_child(squash)
	squash.setup(animator, SquashStretch.Profile.PLAYER)


var _speed_mult := 1.0  # 时间场速度域倍率(加速;跨函数用,故设成员)

# Beta 时间玩法(PvP):服务器权威与本端预测各写一次的加速倍率(1 = 常速)。单机不走这里(走 TimeField.player_speed_mult)。
# ★ 本字段也是唯一分发源:由 _push_haste_mult() 推给攀爬/武器/游泳三个消费点;match_host 的写与快照的读都打在本字段上。
var pvp_haste_mult := 1.0
var _ghost_t := 0.0     # 残影生成计时(加速时)
var _ghost_flip := false  # 红/蓝交替


# 本帧倍率推给三个消费点:攀爬/武器的宿主引用是一次给入的、而倍率每帧在变 ⇒ 只能每帧推;游泳走 swim.update 的调用参数。
# ★ 调用点两处(都在 _physics_process 正常态路径、都在 climb.update 之前):weapons.tick 之前(轮询开火吃本帧倍率)、切枪之后。消费点只读注入值,拿不到就是 1×(静默降级)。
func _push_haste_mult(tm: float) -> void:
	climb.haste_mult = tm
	var cur_w := weapons.current_weapon()
	if cur_w != null:
		cur_w.haste_mult = tm


func _physics_process(delta: float) -> void:
	# 加速走速度域(move_and_slide 用引擎自己的 delta):tick 类与水平速度目标 ×tm,重力/跳跃保持原样 —— 缩放 delta 只会让坠落变快、跳跃变低、移速不变。
	var tm := TimeField.player_speed_mult() if TimeField.current != null else pvp_haste_mult
	_speed_mult = tm
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	# squash 必须在最首行(倒地早退之前):否则倒地后 animator.scale 会卡在最后一个挤压值上。参数成对读:is_on_floor() 是上一帧 move_and_slide 的结果,_pre_move_vy 是那次调用之前缓存的 velocity.y。
	squash.tick(delta, _pre_move_vy, is_on_floor(), combat.is_downed())
	if combat.is_downed():
		# 倒地不更新 _pre_move_vy:不归零的话,被击杀那一刻的下坠速度会陈旧地留满整个倒地窗口,并与复活首帧的地面态配对 → 一个满幅假挤压脉冲。
		_pre_move_vy = 0.0
		_tick_downed(delta)
		return
	_push_haste_mult(tm)   # ① 见该函数注释:必须在 weapons.tick 之前(tick 里的轮询开火吃它)
	weapons.tick(delta * tm)   # 加速时开火/换弹节拍 ×tm(武器帧逻辑走物理 tick)

	if _speed_mult > 1.0:
		_ghost_t -= delta
		if _ghost_t <= 0.0:
			_ghost_t = 0.03   # 2× 下比原先(0.045)更密,拖尾才跟得上
			var anim := animator   # @export 引用,场景实例化即就位
			if anim != null:
				var tint := Color(1.0, 0.25, 0.25, 0.55) if _ghost_flip else Color(0.3, 0.4, 1.0, 0.55)
				_ghost_flip = not _ghost_flip
				AfterImage.spawn(get_parent(), anim, tint)

	combat.update_iframe_blink(delta)

	# 切枪走 input_source 轮询,两条不同量纲的路别合并:本地输入源给背包第 N 把(1-based,就地切),网络输入源给权威目标 inst。
	# ★ 上行必须是 inst:位置的含义由本端背包决定,而拾取/丢弃是服务器裁决、客户端不预测 —— 那 ≈1 RTT 的窗口里同一个下标在两端解出不同的枪。
	var idx := input_source.get_switch_index_pressed()
	if idx > 0:
		weapons.equip_index(idx - 1)
	var winst := input_source.consume_switch_inst()
	if winst > 0:
		weapons.equip_inst(winst)
	# ★ 切枪之后再推一次倍率(见 _push_haste_mult):本帧刚装上的那把也要拿到本帧倍率,否则下一帧输入阶段开火会用它出生时的默认 1.0 出弹。
	_push_haste_mult(tm)

	# R 换弹同样走 input_source 轮询:必须轮询,不能读原始 InputEvent —— 权威服务器永远收不到(它没有输入事件,只有注入包)。
	# 排在切枪之后:同帧切枪+换弹时换的是新枪的弹。倒地时不进来(上面的早退挡住)—— 倒地 R 是重载/复活。
	if input_source.is_action_just_pressed("R"):
		var reload_w := weapons.current_weapon()
		if reload_w != null:
			reload_w.start_reload()

	_poll_pickup_drop(delta)
	_update_reload_ring()

	var mult := weapons.movement_multiplier()

	var horizontal_input = input_source.get_axis("left", "right")

	# 水中与攀爬是数据源:in_water / latched 决定后面每一块跑不跑,故留在编排函数里,只把消费它们的逻辑分出去。
	var in_water := swim.update(self, delta, mult, input_source, tm)
	_update_waterproof(delta)
	var latched := false
	if not in_water:
		climb.update(mult, delta, is_squat, input_source)
		latched = climb.is_latched()
	else:
		is_charge = false
		is_squat = false

	_tick_vertical(delta, latched, in_water, mult)
	_tick_crouch_and_dash(delta, latched, in_water)
	_tick_horizontal(delta, in_water, horizontal_input, mult)
	_tick_facing(delta, horizontal_input)
	_tick_pose_and_collision(delta, in_water)

	# 爆炸击退位移单独走 move_and_collide(带碰撞),不污染 velocity —— 地面把向下击退吃掉后再减回去会把玩家弹起。
	combat.apply_knock(delta)

	# ★ 必须在 move_and_slide() 之前取值:落地那一帧它在调用后就被清零。且必须滤掉不是摔下来的下坠速度(squash 的契约 = 地面真正吸收掉的坠落速度)。
	# ★ 水中/攀爬中置 0 是落实设计取舍(游泳不该有自由落体那种弹感),不是修 bug;梯子下行那条满幅假挤压仍是残留。实测读数与推导见 docs/eng/player.md。
	_pre_move_vy = 0.0 if (in_water or latched) else velocity.y
	move_and_slide()

	_tick_slide_reactions()
	_wrap_position()


func _tick_vertical(delta: float, latched: bool, in_water: bool, mult: Vector2) -> void:
	if latched or in_water:
		return
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		# 空中冲刺那几帧重力 ×charge_air_gravity_mult(变平,可跨沟)。
		var grav_mult := charge_air_gravity_mult if is_charge else 1.0
		velocity.y += gravity * grav_mult * delta
		coyote_timer = maxf(coyote_timer - delta, 0.0)

	if input_source.is_action_just_pressed("up"):
		jump_buffer_timer = jump_buffer_time
	else:
		jump_buffer_timer = maxf(jump_buffer_timer - delta, 0.0)

	if jump_buffer_timer > 0.0 and (is_on_floor() or coyote_timer > 0.0) and not is_squat:
		# 冲刺中按跳 = 打断冲刺转跳跃,保留当前水平速度作动量(下方 accel/air-brake 平滑接管)。
		if is_charge:
			is_charge = false
			charge_timer = 0.0
		velocity.y = jump_velocity * mult.y
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		jump_cut_applied = false
		squash.impulse(SquashStretch.Impulse.JUMP)

	if not jump_cut_applied and input_source.is_action_just_released("up") and velocity.y < 0.0:
		velocity.y *= jump_cut_factor
		jump_cut_applied = true


func _tick_crouch_and_dash(delta: float, latched: bool, in_water: bool) -> void:
	if latched or in_water:
		return
	if not is_on_floor() and input_source.is_action_just_pressed("down") \
			and not climb.is_over_climb_tile():
		velocity.y = charge_down_velocity
	# 下蹲逐帧推导,不用按下/松开边沿:旧实现把 release 分支套在 is_on_floor() 内,空中松开 S 不执行 ⇒ 落地仍蹲(卡蹲)。
	var want_squat := is_on_floor() and input_source.is_action_pressed("down")
	if want_squat and not is_squat:
		is_charge = false   # 冲刺中按 S → 取消冲刺进蹲
	is_squat = want_squat

	if not is_charge and not is_squat and input_source.is_action_just_pressed("charge"):
		is_charge = true
		charge_timer = charge_duration
		squash.impulse(SquashStretch.Impulse.DASH)
		# 冲刺方向沿用最近移动方向;没在走路(如刚用枪瞄)则保留当前朝向。
		if _last_move_timer > 0.0:
			facing_direction = _last_move_dir


# 水平速度:攀爬中不锁横移(爬/挂/空闲都可左右走,由 climb 只管垂直)。
func _tick_horizontal(delta: float, in_water: bool, horizontal_input: float, mult: Vector2) -> void:
	if in_water:
		return
	if is_charge:
		velocity.x = charge_velocity * facing_direction
		charge_timer -= delta
		if charge_timer <= 0:
			is_charge = false
	else:
		var speed_target := (crouch_walk_speed if is_squat else move_speed) * _speed_mult
		var target_velocity_x = horizontal_input * speed_target * mult.x
		if horizontal_input != 0:
			if is_on_floor():
				velocity.x = MathUtil.approach(velocity.x, target_velocity_x, accel_ground, delta)
			else:
				velocity.x = MathUtil.approach(velocity.x, target_velocity_x, accel_air, delta)
		else:
			_brake_horizontal(delta)


# 移动输入非零时朝向跟随移动;零输入时保留(枪瞄准设置的)当前朝向。
func _tick_facing(delta: float, horizontal_input: float) -> void:
	if not is_charge and horizontal_input != 0:
		facing_direction = 1 if horizontal_input > 0 else -1
		_last_move_dir = facing_direction
		_last_move_timer = PlayerParams.charge_dir_window
	else:
		_last_move_timer = maxf(_last_move_timer - delta, 0.0)


# 期望姿态由输入/接触状态决定;每个姿态对应一个 CollisionPolygon2D(多边形可在编辑器里分别调整),运行时只启用当前姿态对应的那个。
func _tick_pose_and_collision(delta: float, in_water: bool) -> void:
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

	animator.play(POSE_ANIM[state])

	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != state


func _tick_slide_reactions() -> void:
	if is_charge:
		for i in range(get_slide_collision_count()):
			var col := get_slide_collision(i)
			if col != null and absf(col.get_normal().x) > 0.5:
				is_charge = false
				charge_timer = 0.0
				velocity.x = 0.0
				break

	# 弹性瓦片(如树叶)弱反弹;空网格跳过(冒烟测试会清空 current_grid;真实游戏 Level0 总会赋值)。
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


# 倒地(死亡态)不取消物理:重力/制动/击退照常,只是不吃输入、不结算战斗。与正常路径的差别只有三处:不读输入、不跑武器/攀爬/跳跃/冲刺/姿态切换、制动那段共用。
# ★ 重力那段刻意不与正常路径合并:这份不乘 charge_air_gravity_mult、也不递减土狼时间 —— 今天都不可观测(倒地不能跳),但不可观测是要论证的。
func _tick_downed(delta: float) -> void:
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		velocity.y += gravity * delta
	_brake_horizontal(delta)
	combat.apply_knock(delta)
	move_and_slide()
	_wrap_position()


# 无水平输入时的制动 + 吸附(倒地路径与正常路径逐句相同,故收在这里):指数缓动逼近不到 0,接近 0 时直接吸附,避免贴地滑行。
func _brake_horizontal(delta: float) -> void:
	if is_on_floor():
		velocity.x = MathUtil.approach(velocity.x, 0.0, brake_ground, delta)
	else:
		velocity.x = MathUtil.approach(velocity.x, 0.0, brake_air, delta)
	if absf(velocity.x) < PlayerParams.stop_snap:
		velocity.x = 0.0


# 环面回卷:玩家只能在中间副本,离开时取模送回。
func _wrap_position() -> void:
	global_position = MazeGenerator.wrap_to_range(global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)


func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# 回溯中不受任何伤害(位置正被回放器搬运,接触判定可能在瞬移中误触发):单机看 TimeField 的回溯态,联机看 time_rewinding meta。
	if (TimeField.current != null and TimeField.current.is_rewinding()) or has_meta("time_rewinding"):
		return
	# 前后比对 hp:只有真吃到伤害才挤压 —— 无敌帧挡下/已倒地时 combat.take_hit 不改 hp,天然把它们排除,比在 combat 里回调更省事。
	var before := combat.hp
	combat.take_hit(source_pos, damage, ignore_iframes, knockback)
	if combat.hp < before:
		squash.impulse(SquashStretch.Impulse.HURT)

func get_facing() -> int:
	return facing_direction

func set_facing(v: int) -> void:
	# 冲刺期间朝向即冲刺方向,锁定不被枪瞄改写(_auto_aim 每帧 set_facing)。
	if is_charge:
		return
	facing_direction = 1 if v >= 0 else -1

func is_downed() -> bool:
	return combat.is_downed()

# 是否冲刺中(武器判断用):冲刺锁身体朝向,但枪口应保持鼠标瞄准侧不跟随翻转。
func is_charging() -> bool:
	return is_charge

# 本物理步的滑动碰撞里有没有非地形碰撞体(= 远端玩家身体所在的层)。判层不判组名/节点名:判 player_replica 组要在本文件写字面量而与它互相引用成环,判 TEAM_ENEMY_LAYER 又会把 server/ 拖进核心玩家类。
# ★ 地形恒为层 1 ⇒ 与 ~1 相与就是非地形;本地玩家的 mask 里除地形外只有对手幽灵体(3v3 队友在层 2、本地 mask 不含 2 ⇒ 队友不算接触)。
# ★ 写成函数而不是每帧刷新的字段:本文件 move_and_slide() 有 3 个调用点,做字段必然漏刷一处,而漏了不报错。用途:C2 预测只在贴身时放宽容差。
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

# C2 预测的整态捕获/恢复:覆盖决定下一物理帧输出的全部变量(player 本体 + climb/swim/combat + 当前武器)。
# 服务器快照 = capture_state();客户端 rollback = restore_state(权威态) 后重放未确认输入。漏一个变量 → 重放与服务器分歧。字段键名尽量短,压缩协议体积。
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
		# ★ winst = 手持那一条的逐把唯一 id:wslot 只有类型 id,同型号两把恒等,光凭它恢复端无法知道权威手持的是哪一把(会静默落回第 0 把:残弹写错条目/丢弃丢错把/武器框高亮错)。
		# ★ 与 mag/rld 同口径:进 capture/restore,不进 _close_enough 的比对。加法式键:老接收端忽略未知键,不协商。
		"winst": weapons.current_inst(),
	}
	# 背包整表(每条 {type, inst, mag})必须进整态:restore_state 会 equip_type(wslot),若不先重建背包,重放时可能切到客户端背包里没有的类型(equip_type 只 push_error、不再凭空造枪)。只进 capture/restore,不进比对。
	st["inv"] = weapons.snapshot_inventory()
	var w: WeaponBase = weapons._weapon
	if w != null:
		st["fire_cd"] = w.fire_cd_timer
		st["aiming"] = w._aiming
		st["fire_buf"] = w._fire_buffered
		st["aim_f"] = w._aim_facing
		st["aim_cf"] = w._current_aim_facing
		# 弹药/装填必须进整态,否则 rollback 重放不确定:同一串输入在记得残弹与忘了残弹两种初态下会走出不同结果,重放就不是复现而是新历史。只进 capture/restore,不进比对(_reload_t 是连续量,比它会每帧判分歧、每帧回滚)。
		st["mag"] = w.mag_ammo
		st["rld"] = w._reloading
		st["rld_t"] = w._reload_t
	return st

func restore_state(st: Dictionary) -> void:
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
	# 武器(背包/手持/弹药):与软同步共用同一段,见 _apply_weapon_state 的顺序说明。
	_apply_weapon_state(st)
	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != state
	animator.flip_h = facing_direction < 0
	# CharacterBody2D 的 is_on_floor 是上次 move_and_slide 的内部结果、无法直接赋值 ⇒ 恢复位置后做一次向下 0.001px 的微位移 move_and_slide,让它在恢复位置重判接触。
	var saved := velocity
	velocity = Vector2(0.0, 0.001)
	move_and_slide()
	velocity = saved


# 非预测字段的软同步(拾取/丢弃/复活/换局改的就是这些):只补字段、不重放 —— 位置/速度是预测出来的,拿权威覆盖它们才是橡皮筋,而背包/残弹只由服务器裁决(客户端从不预测拾取/丢弃)。
# ★ 由 PredictionRollback 在预测被证实那一支调用(每个本人包一次,下行 30Hz),所以先比指纹再动手:restore_inventory 会 emit inventory_changed → ui/hud.gd 整体重建武器框,无脑调等于每帧新建/销毁一堆 Control。
func sync_soft_state(st: Dictionary) -> void:
	# ★ 指纹必须连 winst 一起比:同型号两把之间换手时 wslot 与背包结构都不变,只看那两样会把整条软同步跳过。缺键时默认取当前值 ⇒ 老载荷(无 winst)行为与改动前逐字相同。
	if int(st.get("wslot", weapons._current_type)) == weapons._current_type \
			and int(st.get("winst", weapons.current_inst())) == weapons.current_inst() \
			and _inv_structure_equal(st.get("inv", [])):
		return
	_apply_weapon_state(st)


# 只比结构(type/inst 的有序对):mag 是连续量、本地每帧都在变,比它等于每帧都不一致,守卫当场失效。
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


# 武器/弹药的权威字段回灌(restore_state 与 sync_soft_state 共用)。
# ★ 顺序不可反:先读 wslot(此时 _current_type 还有值,可作默认),再 restore_inventory(它会把 _current_type 清 0),最后 equip_type。反过来会丢默认值,或在旧背包上切枪。
func _apply_weapon_state(st: Dictionary) -> void:
	var wslot := int(st.get("wslot", weapons._current_type))
	# ★ 把手持的是哪一把交给 restore_inventory 按 inst 解析(同型号两把只有它能区分);下面那句 equip_type 只作兜底(老载荷无 winst、或权威那把不在表里时)。
	var by_inst := weapons.restore_inventory(st.get("inv", []), int(st.get("winst", 0)))
	if wslot > 0 and wslot != weapons._current_type:
		# 手上实例的类型与权威不符(_current_type 由 _equip_index/_unequip 维护)→ 必须重建。这是已有行为,别绕开;但重建的落点要分两种,by_inst 就是判别器:
		# ★ 按 winst 解析成功 → 走 equip_index(下标):不能用 equip_type(wslot),后者按类型找第一个,同型号两把时会把刚解析对的下标冲回第 0 把。
		# ★ 按类型兜底(老载荷无 winst、或权威那把不在表里)→ 保原样走 equip_type(wslot):此时手里那个下标只代表旧类型那把,拿它重建会把权威的 wslot 顶掉。
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
		# 弹药/装填随权威整态回灌(理由见 capture_state)。
		# ★ 必须走 WeaponComponent.apply_mag():本帧刚重建过实例时 _weapon 还没入树,直接写 mag_ammo 会被 _ready 用条目旧值盖掉;apply_mag 按 is_inside_tree() 分流,未入树写 pending_mag 由 _ready 消费(同步调用,不排 deferred)。
		WeaponComponent.apply_mag(w, int(st.get("mag", w.mag_ammo)))
		w._reloading = bool(st.get("rld", w._reloading))
		w._reload_t = float(st.get("rld_t", w._reload_t))

# 攀爬跳离梯顶时清跳跃缓冲/土狼/截断标记:防止残留输入造成二次起跳(由 climb 组件调用)。
func cancel_jump_state() -> void:
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	jump_cut_applied = false

# combat 命中落地时调用:冲刺被打断,否则下一帧 is_charge 分支会用冲刺速度覆盖击退。
func cancel_charge() -> void:
	is_charge = false
	charge_timer = 0.0

func _update_waterproof(delta: float) -> void:
	var submerged := false
	if swim.in_water:
		var surface_y := Water.surface_y_at(global_position)
		# 呼吸按大部分没入扣:参考线比中心低 water_breath_line_offset(≈胸口下沿),水面到这条线就扣,要浮到水面低于它才回气(头能露出仍扣)。
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


# 单人倒地按 R 重启(Level0.restart_single 调):满血满氧回出生点,清倒地/冲刺/跳跃残留。
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
	# ★ 这里不再动背包:本函数被单机与联机共用,而两种模式的武器规则不同 —— 单机的重开由 Level0.restart_single 统一重置(清空 + 重新散落),联机的复活另有规则(除随机一把外全丢)。
	weapons.reset_mag_state()   # 只把当前武器的残弹同步进背包条目(不再清任何表)
	set_controls_locked(false)


var _reload_ring: ReloadRing = null   # 换弹圆环(角色后侧)
var _drop_hold_t := 0.0     # Q 已按住多久
var _drop_latched := false  # 本次长按是否已触发过(防按住不放连续丢)


# F 捡起 / Q 长按丢弃都走 input_source 读口,不在 _unhandled_input 里读原始 InputEvent —— 权威服务器没有输入事件、只有注入包,读原始事件的话联机端永远收不到。
func _poll_pickup_drop(delta: float) -> void:
	# ★ Q 长按计时两种模式都要跑:联机时它也是长按丢弃这条规则的唯一执行点(服务器只收得到一次满了的边沿,它自己没有计时器)。
	# 早先写成联机早退 ⇒ 长按形同虚设、碰一下 Q 就丢枪。分支只差满了之后干什么:单机就地丢,联机打一个一次性边沿由 pack_record 上行给服务器裁决(不做客户端预测)。
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

	# 拾取 F 本来就是按下边沿:单机就地执行,联机只上行(服务器侧走 MatchGround._handle_ground_actions 裁决;本函数在服务器上靠 current_scene is Level0 早退兜底)。
	if input_source.is_pickup_pressed() and not Level0.pvp_mode:
		_try_pickup()


# 长按 Q 的进度 0..1(只读;HUD 的丢弃进度条用):没有反馈的长按是不可用的 —— 玩家会以为按键没生效。
func drop_hold_progress() -> float:
	if _drop_latched:
		return 1.0
	return clampf(_drop_hold_t / PlayerParams.weapon_drop_hold_time, 0.0, 1.0)


# 本玩家所属的 Level0(从自己往上走)。★ 不用 get_tree().current_scene:那是当前场景根这一全局状态,与我在哪个世界并不等价
# (PvP 里 current_scene 是 PvpGame/大乱斗场景,Level0 只是它的子节点;服务器 worker 里干脆没有 Level0)。往上走是本地的、精确的。
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
		return   # 空手没什么可丢
	var e: Dictionary = weapons.drop_current()
	if e.is_empty():
		return
	var lvl := host_level()
	if lvl != null:
		lvl.spawn_pickup(int(e["type"]), int(e["mag"]),
			global_position + PlayerParams.weapon_drop_offset * Vector2(float(facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * facing_direction, -PlayerParams.weapon_drop_up),
			0, true)   # self_drop=true:冷却期内不参与自己的拾取(防丢完原地按 F 捡回)


func _unhandled_input(event: InputEvent) -> void:
	# 滚轮切枪(设置开启时):循环跳到下一个启用槽位;倒地时不切。
	# PvP:滚轮不在输入包协议里,只本地切会被快照防脱同步切回旧槽位 ⇒ 走 request_net_cycle(本地即时切 + 目标槽位打包进输入包由服务器权威同步)。
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
		# PvP 倒地不重载场景(服务器权威管复活/回合);单人照旧。
		if not Level0.pvp_mode and event.is_action_pressed("R"):
			# 单人重启:原地复位,不重建世界(重建会偶发原生段错误 → 重启后蓝屏/地图未加载);只在当前场景确为 Level0 时生效。
			var lvl := get_tree().current_scene
			if lvl is Level0:
				# 推迟一帧:restart_single 会同步重建碰撞层(销毁全量 WallCollision/可破坏分块),而此刻仍在 _unhandled_input 的派发栈内 —— 与 safe_change_scene 要 await 一帧同理(立刻摘树会触发 CanvasItem EXIT_TREE)。
				(lvl as Level0).restart_single.call_deferred()
		return
	# R 换弹已从这里迁走(改走 _physics_process 的 input_source 轮询):读原始 InputEvent 的话权威服务器永远收不到。倒地时 R 仍是重载/复活。


# 换弹圆环显示在角色后侧(背对朝向那一侧),环心是带一位小数的倒计时;挂在玩家本体而不是 HUD:圆环要跟人走、要压在角色附近的世界层里,一个接入点覆盖所有模式。
func _update_reload_ring() -> void:
	if _reload_ring == null or not is_instance_valid(_reload_ring):
		return
	var w := weapons.current_weapon()
	var prog := w.reload_progress() if w != null else -1.0
	_reload_ring.visible = prog >= 0.0
	if prog < 0.0:
		return
	var sc := maxf(absf(scale.x), 0.001)
	# 世界单位偏移 ÷ 根缩放 = 本节点的局部偏移(环自己又反向缩放过,故视觉仍是世界单位)
	_reload_ring.position = Vector2(-RELOAD_RING_OFFSET.x * float(facing_direction),
			RELOAD_RING_OFFSET.y) / sc
	_reload_ring.set_progress(prog, w.reload_time * (1.0 - prog))


const RELOAD_RING_OFFSET := Vector2(58.0, -44.0)   # 世界单位:x 朝"后侧"、y 朝上(2026-09-16 上移)

## 回溯还原(WorldRewind 调用):位置/速度/HP/朝向/倒地态回到快照帧。
func rewind_restore(d: Dictionary) -> void:
	global_position = d["p"]
	if d["v"] != null:
		velocity = d["v"]
	combat.knock_velocity = Vector2.ZERO
	# ★ 必须发 hp_changed:HUD 血条只听信号(不是每帧轮询),直接改 combat.hp 的话血条会停在旧值 —— 玩家看到的血量没有回溯就是这个。
	var hp_before := combat.hp
	combat.hp = clampi(int(d["hp"]), 0, combat.max_hp)
	if combat.hp != hp_before:
		combat.hp_changed.emit(combat.hp, combat.max_hp)
	facing_direction = int(d["facing"])
	var downed_now := is_downed()
	# 武器弹量回溯:背包各格残弹 + 手持那件实弹;当前武器不同则切回。
	# ★ 类型化访问取代早先的字符串反射(get/call/set 带字符串):反射改名只在运行期暴露 —— get 拼错静默返回 null、整段被 if 跳过,set 拼错静默不写,call 拼错会中止整个 rewind_restore。
	# ★ 买到的不是编译期就红(Godot 对 class_name 脚本类型上的未知成员只当警告级不安全访问),而是错当场、点名成员、带文件行号地炸,而不是静默把状态写歪。零守卫:rewind_weapon_probe 已删(2026-10-09)。
	# ★ 语句序:切枪必须排在条目写回之前 —— _equip_index 会把走掉那把的出膛实弹写回条目,排在写回之后就会冲掉刚恢复的快照值。
	# ★ 语义口径(别改成以条目为准):回溯 = 逐字段回到快照记录的值,wlive(手持实弹)与 wmags(各槽条目)在快照时就允许不同(条目只在切枪/丢弃时同步,开火只扣 mag_ammo)⇒ 任何从条目推导当前枪、或从当前枪写回条目的动作,都不许在恢复之后把已恢复的值改掉。
	# ★ wlive < 0(快照没记手持实弹)且确实切了枪时,新实例取快照条目值 held[widx](旧语句序里 _equip_index 就是从恢复后的条目取的)。
	var wc: WeaponComponent = weapons
	if wc != null and d.has("wmags"):
		var inv: WeaponInventory = wc.inventory
		# ★ 切枪排在下面条目写回之前:排在之后,_equip_index 写回的实弹会冲掉刚恢复的快照值。
		var want_idx := int(d.get("widx", -1))
		var switched := want_idx >= 0 and want_idx != wc._current_index
		if switched:
			wc.equip_index(want_idx)
		if inv != null:
			var held: Array = inv.held
			var mags: Array = d["wmags"]
			for i in mini(held.size(), mags.size()):
				held[i]["mag"] = int(mags[i])
		var live2: WeaponBase = wc.current_weapon()
		if live2 != null and is_instance_valid(live2):
			var want := int(d.get("wlive", -1))
			if want < 0 and switched and inv != null and wc._current_index >= 0 \
					and wc._current_index < inv.held.size():
				# 见上:快照没记手持实弹而这次换了枪 ⇒ 用快照条目值,不是恢复前的旧值。
				want = int(inv.held[wc._current_index]["mag"])
				# ★ 两个 -1 语义不同:wlive 的 -1 = 哨兵(快照没记手持实弹);条目 mag 的 MAG_FULL(-1) = 满弹(weapon_inventory.gd)。
				# 不折算的话 want 会是 -1、被下面的 want >= 0 挡住 ⇒ apply_mag 不调用 ⇒ 新枪停在 _equip_index 从恢复前条目取的有限旧值。折成 mag_size 与不设 pending_mag、_ready 用 mag_size 逐位同效。
				if want == WeaponInventory.MAG_FULL:
					want = live2.mag_size
			if want >= 0:
				# 见上:走 apply_mag —— 未入树窗口里写 mag_ammo 会被 _ready 覆盖。
				# ★ 它顺带钳位到 [0, mag_size];范围内逐位等价(正常回溯的 wlive 取自同一把枪,而 _ready 自己就钳过);越界那一档无任何断言,见 docs/eng/registered-debt.md §六.13。
				WeaponComponent.apply_mag(live2, want)
	if bool(d["downed"]) and not downed_now:
		combat.set_downed_by_rewind(true)
	elif not bool(d["downed"]) and downed_now:
		combat.revive()
