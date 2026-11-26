extends "res://tests/simulation_fixture.gd"

func run(tree: SceneTree) -> void:
	_water(tree)
	_dynamic_blocking(tree)
	_step_up(tree)
	_step_overhang(tree)
	_step_stairs(tree)
	_step_slope(tree)

func _water(tree: SceneTree) -> void:
	var cells := {}
	for y in range(4, 10):
		cells[Vector2i(2, y)] = 21
	for y in 16:
		cells[Vector2i(5, y)] = 21
	var parent := world_with_walls(tree, 8, 16, cells)
	var actor := player(parent)
	var step_at := func(y: float, delta: float) -> Array:
		_place(actor, Vector2(160.0, y))
		return ActorStep.step(actor, NEUTRAL_INPUT, delta)
	var bank := 256.0 - (actor.collision_rect().end.y - actor.position.y)
	step_at.call(bank + 7.0, ActorStep.DT)
	expect(not actor.in_water, "shallow contact alone does not start swimming")
	step_at.call(bank + 9.0, ActorStep.DT)
	expect(actor.in_water, "feet below the entry depth start swimming")
	step_at.call(bank - 1.0, ActorStep.DT)
	expect(actor.in_water, "swimming holds just above the surface")
	step_at.call(bank - 3.0, ActorStep.DT)
	expect(not actor.in_water, "swimming ends beyond the exit margin")

	# 固定角色脚下的水深以比较两种姿势。站立时能呼吸，蹲下后头部就会没入水中。
	var head_at_surface := 299.0
	actor.waterproof = 1
	step_at.call(head_at_surface, WCFG.water_drain_interval)
	expect(actor.in_water and actor.waterproof == 2, "a swimmer with their head out recovers oxygen")
	actor.set_crouched(true)
	step_at.call(head_at_surface, WCFG.water_drain_interval)
	expect(actor.waterproof == 1, "the same position drains oxygen with the crouched hull")

	var sim := parent.combat
	var hp := actor.sim_hp
	actor._controls_locked = true
	submit(actor, step_at.call(384.0, WCFG.water_drain_interval))
	expect(actor.sim_hp == hp and actor.waterproof == 1, "locked rounds pause water survival")
	actor._controls_locked = false
	submit(actor, step_at.call(384.0, WCFG.water_drain_interval))
	submit(actor, step_at.call(384.0, WCFG.water_drown_damage_interval - 0.1))
	expect(actor.waterproof == 0 and actor.sim_hp == hp, "exhausted oxygen starts the drowning interval")
	submit(actor, step_at.call(head_at_surface, 0.2))
	expect(actor.sim_hp == hp and actor.waterproof == 0, "surfacing stops damage before oxygen recovers")
	submit(actor, step_at.call(384.0, WCFG.water_drown_damage_interval - 0.1))
	expect(actor.sim_hp == hp, "submerging again starts a fresh drowning interval")
	var before := actor.capture_state()
	var actions: Array = step_at.call(384.0, 0.2)
	var after := actor.capture_state()
	actor.restore_state(before)
	expect(step_at.call(384.0, 0.2) == actions and actor.capture_state() == after and actor.sim_hp == hp,
			"replayed drowning produces the same action without changing predicted HP")
	actor.motion_knock_velocity = Vector2(20.0, 10.0)
	var velocity := actor.velocity
	submit(actor, actions)
	expect(actor.sim_hp == hp - CFG.player_waterproof_damage and sim.hits == [[0, actor.role, CFG.player_waterproof_damage]]
			and actor.velocity == velocity and actor.motion_knock_velocity == Vector2(20.0, 10.0),
			"PvP authority deducts drowning damage once without credit or knockback")

	var bird := sim.add_enemy("jump_bird", actor, Vector2(352.0, 8.0))
	bird._waterproof = 0
	hp = bird.hp
	bird._apply_water(ECFG.shared_drown_interval)
	expect(bird.velocity.y < 0.0 and bird.velocity.y >= -ECFG.shared_bird_max_float
			and bird.hp == hp - ECFG.shared_drown_damage,
			"an enemy in a full water column ascends at a finite speed and takes drowning damage")
	cleanup()

func _dynamic_blocking(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var mover := player(parent, 1)
	var blocker := player(parent, 2)
	mover.gravity = 0.0
	blocker.gravity = 0.0
	mover.collision_mask = CombatProfiles.Layer.TERRAIN | CombatProfiles.Layer.TEAM_A
	mover.collision_layer = 0
	mover.position = Vector2(200, 512)
	blocker.position = Vector2(320, 512)
	mover.sync_collision_geometry()
	blocker.sync_collision_geometry()
	collider(blocker, CombatProfiles.Layer.TEAM_A)
	var start := mover.position.x
	var record := [1.0, ActorInput.BIT_UP, 0, 0, 0, Vector2.RIGHT]
	for i in 14:
		ActorStep.step(mover, record)
	expect(mover.position.x > start + 8.0, "the moving actor advances until the blocker stops it")
	expect(mover.position.x < blocker.position.x - 60.0,
			"another actor's body stops the moving body before it overlaps")
	var blocked_at := mover.position.x
	blocker.collision_layer = 0
	for i in 20:
		ActorStep.step(mover, record)
	expect(mover.position.x > blocked_at + 20.0, "clearing the blocker's layer lets the same input continue")

func _step_world(tree: SceneTree, height: int, ceiling := false) -> Node2D:
	return world_from_solid(tree, 16, 8, func(sx: int, sy: int) -> bool:
		if sy >= 24:
			return true
		if height > 0 and sx >= 32 and sy >= 24 - height / 16:
			return true
		if ceiling and sx >= 20 and sx <= 28 and sy >= 15 and sy <= 16:
			return true
		return false)

func _step_up(tree: SceneTree) -> void:
	for height: int in [16, 32, 48, 64]:
		cleanup()
		var parent := _step_world(tree, height)
		var mover := player(parent, 1)
		mover.gravity = WCFG.gravity0
		mover.collision_layer = 0
		mover.collision_mask = CombatProfiles.Layer.TERRAIN
		mover.position = Vector2(400, 384 - 57)
		mover.sync_collision_geometry()
		ActorStep.step(mover, NEUTRAL_INPUT)
		var farthest := mover.position.x
		for i in 60:
			ActorStep.step(mover, FORWARD_INPUT)
			farthest = maxf(farthest, mover.position.x)
		expect(absf(mover.position.y - (384 - height - 57)) < 2.0,
				"a %dpx step is climbed" % height)
		expect(farthest > 512.0, "the actor crosses the %dpx step face" % height)
	cleanup()
	var too_high := _step_world(tree, 80)
	var blocked := player(too_high, 1)
	blocked.gravity = WCFG.gravity0
	blocked.collision_layer = 0
	blocked.collision_mask = CombatProfiles.Layer.TERRAIN
	blocked.position = Vector2(400, 384 - 57)
	blocked.sync_collision_geometry()
	for i in 40:
		ActorStep.step(blocked, FORWARD_INPUT)
	expect(absf(blocked.position.y - (384 - 57)) < 2.0 and blocked.position.x < 500.0,
			"a step higher than 64px keeps the normal collision block")
	cleanup()
	var low := _step_world(tree, 16, true)
	var ceiling_mover := player(low, 1)
	ceiling_mover.gravity = WCFG.gravity0
	ceiling_mover.collision_layer = 0
	ceiling_mover.collision_mask = CombatProfiles.Layer.TERRAIN
	ceiling_mover.position = Vector2(400, 384 - 57)
	ceiling_mover.sync_collision_geometry()
	for i in 40:
		ActorStep.step(ceiling_mover, FORWARD_INPUT)
	expect(absf(ceiling_mover.position.y - (384 - 57)) < 2.0,
			"a low ceiling blocks the whole step path")
	cleanup()
	var dynamic := _step_world(tree, 16)
	var runner := player(dynamic, 1)
	runner.gravity = WCFG.gravity0
	runner.collision_layer = 0
	runner.collision_mask = CombatProfiles.Layer.TERRAIN | CombatProfiles.Layer.TEAM_A
	runner.position = Vector2(400, 384 - 57)
	runner.sync_collision_geometry()
	var blocker := player(dynamic, 2)
	blocker.gravity = 0.0
	# 阻挡者悬在台阶上方。角色沿原高度移动时不会碰到它，但尝试抬高 16 像素后会被挡住。
	blocker.position = Vector2(500, 213)
	blocker.sync_collision_geometry()
	collider(blocker, CombatProfiles.Layer.TEAM_A)
	for i in 40:
		ActorStep.step(runner, FORWARD_INPUT)
	expect(absf(runner.position.y - (384 - 57)) < 2.0,
			"a dynamic actor blocking the raised path prevents the step-up")
	runner.move_by_internal(Vector2(10.0, 0.0))
	expect(absf(runner.position.y - (384 - 57)) < 2.0,
			"a rejected step candidate does not move the actor")
	cleanup()

func _step_overhang(tree: SceneTree) -> void:
	# 台阶在地图左侧，角色从右侧接近。上方有 112 像素的净空，站立的碰撞形状高 107 像素。
	var parent := world_from_solid(tree, 16, 8, func(sx: int, sy: int) -> bool:
		return sy >= 24 or sx < 12 and (sy >= 23 or sy == 15))
	var mover := player(parent)
	_place(mover, Vector2(_terrain.map_size.x - 36.5, 326.999))
	mover.velocity.x = CFG.move_speed
	mover._grounded = true
	var x := mover.position.x
	ActorStep.step(mover, FORWARD_INPUT)
	expect(mover.position.x > x + 10.0 and absf(mover.position.y - 311.0) < 0.1 and mover._grounded,
			"a 16px step across the seam fits under a close overhang")
	cleanup()

func _step_stairs(tree: SceneTree) -> void:
	var parent := world_from_solid(tree, 16, 8, func(sx: int, sy: int) -> bool:
		return sy >= 24 or sx >= 32 and sy >= 23 or sx >= 33 and sy >= 22)
	var mover := player(parent)
	_place(mover, Vector2(475.5, 326.999))
	mover.personal_haste_mult = 3.0
	mover.velocity.x = CFG.move_speed * mover.personal_haste_mult
	mover._grounded = true
	ActorStep.step(mover, FORWARD_INPUT)
	expect(absf(mover.position.y - 311.0) < 0.1 and mover._grounded and mover.velocity.x > 0.0,
			"the next riser shortens fast movement through the first step")
	ActorStep.step(mover, FORWARD_INPUT)
	expect(absf(mover.position.y - 295.0) < 0.1 and mover._grounded,
			"the next tick climbs the second step")
	cleanup()

func _step_slope(tree: SceneTree) -> void:
	var parent := world_from_solid(tree, 16, 16, func(_sx: int, sy: int) -> bool: return sy >= 24)
	var slope := StaticBody2D.new()
	slope.position = Vector2(513, 375)
	slope.rotation_degrees = -70.0
	slope.collision_layer = CombatProfiles.Layer.TERRAIN
	slope.collision_mask = 0
	var hull := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = Vector2(44, 3)
	hull.shape = box
	slope.add_child(hull)
	parent.add_child(slope)
	var mover := player(parent)
	mover.collision_layer = 0
	mover.collision_mask = CombatProfiles.Layer.TERRAIN
	mover.position = Vector2(464, 326.98)
	mover.sync_collision_geometry()
	mover._grounded = true
	mover.step_input = ActorInput.new()
	mover.step_input.axis = 1.0
	var blocked := mover.move_by_internal(Vector2(12, 0))
	expect(blocked == Vector2(1, 0) and mover.position.x < 476.0
			and absf(mover.position.y - 326.98) < 0.2,
			"a rotated terrain face uses normal horizontal blocking")
	var pose: Transform2D = PhysicsServer2D.body_get_state(mover.rid, PhysicsServer2D.BODY_STATE_TRANSFORM)
	expect(pose.origin.is_equal_approx(mover.position), "the blocked actor and RID stay in sync")
	cleanup()

## 该测试覆盖胜队内部的 MVP 评选、同分时的顺序以及平局不评 MVP 的规则。
