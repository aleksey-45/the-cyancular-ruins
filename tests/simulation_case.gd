extends "res://tests/simulation_fixture.gd"

func run(tree: SceneTree) -> void:
	_equipment(tree)
	_inventory_rewind(tree)
	_compound_bow(tree)
	_m249(tree)
	_rounds(tree)
	_grenade(tree)
	_beam(tree)
	_melee(tree)
	_blast(tree)
	_shared_combat_tick(tree)
	_pickup_order(tree)
	_pickup_landing(tree)

func _equipment(tree: SceneTree) -> void:
	var ids := WeaponRegistry.enabled_ids()
	expect(ids == WeaponRegistry.CATALOG.weapons.map(func(weapon: WeaponDef) -> int: return weapon.weapon_id)
			and ids.all(func(id: int) -> bool: return id > 0 and id <= 255),
			"the catalog supplies unique wire IDs in resource order")
	var parent := world(tree)
	var actor := player(parent)
	var initial := actor.capture_state()
	for tick in 32:
		ActorStep.step(actor, NEUTRAL_INPUT)
		if actor.capture_state()[FLOOR]: break
	expect(actor.capture_state()[FLOOR] and actor.position.y < 192, "real terrain stops a falling actor")
	actor.restore_state(initial)
	ActorStep.step(actor, FORWARD_INPUT)
	expect(actor.position.x > initial[POS].x, "movement still uses the real actor shape")
	var display := _display(parent, actor)
	var attack := ActorInput.BIT_ATTACK
	for type_id: int in ids:
		var spec := WeaponRegistry.definition(type_id)
		actor.weapons.set_initial_inventory([type_id])
		var sim := parent.combat
		var before := actor.capture_state()
		var record := _attack(attack, attack)
		if spec["trigger"] in [WeaponDef.Trigger.RELEASE, WeaponDef.Trigger.CHARGE_RELEASE]:
			expect(_fires(ActorStep.step(actor, record)).is_empty() and (actor.equipped as GunBody).aiming,
					"release weapon %d aims on press" % type_id)
			record = _attack(0, 0, attack)
			before = actor.capture_state()
		elif spec["trigger_delay"] > 0.0:
			var quiet := true
			for tick in roundi(spec["trigger_delay"] / ActorStep.DT) - 1:
				quiet = _fires(ActorStep.step(actor, record)).is_empty() and quiet
				record = _attack(attack, 0)
			expect(quiet, "delayed automatic weapon waits for its trigger time")
			before = actor.capture_state()
		var actions := ActorStep.step(actor, record)
		var after := actor.capture_state()
		var spent := int(spec.has("mag"))
		expect(_fires(actions).size() == 1 and after[INV][WeaponInventory.CARRIED] == before[INV][WeaponInventory.CARRIED] - spent,
				"equipped rule %d produces one shot and accounts for ammo" % type_id)
		_draw_actor(display, actor)
		expect(actor.capture_state() == after, "presentation leaves rule %d unchanged" % type_id)
		actor.restore_state(before)
		expect(ActorStep.step(actor, record) == actions and actor.capture_state() == after,
				"restored rule %d reproduces both state and muzzle action" % type_id)
		submit(actor, actions)
		var count := int(spec["count"]) if spec["attack"] == WeaponDef.Attack.PROJECTILE else 0
		expect(sim.projectiles.size() == count, "shot %d produces the configured number of projectiles" % type_id)
		sim.clear()

	display.free()
	var weapons := actor.weapons
	weapons.set_initial_inventory([WeaponType.RIFLE, WeaponType.COMPOUND_BOW])
	actor.equipped.carried = 3
	var added := weapons.pick_up(WeaponType.PISTOL, 5)
	expect(added == {"ok": true, "dropped": {}} and weapons.snapshot()[WeaponInventory.CARRIED] == 3,
			"pickup fills available space and saves the previous weapon's ammo")
	actor.equipped.fire_cd_timer = 0.25
	var full_loadout := actor.capture_state()
	expect(not weapons.pick_up(WeaponType.M249, 7)["ok"] and actor.capture_state() == full_loadout,
			"replacing a pistol with a heavy weapon at capacity leaves the loadout intact")
	actor.equipped.carried = 4
	var inst := weapons.current_inst()
	var replaced := weapons.pick_up(WeaponType.PISTOL, 1)
	var replacement_inst := weapons.current_inst()
	expect(replaced == {"ok": true, "dropped": {"type": WeaponType.PISTOL, "carried": 4}}
			and replacement_inst > inst and weapons.inst_at_index(2) == replacement_inst
			and actor.equipped.carried == 1 and actor.equipped.fire_cd_timer == 0.25,
			"a same-type replacement gets a fresh ID and keeps its slot, both ammo counts and cooldown")
	actor.restore_state(full_loadout)
	var restored_inst := weapons.current_inst()
	weapons.pick_up(WeaponType.PISTOL, 1)
	expect(restored_inst == inst and weapons.current_inst() == replacement_inst,
			"exact restoration reuses the captured weapon allocator on the new branch")
	cleanup()

func _inventory_rewind(tree: SceneTree) -> void:
	var actor := player(world(tree))
	var weapons := actor.weapons
	weapons.set_initial_inventory([WeaponType.RIFLE, WeaponType.PISTOL])
	var rifle := weapons.current_inst()
	var pistol := weapons.inst_at_index(1)
	weapons.equip_inst(pistol)
	actor.equipped.carried = 5
	weapons.equip_inst(rifle)
	actor.equipped.carried = 3
	var snapshot := actor.capture_state()
	expect(weapons.snapshot()[WeaponInventory.CARRIED] == 3, "equipped ammo is stored directly in its inventory slot")
	var active := actor.equipped
	var authority_state := actor.capture_state()
	actor.restore_state(authority_state)
	actor.equipped.carried = 1
	expect(actor.equipped == active and authority_state[INV][WeaponInventory.CARRIED] == 3,
			"restoring the same active weapon keeps its in-hand state object independent of snapshot ammo")
	expect(snapshot == authority_state and snapshot[INV][WeaponInventory.CARRIED] == 3,
			"rewind and reconciliation capture the same player state and independent ammo")
	weapons.equip_inst(pistol)
	actor.rewind_state(snapshot, true)
	expect(weapons.current_inst() == rifle and actor.equipped.carried == 3,
			"solo rewind re-equips a still-owned weapon with its historical ammo")

	var dropped := weapons.drop_current()
	weapons.pick_up(dropped["type"], 9)
	var picked_up := weapons.current_inst()
	weapons.equip_inst(pistol)
	actor.equipped.carried = 1
	weapons.equip_inst(picked_up)
	actor.rewind_state(snapshot, true)
	expect(weapons.inst_at_index(0) == pistol and weapons.inst_at_index(1) == picked_up and picked_up > rifle
			and weapons.current_inst() == picked_up and actor.equipped.carried == 9
			and weapons.snapshot()[WeaponInventory.CARRIED] == 5,
			"solo rewind keeps ownership and restores ammo only to the same instance")

	var ground := actor.combat.ground
	var buttons := ActorInput.BIT_PICKUP | ActorInput.BIT_DROP
	var record := _attack(0, buttons)
	actor._controls_locked = true
	actor.equipped.fire_cd_timer = ActorStep.DT
	actor.equipped.fire_buffered = true
	expect(_fires(ActorStep.step(actor, record)).is_empty()
			and not actor.equipped.fire_buffered, "locked controls clear buffered attacks")
	actor._controls_locked = false
	actor.rewinding = true
	ActorStep.step(actor, record)
	expect(ground.items.is_empty(), "locked and rewinding actors keep their weapon")
	actor.rewinding = false
	actor.force_down()
	ActorStep.step(actor, record)
	expect(ground.items.is_empty(), "downed actors keep their weapon")
	actor.apply_authoritative_state(actor.sim_max_hp, actor.max_waterproof, false)
	ActorStep.step(actor, record)
	expect(ground.items.size() == 1, "only an active actor can pick up or drop items")
	cleanup()

func _compound_bow(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 32, 32, {})
	var actor := player(parent)
	var sim := parent.combat
	_place(actor, Vector2(384, 384))
	actor.weapons.set_initial_inventory([WeaponType.COMPOUND_BOW])
	var bow := actor.equipped as GunBody
	var attack := ActorInput.BIT_ATTACK
	expect(bow.carried == 1, "a fresh bow carries one arrow")
	expect(_fires(ActorStep.step(actor, _attack(0, 0, attack))).is_empty(),
			"a release on a newly equipped bow does not fire")
	var tap := _fires(ActorStep.step(actor, _attack(0, attack, attack)))
	expect(tap.size() == 1 and tap[0]["charge"] == 0.0, "a tap shoots at minimum charge")
	submit(actor, tap)
	var tap_id := ShotRules.shot_id(actor.role, tap[0]["serial"])
	expect(is_equal_approx(sim.projectiles[tap_id].velocity.length(), 600.0) and bow.carried == 0 and bow.reloading,
			"a tap launches at 600 px/s and immediately starts reloading the one-arrow bow")
	sim.erase_projectile(tap_id)
	var hold := _attack(attack, 0)
	ActorStep.step(actor, hold)
	expect(not bow.aiming, "the bow cannot draw during reload")
	for tick in 74:
		ActorStep.step(actor, NEUTRAL_INPUT)
	expect(not bow.reloading and bow.carried == 1, "reload restores exactly one arrow")
	actor.reset_motion()
	_place(actor, Vector2(384, 384))
	for tick in 36:
		ActorStep.step(actor, hold)
	var drawn := actor.capture_state()
	var display := _display(parent, actor)
	_draw_actor(display, actor)
	var guide := display._frame.aim_guide
	var guide_next := guide[1]
	var canvas := display._world._canvas
	var sprite: Array = canvas._batches[canvas._batch_count - 1].rows[-1]
	var nocked: Transform2D = sprite[2]
	expect(sprite[0] == WorldView.BULLETS and nocked.origin.is_equal_approx(guide[0]),
			"the drawn arrow is centered at the start of its guide")
	var release := ActorStep.step(actor, _attack(0, 0, attack))
	submit(actor, release)
	var arrow: BulletBody = sim.projectiles.values()[0]
	var id := arrow.entity_id
	expect(arrow.hit_damage == 29 and is_equal_approx(arrow.velocity.length(), 2040.0)
			and arrow.position.is_equal_approx(nocked.origin),
			"the released arrow starts from the drawn arrow and takes its speed and damage from the draw")
	var spread := deg_to_rad(bow.definition["spread"])
	var max_spread_offset := 2.0 * arrow.velocity.length() * ActorStep.DT * sin(spread * 0.5)
	sim.step_projectile(arrow, ActorStep.DT)
	expect(arrow.position.distance_to(guide_next) <= max_spread_offset + 0.001
			and canvas._marks.is_empty(),
			"the first arrow step stays within spread of the guide without an explosion marker")

	sim.time_field = WorldTime.new(GrainAccount.new())
	_record_time(sim, actor)
	sim.erase_projectile(id)
	_record_time(sim, actor)
	sim.time_field.rewind(sim, actor, 1.0)
	expect(sim.projectiles[id].hit_damage == 29, "rewinding restores the damage of an expired arrow")
	sim.time_field.mode = WorldTime.Mode.NONE
	actor.rewind_state(drawn, true)
	expect(is_equal_approx((actor.equipped as GunBody).charge_ratio(), 0.8),
			"single-player rewind restores a partially drawn bow")
	for tick in 9:
		ActorStep.step(actor, hold)
	expect((actor.equipped as GunBody).charge_ratio() == 1.0, "45 ticks reach full draw")
	ActorStep.step(actor, hold)
	expect((actor.equipped as GunBody).charge_ratio() == 1.0, "holding past full draw keeps charge capped")
	display.free()
	cleanup()

func _m249(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent)
	actor.weapons.set_initial_inventory([WeaponType.M249, WeaponType.PISTOL])
	var attack := ActorInput.BIT_ATTACK
	var hold := _attack(attack, 0)
	var gun := actor.equipped as GunBody
	expect(gun.carried == 100 and _fires(ActorStep.step(actor, hold, 0.2)).is_empty(),
			"M249 starts with 100 rounds and waits while the trigger is held")
	ActorStep.step(actor, _attack(0, 0, attack))
	expect(gun.hold_elapsed == 0.0 and _fires(ActorStep.step(actor, hold, 0.2)).is_empty(),
			"releasing the trigger starts a fresh delay")
	var switch := hold.duplicate()
	switch[ActorInput.WINST] = actor.weapons.inst_at_index(1)
	ActorStep.step(actor, switch)
	switch[ActorInput.WINST] = actor.weapons.inst_at_index(0)
	ActorStep.step(actor, switch)
	gun = actor.equipped as GunBody
	expect(is_equal_approx(gun.hold_elapsed, ActorStep.DT), "switching equipment clears the previous trigger hold")
	gun.carried = 1
	expect(_fires(ActorStep.step(actor, hold, 0.3)).size() == 1 and gun.carried == 0 and gun.reloading,
			"the last M249 round starts the normal reload")
	expect(_fires(ActorStep.step(actor, hold)).is_empty(), "a held trigger cannot fire during reload")
	gun.reload_left = ActorStep.DT
	ActorStep.step(actor, NEUTRAL_INPUT)
	expect(not gun.reloading and gun.carried == 100, "M249 reload fills its magazine")
	cleanup()

func _rounds(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var sim := parent.combat
	var bullet := sim.spawn_projectile(1, WeaponType.PISTOL, actor,
			Vector2(136, 160), Vector2.DOWN * 900.0)
	var hit_sub := Vector2i(8, 12)
	var before := _terrain.get_hp(hit_sub)
	for i in 4:
		sim.step_projectiles(ActorStep.DT)
		if sim.projectiles.is_empty(): break
	expect(sim.projectiles.is_empty(), "an ordinary round ends on terrain contact")
	expect(_terrain.get_hp(hit_sub) == before - bullet.hit_damage
			and _terrain.get_hp(hit_sub + Vector2i.ONE) == before - bullet.hit_damage
			and _terrain.get_hp(hit_sub + Vector2i(2, 0)) == before,
			"a swept projectile immediately damages only the 32 px block at the contact point")
	cleanup()
	var walls := {}
	for x in 8: walls[Vector2i(x, 3)] = wall_texture(true)
	parent = world_with_walls(tree, 8, 4, walls)
	actor = player(parent)
	for i in 40:
		ActorStep.step(actor, NEUTRAL_INPUT)
		if not actor.motion_contacts.is_empty(): break
	expect(not actor.motion_contacts.is_empty() and is_equal_approx(actor.velocity.y, -CFG.elastic_bounce),
			"actor bounces from elastic RID-backed terrain")
	cleanup()
	parent = world_with_walls(tree, 16, 16, {})
	var shooter := player(parent, 1)
	var victim := player(parent, 2)
	var ally := player(parent, 3)
	_place(shooter, Vector2(200, 512), 1)
	_place(victim, Vector2(80, 512), 2)
	_place(ally, Vector2(5, 512), 1)
	for actor_with_team: Player in [shooter, victim, ally]:
		actor_with_team.set_team_collision(actor_with_team.team, false)
	sim = parent.combat
	var hp := victim.sim_hp
	bullet = sim.spawn_projectile(1, WeaponType.PISTOL, shooter,
			Vector2(1000, 512), Vector2.RIGHT * 30000.0)
	sim.step_projectiles(ActorStep.DT)
	expect(victim.sim_hp == hp - bullet.hit_damage and ally.sim_hp == ally.sim_max_hp and sim.projectiles.is_empty(),
			"without body blocking, a fast round still crosses the seam and passes through an ally to hit an opponent")
	expect(bullet.position.x >= 0.0 and bullet.position.x < _terrain.map_size.x,
			"the swept impact also returns to canonical coordinates")
	victim.force_down()
	victim.sync_collision_geometry()
	hp = victim.sim_hp
	sim.spawn_projectile(2, WeaponType.PISTOL, shooter,
			Vector2(1000, 512), Vector2.RIGHT * 30000.0)
	sim.step_projectiles(ActorStep.DT)
	expect(victim.sim_hp == hp and sim.projectiles.is_empty(),
			"the downed hull consumes the round without taking damage")
	cleanup()

func _grenade(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var shooter := player(parent, 1)
	var victim := player(parent, 2)
	_place(shooter, Vector2(200, 512), 1)
	_place(victim, Vector2(600, 512), 2)
	var sim := parent.combat

	var type_id := WeaponType.GRENADE
	shooter.weapons.set_initial_inventory([type_id, WeaponType.PISTOL])
	var bullet := sim.spawn_projectile(1, type_id, shooter, Vector2(500, 512), Vector2.RIGHT * 6000.0)
	var hp := victim.sim_hp
	victim.rewinding = true
	bullet.impact_collider_id = victim.get_instance_id()
	ShotRules._projectile_hit(sim, bullet, Vector2.RIGHT)
	expect(not bullet.direct_hit and victim.sim_hp == hp, "an immune player does not consume the grenade's direct hit")
	victim.rewinding = false
	sim.step_projectiles(ActorStep.DT)
	expect(bullet.impact_actor() == victim and victim.sim_hp == hp - bullet.hit_damage and bullet.direct_hit,
			"a grenade bouncing off a player applies the direct hit once")
	expect(bullet.velocity.x < 0.0 and is_equal_approx(bullet.fuse_duration, 0.1),
			"the direct hit arms the short fuse and reflects velocity")
	var settled := victim.sim_hp
	for tick in range(1, 12):
		sim.tick = tick
		sim.step_projectiles(ActorStep.DT)
	expect(victim.sim_hp == settled and sim.pending_blasts.keys() == [1] and sim.projectiles.is_empty(),
			"the grenade detonates once without repeating contact damage")
	sim.finish_match()
	for id in [2, 3, 4]:
		sim.spawn_projectile(id, type_id, shooter, Vector2(50 + id, 100), Vector2.RIGHT)
	var pistol: int = shooter.weapons.inst_at_index(1)
	var grenade := shooter.weapons.current_inst()
	shooter.weapons.equip_inst(pistol)
	shooter.weapons.equip_inst(grenade)
	var before := shooter.equipped.carried
	var release := _attack(0, 0, ActorInput.BIT_ATTACK)
	expect(_fires(ActorStep.step(shooter, release)).is_empty() and shooter.equipped.carried == before
			and shooter.equipped.fire_cd_timer == 0.0,
			"the cap counts live grenades across equipment switches without spending ammo or cooldown")
	sim.erase_projectile(2)
	expect(_fires(ActorStep.step(shooter, release)).size() == 1,
			"removing a live grenade opens a slot for the next launch")
	var ranged := sim.projectiles[3]
	ranged.max_range = 0.0
	sim.step_projectile(ranged, ActorStep.DT)
	expect(sim.pending_blasts.keys() == [3], "reaching maximum range detonates an unarmed grenade")
	cleanup()

func _beam(tree: SceneTree) -> void:
	var texture := wall_texture()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(14, 8): texture})
	var shooter := player(parent, 1)
	var near := player(parent, 2)
	var far := player(parent, 3)
	var ally := player(parent, 4)
	_place(shooter, Vector2(200, 544), 1)
	_place(near, Vector2(480, 544), 2)
	_place(far, Vector2(650, 544), 2)
	_place(ally, Vector2(340, 544), 1)
	shooter.weapons.set_initial_inventory([WeaponType.LASER])
	var attack := ActorInput.BIT_ATTACK
	var shots := ActorStep.step(shooter, _attack(attack, attack))
	var before := near.sim_hp
	var cell := Vector2i(14, 8)
	_terrain.damage_beam(cell * 4, _terrain.get_hp(cell * 4) - 1)
	var sim := parent.combat
	sim.time_field = WorldTime.new(GrainAccount.new())
	_terrain.commit()
	_record_time(sim, shooter)
	var fired := sim.resolve_requests([shooter.role])
	var beams: Array = [fired.values()[0]["vectors"]]
	var damage: int = WeaponRegistry.definition(WeaponType.LASER)["damage"]
	expect(near.sim_hp == before - damage and far.sim_hp == before - damage,
			"the authoritative beam hits multiple targets, each once across reflections")
	expect(ally.sim_hp == before and shooter.sim_hp == before, "the beam skips its shooter and allies")
	expect(_terrain.material_at(cell * 4) == 0, "the first beam destroys the wall in terrain data immediately")
	ActorStep.step(ally, NEUTRAL_INPUT)
	var bullet := sim.spawn_projectile(1, WeaponType.PISTOL, shooter,
			Vector2(872, 544), Vector2.RIGHT * 3000.0)
	sim.step_projectile(bullet, ActorStep.DT)
	expect(sim.projectiles.is_empty(), "a projectile still collides with the broken wall in the same tick")
	var next: Dictionary = shots[0].duplicate()
	next["serial"] += 1
	beams.append(sim.fire(shooter, next)["vectors"])
	expect(beams.size() == 2 and beams[0].size() >= 3 and beams[0] == beams[1],
			"actor and projectile steps do not rebuild terrain collision between beams")
	_terrain.commit()
	next["serial"] += 1
	beams.append(sim.fire(shooter, next)["vectors"])
	expect(beams.back().size() == 2, "the tick-end collision refresh removes the wall for the following beam")
	var laser := WeaponRegistry.definition(WeaponType.LASER)
	WeaponRegistry._definitions[WeaponType.LASER] = laser.merged({"min_damage": 2})
	next["charge"] = 0.25
	next["serial"] += 1
	before = near.sim_hp
	sim.fire(shooter, next)
	WeaponRegistry._definitions[WeaponType.LASER] = laser
	expect(near.sim_hp == before - 3, "a charged beam uses its interpolated damage")
	_terrain.commit()
	var lit := sim.beams.duplicate()
	_record_time(sim, shooter)
	for i in CombatSimulator.BEAM_TICKS:
		sim.step({})
	_record_time(sim, shooter)
	expect(lit.size() == 4 and sim.beams.is_empty(), "overlapping beams expire after fifteen simulation ticks")
	sim.time_field.rewind(sim, shooter, (1.0 / TCFG.SNAP_HZ) * 0.5 / TCFG.REWIND_START_MULT)
	expect(sim.beams == lit, "world rewind restores the original paths after the wall was destroyed")
	sim.time_field.rewind(sim, shooter, 1.0)
	expect(sim.beams.is_empty(), "rewinding past the shots removes their beams")
	cleanup()

func _melee(tree: SceneTree) -> void:
	const TYPE_ID := 9
	var melee := WeaponDef.new()
	melee.weapon_id = TYPE_ID
	melee.attack = WeaponDef.Attack.MELEE
	melee.data = {
		"tier": WeaponInventory.TIER_LIGHT, "muzzle": Vector2.ZERO, "pitch": 90.0, "recoil": 0.0,
		"cooldown": 0.3, "damage": 7, "impact": 120.0, "range": 115.0, "hit_radius": 16.0,
	}
	WeaponRegistry._definitions.merge(WeaponRegistry._load_definitions([melee]))
	var parent := world_from_solid(tree, 8, 8, func(x: int, y: int) -> bool: return x == 3 and y == 8)
	var shooter := player(parent, 1)
	var target := player(parent, 2)
	var ally := player(parent, 3)
	var blocked := player(parent, 4)
	_place(shooter, Vector2(470, 136), 1)
	_place(target, Vector2(20, 136), 2)
	_place(ally, Vector2(504, 136), 1)
	_place(blocked, Vector2(68, 136), 2)
	shooter.weapons.set_initial_inventory([TYPE_ID])
	var sim := parent.combat
	var attack := ActorInput.BIT_ATTACK
	var shots := ActorStep.step(shooter, _attack(attack, attack | ActorInput.BIT_RELOAD))
	submit(shooter, shots)
	expect(_fires(shots).size() == 1 and not shooter.equipped.reloading and not shooter.equipped.has_magazine()
			and shooter.equipped.carried == WeaponInventory.DEFAULT_CARRIED and sim.projectiles.is_empty(),
			"melee uses the usual input and equip path without consuming ammo or spawning a projectile")
	expect(target.sim_hp == target.sim_max_hp - 7 and blocked.sim_hp == blocked.sim_max_hp
			and ally.sim_hp == ally.sim_max_hp and shooter.sim_hp == shooter.sim_max_hp,
			"melee hits once across a seam and respects walls and teams")
	expect(target.motion_knock_velocity.is_equal_approx(Vector2(120.0, 0.0)),
			"melee pushes the target away from the attacker across the seam")
	cleanup()
	_combat_phase(tree, TYPE_ID)
	WeaponRegistry._definitions.erase(TYPE_ID)

func _combat_phase(tree: SceneTree, melee_type: int) -> void:
	for type_id: int in [WeaponType.LASER, WeaponType.PISTOL, melee_type]:
		var parent := world_with_walls(tree, 16, 16, {})
		var shooter := player(parent, 1)
		var target := player(parent, 2)
		_place(shooter, Vector2(200, 544), 1)
		_place(target, Vector2(335, 544), 2)
		target.motion_knock_velocity = Vector2(600, 0)
		shooter.weapons.set_initial_inventory([type_id])
		var shot := _attack(ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)
		var sim := parent.combat
		var fired := sim.step({shooter.role: shot, target.role: NEUTRAL_INPUT})
		expect(fired.size() == 1 and fired.values()[0]["type_id"] == type_id,
				"attack %d resolves one shot in the shared step" % type_id)
		expect(is_equal_approx(target.position.x, 345.0) and sim.hits.size() == 1,
				"attack type %d hits after the later role completes its movement" % type_id)
		cleanup()

func _blast(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {Vector2i(15, 8): wall_texture()})
	var near := player(parent, 1)
	var across := player(parent, 2)
	var far := player(parent, 3)
	_place(near, Vector2(900, 544), 1)
	_place(across, Vector2(35, 544), 2)
	_place(far, Vector2(360, 544), 2)
	var sim := parent.combat
	var enemy := sim.add_enemy("jump_bird", near, Vector2(936, 530))
	var enemy_hp := enemy.hp
	var cell := Vector2i(15, 8)
	var wall := block_hp(_terrain, cell)
	var hp := near.sim_hp
	near.sim_iframes = 1.0
	sim.tick = 100
	sim.submit_blast(ShotRules.shot_id(near.role, 1), Vector2(936, 544), WeaponType.GRENADE)
	for at in [100, 101, 102]:
		sim.tick = at
		sim.settle_blasts()
		expect(near.sim_hp == hp and enemy.hp == enemy_hp and block_hp(_terrain, cell) == wall,
				"actors and terrain wait until three ticks after detonation")
	sim.tick = 103
	sim.settle_blasts()
	expect(near.sim_hp < hp and across.sim_hp < hp and far.sim_hp == hp and enemy.hp < enemy_hp,
			"one blast reaches players and enemies across the seam and respects its radius")
	expect(block_hp(_terrain, cell) != wall, "blast damage reaches terrain on the same tick")
	var after := near.sim_hp
	sim.settle_blasts()
	expect(near.sim_hp == after and sim.pending_blasts.is_empty(), "each blast settles once")
	cleanup()

func _shared_combat_tick(tree: SceneTree) -> void:
	var local := world(tree)
	var host := world(tree)
	var solo_player := player(local)
	var host_player := player(host)
	for actor: Player in [solo_player, host_player]:
		_place(actor, Vector2(260, 135))
		actor.weapons.set_initial_inventory([WeaponType.GRENADE])
	var single := local.combat
	single.time_field = WorldTime.new(GrainAccount.new())
	var server := host.combat
	var id := ShotRules.shot_id(1, 1)
	var due := 0
	var hit_at := 0
	var direction := Vector2(0.3, 1.0).normalized()
	var held := ActorInput.BIT_DOWN
	var floor_cell := Vector2i(4, 3)
	var original := block_hp(single.terrain, floor_cell)
	var damaged_at := 0
	for at in range(1, 46):
		var release := ActorInput.BIT_ATTACK if at == 1 else 0
		var record := {1: [0.0, held, 0, release, 0, direction]}
		single.time_field.advance(single, solo_player, held, at)
		single.hits.clear()
		single.step(record)
		server.step(record)
		var floor_state := block_hp(single.terrain, floor_cell)
		expect(single.tick == server.tick and solo_player.capture_state() == host_player.capture_state()
				and single.capture_projectiles() == server.capture_projectiles() and single.pending_blasts == server.pending_blasts
				and floor_state == block_hp(server.terrain, floor_cell),
				"the same input produces the same solo and arena combat state at tick %d" % at)
		if at == 1:
			expect(single.projectiles.has(id) and single.projectiles[id].traveled > 0.0,
					"the same release launches and moves the grenade on the firing tick")
		if single.pending_blasts.has(id):
			due = single.pending_blasts[id][CombatSimulator.Blast.DUE]
		if not single.hits.is_empty():
			hit_at = at
		if damaged_at == 0 and floor_state != original:
			damaged_at = at
	expect(due > 3 and hit_at == due and damaged_at == due,
			"the same pending blast settles both HP and terrain on its due tick")
	cleanup()

func _pickup_order(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	actor.position = Vector2(0, 64)
	var ground := GroundWeaponField.new(_terrain)
	var one := ground.spawn( WeaponType.PISTOL, 1, Vector2(_terrain.map_size.x - 24, 64), Vector2.ZERO)
	var two := ground.spawn( WeaponType.PISTOL, 2, Vector2(24, 64), Vector2.ZERO)
	ground.items.erase(one.inst)
	ground.items[one.inst] = one
	expect(ground.nearest(actor) == one, "pickup ties across the seam choose the lowest ID regardless of insertion order")
	one.locked_role = actor.role
	one.unlock_tick = 30
	expect(ground.nearest(actor) == two, "a locked pickup does not hide the next eligible one")
	ground.tick = one.unlock_tick
	ground.handle_actions(actor, _attack(0, ActorInput.BIT_PICKUP))
	expect(not ground.items.has(one.inst) and not one.rid.is_valid() and actor.equipped.carried == 1,
			"the owner can pick up at the deadline and the body is released even with a reference to the item")
	ground.clear()
	expect(not two.rid.is_valid(), "clearing the field immediately removes every remaining collider")
	cleanup()

func _pickup_landing(tree: SceneTree) -> void:
	var parent := world(tree)
	var floor_y := 12.0 * CyrmMap.CELL_SIZE
	var before := parent.get_child_count()
	var field := GroundWeaponField.new(_terrain)
	for preplaced in [true, false]:
		var at := Vector2(160.0 if preplaced else 352.0, floor_y - CyrmMap.CELL_SIZE * 0.5)
		var bow := field.spawn( WeaponType.COMPOUND_BOW, WeaponInventory.DEFAULT_CARRIED, at, Vector2.ZERO)
		if preplaced:
			bow.settle_on_spawn_floor()
		else:
			for i in 60: field.step(ActorStep.DT)
		var bottom := bow.position.y + bow.shape.size.y * 0.5
		expect(bow._settled and absf(bottom - floor_y) < 0.5,
				"a map bow spawns on the floor" if preplaced else "a bow pushed out of terrain falls back to the floor")
	expect(parent.get_child_count() == before, "ground weapons simulate without adding scene nodes")
	field.clear()
	cleanup()
