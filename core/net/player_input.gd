class_name PlayerInput
extends RefCounted

# 玩家输入的纯接口:只声明契约;实现见 LocalInputSource / PacketInputSource / AiInputSource。frozen 短路收在本类公开读口、
# 子类只覆写 _*_raw() ⇒ 冻结契约无法被绕过。frozen = PvP COUNTDOWN/局间冻结:置 true 后一切读口返回中性值
# (C2 本地预测必须与服务器同款冻结,否则 PLAYING 起 ack 跳变 → 大 rollback);★ 冻结期不调用子类 _*_raw()。
var frozen := false

# 输入源种类:用枚举而不是 is_network_driven() 那种二值判断 —— 后者每加一种来源都要重新想"它算不算网络"。
enum Kind { LOCAL, PACKET, AI }


# 本实现的种类。子类必须覆写(基类给会报错的兜底,同仓内其它"必须覆写"桩)。
func source_kind() -> int:
	push_error("PlayerInput: 子类必须覆写 source_kind()")
	return -1


# ── 公开读口:frozen 一律在此短路,子类不得覆写这些(覆写了就等于绕开冻结)──

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

# 拾取(F 按下边沿) / 丢弃(Q 长按满阈值后的那一次边沿):与其它读口同款,冻结一律在此短路,子类不得覆写这两个。
func is_pickup_pressed() -> bool:
	return not frozen and _pickup_pressed_raw()

func is_drop_pressed() -> bool:
	return not frozen and _drop_pressed_raw()


# 本帧上行包里的权威切枪目标(inst):只有 PacketInputSource 覆写它;与 get_aim_dir_override() 同款是"默认空操作"的可选钩子,frozen 短路照旧收在公开读口。
func consume_switch_inst() -> int:
	if frozen:
		return 0
	return _switch_inst_raw()


# ── 覆写钩子:子类只改这里;本基类给会报错的兜底(纯接口,不再自带"本地"实现)──

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


# 可选钩子:默认 0 = "本次上行没有切枪目标"。见 `consume_switch_inst()`。
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


# 瞄准覆盖:本地返回 ZERO → 武器落回鼠标计算;网络驱动的玩家返回注入方向;★ 不参与 frozen。
func get_aim_dir_override() -> Vector2:
	return Vector2.ZERO

# 是否网络注入:网络驱动玩家的瞄准永不读 OS 鼠标(方向 ZERO 时用玩家朝向兜底);保留本方法是因为它是语义问句"要按网络玩家对待吗",调用点三处都是这个语义。
func is_network_driven() -> bool:
	return source_kind() == Kind.PACKET
