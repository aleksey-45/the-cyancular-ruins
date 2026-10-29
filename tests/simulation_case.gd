extends "res://tests/case.gd"

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
	_world_rewind(parent, actor)

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
	source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0}, true))
	for tick in range(101, 109):
		rollback.capture(source, Vector2.RIGHT, tick, 0)
		rollback.advance(ActorStep.DT)
	var original := actor.capture_state()
	var saved: Dictionary = rollback._states[104]
	var buffer := InputBuffer.new()
	buffer.restore_cursor(saved["cursors"][actor.role])
	var own := {"epoch": 1, "ack": buffer.ack, "action_ack": buffer.action_ack,
			"timing_seq": 0, "lead": 2, "input": buffer._last, "rewind": false,
			"state": Player.expand_prediction_state(saved["players"][actor.role])}
	var frame := {"tick": 104, "map_revision": TileDefs.terrain.revision, "own": own,
			"time": {}, "world": {"players": {}, "projectiles": {}}}
	expect(rollback.reusable_tick(frame) == 108, "matching authority retains the full prediction suffix")
	rollback.reconcile(own, 104, 0, true, {})
	expect(rollback.replay_ticks == 0 and actor.capture_state() == original, "reuse executes no unnecessary replay")
	expect(rollback.can_replay_from(105), "short suffix has a usable checkpoint")
	rollback.replay_from(105)
	expect(rollback.replay_ticks == 4 and actor.capture_state() == original, "checkpoint suffix replay equals original simulation")
	rollback.reconcile(own, 104, 0, false, {})
	expect(rollback.replay_ticks == 4 and actor.capture_state() == original, "full authority restore equals optimized replay")
	rollback.combat_prediction.clear()
