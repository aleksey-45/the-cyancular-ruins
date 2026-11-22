class_name Player
extends ActorBody

const WCFG: WorldConfig = preload("res://core/config/world_config.tres")

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

# 玩家在固定模拟帧内处理移动、武器与生命状态。

const STATE_LOCK_TIME := 0.15
const STAND := 0
const MOVE := 1
const FLY := 2
const DASH := 3
const SQUAT := 4

var gravity := WCFG.gravity0
var coyote_timer := 0.0
var jump_buffer_timer := 0.0
var charge_timer := 0.0
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
var waterproof := CFG.player_waterproof_max
var max_waterproof := CFG.player_waterproof_max
var sim_hp := CFG.player_max_hp
var sim_max_hp := CFG.player_max_hp
var personal_haste_mult := 1.0
var facing_direction := 1
var motion_knock_velocity := Vector2.ZERO

var step_input := ActorInput.new()
var combat_requests: Array = []
var presentation_events: Array = []

var _speed_mult := 1.0
var _auto_jump_frame := false
var _auto_jump_timer := 0.0
var weapons := WeaponInventory.new()
var equipped: GunBody:
	get: return weapons.equipped
# 最多容纳四个碰撞形状，一个用于原位置，其余用于地图边缘和角落。
const COLLISION_SLOTS := 4
static var _axis_motion := PhysicsTestMotionResult2D.new()
static var _step_motion := PhysicsTestMotionResult2D.new()

const NetPlayer := PlayerStateSchema.Network

var input_buffer := InputBuffer.new()
var respawn_tick := 0
var last_attacker := 0
var last_hit_tick := 0

func _init(match_sim: CombatSimulator, player_role: int) -> void:
	role = player_role
	var shape := CollisionWorld.rectangle(CFG.standing_hull.size)
	super(match_sim, Vector2.ZERO, CFG.body_scale, shape, CollisionWorld.LAYER_TEAM_A,
			CollisionWorld.LAYER_TERRAIN)
	weapons.feedback.connect(_weapon_feedback)
	for slot in range(1, COLLISION_SLOTS):
		PhysicsServer2D.body_add_shape(rid, shape, Transform2D.IDENTITY, true)
	sync_collision_geometry()

func _weapon_feedback(kind: String) -> void:
	presentation_events.append({"kind": kind})

func set_team_collision(side: int, player_collision: bool) -> void:
	team = side
	collision_layer = CollisionWorld.team_layer(team)
	collision_mask = CollisionWorld.LAYER_TERRAIN
	if player_collision:
		collision_mask |= CollisionWorld.team_layer(3 - team)

func move_by_internal(motion: Vector2) -> Vector2:
	var blocked := Vector2.ZERO
	for axis in 2:
		var distance := motion[axis]
		if distance == 0.0:
			continue
		var start := transform
		var travel := Vector2.ZERO
		travel[axis] = distance
		if CollisionWorld.probe_body(rid, start, travel, _axis_motion):
			if CollisionWorld.axis_blocked(_axis_motion, axis, distance):
				if axis == 0 and motion.y >= 0.0 and _try_step_up(start, travel):
					return Vector2.DOWN
				blocked[axis] = signf(distance)
			_record_contact(_axis_motion)
		start.origin += _axis_motion.get_travel()
		position = start.origin
	return blocked

func _try_step_up(start: Transform2D, travel: Vector2) -> bool:
	var direction := signf(travel.x)
	var wall := _axis_motion.get_collider_rid()
	if not _grounded or sim_downed or is_charge or is_squat or climb_latched or in_water or rewinding \
			or direction != signf(step_input.axis) or _axis_motion.get_collision_normal().x * direction >= -0.5 \
			or PhysicsServer2D.body_get_collision_layer(wall) != CollisionWorld.LAYER_TERRAIN:
		return false
	var margin := CollisionWorld.MOTION_MARGIN
	var foot := collision_rect().end.y
	var edge := _axis_motion.get_collision_point().x + direction * margin
	# 射线要从墙壁内侧向下检测，才能找到台阶上表面。墙太高时，射线从墙内发出，无法找到可站立的表面。
	var hit := terrain.physics.ray_hit(Vector2(edge, foot - CFG.step_max_height - margin),
			Vector2(edge, foot), CollisionWorld.LAYER_TERRAIN, true)
	if hit.is_empty() or hit["normal"] != Vector2.UP:
		return false
	var height := foot - (hit["position"] as Vector2).y
	if height <= margin \
			or CollisionWorld.probe_body(rid, start, Vector2.UP * (height + margin), _step_motion):
		return false
	var pose := start
	pose.origin += _step_motion.get_travel()
	# 先在抬高后的位置检测横向移动，再检测下方是否有可站立的地面。两项检测都通过才使用上台阶的移动结果。
	if CollisionWorld.probe_body(rid, pose, travel, _step_motion) \
			and PhysicsServer2D.body_get_collision_layer(_step_motion.get_collider_rid()) != CollisionWorld.LAYER_TERRAIN:
		return false
	pose.origin += _step_motion.get_travel()
	var drop := start.origin.y - pose.origin.y + 1.0
	if not CollisionWorld.probe_body(rid, pose, Vector2.DOWN * drop, _step_motion) \
			or _step_motion.get_collision_normal().y >= -0.5 \
			or PhysicsServer2D.body_get_collision_layer(_step_motion.get_collider_rid()) != CollisionWorld.LAYER_TERRAIN:
		return false
	pose.origin += _step_motion.get_travel()
	var rise := start.origin.y - pose.origin.y
	if rise <= margin or rise > CFG.step_max_height + margin \
			or (pose.origin.x - start.origin.x - _axis_motion.get_travel().x) * direction <= 0.001:
		return false
	# 与 main 一致:≤32px 抬上去;48/64px 按台阶高度自动跳,而不是瞬移。
	if rise > 32.0 + margin:
		velocity.y = -sqrt(2.0 * maxf(gravity, 1.0) * (rise + 6.0))
		velocity.x = step_input.axis * CFG.move_speed * _speed_mult
		_auto_jump_frame = true
		_auto_jump_timer = 0.35
		jump_cut_applied = true
		return false
	_record_contact(_step_motion)
	position = pose.origin
	return true

func _try_ledge_nudge() -> void:
	# 对齐 main:跳跃/下落贴着台沿时,脚底以 ≤1 个子格卡在台沿竖直面/顶面,向上挤出来。
	if absf(step_input.axis) < 0.01:
		return
	var dir := 1 if step_input.axis > 0.0 else -1
	var bounds := collision_rect()
	var feet_y := bounds.end.y
	var x_px := bounds.get_center().x + dir * (bounds.size.x * 0.5 + 1.0)
	var col := int(floor(x_px / Terrain.SUB_SIZE))
	var feet_sub := int(floor(feet_y / Terrain.SUB_SIZE))
	for k in range(0, 2):
		var row := feet_sub - k
		var tex := terrain.sub_texture(Vector2i(col, row))
		if tex == 0 or TileDefs.type_id_of(tex) != TileDefs.TYPE_WALL:
			continue
		var dy := feet_y - float(row) * Terrain.SUB_SIZE
		if dy <= 0.0 or dy > 16.0:
			continue
		if _sub_solid(col, row - 1) or _sub_solid(col, row - 2):
			return
		position.y -= dy + 1.0
		velocity.y = minf(velocity.y, 0.0)
		return

func _sub_solid(col: int, row: int) -> bool:
	var tex := terrain.sub_texture(Vector2i(col, row))
	return tex != 0 and TileDefs.type_id_of(tex) == TileDefs.TYPE_WALL

func _move_actor(delta: float) -> void:
	motion_contacts.clear()
	var incoming := velocity + motion_knock_velocity
	var motion := incoming * delta
	if _grounded and motion.y >= 0.0:
		motion.y = maxf(motion.y, 1.0)
	var blocked := move_by_internal(motion)
	if blocked.y > 0.0 and not _grounded and incoming.y > 0.0:
		presentation_events.append({"kind": "land", "speed": incoming.y})
	_grounded = blocked.y > 0.0 and not _auto_jump_frame
	if blocked.x != 0.0 and not _auto_jump_frame and _auto_jump_timer <= 0.0:
		velocity.x = 0.0
		motion_knock_velocity.x = 0.0
		cancel_charge()
	if blocked.y != 0.0 and not _auto_jump_frame:
		velocity.y = 0.0
		motion_knock_velocity.y = 0.0
	_auto_jump_frame = false
	_auto_jump_timer = maxf(_auto_jump_timer - delta, 0.0)
	if blocked.x != 0.0 and not _grounded and not in_water and not climb_latched:
		_try_ledge_nudge()
	motion_knock_velocity *= exp(-CFG.player_knock_decay_rate * delta)
	if not sim_downed:
		slide_reactions(incoming)
	var size := terrain.map_size
	position = GridPathfinder.wrap_to_range(position, size)
	sync_collision_geometry()

func brake(delta: float) -> void:
	velocity.x = MathUtil.approach(velocity.x, 0.0, CFG.brake_ground if _grounded else CFG.brake_air, delta)
	if absf(velocity.x) < CFG.stop_snap:
		velocity.x = 0.0

## 在地图另一侧设置碰撞形状时，需要把世界坐标偏移转换成物理体的局部坐标。
## 更新形状后再同步物理体变换，让同一帧的碰撞查询就能看到新形状。
func sync_collision_geometry() -> void:
	var hull := _active_hull()
	var shape := CollisionWorld.rectangle(hull.size)
	var pose := transform
	var to_local := pose.affine_inverse()
	var offsets := terrain.physics.mirror_offsets(pose.origin)
	for slot in COLLISION_SLOTS:
		var used := slot < offsets.size()
		if used:
			var local := Transform2D(0.0, hull.get_center() + to_local.basis_xform(offsets[slot]))
			PhysicsServer2D.body_set_shape(rid, slot, shape)
			PhysicsServer2D.body_set_shape_transform(rid, slot, local)
		PhysicsServer2D.body_set_shape_disabled(rid, slot, not used)
	PhysicsServer2D.body_set_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM, pose)

func collision_rect() -> Rect2:
	return transform * _active_hull()

func _active_hull() -> Rect2:
	return CFG.crouched_hull if is_squat or sim_downed else CFG.standing_hull

func set_crouched(crouched: bool) -> void:
	if crouched == is_squat:
		return
	is_squat = crouched
	sync_collision_geometry()
	if crouched:
		return
	if CollisionWorld.probe_body(rid, transform, Vector2.ZERO, null, 0.0, true):
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
	var target := step_input.axis * CFG.player_swim_speed * mult.x * tm
	velocity.x = MathUtil.approach(velocity.x, target, CFG.player_swim_accel, delta)
	velocity.y = (CFG.player_swim_up if (step_input.held & ActorInput.BIT_UP) != 0 else CFG.player_swim_down) * tm

func over_climb_tile() -> bool:
	if terrain.empty():
		return false
	return terrain.climb_speed(terrain.material_at(
			terrain.cell(position + Vector2(0, CFG.climb_foot_offset)))) > 0.0 \
		or terrain.climb_speed(terrain.material_at(terrain.cell(position))) > 0.0

func ladder_top(foot: Vector2i) -> bool:
	var below := terrain.material_at(foot + Vector2i(0, 1))
	return below != 0 and terrain.climb_speed(below) > 0.0

func update_climb(delta: float, mult: Vector2) -> void:
	if not climb_latched and (step_input.pressed & ActorInput.BIT_UP) == 0:
		return
	if terrain.empty() or is_squat:
		climb_latched = false
		return
	var foot := terrain.cell(position + Vector2(0, CFG.climb_foot_offset))
	var fv := terrain.material_at(foot)
	var cv := terrain.material_at(terrain.cell(position))
	var ft := fv
	var fs := terrain.climb_speed(ft)
	var cs := terrain.climb_speed(cv)
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
			var speed := CFG.climb_speed * maxf(fs, cs) * CFG.climb_vertical_mult * mult.y * tm
			velocity.y = step_input.vertical_axis * speed
			return
		if (step_input.pressed & ActorInput.BIT_UP) != 0:
			climb_latched = false
			velocity.y = CFG.jump_velocity * mult.y
			cancel_jump_state()
			return
		velocity.y = 0.0
		return
	if step_input.vertical_axis > 0.0:
		var descent := terrain.descent_speed(ft)
		if descent <= 0.0:
			climb_latched = false
			return
		velocity.y = step_input.vertical_axis * CFG.climb_speed * descent * CFG.climb_vertical_mult * mult.y * tm
		return
	velocity.y = 0.0

func update_waterproof(delta: float, submerged: bool) -> void:
	if submerged != _was_submerged:
		_was_submerged = submerged
		_waterproof_timer = 0.0
	if submerged and waterproof == 0:
		_waterproof_drown_timer += delta
		if _waterproof_drown_timer >= WCFG.water_drown_damage_interval:
			_waterproof_drown_timer = 0.0
			combat_requests.append({"kind": "drown", "pos": position, "damage": CFG.player_waterproof_damage})
		return
	_waterproof_drown_timer = 0.0
	_waterproof_timer += delta
	if _waterproof_timer >= (WCFG.water_drain_interval if submerged else WCFG.water_recover_interval):
		_waterproof_timer = 0.0
		waterproof = maxi(waterproof - 1, 0) if submerged else mini(waterproof + 1, max_waterproof)

func update_vertical(delta: float, latched: bool, mult: Vector2) -> void:
	if latched or in_water:
		return
	if _grounded:
		coyote_timer = CFG.coyote_time
	else:
		var grav_mult := CFG.charge_air_gravity_mult if is_charge else 1.0
		velocity.y += gravity * grav_mult * delta
		coyote_timer = maxf(coyote_timer - delta, 0.0)
	if (step_input.pressed & ActorInput.BIT_UP) != 0:
		jump_buffer_timer = CFG.jump_buffer_time
	else:
		jump_buffer_timer = maxf(jump_buffer_timer - delta, 0.0)
	if jump_buffer_timer > 0.0 and (_grounded or coyote_timer > 0.0) and not is_squat:
		if is_charge:
			cancel_charge()
		velocity.y = CFG.jump_velocity * mult.y
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		jump_cut_applied = false
		presentation_events.append({"kind": "jump"})
	if not jump_cut_applied and (step_input.released & ActorInput.BIT_UP) != 0 and velocity.y < 0.0:
		velocity.y *= CFG.jump_cut_factor
		jump_cut_applied = true

func update_crouch_dash() -> void:
	if climb_latched or in_water:
		return
	if not _grounded and (step_input.pressed & ActorInput.BIT_DOWN) != 0 and not over_climb_tile():
		velocity.y = maxf(velocity.y, CFG.charge_down_velocity)
	var want_squat := _grounded and (step_input.held & ActorInput.BIT_DOWN) != 0
	if want_squat and not is_squat:
		is_charge = false
	set_crouched(want_squat)
	if not is_charge and not is_squat and step_input.charge_direction != 0:
		is_charge = true
		charge_timer = CFG.charge_distance / maxf(CFG.charge_velocity, 1.0)
		facing_direction = step_input.charge_direction
		presentation_events.append({"kind": "dash"})

func update_horizontal(delta: float, mult: Vector2) -> void:
	if in_water:
		return
	if is_charge:
		velocity.x = CFG.charge_velocity * facing_direction * mult.x
		charge_timer -= delta
		if charge_timer <= 0.0:
			is_charge = false
	else:
		var speed := (CFG.crouch_walk_speed if is_squat else CFG.move_speed) * _speed_mult
		var target := step_input.axis * speed * mult.x
		if step_input.axis != 0.0:
			velocity.x = MathUtil.approach(velocity.x, target, CFG.accel_ground if _grounded else CFG.accel_air, delta)
		else:
			brake(delta)

func update_facing() -> void:
	if not is_charge and step_input.axis != 0.0:
		facing_direction = 1 if step_input.axis > 0.0 else -1

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
		for contact: Array in motion_contacts:
			if (PhysicsServer2D.body_get_collision_layer(contact[Contact.BODY]) & CollisionWorld.LAYER_TERRAIN) != 0 \
					and absf((contact[Contact.NORMAL] as Vector2).x) > 0.5:
				cancel_charge()
				velocity.x = 0.0
				break
	for contact: Array in motion_contacts:
		var normal: Vector2 = contact[Contact.NORMAL]
		# 查询碰撞层使用物理体 RID。由物理服务器直接创建的地形可能没有对应节点。
		var layer := PhysicsServer2D.body_get_collision_layer(contact[Contact.BODY])
		if (layer & CollisionWorld.LAYER_TERRAIN) == 0 or incoming.dot(normal) >= 0.0:
			continue
		var point := GridPathfinder.wrap_to_range((contact[Contact.POINT] as Vector2) - normal, terrain.map_size)
		if terrain.elastic_alive(point):
			velocity = velocity.slide(normal) + normal * CFG.elastic_bounce
			break

func _simulate_motion(delta: float, mult: Vector2, time_mult: float) -> void:
	_speed_mult = time_mult
	if sim_downed:
		if _grounded:
			coyote_timer = CFG.coyote_time
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
	update_facing()
	update_pose(delta)
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
		push *= CFG.climb_recoil_mult
	var v := velocity
	v.x -= facing_direction * push
	velocity = v

func apply_impulse(source: Vector2, force: float) -> void:
	var away := GridPathfinder.toroidal_delta_px(source, position, terrain.map_size)
	if away.is_zero_approx():
		away = Vector2(-float(facing_direction), 0.0)
	else:
		away = away.normalized()
	if force < 0.0:
		velocity = Vector2(away.x * CFG.player_hit_knockback, away.y * CFG.player_hit_knockback - CFG.player_hit_knockback_up)
	else:
		motion_knock_velocity = away * force

func force_down() -> bool:
	if sim_downed:
		return false
	sim_downed = true
	_grounded = false
	sync_collision_geometry()
	if equipped != null:
		equipped.cancel_aim()
	return true

func simulate_hit(source: Vector2, damage: int, force: float) -> bool:
	if force != 0.0:
		apply_impulse(source, force)
	return apply_hit_health(sim_hp - damage)

func apply_hit_health(hp: int) -> bool:
	cancel_charge()
	sim_hp = hp
	sim_iframes = CFG.iframes_time
	return sim_hp <= 0 and force_down()

func apply_authoritative_state(hp: int, wp: int, down: bool) -> void:
	sim_hp = hp
	waterproof = wp
	sim_downed = down
	sync_collision_geometry()

## 返回供同步和回溯使用的角色快照，其中包含手持武器状态。
func capture_state() -> Array:
	var values := []
	values.resize(PlayerStateSchema.SIZE)
	for slot in PlayerStateSchema.WEAPON_INST:
		values[slot] = get(PlayerStateSchema.names[slot])
	values[PlayerStateSchema.WEAPON_INST] = weapons.current_inst()
	values[PlayerStateSchema.INVENTORY] = weapons.snapshot()
	values[PlayerStateSchema.EQUIPMENT] = equipped.state_values() if equipped != null else []
	return values

func restore_state(values: Array, rewinding_inventory := false) -> void:
	for slot in PlayerStateSchema.WEAPON_INST:
		if slot != PlayerStateSchema.SHOT_SERIAL or not rewinding_inventory:
			set(PlayerStateSchema.names[slot], values[slot])
	sync_collision_geometry()
	weapons.restore(values[PlayerStateSchema.WEAPON_INST], values[PlayerStateSchema.INVENTORY],
			values[PlayerStateSchema.EQUIPMENT], rewinding_inventory)

func capture_checkpoint() -> Array:
	return [input_buffer.epoch, input_buffer.action_ack, rewinding, respawn_tick, step_input.aim,
			input_buffer._last, capture_state()]

func restore_checkpoint(snapshot: Array, scope := CombatSnapshot.NETWORK) -> void:
	var oxygen := waterproof
	restore_state(snapshot[NetPlayer.STATE], scope != CombatSnapshot.NETWORK)
	if scope == CombatSnapshot.WORLD:
		sim_hp = clampi(sim_hp, 0, sim_max_hp)
		waterproof = oxygen
	if scope != CombatSnapshot.NETWORK:
		return
	rewinding = snapshot[NetPlayer.REWIND]
	respawn_tick = snapshot[NetPlayer.RESPAWN_TICK]
	step_input.aim = snapshot[NetPlayer.AIM]
	input_buffer.restore_authority(snapshot[NetPlayer.EPOCH], snapshot[NetPlayer.ACTION_ACK], snapshot[NetPlayer.INPUT])
	if collision_layer == 0:
		collision_layer = CollisionWorld.team_layer(team)

func spawn_at(spawn_cell: Vector2i, heal := true) -> void:
	position = CyrmMap.world_position(spawn_cell)
	reset_motion()
	if heal:
		apply_authoritative_state(sim_max_hp, max_waterproof, false)
	else:
		sync_collision_geometry()
