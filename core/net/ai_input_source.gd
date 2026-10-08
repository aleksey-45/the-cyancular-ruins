class_name AiInputSource
extends PlayerInput

# AI 玩家输入源。
# 字段由服务端导航逻辑每帧写入，角色与武器通过基类接口统一读取。
# 仅存在于服务端对局宿主，客户端通过世界状态快照渲染副本。

var axis := 0.0               # 水平移动输入（-1.0、0.0、1.0）
var aim := Vector2.RIGHT      # 瞄准方向（世界坐标单位向量）
var fire := false             # 持续开火状态
var _jump_edge := false       # 一次性跳跃触发边沿


# 输入源类型标识。
func source_kind() -> int:
	return Kind.AI


func press_jump() -> void:
	_jump_edge = true


# 覆写基类底层输入接口，公开接口统一由基类处理冻结状态。

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

# 当前 AI 仅使用初始随机武器，不主动拾取或丢弃武器。
func _pickup_pressed_raw() -> bool:
	return false

func _drop_pressed_raw() -> bool:
	return false

func get_aim_dir_override() -> Vector2:
	return aim


# 标记为受外部驱动：
# 武器逻辑针对外部注入输入，不会读取宿主机的真实鼠标位置，
# 而是直接使用注入的瞄准向量。
func is_network_driven() -> bool:
	return true
