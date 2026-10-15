extends Node

func _ready() -> void:
	_run.call_deferred()

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
	a.position = Vector2(1000, 1000)
	var bullet: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	bullet.entity_id = 777
	bullet.shooter = a
	bullet.authority_world = world
	bullet.position = Vector2(1050, 1000)
	world.add_projectile(bullet)
	bullet.set_physics_process(false)
	world._snap_tick = 30
	world.beta.tick(ActorStep.DT)
	var historical_pos := a.position
	var historical_bullet := bullet.position
	a.position += Vector2(200, 0)
	bullet.position += Vector2(200, 0)
	a.shot_serial = 100
	var other_pos := b.position
	var pickups: Dictionary = world.world_state()["pickups"]
	var map_revision := world.map_revision
	var record := InputBuffer.neutral()
	record["held"] = PacketInputSource.BIT_REWIND
	(a.input_source as PacketInputSource).apply_packet(record)
	world.beta.tick(ActorStep.DT)
	assert(a.position == historical_pos and bullet.position == historical_bullet)
	assert(b.position == other_pos and world.world_state()["pickups"] == pickups and world.map_revision == map_revision)
	assert(a.shot_serial == 100 and world.live_bullets().size() == 1)
	var epoch: int = a.input_buffer.epoch
	(a.input_source as PacketInputSource).reset_state()
	world.beta.tick(ActorStep.DT)
	assert(a.input_buffer.epoch == epoch + 1 and not a.rewinding and not bullet.is_physics_processing())
	# 死亡仅结算一次；AI 与真人共用权威步进。
	b.combat.force_down()
	world.rules.tick(world, ActorStep.DT)
	world.rules.tick(world, ActorStep.DT)
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
	await get_tree().process_frame
	print("AUTHORITY PROBE OK actor speed, six weapons, pickups, ammo, laser history, Beta scope, epochs, damage once, AI, round wins, silent replay")
	get_tree().quit()

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
	world.accept_input(1, {"frames": records, "actions": [jump]})
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
	# RTT 尖峰造成的大偏差及时修正；在途旧时基的反馈不会重复修正。
	clock.reset(1, 0, 1000, 300)
	var src := PacketInputSource.new()
	var input := InputBuffer.neutral()
	input["pressed"] = PacketInputSource.BIT_UP
	src.apply_packet(input)
	clock.capture(src, Vector2.RIGHT, 1000, 0)
	clock.capture(src, Vector2.RIGHT, 1000, 0)
	own["timing_seq"] = 1
	own["lead"] = 20
	clock.reconcile(own, 1000, 300)
	assert(clock._clock == 1002.0 and clock.history[0]["target_tick"] == 1003)
	assert(clock.actions[0]["target_tick"] == 1003)
	own["timing_seq"] = 2
	clock.reconcile(own, 1000, 300)
	assert(clock._clock == 1002.0)
	# 长时间未收到 STATE 快照时仍按模拟时间清理超时动作，防止待发队列无限积压。
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
	# 恢复到另一把武器时，旧手持弹药不能写进新的权威背包。
	player.weapons.set_initial_inventory([1, 2])
	player.weapons.equip_index(1)
	var state: Dictionary = player.capture_state()
	player.weapons.equip_index(0)
	player.weapons.current_weapon().mag_ammo = 1
	player.restore_state(state)
	assert(player.weapons.snapshot_inventory() == state["inv"])
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
		assert(not player.weapons.current_weapon()._laser.visible)
	var count := world.live_bullets().size()
	rollback.reconcile({"epoch": 1, "ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2, "input": InputBuffer.neutral(), "rewind": false, "state": state}, 0, 0)
	assert(world.live_bullets().size() == count)
	assert(player.shot_serial == state["shot_serial"] + 1)
	assert(player.weapons.current_weapon().mag_ammo == state["mag"] - 1)
	assert(player.animator.animation == &"idle" and changes == [0, 0, 0])
	player.present_tick(ActorStep.DT)
	assert(changes == [1, 1, 1])
	player.present_tick(ActorStep.DT)
	assert(changes == [1, 1, 1])
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
