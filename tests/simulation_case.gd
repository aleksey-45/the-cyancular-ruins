extends "res://tests/case.gd"

const NEUTRAL_INPUT := [0.0, 0, 0, 0, 0, Vector2.RIGHT]
const FORWARD_INPUT := [1.0, 0, 0, 0, 0, Vector2.RIGHT]

const POS: int = PlayerStateSchema.POS
const FLOOR: int = PlayerStateSchema.GROUNDED
const INV: int = PlayerStateSchema.INVENTORY

func run(tree: SceneTree) -> void:
	_equipment(tree)
	_inventory_rewind(tree)
	_compound_bow(tree)
	_m249(tree)
	_rounds(tree)
	_water(tree)
	_grenade(tree)
	_beam(tree)
	_melee(tree)
	_blast(tree)
	_world_rewind(tree)
	_rewind_window(tree)
	_enemy_time(tree)
	_beta_history(tree)
	_dynamic_blocking(tree)
	_team_rules()
	_team_health(tree)
	_pickup_order()
	_pickup_landing(tree)
	_step_up(tree)
	_step_overhang(tree)
	_step_stairs(tree)
	_step_slope(tree)
	_mvp(tree)
	_team_setup(tree)
	_team_respawn(tree)
	_camera(tree)

func _place(actor: Player, at: Vector2, team: int = 0) -> void:
	actor.team = team
	actor.global_position = at
	collider(actor, CollisionWorld.team_layer(team))
	actor.sync_collision_geometry()

func _attack(held: int, pressed: int, released := 0) -> Array:
	return [0.0, held, pressed, released, 0, Vector2.RIGHT]

func _fires(actions: Array) -> Array:
	return actions.filter(func(action: Dictionary) -> bool: return action["kind"] == "fire")

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
	var bank := 256.0 - (actor.collision_rect().end.y - actor.global_position.y)
	step_at.call(bank + 7.0, ActorStep.DT)
	expect(not actor.in_water, "shallow contact alone does not start swimming")
	step_at.call(bank + 9.0, ActorStep.DT)
	expect(actor.in_water, "feet below the entry depth start swimming")
	step_at.call(bank - 1.0, ActorStep.DT)
	expect(actor.in_water, "swimming holds just above the surface")
	step_at.call(bank - 3.0, ActorStep.DT)
	expect(not actor.in_water, "swimming ends beyond the exit margin")

	# 水面在同一位置的站姿和蹲姿头顶之间。
	var head_at_surface := 299.0
	actor.waterproof = 1
	step_at.call(head_at_surface, GameParameters.water_drain_interval)
	expect(actor.in_water and actor.waterproof == 2, "a swimmer with their head out recovers oxygen")
	actor.set_crouched(true)
	step_at.call(head_at_surface, GameParameters.water_drain_interval)
	expect(actor.waterproof == 1, "the same position drains oxygen with the crouched hull")

	var sim := CombatSimulator.new(_terrain, parent, true)
	var hits: Array = []
	sim.player_hit.connect(func(source: int, _victim: Player, damage: int,
			knock_changed: bool, _force: float) -> void:
		hits.append([source, damage, knock_changed]))
	var hp := actor.sim_hp
	actor._controls_locked = true
	sim.submit(actor, step_at.call(384.0, GameParameters.water_drain_interval))
	expect(actor.sim_hp == hp and actor.waterproof == 1, "locked rounds pause water survival")
	actor._controls_locked = false
	sim.submit(actor, step_at.call(384.0, GameParameters.water_drain_interval))
	sim.submit(actor, step_at.call(384.0, GameParameters.water_drown_damage_interval - 0.1))
	expect(actor.waterproof == 0 and actor.sim_hp == hp, "exhausted oxygen starts the drowning interval")
	sim.submit(actor, step_at.call(head_at_surface, 0.2))
	expect(actor.sim_hp == hp and actor.waterproof == 0, "surfacing stops damage before oxygen recovers")
	sim.submit(actor, step_at.call(384.0, GameParameters.water_drown_damage_interval - 0.1))
	expect(actor.sim_hp == hp, "submerging again starts a fresh drowning interval")
	var before := actor.capture_state()
	var actions: Array = step_at.call(384.0, 0.2)
	var after := actor.capture_state()
	actor.restore_state(before)
	expect(step_at.call(384.0, 0.2) == actions and actor.capture_state() == after and actor.sim_hp == hp,
			"replayed drowning produces the same action without changing predicted HP")
	actor.motion_knock_velocity = Vector2(20.0, 10.0)
	var velocity := actor.velocity
	sim.submit(actor, actions)
	expect(actor.sim_hp == hp - PlayerParams.player_waterproof_damage and hits == [[0, PlayerParams.player_waterproof_damage, false]]
			and actor.velocity == velocity and actor.motion_knock_velocity == Vector2(20.0, 10.0),
			"PvP authority deducts drowning damage once without credit or knockback")

	var bird: EnemyBase = preload("res://scenes/enemies/enemy_jump_bird.tscn").instantiate()
	bird.combat_rules = sim
	bird.position = Vector2(352.0, 8.0)
	parent.add_child(bird)
	bird._waterproof = 0
	hp = bird.hp
	bird._apply_water(EnemyParams.shared.drown_interval)
	expect(bird.velocity.y < 0.0 and bird.velocity.y >= -EnemyParams.shared.bird_max_float
			and bird.hp == hp - EnemyParams.shared.drown_damage,
			"an enemy in a full water column ascends at a finite speed and takes drowning damage")
	parent.remove_child(bird)
	bird.queue_free()
	cleanup()

func _equipment(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var initial := actor.capture_state()
	for tick in 32:
		ActorStep.step(actor, NEUTRAL_INPUT)
		if actor.capture_state()["actor"][FLOOR]: break
	expect(actor.capture_state()["actor"][FLOOR] and actor.position.y < 192, "real terrain stops a falling actor")
	actor.restore_state(initial)
	ActorStep.step(actor, FORWARD_INPUT)
	expect(actor.position.x > initial["actor"][POS].x, "movement still uses the real actor shape")
	var attack := ActorInput.BIT_ATTACK
	for type_id: int in WeaponRegistry.all_ids():
		var spec := WeaponRegistry.definition(type_id)
		actor.weapons.set_initial_inventory([type_id])
		var sim := CombatSimulator.new(_terrain, parent, true)
		actor.projectile_count = sim.count_projectiles.bind(actor)
		var before := actor.capture_state()
		var record := _attack(attack, attack)
		if spec["trigger"] in [WeaponRegistry.Trigger.RELEASE, WeaponRegistry.Trigger.CHARGE_RELEASE]:
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
		expect(_fires(actions).size() == 1 and after["actor"][INV][WeaponInventory.CARRIED] == before["actor"][INV][WeaponInventory.CARRIED] - 1,
				"equipped rule %d produces one shot and spends one round" % type_id)
		actor.present_tick(ActorStep.DT)
		expect(actor.capture_state() == after, "presentation leaves rule %d unchanged" % type_id)
		actor.restore_state(before)
		expect(ActorStep.step(actor, record) == actions and actor.capture_state() == after,
				"restored rule %d reproduces both state and muzzle action" % type_id)
		sim.submit(actor, actions)
		var count := 0 if spec["attack"] == WeaponRegistry.Attack.BEAM else int(spec["count"])
		expect(sim.projectiles.size() == count, "shot %d produces the configured number of projectiles" % type_id)
		sim.clear()

	var weapons := actor.weapons
	weapons.set_initial_inventory([WeaponRegistry.Type.RIFLE, WeaponRegistry.Type.COMPOUND_BOW])
	actor.equipped.carried = 3
	var added := weapons.pick_up(WeaponRegistry.Type.PISTOL, 5)
	expect(added == {"ok": true, "dropped": {}} and weapons.inventory.carried_at(0) == 3,
			"pickup fills available space and saves the previous weapon's ammo")
	actor.equipped.fire_cd_timer = 0.25
	var full_loadout := actor.capture_state()
	expect(not weapons.pick_up(WeaponRegistry.Type.M249, 7)["ok"] and actor.capture_state() == full_loadout,
			"replacing a pistol with a heavy weapon at capacity leaves the loadout intact")
	actor.equipped.carried = 4
	var inst := weapons.current_inst()
	var replaced := weapons.pick_up(WeaponRegistry.Type.PISTOL, 1)
	var replacement_inst := weapons.current_inst()
	expect(replaced == {"ok": true, "dropped": {"type": WeaponRegistry.Type.PISTOL, "carried": 4}}
			and replacement_inst > inst and weapons.inst_at_index(2) == replacement_inst
			and actor.equipped.carried == 1 and actor.equipped.fire_cd_timer == 0.25,
			"a same-type replacement gets a fresh ID and keeps its slot, both ammo counts and cooldown")
	actor.restore_state(full_loadout)
	var restored_inst := weapons.current_inst()
	weapons.pick_up(WeaponRegistry.Type.PISTOL, 1)
	expect(restored_inst == inst and weapons.current_inst() > replacement_inst,
			"restoring an earlier weapon preserves its ID and subsequent allocations keep increasing")
	cleanup()

func _inventory_rewind(tree: SceneTree) -> void:
	var actor := player(world(tree))
	var weapons := actor.weapons
	weapons.set_initial_inventory([WeaponRegistry.Type.RIFLE, WeaponRegistry.Type.PISTOL])
	var rifle := weapons.current_inst()
	var pistol := weapons.inst_at_index(1)
	weapons.equip_inst(pistol)
	actor.equipped.carried = 5
	weapons.equip_inst(rifle)
	actor.equipped.carried = 3
	var snapshot := actor.capture_rewind_state()
	expect(weapons.inventory.carried_at(0) == 3, "equipped ammo is stored directly in its inventory slot")
	actor.equipped.carried = 1
	expect(snapshot.size() == 8 and snapshot[Player.RewindSlot.INVENTORY][WeaponInventory.CARRIED] == 3,
			"solo rewind records only its own fields and captured ammo survives later mutations")
	weapons.equip_inst(pistol)
	actor.rewind_restore(snapshot)
	expect(weapons.current_inst() == rifle and actor.equipped.carried == 3,
			"solo rewind re-equips a still-owned weapon with its historical ammo")

	var dropped := weapons.drop_current()
	weapons.pick_up(dropped["type"], 9)
	var picked_up := weapons.current_inst()
	weapons.equip_inst(pistol)
	actor.equipped.carried = 1
	weapons.equip_inst(picked_up)
	actor.rewind_restore(snapshot)
	expect(weapons.inventory.index_of_inst(rifle) < 0 and picked_up > rifle
			and weapons.current_inst() == picked_up and actor.equipped.carried == 9
			and weapons.inventory.carried_at(0) == 5,
			"solo rewind keeps ownership and restores ammo only to the same instance")

	var seen := []
	actor.ground_actions = func(_player: Player, record: Array) -> void: seen.append(record[ActorInput.PRESSED])
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
	actor.rewinding = false
	actor.force_down()
	ActorStep.step(actor, record)
	actor.apply_authoritative_state(actor.sim_max_hp, actor.max_waterproof, false)
	ActorStep.step(actor, record)
	expect(seen == [buttons], "only an active actor can pick up or drop items")
	cleanup()

func _compound_bow(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 32, 32, {})
	var actor := player(parent)
	_place(actor, Vector2(384, 384))
	actor.weapons.set_initial_inventory([WeaponRegistry.Type.COMPOUND_BOW])
	var attack := ActorInput.BIT_ATTACK
	expect(_fires(ActorStep.step(actor, _attack(0, 0, attack))).is_empty(),
			"a release on a newly equipped bow does not fire")
	var tap := _fires(ActorStep.step(actor, _attack(0, attack, attack)))
	expect(tap.size() == 1 and tap[0]["charge"] == 0.0, "a tap shoots at minimum charge")
	actor.weapons.set_initial_inventory([WeaponRegistry.Type.COMPOUND_BOW])
	var bow := actor.equipped as GunBody
	var hold := _attack(attack, 0)
	for tick in 36:
		ActorStep.step(actor, hold)
	var drawn := actor.capture_rewind_state()
	var view := actor.weapons.weapon_view()
	view.present_equipped(actor, bow, Vector2.RIGHT)
	var guide := view._laser.points
	var guide_next := view.to_global(guide[1])
	var sim := CombatSimulator.new(_terrain, parent)
	var release := ActorStep.step(actor, _attack(0, 0, attack))
	sim.submit(actor, release)
	var arrow: BulletBody = sim.projectiles.values()[0]
	var id := arrow.entity_id
	expect(arrow.hit_damage == 27 and is_equal_approx(arrow.velocity_vec.length(), 1250.0),
			"the released arrow takes its speed and damage from the draw")
	sim.step_projectile(arrow, ActorStep.DT)
	expect(arrow.position.is_equal_approx(guide_next)
			and view._explosion_marker == null,
			"the bow guide uses arrow flight and has no explosion marker")

	var rewind := WorldRewind.new(sim)
	var dt := 1.0 / TimeParams.SNAP_HZ
	rewind.record(dt, actor, [])
	sim.erase_projectile(id)
	rewind.record(dt, actor, [])
	rewind.begin()
	rewind.step(1.0, actor)
	expect(sim.projectiles[id].hit_damage == 27, "rewinding restores the damage of an expired arrow")
	rewind.finish()
	actor.rewind_restore(drawn)
	expect(is_equal_approx((actor.equipped as GunBody).charge_ratio(), 0.75),
			"single-player rewind restores a partially drawn bow")
	for tick in 20:
		ActorStep.step(actor, hold)
	expect((actor.equipped as GunBody).charge_ratio() == 1.0, "holding past full draw keeps charge capped")
	cleanup()

func _m249(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent)
	actor.weapons.set_initial_inventory([WeaponRegistry.Type.M249, WeaponRegistry.Type.PISTOL])
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
	var sim := CombatSimulator.new(_terrain, parent, true)
	var bullet := sim.spawn_projectile(1, WeaponRegistry.Type.PISTOL, actor.get_instance_id(),
			Vector2(136, 160), Vector2.DOWN * 900.0)
	var sub := Vector2i(8, 12)
	var before := _terrain.get_hp(sub)
	for i in 4:
		sim.step_projectiles(ActorStep.DT)
		if sim.projectiles.is_empty(): break
	expect(sim.projectiles.is_empty(), "an ordinary round ends on terrain contact")
	expect(_terrain.get_hp(sub) == maxi(0, before - bullet.hit_damage),
			"a projectile impact immediately damages the exact subcell")
	cleanup()
	var walls := {}
	for x in 8: walls[Vector2i(x, 3)] = wall_texture(true)
	parent = world_with_walls(tree, 8, 4, walls)
	actor = player(parent)
	for i in 40:
		ActorStep.step(actor, NEUTRAL_INPUT)
		if not actor.motion_contacts.is_empty(): break
	expect(not actor.motion_contacts.is_empty() and is_equal_approx(actor.velocity.y, -PlayerParams.elastic_bounce),
			"actor bounces from elastic RID-backed terrain")
	cleanup()
	parent = world_with_walls(tree, 16, 16, {})
	var shooter := player(parent, 1)
	var victim := player(parent, 2)
	_place(shooter, Vector2(200, 512), 1)
	_place(victim, Vector2(80, 512), 2)
	sim = CombatSimulator.new(_terrain, parent, true)
	var hp := victim.sim_hp
	bullet = sim.spawn_projectile(1, WeaponRegistry.Type.PISTOL, shooter.get_instance_id(),
			Vector2(1000, 512), Vector2.RIGHT * 30000.0)
	sim.step_projectiles(ActorStep.DT)
	expect(victim.sim_hp == hp - bullet.hit_damage and sim.projectiles.is_empty(),
			"a fast round sweeps through the seam and settles its target hit")
	expect(bullet.global_position.x >= 0.0 and bullet.global_position.x < _terrain.map_size.x,
			"the swept impact also returns to canonical coordinates")
	victim.force_down()
	victim.sync_collision_geometry()
	hp = victim.sim_hp
	sim.spawn_projectile(2, WeaponRegistry.Type.PISTOL, shooter.get_instance_id(),
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
	var sim := CombatSimulator.new(_terrain, parent, true)
	sim.players = {1: shooter, 2: victim}
	var type_id := WeaponRegistry.Type.GRENADE
	var source := shooter.get_instance_id()
	shooter.projectile_count = sim.count_projectiles.bind(shooter)
	shooter.weapons.set_initial_inventory([type_id, WeaponRegistry.Type.PISTOL])
	var bullet := sim.spawn_projectile(1, type_id, source, Vector2(500, 512), Vector2.RIGHT * 6000.0)
	var blasts: Array = []
	sim.detonated.connect(func(id: int, _at: Vector2, _type_id: int) -> void: blasts.append(id))
	var hp := victim.sim_hp
	victim.rewinding = true
	bullet.impact_collider_id = victim.get_instance_id()
	ShotRules._projectile_hit(sim, bullet, Vector2.RIGHT, true)
	expect(not bullet.direct_hit and victim.sim_hp == hp, "an immune player does not consume the grenade's direct hit")
	victim.rewinding = false
	sim.step_projectiles(ActorStep.DT)
	expect(bullet.impact_node() == victim and victim.sim_hp == hp - bullet.hit_damage and bullet.direct_hit,
			"a grenade bouncing off a player applies the direct hit once")
	expect(bullet.velocity_vec.x < 0.0 and is_equal_approx(bullet.fuse_duration, 0.1),
			"the direct hit arms the short fuse and reflects velocity")
	var settled := victim.sim_hp
	for tick in range(1, 12):
		sim.tick = tick
		sim.step_projectiles(ActorStep.DT)
	expect(victim.sim_hp == settled and blasts == [1] and sim.projectiles.is_empty(),
			"the grenade detonates once without repeating contact damage")
	sim.clear_blasts()
	for id in [2, 3, 4]:
		sim.spawn_projectile(id, type_id, source, Vector2(50 + id, 100), Vector2.RIGHT)
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
	expect(blasts == [1, 3], "reaching maximum range detonates an unarmed grenade")
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
	shooter.weapons.set_initial_inventory([WeaponRegistry.Type.LASER])
	var attack := ActorInput.BIT_ATTACK
	var shots := ActorStep.step(shooter, _attack(attack, attack))
	var before := near.sim_hp
	var cell := Vector2i(14, 8)
	_terrain.damage_tile(cell, _terrain.capture_cell(cell)["hp"] - 1, 1, 0)
	var sim := CombatSimulator.new(_terrain, parent, true)
	var beams: Array = []
	sim.beam_fired.connect(func(_id: int, _shot: Dictionary, points: PackedVector2Array) -> void:
		beams.append(points))
	sim.submit(shooter, shots)
	var damage: int = WeaponRegistry.definition(WeaponRegistry.Type.LASER)["damage"]
	expect(near.sim_hp == before - damage and far.sim_hp == before - damage,
			"the authoritative beam hits multiple targets, each once across reflections")
	expect(ally.sim_hp == before and shooter.sim_hp == before, "the beam skips its shooter and allies")
	expect(_terrain.value(cell) == 0, "the first beam destroys the wall in terrain data immediately")
	ActorStep.step(ally, NEUTRAL_INPUT)
	var bullet := sim.spawn_projectile(1, WeaponRegistry.Type.PISTOL, shooter.get_instance_id(),
			Vector2(872, 544), Vector2.RIGHT * 3000.0)
	sim.step_projectile(bullet, ActorStep.DT)
	expect(sim.projectiles.is_empty(), "a projectile still collides with the broken wall in the same tick")
	var next: Dictionary = shots[0].duplicate()
	next["serial"] += 1
	sim.fire(shooter, next)
	expect(beams.size() == 2 and beams[0].size() >= 3 and beams[0] == beams[1],
			"actor and projectile steps do not rebuild terrain collision between beams")
	_terrain.flush_collisions()
	next["serial"] += 1
	sim.fire(shooter, next)
	expect(beams.back().size() == 2, "the tick-end collision refresh removes the wall for the following beam")
	var charged := WeaponRegistry.definition(WeaponRegistry.Type.LASER).merged({"min_damage": 2})
	next["charge"] = 0.25
	next["serial"] += 1
	before = near.sim_hp
	ShotRules.beam(sim, shooter, next, charged)
	expect(near.sim_hp == before - 3, "a charged beam uses its interpolated damage")
	cleanup()

func _melee(tree: SceneTree) -> void:
	const TYPE_ID := 9
	WeaponRegistry._definitions[TYPE_ID] = WeaponRegistry.DEFAULTS.merged({
		"tier": WeaponInventory.TIER_LIGHT, "attack": WeaponRegistry.Attack.MELEE,
		"cooldown": 0.3, "damage": 7, "impact": 120.0, "range": 115.0, "hit_radius": 16.0,
	}, true)
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
	var sim := CombatSimulator.new(_terrain, parent, true)
	var attack := ActorInput.BIT_ATTACK
	var shots := ActorStep.step(shooter, _attack(attack, attack | ActorInput.BIT_RELOAD))
	sim.submit(shooter, shots)
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
	for type_id: int in [WeaponRegistry.Type.LASER, WeaponRegistry.Type.PISTOL, melee_type]:
		var parent := world_with_walls(tree, 16, 16, {})
		var shooter := player(parent, 1)
		var target := player(parent, 2)
		_place(shooter, Vector2(200, 544), 1)
		_place(target, Vector2(335, 544), 2)
		target.motion_knock_velocity = Vector2(600, 0)
		shooter.weapons.set_initial_inventory([type_id])
		var authority := AuthorityWorld.new()
		authority.terrain = _terrain
		authority.players = {1: shooter, 2: target}
		authority.rules.phase = NetEvent.RoundState.PLAYING
		authority.combat_rules = CombatSimulator.new(_terrain, parent, true)
		var hit_positions: Array[Vector2] = []
		var shots: Array[Dictionary] = []
		authority.event.connect(func(kind: int, data: Variant, _exclude: int) -> void:
			if kind == NetEvent.Kind.FIRE:
				shots.append(data))
		authority.combat_rules.player_hit.connect(func(_source: int, victim: Player, _damage: int,
				_knock_changed: bool, _force: float) -> void:
			expect(shots.size() == 1 and shots[0]["tick"] == 1 and shots[0]["type_id"] == type_id,
					"attack %d broadcasts its action before resolving a hit" % type_id)
			hit_positions.append(victim.position))
		authority.accept_input(1, [[], [[1, 1, 1, ActorInput.BIT_ATTACK, 0, 0, Vector2.RIGHT]]])
		authority._physics_process(ActorStep.DT)
		expect(is_equal_approx(target.position.x, 345.0) and hit_positions == [target.position],
				"attack type %d hits after the later role completes its movement" % type_id)
		authority.free()
		cleanup()

func _blast(tree: SceneTree) -> void:
	for pvp in [false, true]:
		var parent := world_with_walls(tree, 16, 16, {Vector2i(15, 8): wall_texture()})
		var near := player(parent, 1)
		var across := player(parent, 2)
		var far := player(parent, 3)
		_place(near, Vector2(900, 544), 1)
		_place(across, Vector2(35, 544), 2)
		_place(far, Vector2(360, 544), 2)
		var sim := CombatSimulator.new(_terrain, parent, pvp)
		sim.players = {1: near, 2: across, 3: far}
		var cell := Vector2i(15, 8)
		var terrain_before := _terrain.capture_cell(cell)
		var hp := near.sim_hp
		near.sim_iframes = 1.0
		var center := Vector2(936, 544)
		sim.tick = 100
		sim.submit_blast(ShotRules.shot_id(near.role, 1), center, WeaponRegistry.Type.GRENADE, near)
		if pvp:
			for tick in [100, 101, 102]:
				sim.tick = tick
				sim.settle_blasts()
			expect(near.sim_hp == hp and _terrain.capture_cell(cell) == terrain_before,
					"PvP leaves HP and terrain unchanged before the blast deadline")
			sim.tick = 103
			sim.settle_blasts()
		expect(near.sim_hp < hp and across.sim_hp < hp and far.sim_hp == hp,
				"the blast ignores iframes, reaches across the seam and respects its radius (PvP=%s)" % pvp)
		expect(_terrain.capture_cell(cell) != terrain_before, "blast settlement immediately damages terrain")
		var after := near.sim_hp
		sim.settle_blasts()
		expect(near.sim_hp == after and sim._pending_blasts.is_empty(), "each blast settles only once")
		cleanup()

func _world_rewind(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var sim := CombatSimulator.new(_terrain, parent)
	sim.time_field = TimeField.new(GrainAccount.new())
	var bird: EnemyBase = preload("res://scenes/enemies/enemy_jump_bird.tscn").instantiate()
	bird.combat_rules = sim
	bird.position = Vector2(300, 120)
	parent.add_child(bird)
	bird.velocity = Vector2(12, -7)
	var bird_hp := bird.hp
	var id := (actor.role << 48) | 256
	var bullet := sim.spawn_projectile(id, WeaponRegistry.Type.GRENADE, actor.get_instance_id(),
			Vector2(100, 128), Vector2.RIGHT * 200.0)
	bullet.start_fuse(0.3)
	bullet.fuse_elapsed = 0.1
	bullet.traveled = 29.0
	var before := bullet.motion_state()
	var initial := actor.position
	var rewind := WorldRewind.new(sim)
	var dt := 1.0 / TimeParams.SNAP_HZ
	rewind.record(dt, actor, [bird])
	rewind.begin()
	rewind.step(dt, actor)
	expect(sim.projectiles.get(id) == bullet, "one recorded frame cannot start rewind or clear live projectiles")
	sim.erase_projectile(id)
	actor.position.x += 80.0
	bird.position.x += 40.0
	bird.velocity = Vector2.ZERO
	bird.hp = 0
	bird.is_dead = true
	bird.visible = false
	rewind.record(dt, actor, [bird])
	rewind.begin()
	rewind.step(1.0, actor)
	expect(actor.position == initial, "single-player gameplay rewind restores the actor")
	var restored: BulletBody = sim.projectiles[id]
	expect(restored != bullet and restored.shooter == actor and restored.motion_state() == before,
			"single-player rewind restores the same projectile identity, owner, motion and fuse")
	expect(bird.position == Vector2(300, 120) and bird.velocity == Vector2(12, -7)
			and bird.hp == bird_hp and not bird.is_dead and bird.visible,
			"single-player rewind restores a recorded enemy and revives it")
	rewind.finish()
	bird.hurt(bird.hp, Vector2.ZERO)
	rewind.record(dt, actor, [bird])
	expect(is_equal_approx(bird.rewind_death_time, rewind.recorded_seconds()),
			"a corpse is retained on the rewind timeline")
	rewind.record(TimeParams.SNAP_SECONDS - dt, actor, [bird])
	expect(not bird.is_queued_for_deletion(), "the corpse remains within the recorded window")
	rewind.record(dt * 2, actor, [bird])
	expect(bird.is_queued_for_deletion(), "the corpse expires once recording passes its retention window")
	cleanup()

func _rewind_window(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var rewind := WorldRewind.new(CombatSimulator.new(_terrain, parent))
	var dt := 0.0625
	var window := int(TimeParams.SNAP_SECONDS / dt)
	var samples := 2 * window + 4
	for index in samples:
		actor.position.x = 64.0 + index * 0.25
		rewind.record(dt, actor, [])
	var end := rewind.recorded_seconds()
	var backwards := TimeParams.SNAP_SECONDS * 0.5 + dt * 0.5
	var target := end - backwards
	var expected_x := 64.0 + (floori(target / dt) - 1) * 0.25
	rewind.begin()
	rewind.step(backwards / TimeParams.REWIND_START_MULT, actor)
	expect(actor.position.x == expected_x, "rewind finds the preceding frame across the wrapped buffer")
	expect(is_equal_approx(rewind.finish(), target), "rewind exits at the target time between recorded frames")
	actor.position.x = 480.0
	rewind.record(dt, actor, [])
	rewind.begin()
	rewind.step(dt * 0.25 / TimeParams.REWIND_START_MULT, actor)
	expect(actor.position.x == expected_x, "recording after rewind discards the former future")
	rewind.step(TimeParams.SNAP_SECONDS + 1.0, actor)
	expect(actor.position.x == 64.0 + (samples - 1 - window) * 0.25
			and is_equal_approx(rewind.finish(), end - TimeParams.SNAP_SECONDS),
			"rewinding beyond the window clamps to the oldest retained frame and its time")
	cleanup()

func _enemy_time(tree: SceneTree) -> void:
	var parent := world(tree)
	var bird: EnemyBase = preload("res://scenes/enemies/enemy_jump_bird.tscn").instantiate()
	bird.combat_rules = CombatSimulator.new(_terrain, parent)
	parent.add_child(bird)
	bird.set_physics_process(false)
	# 跳过 AI、重力和衰减，单独检查水平移动倍率。
	bird.is_dead = true
	bird.use_gravity = false
	bird.knock_decay_rate = 0.0
	bird.combat_rules.time_field = TimeField.new(GrainAccount.new())
	bird.time_field.mode = TimeField.Mode.HASTE
	for elite in [false, true]:
		if elite:
			bird.set_meta("elite", true)
		bird.position = Vector2(200.0, 80.0)
		bird.velocity = Vector2(60.0, 0.0)
		bird._physics_process(ActorStep.DT)
		var expected := TimeParams.HASTE_PLAYER if elite else TimeParams.HASTE_WORLD
		expect(is_equal_approx(bird.position.x - 200.0, expected) and bird.velocity.x == 60.0,
				"enemy horizontal displacement uses one time multiplier (elite=%s)" % elite)
	var flyer: EnemyFlyBird = preload("res://scenes/enemies/enemy_fly_bird.tscn").instantiate()
	parent.add_child(flyer)
	flyer.set_physics_process(false)
	flyer.global_position = Vector2(_terrain.map_size.x - 8, 80)
	flyer._apply_flight_collision(true)
	flyer._glide_to(Vector2(8, 80), ActorStep.DT)
	expect(flyer._active_stance == 1 and flyer.velocity.x > 0.0,
			"a flying bird uses its flight hull and glides along the short path across a seam")
	cleanup()

func _beta_history(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent, 1)
	var other := player(parent, 2)
	var authority := AuthorityWorld.new()
	parent.add_child(authority)
	authority.set_physics_process(false)
	authority.players = {1: actor, 2: other}
	authority.combat_rules = CombatSimulator.new(_terrain, parent, true)
	authority.time_economy = TimeEconomy.new({}, [1, 2])
	authority.rules.start_countdown()
	authority.rules.advance(3.0)
	var one := authority.combat_rules.spawn_projectile(1 << 48, WeaponRegistry.Type.GRENADE, actor.get_instance_id(),
			Vector2(100, 128), Vector2.RIGHT)
	var two := authority.combat_rules.spawn_projectile(2 << 48, WeaponRegistry.Type.PISTOL, other.get_instance_id(),
			Vector2(100, 128), Vector2.RIGHT)
	var history := BetaHistory.new(authority)
	for tick in [3, 6, 9]:
		authority._snap_tick = tick
		actor.position.x = tick * 10.0
		one.position.x = tick * 12.0
		two.position.x = tick * 15.0
		history.tick(ActorStep.DT)
	expect(history.frames[1][1]["bullets"].keys() == [1 << 48], "Beta history records only the shooter's projectiles")
	actor.ground_actions = authority._handle_ground_actions
	ActorStep.step(actor, _attack(0, ActorInput.BIT_DROP))
	expect(actor.equipped == null and authority.pickups.size() == 1, "authority removes the dropped weapon from inventory")
	var hp := other.sim_hp
	one.impact_collider_id = other.get_instance_id()
	ShotRules._projectile_hit(authority.combat_rules, one, Vector2.RIGHT, true)
	expect(one.direct_hit and other.sim_hp == hp - one.hit_damage, "Beta grenade applies its first direct hit")
	actor.shot_serial = 123
	var both := _attack(ActorInput.BIT_REWIND | ActorInput.BIT_HASTE, 0)
	var account: GrainAccount = authority.time_economy.accounts[1]
	var balance := account.balance
	var dt := 0.025 / TimeParams.REWIND_START_MULT
	authority.time_economy.step_haste(actor, both, dt)
	actor.step_input.prepare(both, false)
	history.tick(dt)
	expect(is_equal_approx(account.balance, balance - dt * authority.time_economy.rules["rewind_burn"])
			and actor.pvp_haste_mult == 1.0, "simultaneous rewind and haste only spends rewind grains")
	balance = account.balance
	authority.time_economy.step_haste(actor, _attack(ActorInput.BIT_HASTE, 0), dt)
	expect(account.balance == balance, "the exit tick cannot spend haste before a rewinding actor resumes")
	expect(actor.position.x == 60.0 and actor.shot_serial == 123,
			"Beta rewind restores the actor and preserves attack identity")
	expect(one.position.x == 72.0 and two.position.x == 135.0, "Beta rewind only restores the owner's bullets")
	expect(actor.equipped == null and authority.pickups.size() == 1, "Beta rewind preserves a drop without duplicating ownership")
	history.finish(1)
	ShotRules._projectile_hit(authority.combat_rules, one, Vector2.RIGHT, true)
	expect(one.direct_hit and other.sim_hp == hp - one.hit_damage, "Beta rewind preserves settled direct-hit damage")
	expect(history.frames[1].size() == 2 and actor.input_buffer.epoch == 2 and not actor.rewinding,
			"ending Beta rewind trims the future and changes the control epoch")
	cleanup()

func _team_health(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var attacker := player(parent, 1)
	var victim := player(parent, 2)
	var friendly := player(parent, 3)
	_place(attacker, Vector2(300, 300), 2)
	_place(victim, Vector2(400, 300), 1)
	_place(friendly, Vector2(200, 300), 2)
	var sim := CombatSimulator.new(_terrain, parent, true)
	sim.team_counts = {1: 4, 2: 1}
	var hp := victim.sim_hp
	sim.resolve_hit(attacker, victim, CombatProfiles.DIRECT, victim.position, 10, 0.0)
	expect(victim.sim_hp == hp - 11, "team compensation increases the disadvantaged player's hit once")
	expect(not sim.resolve_hit(attacker, friendly, CombatProfiles.DIRECT, friendly.position, 10, 0.0)
			and friendly.sim_hp == hp, "a direct hit excludes allies")
	sim.resolve_hit(attacker, friendly, CombatProfiles.BLAST, friendly.position, 10, 0.0)
	sim.resolve_hit(attacker, attacker, CombatProfiles.BLAST, attacker.position, 10, 0.0)
	expect(friendly.sim_hp == hp - 10 and attacker.sim_hp == hp - 10,
			"friendly and self blast damage are allowed without compensation")
	cleanup()

func _pickup_order() -> void:
	var size := Vector2(512, 256)
	var one := WeaponPickup.new()
	one.inst = 1
	one.canonical_pos = Vector2(506, 64)
	var two := WeaponPickup.new()
	two.inst = 2
	two.canonical_pos = Vector2(6, 64)
	expect(GroundWeaponField.nearest([two, one], Vector2(0, 64), size, func(_item: WeaponPickup) -> bool: return true) == one,
			"pickup uses toroidal distance and breaks ties by smallest instance id")
	expect(GroundWeaponField.nearest([two, one], Vector2(0, 64), size, func(item: WeaponPickup) -> bool: return item != one) == two,
			"a locked pickup does not block the next eligible item")
	one.free()
	two.free()

func _pickup_landing(tree: SceneTree) -> void:
	var parent := world(tree)
	var floor_y := 3.0 * GameParameters.TILE_SIZE
	for preplaced in [true, false]:
		var bow := WeaponPickup.new()
		bow.configure(WeaponRegistry.Type.COMPOUND_BOW, 1 if preplaced else 2,
				WeaponInventory.DEFAULT_CARRIED, Vector2.ZERO)
		bow.position = Vector2(160.0 if preplaced else 352.0, floor_y - GameParameters.TILE_SIZE * 0.5)
		parent.add_child(bow)
		bow.set_physics_process(false)
		if preplaced:
			bow.settle_on_spawn_floor()
		else:
			for i in 60: bow.simulate_tick(ActorStep.DT)
		var hull := bow.hulls[0] as CollisionShape2D
		var bottom := hull.to_global(Vector2(0.0, (hull.shape as RectangleShape2D).size.y * 0.5)).y
		expect(bow._settled and absf(bottom - floor_y) < 0.5,
				"a map bow spawns on the floor" if preplaced else "a bow pushed out of terrain falls back to the floor")
	cleanup()

func _dynamic_blocking(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var mover := player(parent, 1)
	var blocker := player(parent, 2)
	mover.gravity = 0.0
	blocker.gravity = 0.0
	mover.collision_mask = CollisionWorld.LAYER_TERRAIN | CollisionWorld.LAYER_TEAM_A
	mover.collision_layer = 0
	mover._apply_layers()
	mover.global_position = Vector2(200, 512)
	blocker.global_position = Vector2(320, 512)
	mover.sync_collision_geometry()
	blocker.sync_collision_geometry()
	collider(blocker, CollisionWorld.LAYER_TEAM_A)
	var start := mover.global_position.x
	var record := [1.0, ActorInput.BIT_UP, 0, 0, 0, Vector2.RIGHT]
	for i in 14:
		ActorStep.step(mover, record)
	expect(mover.global_position.x > start + 8.0, "the moving actor advances until the blocker stops it")
	expect(mover.global_position.x < blocker.global_position.x - 60.0,
			"another actor's body stops the moving body before it overlaps")
	var blocked_at := mover.global_position.x
	blocker.collision_layer = 0
	blocker._apply_layers()
	for i in 20:
		ActorStep.step(mover, record)
	expect(mover.global_position.x > blocked_at + 20.0, "clearing the blocker's layer lets the same input continue")

func _team_rules() -> void:
	expect(TeamRules.kills_to_win(2) == 5 and TeamRules.kills_to_win(6) == 9,
			"kills target follows total players (2->5, 6->9)")
	expect(TeamRules.kills_to_win(3) == 6 and TeamRules.kills_to_win(4) == 7 and TeamRules.kills_to_win(5) == 8,
			"kills target follows total players (3/4/5)")
	expect(TeamRules.kills_to_win(10) == 13, "5v5 kills target is 13")
	var two_one := TeamRules.team_counts({1: 1, 2: 1, 3: 2})
	expect(two_one == {1: 2, 2: 1}, "team_counts splits A/B")
	expect(TeamRules.disadvantaged_team(two_one) == 2, "the smaller team is disadvantaged")
	expect(TeamRules.score_bonus(2, two_one) == 1 and TeamRules.score_bonus(1, two_one) == 0,
			"score bonus equals the player difference")
	expect(TeamRules.max_hp(2, two_one) == 55 and TeamRules.max_hp(1, two_one) == 50,
			"disadvantaged team starts with 55 HP")
	expect(is_equal_approx(TeamRules.damage_factor(2, 1, two_one), 1.0),
			"a one-player difference does not boost damage")
	var four_one := TeamRules.team_counts({1: 1, 2: 1, 3: 1, 4: 1, 5: 2})
	expect(TeamRules.score_bonus(2, four_one) == 3 and TeamRules.max_hp(2, four_one) == 65,
			"4v1 gives 3 points and 65 HP")
	expect(is_equal_approx(TeamRules.damage_factor(2, 1, four_one), 1.1), "4v1 damage is x1.1")
	var five_one := TeamRules.team_counts({1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 2})
	expect(TeamRules.score_bonus(2, five_one) == 4 and TeamRules.max_hp(2, five_one) == 70,
			"5v1 gives 4 points and 70 HP")
	expect(is_equal_approx(TeamRules.damage_factor(2, 1, five_one), 1.2), "5v1 damage is x1.2")
	expect(is_equal_approx(TeamRules.damage_factor(1, 2, five_one), 1.0),
			"only the disadvantaged side deals extra damage")
	expect(is_equal_approx(TeamRules.damage_factor(2, 2, five_one), 1.0), "friendly damage is not boosted")
	expect(is_equal_approx(TeamRules.damage_factor(0, 1, five_one), 1.0), "unowned damage is not boosted")
	var even := TeamRules.team_counts({1: 1, 2: 2})
	expect(TeamRules.disadvantaged_team(even) == 0 and TeamRules.score_bonus(1, even) == 0,
			"equal teams have no compensation")

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
		mover.gravity = GameParameters.gravity0
		mover.collision_layer = 0
		mover.collision_mask = CollisionWorld.LAYER_TERRAIN
		mover._apply_layers()
		mover.global_position = Vector2(400, 384 - 57)
		mover.sync_collision_geometry()
		ActorStep.step(mover, NEUTRAL_INPUT)
		var farthest := mover.global_position.x
		for i in 60:
			ActorStep.step(mover, FORWARD_INPUT)
			farthest = maxf(farthest, mover.global_position.x)
		expect(absf(mover.global_position.y - (384 - height - 57)) < 2.0,
				"a %dpx step is climbed" % height)
		expect(farthest > 512.0, "the actor crosses the %dpx step face" % height)
	cleanup()
	var too_high := _step_world(tree, 80)
	var blocked := player(too_high, 1)
	blocked.gravity = GameParameters.gravity0
	blocked.collision_layer = 0
	blocked.collision_mask = CollisionWorld.LAYER_TERRAIN
	blocked._apply_layers()
	blocked.global_position = Vector2(400, 384 - 57)
	blocked.sync_collision_geometry()
	for i in 40:
		ActorStep.step(blocked, FORWARD_INPUT)
	expect(absf(blocked.global_position.y - (384 - 57)) < 2.0 and blocked.global_position.x < 500.0,
			"a step higher than 64px keeps the normal collision block")
	cleanup()
	var low := _step_world(tree, 16, true)
	var ceiling_mover := player(low, 1)
	ceiling_mover.gravity = GameParameters.gravity0
	ceiling_mover.collision_layer = 0
	ceiling_mover.collision_mask = CollisionWorld.LAYER_TERRAIN
	ceiling_mover._apply_layers()
	ceiling_mover.global_position = Vector2(400, 384 - 57)
	ceiling_mover.sync_collision_geometry()
	for i in 40:
		ActorStep.step(ceiling_mover, FORWARD_INPUT)
	expect(absf(ceiling_mover.global_position.y - (384 - 57)) < 2.0,
			"a low ceiling blocks the whole step path")
	cleanup()
	var dynamic := _step_world(tree, 16)
	var runner := player(dynamic, 1)
	runner.gravity = GameParameters.gravity0
	runner.collision_layer = 0
	runner.collision_mask = CollisionWorld.LAYER_TERRAIN | CollisionWorld.LAYER_TEAM_A
	runner._apply_layers()
	runner.global_position = Vector2(400, 384 - 57)
	runner.sync_collision_geometry()
	var blocker := player(dynamic, 2)
	blocker.gravity = 0.0
	# 只挡 16px 抬高后的路径，不挡地面水平路径。
	blocker.global_position = Vector2(500, 213)
	blocker.sync_collision_geometry()
	collider(blocker, CollisionWorld.LAYER_TEAM_A)
	for i in 40:
		ActorStep.step(runner, FORWARD_INPUT)
	expect(absf(runner.global_position.y - (384 - 57)) < 2.0,
			"a dynamic actor blocking the raised path prevents the step-up")
	# 被拒绝的候选不能移动角色：候选是只读检测，回退到水平阻挡。
	runner.move_by_internal(Vector2(10.0, 0.0))
	expect(absf(runner.global_position.y - (384 - 57)) < 2.0,
			"a rejected step candidate does not move the actor")
	cleanup()

func _step_overhang(tree: SceneTree) -> void:
	# 角色从地图右侧靠近左侧台阶的镜像。顶板下有 112px，刚好容纳 107px 的站立碰撞体。
	var parent := world_from_solid(tree, 16, 8, func(sx: int, sy: int) -> bool:
		return sy >= 24 or sx < 12 and (sy >= 23 or sy == 15))
	var mover := player(parent)
	_place(mover, Vector2(_terrain.map_size.x - 36.5, 326.999))
	mover.velocity.x = PlayerParams.move_speed
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
	mover.pvp_haste_mult = 3.0
	mover.velocity.x = PlayerParams.move_speed * mover.pvp_haste_mult
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
	slope.collision_layer = CollisionWorld.LAYER_TERRAIN
	slope.collision_mask = 0
	var hull := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = Vector2(44, 3)
	hull.shape = box
	slope.add_child(hull)
	parent.add_child(slope)
	var mover := player(parent)
	mover.collision_layer = 0
	mover.collision_mask = CollisionWorld.LAYER_TERRAIN
	mover._apply_layers()
	mover.global_position = Vector2(464, 326.98)
	mover.sync_collision_geometry()
	mover._grounded = true
	mover.step_input = ActorInput.new()
	mover.step_input.axis = 1.0
	var blocked := mover.move_by_internal(Vector2(12, 0))
	expect(blocked == Vector2(1, 0) and mover.global_position.x < 476.0
			and absf(mover.global_position.y - 326.98) < 0.2,
			"a rotated terrain face uses normal horizontal blocking")
	var pose: Transform2D = PhysicsServer2D.body_get_state(mover.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM)
	expect(pose.origin.is_equal_approx(mover.global_position), "the blocked actor and RID stay in sync")
	cleanup()

# 团队 MVP 只从获胜队选；平局与缺失候选都返回 0。
func _mvp(tree: SceneTree) -> void:
	cleanup()
	var parent := world(tree)
	var authority := AuthorityWorld.new()
	parent.add_child(authority)
	authority.set_physics_process(false)
	authority.rules.mode = PvpSession.MODE_TEAM
	authority.rules.teams = {1: 1, 2: 1, 3: 2, 4: 2}
	authority._stats = {}
	for role: int in [1, 2, 3, 4]:
		authority._stats[role] = {"kills": 50 if role == 1 else (20 if role == 3 else 1),
				"deaths": 1, "assists": 0, "dealt": 100, "taken": 10, "team_damage": 0,
				"self_damage": 0, "team_kills": 0, "rounds": 1, "left": false, "hits": {}}
	authority.rules.winner = 2
	expect(authority.mvp_role() == 3, "the team MVP comes from the winning team")
	authority._stats[4]["kills"] = 20
	authority._stats[4]["dealt"] = 100
	authority._stats[4]["deaths"] = 1
	expect(authority.mvp_role() == 3, "an exact statistical tie is decided by role order")
	authority.rules.winner = 0
	expect(authority.mvp_role() == 0, "a drawn team match has no MVP")
	authority.rules.winner = 2
	cleanup()
# 团队对局初始化：固定阵容、初始比分、出生点规划与换边。
func _team_setup(tree: SceneTree) -> void:
	cleanup()
	var authority := AuthorityWorld.new()
	tree.root.add_child(authority)
	_worlds.append(authority)
	var disabled := WeaponRegistry.all_ids()
	expect(not authority.setup(PvpSession.MODE_TEAM, "res://maps/demo.cyrm", [1, 2, 3], {1: 1, 2: 1, 3: 2},
			{"disabled_weapons": disabled}).is_empty() and authority.players.is_empty(),
			"all weapons disabled rejects the match before spawning players")
	disabled.erase(WeaponRegistry.Type.PISTOL)
	var problem := authority.setup(PvpSession.MODE_TEAM, "res://maps/demo.cyrm", [1, 2, 3], {1: 1, 2: 1, 3: 2},
			{"match_time": 300, "disabled_weapons": disabled})
	expect(problem.is_empty(), "the team match loads and validates its map")
	for p: Player in authority.players.values():
		expect(p.weapons.current_type_id() == WeaponRegistry.Type.PISTOL,
				"each player starts equipped even when only one weapon type is enabled")
	authority.set_physics_process(false)
	expect(authority.rules.phase == NetEvent.RoundState.WAITING and is_zero_approx(authority.rules.round_timer),
			"setup starts in WAITING with a zero timer")
	expect(authority.players[3].sim_max_hp == 55 and authority.players[1].sim_max_hp == 50,
			"team max HP follows the fixed roster")
	expect(int(authority.rules.scores.get(2, 0)) == 1 and int(authority.rules.scores.get(1, 0)) == 0,
			"the smaller team starts with its score bonus")
	expect(authority.rules.team_counts == {1: 2, 2: 1}, "the roster counts are frozen at setup")
	expect(authority.rules.spawns.size() == 3 and authority.rules.swapped.size() == 3,
			"both side plans assign every role")
	expect(authority.rules.spawns[1] == Vector2i(22, 30), "team A uses its first side point")
	var actor: Player = authority.players[1]
	var drop := [1, actor.input_buffer.epoch, 0, ActorInput.BIT_DROP, 0, 0, Vector2.RIGHT]
	authority.accept_input(1, [[], [drop]])
	authority._physics_process(ActorStep.DT)
	expect(actor.weapons.current_type_id() == WeaponRegistry.Type.PISTOL,
			"WAITING blocks a queued drop even after the seat is ready")

	authority.start_countdown()
	authority._advance_round(3.0)
	drop[InputBuffer.SEQ] = 2
	authority.accept_input(1, [[], [drop]])
	authority._physics_process(ActorStep.DT)
	expect(actor.weapons.current_type_id() == 0, "PLAYING accepts the same drop")

	_win_team_round(authority)
	expect(authority.rules.phase == NetEvent.RoundState.WAITING,
			"the next round returns to WAITING instead of counting down")
	expect(authority.rules.round_number == 2 and authority.rules.spawns[1] == Vector2i(79, 30),
			"side swap follows the round number")
	expect(int(authority.rules.scores.get(2, 0)) == 1 and int(authority.rules.scores.get(1, 0)) == 0,
			"the next round reapplies the initial score bonus")

	authority.start_countdown()
	authority._advance_round(3.0)
	authority.set_physics_process(true)
	_win_team_round(authority)
	var result := authority.round_state()
	expect(result["state"] == NetEvent.RoundState.MATCH_OVER and result["match_winner"] == 1,
			"the second round win seals the match result")
	expect(not authority.is_physics_processing(), "the final result stops authoritative combat")
	drop[InputBuffer.EPOCH] = actor.input_buffer.epoch
	drop[InputBuffer.TARGET_TICK] = authority._snap_tick + 1
	authority.accept_input(1, [[], [drop]])
	expect(actor.input_buffer.actions.is_empty(), "the final result stops accepting input")
	authority.remove_role(3)
	expect(authority.round_state() == result, "leaving after the match keeps the final result")
	cleanup()

func _win_team_round(authority: AuthorityWorld) -> void:
	for kill in TeamRules.kills_to_win(3):
		authority.rules.score_down(3, 1)
	authority._advance_round(ActorStep.DT)
	authority._advance_round(4.0)

# 团队复活：只取当前阵营地图侧、避开存活角色占用点，并最大化与敌人的最小环面距离。
func _team_respawn(tree: SceneTree) -> void:
	cleanup()
	var parent := world_from_solid(tree, 125, 75, func(sx: int, sy: int) -> bool: return sy >= 74 * 4)
	var info := MapFormat.load_map("res://maps/demo.cyrm")
	var respawn: Dictionary = info["spawns"]["respawn"]
	var rules := MatchRules.new()
	rules.setup(PvpSession.MODE_TEAM, [1, 2, 3], {1: 1, 2: 1, 3: 2}, info, {})
	var ally := player(parent, 1)
	ally.team = 1
	ally.global_position = Vector2(respawn[1][0]) * 64 + Vector2(32, 32)
	var enemy := player(parent, 3)
	enemy.team = 2
	enemy.global_position = Vector2(respawn[1][1]) * 64 + Vector2(32, 32)
	var players := {1: ally, 3: enemy}
	var point := rules.spawn_for(players, 2)
	expect(respawn[1].has(point), "team respawn stays on the team's current map side")
	expect(point != respawn[1][0] and point != respawn[1][1],
			"occupied respawn points are excluded")
	# 全部本方点被占用时保持倒地，下一 tick 重新选点。
	for index in respawn[1].size():
		var mate := player(parent, 10 + index)
		mate.team = 1
		mate.global_position = Vector2(respawn[1][index]) * 64 + Vector2(32, 32)
		mate.sync_collision_geometry()
		players[10 + index] = mate
	expect(rules.spawn_for(players, 2) == Vector2i(-1, -1),
			"a fully occupied team side reports no point instead of overlapping")
	cleanup()
# 相机：首次绑定、死区平滑、跨接缝副本对齐与震屏合成。
func _camera(tree: SceneTree) -> void:
	cleanup()
	var parent := world(tree)
	var cam = preload("res://core/present/camera_2d.gd").new()
	parent.add_child(cam)
	cam.set_process(false)
	var target := Node2D.new()
	parent.add_child(target)
	cam.target = target
	target.global_position = Vector2(300, 200)
	cam._process(1.0 / 60.0)
	var bias := Vector2(0.0, PlayerParams.cam_y_bias)
	expect(cam.get_base_global_position().is_equal_approx(Vector2(300, 200) + bias),
			"the first bind initializes the base position with the y bias")
	# 死区内目标移动不改变基准位置，超出后按平滑系数跟随。
	target.global_position += Vector2(PlayerParams.cam_deadzone - 1.0, 0.0)
	cam._process(1.0 / 60.0)
	var settled: Vector2 = cam.get_base_global_position()
	expect(settled.x < 301.0, "a target inside the deadzone does not move the camera")
	target.global_position += Vector2(200.0, 0.0)
	cam._process(1.0 / 60.0)
	var moved: Vector2 = cam.get_base_global_position()
	expect(moved.x > settled.x + 1.0 and moved.x < target.global_position.x - 1.0,
			"a target outside the deadzone is followed with exponential smoothing")
	# 强震不被弱震覆盖，基准位置不包含震动偏移。
	cam.shake(30.0, 0.5)
	cam.shake(5.0, 0.1)
	expect(is_equal_approx(cam._shake_amt, 30.0) and cam._shake_time >= 0.49,
			"a weak shake cannot replace a stronger amplitude or a longer duration")
	cam._process(1.0 / 60.0)
	expect(cam.global_position.is_equal_approx(cam.get_base_global_position() + cam._shake_offset),
			"the rendered position is base + shake offset")
	# 跨接缝：目标在右侧边缘、基准在左侧时，相机应整体对齐到目标所在副本。
	cam._shake_amt = 0.0
	cam._shake_time = 0.0
	cam._shake_dur = 0.0
	cam._shake_offset = Vector2.ZERO
	target.global_position = Vector2(_terrain.map_size.x - 4.0, 200)
	cam._base_pos = Vector2(4.0, 200 + PlayerParams.cam_y_bias)
	cam._process(1.0 / 60.0)
	var aligned := GridPathfinder.anchor_to_nearest(cam.get_base_global_position(),
			target.global_position, _terrain.map_size)
	expect(aligned.distance_to(target.global_position + bias) < 32.0,
			"the camera base follows the nearest copy of the target across the seam")
	cleanup()
