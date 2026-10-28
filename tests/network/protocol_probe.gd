extends Node

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	_check_sparse_updates()
	_check_decode_ownership()
	_check_shared_broadcast()
	_check_input_hint_fanout()
	_check_receive_batch()
	seed(123456)
	var world := AuthorityWorld.new()
	add_child(world)
	world.setup(PvpSession.MODE_ROYALE, "res://maps/newfactory.cyrm", [1, 2], {}, {"beta": true, "time": TimeRules.new().to_dict()}, [3])
	world.set_physics_process(false)
	var player: CharacterBody2D = world.players[1]
	world.players[2].combat.knock_velocity = Vector2(1700.25, -480.5)
	await get_tree().physics_frame
	player.weapons.set_initial_inventory([1, 2, 3, 4])
	player.weapons.current_weapon()._reload_t = 0.123456789012345
	player.jump_buffer_timer = 0.987654321098765
	var movement := ProtocolFixture.input()
	movement["frames"][0].merge({"seq": 1, "target_tick": 1}, true)
	player.input_buffer.push(movement, 0)
	player.input_buffer.take(1)
	world._snap_tick = 1
	var server := NetCodec.new()
	var client := NetCodec.new()
	var initial := world.state_for(1, world.world_state())
	initial["tick"] = 100
	var first := server.encode_state(initial)
	var decoded := client.decode_state(ProtocolFixture.stream(first))
	compare(decoded, initial, "frame")
	assert(decoded == initial)
	assert(decoded["world"]["players"][2]["knock"] == Vector2(1700.25, -480.5))
	assert(decoded["world"]["projectiles"] == world.projectile_states())
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
	assert(client.encode_input(input).size() < 15 + 26 * frames.size() + 28)
	# 每个输入包独立解码；前一包丢失不影响重复目标 tick 或按键释放。
	frames[0]["held"] = 3
	frames[1]["held"] = 0
	frames[2]["aim"] = Vector2.LEFT
	frames[3]["ax"] = -0.5
	client.encode_input(input)
	var input_receiver := NetCodec.new()
	assert(input_receiver.decode_input(ProtocolFixture.stream(client.encode_input(input))) == input)
	assert(input_receiver.decode_input(ProtocolFixture.stream(client.encode_input({"frames": [], "actions": [action]}))) == {"frames": [], "actions": [action]})
	assert(input_receiver.decode_input(ProtocolFixture.stream(client.encode_input({"frames": [], "actions": []}))) == {"frames": [], "actions": []})
	assert(server.state_ack == 1)
	var scheduled := input.duplicate(true)
	for kind in scheduled:
		for record: Dictionary in scheduled[kind]:
			record["available_tick"] = maxi(record["target_tick"], 105)
	var hints := {2: {"tick": 104, "packet": scheduled}, 3: {"tick": 105, "packet": scheduled}}
	var client_ack := client.state_ack
	assert(client.decode_input_hints(ProtocolFixture.stream(server.encode_input_hints(hints))) == hints
			and client.state_ack == client_ack,
			"remote input hints must not acknowledge or reset this client's STATE baseline")
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
			"traveled": 43.25, "direct_hit": false, "fuse_active": true, "fuse_elapsed": 0.123456789, "fuse_duration": 0.4}}
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
			[NetEvent.Kind.TERRAIN, {"tick": 1000, "revision": 999, "cells": {Vector2i(12, 34): 0, Vector2i(13, 34): 3}}],
			[NetEvent.Kind.ROUND, world.round_state()], [NetEvent.Kind.KILL, [2, 1]],
			[NetEvent.Kind.HIT, {"shooter": 1, "victim": 2, "damage": 50, "pos": Vector2(1.5, 2.5),
					"id": (1 << 48) | 777, "tick": 125, "source": 0, "knock": Vector2(500, -100), "hp": -10, "facing": -1}],
			[NetEvent.Kind.FIRE, {"role": 1, "shot": 9, "type_id": 4, "sound": "shotgun"}],
			[NetEvent.Kind.BULLET_SPAWN, {"id": (1 << 48) | 777, "tick": 125, "type_id": 1, "pos": Vector2(1000, 500), "vel": Vector2(60, 0)}],
			[NetEvent.Kind.BULLET_REWIND, {"role": 1, "tick": 125, "rewind": true, "projectiles": baseline["projectiles"]}],
			[NetEvent.Kind.EXPLOSION, {"id": (1 << 48) | 777, "type_id": 5, "pos": Vector2(1000, 500), "tick": 125}],
			[NetEvent.Kind.BULLET_FUSE, {"tick": 125, "projectiles": baseline["projectiles"]}],
			[NetEvent.Kind.BULLET_END, {"tick": 130, "ids": [(1 << 48) | 777, (2 << 48) | 42]}],
			[NetEvent.Kind.BEAM, {"id": (1 << 48) | 777, "tick": 125, "type_id": 6, "shooter_role": 1, "pts": PackedVector2Array([Vector2.ONE, Vector2(2, 4)]), "origin": Vector2.ONE,
			"canonical": Vector2(500, 500), "color": UiFactory.C_TEXT_DIM, "half_width": 3.25, "lifetime": 0.123456789, "style": 0}],
			[NetEvent.Kind.MESSAGE, "消息 🌏"], [NetEvent.Kind.LEAVE, null], [NetEvent.Kind.SUICIDE, null],
			[NetEvent.Kind.START, 3], [NetEvent.Kind.PICK_TEAM, 2], [NetEvent.Kind.READY, 10], [NetEvent.Kind.MAP, "res://maps/newfactory.cyrm"],
			[NetEvent.Kind.REJOIN_DENIED, "过期"], [NetEvent.Kind.ROOM_CLOSED, "离开"]]:
		var packet := server.encode_event(entry[0], entry[1])
		if entry[0] == NetEvent.Kind.BULLET_SPAWN: assert(packet.size() == 30)
		if entry[0] == NetEvent.Kind.EXPLOSION: assert(packet.size() == 22)
		if entry[0] == NetEvent.Kind.BULLET_END: assert(packet.size() == 23)
		assert(client.decode_event(entry[0], ProtocolFixture.stream(packet)) == entry[1])
	world.queue_free()
	print("PROTOCOL PROBE OK precision, ACK baseline, loss, create/update/delete, expiry, epoch, events")
	get_tree().quit()

func _check_sparse_updates() -> void:
	var server := NetCodec.new()
	var client := NetCodec.new()
	var frame := ProtocolFixture.frame()
	frame["time"] = {1: {"b": 100.0, "w": 20.0, "l": 0.0, "win": 8.0, "m": 1.0, "cap": 100, "k": false}}
	assert(client.decode_state(ProtocolFixture.stream(server.encode_state(frame))) == frame)
	server.state_ack = client.state_ack
	frame["tick"] += 2
	var quiet := server.encode_state(frame)
	assert(quiet.size() == 18) # 17 字节头与 1 字节变化区块位图。
	assert(client.decode_state(ProtocolFixture.stream(quiet)) == frame)
	server.state_ack = client.state_ack
	frame["tick"] += 2
	frame["world"]["players"][1]["hp"] = 0
	var health := server.encode_state(frame)
	assert(health.size() == 29)
	assert(client.decode_state(ProtocolFixture.stream(health)) == frame)
	server.state_ack = client.state_ack
	frame["tick"] += 2
	frame["world"]["players"][1]["respawn_tick"] = frame["tick"] + 120
	var scheduled := server.encode_state(frame)
	assert(scheduled.size() == 29)
	assert(client.decode_state(ProtocolFixture.stream(scheduled)) == frame)
	server.state_ack = client.state_ack
	frame["tick"] += 2
	frame["own"]["state"]["inv"] = [{"inst": 17, "type": 1, "mag": 8}]
	frame["own"]["state"].merge({"winst": 17, "aiming": false, "fire_buf": false, "rld": false,
			"fire_cd": 0.123456789012345, "rld_t": 0.0, "aim_f": -1, "aim_cf": 1, "mag": 8}, true)
	assert(client.decode_state(ProtocolFixture.stream(server.encode_state(frame))) == frame)
	server.state_ack = client.state_ack
	var inventory_base := client.state_ack
	frame["tick"] += 2
	frame["time"][1]["b"] -= 0.125
	frame["own"]["input"]["target_tick"] += 1
	frame["own"]["state"]["floor"] = false
	frame["own"]["state"]["jbuf"] = 0.987654321012345
	var restored := client.decode_state(ProtocolFixture.stream(server.encode_state(frame)))
	assert(restored == frame)
	restored["own"]["state"]["inv"].clear()
	assert(client.history[inventory_base]["own"]["state"]["inv"].size() == 1)
	assert(client.history[client.latest]["own"]["state"]["inv"].size() == 1)
	server.state_ack = client.state_ack
	frame["tick"] += 2
	frame["own"]["state"]["winst"] = 18
	frame["own"]["state"]["inv"][0]["inst"] = 18
	assert(client.decode_state(ProtocolFixture.stream(server.encode_state(frame))) == frame)
	server.state_ack = client.state_ack
	frame["tick"] += 2
	frame["own"]["state"]["winst"] = 0
	frame["own"]["state"]["inv"].clear()
	for key in ["aiming", "fire_buf", "rld", "fire_cd", "rld_t", "aim_f", "aim_cf", "mag"]:
		frame["own"]["state"].erase(key)
	frame["time"].clear()
	assert(client.decode_state(ProtocolFixture.stream(server.encode_state(frame))) == frame)

func _check_decode_ownership() -> void:
	var server := NetCodec.new()
	var client := NetCodec.new()
	var frame := ProtocolFixture.frame()
	frame["world"]["players"][1]["driver"]["inv"] = [{"inst": 17, "type": 1, "mag": 8}]
	frame["world"]["players"][1]["rewind_path"] = [{"tick": 60,
			"body": {"pos": Vector2(1000, 500), "squat": false, "down": false, "facing": 1}}]
	frame["world"]["pickups"][10] = {"type_id": 1, "mag": 10, "pos": Vector2(200, 300), "vel": Vector2.ZERO}
	frame["world"]["projectiles"][100] = {"type_id": 1, "pos": Vector2(200, 100), "vel": Vector2(600, 0),
			"traveled": 0.0, "fuse_active": false, "fuse_elapsed": 0.0, "fuse_duration": 0.0, "direct_hit": false}
	frame["time"][1] = {"b": 100.0, "w": 20.0, "l": 0.0, "win": 8.0, "m": 1.0, "cap": 100, "k": false}
	var first := client.decode_state(ProtocolFixture.stream(server.encode_state(frame)))
	var original := first.duplicate(true)
	server.state_ack = client.state_ack
	frame["tick"] += 2
	var quiet := client.decode_state(ProtocolFixture.stream(server.encode_state(frame)))
	assert(quiet == frame)
	var protected_history := client.history.duplicate(true)
	quiet["world"]["players"][1]["driver"]["inv"][0]["mag"] = -1
	quiet["world"]["players"][1]["input"]["seq"] = 999
	quiet["world"]["players"][1]["rewind_path"][0]["body"]["pos"] = Vector2.ZERO
	quiet["world"]["pickups"][10]["mag"] = -1
	quiet["world"]["projectiles"][100]["pos"] = Vector2.ZERO
	quiet["own"]["state"]["hp"] = -1
	quiet["own"]["input"]["seq"] = 999
	quiet["time"][1]["b"] = -1.0
	assert(client.history == protected_history and first == original,
			"mutable decoded snapshots must not alias older outputs or any cached baseline")
	server.state_ack = client.state_ack
	frame["tick"] += 2
	frame["world"]["players"][1]["pos"].x += 12.0
	frame["world"]["pickups"][10]["pos"].x += 7.0
	frame["world"]["projectiles"][100]["traveled"] = 20.0
	frame["own"]["state"]["hp"] -= 1
	frame["time"][1]["b"] -= 0.5
	assert(client.decode_state(ProtocolFixture.stream(server.encode_state(frame))) == frame)
	for number in protected_history:
		assert(client.history[number] == protected_history[number], "delta reconstruction must not edit its baseline records")
	assert(first == original, "new delta packets must not mutate an earlier decoded output")
	print("DECODE OWNERSHIP OK unchanged sharing, nested caller mutation and baseline isolation")

func _check_shared_broadcast() -> void:
	var plain: Array[NetCodec] = []
	var cached: Array[NetCodec] = []
	var receivers: Array[NetCodec] = []
	for peer in 8:
		plain.append(NetCodec.new())
		cached.append(NetCodec.new())
		receivers.append(NetCodec.new())
	var shared := {}
	for step in 4:
		var frame := ProtocolFixture.frame(60 + step * 2)
		frame["world"]["players"][1]["pos"] += Vector2(step * 10, 0)
		frame["time"][1] = {"b": 100.0 - step, "w": 0.5, "l": 0.0,
				"k": false, "cap": 1000, "win": 10.0, "m": 3.0}
		for peer in 8:
			# 同一广播中混合全量、不同 ACK 和逐连接 own，字节必须与独立编码相同。
			var ack := 0 if peer % 2 == 0 else step
			plain[peer].state_ack = ack
			cached[peer].state_ack = ack
			frame["own"]["ack"] = peer * 10 + step
			var expected := plain[peer].encode_state(frame)
			var packet := cached[peer].encode_state(frame, shared)
			assert(packet == expected)
			assert(receivers[peer].decode_state(ProtocolFixture.stream(packet)) == frame)
		assert(shared["deltas"].size() <= 2, "equal world baselines share encoded blocks")
		frame["world"]["players"][1]["pos"] = Vector2.ZERO
		frame["own"]["state"]["hp"] = -1
		for peer in 8:
			assert(cached[peer].history[step + 1]["world"]["players"][1]["pos"] != Vector2.ZERO
					and cached[peer].history[step + 1]["own"]["state"]["hp"] == 100,
					"caller mutation cannot alter cached history")
	# 即便调用方在相同 tick 修改世界，缓存也必须失效，原历史仍保持不变。
	var reference := NetCodec.new()
	var encoding := NetCodec.new()
	var changed := ProtocolFixture.frame(99)
	assert(reference.encode_state(changed) == encoding.encode_state(changed, shared))
	changed["world"]["players"][1]["pos"] = Vector2.ZERO
	assert(reference.encode_state(changed) == encoding.encode_state(changed, shared))
	assert(encoding.history[1]["world"]["players"][1]["pos"] != Vector2.ZERO)
	print("SHARED STATE ENCODING OK per-peer ACK, exact bytes and caller isolation")

func _check_input_hint_fanout() -> void:
	var codec := NetCodec.new()
	var hints := {}
	var encoded := {}
	for role in range(1, 9):
		var packet := {"frames": [], "actions": []}
		for i in 4:
			var record: Dictionary = ProtocolFixture.input()["frames"][0]
			record.merge({"seq": 100 + i, "epoch": role, "target_tick": 120 + i,
					"available_tick": 122 + i, "aim": Vector2(role, i)}, true)
			packet["frames"].append(record)
		if role % 2 == 0:
			packet["actions"].append({"seq": 20, "epoch": role, "target_tick": 120, "available_tick": 123,
					"view_tick": 110, "pressed": 8, "released": 0, "winst": role, "aim": Vector2.LEFT})
		hints[role] = {"tick": 119 + role, "packet": packet}
		encoded[role] = codec.encode_input_hint(role, hints[role])
	for except_role in [0, 1, 8, 99]:
		var expected := hints.duplicate()
		expected.erase(except_role)
		var packet := NetCodec.pack_input_hints(encoded, except_role)
		assert(codec.decode_input_hints(ProtocolFixture.stream(packet)) == expected,
				"every recipient retains all other roles, epochs, available ticks and actions")
		# 对照原有字节布局，避免改变协议版本或 delta 的包内基线。
		var legacy := StreamPeerBuffer.new()
		legacy.put_u8(NetCodec.INPUT)
		legacy.put_u8(expected.size())
		for role in expected:
			legacy.put_u8(role)
			legacy.put_u32(expected[role]["tick"])
			codec._write_input(legacy, expected[role]["packet"], true)
		assert(packet == legacy.data_array)
	assert(NetCodec.pack_input_hints({}) == PackedByteArray([NetCodec.INPUT, 0]))
	print("INPUT HINT FANOUT OK eight roles, exact bytes, exclusion and independent packets")

func _wire(packet: PackedByteArray) -> PackedByteArray:
	var wire := PackedByteArray([NetCodec.WIRE_MAGIC, NetCodec.PROTOCOL_VERSION])
	wire.append_array(packet)
	return wire

func _check_receive_batch() -> void:
	var server := NetCodec.new()
	var client := NetCodec.new()
	var frame := ProtocolFixture.frame()
	client.decode_state(ProtocolFixture.stream(server.encode_state(frame)))
	server.state_ack = client.state_ack
	frame["tick"] += 2
	frame["world"]["players"][1]["pos"].x += 10
	var second := _wire(server.encode_state(frame))
	frame["tick"] += 2
	frame["world"]["players"][1]["pos"].x += 10
	var third := _wire(server.encode_state(frame))
	var merged := NetBus._coalesce_messages([[0, 1, second, 100], [0, 1, third, 101]])
	assert(merged.size() == 1 and merged[0][2] == third)
	merged = NetBus._coalesce_messages([[0, 1, third, 100], [0, 1, second, 101]])
	assert(merged.size() == 1 and merged[0][2] == third,
			"a late stale STATE must not replace a newer snapshot in the same batch")
	assert(client.decode_state(ProtocolFixture.stream(third.slice(2))) == frame
			and client.diagnostics["missing_base"] == 0,
			"skipping unacknowledged intermediate STATE must preserve its ACK baseline")
	var event := _wire(server.encode_event(NetEvent.Kind.MESSAGE, "barrier"))
	var input := _wire(client.encode_input(ProtocolFixture.input()))
	merged = NetBus._coalesce_messages([[0, 1, second, 100], [0, 1, event, 101],
			[0, 1, third, 102], [0, 1, input, 103], [0, 1, input, 104], [2, 1, 1000, "closed"]])
	assert(merged.size() == 6 and merged[0][2] == second and merged[1][2] == event
			and merged[2][2] == third and merged[3][3] == 103 and merged[4][3] == 104 and merged[5][0] == 2,
			"reliable and connection events must preserve receive-order barriers")
	merged = NetBus._coalesce_messages([[0, 1, second, 100], [0, 2, third, 101]])
	assert(merged.size() == 2, "different peers have independent latest messages")
	var earlier := {"frames": [], "actions": []}
	var later := {"frames": [], "actions": []}
	for tick in range(101, 109):
		var packet: Dictionary = earlier if tick < 105 else later
		var record := InputBuffer.neutral().merged({"seq": tick, "target_tick": tick,
				"ax": 1.0 if tick % 2 else -1.0}, true)
		packet["frames"].append(record)
		if tick in [102, 106]: packet["actions"].append(record.merged({"pressed": PacketInputSource.BIT_UP}, true))
	var first_input := _wire(client.encode_input(earlier))
	var last_input := _wire(client.encode_input(later))
	# 旧包迟到且包含最新包没有的未来帧；重复包不能重复执行动作。
	merged = NetBus._coalesce_messages([[0, 1, last_input, 100], [0, 1, first_input, 101], [0, 1, last_input, 102]])
	assert(merged.size() == 3, "INPUT must retain novel records from every received packet")
	var buffer := InputBuffer.new()
	for message: Array in merged: buffer.push(server.decode_input(ProtocolFixture.stream(message[2].slice(2))), 100)
	for tick in range(101, 109):
		var command := buffer.take(tick)
		assert(command["seq"] == tick and command["ax"] == (1.0 if tick % 2 else -1.0))
		assert(command["pressed"] == (PacketInputSource.BIT_UP if tick in [102, 106] else 0))
	print("RECEIVE BATCH OK ordered STATE, complete INPUT records, duplicate actions, ACK baseline and reliable barriers")

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
