extends "res://tests/case.gd"

func run(tree: SceneTree) -> void:
	_local_replay(tree)
	_history_window(tree)
	_rewind_and_epoch(tree)
	_world_replication(tree)
	_authority_batch(tree)
	_beam_order(tree)

func _frame(actor: Player, tick: int) -> Dictionary:
	return {"tick": tick, "map_revision": 0,
		"world": {"players": {}, "pickups": {}, "projectiles": {}}, "time": {},
		"own": {"epoch": 1, "action_ack": 0, "timing_seq": 0, "lead": 2,
			"input": InputBuffer.neutral_frame(), "state": actor.capture_state(), "rewind": false}}

func _saved_frame(actor: Player, rollback: PredictionRollback, at: int) -> Dictionary:
	var saved := rollback._state_at(at)
	var frame := _frame(actor, at)
	var cursor := saved.cursor
	frame["own"].merge({"state": saved.player.duplicate(true), "epoch": cursor[0], "action_ack": cursor[2],
		"input": [cursor[1], 1, cursor[3], cursor[4], cursor[5], cursor[6]]}, true)
	frame["time"][actor.role] = saved.account.duplicate()
	return frame

func _capture(rollback: PredictionRollback, held: int, pressed: int) -> void:
	rollback.capture([1.0, held, pressed, 0, 0, Vector2.RIGHT])

func _local_replay(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	var shown: Array = []
	actor.shot_presented.connect(func(shot: Dictionary) -> void: shown.append(shot["serial"]))
	rollback.reset(_frame(actor, 100), 0)
	rollback.advance(ActorStep.DT, rollback.packet())
	var at := rollback.tick
	var snapshot := _saved_frame(actor, rollback, at)
	var equipment_only := snapshot.duplicate(true)
	equipment_only["own"]["state"]["equipment"][0] = 0.25
	expect(rollback.reconcile(equipment_only, 0) == PredictionRollback.Correction.SMOOTH
			and (actor.equipped as GunBody).fire_cd_timer == 0.25,
			"an equipment-only difference restores the equipment block")
	rollback.reconcile(snapshot, 0)
	_capture(rollback, ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)
	rollback.advance(ActorStep.DT, rollback.packet())
	var predicted := actor.capture_state()
	var endpoint := rollback.tick
	expect(actor.shot_serial == 1, "prediction calls the gun rule for the pending attack")
	snapshot["world"]["projectiles"] = {256: {"type_id": WeaponRegistry.Type.PISTOL,
			"pos": Vector2(90, 90), "vel": Vector2.RIGHT}}
	snapshot["world"]["players"] = {2: []}
	snapshot["map_revision"] = 5
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.KEEP
			and actor.capture_state() == predicted and rollback.replay_ticks == 0,
			"remote players, projectiles and terrain revisions do not invalidate local prediction")
	var hp := PlayerStateSchema.HP
	snapshot["own"]["state"]["actor"][hp] -= 4
	var mag := actor.equipped.carried
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.SMOOTH
			and rollback.tick == endpoint and rollback.replay_ticks == endpoint - at,
			"a local HP difference replays exactly the unconfirmed suffix")
	expect(actor.sim_hp == snapshot["own"]["state"]["actor"][hp] and actor.shot_serial == 1
			and actor.equipped.carried == mag and shown == [1],
			"the pending attack survives replay and only spends one round and shows once")
	snapshot["own"]["action_ack"] = rollback.sequence
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.SMOOTH
			and actor.shot_serial == 0 and actor.equipped.carried == mag + 1,
			"an acknowledged action cannot execute again, even when its input frame is still pending")
	cleanup()

func _history_window(tree: SceneTree) -> void:
	var actor := player(world(tree))
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	rollback.reset(_frame(actor, 100), 0)
	for index in PredictionRollback.KEEP + 1:
		rollback._step()
	var oldest := rollback.tick - PredictionRollback.KEEP + 1
	expect(rollback._state_at(oldest - 1) == null and rollback._state_at(oldest) != null,
			"a reused prediction slot rejects the overwritten tick")
	var snapshot := _saved_frame(actor, rollback, oldest)
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
	rollback.bind(actor)
	rollback.time_economy = TimeEconomy.new({}, [actor.role])
	var baseline := _frame(actor, 100)
	baseline["time"] = rollback.time_economy.state_payload()
	rollback.reset(baseline, 0)
	rollback.advance(ActorStep.DT, rollback.packet())
	var authority := _saved_frame(actor, rollback, rollback.tick - 1)
	authority["time"][2] = {"b": 0.0}
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.KEEP,
			"another Beta account never enters local reconciliation")
	authority["time"][actor.role]["b"] *= 0.5
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.SMOOTH,
			"the local Beta account can trigger a replay")
	_capture(rollback, ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)
	authority = _saved_frame(actor, rollback, rollback.tick)
	authority["own"]["rewind"] = true
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.SNAP and actor.rewinding,
			"gameplay rewind follows the authority snapshot")
	var at := rollback.tick
	rollback.advance(2.0 * ActorStep.DT, rollback.packet())
	expect(rollback.tick == at and actor.shot_serial == 0, "local input does not advance the rewinding actor")
	authority["tick"] += 1
	authority["own"]["epoch"] += 1
	authority["own"]["rewind"] = false
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
	var remote := [Vector2(10, 512), Vector2.ZERO, 1, false, ActorBody.STAND, 100, false,
		Vector2.RIGHT, WeaponRegistry.Type.PISTOL, 1, false, false]
	client._latest_players = {2: remote}
	client._sync_proxies()
	var proxy: ActorBody = client._proxies[2]
	var physics := CollisionWorld.acquire(proxy)
	var mask := CollisionWorld.LAYER_TEAM_B
	var seam_x := 10.0 + _terrain.map_size.x
	expect(not physics.ray_hit(Vector2(seam_x, 400), Vector2(seam_x, 650), mask).is_empty(),
			"the latest remote snapshot exposes its hull across the map seam")
	var height := proxy.collision_rect().size.y
	remote[PlayerStateSchema.REMOTE_POS] = Vector2(512, 512)
	remote[PlayerStateSchema.REMOTE_SQUAT] = true
	client._sync_proxies()
	expect(proxy.global_position == Vector2(512, 512) and proxy.is_squat
			and proxy.collision_rect().size.y < height,
			"the next authority snapshot updates position and crouch together")
	expect(physics.ray_hit(Vector2(seam_x, 400), Vector2(seam_x, 650), mask).is_empty(),
			"moving the proxy inland removes its seam collision")
	client._latest_players.erase(2)
	client._sync_proxies()
	expect(physics.ray_hit(Vector2(512, 400), Vector2(512, 650), mask).is_empty(),
			"a removed remote player leaves no collision behind")
	var id := (actor.role << 48) | 256
	var state := {"type_id": WeaponRegistry.Type.GRENADE, "pos": Vector2(800, 544), "vel": Vector2(180, 0)}
	client._last_tick = 100
	client._present_local_shot({"serial": 1, "type_id": state["type_id"], "pos": state["pos"],
		"dir": Vector2.RIGHT, "charge": 1.0})
	var preview := client._preview_projectiles[id]
	expect(client._projectiles.is_empty() and preview.present_preview(ActorStep.DT, actor.position)
			and preview.global_position != state["pos"],
			"a local projectile immediately travels without affecting the authority cap")
	client._projectile_event(id, 102, state)
	expect(client._projectiles[id] == preview and client._preview_projectiles.is_empty(),
			"a reliable spawn takes over the existing projectile view")
	client._projectile_event(id, 102, null)
	client._projectile_event(id, 102, state)
	client._last_tick = 101
	client._sync_projectiles({id: state})
	expect(client._projectiles.is_empty(), "an older STATE cannot revive a projectile ended by a reliable event")
	client._last_tick = 103
	client._sync_projectiles({})
	client._projectile_event(id, 102, state)
	expect(client._projectile_events.is_empty() and client._projectiles.is_empty(),
			"a newer complete snapshot discards obsolete projectile events")
	client.free()
	cleanup()

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
	client._rollback.bind(actor)
	client._rollback.reset(_frame(actor, 100), 0)
	client._last_tick = 100
	client._rollback.advance(3.0 * ActorStep.DT, client._rollback.packet())
	var endpoint := client._rollback.tick
	var before := actor.capture_state()
	var sub := Vector2i(8, 12)
	var initial_hp := terrain.get_hp(sub)
	var old := _saved_frame(actor, client._rollback, 101)
	var wait := _saved_frame(actor, client._rollback, 102)
	wait["map_revision"] = 2
	client._on_state(wait)
	client._on_state(old)
	client._apply_pending_authority()
	expect(client._last_tick == 101 and client._pending_states.size() == 1,
			"the newest STATE with an installed revision is used while a newer revision waits")
	client._on_event(1, NetEvent.Kind.TERRAIN, {"revision": 1, "cells": {sub: initial_hp - 1}})
	client._on_event(1, NetEvent.Kind.HIT, {"shooter": 2, "victim": actor.role, "damage": 3})
	client._apply_pending_authority()
	expect(terrain.get_hp(sub) == initial_hp - 1 and client._last_tick == 101
			and actor.capture_state() == before, "a terrain patch and HIT alone neither modify local HP nor replay")
	var newest := _saved_frame(actor, client._rollback, 103)
	newest["map_revision"] = 2
	var hp := PlayerStateSchema.HP
	newest["own"]["state"]["actor"][hp] -= 3
	client._on_state(newest)
	client._on_state(wait)
	client._on_event(1, NetEvent.Kind.TERRAIN, {"revision": 2, "cells": {sub: 0}})
	client._apply_pending_authority()
	expect(client._last_tick == 103 and client._pending_states.is_empty() and terrain.get_hp(sub) == 0,
			"the matching patch makes only the newest waiting STATE installable")
	expect(actor.sim_hp == before["actor"][hp] - 3 and client._rollback.replay_ticks == endpoint - 103,
			"local damage comes from the authoritative checkpoint and replays one suffix")
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
	var shot := {"type_id": WeaponRegistry.Type.LASER, "pos": Vector2(200, 544), "dir": Vector2.RIGHT, "serial": 1}
	var id := ShotRules.shot_id(actor.role, 1)
	client._present_local_shot(shot)
	var preview := client._preview_beams[id]
	expect(preview.get_node("Core").points.size() >= 3, "the local beam is visible before any authority message")
	var old := shot.merged({"id": ShotRules.shot_id(2, 1), "tick": 101})
	var confirmed := shot.merged({"id": id, "tick": 102})
	var patch := {}
	for y in 4:
		for x in 4:
			patch[cell * 4 + Vector2i(x, y)] = 0
	client._on_event(1, NetEvent.Kind.BEAM, old)
	client._on_event(1, NetEvent.Kind.TERRAIN, {"revision": terrain.revision + 1, "cells": patch})
	client._on_event(1, NetEvent.Kind.BEAM, confirmed)
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
	client._on_beam_fired(shot.merged({"id": id, "tick": 103}))
	expect(client._preview_beams.is_empty() and viewport.get_child_count() == children,
			"a delayed confirmation does not restart a local beam that already faded")
	client.free()
	cleanup()
