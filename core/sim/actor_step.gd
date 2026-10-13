class_name ActorStep
extends RefCounted
const DT := 1.0 / 60.0


static func step(actor: CharacterBody2D, record: Dictionary, delta: float = DT) -> Array:
	actor.step_input.apply_packet(record)
	actor.step_input.frozen = actor._controls_locked
	actor.input_seq = record["seq"]
	actor.view_tick = record["view_tick"]
	actor.step_actions.clear()
	actor.stepping = true
	simulate(actor, delta)
	actor.stepping = false
	return actor.step_actions.duplicate()


static func simulate(actor: CharacterBody2D, delta: float) -> void:
	if actor.rewinding:
		return
	var tm: float = TimeField.player_speed_mult() if TimeField.current != null else actor.pvp_haste_mult
	actor._speed_mult = tm
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	if actor.combat.is_downed():
		actor._pre_move_vy = 0.0
		_tick_downed(actor, delta)
		return
	actor.combat.iframes = maxf(actor.combat.iframes - delta, 0.0)
	var idx: int = actor.step_input.get_switch_index_pressed()
	if idx > 0:
		actor.weapons.equip_index(idx - 1)
	var winst: int = actor.step_input.consume_switch_inst()
	if winst > 0:
		actor.weapons.equip_inst(winst)
		if actor.weapons.current_inst() != winst:
			actor.step_input._pressed &= ~(PacketInputSource.BIT_ATTACK | PacketInputSource.BIT_RELOAD)
			actor.step_input._released &= ~PacketInputSource.BIT_ATTACK
			actor.step_input._held &= ~PacketInputSource.BIT_ATTACK
	if actor.step_input.is_action_just_pressed("R"):
		var reload_w: Node2D = actor.weapons.current_weapon()
		if reload_w != null:
			reload_w.start_reload()
	actor.weapons.tick(delta * tm)
	var mult: Vector2 = actor.weapons.movement_multiplier()
	var horizontal_input: float = actor.step_input.get_axis("left", "right")
	var in_water: bool = actor.swim.update(actor, delta, mult, actor.step_input)
	actor._update_waterproof(delta)
	var latched := false
	if not in_water:
		actor.climb.update(mult, delta, actor.is_squat, actor.step_input)
		latched = actor.climb.is_latched()
	else:
		actor.is_charge = false
		actor.is_squat = false
	_tick_vertical(actor, delta, latched, in_water, mult)
	_tick_crouch_and_dash(actor, delta, latched, in_water)
	_tick_horizontal(actor, delta, in_water, horizontal_input, mult)
	_tick_facing(actor, delta, horizontal_input)
	_tick_pose_and_collision(actor, delta, in_water)
	actor.combat.apply_knock(delta)
	actor._pre_move_vy = 0.0 if (in_water or latched) else actor.velocity.y
	actor.move_and_slide()
	actor._grounded = actor.is_on_floor()
	_tick_slide_reactions(actor)
	_wrap_position(actor)

static func _tick_vertical(actor: CharacterBody2D, delta: float, latched: bool, in_water: bool, mult: Vector2) -> void:
	if latched or in_water:
		return
	if actor._grounded:
		actor.coyote_timer = actor.coyote_time
	else:
		var grav_mult: float = actor.charge_air_gravity_mult if actor.is_charge else 1.0
		actor.velocity.y += actor.gravity * grav_mult * delta
		actor.coyote_timer = maxf(actor.coyote_timer - delta, 0.0)
	if actor.step_input.is_action_just_pressed("up"):
		actor.jump_buffer_timer = actor.jump_buffer_time
	else:
		actor.jump_buffer_timer = maxf(actor.jump_buffer_timer - delta, 0.0)
	if actor.jump_buffer_timer > 0.0 and (actor._grounded or actor.coyote_timer > 0.0) and not actor.is_squat:
		if actor.is_charge:
			actor.is_charge = false
			actor.charge_timer = 0.0
		actor.velocity.y = actor.jump_velocity * mult.y
		actor.jump_buffer_timer = 0.0
		actor.coyote_timer = 0.0
		actor.jump_cut_applied = false
		actor.step_actions.append({"kind": "impulse", "value": SquashStretch.Impulse.JUMP})
	if not actor.jump_cut_applied and actor.step_input.is_action_just_released("up") and actor.velocity.y < 0.0:
		actor.velocity.y *= actor.jump_cut_factor
		actor.jump_cut_applied = true

static func _tick_crouch_and_dash(actor: CharacterBody2D, delta: float, latched: bool, in_water: bool) -> void:
	if latched or in_water:
		return
	if not actor._grounded and actor.step_input.is_action_just_pressed("down") \
			and not actor.climb.is_over_climb_tile():
		actor.velocity.y = actor.charge_down_velocity
	var want_squat: bool = actor._grounded and actor.step_input.is_action_pressed("down")
	if want_squat and not actor.is_squat:
		actor.is_charge = false   # 冲刺中按 S → 取消冲刺进蹲
	actor.is_squat = want_squat
	if not actor.is_charge and not actor.is_squat and actor.step_input.is_action_just_pressed("charge"):
		actor.is_charge = true
		actor.charge_timer = actor.charge_duration
		actor.step_actions.append({"kind": "impulse", "value": SquashStretch.Impulse.DASH})
		if actor._last_move_timer > 0.0:
			actor.facing_direction = actor._last_move_dir

static func _tick_horizontal(actor: CharacterBody2D, delta: float, in_water: bool, horizontal_input: float, mult: Vector2) -> void:
	if in_water:
		return
	if actor.is_charge:
		actor.velocity.x = actor.charge_velocity * actor.facing_direction
		actor.charge_timer -= delta
		if actor.charge_timer <= 0:
			actor.is_charge = false
	else:
		var speed_target: float = (actor.crouch_walk_speed if actor.is_squat else actor.move_speed) * actor._speed_mult
		var target_velocity_x = horizontal_input * speed_target * mult.x
		if horizontal_input != 0:
			if actor._grounded:
				actor.velocity.x = MathUtil.approach(actor.velocity.x, target_velocity_x, actor.accel_ground, delta)
			else:
				actor.velocity.x = MathUtil.approach(actor.velocity.x, target_velocity_x, actor.accel_air, delta)
		else:
			_brake_horizontal(actor, delta)

static func _tick_facing(actor: CharacterBody2D, delta: float, horizontal_input: float) -> void:
	if not actor.is_charge and horizontal_input != 0:
		actor.facing_direction = 1 if horizontal_input > 0 else -1
		actor._last_move_dir = actor.facing_direction
		actor._last_move_timer = PlayerParams.charge_dir_window
	else:
		actor._last_move_timer = maxf(actor._last_move_timer - delta, 0.0)

static func _tick_pose_and_collision(actor: CharacterBody2D, delta: float, in_water: bool) -> void:
	var desired: int = actor.Pose.STAND
	if in_water:
		desired = actor.Pose.MOVE if absf(actor.velocity.x) > 1.0 else actor.Pose.STAND
	elif actor.is_charge:
		desired = actor.Pose.CHARGE
	elif actor.is_squat:
		desired = actor.Pose.SQUAT
	elif not actor._grounded:
		desired = actor.Pose.FLY
	elif actor.velocity.x != 0:
		desired = actor.Pose.MOVE
	if actor.state_lock_timer > 0.0:
		actor.state_lock_timer -= delta
	elif actor.state != desired:
		actor.state = desired
		actor.state_lock_timer = actor.STATE_LOCK_TIME
	for pose in actor._coll_by_pose:
		actor._coll_by_pose[pose].disabled = pose != actor.state

static func _tick_slide_reactions(actor: CharacterBody2D) -> void:
	if actor.is_charge:
		for i in range(actor.get_slide_collision_count()):
			var col := actor.get_slide_collision(i)
			if col != null and absf(col.get_normal().x) > 0.5:
				actor.is_charge = false
				actor.charge_timer = 0.0
				actor.velocity.x = 0.0
				break
	if not MazeGenerator.current_grid.is_empty():
		for i in range(actor.get_slide_collision_count()):
			var sc := actor.get_slide_collision(i)
			if sc == null:
				continue
			var ec := MazeGenerator.cell_of(sc.get_position(), GameParameters.TILE_SIZE,
					MazeGenerator.current_grid[0].size(), MazeGenerator.current_grid.size())
			var ev: int = MazeGenerator.current_grid[ec.y][ec.x]
			if ev != 0 and TileDefs.elastic(MazeGenerator.texture_of(ev)):
				actor.velocity += sc.get_normal() * PlayerParams.elastic_bounce
				break

static func _tick_downed(actor: CharacterBody2D, delta: float) -> void:
	if actor._grounded:
		actor.coyote_timer = actor.coyote_time
	else:
		actor.velocity.y += actor.gravity * delta
	_brake_horizontal(actor, delta)
	actor.combat.apply_knock(delta)
	actor.move_and_slide()
	actor._grounded = actor.is_on_floor()
	_wrap_position(actor)

static func _brake_horizontal(actor: CharacterBody2D, delta: float) -> void:
	if actor._grounded:
		actor.velocity.x = MathUtil.approach(actor.velocity.x, 0.0, actor.brake_ground, delta)
	else:
		actor.velocity.x = MathUtil.approach(actor.velocity.x, 0.0, actor.brake_air, delta)
	if absf(actor.velocity.x) < PlayerParams.stop_snap:
		actor.velocity.x = 0.0

static func _wrap_position(actor: CharacterBody2D) -> void:
	actor.global_position = MazeGenerator.wrap_to_range(actor.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
