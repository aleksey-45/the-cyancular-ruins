extends "res://tests/case.gd"


func run(_tree: SceneTree) -> void:
	var room := {"code": "00048213", "mode": "team", "players": 3, "max": 10,
			"in_match": false, "beta": false, "port": 51234}
	var packet := LanDiscovery.encode_room(room)
	var decoded := LanDiscovery.decode_room(packet)
	expect(not decoded.is_empty(), "valid room packet decodes")
	expect(decoded["code"] == room["code"] and decoded["mode"] == room["mode"]
			and int(decoded["players"]) == 3 and int(decoded["max"]) == 10
			and int(decoded["port"]) == 51234, "decoded fields round-trip")

	expect(LanDiscovery.decode_room(PackedByteArray()).is_empty(), "empty packet is rejected")
	expect(LanDiscovery.decode_room("not json".to_utf8_buffer()).is_empty(), "invalid json is rejected")
	expect(LanDiscovery.decode_room(JSON.stringify({"v": 2, "t": "room", "code": "00048213",
			"mode": "team", "players": 1, "max": 2, "in_match": false, "beta": false,
			"port": 51234}).to_utf8_buffer()).is_empty(), "wrong version is rejected")
	expect(not LanDiscovery.valid_code("1234567") and not LanDiscovery.valid_code("1234567a"),
			"room code must be eight digits")
	expect(LanDiscovery.decode_room(JSON.stringify({"v": 1, "t": "room", "code": "1234567",
			"mode": "team", "players": 1, "max": 2, "in_match": false, "beta": false,
			"port": 51234}).to_utf8_buffer()).is_empty(), "short room code is rejected")
	expect(LanDiscovery.decode_room(JSON.stringify({"v": 1, "t": "room", "code": "12345678",
			"mode": "duel", "players": 1, "max": 2, "in_match": false, "beta": false,
			"port": 51234}).to_utf8_buffer()).is_empty(), "unknown mode is rejected")
	expect(LanDiscovery.decode_room(JSON.stringify({"v": 1, "t": "room", "code": "12345678",
			"mode": "team", "players": 5, "max": 4, "in_match": false, "beta": false,
			"port": 51234}).to_utf8_buffer()).is_empty(), "players above capacity is rejected")
	expect(LanDiscovery.decode_room(JSON.stringify({"v": 1, "t": "room", "code": "12345678",
			"mode": "team", "players": 1, "max": 4, "in_match": false, "beta": false,
			"port": 80}).to_utf8_buffer()).is_empty(), "privileged port is rejected")
	expect(LanDiscovery.decode_room(JSON.stringify({"v": 1, "t": "room", "code": "12345678",
			"mode": "team", "players": 1, "max": 4, "in_match": false, "beta": false,
			"port": 51234, "pad": "x".repeat(2048)}).to_utf8_buffer()).is_empty(),
			"oversized packet is rejected")

	var discovery := LanDiscovery.new()
	var now := 100.0
	expect(discovery.update(room, "192.168.1.10", now), "first update registers a room")
	expect(not discovery.update(room, "192.168.1.10", now + 0.5), "unchanged refresh is not a change")
	expect(discovery.rooms(now + 1.0).size() == 1, "room is listed while fresh")
	var changed := room.duplicate(true)
	changed["players"] = 4
	expect(discovery.update(changed, "192.168.1.10", now + 1.0), "roster change is reported")
	expect(discovery.rooms(now + 1.0)[0]["players"] == 4, "roster change replaces the old card")
	expect(discovery.expire(now + 1.0 + LanDiscovery.TTL + 0.1), "stale room expires")
	expect(discovery.rooms(now + 1.0 + LanDiscovery.TTL + 0.1).is_empty(),
			"expired room is not listed")

	# UDP 监听不参与自动测试(绑定固定端口会与并行测试冲突),只验证未监听时的安全行为。
	var idle := LanDiscovery.new()
	expect(not idle.poll(0.0), "poll without listening reports no change")
	idle.stop()
	expect(idle.rooms(0.0).is_empty(), "stop without listening is harmless")

	var copies := LanDiscovery.new()
	copies.update(room, "10.0.0.2", 5.0)
	var listed := copies.rooms(5.5)
	listed[0]["ip"] = "1.2.3.4"
	expect(str(copies.rooms(5.5)[0]["ip"]) == "10.0.0.2", "listed rooms are copies")
	copies.clear()
	expect(copies.rooms(5.5).is_empty(), "clear drops registered rooms")
