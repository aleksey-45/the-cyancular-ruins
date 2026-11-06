class_name ResultScreen
extends RefCounted

const RESULT_SCENE := preload("res://ui/screens/match_result.tscn")

var _state: ClientState = null
var _ports: ClientPorts = null
var _payload_builder: Callable = Callable()
var _leave_scene: Callable = Callable()
var _result: MatchResult = null


func bind(state: ClientState, ports: ClientPorts) -> void:
	_state = state
	_ports = ports
	_payload_builder = ports.build_result_payload
	_leave_scene = ports.leave_scene


func show(payload: Variant = null) -> void:
	if _result == null:
		_result = RESULT_SCENE.instantiate()
		_ports.add_child.call(_result)
		_result.leave_requested.connect(_leave_scene)
		_result.show_result({})
	if payload == null:
		_result.show_result(_payload_builder.call())
	else:
		_result.show_result(payload)
