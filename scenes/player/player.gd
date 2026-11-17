class_name Player
extends CharacterBody2D

# ★ 新环境必须 `--import` 一次重建全局类缓存:class_name 缺失时别的脚本只报 Could not find type Player。
const HitShape := preload("res://core/sim/hit_shape.gd")   # 受击判定几何唯一入口
const PlayerNetState := preload("res://scenes/player/player_net_state.gd")   # 整态编解码(回滚/权威同步)
const PlayerPresentScript := preload("res://scenes/player/player_present.gd")   # 表现层(headless 不创建)
const PlayerPickupScript := preload("res://scenes/player/player_pickup.gd")     # 拾取/丢弃 + 端口
const PlayerMotorScript := preload("res://scenes/player/player_motor.gd")       # 移动/姿态/物理(帧内顺序唯一真相)
# 帧数据唯一来源 = player.frames.json(本体与 PvP 副本共用;SpriteFramesIO 有缓存)。
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

var squash: SquashStretch = null

var input_source: PlayerInput = LocalInputSource.new()

func set_input_source(src: PlayerInput) -> void:
	input_source = src

func get_aim_dir_override() -> Vector2:
	return input_source.get_aim_dir_override()

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

func get_current_aim_dir() -> Vector2:
	var w := weapons.current_weapon()
	if w != null:
		return w.get_current_aim_dir()
	return Vector2(float(facing_direction), 0.0)

signal hp_changed(current: int, max: int)
signal waterproof_changed(current: int, max: int)

var hp: int:
	get:
		return combat.hp
var max_hp: int:
	get:
		return combat.max_hp

var waterproof: int:
	get:
		return swim.waterproof
var max_waterproof: int:
	get:
		return swim.max_waterproof

enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }
# 姿态动画/碰撞箱表与远端副本共享;枚举顺序由 _ready 的 push_error 兜住。
const PlayerVisual := preload("res://scenes/player/player_visual.gd")

var state: Pose = Pose.STAND



# PvP 倒计时/局间冻结:锁本地输入并冻结输入源,否则预测在冻结期照动 ⇒ 开局大 rollback。
var _controls_locked := false
func set_controls_locked(locked: bool) -> void:
	_controls_locked = locked
	if input_source != null:
		input_source.frozen = locked

func _ready() -> void:
	add_to_group("player")

	# ★ sprite_frames 必须在任何 play() 之前换;场景里不能写 animation/autoplay(载入瞬间没有帧数据会报错)。
	var frames := SpriteFramesIO.load_json(FRAMES_JSON)
	if frames != null:
		animator.sprite_frames = frames
		animator.play(&"idle")
	# 形体光:打光辅助图(RG 部位坐标 / B 贴体 AO);缺 player_shade.png 时回退 parts。
	FormLight.attach(animator, "guide", 1.10, 1.0, {
		"steps": 5.0, "dither": 0.25, "bulge": 2.0, "edge_lo": -0.20, "edge_hi": 0.80,
		"part_flat": 0.45, "ao_strength": 0.35,
	}, true)

	combat.hp_changed.connect(func(cur: int, mx: int) -> void: hp_changed.emit(cur, mx))
	combat.went_down.connect(func() -> void: weapons.cancel_aim())
	swim.waterproof_changed.connect(func(cur: int, mx: int) -> void: waterproof_changed.emit(cur, mx))
	hp_changed.emit(combat.hp, combat.max_hp)

	motor.setup(self)
	if int(Pose.SQUAT) != PlayerVisual.POSE_SQUAT:
		push_error("PlayerVisual.POSE_* 与 player.gd 的 Pose 枚举顺序不一致")

	weapons.set_initial_inventory([])
	if DisplayServer.get_name() != "headless":
		present = PlayerPresentScript.new()
		add_child(present)
		present.setup(self)
	add_child.call_deferred(WaterFx.new())
	squash = SquashStretch.new()
	# ★ 与敌鸟/对手副本统一:先 add_child 再 setup(WeaponPickup.configure 是反向规矩)。
	add_child(squash)
	squash.setup(animator, SquashStretch.Profile.PLAYER)

	floor_snap_length = 4.0
	max_slides = 6



var pvp_haste_mult := 1.0

var present = null
var pickup = PlayerPickupScript.new()
# 移动/姿态/物理:帧内顺序的唯一真相。见 scenes/player/player_motor.gd。
var motor = PlayerMotorScript.new()


func speed_mult() -> float:
	return motor.speed_mult()


# 倍率每帧变 ⇒ 每帧推给攀爬/武器;必须在 weapons.tick 之前,切枪后再推一次。
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

	# 切枪:本地输入给背包第 N 把,网络输入给权威 inst —— 上行必须是 inst(同一个下标在两端可能解出不同的枪)。
	var idx := input_source.get_switch_index_pressed()
	if idx > 0:
		weapons.equip_index(idx - 1)
	var winst := input_source.consume_switch_inst()
	if winst > 0:
		weapons.equip_inst(winst)
	_push_haste_mult(tm)

	# R 换弹走 input_source 轮询(权威服务器没有输入事件);排在切枪之后。
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

## 受击面 = 当前姿态碰撞箱的世界 AABB(所有伤害经 HitShape 查);别拿碰撞体本身当命中判据。
func hurt_rect() -> Rect2:
	return HitShape.hurt_rect_of(self)

## 能否被打中:倒地 = 本轮不再受击(旧实现靠 take_hit 早退,子弹仍会被吞掉)。
func is_hurtable() -> bool:
	return not is_downed()

func get_facing() -> int:
	return facing_direction

func set_facing(v: int) -> void:
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

# 服务器快照权威态:血量/防水/倒地直接采纳(本地 hit 只做视觉);字段归属见 PlayerNetState。
func apply_authoritative_state(hp_val: int, waterproof_val: int, downed_val: bool) -> void:
	PlayerNetState.apply_authoritative(self, hp_val, waterproof_val, downed_val)

# 本体整态字段(位置/速度/朝向/姿态/蹲冲);装配在 player_net_state.gd,键名 = NetCodec.C2_SCHEMA。
# ★ 自动跳的满速窗口不进整态(本地表现量);回滚重放偏差 ≤0.25s,自愈。
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


# 整态捕获/恢复:漏一个变量 ⇒ 重放与服务器分歧(字段归属见 player_net_state.gd)。
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


# 非预测字段软同步(背包/残弹只由服务器裁决);预测字段拿权威覆盖 = 橡皮筋。
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


# 拾取端口:单机由 Level0 绑定;联机不绑 = 本端不执行,只上行走服务器。
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
