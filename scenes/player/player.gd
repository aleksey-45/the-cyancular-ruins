class_name Player
extends NativeActorBody

# 预测历史使用连续值；只在恢复、协议比较时展开字段名。
const PREDICTION_FIELDS := ["pos", "floor", "haste_mult", "vel", "facing", "slock", "coyote", "jbuf", "jcut",
		"squat", "charge", "ct", "lmv_d", "lmv_t", "clatch", "swim", "knock", "shot_serial",
		"wp_t", "wp_s", "wp_d", "ifr", "locked", "winst", "inv", "state", "wp", "hp", "down",
		"fire_cd", "aiming", "fire_buf", "aim_f", "aim_cf", "mag", "rld", "rld_t"]
const PRESENTATION_FIELDS := ["slock", "state"]

var authority_world: Node
var input_buffer := InputBuffer.new()
var respawn_tick := 0
var last_attacker := 0
var last_hit_tick := 0

@export var animator : AnimatedSprite2D
@onready var visuals: Node2D = $Visuals
var _visual_error := Vector2.ZERO
var _visual_left := 0.0
var interpolate_prediction := false
var _visual_from := Vector2.ZERO

@export var weapon_slot: Node2D

@onready var weapons: WeaponComponent = $Weapons
@onready var combat: CombatComponent = $Combat

# 挤压与拉伸补间形变组件，运行时动态创建，仅负责表现层渲染，不参与状态同步。
var squash: SquashStretch = null

# 输入源：默认委托本地输入；联机服务端可注入网络输入源驱动角色。
var input_source: PlayerInput = LocalInputSource.new()

func set_input_source(src: PlayerInput) -> void:
	input_source = src

# 获取瞄准方向覆盖：本地输入使用鼠标瞄准，网络输入返回上报的瞄准方向。
func get_aim_dir_override() -> Vector2:
	return step_input.aim if stepping else input_source.get_aim_dir_override()

# 查询当前输入源是否来自网络注入，网络驱动的角色不读取本机鼠标。
func input_is_network() -> bool:
	return stepping or input_source.is_network_driven()

# 攻击按键状态查询接口。
func is_attack_pressed() -> bool:
	if _controls_locked:
		return false
	return (step_input.held & ActorInput.BIT_ATTACK) != 0 if stepping else input_source.is_attack_pressed()

func is_attack_just_pressed() -> bool:
	if _controls_locked:
		return false
	return (step_input.pressed & ActorInput.BIT_ATTACK) != 0 if stepping else input_source.is_attack_just_pressed()

func is_attack_just_released() -> bool:
	if _controls_locked:
		return false
	return (step_input.released & ActorInput.BIT_ATTACK) != 0 if stepping else input_source.is_attack_just_released()

# 当前瞄准方向（世界坐标系）：委托武器获取实际瞄准向量，用于输入上报。
func get_current_aim_dir() -> Vector2:
	var w := weapons.current_weapon()
	if w != null:
		return w.get_current_aim_dir()
	return Vector2(float(facing_direction), 0.0)

signal hp_changed(current: int, max: int)
signal waterproof_changed(current: int, max: int)   # 氧气值变更信号，供 HUD 刷新
var _shown_hp := -1
var _shown_waterproof := -1

# 生命值只读接口；组件与原生模拟共享同一份原生成员。
var hp: int:
	get:
		return combat.hp
var max_hp: int:
	get:
		return combat.max_hp

# 姿态状态机
enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }
const POSE_ANIM: Dictionary = {
	Pose.STAND: "idle", Pose.MOVE: "move", Pose.FLY: "fly",
	Pose.CHARGE: "charge", Pose.SQUAT: "squat",
}

# 姿态切换锁：进入新姿态后保持最短停留时间，防止物理状态抖动导致高频状态切换。
const STATE_LOCK_TIME := 0.15   # 切换后的最短停留时长（秒）

# 输入锁定控制：在倒计时或回合冻结阶段锁定本地移动与武器开火，保证预测状态与服务端快照一致。
func set_controls_locked(locked: bool) -> void:
	_controls_locked = locked
	if input_source != null:
		input_source.frozen = locked


# 原生基类持有高频状态；配置仍取自现有唯一来源。
func _init() -> void:
	step_input = ActorInput.new()
	configure_motion({
		"gravity": GameParameters.gravity0,
		"jump_velocity": PlayerParams.jump_velocity,
		"charge_down_velocity": PlayerParams.charge_down_velocity,
		"charge_velocity": PlayerParams.charge_velocity,
		"charge_duration": PlayerParams.charge_duration,
		"charge_air_gravity_mult": PlayerParams.charge_air_gravity_mult,
		"move_speed": PlayerParams.move_speed,
		"crouch_walk_speed": PlayerParams.crouch_walk_speed,
		"accel_ground": PlayerParams.accel_ground,
		"accel_air": PlayerParams.accel_air,
		"brake_ground": PlayerParams.brake_ground,
		"brake_air": PlayerParams.brake_air,
		"coyote_time": PlayerParams.coyote_time,
		"jump_buffer_time": PlayerParams.jump_buffer_time,
		"jump_cut_factor": PlayerParams.jump_cut_factor,
		"waterproof": PlayerParams.player_waterproof_max,
		"max_waterproof": PlayerParams.player_waterproof_max,
		"sim_hp": PlayerParams.player_max_hp,
		"sim_max_hp": PlayerParams.player_max_hp,
		"stop_snap": PlayerParams.stop_snap,
		"charge_dir_window": PlayerParams.charge_dir_window,
		"swim_speed": PlayerParams.player_swim_speed,
		"swim_up": PlayerParams.player_swim_up,
		"swim_down": PlayerParams.player_swim_down,
		"swim_accel": PlayerParams.player_swim_accel,
		"climb_speed": PlayerParams.climb_speed,
		"climb_vertical_mult": PlayerParams.climb_vertical_mult,
		"elastic_bounce": PlayerParams.elastic_bounce,
		"knock_decay_rate": PlayerParams.player_knock_decay_rate,
		"breath_line_offset": PlayerParams.water_breath_line_offset,
		"water_drain_interval": GameParameters.water_drain_interval,
		"water_recover_interval": GameParameters.water_recover_interval,
		"water_drown_damage_interval": GameParameters.water_drown_damage_interval,
		"water_damage": PlayerParams.player_waterproof_damage,
		"state_lock_time": STATE_LOCK_TIME,
		"climb_foot_offset": PlayerParams.climb_foot_offset,
		"swim_foot_min": PlayerParams.swim_foot_min,
		"map_dimensions": Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT),
		"jump_impulse": SquashStretch.Impulse.JUMP,
		"dash_impulse": SquashStretch.Impulse.DASH,
		"hit_iframes": PlayerParams.iframes_time,
		"hit_knockback": PlayerParams.player_hit_knockback,
		"hit_knockback_up": PlayerParams.player_hit_knockback_up,
		"climb_recoil_mult": PlayerParams.climb_recoil_mult
	})

func _ready() -> void:
	simulation_visuals = visuals
	add_to_group("player")
	set_process(false)

	hulls = [$CollisionShape2D_stand, $CollisionShape2D_squat]
	# 倒地时取消当前武器瞄准。
	combat.went_down.connect(func() -> void: weapons.cancel_aim())

	apply_collision_pose()

	# 初始化背包：单人模式开局为空手，多人模式由服务端分配初始武器
	weapons.set_initial_inventory([])
	# 动态创建换弹圆环指示器，根据角色根节点缩放进行反向缩放以维持世界尺寸
	_reload_ring = ReloadRing.new()
	_reload_ring.scale = Vector2.ONE / scale.x
	_reload_ring.visible = false
	add_child(_reload_ring)
	if authority_world == null:
		add_child(WaterFx.new())
	# 挂载挤压与拉伸补间形变组件
	squash = SquashStretch.new()
	# 先将形变组件加入场景树，再完成与动画精灵的绑定
	add_child(squash)
	squash.setup(animator, SquashStretch.Profile.PLAYER)

func enable_manual_simulation() -> void:
	set_physics_process(false)
	weapons.prepare_prediction()
	# 查询体的位姿立即生效，移动和接触由共享 tick 中的运动查询计算。
	PhysicsServer2D.body_set_mode(get_rid(), PhysicsServer2D.BODY_MODE_STATIC)

# 多人模式时间加速倍率：由服务端权威与客户端预测根据颗粒余额和输入状态写入
var _ghost_t := 0.0     # 残影生成计时器
var _ghost_flip := false  # 残影颜色交替标记

func _physics_process(delta: float) -> void:
	if not Level0.pvp_mode:
		_poll_pickup_drop(delta)
	var record := PacketInputSource.pack_record(input_source, 0, get_current_aim_dir())
	record["view_tick"] = 0
	record["winst"] = weapons.take_uplink_switch(input_source.get_switch_index_pressed())
	execute_actions(ActorStep.step(self, record, delta))
	present_tick(delta)

func correct_visual(previous: Vector2, snap: bool) -> void:
	_visual_error = Vector2.ZERO if snap else GridPathfinder.toroidal_delta_px(
			global_position, previous, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_visual_left = 0.0 if snap else 0.05
	if snap: _visual_from = global_position
	visuals.position = to_local(global_position + _visual_error)
	set_process(not interpolate_prediction and _visual_left > 0.0)

func corrected_position() -> Vector2:
	return global_position + _visual_error * (_visual_left / 0.05)

func begin_visual_step() -> void:
	_visual_from = global_position

func rebase_visual_step(previous: Vector2) -> void:
	var motion := GridPathfinder.toroidal_delta_px(_visual_from, previous,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_visual_from = global_position - motion

func _process(delta: float) -> void:
	_visual_left = maxf(0.0, _visual_left - delta)
	visuals.position = to_local(corrected_position())
	set_process(not interpolate_prediction and _visual_left > 0.0)

func present_prediction(delta: float, relative_tick: float) -> void:
	_process(delta)
	var motion := GridPathfinder.toroidal_delta_px(_visual_from, global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# 使用最近一个模拟 tick 的位移，视觉外推最多一个 tick。
	visuals.position = to_local(corrected_position() + motion * clampf(relative_tick, -1.0, 1.0))

func present_tick(delta: float) -> void:
	animator.flip_h = facing_direction < 0
	if combat.downed:
		animator.stop()
	else:
		animator.play(POSE_ANIM[state])
	combat.present()
	if not Level0.pvp_mode:
		var pp := get_tree().get_first_node_in_group("post_process")
		if pp != null:
			pp.set_downed(combat.downed)
	if _shown_hp != combat.hp:
		_shown_hp = combat.hp
		hp_changed.emit(combat.hp, combat.max_hp)
	if _shown_waterproof != waterproof:
		_shown_waterproof = waterproof
		waterproof_changed.emit(waterproof, max_waterproof)
	weapons.present()
	if TimeField.current != null and TimeField.current.is_hasting() and not combat.is_downed():
		_ghost_t -= delta
		if _ghost_t <= 0.0:
			_ghost_t = 0.03
			var tint := Color(1.0, 0.25, 0.25, 0.55) if _ghost_flip else Color(0.3, 0.4, 1.0, 0.55)
			_ghost_flip = not _ghost_flip
			AfterImage.spawn(get_parent(), animator, tint)
	squash.tick(delta, _pre_move_vy, _grounded, combat.is_downed())
	_update_reload_ring()
	var weapon := weapons.current_weapon()
	if weapon != null:
		weapon._update_laser()
		weapon._recoil_recover(delta)
		weapon._update_reload_pose()

func execute_actions(actions: Array) -> void:
	for action: Dictionary in actions:
		match action["kind"]:
			"fire":
				weapons.current_weapon().execute_shot(action)
			"sound":
				if authority_world == null:
					Sfx.play(action["sound"])
			"impulse":
				if authority_world == null:
					squash.impulse(action["value"])
			"hit":
				if authority_world != null:
					authority_world.damage(0, role, action["pos"], action["damage"], true)
				elif not Level0.pvp_mode:
					take_hit(action["pos"], action["damage"], true)

func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# 时空回溯状态下免疫一切外部伤害，防止回放过程中因瞬移误触发受击判定
	if (TimeField.current != null and TimeField.current.is_rewinding()) or rewinding:
		return
	# 仅在实际扣除生命值时触发受击挤压形变，无敌帧或倒地状态不重复触发
	var before := combat.hp
	combat.take_hit(source_pos, damage, ignore_iframes, knockback)
	if combat.hp < before and authority_world == null:
		play_hit_feedback(before - combat.hp)

func get_facing() -> int:
	return facing_direction

func is_downed() -> bool:
	return combat.downed

# 查询当前是否处于冲刺状态，武器据此决定枪口朝向是否受限于角色身体朝向
func apply_recoil(push: float) -> void:
	native_apply_recoil(push)

func apply_authoritative_state(hp_val: int, waterproof_val: int, downed_val: bool) -> void:
	native_apply_authoritative_state(hp_val, waterproof_val, downed_val)

# 记录决定下一物理帧模拟所需的全部关键变量，用于服务端权威快照生成与客户端预测回滚重放。
func capture_state(shared_inventory: bool = false) -> Dictionary:
	return capture_state_native(weapons.current_inst(), weapons.snapshot_inventory(shared_inventory))

static func expand_prediction_state(values: Array) -> Dictionary:
	var result := {}
	for index in values.size(): result[PREDICTION_FIELDS[index]] = values[index]
	return result

static func prediction_difference(values: Array, authoritative: Dictionary) -> String:
	if values.is_empty(): return "missing"
	for index in values.size():
		var field: String = PREDICTION_FIELDS[index]
		# 动画姿态和停留计时仍随快照保存恢复，但不决定碰撞、武器或玩法结果。
		if field in PRESENTATION_FIELDS: continue
		if values[index] != authoritative.get(field): return field
	return ""

# 本地完整预测需要武器计时、反冲和控制锁；远端运动代理不执行这些字段。
func capture_driver_state(shared_inventory: bool = false) -> Dictionary:
	var st := {}
	write_driver_state_native(st, weapons.current_inst(), weapons.snapshot_inventory(shared_inventory))
	return st

func restore_state(st: Dictionary) -> void:
	restore_logic_state(st)
	# 恢复武器背包、手持装备及弹药状态
	_apply_weapon_state(st)


# 应用服务端的武器与弹药状态，先同步背包列表，再恢复手持装备与弹药量
func _apply_weapon_state(st: Dictionary) -> void:
	weapons.restore_inventory(st["inv"], st["winst"])
	var w: WeaponBase = weapons._weapon
	if w != null:
		w.native_restore_driver_state(st)

# 单人模式倒地重启。
func restart_at(spawn_cell: Vector2i) -> void:
	var ts: int = GameParameters.TILE_SIZE
	global_position = Vector2(spawn_cell.x * ts + ts * 0.5, spawn_cell.y * ts + ts * 0.5)
	reset_motion()
	combat.iframes = 0.0
	if combat.is_downed():
		combat.revive()
	else:
		combat.hp = combat.max_hp
	waterproof = max_waterproof
	_was_submerged = false
	_waterproof_timer = 0.0
	_waterproof_drown_timer = 0.0
	weapons.cancel_aim()
	# 复位当前手持武器弹药状态并同步至背包数据
	weapons.reset_mag_state()
	set_controls_locked(false)


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
	if not Level0.pvp_mode and input_source.is_pickup_pressed():
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

# 单人回放同一份 capture_state 快照；世界回溯的运动/生命语义由此处理，武器复用公共入口。
func rewind_restore(d: Dictionary) -> void:
	global_position = d["pos"]
	_grounded = false
	velocity = d["vel"]
	combat.knock_velocity = Vector2.ZERO
	combat.hp = clampi(int(d["hp"]), 0, combat.max_hp)
	facing_direction = int(d["facing"])
	var downed_now := is_downed()
	_apply_weapon_state(d)
	if bool(d["down"]) and not downed_now:
		combat.set_downed_by_rewind(true)
	elif not bool(d["down"]) and downed_now:
		combat.revive()
	rotation = -PI / 2.0 * facing_direction if is_downed() else 0.0
# 单人受击和联机 HIT 共用反馈；此处不修改 HP、倒地或击退。
func play_hit_feedback(damage: int) -> void:
	Sfx.play("hurt")
	squash.impulse(SquashStretch.Impulse.HURT)
	var pp := get_tree().get_first_node_in_group("post_process")
	if pp != null:
		pp.flash_hit(clampf(float(damage) / float(max_hp) * 2.0, 0.5, 1.0))
	var cam := get_viewport().get_camera_2d()
	if cam != null:
		var ratio := float(damage) / float(max_hp)
		cam.shake(PlayerParams.hit_cam_shake * (ratio / 0.25) if ratio > 0.25 else 6.0,
				PlayerParams.hit_cam_shake_time if ratio > 0.25 else 0.15)
