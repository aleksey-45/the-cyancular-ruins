class_name AiInputSource
extends PlayerInput


var axis := 0.0
var aim := Vector2.RIGHT
var fire := false
var _jump_edge := false

func source_kind() -> int:
	return Kind.AI


func press_jump() -> void:
	_jump_edge = true


func _axis_raw(neg: String, _pos: String) -> float:
	return axis if neg == "left" else 0.0

func _action_pressed_raw(_action: String) -> bool:
	return false

func _action_just_pressed_raw(action: String) -> bool:
	if action == "up":
		var v := _jump_edge
		_jump_edge = false
		return v
	return false

func _action_just_released_raw(_action: String) -> bool:
	return false

func _attack_pressed_raw() -> bool:
	return fire

func _attack_just_pressed_raw() -> bool:
	return fire

func _attack_just_released_raw() -> bool:
	return false

func _switch_index_raw() -> int:
	return 0

func _pickup_pressed_raw() -> bool:
	return false

func _drop_pressed_raw() -> bool:
	return false

func get_aim_dir_override() -> Vector2:
	return aim

func is_network_driven() -> bool:
	return true
