extends "res://tests/case.gd"

class BetaWorld extends Node:
	var players := {}
	var bullets: Array = []
	var time_economy := TimeEconomy.new(TimeRules.new())
	var _round_state := NetEvent.RoundState.PLAYING
	var _snap_tick := 0
	var epoch_changes := 0
	var events: Array = []
	func live_bullets() -> Array: return bullets
	func new_epoch(_role: int) -> void: epoch_changes += 1
	func projectile_state(bullet: BulletBase) -> Dictionary: return bullet.motion_state()
	func broadcast(kind: int, data: Variant) -> void: events.append([kind, data])

func run(tree: SceneTree) -> void:
	_grenade(tree)
	var parent := world(tree)
	var actor := player(parent)
	var initial := actor.capture_state()
	for tick in 32:
		ActorStep.step(actor, InputBuffer.neutral())
		if actor.capture_state()["floor"]: break
	expect(actor.capture_state()["floor"] and actor.position.y < 192, "real terrain collision stops a falling actor")
	actor.restore_state(initial)
	ActorStep.step(actor, InputBuffer.neutral().merged({"ax": 1.0}, true))
	expect(actor.position.x > initial["pos"].x, "real actor/shape moves through native step")
	actor.restore_state(initial)
	var record := InputBuffer.neutral().merged({"ax": 1.0, "held": ActorInput.BIT_ATTACK, "pressed": ActorInput.BIT_ATTACK}, true)
	var actions := ActorStep.step(actor, record)
	expect(actions.any(func(action: Dictionary) -> bool: return action["kind"] == "fire"), "native weapon produces a fire action")
	expect(actor.capture_state()["mag"] == initial["mag"] - 1, "one shot consumes one round")
	var simulated := actor.capture_state()
	actor.present_tick(ActorStep.DT)
	expect(actor.capture_state() == simulated, "presentation does not change simulation state")
	actor.restore_state(initial)
	ActorStep.step(actor, record)
	expect(actor.capture_state() == simulated, "restoring actor and weapon reproduces the same tick")
	actor.restore_state(initial)
	_replay(actor)
	_query_history(parent, actor, initial)
	_confirmed_lifecycle(actor, initial)
	_world_rewind(parent, actor)
	_beta_history(parent, actor)

func _grenade(tree: SceneTree) -> void:
	var source: BulletBase = preload("res://scenes/weapons/grenade_bullet.tscn").instantiate()
	expect(source.explodes, "grenade scene loads its explosive type")
	var fields := ["explodes", "direct_hit_damage", "fuse_time", "hit_fuse_time",
			"explosion_radius", "explosion_damage", "explosion_knockback"]
	var expected := {}
	for field in fields: expected[field] = source.get(field)
	var packed := PackedScene.new()
	expect(packed.pack(source) == OK, "grenade scene can be repacked for export")
	var path := OS.get_temp_dir().path_join("cyr-grenade-%d.scn" % OS.get_process_id())
	expect(ResourceSaver.save(packed, path) == OK, "grenade scene can be saved in binary format")
	var binary := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var restored: BulletBase = binary.instantiate()
	for field in fields:
		expect(restored.get(field) == expected[field], "binary scene retains grenade %s" % field)
	restored.free()
	source.free()
	DirAccess.remove_absolute(path)

	var parent := world(tree)
	var actor := player(parent)
	var authority := AuthorityWorld.new()
	parent.add_child(authority)
	authority.set_physics_process(false)
	authority.terrain = TileDefs.terrain
	authority.players = {actor.role: actor}
	authority._stats = {actor.role: {"self_damage": 0}}
	authority.time_economy = TimeEconomy.new(TimeRules.new())
	authority.time_economy.add_role(actor.role)
	authority.beta = BetaHistory.new(authority)
	authority._round_state = NetEvent.RoundState.PLAYING
	actor.authority_world = authority
	for type_id in WeaponRegistry.all_ids():
		if WeaponRegistry.scene_of(type_id) == "res://scenes/weapons/grenade_launcher.tscn":
			actor.weapons.set_initial_inventory([type_id])
	var weapon: WeaponBase = actor.weapons.current_weapon()
	weapon.bullet_scene = binary
	var events: Array = []
	authority.event.connect(func(kind: int, data: Variant, _except: int) -> void: events.append([kind, data]))
	weapon._spawn_projectiles({"serial": 1, "input_seq": 0, "input_epoch": 1,
			"dir": Vector2.DOWN, "pos": Vector2(160, 150)})
	var bullet: BulletBase = authority.live_bullets()[0]
	expect(bullet.apply_damage, "authority grenade remains authoritative with the multiplayer display flag set")
	var terrain_before := TileDefs.terrain.capture_cell(Vector2i(2, 3))
	var hp_before := actor.hp
	var fused := false
	for tick in range(1, 61):
		authority._snap_tick = tick
		authority.beta.tick(ActorStep.DT)
		bullet.simulate_tick(ActorStep.DT)
		fused = fused or bullet._fuse_active
		if bullet.finished: break
	var explosions := events.filter(func(event: Array) -> bool: return event[0] == NetEvent.Kind.EXPLOSION)
	expect(fused and bullet.exploded and bullet.is_queued_for_deletion(), "Beta grenade bounces, starts its fuse and detonates")
	expect(explosions.size() == 1 and explosions[0][1]["id"] == bullet.entity_id,
			"authority broadcasts the grenade explosion once")
	expect(actor.hp < hp_before and TileDefs.terrain.capture_cell(Vector2i(2, 3)) != terrain_before,
			"grenade explosion damages players and terrain")
	actor.authority_world = null
	cleanup()

func _world_rewind(parent: Node, actor: Player) -> void:
	var scene := preload("res://scenes/enemies/enemy_bullet.tscn")
	var bullet: EnemyBullet = scene.instantiate()
	bullet.launch(Vector2(40, 30), 500.0, 3, 0.5)
	bullet.water_mult = 1.5
	bullet.position = Vector2(120, 100)
	bullet.set_meta("scene_path", scene.resource_path)
	parent.add_child(bullet)
	var state := bullet.rewind_state()
	var position := actor.global_position
	var rewind := WorldRewind.new(parent)
	rewind.record(1.0 / TimeParams.SNAP_HZ, actor, [], [bullet])
	bullet.position += Vector2(40, 0)
	bullet.damage = 1
	actor.position += Vector2(40, 0)
	rewind.record(1.0 / TimeParams.SNAP_HZ, actor, [], [bullet])
	rewind.begin()
	rewind.step(1.0, actor)
	var restored := rewind.replay_bullets()
	expect(actor.global_position == position, "single-player rewind restores the actor")
	expect(restored.size() == 1 and restored[0].rewind_state() == state,
			"single-player rewind recreates an enemy projectile with its full motion and damage")
	rewind.finish()

func _replay(actor: Player) -> void:
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	rollback.terrain = TileDefs.terrain
	rollback.reset(1, 0, 100, 0)
	rollback._clock = 100.0
	rollback._input.seed(InputBuffer.neutral().merged({"target_tick": 100}, true), 100)
	rollback._remember_state()
	var source: PacketInputSource = actor.input_source
	source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0, "held": ActorInput.BIT_ATTACK, "pressed": ActorInput.BIT_ATTACK}, true))
	var authority_projectiles := {}
	for tick in range(101, 109):
		rollback.capture(source, Vector2.RIGHT, tick, 0)
		rollback.advance(ActorStep.DT)
		if tick == 104: authority_projectiles = _projectiles(rollback.combat_prediction)
	var original := actor.capture_state()
	var original_projectiles := _projectiles(rollback.combat_prediction)
	var saved: NativePredictionFrame = rollback._states[104]
	expect(not authority_projectiles.is_empty(), "replay fixture has a live projectile")
	var snapshot: NativeProjectileSnapshot = saved.projectiles
	expect(snapshot.matches(authority_projectiles), "later simulation cannot mutate an earlier projectile frame")
	var altered := authority_projectiles.duplicate(true)
	for id in altered: altered[id]["fuse_elapsed"] += 0.25
	expect(not snapshot.matches(altered) and snapshot.matches(authority_projectiles),
			"projectile comparison detects changed timers without changing stored history")
	var buffer := InputBuffer.new()
	buffer.restore_cursor(saved.cursor)
	var own := {"epoch": 1, "ack": buffer.ack, "action_ack": buffer.action_ack,
			"timing_seq": 0, "lead": 2, "input": buffer._last, "rewind": false,
			"state": Player.expand_prediction_state(saved.player)}
	var frame := {"tick": 104, "map_revision": TileDefs.terrain.revision, "own": own,
			"time": {}, "world": {"players": {}, "projectiles": authority_projectiles}}
	expect(rollback.reusable_tick(frame) == 108, "matching authority retains the full prediction suffix")
	rollback.reconcile(own, 104, 0, true, authority_projectiles)
	expect(rollback.replay_ticks == 0 and actor.capture_state() == original, "reuse executes no unnecessary replay")
	expect(rollback.can_replay_from(105), "short suffix has a usable checkpoint")
	rollback.replay_from(105)
	expect(rollback.replay_ticks == 4 and actor.capture_state() == original, "checkpoint suffix replay equals original simulation")
	expect(_projectiles(rollback.combat_prediction) == original_projectiles, "checkpoint restores and replays projectile motion exactly")
	rollback.reconcile(own, 104, 0, false, authority_projectiles)
	expect(rollback.replay_ticks == 4 and actor.capture_state() == original, "full authority restore equals optimized replay")
	expect(_projectiles(rollback.combat_prediction) == original_projectiles, "authority restore and native projectile history produce the same future")
	rollback.combat_prediction.clear()

func _projectiles(combat: CombatPrediction) -> Dictionary:
	var states := {}
	for id in combat.projectiles:
		var entry: NativeProjectileEntry = combat.projectiles[id]
		if entry.active and not entry.bullet.finished: states[id] = entry.bullet.motion_state()
	return states

func _query_history(parent: Node, actor: Player, initial: Dictionary) -> void:
	actor.restore_state(initial)
	var owner := player(parent, 2)
	var proxy := player(parent, 3)
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	rollback.terrain = TileDefs.terrain
	rollback._native_history.configure_remotes([
			[owner.role, owner, ActorCollider.new(owner, 1), 0],
			[proxy.role, proxy, ActorCollider.new(proxy, 1), 0]])
	var combat := rollback.combat_prediction
	combat.actors = {actor.role: actor, owner.role: owner, proxy.role: proxy}
	for at in range(4):
		rollback._sim_tick = at
		rollback._remember_state()
	var id: int = (owner.role << 48) | 1
	var state := {"type_id": WeaponRegistry.all_ids()[0], "pos": Vector2(64, 32),
			"vel": Vector2(60, 0), "traveled": 0.0, "fuse_active": false,
			"fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	combat.seed_projectile(id, state, 0, owner)
	combat.projectiles[id].bullet.gravity_factor = 0.0
	var positions := [actor.position, proxy.position]
	actor.position = Vector2(70, 32)
	proxy.position = Vector2(70, 32)
	owner.rewinding = true
	rollback._sim_tick = 4
	rollback._remember_state()
	expect(not rollback._states[3].remote[owner.role][0] and rollback._states[4].remote[owner.role][0],
			"later owner modes cannot mutate an earlier prediction frame")
	var plan := combat.catch_up_remote(id, rollback._states, 3)
	expect(not plan.is_empty() and plan["contacts"].is_empty(),
			"remote catch-up reads saved contact positions instead of current scene nodes")
	actor.position = positions[0]
	proxy.position = positions[1]
	owner.rewinding = false
	if not plan.is_empty(): combat.commit_catch_up(id, plan)
	expect(combat.proxy_queries_match(1, [owner, proxy]), "unchanged remote query dependencies retain history")
	proxy.position = Vector2(70, 32)
	expect(not combat.proxy_queries_match(1, [owner, proxy]), "a previously missed proxy entering the path invalidates history")
	proxy.position = positions[1]
	owner.rewinding = true
	expect(not combat.proxy_queries_match(1, [owner, proxy]), "a changed projectile owner rewind mode invalidates history")
	owner.rewinding = false
	combat._native.discard_queries_after(1)
	proxy.position = Vector2(70, 32)
	expect(not combat.proxy_queries_match(1, [owner, proxy]) and combat.proxy_queries_match(2, [owner, proxy]),
			"suffix invalidation keeps earlier queries and discards later queries")
	proxy.position = positions[1]
	combat.begin_tick(1 + CombatPrediction.KEEP + 1)
	proxy.position = Vector2(70, 32)
	expect(combat.proxy_queries_match(1, [owner, proxy]), "reused history slots do not expose stale tick queries")
	combat.clear()
	owner.free()
	proxy.free()
	actor.restore_state(initial)

func _confirmed_lifecycle(actor: Player, initial: Dictionary) -> void:
	actor.restore_state(initial)

	var combat := CombatPrediction.new()
	combat.bind(actor)
	var id: int = (2 << 48) | 1
	combat.hits[id] = [{"tick": 200, "source": 2, "shooter": 2, "victim": actor.role,
			"hp": initial["hp"] - 1, "knock": Vector2.ZERO, "facing": 1, "pos": actor.position}]
	combat.step(200, [actor], false)
	expect(actor.sim_hp == initial["hp"] - 1, "confirmed explosion applies after its projectile is gone")
	combat.acknowledge(200)
	for serial in [2, 1]:
		combat.hits[(2 << 48) | serial] = [{"tick": 201, "source": 0, "shooter": 2, "victim": actor.role,
				"hp": initial["hp"] - serial - 1, "knock": Vector2.ZERO, "facing": 1, "pos": actor.position}]
	combat.step(201, [actor], false)
	expect(actor.sim_hp == initial["hp"] - 3, "late direct hits retain stable attack order without live projectiles")
	combat.beams[id] = {"tick": 200, "confirmed": true}
	combat.beams[id + 1] = {"tick": 202, "confirmed": true}
	combat.acknowledge(201)
	expect(not combat.beams.has(id) and combat.beams.has(id + 1), "ACK prunes covered beams while keeping future confirmations")
	combat.clear()
	actor.restore_state(initial)

func _beta_history(parent: Node, actor: Player) -> void:
	var other := player(parent, 2)
	var world := BetaWorld.new()
	parent.add_child(world)
	world.players = {actor.role: actor, other.role: other}
	for owner: Player in [actor, other]:
		world.time_economy.add_role(owner.role)
		owner.input_source.apply_packet(InputBuffer.neutral())
		var profile := WeaponRegistry.projectile_profile(WeaponRegistry.all_ids()[0])
		var bullet: BulletBase = profile["scene"].instantiate()
		bullet.shooter = owner
		bullet.entity_id = owner.role << 48
		parent.add_child(bullet)
		bullet.set_physics_process(false)
		world.bullets.append(bullet)
	var history := BetaHistory.new(world)
	for tick in [3, 6, 9]:
		world._snap_tick = tick
		actor.position.x = tick * 10.0
		world.bullets[0].position.x = tick * 12.0
		world.bullets[1].position.x = tick * 15.0
		history.tick(ActorStep.DT)
	expect(history.frames[actor.role][1]["bullets"].keys() == [actor.role << 48], "Beta history records only the shooter's projectiles")
	actor.shot_serial = 123
	actor.input_source.apply_packet(InputBuffer.neutral().merged({"held": ActorInput.BIT_REWIND}, true))
	world._snap_tick = 10
	history.tick(0.025 / TimeParams.REWIND_START_MULT)
	expect(actor.position.x == 60.0 and actor.shot_serial == 123, "Beta rewind chooses the preceding sample and preserves attack identity")
	expect(world.bullets[0].position.x == 72.0 and world.bullets[1].position.x == 135.0, "Beta rewind restores owned bullets without changing another player")
	history.finish(actor.role)
	expect(history.frames[actor.role].size() == 2 and world.epoch_changes == 1, "ending Beta rewind trims the future and changes control epoch once")
	expect(world.events.back()[1]["projectiles"].keys() == [actor.role << 48], "Beta rewind broadcast contains the shooter's current projectiles")
