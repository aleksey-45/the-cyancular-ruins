extends "res://tests/case.gd"


class RequestRecorder extends "res://core/net/net_session.gd":
	var endpoints: Array = []

	func _room_request(_kind: int, _data: Dictionary, port: int, _timeout_ms := 8000, host := "127.0.0.1") -> RoomReply:
		endpoints.append([host, port])
		return RoomReply.new(OK)

	func _exit_tree() -> void:
		pass

func run(_tree: SceneTree) -> void:
	await _rejoin_endpoint()
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
	expect(not bool(RoomOptions.normalized("pvp", {"lan_public": false}).get("lan_public", true)),
			"lan_public false survives room option normalization")

	var discovery := LanDiscovery.new()
	var now := 100.0
	expect(discovery.update(room, "192.168.1.10", now), "first update registers a room")
	expect(not discovery.update(room, "192.168.1.10", now + 0.5), "unchanged refresh is not a change")
	expect(discovery.rooms().size() == 1, "room is listed while fresh")
	var changed := room.duplicate(true)
	changed["players"] = 4
	expect(discovery.update(changed, "192.168.1.10", now + 1.0), "roster change is reported")
	expect(discovery.rooms()[0]["players"] == 4, "roster change replaces the old card")
	expect(discovery.expire(now + 1.0 + LanDiscovery.TTL + 0.1), "stale room expires")
	expect(discovery.rooms().is_empty(),
			"expired room is not listed")

	# 绑定固定端口可能与并行测试冲突，这里验证未监听时的返回值。
	var idle := LanDiscovery.new()
	expect(not idle.poll(0.0), "poll without listening reports no change")
	idle.stop()
	expect(idle.rooms().is_empty(), "stop without listening is harmless")

	var copies := LanDiscovery.new()
	copies.update(room, "10.0.0.2", 5.0)
	var listed := copies.rooms()
	listed[0]["ip"] = "1.2.3.4"
	expect(str(copies.rooms()[0]["ip"]) == "10.0.0.2", "listed rooms are copies")
	copies.clear()
	expect(copies.rooms().is_empty(), "clear drops registered rooms")

func _rejoin_endpoint() -> void:
	var requests := RequestRecorder.new()
	var room := PvpSession.room
	var ip := NetBus.server_ip
	var port := NetBus.server_port
	var target := ["192.0.2.42", 51234]
	await requests.join_room("00048213", {"ip": target[0], "port": target[1]})
	NetBus.server_ip = target[0]
	NetBus.server_port = target[1]
	requests._on_event(1, NetEvent.Kind.ROOM, {"code": "00048213", "token": "01".repeat(16), "in_match": true})
	NetBus.server_ip = "127.0.0.1"
	NetBus.server_port = port
	await requests.rejoin_room()
	await requests.rejoin_room(true)
	expect(requests.endpoints == [target, target, target], "JOIN and both rejoin paths use the admitted LAN endpoint")
	NetBus.server_ip = ip
	PvpSession.room = room
	requests.free()
