extends RefCounted


var _host = null
var _ports: MatchPorts = null
var _ground: GroundSystem = null


func setup(host, ports: MatchPorts) -> void:
	_host = host
	_ports = ports
	_ground = GroundSystem.new()
	_ground.bind(_host.state, _ports)


func ground() -> GroundSystem:
	return _ground


func _setup_ground_weapons() -> void:
	_ground.setup()


func ground_weapons_payload() -> Array:
	return _ground.payload()


func _handle_ground_actions(role: int, src: PacketInputSource) -> void:
	_ground.handle_actions(role, src)


func _sync_ground_positions() -> void:
	_ground.sync_positions()


func _debug_keep_weapon_within_reach() -> void:
	_ground.debug_keep_weapon_within_reach()
