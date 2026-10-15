extends CharacterBody2D

var authority_world: Node
var input_buffer := InputBuffer.new()
var role := 0
var team := 0
var shot_serial := 0
var input_seq := 0
var view_tick := 0
var rewinding := false
var stepping := false
var respawn_left := 0.0
var last_attacker := 0
var last_hit_tick := 0

@export var animator : AnimatedSprite2D
@onready var visuals: Node2D = $Visuals
var _visual_error := Vector2.ZERO
var _visual_left := 0.0
var interpolate_prediction := false
var _visual_from := Vector2.ZERO

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
var _grounded := false
var step_input := PacketInputSource.new()
var step_actions: Array = []

# 输入源：默认委托本地输入；联机服务端可注入网络输入源驱动角色。
var input_source: PlayerInput = LocalInputSource.new()

func set_input_source(src: PlayerInput) -> void:
	input_source = src

# 获取瞄准方向覆盖：本地输入使用鼠标瞄准，网络输入返回上报的瞄准方向。
func get_aim_dir_override() -> Vector2:
	return step_input.get_aim_dir_override() if stepping else input_source.get_aim_dir_override()

# 查询当前输入源是否来自网络注入，网络驱动的角色不读取本机鼠标。
func input_is_network() -> bool:
	return stepping or input_source.is_network_driven()

# 攻击按键状态查询接口。
func is_attack_pressed() -> bool:
	if _controls_locked:
		return false
	return step_input.is_attack_pressed() if stepping else input_source.is_attack_pressed()

func is_attack_just_pressed() -> bool:
	if _controls_locked:
		return false
	return step_input.is_attack_just_pressed() if stepping else input_source.is_attack_just_pressed()

func is_attack_just_released() -> bool:
	if _controls_locked:
		return false
	return step_input.is_attack_just_released() if stepping else input_source.is_attack_just_released()

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
	set_process(false)

	# 倒地时取消当前武器瞄准。
	combat.went_down.connect(func() -> void: weapons.cancel_aim())

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
	if authority_world == null:
		add_child(WaterFx.new())
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

func shot_origin(muzzle: Node2D) -> Vector2:
	return muzzle.global_position - (visuals.global_position - global_position)

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
				if authority_world == null:
					GameLog.record("player_fire", {"role": role, "predicted": Level0.pvp_mode,
							"type": weapons.current_type_id(), "inst": weapons.current_inst(), "action": action})
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

func simulate_tick(delta: float) -> void:
	var record := PacketInputSource.pack_record(input_source, 0, get_current_aim_dir())
	record["view_tick"] = 0
	execute_actions(ActorStep.step(self, record, delta))

func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# 时空回溯状态下免疫一切外部伤害，防止回放过程中因瞬移误触发受击判定
	if (TimeField.current != null and TimeField.current.is_rewinding()) or rewinding:
		return
	# 仅在实际扣除生命值时触发受击挤压形变，无敌帧或倒地状态不重复触发
	var before := combat.hp
	combat.take_hit(source_pos, damage, ignore_iframes, knockback)
	if combat.hp < before and authority_world == null:
		GameLog.record("player_damage", {"role": role, "damage": before - combat.hp,
				"hp": combat.hp, "source": source_pos, "downed": combat.downed})
		play_hit_feedback(before - combat.hp)

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

func apply_recoil(push: float) -> void:
	weapons.apply_recoil(push, is_squat, climb.is_latched())

# 应用服务端快照中的权威状态（生命值、氧气与倒地状态）
func apply_authoritative_state(hp_val: int, waterproof_val: int, downed_val: bool) -> void:
	combat.hp = hp_val
	waterproof = waterproof_val
	combat.downed = downed_val
	rotation = -PI / 2.0 * facing_direction if downed_val else 0.0

# ── 客户端预测：完整状态捕获与恢复（capture_state / restore_state）──
# 记录决定下一物理帧模拟所需的全部关键变量，用于服务端权威快照生成与客户端预测回滚重放。
func capture_state() -> Dictionary:
	var st: Dictionary = {
		"pos": global_position,
		"floor": _grounded,
		"haste_mult": pvp_haste_mult,
		"shot_serial": shot_serial,
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
	global_position = st["pos"]
	_grounded = st["floor"]
	pvp_haste_mult = st["haste_mult"]
	shot_serial = st["shot_serial"]
	velocity = st["vel"]
	facing_direction = int(st["facing"])
	state = st["state"]
	state_lock_timer = float(st["slock"])
	coyote_timer = float(st["coyote"])
	jump_buffer_timer = float(st["jbuf"])
	jump_cut_applied = bool(st["jcut"])
	is_squat = bool(st["squat"])
	is_charge = bool(st["charge"])
	charge_timer = float(st["ct"])
	_last_move_dir = int(st["lmv_d"])
	_last_move_timer = float(st["lmv_t"])
	climb._latched = bool(st["clatch"])
	swim.in_water = bool(st["swim"])
	# 恢复生命值、氧气与倒地状态
	apply_authoritative_state(st["hp"], st["wp"], st["down"])
	combat.iframes = float(st["ifr"])
	combat.knock_velocity = st["knock"]
	_waterproof_timer = float(st["wp_t"])
	_was_submerged = bool(st["wp_s"])
	_waterproof_drown_timer = float(st["wp_d"])
	# 恢复武器背包、手持装备及弹药状态
	_apply_weapon_state(st)
	# 碰撞姿态属于模拟状态；动画留到 present_tick。
	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != state


# 应用服务端的武器与弹药状态，先同步背包列表，再恢复手持装备与弹药量
func _apply_weapon_state(st: Dictionary) -> void:
	weapons.restore_inventory(st["inv"], st["winst"])
	var w: WeaponBase = weapons._weapon
	if w != null:
		w.fire_cd_timer = float(st["fire_cd"])
		w._aiming = bool(st["aiming"])
		w._fire_buffered = bool(st["fire_buf"])
		w._aim_facing = int(st["aim_f"])
		w._current_aim_facing = int(st["aim_cf"])
		# 同步武器开火冷却、瞄准状态及当前弹药量
		WeaponComponent.apply_mag(w, int(st["mag"]))
		w._reloading = bool(st["rld"])
		w._reload_t = float(st["rld_t"])

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
			waterproof = maxi(waterproof - 1, 0)
	else:
		_waterproof_timer += delta
		if _waterproof_timer >= GameParameters.water_recover_interval:
			_waterproof_timer = 0.0
			waterproof = mini(waterproof + 1, max_waterproof)
	if waterproof <= 0:
		_waterproof_drown_timer += delta
		if _waterproof_drown_timer >= GameParameters.water_drown_damage_interval:
			_waterproof_drown_timer = 0.0
			if not Level0.pvp_mode:
				step_actions.append({"kind": "hit", "pos": global_position, "damage": PlayerParams.player_waterproof_damage})

# 单人模式倒地重启：在指定出生点复位角色位置、生命值与氧气，清理物理状态残留
func restart_at(spawn_cell: Vector2i) -> void:
	var ts: int = GameParameters.TILE_SIZE
	global_position = Vector2(spawn_cell.x * ts + ts * 0.5, spawn_cell.y * ts + ts * 0.5)
	velocity = Vector2.ZERO
	_grounded = false
	is_charge = false
	charge_timer = 0.0
	is_squat = false
	cancel_jump_state()
	combat.knock_velocity = Vector2.ZERO
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

# 时空回溯状态还原：恢复位置、速度、生命值、朝向与倒地状态
func rewind_restore(d: Dictionary) -> void:
	global_position = d["p"]
	if d["v"] != null:
		velocity = d["v"]
	combat.knock_velocity = Vector2.ZERO
	combat.hp = clampi(int(d["hp"]), 0, combat.max_hp)
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
# 单人受击和联机 HIT 共用反馈；此处不修改 HP、倒地或击退。
func play_hit_feedback(damage: int) -> void:
	Sfx.play("hurt")
	squash.impulse(SquashStretch.Impulse.HURT)
	var pp := get_tree().get_first_node_in_group("post_process")
	if pp != null:
		pp.flash_hit(clampf(float(damage) / float(max_hp) * 2.0, 0.5, 1.0))
	var cam := get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		var ratio := float(damage) / float(max_hp)
		cam.shake(PlayerParams.hit_cam_shake * (ratio / 0.25) if ratio > 0.25 else 6.0,
				PlayerParams.hit_cam_shake_time if ratio > 0.25 else 0.15)
