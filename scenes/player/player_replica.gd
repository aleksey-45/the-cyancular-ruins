extends Node2D

# 多人对战远端玩家副本节点：
# 负责在客户端渲染远端玩家的外观动画、武器外观与受击特效，由服务端快照驱动。
# 包含独立的碰撞体节点，使本地客户端预测移动时能与远端玩家产生阻挡碰撞。
# 按服务端 tick 缓冲插值，跨地图接缝使用最近环面副本。

# 视觉时间线与权威阻挡体独立。


# 姿态到动画名称映射，与 Player.Pose 枚举对齐
const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}

# 飞行姿态枚举值
const POSE_FLY := 2

# 判定着地时的垂直速度容差阈值
const LAND_VEL_EPS := 1.0

# 与本地历史恢复窗口一致的工作量上限；按实际请求惰性延伸，不是精度保证。
# 显示仍使用 SnapshotBuffer.MAX_EXTRAPOLATION，两者独立。
const MOTION_HORIZON := 32

# 脚底检测点世界坐标偏移（用于水体检测）
var _water_feet_off: float = 24.0

# 远端副本分组名称，供投掷物碰撞与范围伤害判定
const GROUP := "player_replica"

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
var _opponent_canonical := Vector2.ZERO  # 角色阻挡体的规范位置
var _opponent_tick := 0
var _respawn_tick := 0
var _forecast: Player
var _motion_frames: Array = []
var _collision_motion: NativeMotionTrack
var _collision_index := -1
var _collision_data: Dictionary = {}
var _collision_stale := false
var _proxy_layer := 0
var proxy_age := 0
var proxy_stale := false
var proxy_sample_tick := 0
var motion_steps := 0
var motion_cache_hits := 0
var _local_anchor := Vector2.ZERO        # 本地玩家位置锚点
var _have_data := false
var _facing := 1                         # 移动朝向
var _aim_facing := 1                     # 瞄准朝向
var _aim := Vector2(1.0, 0.0)            # 瞄准向量
var _previewing := false                 # 重武器蓄力预瞄标记
var _downed := false                     # 倒地状态标记
var _hit_flash_t := 0.0                  # 受击闪白倒计时

# 幽灵碰撞体（仅参与阻挡碰撞，不执行逻辑）
var _ghost: ActorCollider = null


func _ready() -> void:
	add_to_group(GROUP)
	# 复用 Player 场景的动画帧与矩形碰撞定义
	_forecast = preload("res://scenes/player/player.tscn").instantiate()
	_forecast.name = "Forecast"
	_forecast.top_level = true
	_forecast.role = role
	_forecast.team = team
	_forecast.visible = false
	_forecast.disable_mode = CollisionObject2D.DISABLE_MODE_KEEP_ACTIVE
	_forecast.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(_forecast)
	_forecast.enable_manual_simulation()
	_forecast.set_input_source(PacketInputSource.new())
	_forecast.remove_from_group("player")
	_forecast.collision_layer = 0
	_forecast.collision_mask = 1 | 2 | 32
	_forecast.cache_terrain_motion = true
	_forecast.track_motion_bounds = true
	animator.sprite_frames = _forecast.animator.sprite_frames
	_ghost = ActorCollider.new(_forecast, 0)
	_water_feet_off = Water.feet_offset(_forecast)
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


# 设置幽灵碰撞体所属碰撞层（团队模式根据阵营动态配置）
func set_ghost_layer(n: int) -> void:
	_proxy_layer = n
	_ghost.collision_layer = n

func bind_local(player: CharacterBody2D) -> void:
	_forecast.add_collision_exception_with(player)
	_forecast.collision_mask = 1 | (16 if team == 1 else 2)
	if team == 0 or team != player.team:
		_forecast.collision_mask |= 32


# 应用服务端快照数据，更新位置、朝向、瞄准、武器与姿态
func apply_snapshot(data: Dictionary, local_anchor: Vector2, tick: int) -> void:
	# 只读运动代理：不恢复远端背包，不消费提示输入，不执行远端武器/账户/伤害。
	var motion := data.duplicate()
	motion.erase("driver")
	motion.erase("input")
	motion["locked"] = data.get("driver", {}).get("locked", false)
	# 宿主已校验消息新鲜度；显式恢复较早锚点也用于重连和离线回放。
	if not _motion_frames.is_empty() and tick < _motion_frames[-1]["tick"]: _motion_frames.clear()
	if not _motion_frames.is_empty() and _motion_frames[-1]["tick"] == tick:
		# 同一锚点的事件重放不能再次清空已经生成的运动后缀。
		if _motion_frames[-1]["data"] != motion: _motion_frames.pop_back()
	if _motion_frames.is_empty() or _motion_frames[-1]["tick"] < tick:
		_motion_frames.append({"tick": tick, "data": motion})
	while _motion_frames.size() > SnapshotBuffer.KEEP: _motion_frames.pop_front()
	_respawn_tick = data["respawn_tick"]
	_have_data = true
	anchor_collision(local_anchor, tick)

func simulation_state(data: Dictionary) -> Dictionary:
	var result := data.merged(data["driver"], true)
	result.merge({"state": data["pose"], "wp": data["waterproof"], "down": data["downed"]}, true)
	return result

func receive_input(_tick: int, _packet: Dictionary) -> bool:
	# 提示不是权威结果；远端提示到达不再使本地历史失效或积累重放窗口。
	return false

func begin_prediction_tick(tick: int) -> void:
	anchor_collision(_local_anchor, tick)

func anchor_collision(anchor: Vector2, tick: int) -> void:
	if _motion_frames.is_empty(): return
	var started := Time.get_ticks_usec() if FrameTrace.enabled else 0
	var frame: Dictionary = _motion_frames[0]
	# 通常采样最新锚点，从尾部查找避免每次遍历整个保留窗口。
	for index in range(_motion_frames.size() - 1, -1, -1):
		if _motion_frames[index]["tick"] <= tick:
			frame = _motion_frames[index]
			break
	var data: Dictionary = frame["data"]
	proxy_age = maxi(tick - int(frame["tick"]), 0)
	proxy_stale = proxy_age > MOTION_HORIZON
	proxy_sample_tick = int(frame["tick"]) + mini(proxy_age, MOTION_HORIZON)
	var ahead := 0 if data["rewind"] else mini(proxy_age, MOTION_HORIZON)
	var motion := _motion_sample(frame, ahead)
	if not data["rewind"] and motion == _collision_motion and ahead == _collision_index and is_same(data, _collision_data) and proxy_stale == _collision_stale:
		_finish_anchor(anchor, tick)
		if FrameTrace.enabled: FrameTrace.span(&"proxy_sample", started, Time.get_ticks_usec())
		return
	# 一次原生调用批量恢复运动、碰撞姿态和只读权威属性。
	motion.apply(_forecast, ahead, proxy_stale and not data["rewind"])
	if data["rewind"]:
		proxy_sample_tick = frame["tick"]
		var pos: Vector2 = data["pos"]
		var facing: int = data["facing"]
		var squat: bool = data["squat"]
		var down: bool = data["downed"]
		for knot: Dictionary in data.get("rewind_path", []):
			if knot["tick"] > tick: break
			pos = knot["body"]["pos"]
			facing = knot["body"]["facing"]
			squat = knot["body"]["squat"]
			down = knot["body"]["down"]
			proxy_sample_tick = knot["tick"]
		proxy_stale = tick > proxy_sample_tick
		_forecast.global_position = GridPathfinder.wrap_to_range(pos, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if proxy_stale:
			_forecast.velocity = Vector2.ZERO
			_forecast.combat.knock_velocity = Vector2.ZERO
		_forecast.facing_direction = facing
		_forecast.is_squat = squat
		_forecast.rewinding = true
		_forecast.apply_authoritative_state(data["hp"], data["waterproof"], down)
	_collision_motion = motion
	_collision_index = ahead
	_collision_data = data
	_collision_stale = proxy_stale
	_finish_anchor(anchor, tick)
	if FrameTrace.enabled: FrameTrace.span(&"proxy_sample", started, Time.get_ticks_usec())

func _finish_anchor(anchor: Vector2, tick: int) -> void:
	# 同一运动样本仍要更新复活边界和没有显式 view_tick 的查询元数据。
	_forecast.view_tick = _collision_data.get("view_tick", tick)
	_ghost.collision_layer = _proxy_layer if _collision_data["respawn_tick"] <= 0 or tick <= _collision_data["respawn_tick"] else 0
	_opponent_canonical = _forecast.global_position
	_opponent_tick = tick
	_local_anchor = anchor

func _motion_sample(frame: Dictionary, ahead: int) -> NativeMotionTrack:
	var data: Dictionary = frame["data"]
	# 比较实际覆盖区域。远处分块变化不应重算其余七个角色的运动轨迹。
	if frame.get("geometry", -1) != CollisionBuilder.geometry_revision:
		var initial := Rect2(data["pos"], Vector2.ONE).grow(GameParameters.TILE_SIZE * 2.0)
		var first := not frame.has("motion")
		if first or CollisionBuilder.affects_since(frame["geometry"], frame["bounds"]):
			var motion := NativeMotionTrack.new()
			motion.initialize(data, MOTION_HORIZON, initial)
			frame["motion"] = motion
			frame["bounds"] = initial
			if FrameTrace.enabled:
				FrameTrace.count(&"proxy_motion_initializations" if first else &"proxy_geometry_invalidations")
		elif FrameTrace.enabled: FrameTrace.count(&"proxy_geometry_keeps")
		frame["geometry"] = CollisionBuilder.geometry_revision
	var motion: NativeMotionTrack = frame["motion"]
	if ahead < motion.size():
		motion_cache_hits += 1
		return motion
	_collision_motion = null
	# 样本是连续的原生结构；运动核和逐 tick 扫掠范围保持一致。
	var geometry := TileDefs.terrain
	var tm := TimeField.player_speed_mult() if TimeField.current != null else float(data["haste_mult"])
	var generated := motion.extend(_forecast, ahead, ActorStep.DT, tm, Level0.pvp_mode,
			geometry, GameParameters.TILE_SIZE * 2.0)
	frame["bounds"] = motion.get_bounds()
	motion_steps += generated
	if FrameTrace.enabled: FrameTrace.count(&"proxy_motion_steps", generated)
	return motion

func step_rewind(tick: int) -> void:
	anchor_collision(_local_anchor, tick)

func _apply_visual(data: Dictionary) -> void:
	_vel = data["vel"]
	_facing = data["facing"]
	var aim: Vector2 = data["aim"]
	_aim = aim if aim != Vector2.ZERO else Vector2(float(_facing), 0.0)
	if absf(_aim.x) > 0.1:
		_aim_facing = 1 if _aim.x > 0.0 else -1
	animator.flip_h = _facing < 0
	var type_id: int = data["type_id"]
	if type_id != _weapon_type_int:
		_swap_weapon(type_id)
	_previewing = data["previewing"]
	_downed = data["downed"]
	if _downed:
		animator.stop()
		rotation = -PI / 2.0 * float(_facing)
	else:
		rotation = 0.0
		var pose: int = data["pose"]
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


func render_snapshot(data: Dictionary, anchor: Vector2) -> void:
	_local_anchor = anchor
	_apply_visual(data)
	_drive_weapon_visual()
	global_position = GridPathfinder.anchor_to_nearest(data["pos"], anchor, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func _process(delta: float) -> void:
	if _weapon != null:
		_weapon._recoil_recover(delta)
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
