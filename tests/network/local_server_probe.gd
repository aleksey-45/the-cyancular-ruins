extends Node

var _room_frame := -1

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	assert(NetBus.start_server(0) == OK)
	assert(NetBus.server_port > 0)
	NetBus.stop()
	NetBus.event_received.connect(func(_peer: int, kind: int, data: Variant) -> void:
		if kind == NetEvent.Kind.ROOM:
			assert(data["code"].length() == 8 and not data["token"].is_empty())
			_room_frame = Engine.get_physics_frames())
	var port := await LocalServer.launch_and_connect()
	assert(port > 0 and NetBus.can_send_to_server())
	NetBus.send_event(NetEvent.Kind.HELLO, {"name": "LaunchProbe", "hue": 0.0})
	NetBus.send_event(NetEvent.Kind.CREATE, {"mode": "pvp", "options": {}})

func _physics_process(_delta: float) -> void:
	if _room_frame < 0:
		return
	assert(_room_frame == Engine.get_physics_frames(), "network messages must reach simulation in the same physics tick")
	var pid := LocalServer._owned_pid
	NetBus.stop()
	LocalServer.stop_owned()
	assert(not NetSession.running(pid))
	print("LOCAL SERVER PROBE OK dynamic port, room, token, receive before simulation, owned process shutdown")
	get_tree().quit()
