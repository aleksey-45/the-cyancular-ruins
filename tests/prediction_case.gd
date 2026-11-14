extends "res://tests/case.gd"

func run(tree: SceneTree) -> void:
	_local_replay(tree)
	_history_window(tree)
	_rewind_and_epoch(tree)
	_world_replication(tree)
	_ordered_collision(tree)
	_stacked_collision(tree)
	_aligned_step_replay(tree)
	_authority_batch(tree)
	_lethal_hit(tree)
	_remote_down_replay(tree, false)
	_remote_down_replay(tree, true)
	_beam_order(tree)
	_combat_prediction(tree)
	_proxy_impulse(tree)
	_remote_auto_fire(tree)
	_late_shot(tree)
	_grenade_prediction(tree)
	_late_blast(tree)

func _frame(actor: Player, tick: int) -> Dictionary:
	return {"tick": tick, "map_revision": 0,
		"world": {"players": {actor.role: actor.capture_network_state()}, "pickups": {}, "projectiles": {}},
		"time": {}, "own": {"timing_seq": 0, "lead": 2}}

func _saved_frame(rollback: PredictionRollback, at: int) -> Dictionary:
	var saved := rollback._state_at(at)
	var frame := _frame(rollback._player, at)
	frame["world"]["players"] = saved.players.duplicate(true)
	frame["time"] = saved.accounts.duplicate(true)
	return frame

func _remote(actor: Player, pos: Vector2, hp: int) -> Dictionary:
	var snapshot := actor.capture_network_state()
	var state: Array = snapshot["state"]["actor"]
	state[PlayerStateSchema.POS] = pos
	state[PlayerStateSchema.HP] = hp
	return snapshot

func _capture(rollback: PredictionRollback, held: int, pressed: int) -> void:
	rollback.capture([1.0, held, pressed, 0, 0, Vector2.RIGHT])

func _local_replay(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var rollback := PredictionRollback.new()
	rollback.bind(actor, CombatSimulator.new(_terrain, parent, true))
	var shown: Array = []
	actor.shot_presented.connect(func(shot: Dictionary) -> void: shown.append(shot["serial"]))
	rollback.reset(_frame(actor, 100), 0)
	rollback.advance(ActorStep.DT, rollback.packet())
	var at := rollback.tick
	var snapshot := _saved_frame(rollback, at)
	var equipment_only := snapshot.duplicate(true)
	equipment_only["world"]["players"][actor.role]["state"]["equipment"][0] = 0.25
	expect(rollback.reconcile(equipment_only, 0) == PredictionRollback.Correction.SMOOTH
			and (actor.equipped as GunBody).fire_cd_timer == 0.25,
			"an equipment-only difference restores the equipment block")
	rollback.reconcile(snapshot, 0)
	_capture(rollback, ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)
	rollback.advance(ActorStep.DT, rollback.packet())
	var predicted := actor.capture_state()
	var endpoint := rollback.tick
	expect(actor.shot_serial == 1, "prediction calls the gun rule for the pending attack")
	snapshot["map_revision"] = 5
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.KEEP
			and actor.capture_state() == predicted and rollback.replay_ticks == 0,
			"a terrain revision with matching simulation state keeps the current prediction")
	var hp := PlayerStateSchema.HP
	var own: Dictionary = snapshot["world"]["players"][actor.role]
	own["state"]["actor"][hp] -= 4
	var mag := actor.equipped.carried
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.SMOOTH
			and rollback.tick == endpoint and rollback.replay_ticks == endpoint - at,
			"a local HP difference replays exactly the unconfirmed suffix")
	expect(actor.sim_hp == own["state"]["actor"][hp] and actor.shot_serial == 1
			and actor.equipped.carried == mag and shown == [1],
			"the pending attack survives replay and only spends one round and shows once")
	own["action_ack"] = rollback.sequence
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.SMOOTH
			and actor.shot_serial == 0 and actor.equipped.carried == mag + 1,
			"an acknowledged action cannot execute again, even when its input frame is still pending")
	cleanup()

func _history_window(tree: SceneTree) -> void:
	var actor := player(world(tree))
	var rollback := PredictionRollback.new()
	rollback.bind(actor, CombatSimulator.new(_terrain, actor.get_parent(), true))
	rollback.reset(_frame(actor, 100), 0)
	for index in PredictionRollback.KEEP + 1:
		rollback._step()
	var oldest := rollback.tick - PredictionRollback.KEEP + 1
	expect(rollback._state_at(oldest - 1) == null and rollback._state_at(oldest) != null,
			"a reused prediction slot rejects the overwritten tick")
	var snapshot := _saved_frame(rollback, oldest)
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.KEEP,
			"the oldest retained prediction frame still reconciles")
	rollback.reset(_frame(actor, rollback.tick), 0)
	expect(rollback._state_at(oldest) == null and rollback._state_at(rollback.tick) != null,
			"an authority reset keeps only its new prediction checkpoint")
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.SNAP and rollback.tick == oldest,
			"an absent checkpoint within the tick window snaps to authority")
	cleanup()

func _rewind_and_epoch(tree: SceneTree) -> void:
	var actor := player(world(tree))
	var rollback := PredictionRollback.new()
	rollback.bind(actor, CombatSimulator.new(_terrain, actor.get_parent(), true))
	rollback.time_economy = TimeEconomy.new({}, [actor.role])
	var baseline := _frame(actor, 100)
	baseline["time"] = rollback.time_economy.state_payload()
	rollback.reset(baseline, 0)
	rollback.advance(ActorStep.DT, rollback.packet())
	var authority := _saved_frame(rollback, rollback.tick - 1)
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.KEEP,
			"a matching Beta account keeps the current prediction")
	authority["time"][actor.role]["b"] *= 0.5
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.SMOOTH,
			"the local Beta account can trigger a replay")
	_capture(rollback, ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)
	authority = _saved_frame(rollback, rollback.tick)
	authority["world"]["players"][actor.role]["rewind"] = true
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.SNAP and actor.rewinding,
			"gameplay rewind follows the authority snapshot")
	var at := rollback.tick
	rollback.advance(2.0 * ActorStep.DT, rollback.packet())
	expect(rollback.tick == at and actor.shot_serial == 0, "local input does not advance the rewinding actor")
	authority["tick"] += 1
	authority["world"]["players"][actor.role]["epoch"] += 1
	authority["world"]["players"][actor.role]["rewind"] = false
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.SNAP
			and not actor.rewinding and rollback.packet()[InputBuffer.PACKET_ACTIONS].is_empty(),
			"the new control epoch drops edges from before gameplay rewind")
	rollback.advance(ActorStep.DT, rollback.packet())
	expect(actor.shot_serial == 0 and rollback.tick > at, "prediction resumes without firing an old action")
	cleanup()

func _world_replication(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var viewport := parent.get_viewport() as SubViewport
	var actor := player(viewport)
	var client := PvpMatchClient.new()
	client._local = actor
	client._world = viewport
	client._terrain = _terrain
	client._teams = {2: 2}
	var rollback := client._rollback
	var combat := CombatSimulator.new(_terrain, viewport, true)
	rollback.bind(actor, combat)
	var remote := _remote(actor, Vector2(10, 512), 100)
	remote["state"]["actor"][PlayerStateSchema.KNOCK_VEL] = Vector2(-600, 0)
	var frame := _frame(actor, 100)
	frame["world"]["players"][2] = remote
	client._playback.map_px = _terrain.map_size
	client._install_world(frame)
	rollback.reset(frame, 0)
	var proxy: Player = combat.players[2]
	var physics := CollisionWorld.acquire(proxy)
	var mask := CollisionWorld.LAYER_TEAM_B
	var seam_x := 10.0 + _terrain.map_size.x
	expect(not physics.ray_hit(Vector2(seam_x, 400), Vector2(seam_x, 650), mask).is_empty()
			and proxy.collision_mask == (CollisionWorld.LAYER_TERRAIN | CollisionWorld.LAYER_TEAM_A),
			"the latest remote snapshot exposes a team collider across the map seam")
	for i in 6:
		rollback._step()
	var projected := proxy.global_position
	var visible: Vector2 = client._playback.sample(106)["players"][2]["pos"]
	expect(is_equal_approx(projected.x, visible.x) and projected.y > visible.y
			and not physics.ray_hit(projected - Vector2(0, 80), projected + Vector2(0, 80), mask).is_empty(),
			"the collider applies gravity and projects decaying knockback across the seam")
	rollback._step()
	expect(proxy.global_position == projected, "the collision forecast stops after six ticks")
	frame = _saved_frame(rollback, 106)
	client._install_world(frame)
	expect(rollback.reconcile(frame, 0) == PredictionRollback.Correction.KEEP
			and rollback.replay_ticks == 1 and proxy.global_position.x < projected.x,
			"a matching newer snapshot extends the previously capped forecast")
	var height := proxy.collision_rect().size.y
	frame = _saved_frame(rollback, 107)
	remote = frame["world"]["players"][2]
	remote["state"]["actor"][PlayerStateSchema.POS] = Vector2(512, 512)
	remote["state"]["actor"][PlayerStateSchema.SQUAT] = true
	remote["rewind"] = true
	client._install_world(frame)
	var correction := rollback.reconcile(frame, 0)
	rollback._step()
	expect(correction == PredictionRollback.Correction.KEEP and proxy.rewinding
			and proxy.global_position == Vector2(512, 512) and proxy.collision_rect().size.y < height,
			"an authority snapshot restores position and crouch even if local state matches, and rewind freezes motion")
	expect(physics.ray_hit(Vector2(seam_x, 400), Vector2(seam_x, 650), mask).is_empty(),
			"moving the proxy inland removes its seam collision")
	frame = _saved_frame(rollback, 108)
	remote = frame["world"]["players"][2]
	remote["rewind"] = false
	remote["respawn_tick"] = 110
	var state: Array = remote["state"]["actor"]
	state[PlayerStateSchema.VEL] = Vector2.ZERO
	state[PlayerStateSchema.KNOCK_VEL] = Vector2.ZERO
	state[PlayerStateSchema.DOWNED] = true
	client._install_world(frame)
	rollback.reconcile(frame, 0)
	rollback._step()
	expect(proxy.collision_layer == mask, "the downed proxy still blocks before its respawn tick")
	var before_respawn := _saved_frame(rollback, 109)
	rollback._step()
	expect(proxy.collision_layer == 0 and physics.ray_hit(Vector2(512, 400), Vector2(512, 650), mask).is_empty(),
			"forward prediction releases the downed proxy at the end of the respawn tick")
	before_respawn["world"]["players"][actor.role]["state"]["actor"][PlayerStateSchema.HP] -= 1
	client._install_world(before_respawn)
	expect(rollback.reconcile(before_respawn, 0) == PredictionRollback.Correction.SMOOTH
			and proxy.collision_layer == 0 and rollback.replay_ticks == 1,
			"replay restores the downed proxy before crossing the respawn tick again")
	frame = _saved_frame(rollback, 110)
	frame["world"]["players"][2]["respawn_tick"] = 0
	client._install_world(frame)
	rollback.reconcile(frame, 0)
	expect(not physics.ray_hit(Vector2(512, 400), Vector2(512, 650), mask).is_empty(),
			"authority restores the collider when the actor remains downed after the due tick")
	rollback._step()
	frame = _saved_frame(rollback, 111)
	state = frame["world"]["players"][2]["state"]["actor"]
	state[PlayerStateSchema.DOWNED] = false
	state[PlayerStateSchema.POS] = Vector2(640, 512)
	client._install_world(frame)
	rollback.reconcile(frame, 0)
	expect(physics.ray_hit(Vector2(512, 400), Vector2(512, 650), mask).is_empty()
			and not physics.ray_hit(Vector2(640, 400), Vector2(640, 650), mask).is_empty(),
			"the confirmed respawn places the collider at the authority position")
	rollback._step()
	frame = _saved_frame(rollback, 112)
	frame["world"]["players"].erase(2)
	client._install_world(frame)
	rollback.reconcile(frame, 0)
	expect(physics.ray_hit(Vector2(640, 400), Vector2(640, 650), mask).is_empty(),
			"a removed remote player leaves no collision behind")
	var id := (actor.role << 48) | 256
	var projectile := {"type_id": WeaponRegistry.Type.GRENADE, "pos": Vector2(800, 544), "vel": Vector2(180, 0)}
	client._last_tick = 100
	combat.fire(actor, {"serial": 1, "type_id": projectile["type_id"], "pos": projectile["pos"],
		"dir": Vector2.RIGHT, "charge": 1.0, "speed_mult": 1.0})
	combat.step_projectiles(ActorStep.DT)
	client._present_projectile_previews(ActorStep.DT)
	var preview := client._preview_projectiles[id]
	expect(client._projectiles.is_empty() and preview._position == combat.projectiles[id].position
			and preview._position != projectile["pos"], "the local projectile view uses the predicted physics body")
	client._projectile_event(id, 102, projectile)
	expect(client._projectiles[id] == preview and client._preview_projectiles.is_empty(),
			"a reliable spawn takes over the existing projectile view")
	client._projectile_event(id, 102, null)
	client._projectile_event(id, 102, projectile)
	client._last_tick = 101
	client._sync_projectiles({id: projectile})
	expect(client._projectiles.is_empty(), "an older STATE cannot revive a projectile ended by a reliable event")
	client._last_tick = 103
	client._sync_projectiles({})
	client._projectile_event(id, 102, projectile)
	expect(client._projectile_events.is_empty() and client._projectiles.is_empty(),
			"a newer complete snapshot discards obsolete projectile events")
	client.free()
	cleanup()

func _ordered_collision(tree: SceneTree) -> void:
	# T1492 的公网对撞，平移到测试地图的地面上。
	var parent := world(tree)
	var authority := AuthorityWorld.new()
	authority.terrain = _terrain
	authority.combat_rules = CombatSimulator.new(_terrain, parent, true)
	authority.combat_rules.players = authority.players
	authority.rules.phase = NetEvent.RoundState.PLAYING
	authority._snap_tick = 1492
	for role: int in [5, 1]:
		var actor := player(parent, role)
		actor.set_team_collision(0)
		actor.position = Vector2(200.0 if role == 1 else 284.2959, 134.999)
		actor.velocity.x = 2092.2432 if role == 1 else -630.2997
		actor.pvp_haste_mult = 3.0 if role == 1 else 1.0
		actor._grounded = true
		actor.sync_collision_geometry()
		actor.input_buffer.restore_authority(1, 0, [1, 1, 1492, 1.0 if role == 1 else -1.0, 0, Vector2.RIGHT])
		authority.players[role] = actor
	var baseline := authority.world_state()
	var anchors := {1: authority.state_for(1, baseline, {}), 5: authority.state_for(5, baseline, {})}
	authority._physics_process(ActorStep.DT)
	for local_role: int in [1, 5]:
		var client_world := world(tree)
		var actor := player(client_world, local_role)
		actor.set_team_collision(0)
		var client := PvpMatchClient.new()
		client._local = actor
		client._world = client_world.get_viewport()
		client._terrain = _terrain
		var rollback := client._rollback
		rollback.bind(actor, CombatSimulator.new(_terrain, client_world, true))
		client._install_world(anchors[local_role])
		rollback.reset(anchors[local_role], 0)
		rollback._step()
		for role: int in authority.players:
			var body: ActorBody = rollback.combat.players[role]
			var expected_x: float = authority.players[role].position.x
			expect(absf(body.position.x - expected_x) <= CollisionWorld.MOTION_MARGIN and body.velocity.x == 0.0,
					"role %d with local %d at contact: x=%s (expected %s) vx=%s" %
					[role, local_role, body.position.x, expected_x, body.velocity.x])
		for i in 5:
			rollback._step()
		var endpoint := rollback._state_at(1498)
		rollback._request_replay(1493)
		expect(rollback.reconcile({}, 0) == PredictionRollback.Correction.KEEP and rollback.replay_ticks == 6
				and rollback._state_at(1498).players == endpoint.players,
				"replaying the same ordered collision gives the same local and proxy states")
		client.free()
	authority.free()
	cleanup()

func _stacked_collision(tree: SceneTree) -> void:
	# 公网 T2132：2 号在 6 号上方，6 号脚下是地面。恢复后须保留两人的贴地探测。
	var map := MapFormat.load_map("res://maps/newfactory.cyrm")
	var parent := _install_world(tree, map["grid"], map["descriptors"])
	var upper := player(parent, 2)
	var lower := player(parent, 6)
	upper.position = Vector2(6586.07763671875, 5532.1279296875)
	upper.velocity.x = -170.765701293945
	lower.position = Vector2(6588.923828125, 5639.1298828125)
	lower.pvp_haste_mult = 3.0
	for actor: Player in [upper, lower]:
		actor.set_team_collision(0)
		actor._grounded = true
		actor.sync_collision_geometry()
		actor.input_buffer.restore_authority(1, 0, [1, 1, 2132, -1.0, 0, Vector2.LEFT])
	var frame := _frame(lower, 2132)
	frame["world"]["players"][2] = upper.capture_network_state()
	var codec := NetCodec.new()
	var wire := codec.encode_state(frame, NetCodec.StateBatch.new(frame))
	frame = NetCodec.new().decode_state(NetCodec.Reader.new(wire, 1))
	var viewport := _install_world(tree, map["grid"], map["descriptors"]).get_viewport()
	var local := player(viewport, 6)
	local.set_team_collision(0)
	var client := PvpMatchClient.new()
	client._local = local
	client._world = viewport
	client._terrain = _terrain
	var rollback := client._rollback
	rollback.bind(local, CombatSimulator.new(_terrain, viewport, true))
	client._install_world(frame)
	rollback.reset(frame, 0)
	var proxy: Player = rollback.combat.players[2]
	expect(proxy._grounded, "the remote player restores authoritative ground contact")
	for at in range(2133, 2139):
		for actor: Player in [upper, lower]:
			ActorStep.step(actor, actor.input_buffer.take(at))
		rollback._step()
		expect(proxy.position.distance_to(upper.position) < 0.002 and proxy._grounded == upper._grounded
				and local.position.distance_to(lower.position) < 0.002 and local.velocity.x == 0.0,
				"the stacked contact stays aligned with authority at tick %d" % at)
	var endpoint := rollback._state_at(2138).players
	rollback._request_replay(2134)
	expect(rollback.reconcile({}, 0) == PredictionRollback.Correction.KEEP
			and rollback._state_at(2138).players == endpoint, "replay preserves the stacked contact through six ticks")
	client.free()
	cleanup()

func _aligned_step_replay(tree: SceneTree) -> void:
	for height: int in [48, 80]:
		var parent := _aligned_step_world(tree, height, false)
		var runner := player(parent)
		runner.position = Vector2(475.5, 326.999)
		runner.velocity.x = PlayerParams.move_speed
		runner._grounded = true
		runner.sync_collision_geometry()
		runner.input_buffer.restore_authority(1, 0, [1, 1, 100, 1.0, 0, Vector2.RIGHT])
		var authority := AuthorityWorld.new()
		authority.terrain = _terrain
		authority.players[runner.role] = runner
		authority.combat_rules = CombatSimulator.new(_terrain, parent, true)
		authority.combat_rules.players = authority.players
		authority.rules.phase = NetEvent.RoundState.PLAYING
		authority._snap_tick = 100
		var frame := authority.state_for(runner.role, authority.world_state(), {})
		var codec := NetCodec.new()
		var wire := codec.encode_state(frame, NetCodec.StateBatch.new(frame))

		var client_world := _aligned_step_world(tree, height, true)
		var local := player(client_world)
		var rollback := PredictionRollback.new()
		rollback.bind(local, CombatSimulator.new(_terrain, client_world, true))
		rollback.reset(NetCodec.new().decode_state(NetCodec.Reader.new(wire, 1)), 0)
		for at in range(101, 105):
			authority._physics_process(ActorStep.DT)
			rollback._step()
			expect(local.capture_state() == runner.capture_state(),
					"the %dpx aligned face agrees with authority at tick %d" % [height, at])
		var rise := 326.999 - runner.position.y
		expect(absf(rise - (48.0 if height == 48 else 0.0)) < 0.1 and runner._grounded,
				"the %dpx aligned face obeys the step height limit" % height)
		var endpoint := rollback._state_at(104).players
		rollback._request_replay(101)
		expect(rollback.reconcile({}, 0) == PredictionRollback.Correction.KEEP and rollback.replay_ticks == 4
				and rollback._state_at(104).players == endpoint, "aligned step replay reproduces the endpoint")
		authority.free()
		cleanup()

func _aligned_step_world(tree: SceneTree, height: int, reverse_order: bool) -> Node2D:
	var parent := world_from_solid(tree, 16, 8, func(_sx: int, sy: int) -> bool: return sy >= 24)
	var faces := [Rect2(512, 368, 128, 16), Rect2(512, 384 - height, 64, height - 16)]
	if reverse_order:
		faces.reverse()
	var wall := StaticBody2D.new()
	wall.collision_layer = CollisionWorld.LAYER_TERRAIN
	wall.collision_mask = 0
	for rect: Rect2 in faces:
		var hull := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = rect.size
		hull.shape = shape
		hull.position = rect.get_center()
		wall.add_child(hull)
	parent.add_child(wall)
	return parent

func _authority_batch(tree: SceneTree) -> void:
	var parent := world(tree)
	var viewport := parent.get_viewport() as SubViewport
	var actor := player(viewport)
	var terrain := _terrain
	var client := PvpMatchClient.new()
	client.phase = PvpMatchClient.Phase.ONLINE
	client._local = actor
	client._world = viewport
	client._terrain = terrain
	client._rollback.bind(actor, CombatSimulator.new(terrain, viewport, true))
	client._rollback.reset(_frame(actor, 100), 0)
	client._last_tick = 100
	client._rollback.advance(3.0 * ActorStep.DT, client._rollback.packet())
	var endpoint := client._rollback.tick
	var before := actor.capture_state()
	var sub := Vector2i(8, 12)
	var initial_hp := terrain.get_hp(sub)
	var old := _saved_frame(client._rollback, 101)
	var wait := _saved_frame(client._rollback, 102)
	wait["map_revision"] = 2
	client._on_state(wait)
	client._on_state(old)
	client._apply_pending_authority()
	expect(client._last_tick == 101 and client._pending_states.size() == 1,
			"the newest STATE with an installed revision is used while a newer revision waits")
	client._on_event(1, NetEvent.Kind.TERRAIN, {"revision": 1, "cells": {sub: initial_hp - 1}})
	var hit := {"shooter": 2, "victim": actor.role, "damage": 3, "tick": 102, "epoch": 1,
			"hp": actor.sim_hp - 3, "impulse_mode": 1, "knock": Vector2(600, 0)}
	client._on_event(1, NetEvent.Kind.HIT, hit)
	client._apply_pending_authority()
	var hp := PlayerStateSchema.HP
	var pos := PlayerStateSchema.POS
	expect(terrain.get_hp(sub) == initial_hp - 1 and client._last_tick == 101
			and actor.sim_hp == before["actor"][hp] - 3 and actor.position.x > before["actor"][pos].x
			and client._rollback.tick == endpoint, "a late HIT replays confirmed knockback while STATE waits for terrain")
	var at_hit: Array = client._rollback._state_at(102).players[actor.role]["state"]["actor"]
	expect(at_hit[pos] == wait["world"]["players"][actor.role]["state"]["actor"][pos]
			and at_hit[PlayerStateSchema.KNOCK_VEL] == hit["knock"],
			"a hit after movement changes the velocity at its tick and the position from the next tick")
	var newest := _saved_frame(client._rollback, 103)
	newest["map_revision"] = 2
	var after := actor.capture_state()
	client._on_state(newest)
	client._on_state(wait)
	client._on_event(1, NetEvent.Kind.TERRAIN, {"revision": 2, "cells": {sub: 0}})
	client._apply_pending_authority()
	expect(client._last_tick == 103 and client._pending_states.is_empty() and terrain.get_hp(sub) == 0,
			"the matching patch makes only the newest waiting STATE installable")
	client._on_event(1, NetEvent.Kind.HIT, hit)
	client._apply_pending_authority()
	expect(actor.capture_state() == after and client._rollback._hits.is_empty()
			and client._rollback.replay_ticks == 0, "a STATE covering a hit replaces it without applying the impulse twice")
	for index in PredictionRollback.KEEP + 1:
		_capture(client._rollback, 0, 0)
	client._on_event(1, NetEvent.Kind.HIT, hit.merged({"tick": endpoint}, true))
	client._apply_pending_authority()
	expect(actor.capture_state() == after and client._rollback._hits.has(endpoint),
			"a late HIT waits for STATE once the required input history has been overwritten")
	client.free()
	cleanup()

func _lethal_hit(tree: SceneTree) -> void:
	var actor := player(world(tree))
	var rollback := PredictionRollback.new()
	rollback.bind(actor, CombatSimulator.new(_terrain, actor.get_parent(), true))
	rollback.reset(_frame(actor, 100), 0)
	rollback.queue_hit({"tick": 102, "epoch": 1, "victim": actor.role, "hp": 0,
			"impulse_mode": -1, "vel": Vector2(600, 0)})
	rollback._step()
	var start := actor.position
	expect(not actor.sim_downed and actor.velocity.x == 0.0, "a queued hit waits for its authority tick")
	rollback._step()
	expect(actor.sim_downed and actor.position.x == start.x and actor.velocity.x == 600.0,
			"a lethal hit changes the hull and velocity at the end of its tick")
	rollback._step()
	expect(actor.position.x > start.x, "the downed actor moves with the confirmed impulse on the next tick")
	var fresh := _frame(actor, 104)
	fresh["world"]["players"][actor.role]["epoch"] = 2
	rollback.reconcile(fresh, 0)
	rollback.queue_hit({"tick": 105, "epoch": 1, "victim": actor.role})
	expect(rollback._hits.is_empty(), "a hit from an older epoch cannot move the new actor")
	cleanup()

func _remote_down_replay(tree: SceneTree, with_state: bool) -> void:
	var viewport := world(tree).get_viewport() as SubViewport
	var actor := player(viewport, 2)
	actor.position = Vector2(376, 134.999)
	actor.collision_mask = CollisionWorld.LAYER_TERRAIN | CollisionWorld.LAYER_TEAM_A
	actor._apply_layers()
	actor.sync_collision_geometry()
	var client := PvpMatchClient.new()
	client.phase = PvpMatchClient.Phase.ONLINE
	client._local = actor
	client._world = viewport
	client._terrain = _terrain
	var rollback := client._rollback
	rollback.bind(actor, CombatSimulator.new(_terrain, viewport, true))
	var baseline := _frame(actor, 100)
	var remote_pos := Vector2(240.075, 134.999)
	baseline["world"]["players"][3] = _remote(actor, remote_pos, 4)
	client._install_world(baseline)
	rollback.reset(baseline, 0)
	rollback.advance(3.0 * ActorStep.DT, rollback.packet())
	var endpoint := rollback.tick
	var hit := {"shooter": 3, "victim": 2, "damage": 35, "tick": 102, "epoch": 1, "hp": 10,
			"impulse_mode": 1, "knock": Vector2(-2970.7, -418.37)}
	var down := hit.merged({"victim": 3, "hp": -31, "pos": remote_pos, "facing": -1,
			"vel": Vector2.ZERO, "knock": Vector2(2951.45, -537.55)}, true)
	client._on_event(1, NetEvent.Kind.HIT, hit)
	client._apply_pending_authority()
	expect(rollback._state_at(103).players[actor.role]["state"]["actor"][PlayerStateSchema.KNOCK_VEL].x < 0.0,
			"the standing hull does not block this knockback")
	client._on_event(1, NetEvent.Kind.HIT, down)
	if with_state:
		var state := _saved_frame(rollback, 102)
		var downed: Array = state["world"]["players"][3]["state"]["actor"]
		downed[PlayerStateSchema.DOWNED] = true
		downed[PlayerStateSchema.GROUNDED] = false
		downed[PlayerStateSchema.HP] = down["hp"]
		downed[PlayerStateSchema.FACING] = down["facing"]
		downed[PlayerStateSchema.KNOCK_VEL] = down["knock"]
		client._on_state(state)
	client._apply_pending_authority()
	var proxy: ActorBody = rollback.combat.players[3]
	expect(proxy.sim_downed and proxy.global_position != remote_pos,
			"a confirmed down updates the remote hull and moves it on the following ticks")
	var at_contact: Array = rollback._state_at(103).players[actor.role]["state"]["actor"]
	expect(at_contact[PlayerStateSchema.KNOCK_VEL].x == 0.0 and actor.sim_hp == 10
			and rollback.replay_ticks == endpoint - (102 if with_state else 100),
			"the confirmed down replays movement from the next tick and blocks horizontal knockback")
	var covered := _saved_frame(rollback, endpoint)
	client._on_state(covered)
	client._apply_pending_authority()
	expect(rollback._hits.is_empty() and proxy.sim_downed and rollback._state_at(102) != null,
			"a covering STATE owns the hull and retires the hit without an extra replay")
	client.free()
	cleanup()

func _beam_order(tree: SceneTree) -> void:
	var cell := Vector2i(14, 8)
	var parent := world_with_walls(tree, 16, 16, {cell: wall_texture()})
	var viewport := parent.get_viewport() as SubViewport
	var actor := player(viewport)
	var terrain := _terrain
	var client := PvpMatchClient.new()
	client.phase = PvpMatchClient.Phase.ONLINE
	client._local = actor
	client._world = viewport
	client._terrain = terrain
	client._rollback.bind(actor, CombatSimulator.new(terrain, viewport, true))
	client._rollback.reset(_frame(actor, 100), 0)
	var shot := {"type_id": WeaponRegistry.Type.LASER, "pos": Vector2(200, 544), "dir": Vector2.RIGHT, "serial": 1}
	var id := ShotRules.shot_id(actor.role, 1)
	client._present_local_shot(shot)
	var preview := client._preview_beams[id]
	expect(preview.get_node("Core").points.size() >= 3, "the local beam is visible before any authority message")
	var old := shot.merged({"role": 2, "tick": 101})
	var confirmed := shot.merged({"role": actor.role, "tick": 102})
	var patch := {}
	for y in 4:
		for x in 4:
			patch[cell * 4 + Vector2i(x, y)] = 0
	client._on_event(1, NetEvent.Kind.FIRE, old)
	client._on_event(1, NetEvent.Kind.TERRAIN, {"revision": terrain.revision + 1, "cells": patch})
	client._on_event(1, NetEvent.Kind.FIRE, confirmed)
	var children := viewport.get_child_count()
	client._apply_pending_authority()
	var remote := viewport.get_child(-1)
	expect(remote.get_node("Core").points.size() >= 3 and preview.get_node("Core").points.size() == 2,
			"beams on either side of a TERRAIN event see different collision in the same receive batch")
	expect(client._preview_beams.is_empty() and viewport.get_child_count() == children + 1,
			"the authority updates the visible local beam without playing it again")
	shot["serial"] = 2
	id = ShotRules.shot_id(actor.role, 2)
	client._present_local_shot(shot)
	client._preview_beams[id].free()
	children = viewport.get_child_count()
	client._on_fire(shot.merged({"role": actor.role, "tick": 103}))
	expect(client._preview_beams.is_empty() and viewport.get_child_count() == children,
			"a delayed confirmation does not restart a local beam that already faded")
	client.free()
	cleanup()

func _combat_prediction(tree: SceneTree) -> void:
	const MELEE := 9
	WeaponRegistry._definitions[MELEE] = WeaponRegistry.DEFAULTS.merged({
		"attack": WeaponRegistry.Attack.MELEE, "range": 80.0, "hit_radius": 4.0, "damage": 10, "impact": 350.0}, true)
	for type_id: int in [WeaponRegistry.Type.LASER, WeaponRegistry.Type.PISTOL, MELEE]:
		var parent := world_with_walls(tree, 16, 16, {})
		var actor := player(parent, 2)
		actor.global_position = Vector2(325, 544)
		actor.sim_hp = 1
		actor.sync_collision_geometry()
		var proxy := player(parent, 1)
		proxy.position = Vector2(200, 544)
		proxy.sync_collision_geometry()
		var combat := CombatSimulator.new(_terrain, parent, true)
		var rollback := PredictionRollback.new()
		rollback.bind(actor, combat)
		combat.players[proxy.role] = proxy
		var frame := _frame(actor, 100)
		frame["world"]["players"][proxy.role] = proxy.capture_network_state()
		rollback.reset(frame, 0)
		rollback._step()
		var pos := actor.global_position
		rollback.queue_shot({"kind": "fire", "role": proxy.role, "type_id": type_id, "serial": 1, "tick": 101,
			"pos": Vector2(260, 544), "dir": Vector2.RIGHT, "charge": 1.0, "speed_mult": 1.0})
		expect(rollback.reconcile({}, 0) == PredictionRollback.Correction.SMOOTH
				and actor.global_position == pos and actor.motion_knock_velocity.x > 0.0
				and actor.sim_hp == 1 and not actor.sim_downed,
				"attack %d predicts its impact in the combat phase while HP stays authoritative" % type_id)
		var authority_knock := Vector2(240, 120)
		rollback.queue_hit({"victim": actor.role, "tick": 101, "epoch": 1, "hp": 0,
			"impulse_mode": 1, "knock": authority_knock})
		rollback.reconcile({}, 0)
		expect(actor.sim_downed and actor.motion_knock_velocity == authority_knock,
				"confirmed hit replaces predicted impulse for attack %d" % type_id)
		cleanup()
	WeaponRegistry._definitions.erase(MELEE)

func _late_shot(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var shooter := player(parent, 1)
	var actor := player(parent, 2)
	shooter.position = Vector2(150, 544)
	actor.position = Vector2(450, 544)
	shooter.sync_collision_geometry()
	actor.sync_collision_geometry()
	var combat := CombatSimulator.new(_terrain, parent, true)
	var rollback := PredictionRollback.new()
	rollback.bind(actor, combat)
	combat.players[1] = shooter
	var baseline := _frame(actor, 100)
	baseline["world"]["players"][shooter.role] = shooter.capture_network_state()
	rollback.reset(baseline, 0)
	for i in 4:
		rollback._step()
	var shot := {"kind": "fire", "role": 1, "serial": 1, "tick": 101, "type_id": WeaponRegistry.Type.PISTOL,
			"pos": Vector2(220, 544), "dir": Vector2.RIGHT, "charge": 1.0, "speed_mult": 1.0}
	var id := ShotRules.shot_id(1, 1)
	var spec := WeaponRegistry.definition(shot["type_id"])
	var velocity := ShotRules.projectile_velocities(1, shot, spec)[0]
	var frame := _saved_frame(rollback, 102)
	frame["world"]["projectiles"][id] = {"type_id": shot["type_id"], "vel": velocity,
		"pos": shot["pos"] + velocity * ActorStep.DT * 2.0}
	rollback.reconcile(frame, 0)
	rollback.queue_shot(shot)
	expect(rollback.reconcile({}, 0) == PredictionRollback.Correction.KEEP and rollback.replay_ticks == 2,
			"a shot behind STATE replays its flight without correcting unchanged local motion")
	var bullet: BulletBody = combat.projectiles.get(id)
	expect(bullet != null and is_equal_approx(bullet.traveled, velocity.length() * ActorStep.DT * 4.0),
			"catching up a late projectile calculates its travel from the launch tick")
	for i in 5:
		rollback._step()
	expect(actor.motion_knock_velocity.x > 0.0 and actor.sim_hp == actor.sim_max_hp,
			"a late remote projectile can predict a subsequent impact")
	cleanup()

func _proxy_impulse(tree: SceneTree) -> void:
	var viewport := world_with_walls(tree, 16, 16, {}).get_viewport() as SubViewport
	var actor := player(viewport)
	actor.position = Vector2(200, 544)
	actor.sync_collision_geometry()
	actor.weapons.set_initial_inventory([WeaponRegistry.Type.LASER])
	var client := PvpMatchClient.new()
	client._local = actor
	client._world = viewport
	client._terrain = _terrain
	var rollback := client._rollback
	rollback.bind(actor, CombatSimulator.new(_terrain, viewport, true))
	var baseline := _frame(actor, 100)
	var pos := Vector2(450, 544)
	baseline["world"]["players"][2] = _remote(actor, pos, 1)
	baseline["world"]["players"][2]["state"]["actor"][PlayerStateSchema.GROUNDED] = true
	client._install_world(baseline)
	rollback.reset(baseline, 0)
	_capture(rollback, ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)
	rollback.advance(ActorStep.DT, rollback.packet())
	var proxy: ActorBody = rollback.combat.players[2]
	expect(proxy.motion_knock_velocity.x > 0.0 and proxy.global_position.x == pos.x and proxy.sim_hp == 1,
			"a local action predicts the remote collider impulse after movement")
	rollback._step()
	expect(proxy.global_position.x > pos.x and not proxy.sim_downed,
			"remote collider forecast incorporates a predicted impulse without predicting down")
	client.free()
	cleanup()

func _remote_auto_fire(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent, 2)
	actor.position.x = 800
	actor._grounded = true
	actor.sync_collision_geometry()
	var proxy := player(parent, 1)
	proxy._grounded = true
	proxy.weapons.set_initial_inventory([WeaponRegistry.Type.RIFLE])
	proxy.input_buffer.restore_authority(1, 0, [1, 1, 100, 0.0, ActorInput.BIT_ATTACK, Vector2.RIGHT])
	var rollback := PredictionRollback.new()
	var combat := CombatSimulator.new(_terrain, parent, true)
	rollback.bind(actor, combat)
	combat.players[1] = proxy
	var baseline := _frame(actor, 100)
	baseline["world"]["players"][1] = proxy.capture_network_state()
	rollback.reset(baseline, 0)
	rollback._step()
	var id := ShotRules.shot_id(1, 1)
	expect(combat.projectiles.has(id) and proxy.shot_serial == 1 and proxy.equipped.carried == 29,
			"shared remote actor step advances held fire, equipment and recoil")
	var shot: Dictionary = rollback._state_at(101).shots[id].merged({"pos": Vector2(350, 128)}, true)
	rollback.queue_shot(shot)
	rollback.reconcile({}, 0)
	expect(combat.projectiles.size() == 1 and combat.projectiles[id].launch == shot
			and proxy.shot_serial == 1 and proxy.equipped.carried == 29,
			"the confirmed shot replaces the predicted launch exactly once during replay")
	cleanup()

func _grenade_prediction(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	actor.weapons.set_initial_inventory([WeaponRegistry.Type.GRENADE])
	actor.position = Vector2(260, 135)
	actor.sync_collision_geometry()
	var combat := CombatSimulator.new(_terrain, parent, true)
	var rollback := PredictionRollback.new()
	rollback.bind(actor, combat)
	rollback.reset(_frame(actor, 100), 0)
	rollback.capture([0.0, ActorInput.BIT_DOWN, 0, ActorInput.BIT_ATTACK, 0, Vector2(0.3, 1.0).normalized()])
	rollback.advance(ActorStep.DT, rollback.packet())
	var id := ShotRules.shot_id(actor.role, 1)
	expect(combat.projectiles.has(id), "the local attack action immediately creates a physics projectile")
	for i in 3:
		rollback._step()
	var bullet: BulletBody = combat.projectiles[id]
	var frame := _saved_frame(rollback, rollback.tick)
	frame["world"]["projectiles"][id] = {"type_id": bullet.type_id, "pos": bullet.position, "vel": bullet.velocity_vec}
	frame["world"]["players"][actor.role]["state"]["actor"][PlayerStateSchema.HP] -= 1
	rollback._step()
	var continued := bullet.motion_state()
	expect(bullet.fuse_elapsed > 0.0 and rollback.reconcile(frame, 0) == PredictionRollback.Correction.SMOOTH
			and combat.projectiles[id].motion_state() == continued,
			"replay preserves a physically calculated grenade fuse and travel through a pose-only STATE")
	var hp := actor.sim_hp
	var due := 0
	for i in 50:
		rollback._step()
		if combat._pending_blasts.has(id):
			due = combat._pending_blasts[id]["due"]
			break
	expect(due == rollback.tick + CombatSimulator.BLAST_DELAY and actor.motion_knock_velocity == Vector2.ZERO,
			"the predicted fuse schedules the blast for the ordinary delayed combat phase")
	if due > 0:
		while rollback.tick < due:
			rollback._step()
	expect(actor.motion_knock_velocity != Vector2.ZERO and actor.sim_hp == hp and not actor.sim_downed,
			"the local grenade predicts its own blast impulse before HIT or STATE")
	cleanup()

func _late_blast(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var combat := CombatSimulator.new(_terrain, parent, true)
	var rollback := PredictionRollback.new()
	rollback.bind(actor, combat)
	rollback.reset(_frame(actor, 102), 0)
	var id := ShotRules.shot_id(actor.role, 1)
	rollback.queue_projectile_end(id, 101, CombatSimulator.blast_state(WeaponRegistry.Type.GRENADE,
			actor.position - Vector2(60, 0), 101))
	rollback.reconcile({}, 0)
	rollback._step()
	expect(actor.motion_knock_velocity == Vector2.ZERO, "a late EXPLOSION retains its settlement tick")
	rollback._step()
	expect(actor.motion_knock_velocity.x > 0.0 and combat._pending_blasts.is_empty(),
			"an EXPLOSION older than STATE supplies the pending impulse exactly once")
	cleanup()
