extends "res://tests/case.gd"

# 快照槽位由 PlayerStateSchema 唯一给出。
static var POS := PlayerStateSchema.slot("pos")
static var FLOOR := PlayerStateSchema.slot("floor")
static var MAG := PlayerStateSchema.slot("mag")
static var HP := PlayerStateSchema.slot("hp")

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

# 团队复活测试用的最小世界：只需要玩家表。
class FakeWorld extends Node:
	var players: Dictionary = {}
	var _round_num := 1

# 只记录阶段顺序的模拟器；不执行弹丸物理或爆炸结算。
class OrderSim extends CombatSimulator:
	var order: Array = []
	func _step_projectile(id: int) -> void:
		order.append(["p", id])
	func _step_blast(id: int) -> void:
		order.append(["b", id])

func run(tree: SceneTree) -> void:
	_grenade(tree)
	_terrain_contacts(tree)
	_projectile_order(tree)
	_downed_projectile(tree)
	_blast_phase_order(tree)
	var parent := world(tree)
	var actor := player(parent)
	var initial := actor.capture_state()
	for tick in 32:
		ActorStep.step(actor, InputBuffer.neutral())
		if actor.capture_state()[FLOOR]: break
	expect(actor.capture_state()[FLOOR] and actor.position.y < 192, "real terrain collision stops a falling actor")
	actor.restore_state(initial)
	ActorStep.step(actor, InputBuffer.neutral().merged({"ax": 1.0}, true))
	expect(actor.position.x > initial[POS].x, "real actor/shape moves through the engine step")
	actor.restore_state(initial)
	var record := InputBuffer.neutral().merged({"ax": 1.0, "held": ActorInput.BIT_ATTACK, "pressed": ActorInput.BIT_ATTACK}, true)
	var actions := ActorStep.step(actor, record)
	expect(actions.any(func(action: Dictionary) -> bool: return action["kind"] == "fire"), "weapon produces a fire action")
	expect(actor.capture_state()[MAG] == initial[MAG] - 1, "one shot consumes one round")
	var simulated := actor.capture_state()
	actor.present_tick(ActorStep.DT)
	expect(actor.capture_state() == simulated, "presentation does not change simulation state")
	actor.restore_state(initial)
	ActorStep.step(actor, record)
	expect(actor.capture_state() == simulated, "restoring actor and weapon reproduces the same tick")
	actor.restore_state(initial)
	_replay(actor)
	_confirmed_lifecycle(actor, initial)
	_world_rewind(parent, actor)
	_beta_history(parent, actor)
	_dynamic_blocking(tree)
	_swept_hit(tree)
	_grenade_direct(tree)
	_beam_targets(tree)
	var prediction = preload("res://tests/prediction_case.gd").new()
	prediction.run(tree)
	prediction.cleanup()
	checks += prediction.checks
	failures.append_array(prediction.failures)
	_authority_blast(tree)
	_late_projectile(tree)
	_team_rules()
	_team_health(tree)
	_blast_delay(tree)
	_step_up(tree)
	_mvp(tree)
	_team_setup(tree)
	_team_respawn(tree)
	_camera(tree)

func _terrain_contacts(tree: SceneTree) -> void:
	var parent := world(tree)
	var bullet: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	bullet.setup(Vector2.DOWN, 900.0, 600.0, 1.0, Color.WHITE, null)
	bullet.hit_damage = 1
	bullet.position = Vector2(136, 160)
	parent.add_child(bullet)
	var sub := Vector2i(8, 12)
	var before := TileDefs.terrain.get_hp(sub)
	for i in 4:
		bullet.simulate_tick(ActorStep.DT)
		if bullet.finished: break
	expect(bullet.finished and not bullet.is_physics_processing(), "ordinary terrain hit stops projectile simulation")
	expect(TileDefs.terrain.get_hp(sub) == before - bullet.hit_damage, "ordinary projectile damages RID-backed terrain")
	cleanup()
	var walls := {}
	var texture := wall_texture(true)
	for x in 8: walls[Vector2i(x, 3)] = texture
	parent = world_with_walls(tree, 8, 4, walls)
	var actor := player(parent)
	for i in 40:
		ActorStep.step(actor, InputBuffer.neutral())
		if not actor.motion_contacts.is_empty(): break
	expect(not actor.motion_contacts.is_empty() and is_equal_approx(actor.velocity.y, -actor.elastic_bounce),
			"actor bounces from elastic RID-backed terrain")
	cleanup()

## 同一 tick 的爆炸 ID 小于弹丸 ID 时，仍必须先推进全部弹丸，再结算到期爆炸。
func _blast_phase_order(tree: SceneTree) -> void:
	cleanup()
	var parent := world(tree)
	var local := player(parent, 1)
	var type_id: int = WeaponRegistry.all_ids()[0]
	var profile := WeaponRegistry.projectile_profile(type_id)
	var bullet: BulletBase = profile["scene"].instantiate()
	parent.add_child(bullet)
	bullet.entity_id = 200
	bullet.type_id = type_id
	bullet.finished = false
	var entry := ProjectileEntry.new()
	entry.set_bullet(bullet)
	entry.birth_tick = 100
	entry.tick = 99
	entry.active = true
	var sim := OrderSim.new()
	sim.projectiles = {200: entry}
	sim.blasts = {100: {"id": 100, "tick": 97, "confirmed": true,
			"type_id": type_id, "pos": Vector2.ZERO}}
	sim.hits = {}
	sim.ended = {}
	sim.outcomes = {}
	sim._keep = 4
	sim._local_id = local.get_instance_id()
	sim.step(100, [local], TileDefs.terrain, false)
	expect(sim.order == [["p", 200], ["b", 100]],
			"all projectiles advance before any due blast regardless of ID order")
	bullet.free()
	cleanup()

func _projectile_order(tree: SceneTree) -> void:
	var parent := world(tree)
	var shooter := player(parent, 1)
	var victim := player(parent, 2)
	shooter.position = Vector2(64, 80)
	victim.position = Vector2(256, 80)
	victim.apply_collision_pose()
	collider(victim, CollisionWorld.LAYER_TEAM_A)
	var grenade_type := 0
	for type_id in WeaponRegistry.all_ids():
		if WeaponRegistry.scene_of(type_id) == "res://scenes/weapons/grenade_launcher.tscn": grenade_type = type_id
	var grenade_profile := WeaponRegistry.projectile_profile(grenade_type)
	victim.sim_hp = int(grenade_profile["explosion_damage"])
	var initial := victim.capture_state()
	var normal := {"type_id": WeaponRegistry.all_ids()[0], "pos": Vector2(180, 80), "vel": Vector2(3000, 0),
			"traveled": 0.0, "fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	var grenade := normal.merged({"type_id": grenade_type, "pos": Vector2(256, 120), "vel": Vector2(10, 0),
			"fuse_active": true, "fuse_duration": 0.001}, true)
	var id := (shooter.role << 48) | (1 << 8)
	var combat := CombatPrediction.new()
	combat.bind(victim)
	combat.actors = {shooter.role: shooter, victim.role: victim}
	for i in 2: combat.seed_projectile(id + i * 256, [normal, grenade][i], 99, shooter, false)
	combat.step(100, [shooter, victim], false)
	var predicted_hp := victim.sim_hp
	var predicted_knock := victim.motion_knock_velocity
	var normal_profile := WeaponRegistry.projectile_profile(normal["type_id"])
	for i in 3:
		combat.step(101 + i, [shooter, victim], false)
	predicted_hp = victim.sim_hp
	predicted_knock = victim.motion_knock_velocity
	expect(predicted_hp == initial[HP] - int(normal_profile["damage"]) - int(grenade_profile["explosion_damage"]),
			"the explosion settles three ticks after its trigger")
	combat.clear()
	victim.restore_state(initial)
	combat.seed_projectile(id, normal, 99, shooter, false)
	combat.projectiles[id].bullet.position = Vector2(60, 80)
	combat.projectiles[id].bullet.max_range = 1.0
	combat.step(100, [shooter, victim], false)
	expect(victim.sim_hp == initial[HP], "range-ended projectile does not predict a contact the authority will skip")
	combat.clear()
	victim.restore_state(initial)
	var authority := AuthorityWorld.new()
	parent.add_child(authority)
	authority.set_physics_process(false)
	authority.players = {shooter.role: shooter, victim.role: victim}
	authority.terrain = TileDefs.terrain
	authority._snap_tick = 100
	for actor in [shooter, victim]:
		actor.authority_world = authority
		authority._stats[actor.role] = {"dealt": 0, "taken": 0, "self_damage": 0, "team_damage": 0, "hits": {}}
	for i in 2:
		var state: Dictionary = [normal, grenade][i]
		var profile := WeaponRegistry.projectile_profile(state["type_id"])
		var bullet: BulletBase = profile["scene"].instantiate()
		bullet.setup(state["vel"].normalized(), state["vel"].length(), profile["range"], profile["size"], profile["color"], null)
		bullet.entity_id = id + i * 256
		bullet.type_id = state["type_id"]
		bullet.gravity_factor = profile["gravity"]
		bullet.hit_damage = profile["damage"]
		bullet.hit_impact = profile["impact"]
		bullet.shooter = shooter
		bullet.authority_world = authority
		authority.add_projectile(bullet)
		bullet.set_physics_process(false)
		bullet.bind_actor_layers(shooter)
		bullet.restore_motion(state)
	authority._step_projectiles(ActorStep.DT)
	for i in 3:
		authority._snap_tick += 1
		authority.settle_blasts()
	expect(victim.sim_hp == predicted_hp and victim.motion_knock_velocity == predicted_knock,
			"authority and prediction agree when direct contact and a delayed explosion overlap")
	cleanup()

# 倒地角色仍会被弹丸接触，但服务端已忽略伤害；预测端只消耗弹丸，不能继续扣血。
func _downed_projectile(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var victim := player(parent, 1)
	var shooter := player(parent, 2)
	victim.team = 2
	shooter.team = 1
	victim.gravity = 0.0
	shooter.gravity = 0.0
	victim.global_position = Vector2(620, 544)
	shooter.global_position = Vector2(300, 544)
	victim.apply_collision_pose()
	shooter.apply_collision_pose()
	victim.force_down()
	collider(victim, CollisionWorld.team_layer(victim.team))
	var combat := CombatPrediction.new()
	combat.bind(victim)
	combat.actors = {victim.role: victim, shooter.role: shooter}
	var type_id: int = WeaponRegistry.all_ids()[0]
	var id: int = (shooter.role << 48) | (1 << 8)
	var state := {"type_id": type_id, "pos": Vector2(560, 544), "vel": Vector2(3000, 0),
			"traveled": 0.0, "fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0,
			"direct_hit": false}
	combat.seed_projectile(id, state, 99, shooter, true)
	var before := victim.sim_hp
	combat.step(100, [shooter, victim], false)
	expect(victim.sim_hp == before, "a downed target does not take predicted projectile damage")
	expect(combat.projectiles.has(id) and combat.projectiles[id].bullet.finished,
			"a downed target still consumes the predicted projectile")
	combat.clear()
	cleanup()

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
	weapon._spawn_projectiles({"serial": 1, "dir": Vector2.DOWN, "pos": Vector2(160, 150)})
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
	for i in 3:
		authority._snap_tick += 1
		authority.settle_blasts()
	var explosions := events.filter(func(event: Array) -> bool: return event[0] == NetEvent.Kind.EXPLOSION)
	expect(fused and bullet.exploded and bullet.is_queued_for_deletion(), "Beta grenade bounces, starts its fuse and detonates")
	expect(explosions.size() == 1 and explosions[0][1]["id"] == bullet.entity_id,
			"authority broadcasts the grenade explosion once")
	expect(actor.hp < hp_before and TileDefs.terrain.capture_cell(Vector2i(2, 3)) != terrain_before,
			"grenade explosion damages players and terrain")
	actor.authority_world = null
	cleanup()

# 动态玩家阻挡：另一名角色的真实体挡住移动，其层清零后同一方向继续前进。
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
	mover.apply_collision_pose()
	blocker.apply_collision_pose()
	collider(blocker, CollisionWorld.LAYER_TEAM_A)
	var start := mover.global_position.x
	var record := InputBuffer.neutral().merged({"ax": 1.0, "held": 1}, true)
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

# 连续扫掠：高速弹丸不会跳过路径上的角色代理。
func _swept_hit(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var shooter := player(parent, 1)
	shooter.global_position = Vector2(200, 512)
	var victim := player(parent, 2)
	# 目标贴左边接缝：跨接缝的一段位移必须连到对侧镜像上，命中后位置回到规范区间。
	victim.global_position = Vector2(80, 512)
	victim.apply_collision_pose()
	collider(victim, CollisionWorld.LAYER_TEAM_A)
	var bullet: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	bullet.setup(Vector2.RIGHT, 30000.0, 4000.0, 1.0, Color.WHITE, shooter)
	bullet.position = Vector2(1000, 512)
	parent.add_child(bullet)
	bullet.set_physics_process(false)
	bullet.shooter = shooter
	bullet.bind_actor_layers(shooter)
	expect(bullet.advance_physics(ActorStep.DT) == BulletBody.AdvanceResult.ACTOR_HIT,
			"a fast projectile is swept instead of sampling only its end position")
	expect(bullet.impact_role == victim.role, "the swept hit reports the proxy's role")
	expect(bullet.global_position.x >= 0.0 and bullet.global_position.x < GameParameters.MAP_WIDTH,
			"an actor hit across the seam also returns to canonical coordinates")

# 榴弹直接撞上角色代理：必须报出 impact_role，直击与爆炸各结算一次。
func _grenade_direct(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var shooter := player(parent, 1)
	var victim := player(parent, 2)
	shooter.global_position = Vector2(200, 512)
	victim.global_position = Vector2(600, 512)
	victim.apply_collision_pose()
	collider(victim, CollisionWorld.LAYER_TEAM_A)
	var grenade_type := 0
	for type_id in WeaponRegistry.all_ids():
		if WeaponRegistry.scene_of(type_id) == "res://scenes/weapons/grenade_launcher.tscn": grenade_type = type_id
	var profile := WeaponRegistry.projectile_profile(grenade_type)
	var authority := AuthorityWorld.new()
	parent.add_child(authority)
	authority.set_physics_process(false)
	authority.players = {shooter.role: shooter, victim.role: victim}
	authority.terrain = TileDefs.terrain
	authority._snap_tick = 100
	for actor: Player in [shooter, victim]:
		actor.authority_world = authority
		authority._stats[actor.role] = {"dealt": 0, "taken": 0, "self_damage": 0, "team_damage": 0, "hits": {}}
	var events: Array = []
	authority.event.connect(func(kind: int, data: Variant, _except: int) -> void: events.append([kind, data]))
	var bullet: BulletBase = profile["scene"].instantiate()
	bullet.setup(Vector2.RIGHT, 6000.0, profile["range"], profile["size"], profile["color"], shooter)
	bullet.entity_id = (shooter.role << 48) | (1 << 8)
	bullet.type_id = grenade_type
	bullet.gravity_factor = 0.0
	bullet.hit_damage = profile["damage"]
	bullet.hit_impact = profile["impact"]
	bullet.shooter = shooter
	bullet.authority_world = authority
	bullet.position = Vector2(500, 512)
	authority.add_projectile(bullet)
	bullet.set_physics_process(false)
	bullet.bind_actor_layers(shooter)
	var hp_before := victim.sim_hp
	authority._step_projectiles(ActorStep.DT)
	expect(bullet.impact_role == victim.role, "a grenade that hits a player proxy reports the victim role")
	expect(bullet.direct_hit, "the authority resolves the grenade direct hit")
	expect(victim.sim_hp == hp_before - bullet.direct_hit_damage, "the direct hit applies its damage once")
	expect(bullet.fuse_started and bullet._fuse_duration == bullet.hit_fuse_time,
			"player contact starts the short fuse instead of the wall fuse")
	var settled := victim.sim_hp
	authority._snap_tick += 1
	authority._step_projectiles(ActorStep.DT)
	expect(victim.sim_hp == settled, "bouncing off the same player does not repeat the direct hit")
	for i in 20:
		authority._snap_tick += 1
		authority._step_projectiles(ActorStep.DT)
		if bullet.is_queued_for_deletion(): break
	var explosions := events.filter(func(event: Array) -> bool: return event[0] == NetEvent.Kind.EXPLOSION)
	expect(explosions.size() == 1, "the fuse detonates the grenade exactly once")
	cleanup()

# 光束走廊内的前后目标、起点已重叠的目标都要命中；预测端与采集端给出同一 role 与 point。
func _beam_targets(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var mask := CollisionWorld.LAYER_TEAM_A
	var local := player(parent, 1)
	var near := player(parent, 2)
	var far := player(parent, 3)
	var overlapping := player(parent, 4)
	var positions := {local: Vector2(520, 512), near: Vector2(700, 512),
			far: Vector2(880, 512), overlapping: Vector2(420, 512)}
	for actor: Player in positions:
		actor.global_position = positions[actor]
		actor.apply_collision_pose()
		collider(actor, mask)
	var world := CollisionWorld.acquire(local)
	var corridor := 18.0
	var points := PackedVector2Array([Vector2(400, 512), Vector2(960, 512)])
	var roles := {}
	for contact: Dictionary in world.beam_contacts(points, corridor, mask):
		roles[int(contact["role"])] = contact["point"]
	expect(roles.has(overlapping.role), "a target already overlapping the beam start is hit")
	expect(roles.has(local.role) and roles.has(near.role) and roles.has(far.role),
			"one corridor query reports every actor in front and behind")
	expect((roles[far.role] as Vector2).x > (roles[near.role] as Vector2).x,
			"each contact point comes from its own target geometry")
	# 贴接缝的角色有物理镜像，但只应报告一次。
	cleanup()
	parent = world_with_walls(tree, 16, 16, {})
	var edge := player(parent, 5)
	edge.global_position = Vector2(10, 700)
	edge.apply_collision_pose()
	collider(edge, mask)
	world = CollisionWorld.acquire(edge)
	var crossing := world.beam_contacts(
			PackedVector2Array([Vector2(1000, 700), Vector2(1040, 700)]), corridor, mask)
	var copies := 0
	for contact: Dictionary in crossing:
		if int(contact["role"]) == edge.role: copies += 1
	expect(copies == 1, "a mirrored actor is reported once instead of once per seam copy")
	# 预测端消费同一份采集结果。
	var shooter := player(parent, 6)
	shooter.global_position = Vector2(300, 700)
	shooter.apply_collision_pose()
	edge.global_position = Vector2(500, 700)
	edge.apply_collision_pose()
	var pts := PackedVector2Array([Vector2(320, 700), Vector2(700, 700)])
	var expected := Vector2.INF
	for contact: Dictionary in world.beam_contacts(pts, corridor, mask):
		if int(contact["role"]) == edge.role: expected = contact["point"]
	expect(expected != Vector2.INF, "the shared collector finds the local actor")
	var combat := CombatPrediction.new()
	combat.bind(edge)
	var id: int = (shooter.role << 48) | (1 << 8)
	combat.beams[id] = {"id": id, "tick": 100, "type_id": WeaponRegistry.all_ids()[0],
		"shooter_role": shooter.role, "pts": pts, "half_width": corridor / LaserWeaponBase.HIT_MULT}
	combat.step_beams(100, shooter.role, [shooter, edge])
	var record: Dictionary = combat.simulator.outcomes.get(100, {}).get(["beam", id], {})
	var predicted: Dictionary = record.get("contacts", {})
	expect(predicted.has(edge.role), "prediction reports the beam contact for its own role")
	expect(predicted.get(edge.role, Vector2.ZERO) == expected,
			"prediction and direct collection agree on the contact point")
	combat.clear()
	# 跨接缝：接触点必须落在连续光束坐标上。规范中心 (70,700) 沿光束是 x=1094。
	cleanup()
	parent = world_with_walls(tree, 16, 16, {})
	var seam_actor := player(parent, 7)
	seam_actor.global_position = Vector2(70, 700)
	seam_actor.apply_collision_pose()
	collider(seam_actor, mask)
	world = CollisionWorld.acquire(seam_actor)
	var seam_pts := PackedVector2Array([Vector2(1000, 700), Vector2(1120, 700)])
	var seam_points: Array = []
	for contact: Dictionary in world.beam_contacts(seam_pts, corridor, mask):
		if int(contact["role"]) == seam_actor.role: seam_points.append(contact["point"])
	expect(seam_points.size() == 1, "a cross-seam target is reported exactly once")
	var seam_point: Vector2 = seam_points[0] if not seam_points.is_empty() else Vector2.ZERO
	expect(seam_points.size() == 1 and absf(seam_point.x - 1094.0) < 32.0,
			"the contact point stays on the continuous beam instead of the canonical origin")
	# 预测端对同一束给出的接触点必须与直接采集一致。
	shooter = player(parent, 8)
	shooter.global_position = Vector2(300, 700)
	shooter.apply_collision_pose()
	var seam_combat := CombatPrediction.new()
	seam_combat.bind(seam_actor)
	var seam_id: int = (shooter.role << 48) | (2 << 8)
	seam_combat.beams[seam_id] = {"id": seam_id, "tick": 100, "type_id": WeaponRegistry.all_ids()[0],
		"shooter_role": shooter.role, "pts": seam_pts, "half_width": corridor / LaserWeaponBase.HIT_MULT}
	seam_combat.step_beams(100, shooter.role, [shooter, seam_actor])
	var seam_record: Dictionary = seam_combat.simulator.outcomes.get(100, {}).get(["beam", seam_id], {})
	expect(seam_record.get("contacts", {}).get(seam_actor.role, Vector2.ZERO) == seam_point,
			"prediction and direct collection agree across the seam")
	seam_combat.clear()
	cleanup()

# 联机权威爆炸：目标集合来自玩家表，按环面中心距离结算，不需要注册角色代理。
func _authority_blast(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var authority := AuthorityWorld.new()
	parent.add_child(authority)
	authority.set_physics_process(false)
	authority.terrain = TileDefs.terrain
	authority._snap_tick = 100
	var near := player(parent, 1)
	near.global_position = Vector2(1010, 500)
	var edge := player(parent, 2)
	edge.global_position = Vector2(20, 500)
	var far := player(parent, 3)
	far.global_position = Vector2(120, 500)
	var downed := player(parent, 4)
	downed.global_position = Vector2(1005, 500)
	var actors: Array = [near, edge, far, downed]
	for actor: Player in actors:
		actor.apply_collision_pose()
		actor.authority_world = authority
		authority.players[actor.role] = actor
		authority._stats[actor.role] = {"dealt": 0, "taken": 0, "self_damage": 0,
				"team_damage": 0, "hits": {}}
	downed.combat.set_downed_by_rewind(true)
	var before := {}
	for actor: Player in actors: before[actor.role] = actor.hp
	# 没有任何角色代理注册：权威枚举只读玩家表。
	Explosion.apply_aoe(Vector2(1000, 500), 64.0, 40, 100.0, near, 0, authority)
	expect(near.hp < before[near.role], "the blast centre damages the player standing in it")
	expect(far.hp == before[far.role], "a player outside the radius is untouched")
	expect(edge.hp < before[edge.role], "the toroidal distance reaches a player across the seam")
	expect(downed.hp == before[downed.role], "a downed player is skipped by the authority blast")
	expect(authority.players.size() == 4 and near.hp == before[near.role] - (before[near.role] - near.hp),
			"authority enumerates the player table itself")
	cleanup()

# 晚到事件统一重放世界；已发布检查点不作增量修补。
func _late_projectile(tree: SceneTree) -> void:
	for contact in [false, true]:
		var timely := _projectile_arrival(tree, contact, false)
		var late := _projectile_arrival(tree, contact, true)
		expect(late == timely, "late projectile world replay equals timely arrival, contact=%s" % contact)
	cleanup()

func _projectile_arrival(tree: SceneTree, contact: bool, late: bool) -> Array:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var victim := player(parent, 1)
	victim.gravity = 0.0
	victim.global_position = Vector2(512, 400)
	victim.apply_collision_pose()
	collider(victim, CollisionWorld.LAYER_TEAM_A)
	var shooter := player(parent, 2)
	shooter.gravity = 0.0
	shooter.global_position = Vector2(200, 400)
	shooter.apply_collision_pose()
	var rollback := PredictionRollback.new()
	rollback.bind(victim)
	rollback.terrain = TileDefs.terrain
	rollback.reset(1, 0, 100, 0)
	rollback._clock = 100.0
	rollback._input.seed(InputBuffer.neutral(), 100)
	rollback._remember_state()
	var id: int = (shooter.role << 48) | (1 << 8)
	var state := {"type_id": WeaponRegistry.all_ids()[0],
			"pos": Vector2(420, 398) if contact else Vector2(300, 200),
			"vel": Vector2(3000, 0) if contact else Vector2(600, 0),
			"traveled": 0.0, "fuse_active": false,
			"fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	for at in range(101, 109):
		if at == 104 and not late:
			rollback.combat_prediction.seed_projectile(id, state, 103, shooter)
		rollback._clock = at
		rollback._step(rollback._input.take(at), true)
	if late:
		var old := rollback._states[104]
		var changed := rollback.combat_prediction.seed_projectile(id, state, 103, shooter)
		expect(changed.x == 104 and rollback.can_replay_from(104), "late birth invalidates its world suffix")
		rollback.replay_from(104)
		expect(not old.projectiles._values.has(id), "world replay replaces frames without mutating the published checkpoint")
		expect(rollback.world.tick == 108 and rollback.replay_ticks == 5, "late arrival replays each world tick once")
	var result: Array = [victim.capture_state(), _projectiles(rollback.combat_prediction)]
	if contact:
		expect(victim.sim_hp < victim.sim_max_hp, "historical contact damages the local actor at the actual tick")
	rollback.combat_prediction.clear()
	return result

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
		rollback.capture(source, Vector2.RIGHT, 0)
		rollback.advance(ActorStep.DT)
		if tick == 104: authority_projectiles = _projectiles(rollback.combat_prediction)
	var original := actor.capture_state()
	var original_cursor := rollback._input.capture_cursor()
	var original_projectiles := _projectiles(rollback.combat_prediction)
	var saved: PredictionFrame = rollback._states[104]
	expect(not authority_projectiles.is_empty(), "replay fixture has a live projectile")
	var snapshot: ProjectileSnapshot = saved.projectiles
	expect(snapshot.matches(authority_projectiles), "later simulation cannot mutate an earlier projectile frame")
	var altered := authority_projectiles.duplicate(true)
	for id in altered: altered[id]["fuse_elapsed"] += 0.25
	expect(not snapshot.matches(altered) and snapshot.matches(authority_projectiles),
			"projectile comparison detects changed timers without changing stored history")
	var buffer := InputBuffer.new()
	buffer.restore_cursor(saved.cursor)
	var own := {"epoch": 1, "ack": buffer.ack, "action_ack": buffer.action_ack,
			"timing_seq": 0, "lead": 2, "input": buffer._last, "rewind": false,
			"state": saved.player}
	var frame := {"tick": 104, "map_revision": TileDefs.terrain.revision, "own": own,
			"time": {}, "world": {"players": {actor.role: preload("res://tests/prediction_case.gd").wire_state(saved.player)}, "projectiles": authority_projectiles}}
	expect(rollback.reusable_tick(frame) == 108, "matching authority retains the full prediction suffix")
	rollback.reconcile(frame, 0, true)
	expect(rollback.replay_ticks == 0 and actor.capture_state() == original, "reuse executes no unnecessary replay")
	expect(rollback._input.capture_cursor() == original_cursor, "reuse keeps the input cursor at the predicted future tick")
	expect(rollback.can_replay_from(105), "short suffix has a usable checkpoint")
	rollback.replay_from(105)
	expect(rollback.replay_ticks == 4 and actor.capture_state() == original, "checkpoint suffix replay equals original simulation")
	expect(_projectiles(rollback.combat_prediction) == original_projectiles, "checkpoint restores and replays projectile motion exactly")
	rollback.reconcile(frame, 0, false)
	expect(rollback.replay_ticks == 4 and actor.capture_state() == original, "full authority restore equals optimized replay")
	expect(_projectiles(rollback.combat_prediction) == original_projectiles, "authority restore and projectile history produce the same future")
	rollback.combat_prediction.clear()

func _projectiles(combat: CombatPrediction) -> Dictionary:
	var states := {}
	for id in combat.projectiles:
		var entry: ProjectileEntry = combat.projectiles[id]
		if entry.active and not entry.bullet.finished: states[id] = entry.bullet.motion_state()
	return states

func _confirmed_lifecycle(actor: Player, initial: Array) -> void:
	actor.restore_state(initial)

	var combat := CombatPrediction.new()
	combat.bind(actor)
	var id: int = (2 << 48) | 1
	combat.hits[id] = [{"tick": 200, "source": 2, "shooter": 2, "victim": actor.role,
			"hp": initial[HP] - 1, "knock": Vector2.ZERO, "facing": 1, "pos": actor.position}]
	combat.step(200, [actor], false)
	expect(actor.sim_hp == initial[HP] - 1, "confirmed explosion applies after its projectile is gone")
	combat.acknowledge(200)
	for serial in [2, 1]:
		combat.hits[(2 << 48) | serial] = [{"tick": 201, "source": 0, "shooter": 2, "victim": actor.role,
				"hp": initial[HP] - serial - 1, "knock": Vector2.ZERO, "facing": 1, "pos": actor.position}]
	combat.step(201, [actor], false)
	expect(actor.sim_hp == initial[HP] - 3, "late direct hits retain stable attack order without live projectiles")
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
	var path_history := BetaHistory.new(world)
	var motion := actor.capture_state()
	path_history.frames[actor.role] = [{"tick": 0, "player": motion.duplicate()}, {"tick": 3, "player": motion.duplicate()}]
	path_history.cursors[actor.role] = 0.0
	expect(path_history.collision_path(actor.role).is_empty(), "a stationary rewind path omits its redundant first knot")
	path_history.frames[actor.role][0]["player"][PlayerStateSchema.slot("squat")] = not actor.is_squat
	var path := path_history.collision_path(actor.role)
	expect(path.size() == 1 and path[0][0] == world._snap_tick + 1 and bool(path[0][2] & 1) != actor.is_squat,
			"a collision pose change keeps its first knot even at the same position")
	expect(actor.capture_state() == motion and path_history.cursors[actor.role] == 0.0,
			"building a future path does not advance the actor or rewind cursor")
	history.finish(actor.role)
	expect(history.frames[actor.role].size() == 2 and world.epoch_changes == 1, "ending Beta rewind trims the future and changes control epoch once")
	expect(world.events.back()[1]["projectiles"].keys() == [actor.role << 48], "Beta rewind broadcast contains the shooter's current projectiles")

# 团队规则数值表：击杀目标、少人方补贴、血量与伤害倍率。
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

# 权威端团队血量与伤害倍率；预测端使用同一倍率，权威 HIT 不重复乘。
func _team_health(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var authority := AuthorityWorld.new()
	parent.add_child(authority)
	authority.set_physics_process(false)
	authority.terrain = TileDefs.terrain
	authority.rules.mode = PvpSession.MODE_TEAM
	authority.rules.teams = {1: 1, 2: 1, 3: 1, 4: 1, 5: 2}
	authority.rules.team_counts = TeamRules.team_counts(authority.rules.teams)
	for role: int in [1, 2, 3, 4, 5]:
		var actor := player(parent, role)
		actor.team = int(authority.rules.teams[role])
		actor.global_position = Vector2(200 + role * 40, 300)
		actor.apply_collision_pose()
		authority.players[role] = actor
		authority._stats[role] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
				"team_damage": 0, "self_damage": 0, "team_kills": 0, "rounds": 1, "left": false, "hits": {}}
	authority._apply_team_hp()
	expect(authority.players[5].sim_max_hp == 65 and authority.players[1].sim_max_hp == 50,
			"authority applies the 4v1 max HP split")
	var victim: Player = authority.players[1]
	var before := victim.sim_hp
	authority.damage(5, 1, victim.global_position, 10)
	expect(victim.sim_hp == before - 11, "the disadvantaged attacker deals 10 * 1.1")
	var friendly: Player = authority.players[2]
	before = friendly.sim_hp
	authority.damage(1, 2, friendly.global_position, 10)
	expect(friendly.sim_hp == before - 10, "friendly fire is not boosted")
	before = victim.sim_hp
	authority.damage(1, 1, victim.global_position, 10)
	expect(victim.sim_hp == before - 10, "self damage is not boosted")
	var other: Player = authority.players[5]
	var other_before := other.sim_hp
	authority.damage(1, 5, other.global_position, 10)
	expect(other.sim_hp == other_before - 10, "the advantaged team keeps x1.0")
	other_before = other.sim_hp
	authority.damage(0, 5, other.global_position, 10)
	expect(other.sim_hp == other_before - 10, "unowned damage keeps x1.0")
	var combat := CombatSimulator.new()
	combat.configure(victim, {"projectiles": {}, "blasts": {}, "beams": {}, "hits": {},
			"ended": {}, "outcomes": {}}, WeaponRegistry.combat_profiles(),
			{"keep": 4, "dt": ActorStep.DT, "inner_fraction": Explosion.INNER_FRACTION,
			"blocked_fraction": Explosion.BLOCKED_FRACTION, "beam_hit_mult": LaserWeaponBase.HIT_MULT})
	combat.set_team_counts(authority.rules.team_counts)
	combat.players = [authority.players[5], victim]
	var hit_id: int = (5 << 48) | 1
	before = victim.sim_hp
	combat._apply_hit(hit_id, 0, victim, victim.global_position, 0.0, 10)
	expect(victim.sim_hp == before - 11, "prediction uses the same team damage factor")
	victim.sim_hp = 30
	combat._tick = 7
	combat.hits[hit_id] = [{"tick": 7, "source": 0, "shooter": 5, "victim": victim.role,
			"hp": 20, "knock": Vector2.ZERO, "facing": 1, "pos": victim.global_position}]
	combat._apply_hit(hit_id, 0, victim, victim.global_position, 0.0, 10)
	expect(victim.sim_hp == 20, "a confirmed authoritative HP delta is applied once without the multiplier")
	cleanup()

# 爆炸视觉 tick 只排队；伤害、击退与地形破坏在 t+3 结算一次。
func _blast_delay(tree: SceneTree) -> void:
	cleanup()
	var texture := wall_texture()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(12, 8): texture})
	var authority := AuthorityWorld.new()
	parent.add_child(authority)
	authority.set_physics_process(false)
	authority.terrain = TileDefs.terrain
	authority._snap_tick = 100
	var victim := player(parent, 1)
	victim.global_position = Vector2(650, 544)
	victim.apply_collision_pose()
	authority.players = {1: victim}
	authority._stats = {1: {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
			"team_damage": 0, "self_damage": 0, "team_kills": 0, "rounds": 1, "left": false, "hits": {}}}
	var before_hp := victim.sim_hp
	var before_cell := TileDefs.terrain.capture_cell(Vector2i(12, 8))
	authority.submit_blast(77, Vector2(700, 544), 96.0, 40, 100.0, 0)
	expect(authority._pending_blasts.size() == 1, "an explosion is queued for later settlement")
	authority.settle_blasts()
	expect(victim.sim_hp == before_hp and TileDefs.terrain.capture_cell(Vector2i(12, 8)) == before_cell,
			"the explosion does not damage on its trigger tick")
	for tick: int in [101, 102]:
		authority._snap_tick = tick
		authority.settle_blasts()
	expect(victim.sim_hp == before_hp, "explosion damage waits for t+3")
	authority._snap_tick = 103
	authority.settle_blasts()
	expect(victim.sim_hp < before_hp and TileDefs.terrain.capture_cell(Vector2i(12, 8)) != before_cell,
			"damage and terrain destruction settle together at t+3")
	expect(authority._pending_blasts.is_empty(), "a settled explosion is removed")
	authority.submit_blast(88, Vector2(700, 544), 96.0, 40, 0.0, 0)
	expect(authority._pending_blasts.size() == 1, "a pending explosion is queued once")
	authority.clear_pending_blasts()
	expect(authority._pending_blasts.is_empty(), "round reset clears unsettled explosions")
	var grenade_type := 0
	for type_id in WeaponRegistry.all_ids():
		if WeaponRegistry.scene_of(type_id) == "res://scenes/weapons/grenade_launcher.tscn":
			grenade_type = type_id
	var local := player(parent, 2)
	local.global_position = Vector2(650, 544)
	local.apply_collision_pose()
	var combat := CombatPrediction.new()
	combat.bind(local)
	combat.blasts[55] = {"id": 55, "type_id": grenade_type, "pos": Vector2(700, 544),
			"tick": 100, "confirmed": true}
	var predicted_before := local.sim_hp
	for tick: int in [100, 101, 102]:
		combat.step(tick, [local], false)
	expect(local.sim_hp == predicted_before, "predicted blast damage waits for its due tick")
	combat.step(103, [local], false)
	expect(local.sim_hp < predicted_before, "predicted blast damage settles at tick+3")
	# 回滚到 due tick 之前：已结算的预测爆炸必须重新允许结算，否则重放会丢掉伤害。
	local.sim_hp = local.sim_max_hp
	combat.prepare(101, {})
	expect(not bool(combat.blasts[55].get("settled", false)), "rolling back before the due tick re-arms the blast")
	for tick: int in [101, 102]:
		combat.step(tick, [local], false)
	combat.step(103, [local], false)
	expect(local.sim_hp < local.sim_max_hp, "the replayed blast settles again at tick+3")
	# 迟到的权威命中：事件 tick 仍为 103，本地已先按预测结算；回滚到 102 后重放 103 只应用权威 HP。
	local.sim_hp = local.sim_max_hp
	combat.blasts.erase(55)
	combat.blasts[56] = {"id": 56, "type_id": grenade_type, "pos": Vector2(700, 544),
			"tick": 100, "confirmed": true}
	for tick: int in [100, 101, 102, 103]:
		combat.step(tick, [local], false)
	expect(local.sim_hp < local.sim_max_hp, "the prediction settles at 103 before the authority arrives")
	combat.tick = 105
	var late := {"id": 56, "tick": 103, "source": 2, "shooter": 1, "victim": local.role,
			"hp": 30, "knock": Vector2.ZERO, "facing": 1, "pos": local.global_position}
	var span := combat.confirm_hit(late)
	expect(span == Vector2i(103, 103), "the late hit invalidates the settled 103 outcome")
	local.sim_hp = local.sim_max_hp
	combat.restore_checkpoint(102, ProjectileSnapshot.new())
	combat.step(103, [local], false)
	expect(local.sim_hp == 30, "replaying 103 applies the authoritative HP instead of predicting again")
	combat.step(104, [local], false)
	expect(local.sim_hp == 30, "the authoritative explosion HP is applied once")
	# 未来 tick 的权威 HIT 不能取消更早 tick 的预测；它在自己的 tick 才应用。
	combat.clear()
	local.sim_hp = local.sim_max_hp
	combat.blasts[57] = {"id": 57, "type_id": grenade_type, "pos": Vector2(700, 544),
			"tick": 100, "confirmed": true}
	combat.hits[57] = [{"tick": 104, "source": 2, "shooter": 1, "victim": local.role,
			"hp": 30, "knock": Vector2.ZERO, "facing": 1, "pos": local.global_position}]
	for tick: int in [100, 101, 102, 103]:
		combat.step(tick, [local], false)
	expect(local.sim_hp < local.sim_max_hp,
			"a future authoritative hit does not suppress the earlier predicted damage")
	combat.step(104, [local], false)
	expect(local.sim_hp == 30, "the authoritative hit applies at its own tick")
	combat.clear()
	cleanup()

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
		mover.apply_collision_pose()
		var record := InputBuffer.neutral().merged({"ax": 1.0}, true)
		ActorStep.step(mover, InputBuffer.neutral())
		var farthest := mover.global_position.x
		for i in 60:
			ActorStep.step(mover, record)
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
	blocked.apply_collision_pose()
	var forward := InputBuffer.neutral().merged({"ax": 1.0}, true)
	for i in 40:
		ActorStep.step(blocked, forward)
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
	ceiling_mover.apply_collision_pose()
	for i in 40:
		ActorStep.step(ceiling_mover, forward)
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
	runner.apply_collision_pose()
	var blocker := player(dynamic, 2)
	blocker.gravity = 0.0
	# 只挡 16px 抬高后的路径，不挡地面水平路径。
	blocker.global_position = Vector2(500, 213)
	blocker.apply_collision_pose()
	collider(blocker, CollisionWorld.LAYER_TEAM_A)
	for i in 40:
		ActorStep.step(runner, forward)
	expect(absf(runner.global_position.y - (384 - 57)) < 2.0,
			"a dynamic actor blocking the raised path prevents the step-up")
	# 被拒绝的候选不能移动角色：候选是只读检测，回退到水平阻挡。
	runner.move_by_internal(Vector2(10.0, 0.0))
	expect(absf(runner.global_position.y - (384 - 57)) < 2.0,
			"a rejected step candidate does not move the actor")
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
	var parent := world(tree)
	var authority := AuthorityWorld.new()
	parent.add_child(authority)
	authority.setup(PvpSession.MODE_TEAM, "res://maps/demo.cyrm", [1, 2, 3], {1: 1, 2: 1, 3: 2},
			{"match_time": 300})
	authority.set_physics_process(false)
	expect(authority._round_state == NetEvent.RoundState.WAITING and is_zero_approx(authority._round_timer),
			"setup starts in WAITING with a zero timer")
	expect(authority.players[3].sim_max_hp == 55 and authority.players[1].sim_max_hp == 50,
			"team max HP follows the fixed roster")
	expect(int(authority._scores.get(2, 0)) == 1 and int(authority._scores.get(1, 0)) == 0,
			"the smaller team starts with its score bonus")
	expect(authority.rules.team_counts == {1: 2, 2: 1}, "the roster counts are frozen at setup")
	expect(authority.rules.spawns.size() == 3 and authority.rules.swapped.size() == 3,
			"both side plans assign every role")
	expect(authority.rules.spawns[1] == Vector2i(22, 30), "team A uses its first side point")
	authority._round_state = NetEvent.RoundState.ROUND_OVER
	authority._round_timer = 0.0
	authority._rounds_won = {1: 1}
	authority.rules.tick(authority, 0.016)
	expect(authority._round_state == NetEvent.RoundState.WAITING,
			"the next round returns to WAITING instead of counting down")
	expect(authority._round_num == 2 and authority.rules.spawns[1] == Vector2i(79, 30),
			"side swap follows the round number")
	expect(int(authority._scores.get(2, 0)) == 1 and int(authority._scores.get(1, 0)) == 0,
			"the next round reapplies the initial score bonus")
	cleanup()
# 团队复活：只取当前阵营地图侧、避开存活角色占用点，并最大化与敌人的最小环面距离。
func _team_respawn(tree: SceneTree) -> void:
	cleanup()
	var parent := world_from_solid(tree, 125, 75, func(sx: int, sy: int) -> bool: return sy >= 74 * 4)
	var saved := MazeGenerator.current_spawns
	var info := MapFormat.load_map_info("res://maps/demo.cyrm")
	MazeGenerator.current_spawns = info["spawns"]
	var respawn: Dictionary = MazeGenerator.current_spawns.get("respawn", {})
	var rules := MatchRules.new()
	rules.mode = PvpSession.MODE_TEAM
	rules.teams = {1: 1, 2: 1, 3: 2}
	var fake := FakeWorld.new()
	fake._round_num = 1
	parent.add_child(fake)
	var ally := player(parent, 1)
	ally.team = 1
	ally.global_position = Vector2(respawn[1][0]) * 64 + Vector2(32, 32)
	var enemy := player(parent, 3)
	enemy.team = 2
	enemy.global_position = Vector2(respawn[1][1]) * 64 + Vector2(32, 32)
	fake.players = {1: ally, 3: enemy}
	var point: Vector2i = rules.spawn_for(fake, 2)
	expect(respawn[1].has(point), "team respawn stays on the team's current map side")
	expect(point != respawn[1][0] and point != respawn[1][1],
			"occupied respawn points are excluded")
	# 全部本方点被占用：返回无点，保持倒地，由 MatchRules.tick 在下一 tick 重试。
	for index in respawn[1].size():
		var mate := player(parent, 10 + index)
		mate.team = 1
		mate.global_position = Vector2(respawn[1][index]) * 64 + Vector2(32, 32)
		mate.apply_collision_pose()
		fake.players[10 + index] = mate
	expect(rules.spawn_for(fake, 2) == Vector2i(-1, -1),
			"a fully occupied team side reports no point instead of overlapping")
	MazeGenerator.current_spawns = saved
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
	expect((cam.global_position - cam.get_base_global_position()).is_equal_approx(cam._shake_offset),
			"the rendered position is base + shake offset")
	# 跨接缝：目标在右侧边缘、基准在左侧时，相机应整体对齐到目标所在副本。
	cam._shake_amt = 0.0
	cam._shake_time = 0.0
	cam._shake_dur = 0.0
	cam._shake_offset = Vector2.ZERO
	target.global_position = Vector2(GameParameters.MAP_WIDTH - 4.0, 200)
	cam._base_pos = Vector2(4.0, 200 + PlayerParams.cam_y_bias)
	cam._process(1.0 / 60.0)
	var aligned := GridPathfinder.anchor_to_nearest(cam.get_base_global_position(),
			target.global_position, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	expect(aligned.distance_to(target.global_position + bias) < 32.0,
			"the camera base follows the nearest copy of the target across the seam")
	cleanup()
