class_name PlayerInput
extends RefCounted

# 为 LocalInputSource、PacketInputSource 与 AiInputSource 提供通用输入契约。
# 输入冻结管理：
# 基类的公开查询接口负责统一处理 frozen 冻结状态。
# 冻结期间（如对局开始倒计时或结算停顿），所有公开移动、攻击、切枪及交互查询直接返回中性默认值。
# 子类仅需实现底层的 _*_raw() 内部钩子方法，避免各子类重复实现冻结分支或产生分歧。
# 瞄准方向查询 get_aim_dir_override() 独立于冻结状态，保证武器朝向视觉正常显示。

var frozen := false

# 输入源类别枚举
enum Kind { LOCAL, PACKET, AI }


# 返回当前输入源具体类别，子类必须覆写此方法。
func source_kind() -> int:
	push_error("PlayerInput: 子类必须覆写 source_kind()")
	return -1


# 公开输入查询接口：处于冻结状态时直接返回中性默认值，子类不应覆写此类接口。

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

# 拾取与丢弃动作查询接口：
func is_pickup_pressed() -> bool:
	return not frozen and _pickup_pressed_raw()

func is_drop_pressed() -> bool:
	return not frozen and _drop_pressed_raw()


# 消费网络输入包中的目标武器实例 ID（winst）。
# 仅网络输入源解析其实例 ID；本地与 AI 玩家则通过本地槽位直接切换。
func consume_switch_inst() -> int:
	if frozen:
		return 0
	return _switch_inst_raw()


# 底层虚方法钩子：子类覆写具体输入采集逻辑。

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


# 可选切枪实例 ID 钩子：默认为 0（无切枪请求）。
func _switch_inst_raw() -> int:
	return 0

func _pickup_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _pickup_pressed_raw()")
	return false

# 丢弃武器蓄力边沿标记：
# 本地角色在长按蓄力达标后调用 mark_drop_edge() 写入触发边沿。
var _drop_edge := false

func mark_drop_edge() -> void:
	_drop_edge = true


func _drop_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _drop_pressed_raw()")
	return false


# 瞄准方向覆盖向量。
# 本地输入返回零向量时，武器将根据鼠标光标位置推导朝向；
# 网络驱动输入则返回数据包中携带的世界坐标瞄准向量。
func get_aim_dir_override() -> Vector2:
	return Vector2.ZERO

# 判定当前输入源是否由网络数据驱动。
# 网络驱动角色的武器瞄准不会读取本机鼠标，若未提供覆盖向量则默认朝向角色面朝方向。
func is_network_driven() -> bool:
	return source_kind() == Kind.PACKET
