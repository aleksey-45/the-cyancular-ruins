extends "res://tests/case.gd"

const NetPlayer := PlayerStateSchema.Network

func run(tree: SceneTree) -> void:
	_local_replay(tree)
	_input_schedule(tree)
	_prediction_limit(tree)
	_position_tolerance(tree)
	_history_window(tree)
	_rewind_and_epoch(tree)
	_rewind_presentation(tree)
	_world_replication(tree)
	_remote_bow(tree)
	_ordered_collision(tree, true)
	_ordered_collision(tree, false)
	_stacked_collision(tree)
	_aligned_step_replay(tree)
	_authority_batch(tree)
	_terrain_replay(tree, true)
	_terrain_replay(tree, false)
	_lethal_hit(tree)
	_remote_down_replay(tree, false)
	_remote_down_replay(tree, true)
	_beam_order(tree)
	_pickup_prompt(tree)
	_combat_prediction(tree)
	_proxy_impulse(tree)
	_remote_auto_fire(tree)
	_late_shot(tree)
	_grenade_prediction(tree)
	_late_blast(tree)
	cleanup()
	await _client_scene(tree)

func _client_scene(tree: SceneTree) -> void:
	const MAP := "res://maps/newfactory.cyrm"
	var mode := PvpSession.MODE_ROYALE
	var options := RoomOptions.normalized(mode, {"max_players": 2, "beta": true})
	var authority := AuthorityWorld.new()
	var problem := authority.setup(mode, MAP, [1, 2], {}, options)
	expect(problem.is_empty(), "the authority creates the client scene's match")
	if not problem.is_empty():
		return
	authority.start_countdown()
	authority._advance_round(3.0)
	var frame := authority.state_for(1, authority.world_state(), authority.time_economy.state_payload())
	var data := {"code": "00000001", "mode": mode, "role": 1, "options": options, "names": {1: "A", 2: "B"},
			"hues": {}, "teams": {}, "map": authority.map_bytes, "sub_hp": {},
			"round_state": authority.round_state().merged({"grace": {}}), "frame": frame}
	var wire := NetCodec.new().encode_event(NetEvent.Kind.BASELINE, data)
	var baseline: Dictionary = NetCodec.new().decode_event(NetEvent.Kind.BASELINE, NetCodec.Reader.new(wire, 1))
	PvpSession.begin_match(baseline, CyrmMap.from_bytes(baseline["map"]))
	var runner := tree.current_scene
	var old := Node.new()
	tree.root.add_child(old)
	tree.current_scene = old
	SceneTransition.change(tree, "res://scenes/pvp_game.tscn")
	var id := ShotRules.shot_id(2, 1)
	var end := {"tick": int(frame["tick"]) + 1, "ids": [id]}
	NetBus.event_received.emit(1, NetEvent.Kind.BULLET_END, end)
	await tree.process_frame
	var client := tree.current_scene as PvpMatchClient
	expect(client._pending_events == [[NetEvent.Kind.BULLET_END, end]] and PvpSession.match_events.is_empty(),
			"the switching scene hands the reliable event after BASELINE to the match exactly once")
	await tree.physics_frame
	await tree.physics_frame
	await tree.process_frame
	expect(client._pending_events.is_empty() and client._rollback.projectile_end_tick(id) == end["tick"],
			"the first client physics step consumes the event received during the scene change")
	expect(client.phase == PvpMatchClient.Phase.ONLINE and client._frame.actors.size() == 2,
			"the real client presents both players from the authority's encoded baseline")
	client._view.pause.set_open(true)
	expect(not tree.paused and client.controls.frozen, "opening the online menu freezes local controls")
	client._view.pause.set_open(false)
	client._go_offline("offline")
	var world_time := client._frame.now
	var remaining := client._view.pvp_hud._remaining
	await tree.process_frame
	await tree.process_frame
	expect(client._frame.now == world_time and client._view.pvp_hud._remaining < remaining,
			"the offline overlay advances its clock while the world frame stays frozen")
	tree.current_scene = runner
	client.free()
	PvpSession.reset()
	PvpSession.room = {}

func _frame(actor: Player, tick: int) -> Dictionary:
	return {"tick": tick, "map_revision": 0,
		"world": {"players": {actor.role: actor.capture_checkpoint()}, "pickups": {}, "projectiles": {}, "beams": {}},
		"time": {}, "input_feedback": PackedByteArray()}

func _saved_frame(rollback: PredictionRollback, at: int) -> Dictionary:
	var saved := rollback._state_at(at)
	var frame := _frame(rollback._player, at)
	frame["world"]["players"] = saved.players.duplicate(true)
	frame["world"]["beams"] = saved.beams.duplicate()
	frame["time"] = saved.accounts.duplicate(true)
	return frame

func _remote(actor: Player, pos: Vector2, hp: int) -> Array:
	var snapshot := actor.capture_checkpoint()
	var state: Array = snapshot[NetPlayer.STATE]
	state[PlayerStateSchema.POS] = pos
	state[PlayerStateSchema.HP] = hp
	return snapshot

func _capture(rollback: PredictionRollback, held: int, pressed: int) -> void:
	rollback.capture([1.0, held, pressed, 0, 0, Vector2.RIGHT])

func _local_replay(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	var shown: Array = []
	rollback.step_advanced.connect(func(_from: Vector2, actions: Array) -> void:
		for action: Dictionary in actions:
			if action["kind"] == "fire":
				shown.append(action["serial"]))
	rollback.reset(_frame(actor, 100), 0)
	rollback.advance(ActorStep.DT)
	var at := rollback.tick
	var snapshot := _saved_frame(rollback, at)
	var equipment_only := snapshot.duplicate(true)
	equipment_only["world"]["players"][actor.role][NetPlayer.STATE][PlayerStateSchema.EQUIPMENT][0] = 0.25
	expect(rollback.reconcile(equipment_only, 0) == PredictionRollback.Correction.SMOOTH
			and (actor.equipped as GunBody).fire_cd_timer == 0.25,
			"an equipment-only difference restores the equipment block")
	rollback.reconcile(snapshot, 0)
	_capture(rollback, ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)
	rollback.advance(ActorStep.DT)
	var predicted := actor.capture_state()
	var endpoint := rollback.tick
	expect(actor.shot_serial == 1, "prediction calls the gun rule for the pending attack")
	snapshot["map_revision"] = 5
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.KEEP
			and actor.capture_state() == predicted and rollback.replay_ticks == 0,
			"a terrain revision with matching simulation state keeps the current prediction")
	var pose_only := snapshot.duplicate(true)
	var pose: Array = pose_only["world"]["players"][actor.role][NetPlayer.STATE]
	pose[PlayerStateSchema.STATE] = Player.DASH
	pose[PlayerStateSchema.STATE_LOCK_TIMER] = 0.5
	expect(rollback.reconcile(pose_only, 0) == PredictionRollback.Correction.KEEP
			and rollback.replay_ticks == 0 and actor.capture_state() == predicted,
			"local animation and pose lock alone do not replay the pending attack")
	var hp := PlayerStateSchema.HP
	var own: Array = snapshot["world"]["players"][actor.role]
	own[NetPlayer.STATE][hp] -= 4
	var mag := actor.equipped.carried
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.SMOOTH
			and rollback.tick == endpoint and rollback.replay_ticks == endpoint - at,
			"a local HP difference replays exactly the unconfirmed suffix")
	expect(actor.sim_hp == own[NetPlayer.STATE][hp] and actor.shot_serial == 1
			and actor.equipped.carried == mag and shown == [1],
			"the pending attack survives replay and only spends one round and shows once")
	own[NetPlayer.ACTION_ACK] = rollback.sequence
	expect(rollback.reconcile(snapshot, 0) == PredictionRollback.Correction.SMOOTH
			and actor.shot_serial == 0 and actor.equipped.carried == mag + 1,
			"an acknowledged action cannot execute again, even when its input frame is still pending")
	cleanup()

func _input_schedule(tree: SceneTree) -> void:
	var actor := player(world(tree))
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	var baseline := _frame(actor, 100)
	rollback.reset(baseline, 0)
	var codec := NetCodec.new()
	for n in range(1, 6):
		_capture(rollback, 0, ActorInput.BIT_UP if n == 5 else 0)
		rollback.advance(ActorStep.DT)
	var first: Array = rollback.history.back().duplicate()
	var first_edge: Array = rollback.actions.back().duplicate()
	var correction := _saved_frame(rollback, 103)
	var scheduler := InputScheduler.new()
	scheduler.submit(InputBuffer.new(), [[[3, 1, 99, 0.0, 0, Vector2.RIGHT]], []], 97)
	correction["input_feedback"] = scheduler.feedback
	expect(rollback.reconcile(correction, 0) == PredictionRollback.Correction.KEEP and rollback.replay_ticks == 0,
			"an older estimate changes only future clock decisions, without a schedule rollback")
	var decoded := codec.decode_input(NetCodec.Reader.new(codec.encode_input(rollback.packet()), 1))
	expect(decoded[0].back() == first and decoded[1].back() == first_edge
			and first[InputBuffer.TARGET_TICK] == rollback.tick and actor.input_buffer.action_ack == 5,
			"prediction, replays and every retransmission share the original tick")
	rollback.reset(correction, 50)
	expect(rollback.sequence == 5 and rollback.history.back() == first,
			"a same-epoch baseline cannot recycle an unacknowledged sequence or its commitment")
	_capture(rollback, 0, 0)
	rollback.advance(ActorStep.DT)
	expect(rollback.sequence == 6 and rollback.history.back()[InputBuffer.TARGET_TICK] >= first[InputBuffer.TARGET_TICK],
			"prediction resumes after a same-epoch baseline without reassigning old input")
	cleanup()

func _prediction_limit(tree: SceneTree) -> void:
	var actor := player(world(tree))
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	rollback.reset(_frame(actor, 100), 0)
	var edge_tick := 0
	for seq in range(1, 61):
		_capture(rollback, 0, ActorInput.BIT_UP if seq == 41 else 0)
		rollback.advance(ActorStep.DT)
		if seq == 41:
			edge_tick = rollback.actions.back()[InputBuffer.TARGET_TICK]
	expect(rollback.tick == 100 + PredictionRollback.MAX_REPLAY and edge_tick > rollback.tick,
			"a downstream stall caps local simulation while new inputs retain their future commitments")
	var resumed := _frame(actor, rollback.tick + 4)
	rollback.reconcile(resumed, 0)
	_capture(rollback, 0, 0)
	rollback.advance(ActorStep.DT)
	var before := rollback._state_at(edge_tick - 1)
	var after := rollback._state_at(edge_tick)
	expect(before != null and after != null and before.players[actor.role][NetPlayer.ACTION_ACK] == 0
			and after.players[actor.role][NetPlayer.ACTION_ACK] == 41,
			"catch-up from the new authority checkpoint uses the original edge tick outside the outgoing redundancy window")
	cleanup()

func _position_tolerance(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 8, 8, {})
	var local := player(parent)
	var remote := player(parent, 2)
	local.position.x = 0.02
	var combat := parent.combat
	var rollback := PredictionRollback.new()
	rollback.bind(local)
	combat.players[remote.role] = remote
	var baseline := _frame(local, 100)
	baseline["world"]["players"][remote.role] = remote.capture_checkpoint()
	rollback.reset(baseline, 0)
	rollback._step()
	rollback._step()
	var endpoint := local.capture_state()
	var near := _saved_frame(rollback, 101)
	var pos := PlayerStateSchema.POS
	var local_state: Array = near["world"]["players"][local.role][NetPlayer.STATE]
	var remote_state: Array = near["world"]["players"][remote.role][NetPlayer.STATE]
	local_state[pos] = Vector2(_terrain.map_size.x - 0.02, local_state[pos].y)
	remote_state[pos] += Vector2(0.05, 0.05)
	expect(rollback.reconcile(near, 0) == PredictionRollback.Correction.KEEP
			and rollback.replay_ticks == 0 and local.capture_state() == endpoint,
			"sub-0.1px local seam drift and remote drift do not replay")
	var far := _saved_frame(rollback, 101)
	far["world"]["players"][remote.role][NetPlayer.STATE][pos] += Vector2(0.08, 0.08)
	rollback.reconcile(far, 0)
	expect(rollback.replay_ticks == 1, "the remote position threshold uses distance rather than per-axis tolerances")
	var damaged := _saved_frame(rollback, 101)
	var actor: Array = damaged["world"]["players"][local.role][NetPlayer.STATE]
	actor[pos] += Vector2(0.05, 0.0)
	actor[PlayerStateSchema.HP] -= 1
	expect(rollback.reconcile(damaged, 0) == PredictionRollback.Correction.SMOOTH
			and rollback.replay_ticks == 1 and local.sim_hp == actor[PlayerStateSchema.HP],
			"a small position difference still allows health to trigger replay")
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
	rollback.bind(actor)
	rollback.time_economy = TimeEconomy.new({}, [actor.role])
	var baseline := _frame(actor, 100)
	baseline["time"] = rollback.time_economy.state_payload()
	rollback.reset(baseline, 0)
	rollback.advance(ActorStep.DT)
	var authority := _saved_frame(rollback, rollback.tick - 1)
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.KEEP,
			"a matching Beta account keeps the current prediction")
	authority["time"][actor.role][GrainAccount.BALANCE] *= 0.5
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.SMOOTH,
			"the local Beta account can trigger a replay")
	_capture(rollback, ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)
	authority = _saved_frame(rollback, rollback.tick)
	authority["world"]["players"][actor.role][NetPlayer.REWIND] = true
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.SNAP and actor.rewinding,
			"gameplay rewind follows the authority snapshot")
	var at := rollback.tick
	rollback.advance(2.0 * ActorStep.DT)
	expect(rollback.tick == at and actor.shot_serial == 0, "local input does not advance the rewinding actor")
	authority["tick"] += 1
	authority["world"]["players"][actor.role][NetPlayer.EPOCH] += 1
	authority["world"]["players"][actor.role][NetPlayer.REWIND] = false
	expect(rollback.reconcile(authority, 0) == PredictionRollback.Correction.SNAP
			and not actor.rewinding and rollback.packet()[InputBuffer.PACKET_ACTIONS].is_empty(),
			"the new control epoch drops edges from before gameplay rewind")
	rollback.advance(ActorStep.DT)
	expect(actor.shot_serial == 0 and rollback.tick > at, "prediction resumes without firing an old action")
	cleanup()

func _rewind_presentation(tree: SceneTree) -> void:
	var client_map := world_with_walls(tree, 16, 16, {})
	var actor := player(client_map)
	actor.position = Vector2(40, 360)
	var client := detached_client(actor)
	client.phase = PvpMatchClient.Phase.ONLINE
	client._rollback.step_advanced.connect(client._live_step)
	client._local_motion.correct(actor.transform, actor.position, _terrain.map_size, true)
	client._rollback.reset(_frame(actor, 100), 0)
	var rewind := _frame(actor, 102)
	var own: Array = rewind["world"]["players"][actor.role]
	var destination := Vector2(_terrain.map_size.x - 20, 360)
	own[NetPlayer.STATE][PlayerStateSchema.POS] = destination
	own[NetPlayer.REWIND] = true
	client._on_state(rewind)
	client._physics_process(ActorStep.DT)
	var starting := GridPathfinder.wrap_to_range(client._local_motion.shown(actor.transform), _terrain.map_size)
	expect(actor.position == destination and starting.is_equal_approx(Vector2(40, 360)),
			"authority restores the body immediately while rewind keeps the last visible pose")
	client._local_motion.advance(ActorStep.DT, 1.0, actor.transform, _terrain.map_size)
	var shown := GridPathfinder.wrap_to_range(client._local_motion.shown(actor.transform), _terrain.map_size)
	expect(shown.is_equal_approx(Vector2(20, 360)), "the first rendered rewind step goes smoothly across the seam")
	var exit := _frame(actor, 104)
	own = exit["world"]["players"][actor.role]
	own[NetPlayer.REWIND] = false
	own[NetPlayer.EPOCH] += 1
	own[NetPlayer.STATE][PlayerStateSchema.VEL] = Vector2(900, 0)
	client._on_state(exit)
	client._physics_process(ActorStep.DT)
	expect(actor.position != destination and not actor.rewinding
			and GridPathfinder.wrap_to_range(client._local_motion.shown(actor.transform), _terrain.map_size).is_equal_approx(shown),
			"resuming prediction on release keeps the last visible rewind pose")
	client._local_motion.advance(0.05, 0.0, actor.transform, _terrain.map_size)
	expect(client._local_motion.shown(actor.transform).is_equal_approx(actor.position), "rewind smoothing settles at the simulated position")
	client.free()
	cleanup()

func _world_replication(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent)
	var client := detached_client(actor)
	client._teams = {2: 2}
	var rollback := client._rollback
	var combat := parent.combat
	var remote := _remote(actor, Vector2(10, 512), 100)
	remote[NetPlayer.STATE][PlayerStateSchema.KNOCK_VEL] = Vector2(-600, 0)
	var frame := _frame(actor, 100)
	frame["world"]["players"][2] = remote
	client._install_world(frame)
	rollback.reset(frame, 0)
	var proxy: Player = combat.players[2]
	var physics := proxy.terrain.physics
	var mask := CollisionWorld.LAYER_TEAM_B
	var seam_x := 10.0 + _terrain.map_size.x
	expect(not physics.ray_hit(Vector2(seam_x, 400), Vector2(seam_x, 650), mask).is_empty()
			and proxy.collision_mask == (CollisionWorld.LAYER_TERRAIN | CollisionWorld.LAYER_ENEMY),
			"the default proxy exposes a team hitbox across the map seam")
	for i in 2:
		rollback._step()
	var visible: Vector2 = client._playback.sample(106)["players"][2][SnapshotBuffer.Sample.POS]
	expect(is_equal_approx(proxy.position.x, visible.x) and proxy.position.y > visible.y,
			"visual extrapolation stops after two ticks of decaying knockback")
	for i in 4:
		rollback._step()
	var projected := proxy.position
	expect(projected.x < visible.x and projected.y > visible.y
			and not physics.ray_hit(projected - Vector2(0, 80), projected + Vector2(0, 80), mask).is_empty(),
			"the collider applies gravity and projects decaying knockback across the seam")
	rollback._step()
	expect(proxy.position == projected, "the collision forecast stops after six ticks")
	frame = _saved_frame(rollback, 106)
	client._install_world(frame)
	expect(rollback.reconcile(frame, 0) == PredictionRollback.Correction.KEEP
			and rollback.replay_ticks == 1 and proxy.position.x < projected.x,
			"a matching newer snapshot extends the previously capped forecast")
	var height := proxy.collision_rect().size.y
	frame = _saved_frame(rollback, 107)
	remote = frame["world"]["players"][2]
	remote[NetPlayer.STATE][PlayerStateSchema.POS] = Vector2(512, 512)
	remote[NetPlayer.STATE][PlayerStateSchema.SQUAT] = true
	remote[NetPlayer.REWIND] = true
	client._install_world(frame)
	var correction := rollback.reconcile(frame, 0)
	rollback._step()
	expect(correction == PredictionRollback.Correction.KEEP and proxy.rewinding
			and proxy.position == Vector2(512, 512) and proxy.collision_rect().size.y < height,
			"an authority snapshot restores position and crouch even if local state matches, and rewind freezes motion")
	expect(physics.ray_hit(Vector2(seam_x, 400), Vector2(seam_x, 650), mask).is_empty(),
			"moving the proxy inland removes its seam collision")
	frame = _saved_frame(rollback, 108)
	remote = frame["world"]["players"][2]
	remote[NetPlayer.REWIND] = false
	remote[NetPlayer.RESPAWN_TICK] = 110
	var state: Array = remote[NetPlayer.STATE]
	state[PlayerStateSchema.VEL] = Vector2.ZERO
	state[PlayerStateSchema.KNOCK_VEL] = Vector2.ZERO
	state[PlayerStateSchema.DOWNED] = true
	client._install_world(frame)
	rollback.reconcile(frame, 0)
	rollback._step()
	expect(proxy.collision_layer == mask, "the downed proxy keeps its hitbox until the respawn tick")
	var before_respawn := _saved_frame(rollback, 109)
	rollback._step()
	expect(proxy.collision_layer == 0 and physics.ray_hit(Vector2(512, 400), Vector2(512, 650), mask).is_empty(),
			"forward prediction releases the downed proxy at the end of the respawn tick")
	before_respawn["world"]["players"][actor.role][NetPlayer.STATE][PlayerStateSchema.HP] -= 1
	client._install_world(before_respawn)
	expect(rollback.reconcile(before_respawn, 0) == PredictionRollback.Correction.SMOOTH
			and proxy.collision_layer == 0 and rollback.replay_ticks == 1,
			"replay restores the downed proxy before crossing the respawn tick again")
	frame = _saved_frame(rollback, 110)
	frame["world"]["players"][2][NetPlayer.RESPAWN_TICK] = 0
	client._install_world(frame)
	rollback.reconcile(frame, 0)
	expect(not physics.ray_hit(Vector2(512, 400), Vector2(512, 650), mask).is_empty()
			and proxy.collision_mask == (CollisionWorld.LAYER_TERRAIN | CollisionWorld.LAYER_ENEMY),
			"restoring a hitbox after the due tick preserves the no-blocking movement mask")
	rollback._step()
	frame = _saved_frame(rollback, 111)
	state = frame["world"]["players"][2][NetPlayer.STATE]
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
	var projectile := [WeaponRegistry.Type.GRENADE, Vector2(800, 544), Vector2(180, 0)]
	client._playback.reset()
	client._playback.push(100, {"players": {}})
	var shot := {"serial": 1, "type_id": projectile[BulletBody.Network.TYPE], "pos": projectile[BulletBody.Network.POS],
		"dir": Vector2.RIGHT, "charge": 1.0, "speed_mult": 1.0, "role": actor.role, "tick": 102}
	combat.fire(actor, shot)
	combat.step_projectiles(ActorStep.DT)
	client._present_projectiles(ActorStep.DT, client._local_motion.shown(actor.transform))
	var preview := client._projectiles[id]
	expect(preview.predicted and preview._target == combat.projectiles[id].position
			and preview._target != projectile[BulletBody.Network.POS], "the local projectile view uses the predicted physics body")
	client._apply_event(NetEvent.Kind.FIRE, shot)
	expect(client._projectiles[id] == preview and not preview.predicted,
			"a reliable spawn takes over the existing projectile view")
	client._sync_projectiles({})
	expect(client._projectiles.get(id) == preview, "an older STATE preserves a newer reliable spawn")
	var shot_pos: Vector2 = projectile[BulletBody.Network.POS]
	var shot_vel: Vector2 = projectile[BulletBody.Network.VEL]
	preview.present(ActorStep.DT, shot_pos)
	preview.sample(104, shot_pos - Vector2(320, 0), shot_vel, true)
	preview.present(ActorStep.DT, shot_pos)
	expect(preview.position.is_equal_approx(shot_pos - Vector2(160, 0)),
			"a live projectile interpolates a large backward step on entering rewind")
	preview.present(0.1, shot_pos)
	expect(preview.position.is_equal_approx(shot_pos - Vector2(320, 0)),
			"a rewinding projectile holds after reaching its last known position")
	preview.sample(106, shot_pos, shot_vel, false)
	preview.present(ActorStep.DT, shot_pos)
	expect(preview.position.is_equal_approx(shot_pos - Vector2(160, 0)),
			"a live projectile also interpolates on leaving rewind")
	client._apply_event(NetEvent.Kind.BULLET_END, {"tick": 102, "ids": [id]})
	client._apply_event(NetEvent.Kind.FIRE, shot)
	client._playback.push(101, {"players": {}})
	client._sync_projectiles({id: projectile})
	expect(client._projectiles.is_empty(), "an older STATE cannot revive a projectile ended by a reliable event")
	client._playback.push(103, {"players": {}})
	client._sync_projectiles({})
	client._apply_event(NetEvent.Kind.FIRE, shot)
	expect(client._projectiles.is_empty(),
			"a newer complete snapshot discards obsolete projectile events")
	client.free()
	cleanup()

func _remote_bow(tree: SceneTree) -> void:
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent)
	var remote := player(parent, 2)
	remote.weapons.set_initial_inventory([WeaponRegistry.Type.COMPOUND_BOW])
	ActorStep.step(remote, [0.0, ActorInput.BIT_ATTACK, 0, 0, 0, Vector2.RIGHT], 0.375)
	var client := detached_client(actor)
	var baseline := _frame(actor, 100)
	baseline["world"]["players"][remote.role] = remote.capture_checkpoint()
	client._install_world(baseline)
	client._rollback.reset(baseline, 0)
	var samples: Dictionary = client._playback.sample(100.0, actor.role)["players"]
	client._sample_remotes(samples, actor.position)
	expect(is_equal_approx(client._frame.actors[0].bow_draw, 0.5), "a remote snapshot shows the held bow's charge")
	var requests := ActorStep.step(remote, [0.0, 0, 0, ActorInput.BIT_ATTACK, 0, Vector2.RIGHT])
	var shot: Dictionary = requests[0]
	shot.merge({"role": remote.role, "tick": 101})
	var id := ShotRules.shot_id(remote.role, shot["serial"])
	client._apply_event(NetEvent.Kind.FIRE, shot)
	client._frame.begin(0.0, actor.position)
	client._sample_remotes(samples, actor.position)
	expect(client._projectiles.has(id) and client._frame.actors[0].bow_draw < 0.0,
			"a remote arrow already in flight clears the older held arrow")
	client._apply_event(NetEvent.Kind.BULLET_END, {"tick": 101, "ids": [id]})
	client._frame.begin(0.0, actor.position)
	client._sample_remotes(samples, actor.position)
	expect(not client._projectiles.has(id) and client._frame.actors[0].bow_draw < 0.0,
			"the old held arrow does not reappear when a remote projectile ends before the next snapshot")
	client.free()
	cleanup()

func _ordered_collision(tree: SceneTree, enabled: bool) -> void:
	# 让两名角色迎面相撞，比较服务器模拟和客户端预测得到的位置。
	var parent := world(tree)
	var authority := AuthorityWorld.new()
	authority.terrain = _terrain
	authority.combat_rules = parent.combat

	authority.rules.phase = NetEvent.RoundState.PLAYING
	authority.combat_rules.tick = 1492
	for role: int in [5, 1]:
		var actor := player(parent, role)
		actor.set_team_collision(0, enabled)
		actor.position = Vector2(200.0 if role == 1 else 284.2959, 134.999)
		actor.velocity.x = 2092.2432 if role == 1 else -630.2997
		actor.personal_haste_mult = 3.0 if role == 1 else 1.0
		actor._grounded = true
		actor.sync_collision_geometry()
		actor.input_buffer.restore_authority(1, 0, [1, 1, 1492, 1.0 if role == 1 else -1.0, 0, Vector2.RIGHT])

	var baseline := authority.world_state()
	var anchors := {1: authority.state_for(1, baseline, {}), 5: authority.state_for(5, baseline, {})}
	authority.step()
	for local_role: int in [1, 5]:
		var client_world := world(tree)
		var actor := player(client_world, local_role)
		actor.set_team_collision(0, enabled)
		var client := detached_client(actor)
		client._player_collision = enabled
		var rollback := client._rollback
		client._install_world(anchors[local_role])
		rollback.reset(anchors[local_role], 0)
		rollback._step()
		for role: int in authority.players:
			var body: Player = rollback.combat.players[role]
			var expected: Player = authority.players[role]
			expect(absf(body.position.x - expected.position.x) <= CollisionWorld.MOTION_MARGIN
					and body.velocity.x == expected.velocity.x and (body.velocity.x == 0.0) == enabled,
					"role %d with local %d follows authority with player collision %s" % [role, local_role, enabled])
		for i in 5:
			rollback._step()
		var endpoint := rollback._state_at(1498)
		if not enabled:
			expect(rollback.combat.players[1].position.x > rollback.combat.players[5].position.x,
					"both players cross when blocking is disabled")
		rollback._request_replay(1493)
		expect(rollback.reconcile({}, 0) == PredictionRollback.Correction.KEEP and rollback.replay_ticks == 6
				and rollback._state_at(1498).players == endpoint.players,
				"replaying the same ordered collision gives the same local and proxy states")
		client.free()
	cleanup()

func _stacked_collision(tree: SceneTree) -> void:
	# 两个角色上下相叠。应用服务器快照后，上方角色仍站在另一名角色身上，下方角色仍站在地面上。
	var map := CyrmMap.load_file("res://maps/newfactory.cyrm")
	var parent := _install_world(tree, map)
	var upper := player(parent, 2)
	var lower := player(parent, 6)
	upper.position = Vector2(6586.07763671875, 5532.1279296875)
	upper.velocity.x = -170.765701293945
	lower.position = Vector2(6588.923828125, 5639.1298828125)
	lower.personal_haste_mult = 3.0
	for actor: Player in [upper, lower]:
		actor.set_team_collision(0, true)
		actor._grounded = true
		actor.sync_collision_geometry()
		actor.input_buffer.restore_authority(1, 0, [1, 1, 2132, -1.0, 0, Vector2.LEFT])
	var frame := _frame(lower, 2132)
	frame["world"]["players"][2] = upper.capture_checkpoint()
	var codec := NetCodec.new()
	var wire := codec.encode_state(frame, NetCodec.StateBatch.new(frame))
	frame = NetCodec.new().decode_state(NetCodec.Reader.new(wire, 1))
	var client_map := _install_world(tree, map)
	var local := player(client_map, 6)
	local.set_team_collision(0, true)
	var client := detached_client(local)
	client._player_collision = true
	var rollback := client._rollback
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
		authority.combat_rules = parent.combat

		authority.rules.phase = NetEvent.RoundState.PLAYING
		authority.combat_rules.tick = 100
		var frame := authority.state_for(runner.role, authority.world_state(), {})
		var codec := NetCodec.new()
		var wire := codec.encode_state(frame, NetCodec.StateBatch.new(frame))

		var client_world := _aligned_step_world(tree, height, true)
		var local := player(client_world)
		var rollback := PredictionRollback.new()
		rollback.bind(local)
		rollback.reset(NetCodec.new().decode_state(NetCodec.Reader.new(wire, 1)), 0)
		for at in range(101, 105):
			authority.step()
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
		cleanup()

func _aligned_step_world(tree: SceneTree, height: int, reverse_order: bool) -> TestWorld:
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
	var actor := player(parent)
	var terrain := _terrain
	var client := detached_client(actor)
	client.phase = PvpMatchClient.Phase.ONLINE
	client._rollback.reset(_frame(actor, 100), 0)
	client._playback.reset()
	client._playback.push(100, {"players": {}})
	client._rollback.advance(3.0 * ActorStep.DT)
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
	expect(client._playback.latest_tick == 101 and client._pending_states.size() == 1,
			"the newest STATE with an installed revision is used while a newer revision waits")
	client._on_event(1, NetEvent.Kind.TERRAIN, {"tick": 102, "revision": 1, "cells": {sub: initial_hp - 1}})
	var hit := {"shooter": 2, "victim": actor.role, "damage": 3, "tick": 102, "epoch": 1,
			"hp": actor.sim_hp - 3, "impulse_mode": 1, "knock": Vector2(600, 0)}
	client._on_event(1, NetEvent.Kind.HIT, hit)
	client._apply_pending_authority()
	var hp := PlayerStateSchema.HP
	var pos := PlayerStateSchema.POS
	expect(terrain.get_hp(sub) == initial_hp - 1 and client._playback.latest_tick == 101
			and actor.sim_hp == before[hp] - 3 and actor.position.x > before[pos].x
			and client._rollback.tick == endpoint, "a late HIT replays confirmed knockback while STATE waits for terrain")
	var at_hit: Array = client._rollback._state_at(102).players[actor.role][NetPlayer.STATE]
	expect(at_hit[pos] == wait["world"]["players"][actor.role][NetPlayer.STATE][pos]
			and at_hit[PlayerStateSchema.KNOCK_VEL] == hit["knock"],
			"a hit after movement changes the velocity at its tick and the position from the next tick")
	var newest := _saved_frame(client._rollback, 103)
	newest["map_revision"] = 2
	var after := actor.capture_state()
	client._on_state(newest)
	client._on_state(wait)
	client._on_event(1, NetEvent.Kind.TERRAIN, {"tick": 102, "revision": 2, "cells": {sub: 0}})
	client._apply_pending_authority()
	expect(client._playback.latest_tick == 103 and client._pending_states.is_empty() and terrain.get_hp(sub) == 0,
			"the matching patch makes only the newest waiting STATE installable")
	var replayed := client._rollback.replay_ticks
	client._on_event(1, NetEvent.Kind.HIT, hit)
	client._apply_pending_authority()
	expect(actor.capture_state() == after and client._rollback._hits.is_empty()
			and client._rollback.replay_ticks == replayed, "a STATE covering a hit replaces it without applying the impulse twice")
	for index in PredictionRollback.KEEP + 1:
		_capture(client._rollback, 0, 0)
	client._on_event(1, NetEvent.Kind.HIT, hit.merged({"tick": endpoint}, true))
	client._apply_pending_authority()
	expect(actor.capture_state() == after and client._rollback._hits.has(endpoint),
			"a late HIT waits for STATE once the required input history has been overwritten")
	client.free()
	cleanup()

func _terrain_replay(tree: SceneTree, with_state: bool) -> void:
	const BREAK_TICK := 101
	const WALL_X := 32
	var parent := world_from_solid(tree, 64, 48, func(x: int, y: int) -> bool:
		return y == 24 or (x == WALL_X and y >= 10 and y < 24))
	var actor := player(parent)
	actor.position = Vector2(475.5, 326.999)
	actor.velocity = Vector2(PlayerParams.move_speed, 0.0)
	actor.input_buffer.restore_authority(1, 0, [1, 1, BREAK_TICK - 2, 1.0, 0, Vector2.RIGHT])
	actor.sync_collision_geometry()
	var client := detached_client(actor)
	client.phase = PvpMatchClient.Phase.ONLINE
	var rollback := client._rollback
	var baseline := _frame(actor, BREAK_TICK - 2)
	client._install_world(baseline)
	rollback.reset(baseline, 0)
	for index in 3:
		_capture(rollback, 0, 0)
		rollback.advance(ActorStep.DT)
	var blocked: Vector2 = rollback._state_at(BREAK_TICK).players[actor.role][NetPlayer.STATE][PlayerStateSchema.POS]
	var endpoint := actor.position
	if with_state:
		var old := _saved_frame(rollback, BREAK_TICK - 1)
		old["world"]["players"][actor.role][NetPlayer.STATE][PlayerStateSchema.HP] -= 1
		client._on_state(old)
	var cells := {}
	for y in range(10, 24):
		cells[Vector2i(WALL_X, y)] = 0
	client._on_event(1, NetEvent.Kind.TERRAIN, {"tick": BREAK_TICK, "revision": cells.size(), "cells": cells})
	client._apply_pending_authority()
	var replayed: Vector2 = rollback._state_at(BREAK_TICK).players[actor.role][NetPlayer.STATE][PlayerStateSchema.POS]
	expect(replayed.is_equal_approx(blocked), "movement still collides with the wall in the frame that breaks it")
	expect(actor.position.x > endpoint.x and rollback.replay_ticks > 0,
			"a terrain patch replays movement after the break even without a new STATE")
	if with_state:
		var ahead := rollback.tick + 3
		var floor := {}
		for x in range(WALL_X - 5, WALL_X + 6):
			floor[Vector2i(x, 24)] = 0
		client._on_event(1, NetEvent.Kind.TERRAIN, {"tick": ahead, "revision": cells.size() + floor.size(), "cells": floor})
		for i in 2:
			client._physics_process(ActorStep.DT)
		expect(rollback.tick < ahead and actor._grounded and _terrain.get_hp(Vector2i(WALL_X, 24)) > 0,
				"a future patch leaves the floor intact until its frame")
		rollback._step()
		expect(rollback.tick == ahead and actor._grounded and _terrain.get_hp(Vector2i(WALL_X, 24)) == 0,
				"the floor breaks after movement in the frame that owns the patch")
	client.free()
	cleanup()

func _lethal_hit(tree: SceneTree) -> void:
	var actor := player(world(tree))
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	rollback.reset(_frame(actor, 100), 0)
	rollback.queue_event(NetEvent.Kind.HIT, {"tick": 102, "epoch": 1, "victim": actor.role, "hp": 0,
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
	fresh["world"]["players"][actor.role][NetPlayer.EPOCH] = 2
	rollback.reconcile(fresh, 0)
	rollback.queue_event(NetEvent.Kind.HIT, {"tick": 105, "epoch": 1, "victim": actor.role})
	expect(rollback._hits.is_empty(), "a hit from an older epoch cannot move the new actor")
	cleanup()

func _remote_down_replay(tree: SceneTree, with_state: bool) -> void:
	var client_map := world_with_walls(tree, 8, 8, {})
	var actor := player(client_map, 2)
	# 击退方向经过远程角色所在位置。对方站立时会挡住本地角色，倒地后留出的空间足以通过。
	actor.position = Vector2(360, 290)
	actor.collision_mask = CollisionWorld.LAYER_TERRAIN | CollisionWorld.LAYER_TEAM_A
	actor.sync_collision_geometry()
	var client := detached_client(actor)
	client.phase = PvpMatchClient.Phase.ONLINE
	client._player_collision = true
	var rollback := client._rollback
	var baseline := _frame(actor, 100)
	var remote_pos := Vector2(240.075, 390.999)
	baseline["world"]["players"][3] = _remote(actor, remote_pos, 4)
	client._install_world(baseline)
	rollback.reset(baseline, 0)
	rollback.advance(3.0 * ActorStep.DT)
	var endpoint := rollback.tick
	var hit := {"shooter": 3, "victim": 2, "damage": 35, "tick": 102, "epoch": 1, "hp": 10,
			"impulse_mode": 1, "knock": Vector2(-2970.7, -418.37)}
	var down := hit.merged({"victim": 3, "hp": -31, "pos": remote_pos, "facing": -1,
			"vel": Vector2.ZERO, "knock": Vector2(2951.45, -537.55)}, true)
	client._on_event(1, NetEvent.Kind.HIT, hit)
	client._apply_pending_authority()
	expect(rollback._state_at(103).players[actor.role][NetPlayer.STATE][PlayerStateSchema.KNOCK_VEL].x == 0.0,
			"the standing hull blocks this knockback")
	client._on_event(1, NetEvent.Kind.HIT, down)
	if with_state:
		var state := _saved_frame(rollback, 102)
		var downed: Array = state["world"]["players"][3][NetPlayer.STATE]
		downed[PlayerStateSchema.DOWNED] = true
		downed[PlayerStateSchema.GROUNDED] = false
		downed[PlayerStateSchema.HP] = down["hp"]
		downed[PlayerStateSchema.FACING] = down["facing"]
		downed[PlayerStateSchema.KNOCK_VEL] = down["knock"]
		client._on_state(state)
	client._apply_pending_authority()
	var proxy: Player = rollback.combat.players[3]
	expect(proxy.sim_downed and proxy.position != remote_pos,
			"a confirmed down updates the remote hull and moves it on the following ticks")
	var at_contact: Array = rollback._state_at(103).players[actor.role][NetPlayer.STATE]
	expect(at_contact[PlayerStateSchema.KNOCK_VEL].x < 0.0 and actor.sim_hp == 10
			and rollback.replay_ticks == endpoint - (102 if with_state else 100),
			"the confirmed down replays movement from the next tick and clears the lower hull")
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
	var actor := player(parent)
	actor.gravity = 0.0
	actor.position = Vector2(125, 531.5)
	actor.sync_collision_geometry()
	actor.weapons.set_initial_inventory([WeaponRegistry.Type.LASER])
	var remote := player(parent, 2)
	var client := PvpMatchClient.new()
	client.phase = PvpMatchClient.Phase.ONLINE
	client.player = actor
	client.combat_rules = actor.combat
	client.terrain = _terrain
	client._view = preload("res://scenes/match_view.tscn").instantiate()
	parent.add_child(client._view)
	client._camera = client._view.camera
	client.map = _document
	client._mount(MatchFrame.Mode.DUEL, null)
	var canvas: WorldCanvas = client._view.get_node("WorldViewport/Canvas")
	var rollback := client._rollback
	rollback.bind(actor)
	rollback.step_advanced.connect(client._live_step)
	var baseline := _frame(actor, 100)
	baseline["world"]["players"][remote.role] = remote.capture_checkpoint()
	client._playback.map_px = _terrain.map_size
	client._install_world(baseline)
	rollback.reset(baseline, 0)
	rollback.capture([0.0, ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK, 0, 0, Vector2.RIGHT])
	rollback.advance(ActorStep.DT)
	client._process(0.0)
	var id := ShotRules.shot_id(actor.role, 1)
	var shot: Dictionary = rollback._state_at(rollback.tick).shots[id].duplicate()
	var reflected: PackedVector2Array = shot["vectors"]
	var deadline: int = actor.combat.beams[id][CombatSimulator.Beam.END_TICK]
	expect(reflected.size() >= 3 and canvas._lines.size() == 2 and canvas._lines[0][0] == reflected,
			"the first render draws the predicted reflected path before authority")
	shot.erase("vectors")
	shot.erase("trace")
	var break_tick: int = shot["tick"] - 1
	var remote_shot := shot.merged({"role": remote.role, "tick": break_tick}, true)
	var patch := {}
	for y in 4:
		for x in 4:
			patch[cell * 4 + Vector2i(x, y)] = 0
	client._on_event(1, NetEvent.Kind.FIRE, remote_shot)
	client._on_event(1, NetEvent.Kind.TERRAIN, {"tick": break_tick, "revision": _terrain.revision + 1, "cells": patch})
	client._on_event(1, NetEvent.Kind.FIRE, shot)
	client._apply_pending_authority()
	client._process(0.0)
	var remote_id := ShotRules.shot_id(remote.role, 1)
	var straight: PackedVector2Array = actor.combat.beams[id][CombatSimulator.Beam.POINTS]
	expect(actor.combat.beams[remote_id][CombatSimulator.Beam.POINTS] == reflected and straight.size() == 2,
			"replay preserves the paths resolved before and after the terrain change")
	expect(actor.combat.beams[id][CombatSimulator.Beam.END_TICK] == deadline
			and canvas._lines.size() == 2 and canvas._lines[0][0] == straight,
			"the corrected local beam replaces the old drawing without restarting its lifetime")

	var confirmed := _saved_frame(rollback, rollback.tick)
	confirmed["map_revision"] = _terrain.revision
	confirmed["world"]["beams"].erase(id)
	client._on_state(confirmed)
	client._apply_pending_authority()
	client._process(0.0)
	expect(actor.shot_serial == 1 and not actor.combat.beams.has(id) and canvas._lines.is_empty(),
			"a beam-only snapshot difference removes the rendering even with the same shot serial")
	while rollback.tick <= deadline:
		rollback._step()
	client._playback.render_tick = confirmed["tick"]
	client._process(0.0)
	expect(actor.combat.beams.is_empty() and canvas._lines.size() == 2 and canvas._lines[0][0] == reflected,
			"a remote beam follows its shooter's snapshot clock even after it expires on the prediction clock")

	var expired := _saved_frame(rollback, rollback.tick)
	expired["map_revision"] = _terrain.revision
	client._on_state(expired)
	client._apply_pending_authority()
	client._on_event(1, NetEvent.Kind.FIRE, remote_shot)
	client._apply_pending_authority()
	client._playback.render_tick = expired["tick"]
	client._process(0.0)
	expect(actor.combat.beams.is_empty() and canvas._lines.is_empty(), "a late FIRE cannot revive an expired beam")
	rollback.reset(confirmed, 0)
	expect(actor.combat.beams == confirmed["world"]["beams"] and actor.combat.beams.has(remote_id),
			"joining during a beam restores its path and deadline from the baseline alone")
	client.free()
	cleanup()

func _pickup_prompt(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent, 2)
	actor.weapons.enabled_types = [WeaponRegistry.Type.PISTOL]
	var client := detached_client(actor)
	var at := actor.position
	const TICK := 65535
	var pickups := {1: [at, Vector2.ZERO, WeaponRegistry.Type.PISTOL, 2, TICK + 1],
		2: [at, Vector2.ZERO, WeaponRegistry.Type.PISTOL, 1, TICK + 1],
		3: [at, Vector2.ZERO, WeaponRegistry.Type.RIFLE, 0, 0]}
	client._playback.push(TICK, {"pickups": pickups})
	client._draw_pickups(pickups)
	expect(not client._frame.pickups[0][2] and client._frame.pickups[1][2] and not client._frame.pickups[2][2],
			"the prompt honors the owner lock and enabled weapons")
	client._frame.pickups.clear()
	client._playback.push(TICK + 1, {"pickups": pickups})
	client._draw_pickups(pickups)
	expect(client._frame.pickups[0][2], "the owner's pickup prompt appears at the full server tick deadline")
	client.free()
	cleanup()

func _combat_prediction(tree: SceneTree) -> void:
	const MELEE := 9
	WeaponRegistry._definitions[MELEE] = WeaponRegistry.DEFAULTS.merged({
		"attack": WeaponRegistry.Attack.MELEE, "range": 80.0, "hit_radius": 4.0, "damage": 10, "impact": 350.0}, true)
	for type_id: int in [WeaponRegistry.Type.LASER, WeaponRegistry.Type.PISTOL, MELEE]:
		var parent := world_with_walls(tree, 16, 16, {})
		var actor := player(parent, 2)
		actor.position = Vector2(325, 544)
		actor.sim_hp = 1
		actor.sync_collision_geometry()
		var proxy := player(parent, 1)
		proxy.position = Vector2(200, 544)
		proxy.sync_collision_geometry()
		var combat := parent.combat
		var rollback := PredictionRollback.new()
		rollback.bind(actor)
		combat.players[proxy.role] = proxy
		var frame := _frame(actor, 100)
		frame["world"]["players"][proxy.role] = proxy.capture_checkpoint()
		rollback.reset(frame, 0)
		rollback._step()
		var pos := actor.position
		rollback.queue_event(NetEvent.Kind.FIRE, {"role": proxy.role, "type_id": type_id, "serial": 1, "tick": 101,
			"pos": Vector2(260, 544), "dir": Vector2.RIGHT, "charge": 1.0, "speed_mult": 1.0})
		expect(rollback.reconcile({}, 0) == PredictionRollback.Correction.SMOOTH
				and actor.position == pos and actor.motion_knock_velocity.x > 0.0
				and actor.sim_hp == 1 and not actor.sim_downed,
				"attack %d predicts its impact in the combat phase while HP stays authoritative" % type_id)
		var authority_knock := Vector2(240, 120)
		rollback.queue_event(NetEvent.Kind.HIT, {"victim": actor.role, "tick": 101, "epoch": 1, "hp": 0,
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
	var combat := parent.combat
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	combat.players[1] = shooter
	var baseline := _frame(actor, 100)
	baseline["world"]["players"][shooter.role] = shooter.capture_checkpoint()
	rollback.reset(baseline, 0)
	for i in 4:
		rollback._step()
	var shot := {"role": 1, "serial": 1, "tick": 101, "type_id": WeaponRegistry.Type.PISTOL,
			"pos": Vector2(220, 544), "dir": Vector2.RIGHT, "charge": 1.0, "speed_mult": 1.0}
	var velocity := ShotRules.projectile_velocities(1, shot, WeaponRegistry.definition(shot["type_id"]))[0]
	var id := ShotRules.shot_id(1, 1)
	var frame := _saved_frame(rollback, 102)
	frame["world"]["projectiles"][id] = [shot["type_id"], shot["pos"] + velocity * ActorStep.DT * 2.0, velocity]
	rollback.reconcile(frame, 0)
	rollback.queue_event(NetEvent.Kind.FIRE, shot)
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
	var client_map := world_with_walls(tree, 16, 16, {})
	var actor := player(client_map)
	actor.position = Vector2(200, 544)
	actor.sync_collision_geometry()
	actor.weapons.set_initial_inventory([WeaponRegistry.Type.LASER])
	var client := detached_client(actor)
	var rollback := client._rollback
	var baseline := _frame(actor, 100)
	var pos := Vector2(450, 544)
	baseline["world"]["players"][2] = _remote(actor, pos, 1)
	baseline["world"]["players"][2][NetPlayer.STATE][PlayerStateSchema.GROUNDED] = true
	client._install_world(baseline)
	rollback.reset(baseline, 0)
	_capture(rollback, ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)
	rollback.advance(ActorStep.DT)
	var proxy: Player = rollback.combat.players[2]
	expect(proxy.motion_knock_velocity.x > 0.0 and proxy.position.x == pos.x and proxy.sim_hp == 1,
			"a local action predicts the remote collider impulse after movement")
	rollback._step()
	expect(proxy.position.x > pos.x and not proxy.sim_downed,
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
	var combat := parent.combat
	rollback.bind(actor)
	combat.players[1] = proxy
	var baseline := _frame(actor, 100)
	baseline["world"]["players"][1] = proxy.capture_checkpoint()
	rollback.reset(baseline, 0)
	rollback._step()
	var id := ShotRules.shot_id(1, 1)
	expect(combat.projectiles.has(id) and proxy.shot_serial == 1 and proxy.equipped.carried == 29,
			"shared remote actor step advances held fire, equipment and recoil")
	var shot: Dictionary = rollback._state_at(101).shots[id].merged({"pos": Vector2(350, 128)}, true)
	rollback.queue_event(NetEvent.Kind.FIRE, shot)
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
	var combat := parent.combat
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	rollback.reset(_frame(actor, 100), 0)
	rollback.capture([0.0, ActorInput.BIT_DOWN, 0, ActorInput.BIT_ATTACK, 0, Vector2(0.3, 1.0).normalized()])
	rollback.advance(ActorStep.DT)
	var id := ShotRules.shot_id(actor.role, 1)
	expect(combat.projectiles.has(id), "the local attack action immediately creates a physics projectile")
	for i in 3:
		rollback._step()
	var bullet: BulletBody = combat.projectiles[id]
	var frame := _saved_frame(rollback, rollback.tick)
	frame["world"]["projectiles"][id] = [bullet.type_id, bullet.position, bullet.velocity]
	frame["world"]["players"][actor.role][NetPlayer.STATE][PlayerStateSchema.HP] -= 1
	rollback._step()
	var continued := bullet.motion_state()
	expect(bullet.fuse_elapsed > 0.0 and rollback.reconcile(frame, 0) == PredictionRollback.Correction.SMOOTH
			and combat.projectiles[id].motion_state() == continued,
			"replay preserves a physically calculated grenade fuse and travel through a pose-only STATE")
	var hp := actor.sim_hp
	var due := 0
	for i in 50:
		rollback._step()
		if combat.pending_blasts.has(id):
			due = combat.pending_blasts[id][CombatSimulator.Blast.DUE]
			break
	expect(due == rollback.tick + CombatSimulator.BLAST_DELAY and actor.motion_knock_velocity == Vector2.ZERO,
			"the predicted fuse schedules the blast for the ordinary delayed combat phase")
	if due > 0:
		var blast: Array = combat.pending_blasts[id]
		var live_id := ShotRules.shot_id(actor.role, 2)
		var live := combat.spawn_projectile(live_id, WeaponRegistry.Type.PISTOL, actor,
				Vector2(160, 64), Vector2.RIGHT * 60.0)
		rollback._step()
		var saved := rollback._state_at(rollback.tick)
		expect(saved.projectiles.keys() == [live_id] and saved.pending_blasts == {id: blast}
				and blast.size() == 3 and blast[CombatSimulator.Blast.TYPE] == WeaponRegistry.Type.GRENADE,
				"one prediction frame keeps the flying bullet and the scheduled grenade in separate tables")
		var anchor := _saved_frame(rollback, rollback.tick)
		var corrected_pos := live.position + Vector2(2, 0)
		anchor["world"]["projectiles"][live_id] = [live.type_id, corrected_pos, live.velocity]
		rollback.reconcile(anchor, 0)
		expect(live.position == corrected_pos and combat.pending_blasts == {id: blast},
				"an authoritative pose correction restores the live bullet and the pending blast together")
		while rollback.tick < due:
			rollback._step()
		expect(combat.pending_blasts.is_empty() and saved.pending_blasts == {id: blast},
				"settling the grenade leaves its saved prediction frame intact")
	expect(actor.motion_knock_velocity != Vector2.ZERO and actor.sim_hp == hp and not actor.sim_downed,
			"the local grenade predicts its own blast impulse before HIT or STATE")
	cleanup()

func _late_blast(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var combat := parent.combat
	var rollback := PredictionRollback.new()
	rollback.bind(actor)
	rollback.reset(_frame(actor, 102), 0)
	var id := ShotRules.shot_id(actor.role, 1)
	rollback.queue_event(NetEvent.Kind.EXPLOSION, {"id": id, "tick": 101,
			"type_id": WeaponRegistry.Type.GRENADE, "pos": actor.position - Vector2(60, 0)})
	rollback.reconcile({}, 0)
	rollback._step()
	expect(actor.motion_knock_velocity == Vector2.ZERO, "a late EXPLOSION retains its settlement tick")
	rollback._step()
	expect(actor.motion_knock_velocity.x > 0.0 and combat.pending_blasts.is_empty(),
			"an EXPLOSION older than STATE supplies the pending impulse exactly once")
	cleanup()
