extends Node

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	seed(123456)
	var world := AuthorityWorld.new()
	add_child(world)
	world.setup(PvpSession.MODE_ROYALE, "res://maps/newfactory.cyrm", [1, 2], {}, {"beta": true, "time": TimeRules.new().to_dict()}, [3])
	world.set_physics_process(false)
	var player: CharacterBody2D = world.players[1]
	await get_tree().physics_frame
	player.weapons.set_initial_inventory([1, 2, 3, 4])
	player.weapons.current_weapon()._reload_t = 0.123456789012345
	player.jump_buffer_timer = 0.987654321098765
	var movement := ProtocolFixture.input()
	movement["frames"][0].merge({"seq": 1, "target_tick": 1}, true)
	player.input_buffer.push(movement, 0)
	player.input_buffer.take(1)
	var server := NetCodec.new()
	var client := NetCodec.new()
	var initial := world.state_for(1, world.world_state())
	initial["tick"] = 100
	var first := server.encode_state(initial)
	var decoded := client.decode_state(ProtocolFixture.stream(first))
	compare(decoded, initial, "frame")
	assert(decoded == initial)
	assert(not decoded["world"].has("projectiles"))
	assert(client.history[1]["own"]["state"]["rld_t"] == player.weapons.current_weapon()._reload_t)
	# 输入保留不同目标时间、非连续动作，以及独立快照 ACK。
	var frames: Array = []
	for i in 4:
		var record := InputBuffer.neutral()
		for key in ["pressed", "released", "winst"]: record.erase(key)
		record.merge({"seq": 80 + i, "epoch": 7, "target_tick": 101 + i / 2, "view_tick": -1, "ax": 0.125}, true)
		frames.append(record)
	var action := {"seq": 41, "epoch": 7, "target_tick": 99, "view_tick": 90, "pressed": 256, "released": 8, "winst": 11, "aim": Vector2.LEFT}
	var input := {"frames": frames, "actions": [action]}
	assert(server.decode_input(ProtocolFixture.stream(client.encode_input(input))) == input)
	assert(server.state_ack == 1)
	var id := 1000000
	var second := initial.duplicate(true)
	second["tick"] = 102
	second["world"]["pickups"][id] = {"type_id": 1, "mag": 10, "pos": Vector2(1100, 500), "vel": Vector2(900, 0)}
	server.encode_state(second) # 故意丢包，未确认。
	var third := second.duplicate(true)
	third["tick"] = 104
	third["world"]["pickups"][id]["pos"].x += 30.0
	third["world"]["pickups"].erase(third["world"]["pickups"].keys()[0])
	third["world"]["players"].erase(2)
	var third_packet := server.encode_state(third)
	assert(client.decode_state(ProtocolFixture.stream(third_packet)) == third)
	assert(client.decode_state(ProtocolFixture.stream(first)).is_empty())
	assert(client.diagnostics["serial_skips"] == 1 and client.diagnostics["stale"] == 1)
	# 外部代码修改快照不能修改解码基线；省略表示沿用，空列表不会删除未变化拾取物。
	server.decode_input(ProtocolFixture.stream(client.encode_input(input)))
	var stable := third.duplicate(true)
	stable["tick"] = 106
	var stable_packet := server.encode_state(stable)
	var restored := client.decode_state(ProtocolFixture.stream(stable_packet))
	assert(restored == stable and stable_packet.size() < third_packet.size())
	restored["own"]["state"]["inv"].clear()
	assert(not client.history[client.latest]["own"]["state"]["inv"].is_empty())
	# 显式消失、控制阶段及背包更换。
	server.decode_input(ProtocolFixture.stream(client.encode_input(input)))
	var fourth := stable.duplicate(true)
	fourth["tick"] = 108
	fourth["world"]["pickups"].clear()
	fourth["own"]["epoch"] = 8
	fourth["own"]["state"]["inv"][0]["mag"] = 1
	assert(client.decode_state(ProtocolFixture.stream(server.encode_state(fourth))) == fourth)
	# 基线过期走全量；客户端意外失去基线时通过 INPUT ACK=0 恢复。
	for i in NetCodec.KEEP + 1:
		fourth["tick"] += 2
		server.encode_state(fourth)
	assert(server.history.size() == NetCodec.KEEP)
	assert(client.decode_state(ProtocolFixture.stream(server.encode_state(fourth))) == fourth)
	server.decode_input(ProtocolFixture.stream(client.encode_input(input)))
	client.history.clear()
	fourth["tick"] += 2
	assert(client.decode_state(ProtocolFixture.stream(server.encode_state(fourth))).is_empty())
	assert(client.state_ack == 0)
	assert(client.diagnostics["missing_base"] == 1)
	server.decode_input(ProtocolFixture.stream(client.encode_input(input)))
	assert(client.decode_state(ProtocolFixture.stream(server.encode_state(fourth))) == fourth)
	# 可靠基线改变控制阶段并重新建缓存；旧 STATE 不可污染新回合。
	var baseline := ProtocolFixture.baseline()
	baseline["projectiles"] = {(1 << 48) | 777: {"type_id": 1, "pos": Vector2(1000, 500), "vel": Vector2(60, 0),
			"traveled": 43.25, "fuse_active": true, "fuse_elapsed": 0.123456789, "fuse_duration": 0.4}}
	baseline["frame"] = fourth
	var old_packet := server.encode_state(fourth)
	assert(client.decode_event(NetEvent.Kind.BASELINE, ProtocolFixture.stream(server.encode_event(NetEvent.Kind.BASELINE, baseline))) == baseline)
	assert(client.decode_state(ProtocolFixture.stream(old_packet)).is_empty())
	assert(client.history.size() == 1)
	var room := RoomSession.new()
	room.code = "00001234"
	room.host_role = 1
	room.mode = PvpSession.MODE_TEAM
	room.seats = {1: {"name": "玩家 🌏", "team": 1}, 2: {"name": "玩家二", "team": 2}}
	var room_data := room.room_data()
	room_data.merge({"invite_code": "00001", "your_role": 1, "token": "00112233445566778899aabbccddeeff"})
	assert(client.decode_event(NetEvent.Kind.ROOM, ProtocolFixture.stream(server.encode_event(NetEvent.Kind.ROOM, room_data))) == room_data)
	room_data = room.room_data()
	room_data.merge({"joinable": false, "rejoinable": true})
	assert(client.decode_event(NetEvent.Kind.ROOMS, ProtocolFixture.stream(server.encode_event(NetEvent.Kind.ROOMS, [room_data]))) == [room_data])
	room.free()
	for type_id in WeaponRegistry.all_ids():
		var weapon: WeaponBase = load(WeaponRegistry.scene_of(type_id)).instantiate()
		if not weapon is LaserWeaponBase:
			var profile := WeaponRegistry.projectile_profile(type_id)
			assert(profile["scene"] == weapon.bullet_scene and profile["range"] == weapon.bullet_range)
			assert(profile["size"] == weapon.bullet_size and profile["color"] == weapon.bullet_color)
			assert(profile["gravity"] == weapon.bullet_gravity)
		weapon.free()
	for entry in [[NetEvent.Kind.HELLO, {"name": "玩家 α", "hue": 0.987654321}],
			[NetEvent.Kind.CREATE, {"mode": PvpSession.MODE_TEAM, "options": {"is_public": false, "invite_code": "0123", "beta": true, "time": TimeRules.new().to_dict(), "disabled_weapons": [2, 4]}}],
			[NetEvent.Kind.JOIN, {"code": "00001234", "invite": "中文", "beta": true}],
			[NetEvent.Kind.LIST, {"token": "00112233445566778899aabbccddeeff", "beta": false}],
			[NetEvent.Kind.REJOIN, {"code": "00001234", "token": "00112233445566778899aabbccddeeff"}],
			[NetEvent.Kind.TERRAIN, {"revision": 999, "sub": Vector2i(12, 34), "hp": 0}],
			[NetEvent.Kind.ROUND, world.round_state()], [NetEvent.Kind.KILL, [2, 1]],
			[NetEvent.Kind.HIT, {"shooter": 1, "victim": 2, "damage": 50, "pos": Vector2(1.5, 2.5)}],
			[NetEvent.Kind.FIRE, {"role": 1, "shot": 9, "type_id": 4, "sound": "shotgun"}],
			[NetEvent.Kind.BULLET_SPAWN, {"id": (1 << 48) | 777, "type_id": 1, "pos": Vector2(1000, 500), "vel": Vector2(60, 0)}],
			[NetEvent.Kind.BULLET_REWIND, {"role": 1, "rewind": true, "projectiles": baseline["projectiles"]}],
			[NetEvent.Kind.BEAM, {"shooter_role": 1, "pts": PackedVector2Array([Vector2.ONE, Vector2(2, 4)]), "origin": Vector2.ONE,
			"canonical": Vector2(500, 500), "color": UiFactory.C_TEXT_DIM, "half_width": 3.25, "lifetime": 0.123456789, "style": 0}],
			[NetEvent.Kind.MESSAGE, "消息 🌏"], [NetEvent.Kind.LEAVE, null], [NetEvent.Kind.SUICIDE, null],
			[NetEvent.Kind.START, 3], [NetEvent.Kind.PICK_TEAM, 2], [NetEvent.Kind.READY, 10], [NetEvent.Kind.MAP, "res://maps/newfactory.cyrm"],
			[NetEvent.Kind.REJOIN_DENIED, "过期"], [NetEvent.Kind.ROOM_CLOSED, "离开"]]:
		var packet := server.encode_event(entry[0], entry[1])
		if entry[0] == NetEvent.Kind.BULLET_SPAWN: assert(packet.size() == 26)
		assert(client.decode_event(entry[0], ProtocolFixture.stream(packet)) == entry[1])
	world.queue_free()
	print("PROTOCOL PROBE OK precision, ACK baseline, loss, create/update/delete, expiry, epoch, events")
	get_tree().quit()

func compare(actual: Variant, expected: Variant, path: String) -> void:
	if actual is Dictionary and expected is Dictionary:
		for key in actual:
			if not expected.has(key): print("EXTRA ", path, ".", key)
		for key in expected:
			if not actual.has(key): print("MISSING ", path, ".", key)
			else: compare(actual[key], expected[key], path + "." + str(key))
	elif actual is Array and expected is Array:
		for i in mini(actual.size(), expected.size()): compare(actual[i], expected[i], path + "[" + str(i) + "]")
		if actual.size() != expected.size(): print("SIZE DIFF ", path)
	elif typeof(actual) != typeof(expected):
		print("TYPE DIFF ", path, ": ", typeof(actual), " != ", typeof(expected), " value=", expected)
	elif actual != expected:
		print("DIFF ", path, ": ", actual, " != ", expected)
