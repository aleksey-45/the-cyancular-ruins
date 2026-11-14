class_name Player
extends ActorBody

# 预测历史使用连续值；字段定义集中在 PlayerStateSchema。

var combat_rules: CombatSimulator
var post_process: PostProcess
var time_field: TimeField:
	get: return combat_rules.time_field if combat_rules != null else null
var ground_actions: Callable
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

# 挤压与拉伸补间形变组件，运行时动态创建，仅负责表现层渲染，不参与状态同步。
var squash: SquashStretch = null

var input_frozen := false

func get_current_aim_dir() -> Vector2:
	var fallback := Vector2(float(facing_direction), 0.0)
	var viewport := get_viewport()
	var camera := viewport.get_camera_2d()
	if camera == null:
		return fallback
	var window := viewport.get_window()
	var mouse_offset := window.get_mouse_position() - window.get_visible_rect().size * 0.5
	var dir: Vector2 = camera.get_base_global_position() + mouse_offset / camera.zoom - global_position
	return fallback if dir.length_squared() < 0.0001 else dir.normalized()

signal hp_changed(current: int, max: int)
signal shot_presented(shot: Dictionary)
signal waterproof_changed(current: int, max: int)   # 氧气值变更信号，供 HUD 刷新
var _shown_hp := -1
var _shown_waterproof := -1

const POSE_ANIM: Dictionary = {
	STAND: "idle", MOVE: "move", FLY: "fly", DASH: "charge", SQUAT: "squat",
}

func _ready() -> void:
	super()
	if process_mode == Node.PROCESS_MODE_DISABLED:
		return
	add_to_group("player")
	set_process(false)

	# 初始化背包：单人模式开局为空手，多人模式由服务端分配初始武器
	weapons.set_initial_inventory([])
	# 动态创建换弹圆环指示器，根据角色根节点缩放进行反向缩放以维持世界尺寸
	_reload_ring = ReloadRing.new()
	_reload_ring.scale = Vector2.ONE / scale.x
	_reload_ring.visible = false
	add_child(_reload_ring)
	add_child(WaterFx.new())
	# 挂载挤压与拉伸补间形变组件
	squash = SquashStretch.new()
	# 先将形变组件加入场景树，再完成与动画精灵的绑定
	add_child(squash)
	squash.setup(animator, SquashStretch.Profile.PLAYER)

func enable_manual_simulation() -> void:
	set_physics_process(false)

# 多人模式时间加速倍率：由服务端权威与客户端预测根据颗粒余额和输入状态写入
var _ghost_t := 0.0     # 残影生成计时器
var _ghost_flip := false  # 残影颜色交替标记
var _charge_ghost_t := 0.0  # 冲刺残影生成计时器
const CHARGE_GHOST_INTERVAL := 0.06

func _physics_process(delta: float) -> void:
	var actions := ActorStep.step(self, sample_input(delta), delta)
	combat_rules.submit(self, actions)
	present_actions(actions)
	present_tick(delta)

func correct_visual(previous: Vector2, snap: bool) -> void:
	_visual_error = Vector2.ZERO if snap else GridPathfinder.toroidal_delta_px(
			global_position, previous, terrain.map_size)
	_visual_left = 0.0 if snap else 0.05
	if snap: _visual_from = global_position
	visuals.position = to_local(global_position + _visual_error)
	set_process(not interpolate_prediction and _visual_left > 0.0)

func corrected_position() -> Vector2:
	return global_position + _visual_error * (_visual_left / 0.05)

func begin_visual_step() -> void:
	_visual_from = global_position

func rebase_visual_step(previous: Vector2) -> void:
	var motion := GridPathfinder.toroidal_delta_px(_visual_from, previous, terrain.map_size)
	_visual_from = global_position - motion

func _process(delta: float) -> void:
	_visual_left = maxf(0.0, _visual_left - delta)
	visuals.position = to_local(corrected_position())
	set_process(not interpolate_prediction and _visual_left > 0.0)

func present_prediction(delta: float, relative_tick: float) -> void:
	_process(delta)
	var motion := GridPathfinder.toroidal_delta_px(_visual_from, global_position, terrain.map_size)
	# 使用最近一个模拟 tick 的位移，视觉外推最多一个 tick。
	visuals.position = to_local(corrected_position() + motion * clampf(relative_tick, -1.0, 1.0))

func present_tick(delta: float) -> void:
	animator.flip_h = facing_direction < 0
	if sim_downed:
		animator.stop()
	else:
		animator.play(POSE_ANIM[state])
	modulate.a = 0.4 if sim_iframes > 0.0 and int(sim_iframes * 20.0) % 2 == 0 else 1.0
	if post_process != null:
		post_process.set_downed(sim_downed)
		post_process.set_health_ratio(sim_hp, sim_max_hp)
	if _shown_hp != sim_hp:
		_shown_hp = sim_hp
		hp_changed.emit(sim_hp, sim_max_hp)
	if _shown_waterproof != waterproof:
		_shown_waterproof = waterproof
		waterproof_changed.emit(waterproof, max_waterproof)
	weapons.present()
	if time_field != null and time_field.is_hasting() and not sim_downed:
		_ghost_t -= delta
		if _ghost_t <= 0.0:
			_ghost_t = 0.03
			var tint := Color(1.0, 0.25, 0.25, 0.55) if _ghost_flip else Color(0.3, 0.4, 1.0, 0.55)
			_ghost_flip = not _ghost_flip
			AfterImage.spawn(get_parent(), animator, tint)
	else:
		_ghost_t = 0.0
	# 冲刺残影：本地按 is_charge 生成，约每 0.06s 一次；冲刺结束立即停止。
	if is_charge and not sim_downed:
		_charge_ghost_t -= delta
		if _charge_ghost_t <= 0.0:
			_charge_ghost_t = CHARGE_GHOST_INTERVAL
			AfterImage.spawn(get_parent(), animator, UiFactory.C_TEAM_A if team != 2 else UiFactory.C_TEAM_B)
	else:
		_charge_ghost_t = 0.0
	squash.tick(delta, _pre_move_vy, _grounded, sim_downed)
	_update_reload_ring()
	var view := weapons.weapon_view()
	if view != null:
		view.present_equipped(self, equipped, get_current_aim_dir())

func present_actions(actions: Array) -> void:
	for action: Dictionary in actions:
		match action["kind"]:
			"fire":
				weapons.weapon_view().present_shot()
				shot_presented.emit(action)
			"sound":
				Sfx.play(action["sound"])
			"impulse":
				squash.impulse(action["value"])

# 记录决定下一物理帧模拟所需的全部关键变量，用于服务端权威快照生成与客户端预测回滚重放。
func capture_state() -> Dictionary:
	return {"actor": capture_actor_state(weapons.current_inst(), weapons.inventory.snapshot()),
		"equipment": equipped.state_values() if equipped != null else []}

func restore_state(snapshot: Dictionary, rewinding_inventory := false) -> void:
	var actor: Array = snapshot["actor"]
	restore_logic_state(actor)
	_restore_equipment(actor[PlayerStateSchema.WEAPON_INST], actor[PlayerStateSchema.INVENTORY],
			snapshot["equipment"], rewinding_inventory)

func capture_network_state() -> Dictionary:
	return {"state": capture_state(), "input": input_buffer._last, "aim": step_input.aim,
			"epoch": input_buffer.epoch, "action_ack": input_buffer.action_ack,
			"rewind": rewinding, "respawn_tick": respawn_tick}

func restore_network_state(snapshot: Dictionary) -> void:
	restore_state(snapshot["state"])
	rewinding = snapshot["rewind"]
	respawn_tick = snapshot["respawn_tick"]
	step_input.aim = snapshot["aim"]
	input_buffer.restore_authority(snapshot["epoch"], snapshot["action_ack"], snapshot["input"])
	if collision_layer == 0:
		set_team_collision(team)

func _restore_equipment(instance: int, entries: PackedInt32Array, values: Array, rewind: bool) -> void:
	if rewind:
		if not weapons.rewind_inventory(entries, instance):
			return
	else:
		weapons.restore_inventory(entries, instance)
	if equipped != null:
		equipped.restore_state_values(values)

# 单人模式倒地重启。
func restart_at(spawn_cell: Vector2i) -> void:
	global_position = terrain.cell_center(spawn_cell)
	reset_motion()
	sim_iframes = 0.0
	apply_authoritative_state(sim_max_hp, max_waterproof, false)
	weapons.cancel_aim()
	_controls_locked = false


var _reload_ring: ReloadRing = null   # 换弹圆环节点引用
var _drop_hold_t := 0.0     # 丢弃按键长按计时器
var _drop_latched := false  # 长按单次触发锁定标记


func sample_input(delta: float) -> Array:
	var record := LocalInputSource.sample(get_current_aim_dir(), input_frozen)
	if _drop_pressed(delta):
		record[ActorInput.PRESSED] |= ActorInput.BIT_DROP
	record[ActorInput.WINST] = weapons.take_uplink_switch(0 if input_frozen else LocalInputSource.switch_index())
	return record

func _drop_pressed(delta: float) -> bool:
	if input_frozen or not Input.is_action_pressed(&"Q"):
		_drop_hold_t = 0.0
		_drop_latched = false
		return false
	if _drop_latched:
		return false
	_drop_hold_t += delta
	_drop_latched = _drop_hold_t >= PlayerParams.weapon_drop_hold_time
	return _drop_latched


# 获取长按丢弃进度（0.0 ~ 1.0），供 HUD 丢弃进度条渲染显示
func drop_hold_progress() -> float:
	if _drop_latched:
		return 1.0
	return clampf(_drop_hold_t / PlayerParams.weapon_drop_hold_time, 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	# 滚轮切换武器：循环选择下一个已启用的武器槽位
	if Settings.wheel_switch and not sim_downed \
			and event is InputEventMouseButton and event.pressed:
		var dir := 0
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dir = -1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dir = 1
		if dir != 0:
			weapons.request_cycle(dir)
			return
	if sim_downed:
		# 联机对战由服务端权威控制复活，单人模式按 R 重置关卡
		if time_field != null and event.is_action_pressed("R"):
			var lvl := get_tree().current_scene
			if lvl is Level0:
				# 延迟至帧末调用重置逻辑，避免在当前输入分发调用栈内直接销毁碰撞层节点
				(lvl as Level0).restart_single.call_deferred()
		return


# 更新换弹圆环状态：根据装填进度计算倒计时并在角色后侧渲染
func _update_reload_ring() -> void:
	if _reload_ring == null or not is_instance_valid(_reload_ring):
		return
	var w := equipped
	var prog := w.reload_progress() if w != null else -1.0
	_reload_ring.visible = prog >= 0.0
	if prog < 0.0:
		return
	var sc := maxf(absf(scale.x), 0.001)
	# 局部坐标偏移换算，抵消角色根节点的缩放影响
	_reload_ring.position = Vector2(-RELOAD_RING_OFFSET.x * float(facing_direction),
			RELOAD_RING_OFFSET.y) / sc
	_reload_ring.set_progress(prog, w.reload_left)


const RELOAD_RING_OFFSET := Vector2(58.0, -44.0)   # 换弹圆环局部坐标偏移向量

enum RewindSlot { POS, VEL, FACING, HP, DOWNED, INSTANCE, INVENTORY, EQUIPMENT }

func capture_rewind_state() -> Array:
	return [global_position, velocity, facing_direction, sim_hp, sim_downed, weapons.current_inst(),
			weapons.inventory.snapshot(), equipped.state_values() if equipped != null else []]

func rewind_restore(values: Array) -> void:
	global_position = values[RewindSlot.POS]
	_grounded = false
	velocity = values[RewindSlot.VEL]
	motion_knock_velocity = Vector2.ZERO
	facing_direction = values[RewindSlot.FACING]
	var restored_hp := clampi(values[RewindSlot.HP], 0, sim_max_hp)
	var downed: bool = values[RewindSlot.DOWNED]
	var entered_downed := downed and not sim_downed
	_restore_equipment(values[RewindSlot.INSTANCE], values[RewindSlot.INVENTORY], values[RewindSlot.EQUIPMENT], true)
	apply_authoritative_state(restored_hp, waterproof, downed)
	if entered_downed:
		weapons.cancel_aim()

# 单人受击和联机 HIT 共用反馈；此处不修改 HP、倒地或击退。
func play_hit_feedback(damage: int) -> void:
	Sfx.play("hurt")
	squash.impulse(SquashStretch.Impulse.HURT)
	if post_process != null:
		post_process.flash_hit(clampf(float(damage) / float(sim_max_hp) * 2.0, 0.5, 1.0))
	var cam := get_viewport().get_camera_2d()
	if cam != null:
		var ratio := float(damage) / float(sim_max_hp)
		cam.shake(PlayerParams.hit_cam_shake * (ratio / 0.25) if ratio > 0.25 else 6.0,
				PlayerParams.hit_cam_shake_time if ratio > 0.25 else 0.15)
