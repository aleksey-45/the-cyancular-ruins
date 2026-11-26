extends "res://tests/simulation_fixture.gd"

func run(tree: SceneTree) -> void:
	_world_rewind(tree)
	_rewound_blast(tree)
	_rewound_enemy_action(tree)
	_rewind_window(tree)
	_enemy_time(tree)
	_grain_rewards(tree)
	_shared_rewind_history(tree)
	_personal_rewind()

func _world_rewind(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var sim := parent.combat
	sim.time_field = WorldTime.new(GrainAccount.new())
	var bird := sim.add_enemy("jump_bird", actor, Vector2(300, 120))
	bird.velocity = Vector2(12, -7)
	var bird_hp := bird.hp
	var id := (actor.role << 48) | 256
	var bullet := sim.spawn_projectile(id, WeaponType.GRENADE, actor,
			Vector2(100, 128), Vector2.RIGHT * 200.0)
	bullet.start_fuse(0.3)
	bullet.fuse_elapsed = 0.1
	bullet.traveled = 29.0
	var before := bullet.motion_state()
	var initial := actor.position
	var rewind := sim.time_field
	var dt := 1.0 / TCFG.SNAP_HZ
	_record_time(sim, actor, dt)
	expect(not rewind.history.can_rewind() and sim.projectiles.get(id) == bullet, "one newly recorded frame cannot start rewind or clear live projectiles")
	sim.erase_projectile(id)
	actor.position.x += 80.0
	bird.position.x += 40.0
	bird.velocity = Vector2.ZERO
	bird.hp = 0
	bird.is_dead = true
	bird.active = false
	sim.tick += 1
	_record_time(sim, actor, dt)
	var sub := Vector2i(8, 12)
	var wall_hp := _terrain.get_hp(sub)
	_terrain.apply_at(_terrain.version, {sub: 0})
	sim.tick += 1
	var elite := sim.add_enemy("black_bird", actor, Vector2(100, 128)) as EnemyBlackBird
	var elite_hp := elite.hp
	rewind.rewind(sim, actor, 1.0)
	sim.hit_rewound_elites(rewind._elite_hits)
	expect(actor.position == initial, "single-player gameplay rewind restores the actor")
	var restored: BulletBody = sim.projectiles[id]
	expect(_terrain.get_hp(sub) == wall_hp, "entering rewind seals and restores the last live tick's terrain")
	expect(elite.hp == elite_hp - restored.hit_damage, "a rewound projectile hits an elite added after recording")
	rewind.rewind(sim, actor, dt)
	sim.hit_rewound_elites(rewind._elite_hits)
	expect(elite.hp == elite_hp - restored.hit_damage, "holding rewind on the same sample hits the elite once")
	expect(restored != bullet and restored.shooter == actor and restored.motion_state() == before,
			"single-player rewind restores the same projectile identity, owner, motion and fuse")
	expect(bird.position == Vector2(300, 120) and bird.velocity == Vector2(12, -7)
			and bird.hp == bird_hp and not bird.is_dead and bird.active,
			"single-player rewind restores a recorded enemy and revives it")
	bird.hurt(bird.hp, Vector2.ZERO)
	_record_time(sim, actor, dt)
	var remaining := bird.corpse_left
	rewind.mode = WorldTime.Mode.NONE
	bird.simulate_tick(remaining + dt)
	_record_time(sim, actor, dt)
	expect(not bird.active and bird.collision_layer == 0 and sim.enemies[bird.slot] == bird,
			"an expired corpse keeps its slot without collision")
	rewind.rewind(sim, actor, dt / TCFG.REWIND_START_MULT)
	expect(bird.active and bird.is_dead and bird.corpse_left == remaining and bird.collision_layer == CombatProfiles.Layer.ENEMY,
			"rewinding into the corpse interval restores collision and its remaining lifetime")
	rewind.rewind(sim, actor, TCFG.SNAP_SECONDS)
	expect(bird.active and not bird.is_dead and bird.hp == bird_hp, "rewinding before the kill revives the same slot")
	cleanup()

func _rewound_blast(tree: SceneTree) -> void:
	var cell := Vector2i(15, 8)
	var parent := world_with_walls(tree, 16, 16, {cell: wall_texture()})
	var actor := player(parent)
	_place(actor, Vector2(900, 544))
	actor.gravity = 0.0
	var sim := parent.combat
	sim.time_field = WorldTime.new(GrainAccount.new())
	var rewind := sim.time_field
	var dt := 1.0 / TCFG.SNAP_HZ
	var wall := block_hp(sim.terrain, cell)
	var hp := actor.sim_hp
	var id := ShotRules.shot_id(actor.role, 1)
	var shot := sim.spawn_projectile(id, WeaponType.GRENADE, actor, Vector2(936, 544), Vector2.RIGHT)
	shot.start_fuse(ActorStep.DT)
	var inputs := {actor.role: NEUTRAL_INPUT}
	_record_time(sim, actor, dt)
	sim.step(inputs)
	sim.step(inputs)
	_record_time(sim, actor, dt)
	var scheduled := sim.pending_blasts[id][CombatSimulator.Blast.DUE] as int
	sim.step(inputs)
	sim.step(inputs)
	var damaged := block_hp(sim.terrain, cell)
	var hit_hp := actor.sim_hp
	expect(scheduled == 4 and hit_hp < hp and damaged != wall, "the original grenade settles at tick four")
	# 地形损伤落在两份世界记录之间。
	_record_time(sim, actor, dt * 0.5)
	_record_time(sim, actor, dt * 0.5)
	sim.time_field.mode = WorldTime.Mode.REWIND
	rewind.rewind(sim, actor, dt * 0.25 / TCFG.REWIND_START_MULT)
	for i in 4:
		rewind.rewind(sim, actor, 0.0)
		sim.step(inputs)
	expect(sim.tick == 2 and sim.ground.tick == 4 and sim.projectiles.is_empty()
			and sim.pending_blasts[id][CombatSimulator.Blast.DUE] == 4
			and actor.sim_hp == hp and block_hp(sim.terrain, cell) == wall,
			"holding a pending-blast sample restores its wall and HP and freezes its two remaining ticks")
	sim.time_field.mode = WorldTime.Mode.NONE
	_record_time(sim, actor, 0.0)
	sim.step(inputs)
	expect(actor.sim_hp == hp and block_hp(sim.terrain, cell) == wall, "one resumed tick leaves the blast pending")
	sim.step(inputs)
	expect(actor.sim_hp == hit_hp and actor.motion_knock_velocity != Vector2.ZERO
			and block_hp(sim.terrain, cell) == damaged and sim.pending_blasts.is_empty(),
			"resuming settles the original damage and impulse once without a second detonation event")
	actor.waterproof = 1
	actor.shot_serial = 7
	sim.time_field.mode = WorldTime.Mode.REWIND
	rewind.rewind(sim, actor, 1.0)
	expect(sim.projectiles.has(id) and sim.projectiles[id].fuse_duration == ActorStep.DT
			and sim.pending_blasts.is_empty() and actor.sim_hp == hp and block_hp(sim.terrain, cell) == wall
			and actor.waterproof == 1 and actor.shot_serial == 7,
			"rewinding before detonation restores the live fuse, preserving oxygen and unique shot IDs")
	sim.time_field.mode = WorldTime.Mode.NONE
	_record_time(sim, actor, 0.0)
	for i in 5:
		sim.step(inputs)
	expect(actor.sim_hp == hit_hp and block_hp(sim.terrain, cell) == damaged
			and sim.projectiles.is_empty() and sim.pending_blasts.is_empty(),
			"a new branch detonates once and reproduces exactly one terrain and damage settlement")
	cleanup()

func _rewound_enemy_action(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent)
	_place(actor, Vector2(400, 320))
	actor.gravity = 0.0
	var sim := parent.combat
	sim.time_field = WorldTime.new(GrainAccount.new())
	var jumper := sim.add_enemy("jump_bird", actor, Vector2(480, 320)) as EnemyJumpBird
	jumper.state = EnemyBase.State.LUNGE_WINDUP
	jumper._state_timer = ActorStep.DT
	var flyer := sim.add_enemy("fly_bird", actor, Vector2(340, 220)) as EnemyFlyBird
	flyer.use_gravity = false
	flyer._start_shoot()
	flyer._shoot_timer = 0.0
	sim.spawn_enemy_projectile(CombatProfiles.BIRD_BOMB_TYPE, flyer, Vector2.RIGHT * 100.0)
	var rewind := sim.time_field
	var dt := 1.0 / TCFG.SNAP_HZ
	_record_time(sim, actor, dt)
	sim.step({1: NEUTRAL_INPUT})
	var jump := jumper.capture_state()
	var fly := flyer.capture_state()
	expect(jumper.state == EnemyBase.State.LUNGE_DASH and flyer._strafe_target != Vector2.INF,
			"one input tick starts the jump bird's lunge and the fly bird's firing strafe")
	_record_time(sim, actor, dt)
	sim.clear()
	rewind.rewind(sim, actor, 1.0)
	expect(sim.projectiles.size() == 1 and sim.projectiles[-1].shooter == flyer and sim.tick == 0,
			"a recreated enemy projectile resolves the same shooter from the world checkpoint")
	_record_time(sim, actor, 0.0)
	rewind.mode = WorldTime.Mode.NONE
	sim.step({1: NEUTRAL_INPUT})
	expect(jumper.capture_state() == jump and flyer.capture_state() == fly,
			"resuming repeats both enemies' AI transitions, timers, movement and chosen strafe")
	cleanup()

func _rewind_window(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var rewind := TimeHistory.new(TCFG.SNAP_SECONDS)
	var sample := func() -> Array: return [actor.capture_state(), {}]
	var dt := 0.0625
	var window := int(TCFG.SNAP_SECONDS / dt)
	var samples := 2 * window + 4
	for index in samples:
		actor.position.x = 64.0 + index * 0.25
		rewind.record(dt, index, sample)
	var end := samples * dt
	var backwards := TCFG.SNAP_SECONDS * 0.5 + dt * 0.5
	var target := end - backwards
	var expected_x := 64.0 + (floori(target / dt) - 1) * 0.25
	actor.rewind_state(rewind.backward(backwards / TCFG.REWIND_START_MULT)[TimeHistory.Sample.ACTOR], true)
	expect(actor.position.x == expected_x, "rewind finds the preceding frame across the wrapped buffer")
	rewind.record(0.0, samples, sample)
	expect(is_equal_approx(rewind.time, target), "rewind exits at the target time between recorded frames")
	actor.position.x = 480.0
	rewind.record(dt, samples, sample)
	actor.rewind_state(rewind.backward(dt * 0.25 / TCFG.REWIND_START_MULT)[TimeHistory.Sample.ACTOR], true)
	expect(actor.position.x == expected_x, "recording after rewind discards the former future")
	actor.rewind_state(rewind.backward(TCFG.SNAP_SECONDS + 1.0)[TimeHistory.Sample.ACTOR], true)
	rewind.record(0.0, samples, sample)
	expect(actor.position.x == 64.0 + (samples - 1 - window) * 0.25
			and is_equal_approx(rewind.time, end - TCFG.SNAP_SECONDS),
			"rewinding beyond the window clamps to the oldest retained frame and its time")
	cleanup()

func _enemy_time(tree: SceneTree) -> void:
	var parent := world(tree)
	var target := player(parent)
	_place(target, Vector2(400, 80))
	var bird := parent.combat.add_enemy("jump_bird", target, Vector2.ZERO) as EnemyJumpBird
	bird.kind = bird.kind.duplicate()
	bird.kind.frames = bird.kind.frames.duplicate()
	bird.kind.frames.set_animation_speed(&"wake_up", 16.0)
	bird._tick_sleep(0.0, 0.0)
	bird._tick_wake(0.25)
	expect(bird.state == EnemyBase.State.WAKE, "changing the art's frame rate doesn't shorten the wake phase")
	bird._tick_wake(0.25)
	expect(bird.state == EnemyBase.State.CHASE, "the wake phase keeps its original half-second duration")
	# 禁用重力、行动逻辑和击退衰减，让水平位移的差别仅取决于时间倍率。
	bird.is_dead = true
	bird.use_gravity = false
	bird.knock_decay_rate = 0.0
	bird.combat.time_field = WorldTime.new(GrainAccount.new())
	bird.time_field.mode = WorldTime.Mode.HASTE
	for elite in [false, true]:
		bird.kind.elite = elite
		bird.position = Vector2(200.0, 80.0)
		bird.velocity = Vector2(60.0, 0.0)
		bird.simulate_tick(ActorStep.DT)
		var expected := TCFG.HASTE_PLAYER if elite else TCFG.HASTE_WORLD
		expect(is_equal_approx(bird.position.x - 200.0, expected) and bird.velocity.x == 60.0,
				"enemy horizontal displacement uses one time multiplier (elite=%s)" % elite)
	var flyer := parent.combat.add_enemy("fly_bird", target, Vector2.ZERO) as EnemyFlyBird
	flyer.position = Vector2(_terrain.map_size.x - 8, 80)
	flyer.stance = 1
	flyer._glide_to(Vector2(8, 80), ActorStep.DT)
	expect(flyer.hull == flyer.kind.hulls[1] and flyer.velocity.x > 0.0,
			"a flying bird uses its flight hull and glides along the short path across a seam")
	var flight := flyer.capture_state()
	flyer.stance = 0
	flyer.restore_state(flight)
	expect(PhysicsServer2D.body_get_shape(flyer.rid, 0) == flyer.kind.hulls[1].get_rid(),
			"restoring the flight stance also restores the physics shape")
	flyer.position = Vector2(200, 80)
	_place(target, Vector2(340, 80))
	expect(not flyer.touches_player(), "a separated hull is outside the contact rectangle")
	target.position.x = 275
	expect(flyer.touches_player() and flyer.touches_player(), "contact begins immediately and persists beyond the old 40 px radius")
	target.position.x = 340
	expect(not flyer.touches_player(), "moving out immediately ends contact")
	flyer.position = Vector2(2, 2)
	_place(target, _terrain.map_size - Vector2(8, 8))
	expect(flyer.touches_player(), "a player's diagonal mirror participates in enemy contact")
	flyer.position = Vector2(200, 80)
	_place(target, Vector2(200, 166))
	expect(flyer.touches_player(), "the standing player's head touches the bottom of the contact rectangle")
	target.set_crouched(true)
	expect(not flyer.touches_player(), "crouching ends contact in the same tick")
	flyer.state = EnemyBase.State.CHARGE
	flyer.motion_contacts.append([target.rid, Vector2.LEFT, target.position, target.get_instance_id()])
	flyer.time_field.mode = WorldTime.Mode.REWIND
	flyer.simulate_tick(ActorStep.DT)
	expect(not flyer.is_dead, "a suspended charge cannot process a contact from an earlier tick")
	flyer.time_field.mode = WorldTime.Mode.NONE
	var biting := parent.combat.add_enemy("jump_bird", target, Vector2(200, 80))
	_place(target, Vector2(275, 80))
	var hp := target.sim_hp
	biting.simulate_tick(ActorStep.DT)
	biting.simulate_tick(ActorStep.DT)
	expect(target.sim_hp == hp - biting.kind.contact_damage, "entering melee contact deals damage and standing in it respects iframes")
	target.sim_iframes = 0.0
	_place(target, Vector2(400, 80))
	biting.simulate_tick(ActorStep.DT)
	expect(target.sim_hp == hp - biting.kind.contact_damage, "leaving the contact rectangle ends melee damage")
	cleanup()

func _grain_rewards(tree: SceneTree) -> void:
	var parent := world(tree)
	var combat := parent.combat
	var account := GrainAccount.new(0.0)
	var field := WorldTime.new(account)
	combat.time_field = field
	var elite := combat.add_enemy("black_bird", player(parent), Vector2.ZERO) as EnemyBlackBird
	elite._begin_death()
	for i in TCFG.ELITE_GRAIN_DELAY_TICKS - 1:
		field.step_rewards()
	expect(field.account.balance == 0.0, "crystals wait for the reward tick")
	field.step_rewards()
	expect(account.balance == TCFG.ELITE_GRAIN_DROP,
			"the elite's reward settles on its tick without a camera, HUD, or crystal effect")
	field.step_rewards()
	expect(account.balance == TCFG.ELITE_GRAIN_DROP, "the reward is delivered once")
	cleanup()

func _shared_rewind_history(tree: SceneTree) -> void:
	var parent := world(tree)
	var first := player(parent, 1)
	var second := player(parent, 2)
	var sim := parent.combat
	var time := PersonalTime.new({}, [1, 2])
	var dt := 1.0 / TCFG.SNAP_HZ
	var id := ShotRules.shot_id(first.role, 1)
	var shell := sim.spawn_projectile(id, WeaponType.GRENADE, first, Vector2(180, 64), Vector2.RIGHT)
	var gone := ShotRules.shot_id(first.role, 2)
	sim.spawn_projectile(gone, WeaponType.PISTOL, first, Vector2(260, 64), Vector2.LEFT)
	var remote := sim.spawn_projectile(ShotRules.shot_id(second.role, 1), WeaponType.PISTOL,
			second, Vector2(310, 64), Vector2.RIGHT)
	for i in range(1, 4):
		sim.tick = i * 3
		first.position.x = 100.0 + i
		second.position.x = 200.0 + i
		shell.position.x = 180.0 + i
		shell.fuse_elapsed = i * 0.01
		remote.position.x = 310.0 + i
		for actor: Player in [first, second]:
			time.histories[actor.role].record(dt, sim.tick, PersonalTime._sample.bind(sim, actor))
	sim.erase_projectile(gone)
	sim.submit_blast(ShotRules.shot_id(1, 3), shell.position, WeaponType.GRENADE)
	var pending := sim.pending_blasts.duplicate(true)
	var sub := Vector2i(8, 12)
	sim.terrain.apply_at(sim.terrain.version, {sub: 0})
	ActorStep.step(first, _attack(0, ActorInput.BIT_DROP))
	first.shot_serial = 8
	first.waterproof = 1
	shell.impact_collider_id = second.get_instance_id()
	ShotRules._projectile_hit(sim, shell, Vector2.RIGHT)
	var hit_hp := second.sim_hp
	var late_id := ShotRules.shot_id(first.role, 8)
	sim.spawn_projectile(late_id, WeaponType.PISTOL, first, Vector2(220, 64), Vector2.RIGHT)
	time.advance(sim, {1: _attack(ActorInput.BIT_REWIND, 0), 2: NEUTRAL_INPUT}, 10)
	expect(first.position.x == 102.0 and shell.position.x == 182.0 and is_equal_approx(shell.fuse_elapsed, 0.02)
			and second.position.x == 203.0 and remote.position.x == 313.0 and sim.tick == 9,
			"personal rewind restores just its player and the motion of surviving owned projectiles")
	ShotRules._projectile_hit(sim, shell, Vector2.RIGHT)
	expect(shell.direct_hit and second.sim_hp == hit_hp and not sim.projectiles.has(gone) and sim.projectiles.has(late_id)
			and sim.pending_blasts == pending and sim.terrain.get_hp(sub) == 0 and first.waterproof == first.max_waterproof
			and first.equipped == null and first.shot_serial == 8 and sim.ground.items.size() == 1,
			"personal restore preserves world effects, settled hits, projectile lifetimes, weapon ownership and shot IDs")
	time.advance(sim, {1: NEUTRAL_INPUT, 2: _attack(ActorInput.BIT_REWIND, 0)}, 11)
	expect(second.position.x < 203.0 and first.position.x == 102.0 and remote.position.x < 313.0,
			"one player's new branch leaves the other player's past intact")
	cleanup()

func _personal_rewind() -> void:
	var mode := WorldSpec.ROYALE
	var host := arena(mode, [1, 2, 3], {}, RoomOptions.normalized(mode, {"max_players": 3, "beta": true}))
	var server := host.world
	expect(server.problem.is_empty(), "authority creates an arena with personal time skills")
	server.rules.phase = MatchRules.Phase.PLAYING
	var first := server.players[1]
	var second := server.players[2]
	first.weapons.set_initial_inventory([WeaponType.RIFLE])
	var epoch := host._buffers[1].epoch
	for at in range(1, 11):
		first.sim_hp = 20 + at
		second.sim_hp = 30 + at
		host.fixed_step()
	var account := server.personal_time.accounts[1]
	var balance := account.balance
	var both := ActorInput.BIT_REWIND | ActorInput.BIT_HASTE
	host.fixed_step({1: _attack(both, 0)})
	expect(first.rewinding and first.sim_hp == 26 and second.sim_hp == 40 and server.tick == 11
			and first.personal_haste_mult == 1.0
			and is_equal_approx(account.balance, balance - ActorStep.DT * server.personal_time.rules["rewind_burn"]),
			"rewind has priority and restores health while the commit clock advances")
	host.fixed_step({1: _attack(both, 0), 2: _attack(ActorInput.BIT_REWIND, 0)})
	expect(first.rewinding and second.rewinding and first.sim_hp == 23 and second.sim_hp == 36,
			"two concurrent personal rewinds select different moments")
	host.fixed_step({1: _attack(ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK), 2: _attack(ActorInput.BIT_REWIND, 0)})
	expect(not first.rewinding and host._buffers[1].epoch == epoch + 1 and first.shot_serial == 0
			and second.rewinding and host._buffers[2].epoch == epoch and server.tick == 13,
			"releasing one skill discards stale actions and leaves the other branch and input epoch alone")
	second.force_down()
	second.respawn_tick = server.tick + 1
	host.fixed_step()
	expect(not second.rewinding and host._buffers[2].epoch == epoch + 1,
			"respawning during a rewind starts one new input epoch")
	host.fixed_step({2: _attack(ActorInput.BIT_REWIND, 0)})
	expect(not second.rewinding and second.sim_hp == second.sim_max_hp,
			"respawn discards all personal samples from the previous life")
	host.enqueue(MatchWorld.Command.LEAVE, 3)
	host.fixed_step()
	expect(not server.personal_time.histories.has(3), "a departing player releases its history")
	host.close()
