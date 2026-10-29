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
	_confirmed_lifecycle(actor, initial)
	_world_rewind(parent, actor)
	_beta_history(parent, actor)

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
	var saved: Dictionary = rollback._states[104]
	expect(not authority_projectiles.is_empty(), "replay fixture has a live projectile")
	var snapshot: NativeProjectileSnapshot = saved["projectiles"]
	expect(snapshot.matches(authority_projectiles), "later simulation cannot mutate an earlier projectile frame")
	var altered := authority_projectiles.duplicate(true)
	for id in altered: altered[id]["fuse_elapsed"] += 0.25
	expect(not snapshot.matches(altered) and snapshot.matches(authority_projectiles),
			"projectile comparison detects changed timers without changing stored history")
	var buffer := InputBuffer.new()
	buffer.restore_cursor(saved["cursors"][actor.role])
	var own := {"epoch": 1, "ack": buffer.ack, "action_ack": buffer.action_ack,
			"timing_seq": 0, "lead": 2, "input": buffer._last, "rewind": false,
			"state": Player.expand_prediction_state(saved["players"][actor.role])}
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
