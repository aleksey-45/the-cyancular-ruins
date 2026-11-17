class_name Player
extends CharacterBody2D

# ★ 本文件有 class_name(2026-11-02 才加):承重的回滚 / 命中 / 快照路径原先只能按名反射
#   (has_method / call / get),拼错不报错、只在运行期静默失效。代价 = 新环境必须 `--import`
#   一次重建全局类缓存(否则别的脚本报 Could not find type Player)—— 本地跑批与 CI 都已显式 import。
const HitShape := preload("res://core/sim/hit_shape.gd")   # 受击判定几何唯一入口
const PlayerNetState := preload("res://scenes/player/player_net_state.gd")   # 整态编解码(回滚/权威同步)
const PlayerPresentScript := preload("res://scenes/player/player_present.gd")   # 表现层(headless 不创建)
const PlayerPickupScript := preload("res://scenes/player/player_pickup.gd")     # 拾取/丢弃 + 端口
const PlayerMotorScript := preload("res://scenes/player/player_motor.gd")       # 移动/姿态/物理(帧内顺序唯一真相)
# 帧数据:网格 + 每帧 [列, 行] 写在 JSON 里,由网格推导 Rect2(不再手写 .tres)。
# ★ 本体与 PvP 副本都走这一份,且 SpriteFramesIO 有缓存 ⇒ 仍是"只有一处帧数据"。
const FRAMES_JSON := "res://assets/textures/player.frames.json"

@export var animator : AnimatedSprite2D


var is_squat: bool = false
var is_charge: bool = false
var facing_direction: int = 1   # 1=右，-1=左

var charge_timer: float = 0.0

@export var weapon_slot: Node2D

@onready var climb: ClimbComponent = $Climb
@onready var weapons: WeaponComponent = $Weapons
@onready var combat: CombatComponent = $Combat
@onready var swim: SwimComponent = $Swim

# 补间形变(squash & stretch):运行期创建、不进 capture_state()/restore_state()、不碰碰撞箱。
var squash: SquashStretch = null

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

# 防水值(氧气)归 SwimComponent(它已是水判定的唯一来源);这里只保留转发,外部(HUD / 整态)接口不变。
var waterproof: int:
	get:
		return swim.waterproof
var max_waterproof: int:
	get:
		return swim.max_waterproof

enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }
# 姿态动画名 / 碰撞箱节点名 / 冲刺残影常量 = **与远端副本共享的单一来源**。
# 键就是本文件的 Pose 枚举值;顺序一致性由 _ready 里那句 push_error 兜住(改一处忘另一处不会静默)。
const PlayerVisual := preload("res://scenes/player/player_visual.gd")

# 姿态锁:进入某姿态后锁定一小段时间,防止 is_on_floor()/velocity 抖动导致 move↔fly 等高频切换(走路抽搐)。
var state: Pose = Pose.STAND



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
	swim.waterproof_changed.connect(func(cur: int, mx: int) -> void: waterproof_changed.emit(cur, mx))
	hp_changed.emit(combat.hp, combat.max_hp)

	# 姿态碰撞箱与姿态锁归 motor(它每帧按姿态启用对应箱子);这里只做枚举顺序的一致性检查。
	motor.setup(self)
	# 共享表的键是裸 int:枚举顺序改了这里会立刻喊,而不是静默放错动画 / 用错碰撞箱。
	if int(Pose.SQUAT) != PlayerVisual.POSE_SQUAT:
		push_error("PlayerVisual.POSE_* 与 player.gd 的 Pose 枚举顺序不一致")

	# 单机开局空手:武器全部散落在地图上,由 Level0._ready 铺;联机由 MatchHost 调 set_initial_inventory 发随机一把。
	weapons.set_initial_inventory([])
	# 表现层:只在**有渲染**的环境创建(headless = 服务器/测试,没有画面,建了就是白花;
	# 旧实现靠"找不到 post_process 就 return"降级,结果权威端每个玩家都建了一个换弹圆环)。
	if DisplayServer.get_name() != "headless":
		present = PlayerPresentScript.new()
		add_child(present)
		present.setup(self)
	add_child.call_deferred(WaterFx.new())
	# 补间形变:挂在玩家自己身上(一个接入点覆盖单机/PvP/大乱斗);animator 是 @export 引用,场景实例化时就已就位。
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



# Beta 时间玩法(PvP):服务器权威与本端预测各写一次的加速倍率(1 = 常速)。单机不走这里(走 TimeField.player_speed_mult)。
# ★ 本字段也是唯一分发源:由 _push_haste_mult() 推给攀爬/武器/游泳三个消费点;match_host 的写与快照的读都打在本字段上。
var pvp_haste_mult := 1.0

# 表现层(发光/换弹环/残影/朝向 flip):headless 下为 null。见 scenes/player/player_present.gd。
var present = null
# 拾取/丢弃(F/Q)与长按进度:端口由单机 Level0 在出生时绑定;联机不绑(只上行走服务器)。见 player_pickup.gd。
var pickup = PlayerPickupScript.new()
# 移动/姿态/物理:帧内顺序的唯一真相。见 scenes/player/player_motor.gd。
var motor = PlayerMotorScript.new()


func speed_mult() -> float:
	return motor.speed_mult()


# 本帧倍率推给三个消费点:攀爬/武器的宿主引用是一次给入的、而倍率每帧在变 ⇒ 只能每帧推;游泳走 swim.update 的调用参数。
# ★ 调用点两处(都在 _physics_process 正常态路径、都在 climb.update 之前):weapons.tick 之前(轮询开火吃本帧倍率)、切枪之后。消费点只读注入值,拿不到就是 1×(静默降级)。
func _push_haste_mult(tm: float) -> void:
	climb.haste_mult = tm
	var cur_w := weapons.current_weapon()
	if cur_w != null:
		cur_w.haste_mult = tm


func _process(delta: float) -> void:
	if present != null:
		present.tick(delta)


func _physics_process(delta: float) -> void:
	# 加速走速度域(move_and_slide 用引擎自己的 delta):tick 类与水平速度目标 ×tm,重力/跳跃保持原样 —— 缩放 delta 只会让坠落变快、跳跃变低、移速不变。
	var tm := TimeField.player_speed_mult() if TimeField.current != null else pvp_haste_mult
	motor.set_speed_mult(tm)
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	# squash 必须在最首行(倒地早退之前):否则倒地后 animator.scale 会卡在最后一个挤压值上。
	squash.tick(delta, motor.pre_move_vy(), is_on_floor(), combat.is_downed())
	if combat.is_downed():
		# 倒地路径不归零 _pre_move_vy:否则被击杀那一刻的下坠速度会陈旧地留满整个倒地窗口(见 motor.tick_downed)。
		motor.tick_downed(delta)
		return
	_push_haste_mult(tm)   # ① 见该函数注释:必须在 weapons.tick 之前(tick 里的轮询开火吃它)
	weapons.tick(delta * tm)   # 加速时开火/换弹节拍 ×tm(武器帧逻辑走物理 tick)

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

	pickup.tick(self, delta)

	# ② 移动/物理:帧内顺序的唯一真相在 PlayerMotor.tick(顺序说明见该文件头)。
	motor.tick(delta, tm)


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
# 字段归谁、按什么顺序采纳,都在 PlayerNetState(与整态恢复共用同一份"倒地不顶满 hp"的判据)。
func apply_authoritative_state(hp_val: int, waterproof_val: int, downed_val: bool) -> void:
	PlayerNetState.apply_authoritative(self, hp_val, waterproof_val, downed_val)

# 根本体自己拥有的整态字段(位置/速度/朝向/姿态/蹲冲)。移动计时器归 PlayerMotor,水/战斗/武器归各自组件;
# 装配在 scenes/player/player_net_state.gd;键名 = core/net/net_codec.gd 的 C2_SCHEMA。
# ★ 自动跳的"满速横移"窗口 **不进整态/不上线**:它是本地表现量,只影响自己后半秒的横移补速,
#   且服务器从不 restore(只有客户端回滚重放会用到);进了 c2 就要动线格式(protocol 变更)与快照体积,
#   收益不抵风险。已知边界:回滚重放时该窗口可能少/多几帧 ⇒ 偏差 <= 0.25s 的横移补速,自愈。
func capture_self_state() -> Dictionary:
	var st := {
		"pos": global_position,
		"vel": velocity,
		"facing": facing_direction,
		"state": state,
		"squat": is_squat,
		"charge": is_charge,
		"ct": charge_timer,
	}
	st.merge(motor.capture_extra(), true)
	return st


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
	motor.restore_extra(st)
	is_squat = bool(st.get("squat", is_squat))
	is_charge = bool(st.get("charge", is_charge))
	charge_timer = float(st.get("ct", charge_timer))


func restore_state(st: Dictionary) -> void:
	PlayerNetState.restore(self, st)
	_after_state_restore()


# 不可序列化的收尾:按姿态启用碰撞箱、朝向贴图、以及恢复位置后的一次贴地重判。
func _after_state_restore() -> void:
	motor.sync_pose_collision()
	animator.flip_h = facing_direction < 0
	if present != null:
		present.sync_form_flip()
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
	motor.cancel_jump_state()

# combat 命中落地时调用:冲刺被打断,否则下一帧 is_charge 分支会用冲刺速度覆盖击退。
func cancel_charge() -> void:
	is_charge = false
	charge_timer = 0.0


# 单人倒地按 R 重启(Level0.restart_single 调):满血满氧回出生点,清倒地/冲刺/跳跃残留。
func restart_at(spawn_cell: Vector2i) -> void:
	var ts: int = GameParameters.TILE_SIZE
	global_position = Vector2(spawn_cell.x * ts + ts * 0.5, spawn_cell.y * ts + ts * 0.5)
	velocity = Vector2.ZERO
	is_charge = false
	charge_timer = 0.0
	is_squat = false
	motor.reset_timers()
	combat.knock_velocity = Vector2.ZERO
	combat.iframes = 0.0
	if combat.is_downed():
		combat.revive()   # 复位倒地 + PostProcess 变灰复位(PvP 回合复活同款)
	else:
		combat.hp = combat.max_hp
	combat.hp_changed.emit(combat.hp, combat.max_hp)   # 兜底同步 HUD 血条(revive 本身不发射)
	swim.reset_oxygen()
	weapons.cancel_aim()
	# ★ 这里不再动背包:本函数被单机与联机共用,而两种模式的武器规则不同 —— 单机的重开由 Level0.restart_single 统一重置(清空 + 重新散落),联机的复活另有规则(除随机一把外全丢)。
	weapons.reset_mag_state()   # 只把当前武器的残弹同步进背包条目(不再清任何表)
	set_controls_locked(false)


# 拾取/丢弃的端口:单机由 Level0 在出生时绑定(PlayerPickup 只认两个方法名,不认场景类);
# 联机不绑 = 明确"本端不执行",只上行走服务器裁决。
func bind_pickup_host(host: Node) -> void:
	pickup.bind(host)


# 长按 Q 的进度 0..1(只读;HUD 的丢弃进度条用):没有反馈的长按是不可用的 —— 玩家会以为按键没生效。
func drop_hold_progress() -> float:
	return pickup.progress()


func _unhandled_input(event: InputEvent) -> void:
	# 滚轮切枪(仅本地):判据与分发都在 WeaponComponent,根不再复制一份按键表。
	if weapons.try_wheel_switch(event):
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


## 回溯还原已搬到 core/sim/rewind_frame.gd(RewindFrame.apply_player):单机回溯与服务器 Beta 回溯共用同一份载荷契约。
