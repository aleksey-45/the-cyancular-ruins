extends "res://tests/case.gd"


class TestTunnel extends Tunnel:
	var calls := 0
	var available := true
	func start_client(_code: String, _deadline: int) -> Dictionary:
		calls += 1
		return {"port": 43210} if available else {"error": "offline"}

class RequestRecorder extends "res://core/net/net_session.gd":
	var endpoints: Array = []
	var requests: Array = []
	var direct_available := true

	func _connect_endpoint(endpoint: Dictionary, _timeout_ms: int) -> Error:
		endpoints.append(endpoint)
		return OK if direct_available or endpoint.port == 43210 else ERR_CANT_CONNECT

	func _request(kind: int, data: Variant, _end_ms := 0) -> Reply:
		requests.append([kind, data])
		var reply := Reply.new()
		reply.status = OK
		_on_event(1, NetEvent.Kind.ROOM, {"code": data.code, "host_role": 1, "your_role": 2,
					"token": "01".repeat(16), "in_match": false})
		return reply

func run(tree: SceneTree) -> void:
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
	expect(not RoomSummary.valid_code("1234567") and not RoomSummary.valid_code("1234567a"),
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
	expect(not RoomOptions.DEFAULTS.has("listed_nearby"), "discovery visibility is separate from game rules")

	var discovery := LanDiscovery.new()
	var now := 100.0
	expect(discovery.update(room, "192.168.1.10", now), "first update registers a room")
	expect(not discovery.update(room, "192.168.1.10", now + 0.5), "unchanged refresh is not a change")
	expect(not discovery.update(room, "192.168.1.11", now + 0.6) and discovery.endpoint(room.code, now + 0.6).ip == "192.168.1.11",
			"a route-only change updates the address without rebuilding the card")
	expect(discovery.rooms().size() == 1, "room is listed while fresh")
	var changed := room.duplicate(true)
	changed["players"] = 4
	expect(discovery.update(changed, "192.168.1.10", now + 1.0), "roster change is reported")
	expect(discovery.rooms()[0].occupied == 4, "roster change replaces the old card")
	expect(discovery.expire(now + 1.0 + LanDiscovery.TTL + 0.1), "stale room expires")
	expect(discovery.rooms().is_empty(),
			"expired room is not listed")

	# 绑定固定端口可能与并行测试冲突，这里验证未监听时的返回值。
	var idle := LanDiscovery.new()
	expect(not idle.poll(0.0), "poll without listening reports no change")
	idle.stop()
	expect(idle.rooms().is_empty(), "stop without listening is harmless")

	discovery.update(room, "10.0.0.2", now)
	var card := discovery.rooms()[0]
	card.occupied = 0
	expect(discovery.rooms()[0].occupied == 3 and discovery.endpoint(room.code, now).ip == "10.0.0.2",
			"cards expose independent summaries and the directory keeps the route")
	expect(discovery.endpoint(room.code, now + 4).is_empty(), "expired addresses are never selected")
	await _room_paths(tree, room)
	_join_controls(tree, room.code)

func _join_controls(tree: SceneTree, code: String) -> void:
	var lobby := LobbyView.new()
	tree.root.add_child(lobby)
	lobby.mount("host", preload("res://scenes/mp_lobby.gd")._form_values())
	var attempts: Array[String] = []
	lobby.join_requested.connect(func(value: String) -> void: attempts.append(value))
	lobby._join_button.pressed.emit()
	expect(lobby._code.has_focus() and lobby._code.is_editing() and attempts.is_empty(),
			"joining without a code focuses the toolbar field")
	lobby._code.text = code
	lobby._code.text_submitted.emit(code)
	lobby._join_button.pressed.emit()
	expect(attempts == [code, code], "Enter and Join each submit the same room code once")
	lobby._create_button.pressed.emit()
	expect(lobby._create.is_ancestor_of(tree.root.gui_get_focus_owner())
			and lobby._join_button.get_focus_mode_with_override() == Control.FOCUS_NONE,
			"opening the create form keeps keyboard focus inside it")
	lobby.close_create()
	expect(lobby._create_button.has_focus(), "closing the form returns focus to Create")
	lobby.free()

func _room_paths(tree: SceneTree, info: Dictionary) -> void:
	var session := RequestRecorder.new()
	var tunnel := TestTunnel.new()
	session._tunnel = tunnel
	tree.root.add_child(session)
	var code: String = info.code
	var direct := {"ip": "192.0.2.42", "port": info.port}
	var forwarded := {"ip": "127.0.0.1", "port": 43210}
	session._discovery.update(info, direct.ip, Time.get_ticks_msec() / 1000.0)
	await session.join_room(code)
	expect(session.endpoints == [direct] and tunnel.calls == 0 and not session.room.has("token"),
			"joining a discovered code uses the direct address and keeps the credential private")
	session._discovery.stop()
	await session.rejoin_room()
	expect(session.endpoints.back() == direct and session.requests.back()[0] == NetEvent.Kind.REJOIN,
			"rejoin uses the admitted endpoint after discovery expires")
	session.direct_available = false
	await session.rejoin_room()
	expect(session.endpoints.slice(-2) == [direct, forwarded] and session.requests.back()[1].token == "01".repeat(16),
			"a failed direct reconnect switches path and keeps the original seat credential")
	session.direct_available = true
	tunnel.available = false
	session._discovery.update(info, direct.ip, Time.get_ticks_msec() / 1000.0)
	await session.rejoin_room()
	expect(session.endpoints.back() == direct and not session._tunneled, "a tunnel guest can recover over LAN")
	tunnel.available = true
	session._discovery.stop()
	await session.join_room(code)
	expect(session.endpoints.back() == forwarded, "an unlisted code resolves through the tunnel")
	session.free()
