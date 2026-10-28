extends Node

func _ready() -> void:
	_run.call_deferred()

func _history_bullet(world: AuthorityWorld, shooter: Node, id: int, pos: Vector2) -> BulletBase:
	var bullet: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	bullet.entity_id = id
	bullet.type_id = 1
	bullet.shooter = shooter
	bullet.authority_world = world
	bullet.position = pos
	world.add_projectile(bullet)
	bullet.set_physics_process(false)
	return bullet

func _run() -> void:
	seed(123456)
	Level0.pvp_mode = false
	var world := AuthorityWorld.new()
	add_child(world)
	world.setup(PvpSession.MODE_ROYALE, "res://maps/newfactory.cyrm", [1, 2], {},
			{"beta": true, "time": TimeRules.new().to_dict()}, [3])
	world.set_physics_process(false)
	world._round_state = NetEvent.RoundState.PLAYING
	var a: CharacterBody2D = world.players[1]
	var b: CharacterBody2D = world.players[2]
	await get_tree().physics_frame
	_check_respawn_motion(world, a)
	await _check_motion_hulls()
	await _check_player_platforms()
	# 拾取、丢弃和再次拾取保留弹药；空手状态也能作为完整基线恢复。
	for inst in world.pickups.keys():
		world._remove_ground_weapon(inst)
	a.weapons.set_initial_inventory([1])
	var inst := world._spawn_ground_weapon(2, 2, a.position, Vector2.ZERO)
	world._try_server_pickup(a, 1)
	assert(not world.pickups.has(inst))
	a.weapons.equip_index(a.weapons.inventory.held.size() - 1)
	assert(a.weapons.current_weapon().mag_ammo == 2)
	world._try_server_drop(a, 1)
	var dropped: Dictionary = world.world_state()["pickups"].values()[0]
	assert(dropped["mag"] == 2 and dropped["type_id"] == 2)
	b.position = dropped["pos"]
	world._try_server_pickup(b, 2)
	assert(world.pickups.is_empty())
	assert(b.weapons.snapshot_inventory().any(func(e: Dictionary) -> bool: return e["type"] == 2 and e["mag"] == 2))
	# 光束折线路径同一目标只结算一次，读取最多 12 tick 的角色历史。
	a.weapons.set_initial_inventory([WeaponRegistry.all_ids()[-1]])
	var laser: LaserWeaponBase = a.weapons.current_weapon()
	a.position = Vector2(1000, 1000)
	b.position = Vector2(1100, 1000)
	b.combat.iframes = 0.0
	var before: int = b.hp
	world._snap_tick = 20
	world._record_hitboxes()
	a.view_tick = 20
	var old_rect := world.target_rect_at(b, a)
	b.position += Vector2(0, 500)
	assert(world.target_rect_at(b, a) == old_rect)
	laser._damage_path_targets(PackedVector2Array([a.position, Vector2(1200, 1000), a.position]))
	assert(b.hp == before - laser.damage and world._stat_entry(1)["dealt"] == laser.damage)
	# Beta 只恢复自身和仍存活的自身弹丸，不恢复他人、拾取物或地形。
	world.respawn(1)
	a.weapons.set_initial_inventory([1, 2])
	a.weapons.inventory.held[1]["mag"] = 4
	var historical_weapon: int = a.weapons.current_inst()
	var historical_live: WeaponBase = a.weapons.current_weapon()
	historical_live.mag_ammo = 3
	historical_live._reloading = true
	historical_live._reload_t = 0.25
	historical_live.fire_cd_timer = 0.4
	a.position = Vector2(1000, 1000)
	var bullet: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	bullet.entity_id = (1 << 48) | 777
	bullet.type_id = 1
	bullet.shooter = a
	bullet.authority_world = world
	bullet.position = Vector2(1050, 1000)
	var births: Array = []
	world.event.connect(func(kind: int, data: Variant, except_role: int) -> void:
		if kind == NetEvent.Kind.BULLET_SPAWN: births.append([data, except_role]))
	var packet_before := NetCodec.new().encode_state(world.state_for(1, world.world_state()))
	world.add_projectile(bullet)
	var packet_after := NetCodec.new().encode_state(world.state_for(1, world.world_state()))
	assert(packet_before != packet_after and births.size() == 1,
			"STATE includes a projectile anchor as well as its reliable birth event")
	assert(world.world_state()["projectiles"].has(bullet.entity_id))
	assert(births[0][0]["id"] == bullet.entity_id and births[0][1] == -1)
	bullet.set_physics_process(false)
	bullet.velocity_vec = Vector2(80, -30)
	bullet.traveled = 12.5
	var expired := _history_bullet(world, a, (1 << 48) | 778, Vector2(1050, 1100))
	world._snap_tick = 30
	world.beta.tick(ActorStep.DT)
	var historical_pos := a.position
	var historical_bullet := bullet.position
	var historical_state := bullet.rewind_state()
	expired.finish()
	var future := _history_bullet(world, a, (1 << 48) | 779, Vector2(1200, 1100))
	var other_bullet := _history_bullet(world, b, (2 << 48) | 780, Vector2(1400, 1100))
	var future_state := future.rewind_state()
	var other_state := other_bullet.rewind_state()
	a.position += Vector2(200, 0)
	bullet.position += Vector2(200, 0)
	bullet.velocity_vec = -bullet.velocity_vec
	bullet.traveled += 200
	a.weapons.equip_index(1)
	a.weapons.current_weapon().mag_ammo = 1
	a.shot_serial = 100
	var other_pos := b.position
	var pickups: Dictionary = world.world_state()["pickups"]
	var map_revision := world.map_revision
	var record := InputBuffer.neutral()
	record["held"] = PacketInputSource.BIT_REWIND
	(a.input_source as PacketInputSource).apply_packet(record)
	world.beta.tick(ActorStep.DT)
	assert(a.position == historical_pos and bullet.position == historical_bullet)
	assert(bullet.rewind_state() == historical_state, "Beta uses the same complete projectile restore interface")
	assert(expired.is_queued_for_deletion() and future.rewind_state() == future_state,
		"Beta must not resurrect expired bullets or invent states before a live bullet was born")
	assert(other_bullet.rewind_state() == other_state, "Beta cannot rewind another player's projectile")
	assert(a.weapons.current_inst() == historical_weapon and a.weapons.current_weapon().mag_ammo == 3)
	assert(a.weapons.inventory.held[1]["mag"] == 4)
	assert(a.weapons.current_weapon()._reloading and is_equal_approx(a.weapons.current_weapon()._reload_t, 0.25))
	assert(is_equal_approx(a.weapons.current_weapon().fire_cd_timer, 0.4), "Beta restores the same weapon snapshot used by singleplayer")
	assert(b.position == other_pos and world.world_state()["pickups"] == pickups and world.map_revision == map_revision)
	assert(a.shot_serial == 100 and world.live_bullets().size() == 3)
	var epoch: int = a.input_buffer.epoch
	(a.input_source as PacketInputSource).reset_state()
	world.beta.tick(ActorStep.DT)
	assert(a.input_buffer.epoch == epoch + 1 and not a.rewinding and not bullet.is_physics_processing())
	future.queue_free()
	other_bullet.queue_free()
	# 死亡仅结算一次；AI 与真人共用权威步进。
	b.combat.force_down()
	world.rules.tick(world, ActorStep.DT)
	world.rules.tick(world, ActorStep.DT)
	assert(world._stat_entry(2)["deaths"] == 1)
	var respawn_tick: int = b.respawn_tick
	assert(respawn_tick == world._snap_tick + 120)
	assert(world.world_state()["players"][2]["respawn_tick"] == respawn_tick)
	world._snap_tick = respawn_tick - 1
	world.rules.tick(world, ActorStep.DT)
	assert(b.is_downed(), "the corpse remains until the scheduled tick finishes")
	world._snap_tick = respawn_tick
	world.rules.tick(world, ActorStep.DT)
	assert(not b.is_downed() and b.respawn_tick == 0)
	assert(world._stat_entry(2)["deaths"] == 1)
	for i in 60:
		world._physics_process(ActorStep.DT)
		await get_tree().physics_frame
	assert(world.players[3].input_source is AiInputSource)
	assert(world.players[3].input_seq == 0)
	# 六种武器均通过真实输入步进开火；可靠开火事件每次只上报一次。
	var fired_types := {}
	world.event.connect(func(kind: int, data: Variant, _except_role: int) -> void:
		if kind == NetEvent.Kind.FIRE and data["role"] == 1:
			fired_types[data["type_id"]] = true)
	for type_id in WeaponRegistry.all_ids():
		a.apply_authoritative_state(a.max_hp, a.max_waterproof, false)
		a.weapons.set_initial_inventory([type_id])
		world.new_epoch(1)
		var press := InputBuffer.neutral()
		press["seq"] = 1
		press["epoch"] = a.input_buffer.epoch
		press["held"] = PacketInputSource.BIT_ATTACK
		press["pressed"] = PacketInputSource.BIT_ATTACK
		var release := InputBuffer.neutral()
		release["seq"] = 2
		release["epoch"] = a.input_buffer.epoch
		release["released"] = PacketInputSource.BIT_ATTACK
		press["target_tick"] = world._snap_tick + 1
		release["target_tick"] = world._snap_tick + 2
		world.accept_input(1, {"frames": [press, release], "actions": [press, release]})
		world._physics_process(ActorStep.DT)
		world._physics_process(ActorStep.DT)
	assert(fired_types.size() == WeaponRegistry.all_ids().size())
	_check_prediction(a, world)
	_check_terrain_batch(world)
	_check_projectile_end(world, a)
	world.free()
	# 两种回合规则均为两局获胜，换局重建基线并推进控制阶段。
	for mode in [PvpSession.MODE_PVP, PvpSession.MODE_TEAM]:
		world = AuthorityWorld.new()
		add_child(world)
		var peers := {1: 101, 2: 102}
		var teams := {1: 1, 2: 2} if mode == PvpSession.MODE_TEAM else {}
		world.setup(mode, "res://maps/newfactory.cyrm", peers.keys(), teams, {}, [])
		world.set_physics_process(false)
		for round_index in 2:
			world._round_state = NetEvent.RoundState.PLAYING
			world._scores[1] = 9 if mode == PvpSession.MODE_TEAM else 5
			world.rules.tick(world, ActorStep.DT)
			assert(world._round_state == NetEvent.RoundState.ROUND_OVER)
			world.rules.tick(world, 4.1)
		assert(world._round_state == NetEvent.RoundState.MATCH_OVER and world.rules.winner == 1)
		assert(world.round_state()["rounds_won"][1] == 2)
		world.free()
	await _check_actor_motion()
	await _check_tick_dispatch()
	await _check_seam_actor_collision()
	await _check_replay_contact_memory()
	await _check_crowded_jump()
	await _check_beta_prediction()
	_check_impact_state()
	_check_partial_confirmations()
	_check_blast_prediction()
	_check_hit_prediction()
	_check_checkpoint_replay()
	await get_tree().process_frame
	print("AUTHORITY PROBE OK actor speed, six weapons, pickups, ammo, laser history, Beta scope, epochs, damage once, AI, round wins, silent replay")
	get_tree().quit()

func _check_checkpoint_replay() -> void:
	var world := AuthorityWorld.new()
	add_child(world)
	world.setup(PvpSession.MODE_ROYALE, "res://tests/network/arena.cyrm", [1, 2], {},
			{"beta": true, "time": TimeRules.new().to_dict()}, [])
	world.set_physics_process(false)
	world._round_state = NetEvent.RoundState.PLAYING
	world._snap_tick = 100
	for role in world.players:
		world.players[role].set_controls_locked(false)
		world.players[role].position = Vector2(800 + role * 200, 300)
		world.players[role].gravity = 0.0
		world.players[role].collision_mask = 0
		world.players[role].weapons.set_initial_inventory([1])
	var frame := world.state_for(1, world.world_state())
	var local: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(local)
	local.enable_manual_simulation()
	local.role = 1
	local.gravity = 0.0
	local.collision_mask = 0
	local.restore_state(frame["own"]["state"])
	var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.role = 2
	add_child(replica)
	replica.set_ghost_layer(2)
	replica.apply_snapshot(frame["world"]["players"][2], local.position, 100)
	replica._forecast.gravity = 0.0
	replica._forecast.collision_mask = 0
	var rollback := PredictionRollback.new()
	rollback.bind(local, {2: replica})
	rollback.time_economy = TimeEconomy.new(world.time_economy.rules, [1, 2])
	rollback.reset(1, 0, 100, 0)
	rollback._clock = 100.0
	var source := PacketInputSource.new()
	for tick in 6:
		source.apply_packet(InputBuffer.neutral().merged({"held": PacketInputSource.BIT_ATTACK,
				"pressed": PacketInputSource.BIT_ATTACK if tick == 0 else 0}, true))
		rollback.capture(source, Vector2.RIGHT, 100, 0)
		rollback.advance(ActorStep.DT)
	var input := InputBuffer.neutral().merged({"seq": 1, "target_tick": 104,
			"available_tick": 104, "ax": -1.0}, true)
	assert(not replica.receive_input(100, {"frames": [input], "actions": []}),
			"remote hints must not invalidate local replay")
	rollback.combat_prediction.receive_reward({"serial": 1, "tick": 105, "phase": 0, "role": 1, "amount": 10})
	assert(rollback.can_replay_from(104))
	rollback.replay_from(104)
	assert(rollback.diagnostics["replay_ticks"] == 3)
	var own: Dictionary = local.capture_state()
	var remote: Dictionary = replica._forecast.capture_state()
	var bullets := rollback.combat_prediction.snapshot_projectiles()
	var accounts := rollback.time_economy.state_payload()
	replica.apply_snapshot(frame["world"]["players"][2], local.position, 100)
	for role in frame["time"]: rollback.time_economy.restore_account(role, frame["time"][role])
	rollback.reconcile(frame["own"], 100, 0, false, frame["world"]["projectiles"])
	assert(rollback.diagnostics["replay_ticks"] == 6)
	assert(local.capture_state() == own and replica._forecast.capture_state() == remote,
			"checkpoint and full-anchor replay must produce identical actor state")
	assert(rollback.combat_prediction.snapshot_projectiles() == bullets
			and rollback.time_economy.state_payload() == accounts,
			"checkpoint replay must restore projectile lifetime and apply rewards exactly once")
	# 不同移动 ACK 可以产生相同命令后缀；验证调度后保留物理结果，再与完整恢复对照。
	var saved: Dictionary = rollback.checkpoint_state(103)
	var accepted := frame.duplicate(true)
	accepted["tick"] = 103
	# 新锚点须携带其 tick 的运动状态，不能把 tick 100 的模式计时冒充 tick 103。
	replica.anchor_collision(local.position, 103)
	accepted["world"]["players"][2].merge(replica._forecast.capture_motion_state(), true)
	accepted["world"]["players"][2]["pose"] = replica._forecast.state
	replica.anchor_collision(local.position, 106)
	accepted["own"]["state"] = saved["players"][1]
	accepted["own"]["ack"] = 1
	accepted["own"]["action_ack"] = 1
	accepted["own"]["input"] = InputBuffer.neutral().merged({"seq": 1, "target_tick": 101,
			"view_tick": 100, "held": PacketInputSource.BIT_ATTACK}, true)
	assert(saved["players"].keys() == [1], "the remote actor must not be captured in local replay history")
	accepted["world"]["projectiles"] = saved["projectiles"]
	accepted["time"] = saved["time"]
	assert(not saved["projectiles"].is_empty(), "fixture must contain an actual predicted projectile")
	for id in saved["projectiles"]:
		assert(not rollback.confirm_projectile(id, saved["projectiles"][id], 103, local),
				"a matching projectile checkpoint must not request another replay")
	for record: Dictionary in rollback.history:
		if record["target_tick"] > 103: record["aim"] = Vector2(0.8, 0.6)
	assert(rollback.can_reuse(accepted), "equivalent scheduled commands may reuse a suffix with a different movement ACK")
	var shot_aim: Vector2 = rollback.actions[0]["aim"]
	rollback.actions[0]["aim"] = Vector2(0.8, 0.6)
	assert(not rollback.can_reuse(frame), "a changed aim on an actual shot must invalidate the predicted suffix")
	rollback.actions[0]["aim"] = shot_aim
	assert(rollback.can_reuse(accepted))
	rollback.reconcile(accepted["own"], 103, 0, true, accepted["world"]["projectiles"])
	assert(rollback.diagnostics["replay_ticks"] == 0 and local.capture_state() == own)
	replica.apply_snapshot(accepted["world"]["players"][2], local.position, 103)
	for role in accepted["time"]: rollback.time_economy.restore_account(role, accepted["time"][role])
	rollback.reconcile(accepted["own"], 103, 0, false, accepted["world"]["projectiles"])
	assert(local.capture_state() == own and replica._forecast.capture_state() == remote
			and rollback.combat_prediction.snapshot_projectiles() == bullets
			and rollback.time_economy.state_payload() == accounts,
			"reused input queues must remain equivalent to complete authoritative replay")
	rollback.combat_prediction.clear()
	replica.free()
	local.free()
	world.free()
	print("CHECKPOINT REPLAY OK same actors, projectiles and time accounts as full replay")

func _check_projectile_end(world: AuthorityWorld, player: CharacterBody2D) -> void:
	var events := []
	var ids: Array[int] = []
	world.event.connect(func(kind: int, data: Variant, _except_role: int) -> void:
		if kind == NetEvent.Kind.BULLET_END and data["ids"].any(func(id: int) -> bool: return ids.has(id)):
			events.append(data))
	for i in 2:
		var bullet: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
		bullet.entity_id = (player.role << 48) | ((10001 + i) << 8)
		bullet.type_id = 1
		bullet.shooter = player
		bullet.position = Vector2(1000, 500)
		bullet.collision_mask = 0
		world.add_projectile(bullet)
		bullet.set_physics_process(false)
		ids.append(bullet.entity_id)
	world._physics_process(ActorStep.DT)
	assert(events.size() == 1 and events[0]["tick"] == world._snap_tick)
	for id in ids:
		assert(events[0]["ids"].has(id) and not world.projectiles.has(id))
	world._physics_process(ActorStep.DT)
	assert(events.size() == 1, "projectile ends must be batched once at their simulation tick")
	print("PROJECTILE END AUTHORITY OK batch, tick, removal and no duplicate")

func _check_impact_state() -> void:
	var world := AuthorityWorld.new()
	add_child(world)
	world.setup(PvpSession.MODE_ROYALE, "res://tests/network/arena.cyrm", [1, 2], {}, {}, [])
	world.set_physics_process(false)
	world._round_state = NetEvent.RoundState.PLAYING
	world._snap_tick = 10
	for role in world.players:
		var player: CharacterBody2D = world.players[role]
		player.position = Vector2(1000 if role == 1 else 1500, 300)
		player.gravity = 0.0
		player.collision_mask = 0
		player.weapons.set_initial_inventory([])
	var sent: Array = []
	var explosions: Array = []
	world.state_ready.connect(func(frame: Dictionary, targets: Array) -> void:
		sent.append({"tick": world._snap_tick, "frame": frame, "targets": targets}))
	world.event.connect(func(kind: int, data: Variant, _except_role: int) -> void:
		if kind == NetEvent.Kind.EXPLOSION: explosions.append(data))
	for i in 2:
		_add_timed_blast(world, 1)
	world._physics_process(ActorStep.DT)
	assert(sent.size() == 1 and sent[0]["tick"] == 11 and sent[0]["targets"] == [1],
			"multiple blasts in an odd tick must send one complete state to the affected player")
	assert(sent[0]["frame"]["players"][1]["knock"].length() > 0.0)
	assert(explosions.size() == 2 and explosions[0]["tick"] == 11 and explosions[1]["tick"] == 11)
	assert(explosions[0]["id"] != explosions[1]["id"] and explosions[0]["type_id"] == 5)
	world._physics_process(ActorStep.DT)
	assert(sent.size() == 2 and sent[1]["tick"] == 12 and sent[1]["targets"] == [1, 2])
	var hp: int = world.players[1].hp
	_add_timed_blast(world, 0)
	world._physics_process(ActorStep.DT)
	assert(world.players[1].hp == hp)
	assert(sent.size() == 3 and sent[2]["tick"] == 13 and sent[2]["targets"] == [1],
			"a blast impulse without HP damage must also arrive promptly")
	world._physics_process(ActorStep.DT)
	world._physics_process(ActorStep.DT)
	assert(sent.size() == 4, "the impact must not keep producing extra states")
	_add_timed_blast(world, 1)
	world._physics_process(ActorStep.DT)
	assert(sent.size() == 5 and sent[4]["tick"] == 16 and sent[4]["targets"] == [1, 2],
			"an even-tick blast must use the regular state without a duplicate")
	world.free()

func _add_timed_blast(world: AuthorityWorld, damage: int) -> void:
	var grenade: BulletBase = preload("res://scenes/weapons/grenade_bullet.tscn").instantiate()
	grenade.entity_id = (2 << 48) | (world.projectiles.size() + 1)
	grenade.type_id = 5
	grenade.authority_world = world
	grenade.shooter = world.players[2]
	grenade.position = world.players[1].position
	grenade.collision_mask = 0
	grenade.explosion_damage = damage
	grenade._fuse_active = true
	grenade._fuse_duration = ActorStep.DT
	world.add_projectile(grenade)
	grenade.set_physics_process(false)

func _check_hit_prediction() -> void:
	_check_confirmed_impact_replay()
	_check_death_rejection()
	var cases := []
	for type_id in WeaponRegistry.all_ids():
		for hp in [1, 1000]: cases.append({"type": type_id, "hp": hp})
	for test: Dictionary in cases:
		var type_id: int = test["type"]
		var world := AuthorityWorld.new()
		add_child(world)
		world.setup(PvpSession.MODE_ROYALE, "res://tests/network/arena.cyrm", [1, 2], {}, {}, [])
		world.set_physics_process(false)
		world._round_state = NetEvent.RoundState.PLAYING
		world._snap_tick = 100
		for role in world.players:
			var actor: CharacterBody2D = world.players[role]
			actor.position = Vector2(1000 if role == 1 else 700, 300)
			actor.gravity = 0.0
			actor.collision_mask = 0
			actor.weapons.set_initial_inventory([])
			actor.combat.hp = test["hp"] if role == 1 else 1000
		var shooter: CharacterBody2D = world.players[2]
		shooter.weapons.set_initial_inventory([type_id])
		var weapon: WeaponBase = shooter.weapons.current_weapon()
		var local: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		add_child(local)
		local.enable_manual_simulation()
		local.remove_from_group("player")
		local.collision_layer = 0
		local.collision_mask = 0
		local.gravity = 0.0
		local.role = 1
		local.set_controls_locked(false)
		var initial: Dictionary = world.players[1].capture_state()
		local.restore_state(initial)
		var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
		replica.role = 2
		add_child(replica)
		replica.set_ghost_layer(2)
		replica.apply_snapshot(world.world_state()["players"][2], local.position, 100)
		replica._forecast.gravity = 0.0
		replica._forecast.collision_mask = 0
		var rollback := PredictionRollback.new()
		rollback.bind(local, {2: replica})
		rollback.reset(1, 0, 100, 60)
		var action := {"dir": Vector2.RIGHT, "serial": 1, "pos": Vector2(760, 300), "input_seq": 1, "input_epoch": 1}
		var confirmations: Array = []
		world.event.connect(func(kind: int, data: Variant, _except_role: int) -> void:
			if kind == NetEvent.Kind.HIT and data["victim"] == 1: confirmations.append(data))
		if weapon is LaserWeaponBase:
			var beam: Dictionary = weapon._make_beam_report(weapon._emit_beam(action["pos"], Vector2.RIGHT)["points"])
			beam.merge({"id": (2 << 48) | 256, "tick": 104, "type_id": type_id, "shooter_role": 2}, true)
			rollback.combat_prediction.receive_beam(beam)
		else:
			weapon._spawn_projectiles(action)
			for bullet: BulletBase in world.live_bullets():
				rollback.combat_prediction.seed_projectile(bullet.entity_id, world.projectile_state(bullet), 100, replica._forecast)
		var history := {100: initial}
		for tick in range(101, 125):
			world._physics_process(ActorStep.DT)
			if weapon is LaserWeaponBase and tick == 104:
				shooter.shot_serial = 1
				weapon._damage_path_targets(rollback.combat_prediction.beams.values()[0]["pts"])
			history[tick] = world.players[1].capture_state()
		rollback.advance(0.0)
		for i in 18: rollback.advance(ActorStep.DT)
		var expected: Vector2 = history[124]["pos"]
		var error := local.position.distance_to(expected)
		assert(error < 0.02, "weapon %d prediction error %f" % [type_id, error])
		assert(local.position.distance_to(initial["pos"]) > 8.0 or local.is_downed(), "the target must be pushed or killed")
		assert(local.hp == history[124]["hp"], "predicted combat state must match authority")
		var own := {"epoch": 1, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2,
				"rewind": false, "state": history[102], "input": InputBuffer.neutral()}
		rollback.reconcile(own, 102, 60)
		assert(local.position.distance_to(expected) < 0.02, "replay must reconstruct the same impact")
		for hit: Dictionary in confirmations: rollback.combat_prediction.confirm_hit(hit)
		rollback.reconcile(own, 102, 60)
		assert(local.position.distance_to(expected) < 0.02, "confirmed hits must not add a second impulse")
		own["state"] = history[110]
		rollback.reconcile(own, 110, 60)
		assert(local.position.distance_to(expected) < 0.02, "a grenade direct hit must stay consumed while its fuse continues")
		own["state"] = history[124]
		rollback.reconcile(own, 124, 60)
		assert(local.position.distance_to(expected) < 0.02, "authority already includes acknowledged impacts")
		print("HIT PREDICTION weapon=", type_id, " initial_hp=", test["hp"], " error_px=", error, " confirmations=", confirmations.size())
		rollback.combat_prediction.clear()
		replica.free()
		local.free()
		world.free()

func _check_confirmed_impact_replay() -> void:
	for source in 3:
		var reference: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		var local: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		for player in [reference, local]:
			add_child(player)
			player.enable_manual_simulation()
			player.remove_from_group("player")
			player.role = 1
			player.collision_layer = 0
			player.collision_mask = 0
			player.gravity = 0.0
			player.position = Vector2(1000, 500)
			player.combat.hp = 10
		var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
		replica.role = 2
		add_child(replica)
		replica.set_ghost_layer(2)
		var remote: Dictionary = ProtocolFixture.frame()["world"]["players"][1]
		remote["pos"] = Vector2(700, 500)
		replica.apply_snapshot(remote, local.position, 100)
		replica._forecast.gravity = 0.0
		replica._forecast.collision_mask = 0
		var rollback := PredictionRollback.new()
		rollback.bind(local, {2: replica})
		rollback.reset(1, 0, 100, 0)
		rollback._clock = 100.0
		var initial: Dictionary = local.capture_state()
		var history := {100: initial}
		var hit := {"id": (2 << 48) | 256, "tick": 104, "shooter": 2, "victim": 1,
				"damage": 20, "hp": -10, "facing": 1, "source": source,
				"pos": Vector2(900, 500), "knock": Vector2(1800, 0)}
		for tick in range(101, 113):
			ActorStep.step(reference, InputBuffer.neutral())
			if tick == 104: reference.combat.take_hit(hit["pos"], 20, true, 1800.0)
			history[tick] = reference.capture_state()
			rollback.advance(ActorStep.DT)
		var missing_error := local.position.distance_to(reference.position)
		assert(missing_error > 32.0, "the missing authoritative outcome must change the trajectory")
		rollback.combat_prediction.confirm_hit(hit)
		var own := {"epoch": 1, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2,
				"rewind": false, "state": initial, "input": InputBuffer.neutral()}
		for repeat in 2:
			replica.apply_snapshot(remote, local.position, 100)
			rollback.reconcile(own, 100, 0)
			assert(local.position.distance_to(reference.position) < 0.02,
					"a confirmed hit must survive replay without its local projectile, source=%d" % source)
			assert(local.hp == -10 and local.is_downed(), "confirmed death must restore the authoritative collision state")
		own["state"] = history[104]
		replica.apply_snapshot(remote, local.position, 104)
		rollback.reconcile(own, 104, 0)
		assert(local.position.distance_to(reference.position) < 0.02 and rollback.combat_prediction.hits.is_empty(),
				"an acknowledged hit must not execute again")
		print("CONFIRMED IMPACT source=", source, " missing_px=", missing_error,
				" replay_px=", local.position.distance_to(reference.position), " hp=", local.hp)
		rollback.combat_prediction.clear()
		replica.free()
		local.free()
		reference.free()
	print("CONFIRMED IMPACT REPLAY OK missing projectile, three phases, death, repeated replay, ACK")

func _check_death_rejection() -> void:
	var actors: Array = []
	for role in [1, 1]:
		var actor: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		add_child(actor)
		actor.enable_manual_simulation()
		actor.remove_from_group("player")
		actor.role = role
		actor.collision_layer = 0
		actor.collision_mask = 0
		actor.gravity = 0.0
		actor.position = Vector2(1000, 300)
		actor.combat.hp = 1
		actor.weapons.set_initial_inventory([1])
		actor.set_controls_locked(false)
		actors.append(actor)
	var local: CharacterBody2D = actors[0]
	var reference: CharacterBody2D = actors[1]
	var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.role = 2
	add_child(replica)
	replica.set_ghost_layer(2)
	var remote: Dictionary = ProtocolFixture.frame()["world"]["players"][1].duplicate(true)
	remote.merge({"pos": Vector2(700, 300), "vel": Vector2.ZERO, "axis": 0.0}, true)
	replica.apply_snapshot(remote, local.position, 100)
	replica._forecast.gravity = 0.0
	replica._forecast.collision_mask = 0
	var rollback := PredictionRollback.new()
	rollback.bind(local, {2: replica})
	rollback.reset(1, 0, 100, 0)
	rollback._clock = 100.0
	rollback.combat_prediction.receive_beam({"id": (2 << 48) | 256, "tick": 104,
			"type_id": 6, "shooter_role": 2, "pts": PackedVector2Array([Vector2(700, 300), Vector2(1300, 300)]),
			"half_width": 4.0})
	var notifications := [0]
	local.combat.took_hit.connect(func(_pos: Vector2, _damage: int) -> void: notifications[0] += 1)
	var source := PacketInputSource.new()
	var history: Dictionary = {}
	var records: Dictionary = {}
	for tick in range(101, 111):
		var attack: int = PacketInputSource.BIT_ATTACK if tick == 108 else 0
		var record := InputBuffer.neutral().merged({"seq": tick - 100, "epoch": 1,
				"target_tick": tick, "ax": 1.0, "held": attack, "pressed": attack,
				"released": PacketInputSource.BIT_ATTACK if tick == 109 else 0}, true)
		records[tick] = record
		ActorStep.step(reference, record)
		history[tick] = reference.capture_state()
		source.apply_packet(record)
		rollback.capture(source, Vector2.RIGHT, 100, 0)
		rollback.advance(ActorStep.DT)
	assert(local.is_downed() and local.hp <= 0 and local.rotation != 0.0)
	assert(local.shot_serial == 0 and reference.shot_serial == 1,
			"the predicted death must stop firing after its lethal tick")
	var own := {"epoch": 1, "ack": 6, "action_ack": 6, "timing_seq": 0, "lead": 2,
			"rewind": false, "state": history[106], "input": records[106]}
	for repeat in 2:
		replica.apply_snapshot(remote, local.position, 106)
		rollback.reconcile(own, 106, 0)
		assert(local.hp == 1 and not local.is_downed() and local.rotation == 0.0)
		assert(local.position.distance_to(reference.position) < 0.02)
		assert(local.collision_rect().size.is_equal_approx(reference.collision_rect().size))
		assert(local.shot_serial == reference.shot_serial
				and local.weapons.current_weapon().mag_ammo == reference.weapons.current_weapon().mag_ammo,
				"rejecting death must restore collision and replay the surviving player's shot once")
	assert(notifications[0] == 0, "prediction must not publish authoritative damage events")
	rollback.combat_prediction.clear()
	replica.free()
	for actor: CharacterBody2D in actors: actor.free()
	print("DEATH REJECTION OK alive state, collider, pending shot, repeated replay and silent prediction")

func _check_partial_confirmations() -> void:
	var actors: Array[CharacterBody2D] = []
	for role in [1, 2, 3]:
		var actor: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		add_child(actor)
		actor.enable_manual_simulation()
		actor.remove_from_group("player")
		actor.role = role
		actor.gravity = 0.0
		actor.collision_layer = 0
		actor.collision_mask = 0
		actor.position = Vector2(900 if role == 1 else 1100 if role == 2 else 700, 300)
		actor.apply_authoritative_state(1 if role == 1 else 100, actor.max_waterproof, false)
		actors.append(actor)
	var initial := actors.map(func(actor: CharacterBody2D): return actor.capture_state())
	for source in [1, 2]:
		for i in actors.size(): actors[i].restore_state(initial[i])
		var prediction := CombatPrediction.new()
		prediction.bind(actors[0])
		var id: int = (3 << 48) | (source << 8)
		if source == 1:
			prediction.beams[id] = {"id": id, "tick": 101, "shooter_role": 3, "type_id": 6,
				"pts": PackedVector2Array([Vector2(800, 300), Vector2(1200, 300)]), "half_width": 8.0}
		else:
			prediction.blasts[id] = {"id": id, "tick": 101, "type_id": 5, "pos": Vector2(1000, 300)}
		if source == 1: prediction.step_beams(101, 3, actors)
		else: prediction.step(101, actors, false)
		assert(actors[0].is_downed(), "the initial attack must predict lethal damage")
		var expected := actors.map(func(actor: CharacterBody2D): return actor.capture_state())
		for index in [1, 0]:
			var victim := actors[index]
			prediction.confirm_hit({"id": id, "tick": 101, "source": source, "shooter": 3,
				"victim": victim.role, "pos": Vector2(1000, 300), "hp": expected[index]["hp"],
				"facing": expected[index]["facing"], "knock": expected[index]["knock"]})
			for repeat in 2:
				for i in actors.size(): actors[i].restore_state(initial[i])
				if source == 1: prediction.step_beams(101, 3, actors)
				else: prediction.step(101, actors, false)
				for i in [0, 1]:
					assert(actors[i].hp == expected[i]["hp"] and actors[i].is_downed() == expected[i]["down"],
						"another victim's confirmation must not cancel this victim's predicted damage or death")
					assert(actors[i].combat.knock_velocity.is_equal_approx(expected[i]["knock"]),
						"partial confirmations must neither remove nor double an impulse")
		prediction.clear()
	for actor in actors: actor.free()
	print("PARTIAL HIT CONFIRMATION OK beam, blast, death, impulse and repeated replay")

func _check_blast_prediction() -> void:
	var world := AuthorityWorld.new()
	add_child(world)
	world.setup(PvpSession.MODE_ROYALE, "res://tests/network/arena.cyrm", [1, 2], {},
			{"beta": true, "time": TimeRules.new().to_dict()}, [])
	world.set_physics_process(false)
	world._round_state = NetEvent.RoundState.PLAYING
	world._snap_tick = 100
	for role in world.players:
		var player: CharacterBody2D = world.players[role]
		player.position = Vector2(1000 if role == 1 else 1500, 300)
		player.gravity = 0.0
		player.collision_mask = 0
		player.weapons.set_initial_inventory([])
	var local: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(local)
	local.enable_manual_simulation()
	local.remove_from_group("player")
	local.collision_layer = 0
	local.collision_mask = 0
	local.gravity = 0.0
	local.role = 1
	local.set_controls_locked(false)
	var initial: Dictionary = world.players[1].capture_state()
	local.restore_state(initial)
	var rollback := PredictionRollback.new()
	rollback.bind(local)
	rollback.reset(1, 0, 100, 60)
	var presentations: Array = []
	rollback.combat_prediction.detonated.connect(func(data: Dictionary) -> void: presentations.append(data))
	var profile := WeaponRegistry.projectile_profile(5)
	var grenade: BulletBase = profile["scene"].instantiate()
	grenade.setup(Vector2.RIGHT, 400, profile["range"], profile["size"], profile["color"], null)
	grenade.entity_id = (2 << 48) | 77
	grenade.type_id = 5
	grenade.authority_world = world
	grenade.shooter = world.players[2]
	grenade.position = Vector2(900, 300)
	grenade.gravity_factor = profile["gravity"]
	grenade._fuse_active = true
	grenade._fuse_duration = 0.15
	world.add_projectile(grenade)
	grenade.set_physics_process(false)
	var seed := {"tick": 100, "projectiles": {grenade.entity_id: world.projectile_state(grenade)}}
	rollback.combat_prediction.plan(seed)
	var planned: Dictionary = rollback.combat_prediction.blasts[grenade.entity_id]
	var actual: Array = []
	world.event.connect(func(kind: int, data: Variant, _except_role: int) -> void:
		if kind == NetEvent.Kind.EXPLOSION: actual.append(data))
	var history := {100: initial}
	for tick in range(101, 115):
		world._physics_process(ActorStep.DT)
		history[tick] = world.players[1].capture_state()
	var terrain := TileDefs.sub_hp.duplicate()
	var authoritative_patch := world.terrain.get_modified()
	var map_revision := world.map_revision
	assert(actual.size() == 1 and planned["tick"] == actual[0]["tick"])
	assert(GridPathfinder.toroidal_delta_px(planned["pos"], actual[0]["pos"],
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length() < 0.01)
	rollback.advance(0.0)
	for i in 8:
		rollback.advance(ActorStep.DT)
	var predicted := local.position
	var expected: Vector2 = history[114]["pos"]
	assert(predicted.distance_to(expected) < 0.01, "known fuse must predict the authority blast motion before receiving the hit")
	assert(predicted.distance_to(initial["pos"]) > 128.0)
	assert(local.hp == history[114]["hp"], "predicted health must match authority")
	assert(world.map_revision == map_revision and world.terrain.get_modified() == authoritative_patch,
			"prediction cannot create authoritative terrain changes")
	assert(presentations.size() == 1)
	var own := {"epoch": 1, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2,
			"rewind": false, "state": history[108], "input": InputBuffer.neutral()}
	rollback.reconcile(own, 108, 60)
	assert(local.position.distance_to(predicted) < 0.01, "replay before the blast must include its force exactly once")
	rollback.combat_prediction.confirm(actual[0])
	rollback.reconcile(own, 108, 60)
	assert(local.position.distance_to(predicted) < 0.01, "confirming a predicted explosion must not add a second impulse")
	own["state"] = history[110]
	rollback.reconcile(own, 110, 60)
	assert(local.position.distance_to(predicted) < 0.01 and rollback.combat_prediction.blasts.is_empty())
	assert(presentations.size() == 1, "input replay must not repeat the explosion presentation")
	rollback.combat_prediction.plan(seed)
	rollback.combat_prediction.cancel_role(2)
	assert(rollback.combat_prediction.blasts.is_empty(), "Beta must cancel unconfirmed fuse forecasts")
	# 真实落地反弹和跨环面飞行均使用同一弹丸步进预报。
	for bounce in [true, false]:
		var projectile: BulletBase = profile["scene"].instantiate()
		projectile.setup(Vector2.DOWN if bounce else Vector2.RIGHT, 600, profile["range"], profile["size"], profile["color"], null)
		projectile.entity_id = (2 << 48) | (88 if bounce else 89)
		projectile.type_id = 5
		projectile.authority_world = world
		projectile.shooter = world.players[2]
		projectile.position = Vector2(1000, 550) if bounce else Vector2(2040, 300)
		projectile.gravity_factor = profile["gravity"]
		projectile.explosion_damage = 0
		if not bounce: projectile._start_fuse(0.15)
		world.add_projectile(projectile)
		projectile.set_physics_process(false)
		var messages: Array = []
		var listener := func(kind: int, data: Variant, _except_role: int) -> void:
			if kind == NetEvent.Kind.BULLET_FUSE: messages.append(data)
		world.event.connect(listener)
		actual.clear()
		while messages.is_empty():
			world._physics_process(ActorStep.DT)
		if bounce:
			var input := InputBuffer.neutral().merged({"seq": 1, "epoch": world.players[2].input_buffer.epoch,
					"target_tick": world._snap_tick + 1, "held": PacketInputSource.BIT_REWIND}, true)
			world.accept_input(2, {"frames": [input], "actions": []})
			world._physics_process(ActorStep.DT)
			assert(world.players[2].rewinding)
			input = InputBuffer.neutral().merged({"seq": 2, "epoch": world.players[2].input_buffer.epoch,
					"target_tick": world._snap_tick + 1}, true)
			world.accept_input(2, {"frames": [input], "actions": []})
			world._physics_process(ActorStep.DT)
			assert(not world.players[2].rewinding)
		while actual.is_empty():
			world._physics_process(ActorStep.DT)
		world.event.disconnect(listener)
		assert(messages.size() == (2 if bounce else 1), "each fuse phase and Beta resume sends one snapshot")
		rollback.combat_prediction.plan(messages[-1])
		var forecast: Dictionary = rollback.combat_prediction.blasts[actual[0]["id"]]
		assert(forecast["tick"] == actual[0]["tick"])
		assert(GridPathfinder.toroidal_delta_px(forecast["pos"], actual[0]["pos"],
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length() < 0.01)
	print("BLAST PREDICTION error_px=", local.position.distance_to(predicted),
			" without_force_px=", predicted.distance_to(initial["pos"]))
	# 同 tick 冲量覆盖顺序由稳定实体 ID 决定，消息到达顺序不改变结果。
	var ending: Vector2 = local.combat.knock_velocity
	var blast_tick := rollback._sim_tick + 1
	var lower := {"id": (1 << 48) | 999, "type_id": 5, "tick": blast_tick,
			"pos": local.position - Vector2(100, 0)}
	var higher := {"id": (2 << 48) | 999, "type_id": 5, "tick": blast_tick,
			"pos": local.position + Vector2(100, 0)}
	for order in [[higher, lower], [lower, higher]]:
		local.apply_authoritative_state(1000, 100, false)
		rollback.combat_prediction.clear()
		for blast: Dictionary in order: rollback.combat_prediction.confirm(blast)
		rollback.combat_prediction.step(blast_tick, [local], false)
		assert(local.combat.knock_velocity.x < -2999.0 and absf(local.combat.knock_velocity.y) < 0.01)
	local.combat.knock_velocity = ending
	world.players[1].reset_motion()
	world.players[1].apply_authoritative_state(1000, 100, false)
	world.players[1].position = Vector2(1000, 300)
	actual.clear()
	for blast: Dictionary in [higher, lower]:
		var projectile: BulletBase = profile["scene"].instantiate()
		projectile.entity_id = blast["id"]
		projectile.type_id = 5
		projectile.authority_world = world
		projectile.shooter = world.players[2]
		projectile.position = Vector2(1100, 300) if blast == higher else Vector2(900, 300)
		projectile.explosion_damage = 0
		projectile._fuse_active = true
		projectile._fuse_duration = ActorStep.DT
		world.add_projectile(projectile)
		projectile.set_physics_process(false)
	world._physics_process(ActorStep.DT)
	assert(actual.size() == 2 and actual[0]["id"] == lower["id"] and actual[1]["id"] == higher["id"])
	assert(world.players[1].combat.knock_velocity.x < -2999.0)
	# 服务端确认的爆点与 tick 是本次攻击的重放结果。
	rollback.combat_prediction.clear()
	rollback.combat_prediction.confirm(higher)
	rollback.combat_prediction.plan({"tick": seed["tick"],
			"projectiles": {higher["id"]: seed["projectiles"].values()[0]}})
	assert(rollback.combat_prediction.blasts[higher["id"]]["confirmed"])
	var different: Dictionary = seed["projectiles"].values()[0].duplicate()
	different.merge({"fuse_active": true, "fuse_elapsed": 0.0, "fuse_duration": ActorStep.DT}, true)
	rollback.combat_prediction.seed_projectile(higher["id"], different, blast_tick - 5, null)
	rollback.combat_prediction.step(blast_tick - 4, [local], false)
	assert(rollback.combat_prediction.blasts[higher["id"]]["tick"] == blast_tick
			and rollback.combat_prediction.blasts[higher["id"]]["pos"] == higher["pos"],
			"local fuse simulation must preserve the confirmed explosion")
	rollback.combat_prediction.clear()
	assert(TileDefs.sub_hp == terrain, "clearing prediction restores the shared fixture's authority HP")
	print("BLAST PREDICTION OK authority tick and position, early force, silent replay, confirmation once, ACK and Beta cancellation")
	local.free()
	world.free()

func _check_respawn_motion(world: AuthorityWorld, player: CharacterBody2D) -> void:
	player._grounded = true
	player.combat.force_down()
	assert(not player._grounded, "rotating the death collider invalidates the ground contact")
	player._grounded = true
	player.velocity = Vector2(700, 800)
	player.combat.knock_velocity = Vector2(2400, -1800)
	player.state = player.Pose.SQUAT
	player.state_lock_timer = 0.1
	player.is_squat = true
	player.is_charge = true
	player.charge_timer = 1.0
	player.climb._latched = true
	player.swim.in_water = true
	player.jump_buffer_timer = 0.1
	player.coyote_timer = 0.1
	world.respawn(player.role)
	assert(not player.is_downed() and player.rotation == 0.0)
	assert(not player._grounded and player.velocity == Vector2.ZERO)
	assert(player.combat.knock_velocity == Vector2.ZERO)
	assert(not player.is_squat and not player.is_charge)
	assert(not player.climb._latched and not player.swim.in_water)
	assert(player.jump_buffer_timer == 0.0 and player.coyote_timer == 0.0)
	assert(player.state == player.Pose.STAND and player.state_lock_timer == 0.0)
	assert(not player.hulls[0].disabled and player.hulls[1].disabled)

func _check_actor_motion() -> void:
	var world := AuthorityWorld.new()
	add_child(world)
	world.setup(PvpSession.MODE_ROYALE, "res://tests/network/arena.cyrm", [1], {}, {}, [2])
	world.set_physics_process(false)
	world._round_state = NetEvent.RoundState.PLAYING
	for actor: CharacterBody2D in world.players.values():
		assert(not actor.is_physics_processing())
	var player: CharacterBody2D = world.players[1]
	player.position = Vector2(1000, 300)
	player.gravity = 0.0
	player.collision_mask = 0
	player.velocity = Vector2(player.move_speed, 0)
	var start := player.position
	for tick in 60:
		var record := InputBuffer.neutral().merged({"seq": tick + 1, "target_tick": tick + 1, "ax": 1.0}, true)
		world.accept_input(1, {"frames": [record], "actions": []})
		world._physics_process(ActorStep.DT)
		await get_tree().physics_frame
	var distance := GridPathfinder.toroidal_delta_px(start, player.position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	assert(distance.is_equal_approx(Vector2(player.move_speed, 0)))
	print("ACTOR MOTION OK 60 ticks distance=", distance.x, " speed=", player.move_speed)
	world.free()

func _check_tick_dispatch() -> void:
	var world := AuthorityWorld.new()
	add_child(world)
	world.setup(PvpSession.MODE_PVP, "res://maps/newfactory.cyrm", [1, 2], {}, {}, [])
	world.set_physics_process(false)
	world._round_state = NetEvent.RoundState.PLAYING
	world._snap_tick = 100
	var a: CharacterBody2D = world.players[1]
	var b: CharacterBody2D = world.players[2]
	b.restore_state(a.capture_state())
	for player in [a, b]:
		player.collision_layer = 0
		player.collision_mask = 1
	var records: Array = []
	for seq in range(1, 10):
		var record := InputBuffer.neutral()
		record.merge({"seq": seq, "target_tick": 91 + seq, "ax": 1.0}, true)
		records.append(record)
	var jump: Dictionary = records[0].duplicate()
	jump["pressed"] = PacketInputSource.BIT_UP
	assert(world.accept_input(1, {"frames": records, "actions": [jump]}))
	assert(not world.accept_input(1, {"frames": records, "actions": [jump]}), "duplicate inputs need no forwarding")
	world.accept_input(2, {"frames": [records[-1]], "actions": [jump]})
	for i in 12:
		world._physics_process(ActorStep.DT)
		assert(a.position.is_equal_approx(b.position) and a.velocity.is_equal_approx(b.velocity))
		assert(a.input_buffer.ack == 9 and a.input_buffer.action_ack == 1)
		world.accept_input(1, {"frames": records, "actions": [jump]})
		await get_tree().physics_frame
	# 批量半自动点击不绕过冷却，也不让九条旧移动获得九次物理步进。
	for type_id in WeaponRegistry.all_ids():
		a.weapons.set_initial_inventory([type_id])
		if not a.weapons.current_weapon().full_auto and not a.weapons.current_weapon().heavy_aim:
			break
	var shots: int = a.shot_serial
	var clicks: Array = []
	for seq in range(10, 13):
		var click := InputBuffer.neutral()
		click.merge({"seq": seq, "target_tick": world._snap_tick, "pressed": PacketInputSource.BIT_ATTACK,
			"winst": a.weapons.current_inst()}, true)
		clicks.append(click)
	world.accept_input(1, {"frames": [], "actions": clicks})
	for i in 3:
		world._physics_process(ActorStep.DT)
		await get_tree().physics_frame
	assert(a.shot_serial == shots + 1 and a.input_buffer.action_ack == 12)
	# 引用相同武器不会重新装备并取消换弹；不存在的旧武器动作不会对另一把枪生效。
	var weapon: WeaponBase = a.weapons.current_weapon()
	weapon.start_reload()
	a.weapons.equip_inst(a.weapons.current_inst())
	assert(a.weapons.current_weapon() == weapon and weapon.is_reloading())
	var wrong := InputBuffer.neutral()
	wrong.merge({"seq": 13, "target_tick": world._snap_tick + 1, "pressed": PacketInputSource.BIT_ATTACK, "winst": 99999}, true)
	world.accept_input(1, {"frames": [], "actions": [wrong]})
	world._physics_process(ActorStep.DT)
	assert(a.shot_serial == shots + 1 and a.input_buffer.action_ack == 13)
	# RTT 为初始提前量；只使用新的到达余量样本，缺包时不反复调同一反馈。
	var clock := PredictionRollback.new()
	clock.bind(a)
	clock.reset(1, 0, 1000, 80)
	assert(clock._clock == 1007.0)
	var own := {"epoch": 1, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": -4,
		"rewind": false, "state": a.capture_state(), "input": InputBuffer.neutral()}
	for seq in range(1, 21):
		own["timing_seq"] = seq
		clock.reconcile(own, 1000, 80)
	assert(clock._rate > 1.0)
	for seq in range(21, 61):
		own["timing_seq"] = seq
		own["lead"] = 8
		clock.reconcile(own, 1000, 80)
	assert(clock._rate < 1.0)
	var previous: float = clock._rate
	own["lead"] = -100
	clock.reconcile(own, 1000, 80)
	assert(clock._rate == previous)
	# 到达余量只改变后续时钟速率，已发送输入与当前模拟时间不跳变。
	clock.reset(1, 0, 1000, 300)
	var src := PacketInputSource.new()
	var input := InputBuffer.neutral()
	input["pressed"] = PacketInputSource.BIT_UP
	src.apply_packet(input)
	clock.capture(src, Vector2.RIGHT, 1000, 0)
	clock.capture(src, Vector2.RIGHT, 1000, 0)
	var targets: Array = clock.history.map(func(record: Dictionary): return record["target_tick"])
	var action_targets: Array = clock.actions.map(func(record: Dictionary): return record["target_tick"])
	own["timing_seq"] = 1
	own["lead"] = 20
	clock.reconcile(own, 1000, 300)
	assert(clock._clock == 1020.0 and clock._rate < 1.0)
	assert(clock.history.map(func(record: Dictionary): return record["target_tick"]) == targets)
	assert(clock.actions.map(func(record: Dictionary): return record["target_tick"]) == action_targets)
	own["timing_seq"] = 2
	own["lead"] = -20
	clock.reconcile(own, 1000, 300)
	assert(clock._clock == 1020.0 and not clock.diagnostics.has("retime_ticks"))
	assert(clock.packet()["frames"].map(func(record: Dictionary): return record["target_tick"]) == targets)
	print("PREDICTION CLOCK OK immutable input timestamps and continuous adjustment")
	# 未确认动作按输入序号保留有限窗口。
	clock.reset(1, 0, 1000, 0)
	for tick in 200:
		clock._clock += 1.0
		clock.capture(src, Vector2.RIGHT, 1000, 0)
		# 含期限端点与 target_tick=clock+1 的待模拟输入。
		assert(clock.packet()["actions"].size() <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS + 2)
	assert(clock.packet()["actions"][0]["seq"] > 100)
	assert(clock.history.size() == PredictionRollback.KEEP and clock.packet()["frames"].size() == InputBuffer.REDUNDANCY)
	world.free()

func _check_prediction(player: CharacterBody2D, world: AuthorityWorld) -> void:
	_check_prediction_horizon()
	# 容量满时原位替换武器，再恢复同实例 ID 的不同类型快照。
	player.weapons.set_initial_inventory([2, 6])
	player.weapons.equip_index(1)
	var original: Dictionary = player.capture_state()
	var original_inst: int = player.weapons.current_inst()
	player.weapons.current_weapon().mag_ammo = 7
	assert(player.weapons.pick_up(5, 2) == 6)
	var replaced: Dictionary = player.capture_state()
	assert(replaced["winst"] == original_inst and replaced["mag"] == 2)
	assert(player.weapons.take_last_dropped()["mag"] == 7)
	for state in [original, replaced, original, replaced]:
		player.restore_state(state)
		var weapon: WeaponBase = player.weapons.current_weapon()
		var entry: Dictionary = state["inv"].filter(func(item: Dictionary) -> bool: return item["inst"] == state["winst"])[0]
		assert(player.weapons.log_state()["consistent"])
		assert(weapon.scene_file_path == WeaponRegistry.scene_of(entry["type"]))
		assert(weapon.mag_ammo == state["mag"] and player.weapons.snapshot_inventory() == state["inv"])
	# 恢复到另一把武器时，旧手持弹药不能写进新的权威背包。
	player.weapons.set_initial_inventory([1, 2])
	player.weapons.equip_index(1)
	var state: Dictionary = player.capture_state()
	player.weapons.equip_index(0)
	player.weapons.current_weapon().mag_ammo = 1
	player.restore_state(state)
	assert(player.weapons.snapshot_inventory() == state["inv"])
	# 复活保留和掉落的弹药均来自各自实例。
	for i in 8:
		player.weapons.set_initial_inventory([1, 2])
		player.weapons.equip_index(1)
		player.weapons.current_weapon().mag_ammo = 1
		var before: Array = player.weapons.snapshot_inventory()
		var dropped: Array = player.weapons.random_keep_one()
		var kept: Array = player.weapons.snapshot_inventory()
		assert(kept.size() == 1 and dropped.size() == 1)
		for entry: Dictionary in kept + dropped:
			assert(before.has(entry))
	player.weapons.set_initial_inventory([3])
	player.apply_authoritative_state(player.max_hp, player.max_waterproof, false)
	player.set_controls_locked(false)
	player.present_tick(ActorStep.DT)
	state = player.capture_state()
	state["hp"] -= 1
	state["wp"] -= 1
	var changes := [0, 0, 0]
	player.hp_changed.connect(func(_hp: int, _max: int) -> void: changes[0] += 1)
	player.waterproof_changed.connect(func(_wp: int, _max: int) -> void: changes[1] += 1)
	player.weapons.inventory_changed.connect(func() -> void: changes[2] += 1)
	var rollback := PredictionRollback.new()
	rollback.bind(player)
	rollback.reset(1, 0, 0, 0)
	rollback._clock = 0.0
	player.animator.play("idle")
	for seq in range(1, 5):
		var record := InputBuffer.neutral()
		record["seq"] = seq
		if seq == 1:
			record["held"] = PacketInputSource.BIT_ATTACK
			record["pressed"] = PacketInputSource.BIT_ATTACK
		elif seq == 2:
			record["released"] = PacketInputSource.BIT_ATTACK
		record["target_tick"] = seq
		rollback.history.append(record)
		rollback.actions.append(record)
		rollback._clock = seq
		player.execute_actions(ActorStep.step(player, record))
		var preview: Line2D = player.weapons.current_weapon()._laser
		assert(preview == null or not preview.visible)
	var count := world.live_bullets().size()
	rollback.reconcile({"epoch": 1, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2, "input": InputBuffer.neutral(), "rewind": false, "state": state}, 0, 0)
	assert(world.live_bullets().size() == count)
	assert(player.shot_serial == state["shot_serial"] + 1)
	assert(player.weapons.current_weapon().mag_ammo == state["mag"] - 1)
	assert(player.animator.animation == &"idle" and changes == [0, 0, 0])
	player.present_tick(ActorStep.DT)
	assert(changes == [1, 1, 0], "unchanged weapon layout keeps its HUD nodes during reconciliation")
	player.present_tick(ActorStep.DT)
	assert(changes == [1, 1, 0])
	# 角色缩放为 2.5；世界校正 50px 必须让角色和武器各移动 50px，弹道原点保持不变。
	var canonical := player.global_position
	var muzzle: Marker2D = player.weapons.current_weapon().muzzle
	var origin: Vector2 = player.shot_origin(muzzle)
	player.correct_visual(canonical + Vector2(50, 20), false)
	assert(player.global_position == canonical)
	assert(player.visuals.global_position.is_equal_approx(canonical + Vector2(50, 20)))
	assert(player.shot_origin(muzzle).is_equal_approx(origin))
	player._process(0.025)
	assert(player.visuals.global_position.is_equal_approx(canonical + Vector2(25, 10)))
	player._process(0.025)
	assert(player.visuals.global_position.is_equal_approx(canonical))
	# 控制阶段改变时瞬间采用新出生点，清空历史并复位表现偏移。
	player.correct_visual(canonical + Vector2(50, 20), false)
	var snap := rollback.reconcile({"epoch": 2, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2, "input": InputBuffer.neutral(), "rewind": false, "state": state}, 0, 0)
	player.correct_visual(player.visuals.global_position, snap)
	assert(snap and rollback.history.is_empty() and player.visuals.position.is_zero_approx())

func _check_prediction_horizon() -> void:
	var player: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(player)
	player.set_physics_process(false)
	player.collision_layer = 0
	player.collision_mask = 0
	player.gravity = 0.0
	player.position = Vector2(1000, 1000)
	player.velocity = Vector2(720, 0)
	var initial: Dictionary = player.capture_state()
	var source := PacketInputSource.new()
	source.apply_packet(InputBuffer.neutral().merged({"ax": 1.0, "pressed": PacketInputSource.BIT_UP}, true))
	var rollback := PredictionRollback.new()
	rollback.bind(player)
	rollback.reset(1, 0, 1000, 80)
	# 持续四秒没有 STATE，客户端只在可恢复的预测窗口内推进。
	for i in 240:
		rollback.capture(source, Vector2.RIGHT, 1000, 0)
		rollback.advance(ActorStep.DT)
		assert(rollback.packet()["actions"].size() <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS + 2)
		assert(rollback._input.actions.size() <= InputBuffer.FUTURE_TICKS + InputBuffer.ACTION_TICKS + 2)
		assert(rollback._input.frames.size() <= InputBuffer.FUTURE_TICKS + 1)
	assert(rollback._sim_tick <= 1000 + PredictionRollback.MAX_REPLAY)
	assert(rollback.packet()["frames"][-1]["target_tick"] <= 1000 + PredictionRollback.MAX_REPLAY)
	assert(player.position.x - initial["pos"].x <= 720.0 * PredictionRollback.MAX_REPLAY / 60.0 + 1.0)
	var own := {"epoch": 1, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2,
			"rewind": false, "state": initial, "input": InputBuffer.neutral()}
	rollback.reconcile(own, 1060, 978)
	assert(int(rollback._clock) - 1060 <= PredictionRollback.MAX_REPLAY)
	# 恢复后 RTT 统计仍接近一秒，不可每个 STATE 都进入超预算重置。
	for tick in range(1062, 1082, 2):
		for i in 2:
			rollback.capture(source, Vector2.RIGHT, tick, 0)
			rollback.advance(ActorStep.DT)
		rollback.reconcile(own, tick, 978)
		assert(rollback.diagnostics["reason"] == "")
		assert(rollback.diagnostics["replay_ticks"] <= PredictionRollback.MAX_REPLAY)
	player.free()

func _check_motion_hulls() -> void:
	var viewport := SubViewport.new()
	viewport.world_2d = World2D.new()
	add_child(viewport)
	var player: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	viewport.add_child(player)
	player.enable_manual_simulation()
	player.position = Vector2(1000, 1000)
	player.collision_layer = 0
	player.collision_mask = 1
	var standing: Rect2 = player.collision_rect()
	for pose in player.Pose.values():
		player.state = pose
		player.apply_collision_pose()
		assert(player.collision_rect().is_equal_approx(standing), "animation changes must not resize the movement hull")
	player.set_crouched(true)
	var crouched: Rect2 = player.collision_rect()
	assert(is_equal_approx(standing.end.y, crouched.end.y) and standing.size.x == crouched.size.x,
			"crouching keeps the same feet position and width")
	var ceiling := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	shape.shape = RectangleShape2D.new()
	shape.shape.size = Vector2(200, 10)
	ceiling.position = Vector2(1000, (standing.position.y + crouched.position.y) / 2.0 - 5.0)
	ceiling.add_child(shape)
	viewport.add_child(ceiling)
	await get_tree().physics_frame
	player.set_crouched(false)
	assert(player.is_squat, "uncrouching requires enough headroom")
	assert(player.position == Vector2(1000, 1000), "a blocked stance change must not recover the player through the ceiling")
	ceiling.free()
	player.set_crouched(false)
	assert(not player.is_squat and player.collision_rect().is_equal_approx(standing))
	var wall := StaticBody2D.new()
	shape = CollisionShape2D.new()
	shape.shape = RectangleShape2D.new()
	shape.shape.size = Vector2(64, 500)
	wall.position = Vector2(standing.position.x - 33, 1000)
	wall.add_child(shape)
	viewport.add_child(wall)
	await get_tree().physics_frame
	var position := player.position
	player.velocity = Vector2(600, 0)
	player.combat.knock_velocity = Vector2(-600, 0)
	ActorStep._move(player, ActorStep.DT)
	assert(player.position.is_equal_approx(position), "movement and knockback must collide as a single displacement")
	player.velocity = Vector2.ZERO
	player.combat.knock_velocity = Vector2(-600, 0)
	ActorStep._move(player, ActorStep.DT)
	assert(player.combat.knock_velocity.x == 0.0, "a wall clips the external velocity as well as normal movement")
	viewport.free()

func _check_player_platforms() -> void:
	var viewport := SubViewport.new()
	viewport.world_2d = World2D.new()
	add_child(viewport)
	var rider: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	var carrier: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	rider.position = Vector2(1000, 890)
	carrier.position = Vector2(1000, 1000)
	for player: CharacterBody2D in [rider, carrier]:
		viewport.add_child(player)
		player.enable_manual_simulation()
		player.collision_layer = 0
		player.collision_mask = 2
		player.restore_state(player.capture_state())
	carrier.combat.force_down()
	var blocker := ActorCollider.new(carrier, 2)
	rider.actor_colliders.append(blocker)
	await get_tree().physics_frame
	for tick in 8:
		rider.velocity = Vector2(0, 400)
		ActorStep.step(rider, InputBuffer.neutral())
		await get_tree().physics_frame
	assert(rider._grounded, "players still collide")
	var before := rider.position
	carrier.position.x += 400
	carrier.apply_authoritative_state(carrier.max_hp, carrier.max_waterproof, false)
	await get_tree().physics_frame
	rider.velocity = Vector2.ZERO
	ActorStep.step(rider, InputBuffer.neutral())
	assert(rider.position.distance_to(before) <= rider.floor_snap_length + 0.01, "player respawn must not carry another player")
	assert(rider.velocity.length() < 1.0, "player respawn must not add platform velocity")
	viewport.free()

func _check_seam_actor_collision() -> void:
	var viewport := SubViewport.new()
	viewport.world_2d = World2D.new()
	add_child(viewport)
	var world := AuthorityWorld.new()
	viewport.add_child(world)
	world.set_physics_process(false)
	for role in [1, 2]:
		var player: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		world.add_child(player)
		world.players[role] = player
		player.set_physics_process(false)
		player.collision_mask = 2
		player.collision_layer = 0
		player.gravity = 0.0
		player.brake_air = 0.0
		player.brake_ground = 0.0
		world._actor_colliders[role] = ActorCollider.new(player, 2)
	var moving: CharacterBody2D = world.players[1]
	var blocker: CharacterBody2D = world.players[2]
	for direction in [1.0, -1.0]:
		moving.position = Vector2(GameParameters.MAP_WIDTH - 150 if direction > 0 else 150.0, 500)
		blocker.position = Vector2(27 if direction > 0 else GameParameters.MAP_WIDTH - 27.0, 500)
		moving.velocity = Vector2(700 * direction, 0)
		var start := moving.position
		for tick in 20:
			await get_tree().physics_frame
			world._step_player(moving, InputBuffer.neutral(), ActorStep.DT)
		var distance := GridPathfinder.toroidal_delta_px(start, moving.position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		assert(distance < 130.0, "authority must block players across seam: %s" % distance)
	moving.position = Vector2(1000, 650)
	moving.velocity = Vector2(0, -600)
	blocker.position = Vector2(1000, 500)
	blocker.velocity = Vector2(0, 2000)
	await get_tree().physics_frame
	var touched := false
	for tick in 12:
		await get_tree().physics_frame
		world._step_player(moving, InputBuffer.neutral(), ActorStep.DT)
		touched = touched or is_zero_approx(moving.velocity.y)
		assert(moving.velocity.y <= 0.0, "ceiling contact must not inherit another player's falling velocity")
	assert(touched, "jumping player must hit the opponent above")
	viewport.free()

func _check_crowded_jump() -> void:
	var viewport := SubViewport.new()
	viewport.world_2d = World2D.new()
	add_child(viewport)
	var floor_body := StaticBody2D.new()
	var floor_shape := CollisionShape2D.new()
	floor_shape.shape = RectangleShape2D.new()
	floor_shape.shape.size = Vector2(1600, 64)
	floor_body.position = Vector2(800, 1032)
	floor_body.add_child(floor_shape)
	viewport.add_child(floor_body)
	var actors := []
	for role in [1, 2, 3]:
		var player: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		viewport.add_child(player)
		player.enable_manual_simulation()
		player.role = role
		player.collision_layer = 0
		player.collision_mask = 3
		player.position = Vector2(800, 942.924)
		actors.append(player)
	var player: CharacterBody2D = actors[0]
	player.state = player.Pose.FLY
	player.apply_collision_pose()
	player.velocity = Vector2(0, 600)
	var bounds := CollisionAabb.world_rect(player)
	for index in [1, 2]:
		var collider := ActorCollider.new(actors[index], 2)
		var rect := collider.world_rect(player.position)
		actors[index].position.x += bounds.position.x - rect.end.x + 0.04 if index == 1 else bounds.end.x - rect.position.x - 0.04
		player.actor_colliders.append(collider)
	for tick in 8:
		await get_tree().physics_frame
		ActorStep.step(player, InputBuffer.neutral())
		assert(player._grounded and is_zero_approx(player.velocity.y), "side pressure must preserve floor contact")
	var floor_y := player.position.y
	await get_tree().physics_frame
	ActorStep.step(player, InputBuffer.neutral().merged({"held": PacketInputSource.BIT_UP, "pressed": PacketInputSource.BIT_UP}, true))
	assert(player.position.y < floor_y - 10.0 and player.velocity.y < 0.0, "side pressure must not consume the buffered jump")
	viewport.free()

func _check_replay_contact_memory() -> void:
	var viewport := SubViewport.new()
	viewport.world_2d = World2D.new()
	add_child(viewport)
	for wall in [Rect2(1068, 600, 64, 800), Rect2(700, 1368, 600, 32)]:
		var body := StaticBody2D.new()
		var shape := CollisionShape2D.new()
		shape.shape = RectangleShape2D.new()
		shape.shape.size = wall.size
		body.position = wall.get_center()
		body.add_child(shape)
		viewport.add_child(body)
	var player: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	viewport.add_child(player)
	player.enable_manual_simulation()
	player.collision_mask = 1
	player.position = Vector2(1030, 1000)
	player.velocity = Vector2(700, 600)
	var state: Dictionary = player.capture_state()
	await get_tree().physics_frame
	ActorStep.step(player, InputBuffer.neutral().merged({"ax": 1.0}, true))
	var expected: Dictionary = player.capture_state()
	player.position = Vector2(1000, 1300)
	for tick in 8:
		await get_tree().physics_frame
		player.velocity = Vector2(0, 600)
		player.move_and_slide()
	assert(player.is_on_floor(), "fixture must prime the engine's floor contact")
	player.restore_state(state)
	ActorStep.step(player, InputBuffer.neutral().merged({"ax": 1.0}, true))
	assert(player.position.is_equal_approx(expected["pos"]), "replay must not depend on an earlier predicted floor contact")
	assert(player.velocity.is_equal_approx(expected["vel"]) and player._grounded == expected["floor"])
	player.gravity = 0.0
	for grounded in [false, true]:
		player.position = Vector2(1000, 1310.5)
		player.velocity = Vector2(0, 0 if grounded else 12)
		player._grounded = grounded
		player.state = player.Pose.STAND
		player.state_lock_timer = 100.0
		var near_floor: Dictionary = player.capture_state()
		var reference := {}
		for primed_floor in [grounded, not grounded]:
			player.position = Vector2(1000, 1310 if primed_floor else 1000)
			player.velocity = Vector2(0, 600 if primed_floor else 0)
			for tick in 2:
				await get_tree().physics_frame
				player.move_and_slide()
			assert(player.is_on_floor() == primed_floor)
			player.restore_state(near_floor)
			for tick in 6:
				await get_tree().physics_frame
				ActorStep.step(player, InputBuffer.neutral().merged({"ax": -1.0}, true))
			if reference.is_empty():
				reference = player.capture_state()
			else:
				assert(player.position.is_equal_approx(reference["pos"]), "near-floor replay must restore floor contact: %s vs %s" % [player.position, reference["pos"]])
				assert(player.velocity.is_equal_approx(reference["vel"]) and player._grounded == reference["floor"])
	player.restore_state(state)
	player.combat.force_down()
	player.combat.knock_velocity = Vector2(2400, -1800)
	var fallen: Dictionary = player.capture_state()
	var fallen_result := {}
	for mask_history in [false, true]:
		player.position = Vector2(900, 900)
		player.rotation = 0.0
		await get_tree().physics_frame
		player.restore_state(fallen)
		player.force_update_transform()
		var query_transform: Transform2D = PhysicsServer2D.body_get_state(player.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM)
		assert(query_transform.is_equal_approx(player.global_transform), "restored geometry must be queryable in the same tick")
		if mask_history:
			player.collision_mask = 3
			player.collision_mask = 1
		ActorStep.step(player, InputBuffer.neutral())
		if fallen_result.is_empty():
			fallen_result = player.capture_state()
		else:
			assert(player.position.is_equal_approx(fallen_result["pos"]), "restored rotated contact must not depend on collision query history")
			assert(player.velocity.is_equal_approx(fallen_result["vel"]))
	viewport.free()

func _check_beta_prediction() -> void:
	var viewport := SubViewport.new()
	viewport.world_2d = World2D.new()
	add_child(viewport)
	for budget in [1000.0, 5.0]:
		var reference: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		var predicted: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
		for actor: CharacterBody2D in [reference, predicted]:
			viewport.add_child(actor)
			actor.set_physics_process(false)
			actor.role = 1
			actor.collision_mask = 0
			actor.gravity = 0.0
			actor.position = Vector2(1000, 1000)
			actor.combat.knock_velocity = Vector2(2000, -1000)
		var initial: Dictionary = predicted.capture_state()
		var rules := TimeRules.new()
		rules.initial = budget
		var economy := TimeEconomy.new(rules, [1])
		var rollback := PredictionRollback.new()
		rollback.bind(predicted)
		rollback.time_economy = TimeEconomy.new(rules, [1])
		rollback.reset(1, 0, 0, 0)
		rollback._clock = 0.0
		var source := PacketInputSource.new()
		for tick in range(1, 17):
			await get_tree().physics_frame
			var record := InputBuffer.neutral()
			record.merge({"seq": tick, "target_tick": tick, "ax": 1.0,
					"held": PacketInputSource.BIT_HASTE if tick >= 3 and tick <= 12 else 0}, true)
			source.apply_packet(record)
			economy.step_haste(reference, record, ActorStep.DT)
			ActorStep.step(reference, record)
			economy.tick(ActorStep.DT)
			rollback.capture(source, Vector2.RIGHT, 0, 0)
			rollback.advance(ActorStep.DT)
			assert(predicted.position.is_equal_approx(reference.position))
		rollback.time_economy = TimeEconomy.new(rules, [1])
		rollback.reconcile({"epoch": 1, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2,
				"input": InputBuffer.neutral(), "rewind": false, "state": initial}, 0, 0)
		assert(predicted.position.is_equal_approx(reference.position))
		assert(predicted.velocity.is_equal_approx(reference.velocity))
		assert(predicted.combat.knock_velocity.is_equal_approx(reference.combat.knock_velocity))
		assert(is_equal_approx(rollback.time_economy.accounts[1].balance, economy.accounts[1].balance))
		assert(is_equal_approx(rollback.time_economy.accounts[1].short_used, economy.accounts[1].short_used))
		assert(predicted.pvp_haste_mult == 1.0)
		reference.free()
		predicted.free()
	viewport.free()

func _check_terrain_batch(world: AuthorityWorld) -> void:
	var cells: Array[Vector2i] = []
	for y in TileDefs.sub_rows:
		for x in TileDefs.sub_cols:
			var sub := Vector2i(x, y)
			if TileDefs.sub_hp[y * TileDefs.sub_cols + x] > 2 and TileDefs.explosion_destroyable(TileDefs.sub_texture(sub)):
				cells.append(sub)
			if cells.size() == 2: break
		if cells.size() == 2: break
	assert(cells.size() == 2)
	for bullet: BulletBase in world.live_bullets(): bullet.free()
	world._round_state = NetEvent.RoundState.COUNTDOWN
	world._round_timer = 100.0
	world.terrain.take_network_changes()
	var updates: Array = []
	world.event.connect(func(kind: int, data: Variant, _except_role: int) -> void:
		if kind == NetEvent.Kind.TERRAIN: updates.append(data))
	var revision := world.map_revision
	TileDefs.damage_sub(cells[0], 1, "explosion")
	TileDefs.damage_sub(cells[0], 1, "explosion")
	TileDefs.damage_sub(cells[1], 1, "explosion")
	assert(updates.is_empty() and world.map_revision == revision + 3)
	world._physics_process(ActorStep.DT)
	assert(updates.size() == 1 and updates[0]["revision"] == world.map_revision)
	assert(updates[0]["cells"].size() == 2 and world.terrain.take_network_changes().is_empty())
	for sub in cells:
		assert(updates[0]["cells"][sub] == TileDefs.sub_hp[sub.y * TileDefs.sub_cols + sub.x])
