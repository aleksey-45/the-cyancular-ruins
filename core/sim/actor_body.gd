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

var gravity := GameParameters.gravity0
var coyote_timer := 0.0
var jump_buffer_timer := 0.0
var charge_timer := 0.0
var _last_move_timer := 0.0
var _pre_move_vy := 0.0
var state_lock_timer := 0.0
var _waterproof_timer := 0.0
var _waterproof_drown_timer := 0.0
var sim_iframes := 0.0
var rewinding := false
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
var waterproof := PlayerParams.player_waterproof_max
var max_waterproof := PlayerParams.player_waterproof_max
var sim_hp := PlayerParams.player_max_hp
var sim_max_hp := PlayerParams.player_max_hp
var pvp_haste_mult := 1.0
var facing_direction := 1
var _last_move_dir := 1
var motion_knock_velocity := Vector2.ZERO
var projectile_count: Callable

var step_input := ActorInput.new()
# 拥有本角色模拟权威的环境（AuthorityWorld）；null = 无权威环境（单机本地/纯预测体）。
var authority_world: Node
@onready var _hulls: Array[CollisionShape2D] = [$CollisionShape2D_stand, $CollisionShape2D_squat]
# 本 tick 的运动接触：{"rid", "normal", "point"}；result 对象是复用的，出结果立即抄值。
var motion_contacts: Array = []
var step_actions: Array = []

var _speed_mult := 1.0
var equipped: GunBody
# 原 CharacterBody2D 的内建字段改为普通数据。
var velocity := Vector2.ZERO
var floor_snap_length := 1.0
var safe_margin := 0.08
# 本体与最多三个接缝副本。
const COLLISION_SLOTS := 4
static var _step_motion := PhysicsTestMotionResult2D.new()


func _ready() -> void:
	var shape := _hulls[0].shape
	for slot in COLLISION_SLOTS:
		PhysicsServer2D.body_add_shape(_rid, shape, Transform2D.IDENTITY, true)
	sync_collision_geometry()

# 地形与角色阻挡共用同一条 CollisionWorld.move_body() 路径；掩码决定谁挡路（队友不在掩码内即穿透）。
func move_by_internal(motion: Vector2) -> Vector2:
	var blocked := Vector2.ZERO
	var step_ready := _step_up_ready() and motion.y >= 0.0
	for axis in 2:
		var distance := motion[axis]
		if distance == 0.0:
			continue
		var start := global_transform
		var travel := Vector2.ZERO
		travel[axis] = distance
		if axis == 0 and step_ready and signf(distance) == signf(step_input.axis) \
				and CollisionWorld.probe_body(_rid, start, travel, safe_margin) \
				and _try_step_up(distance, start):
			blocked.y = 1.0
			continue
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

## 仅着地、正常水平输入、未处于冲刺/蹲伏/攀爬/游泳时启用自动上台阶。
func _step_up_ready() -> bool:
	if not _grounded or sim_downed or is_charge or is_squat or climb_latched or in_water or rewinding:
		return false
	if PlayerParams.step_max_height <= 0.0 or step_input.axis == 0.0:
		return false
	return true

## 每段用物理查询返回的实际位移接续下一段，最后把有效落脚位置一次提交给节点和 RID。
func _try_step_up(distance: float, start: Transform2D) -> bool:
	for step in floori((PlayerParams.step_max_height + 0.001) / 16.0):
		var height := (step + 1) * 16.0
		var pose := start
		if CollisionWorld.probe_body(_rid, pose, Vector2(0.0, -height), safe_margin, true, _step_motion):
			continue
		pose.origin += _step_motion.get_travel()
		if CollisionWorld.probe_body(_rid, pose, Vector2(distance, 0.0), safe_margin, true, _step_motion):
			continue
		pose.origin += _step_motion.get_travel()
		if not CollisionWorld.probe_body(_rid, pose, Vector2(0.0, height + 1.0), safe_margin, false, _step_motion):
			continue
		var normal := _step_motion.get_collision_normal()
		if normal.y >= -0.5:
			continue
		pose.origin += _step_motion.get_travel()
		motion_contacts.append({"rid": _step_motion.get_collider_rid(),
				"normal": normal, "point": _step_motion.get_collision_point()})
		global_position = pose.origin
		CollisionWorld.sync_body_pose(_rid, pose)
		return true
	return false

func _move_actor(delta: float) -> void:
	var incoming := velocity + motion_knock_velocity
	var motion := incoming * delta
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
	motion_knock_velocity *= exp(-PlayerParams.player_knock_decay_rate * delta)
	if not sim_downed:
		slide_reactions(incoming)
	var size := terrain.map_size
	global_position = GridPathfinder.wrap_to_range(global_position, size)
	sync_collision_geometry()

func brake(delta: float) -> void:
	velocity.x = MathUtil.approach(velocity.x, 0.0, PlayerParams.brake_ground if _grounded else PlayerParams.brake_air, delta)
	if absf(velocity.x) < PlayerParams.stop_snap:
		velocity.x = 0.0

## 偏移首项为本体的零偏移，副本的世界偏移换算到物理体局部坐标。
## 写入形状后重设体变换，使同帧查询能立即读到碰撞。
func sync_collision_geometry() -> void:
	var hull := _active_hull()
	var shape := hull.shape
	var pose := global_transform
	var to_local := pose.affine_inverse()
	var offsets := _physics.mirror_offsets(pose.origin)
	for slot in COLLISION_SLOTS:
		var used := slot < offsets.size()
		if used:
			var local := hull.transform
			local.origin += to_local.basis_xform(offsets[slot])
			PhysicsServer2D.body_set_shape(_rid, slot, shape)
			PhysicsServer2D.body_set_shape_transform(_rid, slot, local)
		PhysicsServer2D.body_set_shape_disabled(_rid, slot, not used)
	PhysicsServer2D.body_set_state(_rid, PhysicsServer2D.BODY_STATE_TRANSFORM, pose)

func collision_rect() -> Rect2:
	var hull := _active_hull()
	return (global_transform * hull.transform) * hull.shape.get_rect()

func _active_hull() -> CollisionShape2D:
	return _hulls[1 if is_squat and not sim_downed else 0]

func set_crouched(crouched: bool) -> void:
	if crouched == is_squat:
		return
	is_squat = crouched
	sync_collision_geometry()
	if crouched:
		return
	if CollisionWorld.probe_body(_rid, global_transform, Vector2.ZERO, 0.0, true):
		is_squat = true
		sync_collision_geometry()

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
	_was_submerged = false
	_waterproof_timer = 0.0
	_waterproof_drown_timer = 0.0
	motion_knock_velocity = Vector2.ZERO

func cancel_charge() -> void:
	is_charge = false
	charge_timer = 0.0

func cancel_jump_state() -> void:
	coyote_timer = 0.0
	jump_buffer_timer = 0.0
	jump_cut_applied = false

func update_swim(delta: float, mult: Vector2) -> void:
	var tm := _speed_mult
	var target := step_input.axis * PlayerParams.player_swim_speed * mult.x * tm
	velocity.x = MathUtil.approach(velocity.x, target, PlayerParams.player_swim_accel, delta)
	velocity.y = (PlayerParams.player_swim_up if (step_input.held & ActorInput.BIT_UP) != 0 else PlayerParams.player_swim_down) * tm

func over_climb_tile() -> bool:
	if terrain.empty():
		return false
	var position := global_position
	return terrain.climb_speed(Terrain.texture(terrain.value(
			terrain.cell(position + Vector2(0, PlayerParams.climb_foot_offset))))) > 0.0 \
		or terrain.climb_speed(Terrain.texture(terrain.value(terrain.cell(position)))) > 0.0

func ladder_top(foot: Vector2i) -> bool:
	var below := terrain.value(foot + Vector2i(0, 1))
	return below != 0 and terrain.climb_speed(Terrain.texture(below)) > 0.0

func update_climb(delta: float, mult: Vector2) -> void:
	if not climb_latched and (step_input.pressed & ActorInput.BIT_UP) == 0:
		return
	if terrain.empty() or is_squat:
		climb_latched = false
		return
	var position := global_position
	var foot := terrain.cell(position + Vector2(0, PlayerParams.climb_foot_offset))
	var fv := terrain.value(foot)
	var cv := terrain.value(terrain.cell(position))
	var ft := Terrain.texture(fv)
	var fs := terrain.climb_speed(ft)
	var cs := terrain.climb_speed(Terrain.texture(cv))
	var foot_channel := fv != 0 and fs > 0.0
	var center_channel := cv != 0 and cs > 0.0
	if not climb_latched and (center_channel or foot_channel) and (step_input.pressed & ActorInput.BIT_UP) != 0:
		climb_latched = true
	if climb_latched and not center_channel and not foot_channel and not ladder_top(foot):
		climb_latched = false
	if not climb_latched:
		return
	var tm := _speed_mult
	if step_input.vertical_axis < 0.0:
		if foot_channel or not ladder_top(foot):
			var speed := PlayerParams.climb_speed * maxf(fs, cs) * PlayerParams.climb_vertical_mult * mult.y * tm
			velocity.y = step_input.vertical_axis * speed
			return
		if (step_input.pressed & ActorInput.BIT_UP) != 0:
			climb_latched = false
			velocity.y = PlayerParams.jump_velocity * mult.y
			cancel_jump_state()
			return
		velocity.y = 0.0
		return
	if step_input.vertical_axis > 0.0:
		var descent := terrain.descent_speed(ft)
		if descent <= 0.0:
			climb_latched = false
			return
		velocity.y = step_input.vertical_axis * PlayerParams.climb_speed * descent * PlayerParams.climb_vertical_mult * mult.y * tm
		return
	velocity.y = 0.0

func update_waterproof(delta: float, submerged: bool) -> void:
	if submerged != _was_submerged:
		_was_submerged = submerged
		_waterproof_timer = 0.0
	if submerged and waterproof == 0:
		_waterproof_drown_timer += delta
		if _waterproof_drown_timer >= GameParameters.water_drown_damage_interval:
			_waterproof_drown_timer = 0.0
			step_actions.append({"kind": "drown", "pos": global_position, "damage": PlayerParams.player_waterproof_damage})
		return
	_waterproof_drown_timer = 0.0
	_waterproof_timer += delta
	if _waterproof_timer >= (GameParameters.water_drain_interval if submerged else GameParameters.water_recover_interval):
		_waterproof_timer = 0.0
		waterproof = maxi(waterproof - 1, 0) if submerged else mini(waterproof + 1, max_waterproof)

func impulse(kind: int) -> void:
	step_actions.append({"kind": "impulse", "value": kind})

func update_vertical(delta: float, latched: bool, mult: Vector2) -> void:
	if latched or in_water:
		return
	if _grounded:
		coyote_timer = PlayerParams.coyote_time
	else:
		var grav_mult := PlayerParams.charge_air_gravity_mult if is_charge else 1.0
		velocity.y += gravity * grav_mult * delta
		coyote_timer = maxf(coyote_timer - delta, 0.0)
	if (step_input.pressed & ActorInput.BIT_UP) != 0:
		jump_buffer_timer = PlayerParams.jump_buffer_time
	else:
		jump_buffer_timer = maxf(jump_buffer_timer - delta, 0.0)
	if jump_buffer_timer > 0.0 and (_grounded or coyote_timer > 0.0) and not is_squat:
		if is_charge:
			cancel_charge()
		velocity.y = PlayerParams.jump_velocity * mult.y
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		jump_cut_applied = false
		impulse(SquashStretch.Impulse.JUMP)
	if not jump_cut_applied and (step_input.released & ActorInput.BIT_UP) != 0 and velocity.y < 0.0:
		velocity.y *= PlayerParams.jump_cut_factor
		jump_cut_applied = true

func update_crouch_dash() -> void:
	if climb_latched or in_water:
		return
	if not _grounded and (step_input.pressed & ActorInput.BIT_DOWN) != 0 and not over_climb_tile():
		velocity.y = PlayerParams.charge_down_velocity
	var want_squat := _grounded and (step_input.held & ActorInput.BIT_DOWN) != 0
	if want_squat and not is_squat:
		is_charge = false
	set_crouched(want_squat)
	if not is_charge and not is_squat and (step_input.pressed & ActorInput.BIT_CHARGE) != 0:
		is_charge = true
		charge_timer = PlayerParams.charge_duration
		impulse(SquashStretch.Impulse.DASH)
		if _last_move_timer > 0.0:
			facing_direction = _last_move_dir

func update_horizontal(delta: float, mult: Vector2) -> void:
	if in_water:
		return
	if is_charge:
		velocity.x = PlayerParams.charge_velocity * facing_direction
		charge_timer -= delta
		if charge_timer <= 0.0:
			is_charge = false
	else:
		var speed := (PlayerParams.crouch_walk_speed if is_squat else PlayerParams.move_speed) * _speed_mult
		var target := step_input.axis * speed * mult.x
		if step_input.axis != 0.0:
			velocity.x = MathUtil.approach(velocity.x, target, PlayerParams.accel_ground if _grounded else PlayerParams.accel_air, delta)
		else:
			brake(delta)

func update_facing(delta: float) -> void:
	if not is_charge and step_input.axis != 0.0:
		facing_direction = 1 if step_input.axis > 0.0 else -1
		_last_move_dir = facing_direction
		_last_move_timer = PlayerParams.charge_dir_window
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
		state_lock_timer = STATE_LOCK_TIME

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
		var point := GridPathfinder.wrap_to_range((contact["point"] as Vector2) - normal, terrain.map_size)
		if terrain.elastic_alive(point):
			velocity = velocity.slide(normal) + normal * PlayerParams.elastic_bounce
			break

func _simulate_motion(delta: float, mult: Vector2, time_mult: float) -> void:
	_speed_mult = time_mult
	motion_contacts.clear()
	if sim_downed:
		_pre_move_vy = 0.0
		if _grounded:
			coyote_timer = PlayerParams.coyote_time
		else:
			velocity.y += gravity * delta
		brake(delta)
		_move_actor(delta)
		return
	var bounds := collision_rect()
	in_water = Water.swim_depth(terrain, Water.feet(bounds), in_water) != -INF
	if not _controls_locked:
		update_waterproof(delta, Water.head_submerged(terrain, bounds))
	if in_water:
		update_swim(delta, mult)
		is_charge = false
		if is_squat:
			is_squat = false
			sync_collision_geometry()
	else:
		update_climb(delta, mult)
	var latched := not in_water and climb_latched
	update_vertical(delta, latched, mult)
	update_crouch_dash()
	update_horizontal(delta, mult)
	update_facing(delta)
	update_pose(delta)
	_pre_move_vy = 0.0 if (in_water or latched) else velocity.y
	_move_actor(delta)

func step_actor(delta: float, time_mult: float) -> void:
	var started := PerformanceStats.begin()
	var mult := Vector2.ONE
	if not sim_downed:
		sim_iframes = maxf(sim_iframes - delta, 0.0)
		if equipped != null:
			mult = equipped.step(self, step_input, delta * time_mult)
	_simulate_motion(delta, mult, time_mult)
	PerformanceStats.end(PerformanceStats.ACTOR_STEP, started)

func apply_recoil(push: float) -> void:
	if is_squat:
		return
	if climb_latched:
		push *= PlayerParams.climb_recoil_mult
	var v := velocity
	v.x -= facing_direction * push
	velocity = v

func apply_impulse(source: Vector2, force: float) -> void:
	var position := global_position
	var away := position - source
	if terrain != null:
		away = GridPathfinder.toroidal_delta_px(source, position, terrain.map_size)
	if away.is_zero_approx():
		away = Vector2(-float(facing_direction), 0.0)
	else:
		away = away.normalized()
	if force < 0.0:
		velocity = Vector2(away.x * PlayerParams.player_hit_knockback, away.y * PlayerParams.player_hit_knockback - PlayerParams.player_hit_knockback_up)
	else:
		motion_knock_velocity = away * force

func force_down() -> bool:
	if sim_downed:
		return false
	sim_downed = true
	rotation = -PI / 2.0 * facing_direction
	_grounded = false
	sync_collision_geometry()
	if equipped != null:
		equipped.cancel_aim()
	return true

func simulate_hit(source: Vector2, damage: int, force: float) -> bool:
	cancel_charge()
	sim_hp -= damage
	sim_iframes = PlayerParams.iframes_time
	if force != 0.0:
		apply_impulse(source, force)
	return sim_hp <= 0 and force_down()

func apply_authoritative_state(hp: int, wp: int, down: bool) -> void:
	sim_hp = hp
	waterproof = wp
	sim_downed = down
	rotation = -PI / 2.0 * facing_direction if down else 0.0
	sync_collision_geometry()

func capture_actor_state(instance: int, inventory: PackedInt32Array) -> Array:
	var values: Array = []
	values.resize(PlayerStateSchema.SIZE)
	values[PlayerStateSchema.POS] = global_position
	values[PlayerStateSchema.GROUNDED] = _grounded
	values[PlayerStateSchema.HASTE_MULT] = pvp_haste_mult
	values[PlayerStateSchema.VEL] = velocity
	values[PlayerStateSchema.FACING] = facing_direction
	values[PlayerStateSchema.STATE_LOCK_TIMER] = state_lock_timer
	values[PlayerStateSchema.COYOTE_TIMER] = coyote_timer
	values[PlayerStateSchema.JUMP_BUFFER_TIMER] = jump_buffer_timer
	values[PlayerStateSchema.JUMP_CUT_APPLIED] = jump_cut_applied
	values[PlayerStateSchema.SQUAT] = is_squat
	values[PlayerStateSchema.CHARGE] = is_charge
	values[PlayerStateSchema.CHARGE_TIMER] = charge_timer
	values[PlayerStateSchema.LAST_MOVE_DIR] = _last_move_dir
	values[PlayerStateSchema.LAST_MOVE_TIMER] = _last_move_timer
	values[PlayerStateSchema.CLIMB_LATCHED] = climb_latched
	values[PlayerStateSchema.IN_WATER] = in_water
	values[PlayerStateSchema.KNOCK_VEL] = motion_knock_velocity
	values[PlayerStateSchema.SHOT_SERIAL] = shot_serial
	values[PlayerStateSchema.WATERPROOF_TIMER] = _waterproof_timer
	values[PlayerStateSchema.WAS_SUBMERGED] = _was_submerged
	values[PlayerStateSchema.DROWN_TIMER] = _waterproof_drown_timer
	values[PlayerStateSchema.IFRAMES] = sim_iframes
	values[PlayerStateSchema.CONTROLS_LOCKED] = _controls_locked
	values[PlayerStateSchema.WEAPON_INST] = instance
	values[PlayerStateSchema.INVENTORY] = inventory
	values[PlayerStateSchema.STATE] = state
	values[PlayerStateSchema.WATERPROOF] = waterproof
	values[PlayerStateSchema.HP] = sim_hp
	values[PlayerStateSchema.DOWNED] = sim_downed
	return values

func restore_logic_state(values: Array) -> void:
	global_position = values[PlayerStateSchema.POS]
	_grounded = values[PlayerStateSchema.GROUNDED]
	pvp_haste_mult = values[PlayerStateSchema.HASTE_MULT]
	velocity = values[PlayerStateSchema.VEL]
	facing_direction = values[PlayerStateSchema.FACING]
	state_lock_timer = values[PlayerStateSchema.STATE_LOCK_TIMER]
	coyote_timer = values[PlayerStateSchema.COYOTE_TIMER]
	jump_buffer_timer = values[PlayerStateSchema.JUMP_BUFFER_TIMER]
	jump_cut_applied = values[PlayerStateSchema.JUMP_CUT_APPLIED]
	is_squat = values[PlayerStateSchema.SQUAT]
	is_charge = values[PlayerStateSchema.CHARGE]
	charge_timer = values[PlayerStateSchema.CHARGE_TIMER]
	_last_move_dir = values[PlayerStateSchema.LAST_MOVE_DIR]
	_last_move_timer = values[PlayerStateSchema.LAST_MOVE_TIMER]
	climb_latched = values[PlayerStateSchema.CLIMB_LATCHED]
	in_water = values[PlayerStateSchema.IN_WATER]
	motion_knock_velocity = values[PlayerStateSchema.KNOCK_VEL]
	state = values[PlayerStateSchema.STATE]
	_controls_locked = values[PlayerStateSchema.CONTROLS_LOCKED]
	shot_serial = values[PlayerStateSchema.SHOT_SERIAL]
	apply_authoritative_state(values[PlayerStateSchema.HP], values[PlayerStateSchema.WATERPROOF],
			values[PlayerStateSchema.DOWNED])
	sim_iframes = values[PlayerStateSchema.IFRAMES]
	_waterproof_timer = values[PlayerStateSchema.WATERPROOF_TIMER]
	_was_submerged = values[PlayerStateSchema.WAS_SUBMERGED]
	_waterproof_drown_timer = values[PlayerStateSchema.DROWN_TIMER]
