class_name PlayerInput
extends RefCounted

var frozen := false

enum Kind { LOCAL, PACKET, AI }


func source_kind() -> int:
	push_error("PlayerInput: 子类必须覆写 source_kind()")
	return -1



func get_axis(neg: String, pos: String) -> float:
	if frozen:
		return 0.0
	return _axis_raw(neg, pos)

func is_action_pressed(action: String) -> bool:
	return not frozen and _action_pressed_raw(action)

func is_action_just_pressed(action: String) -> bool:
	return not frozen and _action_just_pressed_raw(action)

func is_action_just_released(action: String) -> bool:
	return not frozen and _action_just_released_raw(action)

func is_attack_pressed() -> bool:
	return not frozen and _attack_pressed_raw()

func is_attack_just_pressed() -> bool:
	return not frozen and _attack_just_pressed_raw()

func is_attack_just_released() -> bool:
	return not frozen and _attack_just_released_raw()

func get_switch_index_pressed() -> int:
	if frozen:
		return 0
	return _switch_index_raw()

func is_pickup_pressed() -> bool:
	return not frozen and _pickup_pressed_raw()

func is_drop_pressed() -> bool:
	return not frozen and _drop_pressed_raw()


func consume_switch_inst() -> int:
	if frozen:
		return 0
	return _switch_inst_raw()



func _axis_raw(_neg: String, _pos: String) -> float:
	push_error("PlayerInput: 子类必须覆写 _axis_raw();本地输入请用 LocalInputSource")
	return 0.0

func _action_pressed_raw(_action: String) -> bool:
	push_error("PlayerInput: 子类必须覆写 _action_pressed_raw()")
	return false

func _action_just_pressed_raw(_action: String) -> bool:
	push_error("PlayerInput: 子类必须覆写 _action_just_pressed_raw()")
	return false

func _action_just_released_raw(_action: String) -> bool:
	push_error("PlayerInput: 子类必须覆写 _action_just_released_raw()")
	return false

func _attack_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _attack_pressed_raw()")
	return false

func _attack_just_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _attack_just_pressed_raw()")
	return false

func _attack_just_released_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _attack_just_released_raw()")
	return false

func _switch_index_raw() -> int:
	push_error("PlayerInput: 子类必须覆写 _switch_index_raw()")
	return 0


func _switch_inst_raw() -> int:
	return 0

func _pickup_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _pickup_pressed_raw()")
	return false

# 可选钩子(默认空操作):长按 Q 满阈值的那次边沿由本地实现提供 —— 计时在 player.gd 物理帧做(delta 确定),做完调 mark_drop_edge() 打标,pack_record 组包时取走。
var _drop_edge := false

func mark_drop_edge() -> void:
	_drop_edge = true


func _drop_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _drop_pressed_raw()")
	return false


func get_aim_dir_override() -> Vector2:
	return Vector2.ZERO

func is_network_driven() -> bool:
	return source_kind() == Kind.PACKET
