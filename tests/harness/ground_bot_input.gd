extends PlayerInput

# 地面武器拾取与丢弃网络同步测试手柄：
# 纯被动输入源，本身不维护决策状态，各控制字段由测试观察者（ground_net_watcher.gd）按帧写入；
# 测试观察者根据场景中地面武器与背包状态精确驱动角色的移动与拾取行为。

var axis := 0.0
var aim := Vector2.RIGHT
var jump := false
var hold_q := false

var _f_edge := false


# 观察者调:让下一帧的输入包带上"按了一次 F"的边沿(读一次即清)。
func press_f() -> void:
	_f_edge = true


func source_kind() -> int:
	return Kind.AI


# ── 覆写钩子(公开输入读取接口由基类持有并对 frozen 短路)──
func _axis_raw(neg: String, _pos: String) -> float:
	# 垂直轴(climb/swim 用 get_axis("up","down"))不走这里 —— 跳跃走 "up" 动作的边沿。
	return axis if neg == "left" else 0.0

func _action_pressed_raw(action: String) -> bool:
	# - Q 必须是 is_action_pressed(不是边沿):player.gd 的长按计时读的就是它,
	#   满 weapon_drop_hold_time 才打一次丢弃边沿。这里返回 true 的时长由观察者控制。
	return hold_q if action == "Q" else false

func _action_just_pressed_raw(action: String) -> bool:
	return jump if action == "up" else false

func _action_just_released_raw(_action: String) -> bool:
	return false

func _attack_pressed_raw() -> bool:
	return false

func _attack_just_pressed_raw() -> bool:
	return false

func _attack_just_released_raw() -> bool:
	return false

func _switch_index_raw() -> int:
	return 0

func _pickup_pressed_raw() -> bool:
	var v := _f_edge
	_f_edge = false
	return v

# 长按丢弃边沿触发由角色物理逻辑判定，触发后调用 mark_drop_edge 设置标记；
# 本钩子读取并清空丢弃标记，上报丢弃输入
func _drop_pressed_raw() -> bool:
	var v := _drop_edge
	_drop_edge = false
	return v


# 无头模式下避免读取宿主鼠标坐标，返回观察者指定的瞄准向量
func get_aim_dir_override() -> Vector2:
	return aim
