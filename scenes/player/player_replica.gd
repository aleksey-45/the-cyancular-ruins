class_name PlayerReplica
extends Node2D

# 多人对战远端玩家副本节点：
# 负责在客户端渲染远端玩家的外观动画、武器外观与受击特效，由服务端快照驱动。
# 姿态到动画名称映射：唯一来源是 Player.POSE_ANIM（键为 Pose 枚举整数值）。
const POSE_ANIM: Dictionary = Player.POSE_ANIM

# 飞行姿态枚举值
const POSE_FLY := 2

# 判定着地时的垂直速度容差阈值
const LAND_VEL_EPS := 1.0

# 脚底检测点世界坐标偏移（用于水体检测）
var _water_feet_off: float = 24.0

const HIT_FLASH_TIME := 0.35   # 受击闪白持续时间（秒）
const HIT_FLASH_RATE := 20.0   # 受击闪白频率

@onready var animator: AnimatedSprite2D = $AnimatedSprite2D

# 挤压拉伸补间形变组件
var squash: SquashStretch = null
var _vel: Vector2 = Vector2.ZERO
var team := 0
var role := 0
var _pose: int = 0
var _prev_vel_y: float = 0.0

var _weapon_slot_node: Node2D        # 武器挂载节点
var _weapon: WeaponBase = null       # 当前手持武器视觉实例
var _weapon_type_int := 0            # 当前武器类型 ID
var _facing := 1                         # 移动朝向
var _aim_facing := 1                     # 瞄准朝向
var _aim := Vector2(1.0, 0.0)            # 瞄准向量
var _downed := false                     # 倒地状态标记
var _hit_flash_t := 0.0                  # 受击闪白倒计时
var _charge_ghost_t := 0.0               # 冲刺残影计时器
const CHARGE_GHOST_INTERVAL := 0.06

func _ready() -> void:
	animator.sprite_frames = preload("res://scenes/player/player_frames.tres")
	_water_feet_off = Water.feet_offset(self)
	_weapon_slot_node = Node2D.new()
	_weapon_slot_node.name = "WeaponSlot"
	add_child(_weapon_slot_node)
	squash = SquashStretch.new()
	squash.setup(animator, SquashStretch.Profile.PLAYER)
	add_child(squash)
	_align_draw_order.call_deferred()

func _align_draw_order() -> void:
	var terrain := Level0.wall_layer
	if is_instance_valid(terrain) and terrain.get_parent() == get_parent():
		get_parent().move_child(self, terrain.get_index())


func _apply_visual(data: Array) -> void:
	_vel = data[PlayerStateSchema.slot("vel")]
	_facing = data[PlayerStateSchema.slot("facing")]
	var aim: Vector2 = data[PlayerStateSchema.slot("aim")]
	_aim = aim if aim != Vector2.ZERO else Vector2(float(_facing), 0.0)
	if absf(_aim.x) > 0.1:
		_aim_facing = 1 if _aim.x > 0.0 else -1
	animator.flip_h = _facing < 0
	var type_id: int = data[PlayerStateSchema.slot("type_id")]
	if type_id != _weapon_type_int:
		_swap_weapon(type_id)
	_downed = data[PlayerStateSchema.slot("down")]
	if _downed:
		animator.stop()
		rotation = -PI / 2.0 * float(_facing)
	else:
		rotation = 0.0
		var pose: int = data[PlayerStateSchema.slot("state")]
		_pose = pose
		animator.play(POSE_ANIM[pose])

# 播放受击反馈闪烁动画
func play_hit(_source_pos: Vector2) -> void:
	_hit_flash_t = HIT_FLASH_TIME

func play_fire(type_id: int) -> void:
	if _weapon != null and _weapon_type_int == type_id:
		_weapon.play_recoil()

# 切换当前展示的武器外观实例
func _swap_weapon(type_id: int) -> void:
	_weapon_type_int = type_id
	if _weapon != null:
		_weapon.queue_free()
		_weapon = null
	if type_id == 0:
		return
	var scene: PackedScene = load(WeaponRegistry.scene_of(type_id))
	_weapon = scene.instantiate()
	_weapon_slot_node.add_child(_weapon)


# 驱动武器视觉方向与枪口仰角
func _drive_weapon_visual() -> void:
	if _weapon == null:
		return
	_weapon.drive_remote_visual(_aim, _aim_facing)


# 查询远端玩家脚底是否浸入水中
func _in_water() -> bool:
	var gp := global_position
	return Water.is_in_water(Vector2(gp.x, gp.y + _water_feet_off))

func render_snapshot(data: Array, anchor: Vector2) -> void:
	_apply_visual(data)
	_drive_weapon_visual()
	global_position = GridPathfinder.anchor_to_nearest(data[PlayerStateSchema.slot("pos")], anchor,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func _process(delta: float) -> void:
	if _weapon != null:
		_weapon.present_step(delta)
	# 远端按同步姿态触发冲刺残影；冲刺结束停止生成。
	if _pose == 3 and not _downed:
		_charge_ghost_t -= delta
		if _charge_ghost_t <= 0.0:
			_charge_ghost_t = CHARGE_GHOST_INTERVAL
			AfterImage.spawn(get_parent(), animator, UiFactory.C_TEAM_A if team == 1 else UiFactory.C_TEAM_B)
	else:
		_charge_ghost_t = 0.0
	# 受击半透明闪烁反馈
	if _hit_flash_t > 0.0:
		_hit_flash_t = maxf(_hit_flash_t - delta, 0.0)
		var on := int(_hit_flash_t * HIT_FLASH_RATE) % 2 == 0
		modulate.a = 0.4 if on else 1.0
		if _hit_flash_t <= 0.0:
			modulate.a = 1.0
	elif modulate.a != 1.0:
		modulate.a = 1.0
	# 挤压拉伸形变更新
	var on_floor := (not _downed) and _pose != POSE_FLY and absf(_vel.y) < LAND_VEL_EPS
	var vel_y := _prev_vel_y
	if _in_water():
		vel_y = 0.0
	squash.tick(delta, vel_y, on_floor, _downed)
	_prev_vel_y = _vel.y
