extends Node2D

# 多人对战远端玩家副本节点：
# 负责在客户端渲染远端玩家的外观动画、武器外观与受击特效，由服务端快照驱动。
# 包含独立的碰撞体节点，使本地客户端预测移动时能与远端玩家产生阻挡碰撞。
# 位置通过平滑指数插值朝向最近环面副本坐标收敛，确保视觉连续平滑。

# 指数追赶平滑速率
const INTERP_RATE := 12.0

# 姿态到动画名称映射，与 Player.Pose 枚举对齐
const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}

# 飞行姿态枚举值
const POSE_FLY := 2

# 判定着地时的垂直速度容差阈值
const LAND_VEL_EPS := 1.0

# 脚底检测点世界坐标偏移（用于水体检测）
var _water_feet_off: float = 24.0

# 各姿态对应的碰撞体节点名称映射
const POSE_SHAPE: Dictionary = {
	0: "CollisionShape2D_stand", 1: "CollisionShape2D_move", 2: "CollisionShape2D_fly",
	3: "CollisionShape2D_charge", 4: "CollisionShape2D_squat",
}

# 远端副本分组名称，供投掷物碰撞与范围伤害判定
const GROUP := "player_replica"

const HIT_FLASH_TIME := 0.35   # 受击闪白持续时间（秒）
const HIT_FLASH_RATE := 20.0   # 受击闪白频率

@onready var animator: AnimatedSprite2D = $AnimatedSprite2D

# 挤压拉伸补间形变组件
var squash: SquashStretch = null
var _vel: Vector2 = Vector2.ZERO
var _pose: int = 0
var _prev_vel_y: float = 0.0

var _weapon_slot_node: Node2D        # 武器挂载节点
var _weapon: Node2D = null           # 当前手持武器视觉实例
var _weapon_type_int := 0            # 当前武器类型 ID
var _opponent_canonical := Vector2.ZERO  # 服务端权威规范位置
var _local_anchor := Vector2.ZERO        # 本地玩家位置锚点
var _have_data := false
var _placed := false                     # 首次位置初始化标记
var _facing := 1                         # 移动朝向
var _aim_facing := 1                     # 瞄准朝向
var _aim := Vector2(1.0, 0.0)            # 瞄准向量
var _previewing := false                 # 重武器蓄力预瞄标记
var _downed := false                     # 倒地状态标记
var _hit_flash_t := 0.0                  # 受击闪白倒计时

# 幽灵碰撞体（仅参与阻挡碰撞，不执行逻辑）
var _ghost: StaticBody2D = null
var _ghost_shapes: Dictionary = {}   # 姿态对应的多边形碰撞体


func _ready() -> void:
	add_to_group(GROUP)
	# 复用 Player 场景的动画帧与碰撞多边形定义
	var tmp := preload("res://scenes/player/player.tscn").instantiate()
	animator.sprite_frames = tmp.get_node("AnimatedSprite2D").sprite_frames
	_build_ghost_body(tmp)
	tmp.free()
	_water_feet_off = Water.feet_offset(_ghost) if _ghost != null else 24.0
	_weapon_slot_node = Node2D.new()
	_weapon_slot_node.name = "WeaponSlot"
	add_child(_weapon_slot_node)
	squash = SquashStretch.new()
	squash.setup(animator, SquashStretch.Profile.PLAYER)
	add_child(squash)


# 构建幽灵碰撞体：使用静态刚体作为子节点，使本地客户端预测能正确检测对手阻挡
func _build_ghost_body(src: Node) -> void:
	_ghost = StaticBody2D.new()
	_ghost.name = "GhostBody"
	_ghost.collision_layer = 2
	_ghost.collision_mask = 0
	add_child(_ghost)
	for pose in POSE_SHAPE:
		var from := src.get_node_or_null(POSE_SHAPE[pose]) as CollisionPolygon2D
		if from == null:
			continue
		var poly := CollisionPolygon2D.new()
		poly.name = POSE_SHAPE[pose]
		poly.polygon = from.polygon
		poly.position = from.position
		poly.disabled = pose != 0
		_ghost.add_child(poly)
		_ghost_shapes[pose] = poly


# 设置幽灵碰撞体所属碰撞层（团队模式根据阵营动态配置）
func set_ghost_layer(n: int) -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.collision_layer = n


# 根据当前姿态切换幽灵碰撞体
func _set_ghost_pose(pose: int) -> void:
	for p in _ghost_shapes:
		(_ghost_shapes[p] as CollisionPolygon2D).disabled = p != pose


# 应用服务端快照数据，更新位置、朝向、瞄准、武器与姿态
func apply_snapshot(data: Dictionary, local_anchor: Vector2, _tick: int) -> void:
	_opponent_canonical = data["pos"]
	_local_anchor = local_anchor
	_have_data = true
	_vel = data.get("vel", Vector2.ZERO)
	_facing = 1 if int(data.get("facing", 1)) >= 0 else -1
	var aim: Vector2 = data.get("aim", Vector2.ZERO)
	_aim = aim if aim != Vector2.ZERO else Vector2(float(_facing), 0.0)
	if absf(_aim.x) > 0.1:
		_aim_facing = 1 if _aim.x > 0.0 else -1
	animator.flip_h = _facing < 0
	var type_id := int(data.get("type_id", 0))
	if type_id != _weapon_type_int:
		_swap_weapon(type_id)
	_previewing = bool(data.get("previewing", false))
	_downed = bool(data.get("downed", false))
	if _downed:
		animator.stop()
		rotation = -PI / 2.0 * float(_facing)
	else:
		rotation = 0.0
		var pose: int = clampi(int(data["pose"]), 0, POSE_SHAPE.size() - 1)
		_pose = pose
		animator.play(POSE_ANIM.get(pose, "idle"))
		_set_ghost_pose(pose)
	if _ghost != null:
		_ghost.global_rotation = 0.0


# 播放受击反馈闪烁动画
func play_hit(_source_pos: Vector2) -> void:
	_hit_flash_t = HIT_FLASH_TIME


# 切换当前展示的武器外观实例
func _swap_weapon(type_id: int) -> void:
	_weapon_type_int = type_id
	if _weapon != null:
		_weapon.queue_free()
		_weapon = null
	var scene_path: String = WeaponRegistry.scene_of(type_id)
	if scene_path.is_empty():
		return
	var scene: PackedScene = load(scene_path)
	if scene == null:
		return
	_weapon = scene.instantiate()
	_weapon_slot_node.add_child(_weapon)


# 驱动武器视觉方向与枪口仰角
func _drive_weapon_visual() -> void:
	if _weapon == null or not _weapon.has_method("drive_remote_visual"):
		return
	_weapon.drive_remote_visual(_aim, _aim_facing)


# 查询远端玩家脚底是否浸入水中
func _in_water() -> bool:
	var gp := global_position
	return Water.is_in_water(Vector2(gp.x, gp.y + _water_feet_off))


func _process(delta: float) -> void:
	if _have_data:
		_drive_weapon_visual()
		# 将权威位置对齐至相对本地玩家最近的环面副本位置
		var target := MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if not _placed:
			global_position = target
			_placed = true
		else:
			# 平滑追赶目标副本位置
			var current := MazeGenerator.anchor_to_nearest(global_position, target,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			global_position += (target - current) * (1.0 - exp(-INTERP_RATE * delta))
			global_position = MazeGenerator.anchor_to_nearest(global_position, _local_anchor,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		# 幽灵碰撞体直接对齐权威目标位置，保证客户端预测碰撞的准确性
		if _ghost != null:
			_ghost.global_position = target
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
	var on_floor := (not _downed) and _pose != POSE_FLY 			and absf(_vel.y) < LAND_VEL_EPS
	var vel_y := _prev_vel_y
	if _in_water():
		vel_y = 0.0
	squash.tick(delta, vel_y, on_floor, _downed)
	_prev_vel_y = _vel.y
