class_name LocalInputSource
extends PlayerInput

# 本地输入源:直接读真实 `Input`(阶段 5.9 从旧 `InputSource` 的默认实现拆出)。
# ★ 冲刺是**派生**出来的:键位表里没有冲刺键,双击左 / 右走就是冲刺(2026-11 用户改令,原 X 键作废)。

# 双击窗口(物理帧;60Hz ⇒ 15 帧 ≈ 0.25s)。只在这里定义,别在 player 里再抄一份。
const DOUBLE_TAP_FRAMES := 15

var _tap_frame := {"left": -1000000, "right": -1000000}
# 同一物理帧里本边沿会被问两次(玩家 tick 一次、PvP 上行组包一次):两次答案必须一致,
# 否则服务器收到的位与本地预测分叉 —— 冲刺只在这一帧有效,判错就是"本地冲了、服务器没冲"。
var _dash_frame := -1000000
var _dash_edge := false


func source_kind() -> int:
	return Kind.LOCAL


func _dash_edge_raw() -> bool:
	var f := Engine.get_physics_frames()
	if f == _dash_frame:
		return _dash_edge
	_dash_frame = f
	_dash_edge = false
	for dir_name in ["left", "right"]:
		if not Input.is_action_just_pressed(dir_name):
			continue
		if f - int(_tap_frame[dir_name]) <= DOUBLE_TAP_FRAMES:
			_tap_frame[dir_name] = -1000000   # 消费掉:连点三下不会连冲两下
			_dash_edge = true
		else:
			_tap_frame[dir_name] = f
	return _dash_edge


func _axis_raw(neg: String, pos: String) -> float:
	return Input.get_axis(neg, pos)

func _action_pressed_raw(action: String) -> bool:
	if action == "charge":
		return false   # 冲刺只有按下边沿,没有按住态
	return Input.is_action_pressed(action)

func _action_just_pressed_raw(action: String) -> bool:
	if action == "charge":
		return _dash_edge_raw()
	return Input.is_action_just_pressed(action)

func _action_just_released_raw(action: String) -> bool:
	if action == "charge":
		return false
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
