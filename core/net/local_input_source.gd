class_name LocalInputSource
extends PlayerInput

# 本地输入源：直接读取操作系统真实输入事件。
# 适用于单人模式本地角色以及多人对战中由本机操控的预测角色。
# 远端实体与服务端模拟则使用数据包输入源。

func source_kind() -> int:
	return Kind.LOCAL


func _axis_raw(neg: String, pos: String) -> float:
	return Input.get_axis(neg, pos)

func _action_pressed_raw(action: String) -> bool:
	return Input.is_action_pressed(action)

func _action_just_pressed_raw(action: String) -> bool:
	return Input.is_action_just_pressed(action)

func _action_just_released_raw(action: String) -> bool:
	return Input.is_action_just_released(action)

func _attack_pressed_raw() -> bool:
	return Input.is_action_pressed("attack")

func _attack_just_pressed_raw() -> bool:
	return Input.is_action_just_pressed("attack")

func _attack_just_released_raw() -> bool:
	return Input.is_action_just_released("attack")

func _switch_index_raw() -> int:
	# 仅响应 1-4 数字键切枪，对应默认武器槽位上限
	for i in range(1, 5):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0

func _pickup_pressed_raw() -> bool:
	return Input.is_action_just_pressed("F")

func _drop_pressed_raw() -> bool:
	# 返回长按蓄力完成后的单次触发边沿，由角色逻辑在完成蓄力计时后通过 mark_drop_edge() 写入
	var v := _drop_edge
	_drop_edge = false
	return v
