extends PlayerInput

# 3v3 真链路探针(tests/e2e/team_match_probe.*)的脚本手柄:一根哑手柄 —— 它自己不做任何决策,只把观察者(team_match_watcher.gd)每物理帧写进来的 axis / aim / attack / 一次性边沿(jump / switch_index / F)报给输入读口。

var axis := 0.0
var aim := Vector2.RIGHT
var attack := false
var _edges: Dictionary = {}

func _set_edge(name: String) -> void:
	_edges[name] = Engine.get_physics_frames()


func _edge_now(name: String) -> bool:
	return int(_edges.get(name, -1)) == Engine.get_physics_frames()

var hold_up := false
var hold_down := false

var _switch_index := 0


func source_kind() -> int:
	return Kind.AI



func press_jump() -> void:
	_set_edge("jump")


func press_switch_index(i: int) -> void:
	_switch_index = i
	_set_edge("switch_index")


func press_f() -> void:
	_set_edge("pickup")



func _axis_raw(neg: String, _pos: String) -> float:
	if neg == "left":
		return axis
	return (1.0 if hold_down else 0.0) - (1.0 if hold_up else 0.0)


func _action_pressed_raw(action: String) -> bool:
	match action:
		"attack":
			return attack
		"up":
			return hold_up
		"down":
			return hold_down
	return false


func _action_just_pressed_raw(action: String) -> bool:
	match action:
		"attack":
			return _edge_now("atk")
		"up":
			return _edge_now("jump")
	return false


func _action_just_released_raw(action: String) -> bool:
	if action == "attack":
		return _edge_now("atk_rel")
	return false


func _attack_pressed_raw() -> bool:
	return attack


func _attack_just_pressed_raw() -> bool:
	return _edge_now("atk")


func _attack_just_released_raw() -> bool:
	return _edge_now("atk_rel")


func press_attack_edge() -> void:
	_set_edge("atk")


func release_attack_edge() -> void:
	_set_edge("atk_rel")


func _switch_index_raw() -> int:
	return _switch_index if _edge_now("switch_index") else 0


func _pickup_pressed_raw() -> bool:
	return _edge_now("pickup")


func _drop_pressed_raw() -> bool:
	var v := _drop_edge
	_drop_edge = false
	return v


func get_aim_dir_override() -> Vector2:
	return aim


func is_network_driven() -> bool:
	return true
