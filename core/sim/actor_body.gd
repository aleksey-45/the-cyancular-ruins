class_name ActorBody
extends ServerBody

# 角色运动状态机与玩法状态。角色是自管 RID 物理体：地形与角色阻挡统一由
# CollisionWorld.move_body() 在同一物理空间求解；本节点只承载状态、输入处理与
# X/Y 运动顺序，节点变换就是权威数据位姿，服务器变换在每个写入收口同步。
# 环形地图接缝由本体 RID 上的镜像形状槽补齐（规范形状由节点 hull 载体承担）。

const STATE_LOCK_TIME := 0.15
const STAND := 0
const MOVE := 1
const FLY := 2
const DASH := 3
const SQUAT := 4
const UP := 1
const DOWN := 2
const CHARGE := 4

var gravity := 0.0
var jump_velocity := 0.0
var charge_down_velocity := 0.0
var charge_velocity := 0.0
var charge_duration := 0.0
var charge_air_gravity_mult := 0.0
var move_speed := 0.0
var crouch_walk_speed := 0.0
var accel_ground := 0.0
var accel_air := 0.0
var brake_ground := 0.0
var brake_air := 0.0
var coyote_time := 0.0
var jump_buffer_time := 0.0
var jump_cut_factor := 0.0
var coyote_timer := 0.0
var jump_buffer_timer := 0.0
var charge_timer := 0.0
var _last_move_timer := 0.0
var _pre_move_vy := 0.0
var state_lock_timer := 0.0
var _waterproof_timer := 0.0
var _waterproof_drown_timer := 0.0
var sim_iframes := 0.0
var stop_snap := 0.0
var charge_dir_window := 0.0
var swim_speed := 0.0
var swim_up := 0.0
var swim_down := 0.0
var swim_accel := 0.0
var climb_speed := 0.0
var climb_vertical_mult := 0.0
var elastic_bounce := 0.0
var knock_decay_rate := 0.0
var breath_line_offset := 0.0
var water_drain_interval := 0.0
var water_recover_interval := 0.0
var water_drown_damage_interval := 0.0
var state_lock_time := 0.0
var climb_foot_offset := 0.0
var swim_foot_min := 0.0
var step_max_height := 0.0
var rewinding := false
var stepping := false
var jump_cut_applied := false
var is_squat := false
var is_charge := false
var _grounded := false
var _controls_locked := false
var _was_submerged := false
var sim_downed := false
var climb_latched := false
var in_water := false
var role := 0
var team := 0
var shot_serial := 0
var state := 0
var waterproof := 0
var max_waterproof := 0
var sim_hp := 0
var sim_max_hp := 0
var water_damage := 0
var pvp_haste_mult := 1.0
var facing_direction := 1
var _last_move_dir := 1
var motion_knock_velocity := Vector2.ZERO
var map_dimensions := Vector2.ZERO
var jump_impulse := 0
var dash_impulse := 0
var combat_tick := 0
var hit_iframes := 0.0
var hit_knockback := 0.0
var hit_knockback_up := 0.0
var climb_recoil_mult := 0.0

var step_input: ActorInput = null
# 拥有本角色模拟权威的环境（AuthorityWorld）；null = 无权威环境（单机本地/纯预测体）。
var authority_world: Node
# 姿态壳载体：节点 CollisionShape2D 只提供形状与局部变换，物理全在服务器槽位上。
var hulls: Array = []
# 本 tick 的运动接触：{"rid", "normal", "point"}；result 对象是复用的，出结果立即抄值。
var motion_contacts: Array = []
var step_actions: Array = []

var _terrain: Terrain = null
var _speed_mult := 1.0
var _weapon: Node2D = null
var _visual: Node2D = null
var _prediction_projectiles: Dictionary = {}
var _prediction_registry_bound := false
# 原 CharacterBody2D 的内建字段改为普通数据。
var velocity := Vector2.ZERO
var floor_snap_length := 1.0
var safe_margin := 0.08
# 本体 RID 上的接缝镜像槽：X、Y 与角落副本；规范形状由节点 hull 承担。
const MIRROR_SLOTS := 3
var _mirror_stance := -1
var _mirror_pose := Transform2D()


func _init() -> void:
	super()   # 基类 _init 创建自管物理体；GDScript 不隐式链式调用构造器
	step_input = ActorInput.new()
	gravity = GameParameters.gravity0
	jump_velocity = PlayerParams.jump_velocity
	charge_down_velocity = PlayerParams.charge_down_velocity
	charge_velocity = PlayerParams.charge_velocity
	charge_duration = PlayerParams.charge_duration
	charge_air_gravity_mult = PlayerParams.charge_air_gravity_mult
	move_speed = PlayerParams.move_speed
	crouch_walk_speed = PlayerParams.crouch_walk_speed
	accel_ground = PlayerParams.accel_ground
	accel_air = PlayerParams.accel_air
	brake_ground = PlayerParams.brake_ground
	brake_air = PlayerParams.brake_air
	coyote_time = PlayerParams.coyote_time
	jump_buffer_time = PlayerParams.jump_buffer_time
	jump_cut_factor = PlayerParams.jump_cut_factor
	waterproof = PlayerParams.player_waterproof_max
	max_waterproof = PlayerParams.player_waterproof_max
	sim_hp = PlayerParams.player_max_hp
	sim_max_hp = PlayerParams.player_max_hp
	stop_snap = PlayerParams.stop_snap
	charge_dir_window = PlayerParams.charge_dir_window
	swim_speed = PlayerParams.player_swim_speed
	swim_up = PlayerParams.player_swim_up
	swim_down = PlayerParams.player_swim_down
	swim_accel = PlayerParams.player_swim_accel
	climb_speed = PlayerParams.climb_speed
	climb_vertical_mult = PlayerParams.climb_vertical_mult
	elastic_bounce = PlayerParams.elastic_bounce
	knock_decay_rate = PlayerParams.player_knock_decay_rate
	breath_line_offset = PlayerParams.water_breath_line_offset
	water_drain_interval = GameParameters.water_drain_interval
	water_recover_interval = GameParameters.water_recover_interval
	water_drown_damage_interval = GameParameters.water_drown_damage_interval
	water_damage = PlayerParams.player_waterproof_damage
	state_lock_time = STATE_LOCK_TIME
	climb_foot_offset = PlayerParams.climb_foot_offset
	swim_foot_min = PlayerParams.swim_foot_min
	step_max_height = PlayerParams.step_max_height
	map_dimensions = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	jump_impulse = SquashStretch.Impulse.JUMP
	dash_impulse = SquashStretch.Impulse.DASH
	hit_iframes = PlayerParams.iframes_time
	hit_knockback = PlayerParams.player_hit_knockback
	hit_knockback_up = PlayerParams.player_hit_knockback_up
	climb_recoil_mult = PlayerParams.climb_recoil_mult


func _ready() -> void:
	hulls = [$CollisionShape2D_stand, $CollisionShape2D_squat]
	apply_collision_pose()

func _enter_tree() -> void:
	super()   # 空间挂接、层掩码提交与归属挂载
	_mirror_stance = -1

# 地形与角色阻挡共用同一条 CollisionWorld.move_body() 路径；掩码决定谁挡路（队友不在掩码内即穿透）。
func move_by_internal(motion: Vector2) -> Vector2:
	if hulls.size() < 2:
		# 姿态壳在 _ready 填充，模拟 tick 必然晚于它；走到这里说明碰撞节点配置损坏。
		push_error("ActorBody: 缺少姿态壳 CollisionShape2D,角色无法运动(节点名 = %s)" % name)
		return Vector2.ZERO
	var blocked := Vector2.ZERO
	var step_ready := _step_up_ready() and motion.y >= 0.0
	for axis in 2:
		var distance := motion[axis]
		if distance == 0.0:
			continue
		var start := global_transform
		var travel := Vector2.ZERO
		travel[axis] = distance
		# 台阶：候选检测全部是只读的 probe_body（本体自动排除，含镜像槽）；只有选中路径才真正移动。
		if axis == 0 and step_ready and signf(distance) == signf(step_input.axis) \
				and CollisionWorld.probe_body(_rid, start, travel, safe_margin, true):
			var height := _step_up_height(distance, start)
			if height > 0.0 and _execute_step_up(height, distance):
				blocked.x = 0.0
				# 实际落脚是向下接触；向上运动时不能把本 tick 标为着地。
				if motion.y >= 0.0:
					blocked.y = 1.0
				continue
			# 没有候选或执行与检测矛盾：回到本轴起点，走正常阻挡路径。
			_apply_pose(start.origin)
		var out := CollisionWorld.move_body(_rid, start, travel)
		var hit: bool = out[0]
		var result: PhysicsTestMotionResult2D = out[1]
		global_position = start.origin + result.get_travel()
		if hit:
			motion_contacts.append({"rid": result.get_collider_rid(),
					"normal": result.get_collision_normal(), "point": result.get_collision_point()})
			if CollisionWorld.axis_blocked(result, axis, travel[axis]):
				blocked[axis] = signf(distance)
	return blocked

# 直接写位姿的数据侧收口：节点变换与服务器变换一起更新（回摆/回退等非移动路径共用）。
func _apply_pose(origin: Vector2) -> void:
	global_position = origin
	CollisionWorld.sync_body_pose(_rid, global_transform)

## 仅着地、正常水平输入、未处于冲刺/蹲伏/攀爬/游泳时启用自动上台阶。
func _step_up_ready() -> bool:
	if not _grounded or sim_downed or is_charge or is_squat or climb_latched or in_water or rewinding:
		return false
	if step_max_height <= 0.0 or step_input == null or step_input.axis == 0.0:
		return false
	return true

## 只读候选检测：依次检查 16/32/48/64px 的上升、横移与下落。
## probe_body 不移动角色、不写接触记录；本体（含镜像槽）自动排除，返回第一个可行高度，0 表示没有。
func _step_up_height(distance: float, start: Transform2D) -> float:
	var found := 0.0
	var height := 16.0
	while height <= step_max_height + 0.001:
		var up := Vector2(0.0, -height)
		if not CollisionWorld.probe_body(_rid, start, up, safe_margin, true):
			var raised := start
			raised.origin += up
			var across := Vector2(distance, 0.0)
			if not CollisionWorld.probe_body(_rid, raised, across, safe_margin, true):
				var landed := raised
				landed.origin += across
				if CollisionWorld.probe_body(_rid, landed, Vector2(0.0, height + 1.0), safe_margin, false):
					found = height
					break
		height += 16.0
	return found

## 执行已验证的台阶路径；候选与执行用同一套掩码与几何，正常不应出现新阻挡。
## 若执行结果与候选检测矛盾，恢复由调用方处理并显式报错，不把回写位置当作成功。
func _execute_step_up(height: float, distance: float) -> bool:
	var up := CollisionWorld.move_body(_rid, global_transform, Vector2(0.0, -height))
	global_position += (up[1] as PhysicsTestMotionResult2D).get_travel()
	var across := CollisionWorld.move_body(_rid, global_transform, Vector2(distance, 0.0))
	global_position += (across[1] as PhysicsTestMotionResult2D).get_travel()
	var down := CollisionWorld.move_body(_rid, global_transform, Vector2(0.0, height + 1.0))
	var down_hit: bool = down[0]
	var down_result: PhysicsTestMotionResult2D = down[1]
	global_position += down_result.get_travel()
	if bool(up[0]) or bool(across[0]) or not down_hit or down_result.get_collision_normal().y >= -0.5:
		push_error("ActorBody: 台阶候选路径与实际移动结果不一致 role=%d pf=%d height=%.0f distance=%.1f pos=%s velocity=%s" % [
				role, Engine.get_physics_frames(), height, distance, global_position, velocity])
		return false
	motion_contacts.append({"rid": down_result.get_collider_rid(),
			"normal": down_result.get_collision_normal(), "point": down_result.get_collision_point()})
	return true

func move_actor(delta: float) -> void:
	var motion := (velocity + motion_knock_velocity) * delta
	if _grounded and motion.y >= 0.0:
		motion.y = maxf(motion.y, floor_snap_length)
	var blocked := move_by_internal(motion)
	_grounded = blocked.y > 0.0
	if blocked.x != 0.0:
		velocity.x = 0.0
		motion_knock_velocity.x = 0.0
		cancel_charge()
	if blocked.y != 0.0:
		velocity.y = 0.0
		motion_knock_velocity.y = 0.0
	motion_knock_velocity *= exp(-knock_decay_rate * delta)

func brake(delta: float) -> void:
	velocity.x = MathUtil.approach(velocity.x, 0.0, brake_ground if _grounded else brake_air, delta)
	if absf(velocity.x) < stop_snap:
		velocity.x = 0.0

func wrap_position() -> void:
	if _terrain == null:
		return
	var at := global_position
	var wrapped := GridPathfinder.wrap_to_range(at, _terrain.size().x, _terrain.size().y)
	if at != wrapped:
		_apply_pose(wrapped)

func apply_collision_pose() -> void:
	sync_collision_geometry()

## 把全部形状槽同步到当前位姿与姿态壳：基础槽承载各姿态 hull，镜像槽承载
## X/Y/角落副本（形状取自当前姿态 hull）。形状改动后重设本体变换，保证同帧查询立即可见。
## 变换写本体局部坐标：镜像偏移是全局位移，需换算回本体局部方向（本体带缩放与倒地旋转）。
## stance 传 -1 时取当前玩法姿态。
func sync_collision_geometry(stance: int = -1) -> void:
	if hulls.size() < 2 or not _world_space.is_valid():
		return
	if stance < 0:
		stance = collision_stance()
	var pose := global_transform
	if stance == _mirror_stance and pose == _mirror_pose:
		return
	var rid := _rid
	var to_local := pose.affine_inverse()
	var mirrors := CollisionWorld.mirror_offsets(pose.origin)
	var total := hulls.size() + MIRROR_SLOTS
	while PhysicsServer2D.body_get_shape_count(rid) < total:
		PhysicsServer2D.body_add_shape(rid, CollisionWorld.placeholder)
	for i in hulls.size():
		var hull := hulls[i] as CollisionShape2D
		var shape: Shape2D = hull.shape if hull != null else null
		var active: bool = i == stance and shape != null
		PhysicsServer2D.body_set_shape_disabled(rid, i, not active)
		if active:
			PhysicsServer2D.body_set_shape(rid, i, shape)
			PhysicsServer2D.body_set_shape_transform(rid, i, hull.transform)
	for m in MIRROR_SLOTS:
		var slot := hulls.size() + m
		var hull := hulls[stance] as CollisionShape2D
		var shape: Shape2D = hull.shape if hull != null else null
		var used: bool = (m + 1) < mirrors.size() and shape != null
		PhysicsServer2D.body_set_shape_disabled(rid, slot, not used)
		if used:
			PhysicsServer2D.body_set_shape(rid, slot, shape)
			var local := hull.transform
			local.origin += to_local.basis_xform(mirrors[m + 1])
			PhysicsServer2D.body_set_shape_transform(rid, slot, local)
	PhysicsServer2D.body_set_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM, pose)
	_mirror_stance = stance
	_mirror_pose = pose

func collision_rect() -> Rect2:
	if hulls.size() < 2:
		return Rect2(global_position, Vector2.ZERO)
	var hull := hulls[collision_stance()] as CollisionShape2D
	return (global_transform * hull.transform) * hull.shape.get_rect()

func collision_stance() -> int:
	return 1 if is_squat and not sim_downed else 0

func set_crouched(crouched: bool) -> void:
	if crouched == is_squat:
		return
	is_squat = crouched
	apply_collision_pose()
	if crouched:
		return
	if CollisionWorld.probe_body(_rid, global_transform, Vector2.ZERO, 0.0, true):
		is_squat = true
		apply_collision_pose()

func reset_motion() -> void:
	velocity = Vector2.ZERO
	_grounded = false
	state = STAND
	state_lock_timer = 0.0
	is_squat = false
	cancel_jump_state()
	cancel_charge()
	_last_move_dir = 0
	_last_move_timer = 0.0
	climb_latched = false
	in_water = false
	motion_knock_velocity = Vector2.ZERO
	apply_collision_pose()

func cancel_charge() -> void:
	is_charge = false
	charge_timer = 0.0

func cancel_jump_state() -> void:
	coyote_timer = 0.0
	jump_buffer_timer = 0.0
	jump_cut_applied = false

func update_swim(delta: float, mult: Vector2) -> void:
	var position := global_position
	var feet := Vector2(position.x, maxf(position.y + swim_foot_min, collision_rect().end.y))
	in_water = not _terrain.empty() and _terrain.water(feet)
	if not in_water:
		return
	var tm := _speed_mult
	var target := step_input.axis * swim_speed * mult.x * tm
	velocity.x = MathUtil.approach(velocity.x, target, swim_accel, delta)
	velocity.y = (swim_up if (step_input.held & UP) != 0 else swim_down) * tm

func over_climb_tile() -> bool:
	if _terrain.empty():
		return false
	var position := global_position
	return _terrain.climb_speed(Terrain.texture(_terrain.value(
			_terrain.cell(position + Vector2(0, climb_foot_offset))))) > 0.0 \
		or _terrain.climb_speed(Terrain.texture(_terrain.value(_terrain.cell(position)))) > 0.0

func ladder_top(foot: Vector2i) -> bool:
	var below := _terrain.value(foot + Vector2i(0, 1))
	return below != 0 and _terrain.climb_speed(Terrain.texture(below)) > 0.0

func update_climb(delta: float, mult: Vector2) -> void:
	if not climb_latched and (step_input.pressed & UP) == 0:
		return
	if _terrain.empty() or is_squat:
		climb_latched = false
		return
	var position := global_position
	var foot := _terrain.cell(position + Vector2(0, climb_foot_offset))
	var fv := _terrain.value(foot)
	var cv := _terrain.value(_terrain.cell(position))
	var ft := Terrain.texture(fv)
	var fs := _terrain.climb_speed(ft)
	var cs := _terrain.climb_speed(Terrain.texture(cv))
	var foot_channel := fv != 0 and fs > 0.0
	var center_channel := cv != 0 and cs > 0.0
	if not climb_latched and (center_channel or foot_channel) and (step_input.pressed & UP) != 0:
		climb_latched = true
	if climb_latched and not center_channel and not foot_channel and not ladder_top(foot):
		climb_latched = false
	if not climb_latched:
		return
	var tm := _speed_mult
	if step_input.vertical_axis < 0.0:
		if foot_channel or not ladder_top(foot):
			var speed := climb_speed * maxf(fs, cs) * climb_vertical_mult * mult.y * tm
			velocity.y = step_input.vertical_axis * speed
			return
		if (step_input.pressed & UP) != 0:
			climb_latched = false
			velocity.y = jump_velocity * mult.y
			cancel_jump_state()
			return
		velocity.y = 0.0
		return
	if step_input.vertical_axis > 0.0:
		var descent := _terrain.descent_speed(ft)
		if descent <= 0.0:
			climb_latched = false
			return
		velocity.y = step_input.vertical_axis * climb_speed * descent * climb_vertical_mult * mult.y * tm
		return
	velocity.y = 0.0

func update_waterproof(delta: float, pvp: bool) -> void:
	var submerged := false
	if in_water:
		var breath := global_position + Vector2(0, breath_line_offset)
		submerged = breath.y > _terrain.water_surface(global_position)
	if submerged != _was_submerged:
		_was_submerged = submerged
		_waterproof_timer = 0.0
	_waterproof_timer += delta
	if _waterproof_timer >= (water_drain_interval if submerged else water_recover_interval):
		_waterproof_timer = 0.0
		waterproof = maxi(waterproof - 1, 0) if submerged else mini(waterproof + 1, max_waterproof)
	if waterproof <= 0:
		_waterproof_drown_timer += delta
		if _waterproof_drown_timer >= water_drown_damage_interval:
			_waterproof_drown_timer = 0.0
			if not pvp:
				step_actions.append({"kind": "hit", "pos": global_position, "damage": water_damage})

func impulse(kind: int) -> void:
	step_actions.append({"kind": "impulse", "value": kind})

func update_vertical(delta: float, latched: bool, mult: Vector2) -> void:
	if latched or in_water:
		return
	if _grounded:
		coyote_timer = coyote_time
	else:
		var grav_mult := charge_air_gravity_mult if is_charge else 1.0
		velocity.y += gravity * grav_mult * delta
		coyote_timer = maxf(coyote_timer - delta, 0.0)
	if (step_input.pressed & UP) != 0:
		jump_buffer_timer = jump_buffer_time
	else:
		jump_buffer_timer = maxf(jump_buffer_timer - delta, 0.0)
	if jump_buffer_timer > 0.0 and (_grounded or coyote_timer > 0.0) and not is_squat:
		if is_charge:
			cancel_charge()
		velocity.y = jump_velocity * mult.y
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		jump_cut_applied = false
		impulse(jump_impulse)
	if not jump_cut_applied and (step_input.released & UP) != 0 and velocity.y < 0.0:
		velocity.y *= jump_cut_factor
		jump_cut_applied = true

func update_crouch_dash() -> void:
	if climb_latched or in_water:
		return
	if not _grounded and (step_input.pressed & DOWN) != 0 and not over_climb_tile():
		velocity.y = charge_down_velocity
	var want_squat := _grounded and (step_input.held & DOWN) != 0
	if want_squat and not is_squat:
		is_charge = false
	set_crouched(want_squat)
	if not is_charge and not is_squat and (step_input.pressed & CHARGE) != 0:
		is_charge = true
		charge_timer = charge_duration
		impulse(dash_impulse)
		if _last_move_timer > 0.0:
			facing_direction = _last_move_dir

func update_horizontal(delta: float, mult: Vector2) -> void:
	if in_water:
		return
	if is_charge:
		velocity.x = charge_velocity * facing_direction
		charge_timer -= delta
		if charge_timer <= 0.0:
			is_charge = false
	else:
		var speed := (crouch_walk_speed if is_squat else move_speed) * _speed_mult
		var target := step_input.axis * speed * mult.x
		if step_input.axis != 0.0:
			velocity.x = MathUtil.approach(velocity.x, target, accel_ground if _grounded else accel_air, delta)
		else:
			brake(delta)

func update_facing(delta: float) -> void:
	if not is_charge and step_input.axis != 0.0:
		facing_direction = 1 if step_input.axis > 0.0 else -1
		_last_move_dir = facing_direction
		_last_move_timer = charge_dir_window
	else:
		_last_move_timer = maxf(_last_move_timer - delta, 0.0)

func update_pose(delta: float) -> void:
	var desired := STAND
	if in_water:
		desired = MOVE if absf(velocity.x) > 1.0 else STAND
	elif is_charge:
		desired = DASH
	elif is_squat:
		desired = SQUAT
	elif not _grounded:
		desired = FLY
	elif velocity.x != 0.0:
		desired = MOVE
	if state_lock_timer > 0.0:
		state_lock_timer -= delta
	elif state != desired:
		state = desired
		state_lock_timer = state_lock_time
	apply_collision_pose()

func slide_reactions(incoming: Vector2) -> void:
	if is_charge:
		for contact: Dictionary in motion_contacts:
			# 统一求解后角色接触也会进入列表；只有地形法线才打断冲刺。
			if (PhysicsServer2D.body_get_collision_layer(contact["rid"]) & CollisionWorld.LAYER_TERRAIN) != 0 \
					and absf((contact["normal"] as Vector2).x) > 0.5:
				cancel_charge()
				velocity.x = 0.0
				break
	for contact: Dictionary in motion_contacts:
		var normal: Vector2 = contact["normal"]
		# 地形由物理 RID 承载，碰撞结果不一定关联场景节点。
		var layer := PhysicsServer2D.body_get_collision_layer(contact["rid"])
		if (layer & CollisionWorld.LAYER_TERRAIN) == 0 or incoming.dot(normal) >= 0.0:
			continue
		var point := GridPathfinder.wrap_to_range((contact["point"] as Vector2) - normal, _terrain.size().x, _terrain.size().y)
		if _terrain.elastic_alive(point):
			velocity = velocity.slide(normal) + normal * elastic_bounce
			break

func simulate_motion(delta: float, mult: Vector2, time_mult: float, motion_only: bool,
		pvp: bool, terrain: Terrain) -> void:
	if rewinding:
		return
	if terrain == null or step_input == null:
		push_error("ActorBody: 缺少地形或输入")
		return
	terrain.flush_collisions()
	_terrain = terrain
	if not terrain.empty():
		map_dimensions = terrain.size()
	_speed_mult = time_mult
	motion_contacts.clear()
	if sim_downed:
		_pre_move_vy = 0.0
		if _grounded:
			coyote_timer = coyote_time
		else:
			velocity.y += gravity * delta
		brake(delta)
		move_actor(delta)
		wrap_position()
		sync_collision_geometry()
		return
	update_swim(delta, mult)
	if not motion_only:
		update_waterproof(delta, pvp)
	if not in_water:
		update_climb(delta, mult)
	else:
		is_charge = false
		is_squat = false
	var latched := not in_water and climb_latched
	update_vertical(delta, latched, mult)
	update_crouch_dash()
	update_horizontal(delta, mult)
	update_facing(delta)
	update_pose(delta)
	_pre_move_vy = 0.0 if (in_water or latched) else velocity.y
	var incoming := velocity + motion_knock_velocity
	move_actor(delta)
	slide_reactions(incoming)
	wrap_position()
	sync_collision_geometry()

func step_actor(delta: float, time_mult: float, pvp: bool, terrain: Terrain) -> void:
	var started := PerformanceStats.begin()
	if rewinding:
		PerformanceStats.end(PerformanceStats.ACTOR_STEP, started)
		return
	var weapon := active_weapon()
	if not sim_downed:
		sim_iframes = maxf(sim_iframes - delta, 0.0)
		if weapon != null:
			if step_input != null and (step_input.pressed & 16) != 0:
				weapon.start_reload()
			weapon.tick_weapon(delta * time_mult)
	var mult := weapon.get_movement_multiplier() if weapon != null and not sim_downed else Vector2.ONE
	simulate_motion(delta, mult, time_mult, false, pvp, terrain)
	PerformanceStats.end(PerformanceStats.ACTOR_STEP, started)

# 武器与视觉根节点直接持有引用：模拟只读写同一份状态，不用 instance_from_id 中转。
var simulation_weapon: Node2D:
	get: return _weapon
	set(value): _weapon = value

func active_weapon() -> WeaponBody:
	return _weapon as WeaponBody

var simulation_visuals: Node2D:
	get: return _visual
	set(value): _visual = value

func shot_origin(muzzle: Node2D) -> Vector2:
	if _visual == null:
		return muzzle.global_position
	return muzzle.global_position - (_visual.global_position - global_position)

func bind_prediction_projectiles(entries: Dictionary) -> void:
	_prediction_projectiles = entries
	_prediction_registry_bound = true

func has_prediction_registry() -> bool:
	return _prediction_registry_bound

func count_prediction_projectiles(type: int) -> int:
	var count := 0
	for id in _prediction_projectiles.keys():
		var entry := _prediction_projectiles[id] as ProjectileEntry
		var bullet := entry.get_bullet() if entry != null else null
		if bullet != null and (int(id) >> 48) == role and bullet.type_id == type \
				and entry.active and entry.tick < combat_tick and not bullet.finished:
			count += 1
	return count

func apply_recoil(push: float) -> void:
	if is_squat:
		return
	if climb_latched:
		push *= climb_recoil_mult
	var v := velocity
	v.x -= facing_direction * push
	velocity = v

func apply_impulse(source: Vector2, force: float) -> void:
	var position := global_position
	var away := position - source
	if map_dimensions.x > 0.0 and map_dimensions.y > 0.0:
		away = GridPathfinder.toroidal_delta_px(source, position, map_dimensions.x, map_dimensions.y)
	if away.is_zero_approx():
		away = Vector2(-float(facing_direction), 0.0)
	else:
		away = away.normalized()
	if force < 0.0:
		velocity = Vector2(away.x * hit_knockback, away.y * hit_knockback - hit_knockback_up)
	else:
		motion_knock_velocity = away * force

func force_down() -> bool:
	if sim_downed:
		return false
	sim_downed = true
	rotation = -PI / 2.0 * facing_direction
	_grounded = false
	apply_collision_pose()
	var weapon := active_weapon()
	if weapon != null:
		weapon.cancel_aim()
	return true

func simulate_hit(source: Vector2, damage: int, force: float) -> bool:
	cancel_charge()
	sim_hp -= damage
	sim_iframes = hit_iframes
	apply_impulse(source, force)
	return sim_hp <= 0 and force_down()

func apply_authoritative_state(hp: int, wp: int, down: bool) -> void:
	sim_hp = hp
	waterproof = wp
	sim_downed = down
	rotation = -PI / 2.0 * facing_direction if down else 0.0
	apply_collision_pose()

func capture_prediction_prefix(instance: int, inventory: PackedInt32Array) -> Array:
	var values: Array = []
	append_motion_state(values)
	values.append_array([shot_serial, _waterproof_timer, _was_submerged, _waterproof_drown_timer,
		sim_iframes, _controls_locked, instance, inventory, state, waterproof, sim_hp, sim_downed])
	return values

func capture_prediction_state(instance: int, inventory: PackedInt32Array) -> Array:
	var values := capture_prediction_prefix(instance, inventory)
	var weapon := active_weapon()
	if weapon != null:
		weapon.append_prediction_state(values)
	else:
		values.append_array(WeaponBody.idle_state())
	assert(values.size() == PlayerStateSchema.SIZE, "预测状态字段数与 PlayerStateSchema 不一致")
	return values

func restore_logic_state(values: Array) -> void:
	restore_motion_state(values, int(values[PlayerStateSchema.slot("state")]))
	_controls_locked = values[PlayerStateSchema.slot("locked")]
	shot_serial = int(values[PlayerStateSchema.slot("shot_serial")])
	apply_authoritative_state(int(values[PlayerStateSchema.slot("hp")]), int(values[PlayerStateSchema.slot("wp")]),
			bool(values[PlayerStateSchema.slot("down")]))
	sim_iframes = float(values[PlayerStateSchema.slot("ifr")])
	_waterproof_timer = float(values[PlayerStateSchema.slot("wp_t")])
	_was_submerged = bool(values[PlayerStateSchema.slot("wp_s")])
	_waterproof_drown_timer = float(values[PlayerStateSchema.slot("wp_d")])

func append_motion_state(values: Array) -> void:
	values.append_array([global_position, _grounded, pvp_haste_mult, velocity,
		facing_direction, state_lock_timer, coyote_timer, jump_buffer_timer,
		jump_cut_applied, is_squat, is_charge, charge_timer,
		_last_move_dir, _last_move_timer, climb_latched, in_water,
		motion_knock_velocity])

func capture_motion_state() -> Array:
	var values: Array = []
	append_motion_state(values)
	return values

# 运动前缀与姿态分开传入，本地完整状态和远端运动状态共用同一恢复规则。
func restore_motion_state(values: Array, pose: int) -> void:
	global_position = values[0]
	_grounded = bool(values[1])
	pvp_haste_mult = float(values[2])
	velocity = values[3]
	facing_direction = int(values[4])
	state_lock_timer = float(values[5])
	coyote_timer = float(values[6])
	jump_buffer_timer = float(values[7])
	jump_cut_applied = bool(values[8])
	is_squat = bool(values[9])
	is_charge = bool(values[10])
	charge_timer = float(values[11])
	_last_move_dir = int(values[12])
	_last_move_timer = float(values[13])
	climb_latched = bool(values[14])
	in_water = bool(values[15])
	motion_knock_velocity = values[16]
	state = pose
	apply_collision_pose()
