extends "res://tests/case.gd"

const TCFG: TimeConfig = preload("res://core/config/time_config.tres")
const ECFG: EnemyConfig = preload("res://core/config/enemy_config.tres")

const WCFG: WorldConfig = preload("res://core/config/world_config.tres")

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

const NEUTRAL_INPUT := [0.0, 0, 0, 0, 0, Vector2.RIGHT]
const FORWARD_INPUT := [1.0, 0, 0, 0, 0, Vector2.RIGHT]

const POS: int = PlayerStateSchema.POS
const FLOOR: int = PlayerStateSchema.GROUNDED
const INV: int = PlayerStateSchema.INVENTORY

func run(tree: SceneTree) -> void:
	_equipment(tree)
	_actor_animation(tree)
	_inventory_rewind(tree)
	_compound_bow(tree)
	_m249(tree)
	_rounds(tree)
	_water(tree)
	_grenade(tree)
	_beam(tree)
	_melee(tree)
	_blast(tree)
	_shared_combat_tick(tree)
	_damage_numbers(tree)
	_world_rewind(tree)
	_rewound_blast(tree)
	_rewound_enemy_action(tree)
	_rewind_window(tree)
	_enemy_time(tree)
	_daylight(tree)
	if DisplayServer.get_name() != "headless":
		await _daylight_render(tree)
	_grain_rewards(tree)
	_shared_rewind_history(tree)
	_personal_rewind()
	_dynamic_blocking(tree)
	_team_rules()
	_team_health(tree)
	_pickup_order(tree)
	_pickup_landing(tree)
	_step_up(tree)
	_step_overhang(tree)
	_step_stairs(tree)
	_step_slope(tree)
	_mvp()
	_duel_spawns()
	_team_setup()
	_team_respawn(tree)
	_sparse_spawn_map(tree)
	_camera(tree)
	cleanup()
	_detached_match()
	await _solo_scene(tree)
	await _loading_failure(tree)

func _loading_failure(tree: SceneTree) -> void:
	await SceneTransition.change_with_builder(tree, func() -> Node: return null, "载入中")
	var screen := LoadingScreen.find(tree)
	var back: Button = screen.get_node("%Back")
	back.pressed.emit()
	expect(back.visible and screen.is_queued_for_deletion(), "the loading scene's Back button dismisses a failed transition")
	await tree.process_frame

func _detached_match() -> void:
	var map := CyrmMap.load_file("res://maps/demo.cyrm")
	var sim := CombatSimulator.new(Terrain.new(map))
	sim.time_field = WorldTime.new(GrainAccount.new())
	var actor := sim.add_player(1)
	actor.spawn_at(SpawnPicker.single_spawn(map))
	actor.weapons.set_initial_inventory([WeaponType.RIFLE])
	var enemies: Array = map.points.values().filter(func(p: Dictionary) -> bool: return p.kind == "enemy")
	for entry: Dictionary in enemies:
		sim.add_enemy(entry["type"], actor, CyrmMap.world_position(entry.cell))
	var slots: Array[int] = []
	for enemy in sim.enemies:
		slots.append(enemy.slot)
	sim.step({actor.role: _attack(ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)})
	expect(sim.tick == 1 and sim.enemies.size() == enemies.size() and slots == range(slots.size()),
			"demo builds and steps every enemy in map order without a viewport")
	var hulls := sim.terrain.physics.shape_overlaps(CollisionWorld.rectangle(Vector2.ONE), actor.transform, CollisionWorld.LAYER_TEAM_A)
	expect(hulls.size() == 1 and hulls[0]["collider"] == actor, "a detached player's RID resolves to its model")
	expect(sim.projectiles.size() == 1, "a detached match resolves player input and spawns a real projectile")
	sim.close()
	expect(not actor.rid.is_valid() and sim.players.is_empty() and sim.enemies.is_empty() and sim.projectiles.is_empty(),
			"closing a detached match releases all combat bodies")

func _solo_scene(tree: SceneTree) -> void:
	var map := CyrmMap.load_file("res://maps/newfactory.cyrm")
	var level := SoloLevel.create(map, SpawnPicker.single_spawn(map), [WeaponType.RIFLE])
	tree.root.add_child(level)
	var game := level.session.world
	var sim := game.combat
	var enemy_count: int = map.points.values().filter(func(p: Dictionary) -> bool: return p.kind == "enemy").size()
	expect(sim.enemies.size() == enemy_count and enemy_count > 0, "the solo match owns the map's enemies")
	var viewport := level.get_node("View/WorldViewport")
	var nodes := viewport.get_child_count()
	expect(viewport.get_children() == [level._view.camera, level._view.terrain_view, level._world._canvas],
			"only the camera and world graphics are mounted under the viewport")
	await tree.physics_frame
	Input.action_press(&"attack")
	await tree.physics_frame
	Input.action_release(&"attack")
	expect(sim.projectiles.size() == 1 and viewport.get_child_count() == nodes,
			"firing through the solo input creates a projectile without adding a node")
	if sim.projectiles.size() == 1:
		var bullet: BulletBody = sim.projectiles.values()[0]
		var first_step := bullet.traveled
		expect(first_step > 0.0, "a new projectile moves on the firing tick")
		await tree.physics_frame
		expect(bullet.traveled > first_step, "the following tick continues the same projectile")
	var tick := sim.tick
	var feedback := level._view.feedback
	var effect_time := feedback._now
	var daylight_time := game.world_time.elapsed
	level._view.pause.set_open(true)
	await tree.process_frame
	await tree.process_frame
	expect(sim.tick == tick and game.world_time.elapsed == daylight_time and feedback._now > effect_time,
			"pause stops simulation and daylight while the scene tree advances HUD feedback")
	level._view.pause.set_open(false)
	await tree.physics_frame
	await tree.physics_frame
	expect(sim.tick > tick, "closing the pause menu resumes simulation")
	for i in 6:
		await tree.physics_frame
	var before_rewind := sim.tick
	var balance := game.world_time.account.balance
	Input.action_press(&"rewind")
	await tree.physics_frame
	var restored := sim.tick
	expect(game.world_time.is_rewinding() and restored < before_rewind and game.world_time.account.balance < balance,
			"holding rewind in the actual match spends grains and restores an earlier combat tick")
	Input.action_release(&"rewind")
	await tree.physics_frame
	expect(not game.world_time.is_rewinding() and sim.tick == restored + 1,
			"releasing rewind runs the very next combat tick on the new branch")
	var old_drop: WeaponPickup = sim.ground.items.values()[0]
	var old_enemy := sim.enemies[0]
	level.restart_single()
	await tree.physics_frame
	expect(not old_drop.rid.is_valid() and not old_enemy.rid.is_valid() and sim.enemies.size() == enemy_count
			and sim.enemies[0] != old_enemy
			and sim.projectiles.is_empty(), "restart replaces the roster and releases the old bodies on the next fixed step")
	level.free()

func _place(actor: Player, at: Vector2, team: int = 0) -> void:
	actor.team = team
	actor.position = at
	collider(actor, CollisionWorld.team_layer(team))
	actor.sync_collision_geometry()

func _attack(held: int, pressed: int, released := 0) -> Array:
	return [0.0, held, pressed, released, 0, Vector2.RIGHT]

func submit(actor: Player, requests: Array) -> void:
	actor.combat_requests = requests
	actor.combat.resolve_requests([actor.role])

func _fires(actions: Array) -> Array:
	return actions.filter(func(action: Dictionary) -> bool: return action["kind"] == "fire")

class ActorDisplay extends Node:
	var _frame: MatchFrame
	var _world := WorldView.new()
	var presenter: MatchPresenter

func _display(parent: Node, actor: Player) -> ActorDisplay:
	var display := ActorDisplay.new()
	var spec := WorldSpec.solo(_document, Vector2i.ZERO, [WeaponType.RIFLE], 0)
	display.presenter = MatchPresenter.new(spec, _terrain, actor.role, null)
	display._frame = display.presenter.frame
	display._world.bind(canvas_for(parent), _terrain.map_size)
	return display

func _draw_actor(display: ActorDisplay, actor: Player) -> void:
	var row := actor.capture_state()
	var frame := display._frame
	frame.begin(0.0, actor.position)
	var presenter := display.presenter
	presenter._player_pose(actor.role, actor.position, actor.velocity, row, row, Vector2.RIGHT, false, false)
	presenter._player_cues(actor.role, row, row, actor.position, false)
	presenter._actors = {actor.role: row}
	presenter._health = row
	frame.aim_guide = presenter._aim_guide(row, frame.actors[0], false)
	for cue: Array in frame.cues:
		if cue[0] == "motion":
			display._world.motion(cue[1], cue[2], frame.now, cue[3])
	display._world.present(frame)

func _record_time(sim: CombatSimulator, actor: Player, delta := 1.0 / TCFG.SNAP_HZ) -> void:
	sim.time_field.history.record(delta, sim.tick, sim.time_field._sample.bind(sim, actor))

func _actor_animation(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var display := _display(parent, actor)
	var id := actor.role
	var pose := func(part: int) -> Transform2D:
		_draw_actor(display, actor)
		var canvas := display._world._canvas
		var batch := canvas._batches[0 if part == 0 else canvas._batch_count - 1]
		return batch.rows[0][2]

	var foot := actor.collision_rect().end.y - actor.position.y
	_place(actor, Vector2(160, 192 - foot - 8))
	actor.velocity.y = 900.0
	_draw_actor(display, actor)
	ActorStep.step(actor, NEUTRAL_INPUT)
	var hull := actor.collision_rect()
	var scale: Vector2 = pose.call(0).get_scale()
	expect(actor._grounded and scale.x > 2.6 and scale.y < 2.4 and actor.collision_rect() == hull,
			"a real landing squashes the drawn body while keeping its collision shape")
	display._frame.now = 0.3
	ActorStep.step(actor, NEUTRAL_INPUT)
	scale = pose.call(0).get_scale()
	expect(scale.distance_to(Vector2(2.5, 2.5)) < 0.003,
			"resting on the floor lets the landing pulse decay")
	var jump := ActorInput.BIT_UP
	display._world.motion(id, &"land", display._frame.now, 900.0)
	display._frame.now += ActorStep.DT
	ActorStep.step(actor, _attack(jump, jump))
	scale = pose.call(0).get_scale()
	expect(scale.x < 2.45 and scale.y > 2.55, "a jump directly after landing still stretches the drawn body")

	actor.state = Player.MOVE
	var at_rest: Transform2D = pose.call(1)
	display._frame.now += 0.125
	var walking: Transform2D = pose.call(1)
	expect(absf(walking.origin.y - at_rest.origin.y) > 2.0, "the held gun bobs with the walk cycle")
	actor.state = Player.STAND
	var ready: Transform2D = pose.call(1)
	display._world.fire(id, actor.equipped.type_id, display._frame.now)
	var recoil: Transform2D = pose.call(1)
	expect(recoil.origin.x < ready.origin.x - 1.0, "the fired gun kicks back along its aim axis")
	display._frame.now += 0.1
	expect(pose.call(1).is_equal_approx(ready), "recoil returns to the aiming pose")
	actor.equipped.reload_left = float(actor.equipped.definition["reload"]) * 0.5
	var reload: Transform2D = pose.call(1)
	expect(absf(reload.get_rotation() - ready.get_rotation()) > 0.5 and reload.origin.y > ready.origin.y,
			"the held gun tilts and drops during reload")
	display.free()
	cleanup()

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

func _equipment(tree: SceneTree) -> void:
	var ids := WeaponRegistry.all_ids()
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

func _damage_numbers(tree: SceneTree) -> void:
	var parent := world(tree)
	var shooter := player(parent)
	var sim := parent.combat
	var bird := sim.add_enemy("jump_bird", shooter, Vector2.ZERO)
	var view := WorldView.new()
	view.bind(canvas_for(parent), _terrain.map_size)
	var spec := WorldSpec.solo(_document, Vector2i.ZERO, [WeaponType.RIFLE], 0)
	var props := MatchWorld.new()
	props.combat = sim
	props.terrain = _terrain
	var presenter := MatchPresenter.new(spec, _terrain, shooter.role, null)
	var frame := presenter.frame
	frame.begin(0.0, shooter.position)
	presenter._sample_enemies(props.sample()["enemies"], false, false)
	var lethal_damage := bird.hp
	sim.resolve_hit(shooter, bird, CombatProfiles.DIRECT, bird.position, lethal_damage, 0.0)
	frame.begin(0.0, shooter.position)
	presenter._sample_enemies(props.sample()["enemies"], false, false)
	for cue: Array in frame.cues:
		if cue[0] == "number":
			view.hit(cue[1], cue[2], cue[3], cue[4])
	view.present(frame)
	var labels: Array = view._canvas._labels[1]
	expect(bird.is_dead and labels.size() == 1 and labels[0][0] == str(lethal_damage),
			"the hit that kills an enemy still produces a damage number")
	sim.resolve_hit(shooter, bird, CombatProfiles.DIRECT, bird.position, 1, 0.0)
	frame.now = 1.0
	view.present(frame)
	expect(labels.is_empty(), "hitting an enemy that is already dead produces no damage number")
	cleanup()

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
	expect(bird.active and bird.is_dead and bird.corpse_left == remaining and bird.collision_layer == CollisionWorld.LAYER_ENEMY,
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

func _daylight(tree: SceneTree) -> void:
	var sky := Daylight.new()
	for sample in [[0, "2f3643"], [280, "8d779f"], [325, "b38aa3"], [360, "c39da7"],
			[720, "aad9ea"], [1080, "c89475"], [1440, "2f3643"]]:
		var light := sky.set_minute(sample[0])
		expect(light == sky.color and sky.color.to_html(false) == sample[1],
				"the sky color also lights the world at minute %d" % sample[0])
	var dawn := sky.set_minute(360)
	var next := sky.set_minute(365)
	expect(sky.set_minute(362.5).is_equal_approx(dawn.lerp(next, 0.5)), "light changes smoothly between swatches")
	sky.free()
	var parent := world(tree)
	var combat := parent.combat
	var actor := player(parent)
	var field := WorldTime.new(GrainAccount.new())
	combat.time_field = field
	expect(Daylight.time_text(Daylight.minute_at(0.0)) == "06:00" and Daylight.minute_at(120.0) == 360.0,
			"a full daylight cycle returns to dawn after 120 seconds")
	field.elapsed = 89.75
	field.advance(combat, actor, 0, 1)
	_record_time(combat, actor)
	var before := field.elapsed
	for at in range(2, 17):
		field.advance(combat, actor, ActorInput.BIT_HASTE, at)
	expect(is_equal_approx(field.elapsed, before + 0.5) and Daylight.time_text(Daylight.minute_at(field.elapsed)).begins_with("00:"),
			"haste carries the sky and clock through midnight at player speed")
	field.rewind(combat, actor, 1.0)
	expect(field.elapsed == before and Daylight.time_text(Daylight.minute_at(field.elapsed)).begins_with("23:"),
			"rewinding a hasted interval restores the earlier time of day")
	field.advance(combat, actor, 0, 18)
	expect(is_equal_approx(field.elapsed, before + ActorStep.DT), "daylight resumes from the restored time")
	cleanup()

func _daylight_render(tree: SceneTree) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(96, 72)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(viewport)
	var canvas := canvas_for(viewport)
	canvas.rect(Rect2(4, 4, 16, 16), Color.WHITE, -1, false)
	canvas.rect(Rect2(24, 4, 16, 16), Color.WHITE)
	canvas.rect(Rect2(64, 4, 16, 16), Color(1, 0, 0, 0.5), -1, false)
	canvas.rect(Rect2(4, 46, 88, 12), Color.GRAY, -1, false)
	canvas.rect(Rect2(42, 33, 12, 27), Color.BLACK, -1, false)
	canvas.submit()
	canvas.set_daylight(Daylight.NOON)
	await RenderingServer.frame_post_draw
	var noon := viewport.get_texture().get_image()
	canvas.set_daylight(0.0)
	await RenderingServer.frame_post_draw
	var night := viewport.get_texture().get_image()
	var sky := night.get_pixel(60, 36)
	expect(sky.b > 0.12 and noon.get_pixel(60, 36).b > sky.b + 0.4, "empty space shows the night and day sky")
	expect(noon.get_pixel(60, 2).r > noon.get_pixel(60, 68).r + 0.12
			and noon.get_pixel(48, 17) == noon.get_pixel(60, 17)
			and night.get_pixel(48, 17) == night.get_pixel(60, 17),
			"the day and night sky grade vertically and stay even across each row")
	var glass := night.get_pixel(70, 12)
	var air := night.get_pixel(84, 12)
	var white := night.get_pixel(12, 12)
	expect(absf(glass.r - (air.r + white.r) * 0.5) < 0.02 and absf(glass.b - air.b * 0.5) < 0.02,
			"translucent paint blends with the night sky at its authored opacity")
	expect(night.get_pixel(12, 12).r < 0.6 and night.get_pixel(32, 12).r > 0.95,
			"night shades the world while combat cues keep their color")
	canvas._directional.enabled = false
	for minute in [280, 325]:
		canvas.set_daylight(minute)
		await RenderingServer.frame_post_draw
		var dawn := viewport.get_texture().get_image()
		expect(dawn.get_pixel(12, 12) == dawn.get_pixel(60, 0),
				"white terrain follows the brightening sky at %s" % Daylight.time_text(minute))
	canvas._directional.enabled = true
	for hour in [9, 15]:
		canvas.set_daylight(hour * 60.0)
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		expect(image.get_pixel(15, 30) == image.get_pixel(80, 30),
				"the sky is even across the row at %02d:00" % hour)
		var ground := image.get_pixel(10, 52)
		expect(image.get_pixel(41, 52) == ground and image.get_pixel(54, 52) == ground,
				"nearby geometry casts no shadow on either side at %02d:00" % hour)
	await _player_lighting_render(viewport, canvas)
	viewport.free()

func _player_lighting_render(viewport: SubViewport, canvas: WorldCanvas) -> void:
	viewport.size = Vector2i(176, 132)
	var view := WorldView.new()
	view.bind(canvas, Vector2(viewport.size))
	var frame := MatchFrame.new()
	var actor := MatchFrame.Pose.new()
	actor.anchor = Vector2(60, 60)
	frame.actors.append(actor)
	var render := func(minute: float, eyes := true) -> Image:
		frame.day_minute = minute
		view.present(frame)
		for light in canvas._eye_lights:
			light.enabled = eyes
		canvas.rect(Rect2(96, 27, 20, 30), Color.GRAY, -1, false)
		await RenderingServer.frame_post_draw
		return viewport.get_texture().get_image()
	var morning: Image = await render.call(9 * 60, false)
	var afternoon: Image = await render.call(15 * 60, false)
	expect(morning.get_pixel(26, 53).b > morning.get_pixel(86, 53).b
			and afternoon.get_pixel(26, 53).b < afternoon.get_pixel(86, 53).b,
			"Godot lights the player normals from the current sun direction")
	var morning_lit: Image = await render.call(9 * 60)
	expect(morning_lit.get_pixel(68, 51).get_luminance() - morning.get_pixel(68, 51).get_luminance() < 0.02,
			"eye lighting adds little to the face in the morning")
	var night_base: Image = await render.call(0.0, false)
	var night: Image = await render.call(0.0)
	expect(night.get_pixel(61, 36).r > night_base.get_pixel(61, 36).r + 0.4
			and night.get_pixel(78, 36).r > night_base.get_pixel(78, 36).r + 0.4
			and night.get_pixel(99, 38).b > night_base.get_pixel(99, 38).b + 0.02,
			"one point light illuminates both eyes and a nearby surface")
	var other := MatchFrame.Pose.new()
	other.id = 2
	other.anchor = actor.anchor
	frame.actors.append(other)
	var overlap: Image = await render.call(0.0, false)
	var light := canvas._eye_lights[0]
	light.enabled = true
	await RenderingServer.frame_post_draw
	var overlap_lit := viewport.get_texture().get_image()
	expect(overlap_lit.get_pixel(61, 36).r > overlap.get_pixel(61, 36).r
			and canvas._batch_count == 1 and canvas._batches[0].rows.size() == 2,
			"adjacent player bodies share a batch and receive each other's eye light")
	frame.actors.pop_back()
	frame.now = 0.5
	actor.facing = -1
	await render.call(0.0)
	expect(light.position.is_equal_approx(Vector2(50, 40)) and not canvas._eye_lights[1].visible,
			"the lamp follows the mirrored frame and the unused lamp is hidden")
	actor.downed = true
	await render.call(0.0)
	expect(light.position.is_equal_approx(Vector2(85, 72)), "the eye light rotates with the downed pose")
	viewport.size = Vector2i(1970, 180)
	frame.now = 1.0
	frame.actors.clear()
	for index in RoomOptions.ROYALE_PLAYERS.y:
		var pose := MatchFrame.Pose.new()
		pose.id = 100 + index
		pose.anchor = Vector2(60 + index * 120, 82)
		frame.actors.append(pose)
	var crowd: Image = await render.call(0.0)
	expect(frame.actors.all(func(pose: MatchFrame.Pose) -> bool:
		return crowd.get_pixel(int(pose.anchor.x) + 1, 58).r > 0.8),
			"separated players keep their eye lights in a full 16-player match")

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

func _team_health(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var attacker := player(parent, 1)
	var victim := player(parent, 2)
	var friendly := player(parent, 3)
	_place(attacker, Vector2(300, 300), 2)
	_place(victim, Vector2(400, 300), 1)
	_place(friendly, Vector2(200, 300), 2)
	var sim := parent.combat
	sim.team_counts = {1: 4, 2: 1}
	var hp := victim.sim_hp
	sim.resolve_hit(attacker, victim, CombatProfiles.DIRECT, victim.position, 10, 0.0)
	expect(victim.sim_hp == hp - 11, "team compensation increases the disadvantaged player's hit once")
	var previous := victim.sim_hp
	sim.resolve_hit(attacker, victim, CombatProfiles.DIRECT, victim.position, 10, 0.0)
	expect(victim.sim_hp == previous - 11 and not sim.resolve_hit(null, victim, CombatProfiles.BIRD_BOMB_HIT,
			victim.position, 1, 0.0), "consecutive gun hits apply while bird attacks respect active iframes")
	expect(not sim.resolve_hit(attacker, friendly, CombatProfiles.DIRECT, friendly.position, 10, 0.0)
			and friendly.sim_hp == hp, "a direct hit excludes allies")
	sim.resolve_hit(attacker, friendly, CombatProfiles.BLAST, friendly.position, 10, 0.0)
	sim.resolve_hit(attacker, attacker, CombatProfiles.BLAST, attacker.position, 10, 0.0)
	expect(friendly.sim_hp == hp - 10 and attacker.sim_hp == hp - 10,
			"friendly and self blast damage are allowed without compensation")
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

func _dynamic_blocking(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var mover := player(parent, 1)
	var blocker := player(parent, 2)
	mover.gravity = 0.0
	blocker.gravity = 0.0
	mover.collision_mask = CollisionWorld.LAYER_TERRAIN | CollisionWorld.LAYER_TEAM_A
	mover.collision_layer = 0
	mover.position = Vector2(200, 512)
	blocker.position = Vector2(320, 512)
	mover.sync_collision_geometry()
	blocker.sync_collision_geometry()
	collider(blocker, CollisionWorld.LAYER_TEAM_A)
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
		mover.gravity = WCFG.gravity0
		mover.collision_layer = 0
		mover.collision_mask = CollisionWorld.LAYER_TERRAIN
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
	blocked.collision_mask = CollisionWorld.LAYER_TERRAIN
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
	ceiling_mover.collision_mask = CollisionWorld.LAYER_TERRAIN
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
	runner.collision_mask = CollisionWorld.LAYER_TERRAIN | CollisionWorld.LAYER_TEAM_A
	runner.position = Vector2(400, 384 - 57)
	runner.sync_collision_geometry()
	var blocker := player(dynamic, 2)
	blocker.gravity = 0.0
	# 阻挡者悬在台阶上方。角色沿原高度移动时不会碰到它，但尝试抬高 16 像素后会被挡住。
	blocker.position = Vector2(500, 213)
	blocker.sync_collision_geometry()
	collider(blocker, CollisionWorld.LAYER_TEAM_A)
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
func _mvp() -> void:
	var host := arena(WorldSpec.TEAM, [1, 2, 3, 4], {1: 1, 2: 1, 3: 2, 4: 2}, {})
	var world := host.world
	for id: int in world.players:
		world._stats[id]["kills"] = 50 if id == 1 else (20 if id == 3 else 1)
	world.rules.winner = 2
	expect(arena_round(world)["mvp"] == 3, "the team MVP comes from the winning team")
	world._stats[4]["kills"] = 20
	expect(arena_round(world)["mvp"] == 3, "an exact statistical tie is decided by role order")
	world.rules.winner = 0
	expect(arena_round(world)["mvp"] == 0, "a drawn team match has no MVP")
	host.close()

func _duel_spawns() -> void:
	var host := arena(WorldSpec.DUEL, [1, 2], {}, {"player_collision": true})
	var world := host.world
	var sides := SpawnPicker.respawn_cells(world.spec.map)
	expect(world.problem.is_empty(), "the duel loads the multiplayer spawn points")
	expect(players_on_map_points(world, [1], sides[1]) and players_on_map_points(world, [2], sides[2]),
			"duelists open on their respective marked sides")
	world.rules.phase = MatchRules.Phase.PLAYING
	var winner := world.players[1]
	var victim := world.players[2]
	winner.position = Vector2.ZERO
	winner.sim_hp = 13
	victim.position = Vector2.ZERO
	victim.apply_hit_health(0)
	host.fixed_step()
	expect(winner.sim_hp == 13 and players_on_map_points(world, [1], sides[1])
			and victim.sim_downed and victim.respawn_tick == world.tick + MatchRules.RESPAWN_TICKS,
			"the survivor moves to a marked point with current HP while the victim waits")
	for i in MatchRules.RESPAWN_TICKS - 1:
		host.fixed_step()
	victim._auto_jump_timer = 0.35
	host.fixed_step()
	expect(not victim.sim_downed and victim.sim_hp == victim.sim_max_hp and players_on_map_points(world, [2], sides[2]),
			"the victim revives at full HP on the other marked side")
	expect(victim._auto_jump_timer == 0.0, "respawn clears an automatic jump from the previous life")
	world.rules.scores[1] = 5
	host.fixed_step()
	world.rules.round_timer = ActorStep.DT
	host.fixed_step()
	expect(world.rules.round_number == 2 and players_on_map_points(world, [1], sides[2])
			and players_on_map_points(world, [2], sides[1]), "duelists use the opposite map sides in round two")
	host.close()

func _team_setup() -> void:
	var disabled := WeaponRegistry.all_ids()
	var teams := {1: 1, 2: 1, 3: 2}
	var roles := [1, 2, 3]
	var invalid := arena(WorldSpec.TEAM, roles, teams, {"disabled_weapons": disabled}).world
	expect(not invalid.problem.is_empty() and invalid.combat == null, "disabling all weapons rejects the match")
	disabled.erase(WeaponType.PISTOL)
	var host := arena(WorldSpec.TEAM, roles, teams, {"disabled_weapons": disabled}, "res://maps/demo.cyrm")
	var world := host.world
	expect(world.problem.is_empty(), "the team match loads and validates its map")
	for p: Player in world.players.values():
		expect(p.collision_mask == CollisionWorld.LAYER_TERRAIN,
				"players collide with terrain only; NPC contact is damage-only")
		expect(p.equipped != null and p.equipped.type_id == WeaponType.PISTOL,
				"each player starts equipped when only one type is enabled")
	expect(world.rules.phase == MatchRules.Phase.WAITING and is_zero_approx(world.rules.round_timer),
			"setup starts in WAITING with a zero timer")
	expect(world.players[3].sim_max_hp == 55 and world.players[1].sim_max_hp == 50,
			"team max HP follows the fixed roster")
	expect(int(world.rules.scores.get(2, 0)) == 1 and int(world.rules.scores.get(1, 0)) == 0,
			"the smaller team starts with its score bonus")
	expect(world.rules.team_counts == {1: 2, 2: 1}, "the roster counts are frozen at setup")
	var sides := SpawnPicker.respawn_cells(world.spec.map)
	expect(players_on_map_points(world, [1, 2], sides[1]) and players_on_map_points(world, [3], sides[2]),
			"each team opens on distinct points on its own side")
	var actor := world.players[1]
	var drop := _attack(0, ActorInput.BIT_DROP)
	host.fixed_step({1: drop})
	expect(actor.equipped != null, "WAITING blocks a queued drop")
	host.enqueue(MatchWorld.Command.START)
	host.fixed_step()
	world.rules.round_timer = ActorStep.DT
	host.fixed_step()
	host.fixed_step({1: drop})
	expect(actor.equipped == null, "PLAYING accepts the same drop")
	_win_team_round(host)
	expect(world.rules.phase == MatchRules.Phase.WAITING and world.rules.round_number == 2
			and players_on_map_points(world, [1, 2], sides[2]) and players_on_map_points(world, [3], sides[1]),
			"the next round opens on opposite sides and waits for readiness")
	expect(int(world.rules.scores.get(2, 0)) == 1 and int(world.rules.scores.get(1, 0)) == 0,
			"the next round reapplies the initial score bonus")
	world.rules.phase = MatchRules.Phase.PLAYING
	_win_team_round(host)
	var result := arena_round(world)
	expect(result["state"] == MatchRules.Phase.MATCH_OVER and result["match_winner"] == 1,
			"the second round win seals the match result")
	var final_tick := world.tick
	host.enqueue(MatchWorld.Command.LEAVE, 3)
	host.fixed_step()
	expect(world.tick == final_tick and arena_round(world) == result, "terminal matches keep their committed result")
	var epoch := host._buffers[1].epoch
	host.accept_input(1, [[], [[1, epoch, final_tick + 1, ActorInput.BIT_DROP, 0, 0, Vector2.RIGHT]]], 0)
	expect(host._buffers[1].actions.is_empty(), "the final result stops accepting input")
	host.close()

func _win_team_round(host: MatchSession) -> void:
	var world := host.world
	for kill in TeamRules.kills_to_win(3):
		world.rules.score_down(3, 1)
	host.fixed_step()
	world.rules.round_timer = ActorStep.DT
	host.fixed_step()

## 用固定随机种子验证安全点间的抽选，并检查开启碰撞时阵亡角色会让出占用的点。
func _team_respawn(tree: SceneTree) -> void:
	cleanup()
	var parent := world_from_solid(tree, 125, 75, func(sx: int, sy: int) -> bool: return sy >= 74 * 4)
	var info := CyrmMap.load_file("res://maps/demo.cyrm")
	var respawn := SpawnPicker.respawn_cells(info)
	var rules := MatchRules.new(RandomNumberGenerator.new())
	rules.setup(PvpSession.MODE_TEAM, [1, 2, 3], {1: 1, 2: 1, 3: 2}, info, {"player_collision": true})
	var ally := player(parent, 1)
	ally.team = 1
	ally.position = CyrmMap.world_position(respawn[1][0])
	var enemy := player(parent, 3)
	enemy.team = 2
	enemy.position = CyrmMap.world_position(respawn[1][1])
	var players := {1: ally, 3: enemy}
	var picked := {}
	rules._rng.seed = 1729
	for i in 16:
		picked[rules.spawn_for(players, 2)] = true
	var size: Vector2i = info.size
	expect(picked.size() > 1 and picked.keys().all(func(cell: Vector2i) -> bool:
		var distance := GridPathfinder.toroidal_dist(cell, respawn[1][1], size.x, size.y)
		return respawn[1].has(cell) and cell != respawn[1][0] and distance >= SpawnPicker.PREFERRED_DISTANCE),
			"team respawn varies among free points at least eight cells from the enemy")
	# 让队友占用所有己方复活点，比较启用和关闭角色碰撞时的选点结果。
	for index in respawn[1].size():
		var mate := player(parent, 10 + index)
		mate.team = 1
		mate.position = CyrmMap.world_position(respawn[1][index])
		mate.sync_collision_geometry()
		players[10 + index] = mate
	expect(rules.spawn_for(players, 2) == SpawnPicker.NO_CELL,
			"a fully occupied team side reports no point instead of overlapping")
	rules.player_collision = false
	expect(respawn[1].has(rules.spawn_for(players, 2)), "without blocking, occupancy never delays a team respawn")
	rules.player_collision = true
	players[10 + respawn[1].size() - 1].force_down()
	expect(rules.spawn_for(players, 2) == respawn[1].back(), "a downed player frees the only available point")
	cleanup()

func _sparse_spawn_map(tree: SceneTree) -> void:
	var size := Vector2i(18, 4)
	var parent := world_from_solid(tree, size.x, size.y, func(_x: int, y: int) -> bool: return y >= 10)
	var info := CyrmMap.create(size * 4)
	var ground: PackedInt32Array = info.layers[CyrmMap.SCENE]
	var wall := CyrmMap.tile_value(wall_texture())
	for i in range(info.size.x * 10, ground.size()): ground[i] = wall
	info.points[0] = {"kind": "player", "cell": Vector2i(2, 6)}
	info.points[1] = {"kind": "player2", "cell": Vector2i(66, 6)}
	for x: int in [2, 10, 66]: info.points[x] = {"kind": "respawn", "side": 1, "cell": Vector2i(x, 6)}
	expect(not MatchRules.new(RandomNumberGenerator.new()).setup(PvpSession.MODE_PVP, [1, 2], {}, info, {}).is_empty(),
			"a duel with a missing side rejects the map even when both solo markers exist")
	expect(not MatchRules.new(RandomNumberGenerator.new()).setup(PvpSession.MODE_TEAM, [1, 2], {1: 1, 2: 2}, info, {}).is_empty(),
			"a team match rejects a map with an empty side")
	expect(not MatchRules.new(RandomNumberGenerator.new()).setup(PvpSession.MODE_ROYALE, [1, 2, 3, 4], {}, info, {}).is_empty(),
			"a Royale with too few marked points rejects the map")
	var rules := MatchRules.new(RandomNumberGenerator.new())
	expect(not rules.setup(PvpSession.MODE_ROYALE, [1], {}, info, {}).is_empty()
			and not rules.setup(PvpSession.MODE_ROYALE, [1, 2, 3], {}, info, {"max_players": 2}).is_empty(),
			"Royale admission respects both the minimum roster and the configured room cap")
	var problem := rules.setup(PvpSession.MODE_ROYALE, [1, 2], {}, info, {"player_collision": true})
	expect(problem.is_empty(), "a Royale can use points that all come from the same side")
	if problem.is_empty():
		var self_player := player(parent, 1)
		var enemy := player(parent, 2)
		self_player.position = CyrmMap.world_position(Vector2i(10, 6))
		enemy.position = CyrmMap.world_position(Vector2i(70, 6))
		expect(rules.spawn_for({1: self_player, 2: enemy}, 1) == Vector2i(10, 6),
				"with no safe point, pick the farthest across the seam and ignore the moving player's own position")
	info.points[75] = {"kind": "respawn", "side": 2, "cell": Vector2i(2, 6)}
	expect(not MatchRules.new(RandomNumberGenerator.new()).setup(PvpSession.MODE_PVP, [1, 2], {}, info, {}).is_empty(),
			"a point marked on both sides cannot start a duel")
	cleanup()

## 在同一个测试场景中验证摄像机的初始偏移、目标跟随、抖动和跨地图边缘的行为。
func _camera(tree: SceneTree) -> void:
	cleanup()
	var parent := world(tree)
	var cam := MatchCamera.new()
	parent.add_child(cam)
	var target := Node2D.new()
	parent.add_child(target)
	target.position = Vector2(300, 200)
	cam.advance(1.0 / 60.0, target.position, _terrain.map_size)
	var bias := Vector2(0.0, CFG.cam_y_bias)
	expect(cam.base_position.is_equal_approx(Vector2(300, 200) + bias),
			"the first bind initializes the base position with the y bias")
	var leading := MatchCamera.new()
	parent.add_child(leading)
	leading.advance(ActorStep.DT, target.position, _terrain.map_size, CFG.move_speed * 0.5)
	expect(leading.base_position.is_equal_approx(target.position + bias + Vector2(50, 0)),
			"half running speed leads the player by fifty world pixels")
	leading = MatchCamera.new()
	parent.add_child(leading)
	leading.advance(ActorStep.DT, target.position, _terrain.map_size, -CFG.charge_velocity)
	expect(leading.base_position.is_equal_approx(target.position + bias + Vector2(-100, 0)),
			"a leftward dash caps the camera lead at one hundred world pixels")
	var before_stop := leading.base_position.x
	leading.advance(ActorStep.DT, target.position, _terrain.map_size, 0.0)
	expect(leading.base_position.x > before_stop and leading.base_position.x < target.position.x,
			"stopping eases the camera back toward the player")
	# 先让目标在摄像机的跟随阈值以内移动，然后越过阈值。
	target.position += Vector2(CFG.cam_deadzone - 1.0, 0.0)
	cam.advance(1.0 / 60.0, target.position, _terrain.map_size)
	var settled: Vector2 = cam.base_position
	expect(settled.x < 301.0, "a target inside the deadzone does not move the camera")
	target.position += Vector2(200.0, 0.0)
	cam.advance(1.0 / 60.0, target.position, _terrain.map_size)
	var moved: Vector2 = cam.base_position
	expect(moved.x > settled.x + 1.0 and moved.x < target.position.x - 1.0,
			"a target outside the deadzone is followed with exponential smoothing")
	# 在一次强烈抖动中触发一次短而弱的抖动。画面位置等于跟随位置加上当前抖动偏移。
	cam.shake(30.0, 0.5)
	cam.shake(5.0, 0.1)
	expect(is_equal_approx(cam._shake_amt, 30.0) and cam._shake_time >= 0.49,
			"a weak shake cannot replace a stronger amplitude or a longer duration")
	cam.advance(1.0 / 60.0, target.position, _terrain.map_size)
	expect(cam.position.is_equal_approx(cam.base_position + cam._shake_offset),
			"the rendered position is base + shake offset")
	# 清除抖动后，将目标放到地图另一端，观察摄像机是否沿跨越边缘的较短方向跟随。
	cam._shake_amt = 0.0
	cam._shake_time = 0.0
	cam._shake_dur = 0.0
	cam._shake_offset = Vector2.ZERO
	target.position = Vector2(_terrain.map_size.x - 4.0, 200)
	cam.base_position = Vector2(4.0, 200 + CFG.cam_y_bias)
	cam.advance(1.0 / 60.0, target.position, _terrain.map_size)
	expect(cam.base_position.distance_to(target.position + bias) < 32.0,
			"the camera moves into the target's copy across the seam")
	cleanup()
