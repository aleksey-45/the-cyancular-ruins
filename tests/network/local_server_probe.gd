extends Node

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	NetBus.event_received.connect(func(_peer: int, kind: int, data: Variant) -> void:
		if kind == NetEvent.Kind.ROOM:
			assert(data["code"].length() == 8 and not data["token"].is_empty())
			var pid := LocalServer._owned_pid
			NetBus.stop()
			LocalServer.stop_owned()
			assert(not NetSession.running(pid))
			print("LOCAL SERVER PROBE OK dynamic port, room, token, owned process shutdown")
			get_tree().quit())
	var port := await LocalServer.launch_and_connect()
	assert(port > 0 and NetBus.can_send_to_server())
	NetBus.send_event(NetEvent.Kind.HELLO, {"name": "LaunchProbe", "hue": 0.0})
	NetBus.send_event(NetEvent.Kind.CREATE, {"mode": "pvp", "options": {}})
