class_name LocalInputSource
extends PlayerInput

# 本地输入源:直接读真实 `Input`(阶段 5.9 从旧 `InputSource` 的默认实现拆出)。

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
	# ★ 只认 1-4:持有位上限的**默认值**是 4(WeaponInventory.DEFAULT_MAX_WEAPONS)。
	for i in range(1, 5):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0

func _pickup_pressed_raw() -> bool:
	return Input.is_action_just_pressed("F")

func _drop_pressed_raw() -> bool:
	# ★ 报的是"长按满了一次"的**边沿**,不是"Q 现在按着" ——
	var v := _drop_edge
	_drop_edge = false
	return v
