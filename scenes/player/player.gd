class_name Player
extends CharacterBody2D

# ★ 本文件有 class_name(2026-11-02 才加):承重的回滚 / 命中 / 快照路径原先只能按名反射
#   (has_method / call / get),拼错不报错、只在运行期静默失效。代价 = 新环境必须 `--import`
#   一次重建全局类缓存(否则别的脚本报 Could not find type Player)—— 本地跑批与 CI 都已显式 import。
const HitShape := preload("res://core/sim/hit_shape.gd")   # 受击判定几何唯一入口
const DashRule := preload("res://core/sim/dash_rule.gd")   # 冲刺倍率/准入判据唯一入口(两端同一份算式)
const PlayerNetState := preload("res://scenes/player/player_net_state.gd")   # 整态编解码(回滚/权威同步)
# 帧数据:网格 + 每帧 [列, 行] 写在 JSON 里,由网格推导 Rect2(不再手写 .tres)。
# ★ 本体与 PvP 副本都走这一份,且 SpriteFramesIO 有缓存 ⇒ 仍是"只有一处帧数据"。
const FRAMES_JSON := "res://assets/textures/player.frames.json"

@export var animator : AnimatedSprite2D

var gravity: float = GameParameters.gravity0
# 自动跳跃的落地余量(px):按v=-sqrt(2gh)算的峰值高度**等于**台阶高度,60Hz 离散化下可能差一帧够不到,
# 加 2px(远小于一个 16px 子格,肉眼不可辨)保证真的能站上去。
const AUTO_JUMP_CLEARANCE := 2.0
# ★ 2026-11-01(R1 删):这里原有一个 `AUTO_JUMP_ASSIST_S = 0.25s` 的"自动跳后强制满速"窗口。
const AUTO_LEDGE_NUDGE_PX := 16.0
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
const WaterSample := preload("res://core/sim/water_sample.gd")   # 水判定数据类型;本文件不自己查水面
var waterproof: int = PlayerParams.player_waterproof_max
var max_waterproof: int = PlayerParams.player_waterproof_max
var _waterproof_timer: float = 0.0
var _was_submerged: bool = false
var _waterproof_drown_timer: float = 0.0

enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }
# 姿态动画名 / 碰撞箱节点名 / 冲刺残影常量 = **与远端副本共享的单一来源**。
# 键就是本文件的 Pose 枚举值;顺序一致性由 _ready 里那句 push_error 兜住(改一处忘另一处不会静默)。
const PlayerVisual := preload("res://scenes/player/player_visual.gd")

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

	# 帧数据来自 JSON(网格推导 Rect2)。★ 必须在任何 play() 之前:换掉 sprite_frames 会把当前
	# 动画复位,后设的 play 才有效。构建失败返回 null 时保持场景原样,不静默半成品。
	# ★ 场景里不能再写 animation/autoplay:载入瞬间还没有 sprite_frames,写动画名会报
	#   "There is no animation with name ...",所以入门动画由这里 play。
	var frames := SpriteFramesIO.load_json(FRAMES_JSON)
	if frames != null:
		animator.sprite_frames = frames
		animator.play(&"idle")
	# 形体光:打光辅助图(RG=部位局部坐标 / B=贴体 AO);缺 player_shade.png 时 FormLight 自动回退 parts。
	# ★ 与武器/敌人共用同一份材质,uniforms 由 PostProcess 每帧统一推;独特材质 = 每帧写 flip_x
	FormLight.attach(animator, "guide", 1.10, 1.0, {
		"steps": 5.0, "dither": 0.25, "bulge": 2.0, "edge_lo": -0.20, "edge_hi": 0.80,
		"part_flat": 0.45, "ao_strength": 0.35,
	}, true)

	combat.hp_changed.connect(func(cur: int, mx: int) -> void: hp_changed.emit(cur, mx))
	combat.went_down.connect(func() -> void: weapons.cancel_aim())
	hp_changed.emit(combat.hp, combat.max_hp)

	for pose in Pose.values():
		_coll_by_pose[pose] = get_node(PlayerVisual.COLLISION_NODE[pose])
	# 共享表的键是裸 int:枚举顺序改了这里会立刻喊,而不是静默放错动画 / 用错碰撞箱。
	if int(Pose.SQUAT) != PlayerVisual.POSE_SQUAT:
		push_error("PlayerVisual.POSE_* 与 player.gd 的 Pose 枚举顺序不一致")

	# 单机开局空手:武器全部散落在地图上,由 Level0._ready 铺;联机由 MatchHost 调 set_initial_inventory 发随机一把。
	weapons.set_initial_inventory([])
	# 换弹圆环在**第一次需要显示时**才建:它要挂进 PostProcess 的 UI 通道(不吃光照),
	# 而 PostProcess 可能比玩家晚 _ready ⇒ 延迟到 _update_reload_ring 里惰性创建。
	add_child.call_deferred(WaterFx.new())
	# 补间形变:挂在玩家自己身上(与 _reload_ring 同款的一个接入点覆盖单机/PvP/大乱斗);animator 是 @export 引用,场景实例化时就已就位。
	squash = SquashStretch.new()
	# ★ 先 add_child() 再 setup(),与另两个宿主(敌鸟/对手副本)统一。两种序今天等价 —— SquashStretch 没有 _ready,入树不触发按参数建出来的东西。
	# ★ 本仓另有一条相反规矩:WeaponPickup.configure() 必须先于 add_child()。将来给本组件加 _ready 时,这三处要一起倒过来。
	add_child(squash)
	squash.setup(animator, SquashStretch.Profile.PLAYER)

	# 贴台沿/台阶时减少"卡角":多给一点抓地余量 + 允许更多次滑动解算。
	# 依据(查到的通用修法):CharacterBody2D 矩形箱在 tile 接缝会同时接触"地面 + 竖面"两面,
	# floor_snap_length 太小会让它离地一帧、max_slides=4 有时吃不完复杂接触 —— 4px 抓地与 6 次滑动是常用起点。
	floor_snap_length = 4.0
	max_slides = 6


var _speed_mult := 1.0  # 时间场速度域倍率(加速;跨函数用,故设成员)

# Beta 时间玩法(PvP):服务器权威与本端预测各写一次的加速倍率(1 = 常速)。单机不走这里(走 TimeField.player_speed_mult)。
# ★ 本字段也是唯一分发源:由 _push_haste_mult() 推给攀爬/武器/游泳三个消费点;match_host 的写与快照的读都打在本字段上。
var pvp_haste_mult := 1.0
var _ghost_t := 0.0     # 残影生成计时(加速时)
var _ghost_flip := false  # 红/蓝交替
# 冲刺残影:渲染帧里发射(不在物理 tick —— 回滚重放不会重复生成)。
var _dash_ghost_t := 0.0
# 冲刺残影的 3 个常量与远端副本共用一份,见 player_visual.gd。
# 下冲残影:下冲是一次性速度赋值、没有冲刺那样的持续态,故自带一段发射窗口(约 3 张)。纯表现,不进整态。
const DOWN_DASH_GHOST_TIME := 0.06
var _down_dash_ghost_t := 0.0


# 本帧倍率推给三个消费点:攀爬/武器的宿主引用是一次给入的、而倍率每帧在变 ⇒ 只能每帧推;游泳走 swim.update 的调用参数。
# ★ 调用点两处(都在 _physics_process 正常态路径、都在 climb.update 之前):weapons.tick 之前(轮询开火吃本帧倍率)、切枪之后。消费点只读注入值,拿不到就是 1×(静默降级)。
func _push_haste_mult(tm: float) -> void:
	climb.haste_mult = tm
	var cur_w := weapons.current_weapon()
	if cur_w != null:
		cur_w.haste_mult = tm


func _process(delta: float) -> void:
	_tick_eye_glow()
	_sync_form_flip()   # 必须放在下面那条早退之前,否则平时不刷新
	# 冲刺 / 下冲残影(纯表现):只在渲染帧发射 ⇒ C2 回滚重放不会把同一段冲刺再生成一遍;
	# 服务器/无相机路径直接跳过(看不见的节点不花)。强度/间隔见 DASH_GHOST_* 常量。
	if _down_dash_ghost_t > 0.0:
		_down_dash_ghost_t = maxf(_down_dash_ghost_t - delta, 0.0)
	if not (is_charge or _down_dash_ghost_t > 0.0) or animator == null or not is_inside_tree():
		_dash_ghost_t = 0.0
		return
	if get_viewport().get_camera_2d() == null:
		return
	_dash_ghost_t -= delta
	if _dash_ghost_t <= 0.0:
		_dash_ghost_t = PlayerVisual.DASH_GHOST_INTERVAL
		AfterImage.spawn(get_parent(), animator, PlayerVisual.DASH_GHOST_TINT, PlayerVisual.DASH_GHOST_DURATION, -1)


func _physics_process(delta: float) -> void:
	# 加速走速度域(move_and_slide 用引擎自己的 delta):tick 类与水平速度目标 ×tm,重力/跳跃保持原样 —— 缩放 delta 只会让坠落变快、跳跃变低、移速不变。
	var tm := TimeField.player_speed_mult() if TimeField.current != null else pvp_haste_mult
	_speed_mult = tm
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	# squash 必须在最首行(倒地早退之前):否则倒地后 animator.scale 会卡在最后一个挤压值上。
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
	_update_waterproof(delta, swim.sample)
	var latched := false
	if not in_water:
		climb.update(mult, delta, is_squat, input_source)
		latched = climb.is_latched()
	else:
		is_charge = false
		is_squat = false

	_tick_vertical(delta, latched, in_water, mult)
	_tick_crouch_and_dash(delta, latched, in_water, mult)
	_tick_horizontal(delta, in_water, horizontal_input, mult)
	_tick_facing(delta, horizontal_input)
	_tick_pose_and_collision(delta, in_water)
	if not latched and not in_water:
		_try_step_or_jump(delta, mult, float(horizontal_input))

	# 爆炸击退位移单独走 move_and_collide(带碰撞),不污染 velocity —— 地面把向下击退吃掉后再减回去会把玩家弹起。
	combat.apply_knock(delta)

	# ★ 必须在 move_and_slide() 之前取值:落地那一帧它在调用后就被清零。且必须滤掉不是摔下来的下坠速度(squash 的契约 = 地面真正吸收掉的坠落速度)。
	# ★ 水中/攀爬中置 0 是落实设计取舍(游泳不该有自由落体那种弹感),不是修 bug;梯子下行那条满幅假挤压仍是残留。实测读数与推导见 docs/eng/player.md。
	_pre_move_vy = 0.0 if (in_water or latched) else velocity.y
	move_and_slide()
	if _step_up_snap:
		# 迈台阶后脚底只离台面 1px:吸一下地,避免"腾空一帧"(姿态切 FLY/落地挤压)造成的抖动
		_step_up_snap = false
		apply_floor_snap()
	_try_ledge_nudge(in_water, latched, horizontal_input)   # 卡脚修复,见函数注释

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


# ★★ 迈台阶 / 自动跳(用户 2026-11-01 三轮反馈的收敛版)——
var _step_up_snap := false   # 本帧抬过台阶 ⇒ move_and_slide 之后 apply_floor_snap() 吸地

func _try_step_or_jump(delta: float, mult: Vector2, horizontal_input: float) -> void:
	if not is_on_floor() or is_squat or is_charge or jump_buffer_timer > 0.0:
		return
	var dx := velocity.x * delta
	if absf(dx) < 0.5:
		return
	var dir := 1 if dx > 0.0 else -1
	if not test_move(global_transform, Vector2(dx, 0.0)):
		return   # 这一帧本来就过得去
	var feet := _front_feet_subcell(dir)
	var h := StepJump.low_step_height(feet, dir, Callable(self, "_sub_solid_at"))
	if h <= 0 or not _step_up_headroom_clear(feet, dir, h):
		return
	var sub_px := float(GameParameters.TILE_SIZE) / float(StepJump.SUB_PER_CELL)
	# 抬起来之后本帧位移必须真的进得去(物理判据,不只信网格):否则那面"台阶"其实进不去,不抬。
	var lift := float(h) * sub_px + 1.0
	if test_move(global_transform.translated(Vector2(0.0, -lift)), Vector2(dx, 0.0)):
		return
	var full_x := horizontal_input * move_speed * _speed_mult * mult.x
	if StepJump.is_walk_up_step(h):
		# 矮台阶(≤32px):抬到台阶顶,同一帧的 move_and_slide 直接迈上去 —— 不丢那一帧。
		global_position.y -= lift
		velocity.y = 0.0
		velocity.x = full_x
		_step_up_snap = true
		return
	# 3~4 子格(48/64px):按台阶高度起跳(跳高 = 台阶高度,不是满力跳)。
	velocity.y = StepJump.jump_velocity_for_height(float(h) * sub_px + AUTO_JUMP_CLEARANCE, gravity)
	velocity.x = full_x
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	jump_cut_applied = true
	squash.impulse(SquashStretch.Impulse.JUMP)


# 自动跳跃的两个数据口:脚底前方落在哪个 16px 子格 / 该子格有没有碰撞。
# ★ 用 hurt_rect()(= 当前姿态的逻辑体)而不是碰撞箱:与"受击面"同一份几何,蹲下时不会用站立身高去探。
func _front_feet_subcell(dir: int) -> Vector2i:
	var r := hurt_rect()
	var sub := float(GameParameters.TILE_SIZE) / float(StepJump.SUB_PER_CELL)
	var x := r.position.x + r.size.x * 0.5 + float(dir) * (r.size.x * 0.5 + 1.0)
	var y := r.position.y + r.size.y - 2.0
	return Vector2i(int(floor(x / sub)), int(floor(y / sub)))


# 子格是否挡路:**与 CollisionBuilder.build_sub 同一份判据**(否则会出现"看起来是墙但没碰撞/已被打穿"的误判):
#   type=wall 才有碰撞;可破坏砖还要 `sub_alive`(被摧毁的子格纹理不变、碰撞已删 —— 只判纹理会让打穿的洞口被当成台阶)。
# ★ 世界是环面的 ⇒ 子格坐标先环面回绕,否则接缝旁的台阶永远判成"没挡路"。
func _sub_solid_at(cell: Vector2i) -> bool:
	var sub := MazeGenerator.current_subgrid
	if sub.is_empty():
		return false
	var sr := sub.size()
	var sc := (sub[0] as Array).size()
	var wrapped := Vector2i(posmod(cell.x, sc), posmod(cell.y, sr))
	var tex := int((sub[wrapped.y] as Array)[wrapped.x])
	if tex == 0:
		return false
	if TileDefs.type_id_of(tex) != TileDefs.TYPE_WALL:
		return false
	var destr: bool = TileDefs.bullet_destroyable(tex) or TileDefs.explosion_destroyable(tex)
	if destr and TileDefs.sub_cols != 0 and not TileDefs.sub_alive(wrapped):
		return false
	return true


# 迈台阶前的净空检查:台阶顶面往上一格(4 个 16px 子格)必须是空的,否则抬上去就是把头塞进天花板。
# ★ 台阶的实体子格 = 从脚底那行往上连续 step_sub 行,顶面 = (feet_sub.y - step_sub + 1) 行的上沿
#   ⇒ 顶面**上方**第一行 = feet_sub.y - step_sub(顶面那行自己是实体,不能算进净空 —— 旧写法把顶面行也算进去,恒 false)。
func _step_up_headroom_clear(feet_sub: Vector2i, dir: int, step_sub: int) -> bool:
	var top_row := feet_sub.y - step_sub   # 台阶顶面上方第一行
	for k in range(0, StepJump.SUB_PER_CELL):
		if _sub_solid_at(Vector2i(feet_sub.x + dir, top_row - k)):
			return false
	return true


# 卡脚修复:跳跃/下落贴着台沿时,脚底会以 ≤1 个子格的深度卡在台沿竖直面或顶面
func _try_ledge_nudge(in_water: bool, latched: bool, horizontal_input: float) -> void:
	if in_water or latched or is_on_floor() or not is_on_wall() or absf(horizontal_input) < 0.01:
		return
	var sub := MazeGenerator.current_subgrid
	if sub.is_empty():
		return
	var dir := 1 if horizontal_input > 0.0 else -1
	var sub_px := float(GameParameters.TILE_SIZE) / float(StepJump.SUB_PER_CELL)
	var r := hurt_rect()
	var feet_y := r.position.y + r.size.y
	var x_px := r.position.x + r.size.x * 0.5 + float(dir) * (r.size.x * 0.5 + 1.0)
	var col := int(floor(x_px / sub_px))
	var feet_sub := int(floor(feet_y / sub_px))
	# 只看"脚所在子格"与"再上一格":台沿顶面必须在这 2 个子格内,否则是撞真墙/差得太多,不抬。
	for k in range(0, 2):
		var row := feet_sub - k
		if not _sub_solid_at(Vector2i(col, row)):
			continue
		var dy := feet_y - float(row) * sub_px
		if dy <= 0.0 or dy > AUTO_LEDGE_NUDGE_PX:
			continue   # 这一行不在范围内(可能脚正好压在子格边界上),再看下一行
		# 台沿上方要有一格净空(否则是把人往墙里塞)
		if _sub_solid_at(Vector2i(col, row - 1)) or _sub_solid_at(Vector2i(col, row - 2)):
			return
		global_position.y -= dy + 1.0
		velocity.y = minf(velocity.y, 0.0)
		return


func _tick_crouch_and_dash(delta: float, latched: bool, in_water: bool, mult: Vector2) -> void:
	if latched or in_water:
		return
	# 下冲:空中按 S 给一次向下的速度脉冲。已经比他掉得还快时不给(= 不许用它刹车)。
	if not is_on_floor() and input_source.is_action_just_pressed("down") \
			and not climb.is_over_climb_tile() \
			and DashRule.down_dash_allowed(velocity.y, charge_down_velocity):
		velocity.y = charge_down_velocity
		_down_dash_ghost_t = DOWN_DASH_GHOST_TIME
	# 下蹲逐帧推导,不用按下/松开边沿:旧实现把 release 分支套在 is_on_floor() 内,空中松开 S 不执行 ⇒ 落地仍蹲(卡蹲)。
	var want_squat := is_on_floor() and input_source.is_action_pressed("down")
	if want_squat and not is_squat:
		is_charge = false   # 冲刺中按 S → 取消冲刺进蹲
	is_squat = want_squat

	# 冲刺 = 双击左/右走(没有独立键,边沿由 LocalInputSource 合成);已比冲刺还快时不触发。
	if not is_charge and not is_squat and input_source.is_action_just_pressed("charge"):
		if DashRule.dash_allowed(velocity.x, DashRule.dash_speed(charge_velocity, _speed_mult, mult.x)):
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
		# 速度 ×tm、计时 ÷tm(判据见 DashRule)⇒ 时间加速只让冲刺更快、不改变冲刺距离;武器减速只缩短距离。
		velocity.x = DashRule.dash_speed(charge_velocity, _speed_mult, mult.x) * facing_direction
		charge_timer -= delta * _speed_mult
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
	_sync_form_flip()

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

	animator.play(PlayerVisual.ANIM[state])

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


func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0,
		feedback_only: bool = false, cause: String = "") -> void:
	# 回溯中不受任何伤害(位置正被回放器搬运,接触判定可能在瞬移中误触发):单机看 TimeField 的回溯态,联机看 time_rewinding meta。
	if (TimeField.current != null and TimeField.current.is_rewinding()) or has_meta("time_rewinding"):
		return
	# feedback_only:只播反馈 + 挤压,不扣血/不击退/不 emit(供 C2 事件兜底;理由见 combat_component.take_hit)。
	if feedback_only:
		combat.take_hit(source_pos, damage, ignore_iframes, knockback, true, cause)
		squash.impulse(SquashStretch.Impulse.HURT)
		return
	# 前后比对 hp:只有真吃到伤害才挤压 —— 无敌帧挡下/已倒地时 combat.take_hit 不改 hp,天然把它们排除,比在 combat 里回调更省事。
	var before := combat.hp
	combat.take_hit(source_pos, damage, ignore_iframes, knockback, false, cause)
	if combat.hp < before:
		squash.impulse(SquashStretch.Impulse.HURT)

## 受击面(= 逻辑 hurtbox):当前姿态碰撞箱的世界 AABB,所有伤害来源经 core/sim/hit_shape.gd 查它。
## ★ 物理碰撞箱只负责移动;别再拿碰撞层/碰撞体本身当命中判据(那是旧口径,PvP 曾用 40px 圆)。
func hurt_rect() -> Rect2:
	return HitShape.hurt_rect_of(self)

## 能否被打中:倒地 = 本轮不再受击(旧实现靠 take_hit 早退,子弹仍会被吞掉)。
func is_hurtable() -> bool:
	return not is_downed()

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
		# ★ 2026-11-01(R3):不能走 revive() —— 它会把 hp 顶成 max_hp,冲掉上面刚采纳的**权威** hp。
		combat.restore_alive_state()

# 根本体自己拥有的整态字段(位置/移动/姿态/水下计时)。组件字段由各自的 capture_state() 提供,
# 装配在 scenes/player/player_net_state.gd;键名 = core/net/net_codec.gd 的 C2_SCHEMA。
# ★ 自动跳的"满速横移"窗口 **不进整态/不上线**:它是本地表现量,只影响自己后半秒的横移补速,
#   且服务器从不 restore(只有客户端回滚重放会用到);进了 c2 就要动线格式(protocol 变更)与快照体积,
#   收益不抵风险。已知边界:回滚重放时该窗口可能少/多几帧 ⇒ 偏差 <= 0.25s 的横移补速,自愈。
func capture_self_state() -> Dictionary:
	return {
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
	}


# C2 预测的整态捕获/恢复:覆盖决定下一物理帧输出的全部变量(本体 + climb/swim/combat + 当前武器)。
# 服务器快照 = capture_state();客户端 rollback = restore_state(权威态) 后重放未确认输入。漏一个变量 → 重放与服务器分歧。
func capture_state() -> Dictionary:
	return PlayerNetState.capture(self)

# 根本体字段的回灌;碰撞箱/朝向贴图/贴地重判不属于可序列化状态,留在 _after_state_restore。
func restore_self_state(st: Dictionary) -> void:
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
	var wp_v := int(st.get("wp", waterproof))
	if wp_v != waterproof:
		waterproof = clampi(wp_v, 0, max_waterproof)
		waterproof_changed.emit(waterproof, max_waterproof)
	_waterproof_timer = float(st.get("wp_t", _waterproof_timer))
	_was_submerged = bool(st.get("wp_s", _was_submerged))
	_waterproof_drown_timer = float(st.get("wp_d", _waterproof_drown_timer))


func restore_state(st: Dictionary) -> void:
	PlayerNetState.restore(self, st)
	_after_state_restore()


# 不可序列化的收尾:按姿态启用碰撞箱、朝向贴图、以及恢复位置后的一次贴地重判。
func _after_state_restore() -> void:
	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != state
	animator.flip_h = facing_direction < 0
	_sync_form_flip()
	# CharacterBody2D 的 is_on_floor 是上次 move_and_slide 的内部结果、无法直接赋值 ⇒ 恢复位置后做一次向下 0.001px 的微位移 move_and_slide,让它在恢复位置重判接触。
	var saved := velocity
	velocity = Vector2(0.0, 0.001)
	move_and_slide()
	velocity = saved


# 非预测字段的软同步(拾取/丢弃/复活/换局改的就是这些):只补字段、不重放 —— 位置/速度是预测出来的,
# 拿权威覆盖它们才是橡皮筋,而背包/残弹只由服务器裁决(客户端从不预测拾取/丢弃)。
# ★ 由 PredictionRollback 在预测被证实那一支调用(每个本人包一次),指纹与回灌都在 WeaponComponent 里。
func sync_soft_state(st: Dictionary) -> void:
	PlayerNetState.sync_soft(self, st)

# 攀爬跳离梯顶时清跳跃缓冲/土狼/截断标记:防止残留输入造成二次起跳(由 climb 组件调用)。
func cancel_jump_state() -> void:
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	jump_cut_applied = false

# combat 命中落地时调用:冲刺被打断,否则下一帧 is_charge 分支会用冲刺速度覆盖击退。
func cancel_charge() -> void:
	is_charge = false
	charge_timer = 0.0

# 呼吸口径:头低于水面线(head_under)才扣氧 —— 采样点与水面线都由 Water.sample_body 定,玩家与敌人同一条线。
func _update_waterproof(delta: float, water: WaterSample) -> void:
	var submerged := water != null and water.head_under
	if submerged != _was_submerged:
		_was_submerged = submerged
		_waterproof_timer = 0.0  # 状态切换重置:自切换起累计满一个间隔才结算第一下
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
			# ★ cause="water":这是**客户端已本地预测**的伤害(两端跑同一份 _tick_underwater)。服务器必须据此不广播 hit_event,
			#   否则客户端会二次应用(多扣一次血 → 下个 ack 再回滚)。服务端跳过见 match_combat._on_player_hit。
			take_hit(global_position, PlayerParams.player_waterproof_damage, true, -1.0, false, "water")

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


var _reload_ring: ReloadRing = null   # 换弹圆环(角色后侧);挂在 UI 通道里
var _ring_in_ui: bool = false        # 圆环是否已挂进 UI 通道(决定用世界坐标还是局部坐标)
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


# 换弹圆环显示在角色后侧(背对朝向那一侧),环心是带一位小数的倒计时。
# ★ 挂在 PostProcess 的 **UI 通道**(不吃 ambient、不吃影子):它是有暗色底环的 UI,
#   留在世界里会被整体压暗,塞进加色的发光通道又会变亮。
#   降级:没有 UI 通道时退回挂在玩家身上(旧的局部坐标算法)。
func _ensure_reload_ring() -> void:
	if _reload_ring != null and is_instance_valid(_reload_ring):
		return
	var pp := get_tree().get_first_node_in_group("post_process")
	var root: Node = null
	if pp != null and pp.has_method("ui_root"):
		root = pp.ui_root()
	_reload_ring = ReloadRing.new()
	_reload_ring.visible = false
	if root != null:
		_ring_in_ui = true
		root.add_child(_reload_ring)          # UI 通道里 1 单位 = 1 世界像素
	else:
		_ring_in_ui = false
		_reload_ring.scale = Vector2.ONE / scale.x
		add_child(_reload_ring)


func _update_reload_ring() -> void:
	_ensure_reload_ring()
	if _reload_ring == null or not is_instance_valid(_reload_ring):
		return
	var w := weapons.current_weapon()
	var prog := w.reload_progress() if w != null else -1.0
	_reload_ring.visible = prog >= 0.0
	if prog < 0.0:
		return
	var offset := Vector2(-RELOAD_RING_OFFSET.x * float(facing_direction), RELOAD_RING_OFFSET.y)
	if _ring_in_ui:
		# UI 通道有自己的一份同参数相机 ⇒ 直接用世界坐标即可,不需要投影换算。
		_reload_ring.global_position = global_position + offset
		_reload_ring.scale = Vector2.ONE
	else:
		var sc := maxf(absf(scale.x), 0.001)
		_reload_ring.position = offset / sc
	_reload_ring.set_progress(prog, w.reload_time * (1.0 - prog))


const RELOAD_RING_OFFSET := Vector2(58.0, -44.0)   # 世界单位:x 朝"后侧"、y 朝上(2026-09-16 上移)

## 回溯还原已搬到 core/sim/rewind_frame.gd(RewindFrame.apply_player):单机回溯与服务器 Beta 回溯共用同一份载荷契约。


# ── 发光:由**美术遮罩**驱动(独立资产,像灯瓦片)──
# 遮罩 = `player_light.png`,与 player.png **同布局**(同一份 cells)、白色标记、A 通道装强度。
# ★ 为什么用遮罩而不是程序化:眼睛每帧位置都在变(实测跨帧 x 漂 4px、y 漂 6px),
#   硬编码坐标跟不住;遮罩逐帧画,天然对齐。
# ★ 为什么要单独的发光通道:世界整体在 PostProcess 里乘 ambient。发光体若画在世界里,会被
#   一起压暗 —— 那不是"夜里更亮",而是"夜里跟着变暗",与需求相反。所以发光精灵挂在
#   PostProcess 的 GlowViewport(相机逐帧同步),由 shader 在光照**之后**叠加。
# ★ 纯表现:不碰逻辑、不进快照;拿不到遮罩或发光通道就不显示。
const LIGHT_FIELD := "light_image"          # player.frames.json 里的遮罩字段名
const LIGHT_K := 0.32                        # 强度上限(压低:核心与光晕一起变淡)
const LIGHT_TINT := Color(0.86, 0.93, 1.0)   # 发光色(偏冷);白色标记只表示"这里发光",颜色在这里定
var _light: AnimatedSprite2D = null
var _light_root: Node2D = null   # 发光通道里的镜像根(承载玩家的位置/缩放)
var _post: Node = null           # PostProcess(惰性获取)


func _sync_form_flip() -> void:
	var mat := animator.material as ShaderMaterial if animator != null else null
	if mat != null:
		mat.set_shader_parameter("flip_x", 1.0 if animator.flip_h else 0.0)



func _tick_eye_glow() -> void:
	if animator == null:
		return
	if _light == null:
		if _post == null or not is_instance_valid(_post):
			_post = get_tree().get_first_node_in_group("post_process")
		if _post == null or not _post.has_method("glow_root"):
			return
		var glow_parent: Node = _post.glow_root()
		if glow_parent == null:
			return                        # 没有发光通道(别的场景/测试)=> 本特性自隐
		var lf := SpriteFramesIO.load_json(FRAMES_JSON, LIGHT_FIELD)
		if lf == null:
			return
		_light_root = Node2D.new()
		_light_root.name = "PlayerLight"
		glow_parent.add_child(_light_root)
		_light = AnimatedSprite2D.new()
		_light.name = "LightMask"
		_light.sprite_frames = lf
		_light.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 遮罩绝不能被过滤混色
		_light.centered = animator.centered
		_light.offset = animator.offset
		_light_root.add_child(_light)
	# 镜像本体变换:发光通道有自己的相机(同世界相机),所以世界坐标直接可用。
	_light_root.global_position = global_position
	_light_root.scale = scale
	# 与本体严格同帧:同一个动画名 + 同一个帧号,遮罩不会和贴图错开。
	_light.animation = animator.animation
	_light.frame = animator.frame
	_light.flip_h = animator.flip_h
	_light.scale = animator.scale
	var amb := 1.0
	if _post != null and is_instance_valid(_post):
		amb = clampf(_post.ambient_for(_post.get("day_hour"), _post.moon_amount(_post.get("day_hour"))), 0.05, 1.0)
	# 强度:白天几乎为 0、夜里明显。遮罩自己的 A 通道仍是逐像素强度,两者相乘。
	var gain := clampf(LIGHT_K * (1.0 - amb), 0.0, 1.0)
	_light.modulate = Color(LIGHT_TINT.r, LIGHT_TINT.g, LIGHT_TINT.b, gain)
