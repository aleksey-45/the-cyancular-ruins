extends PlayerInput

# 加速探针的**哑手柄**(无 class_name;由 haste_probe.gd preload 引用 —— 新建全局类要刷全局类缓存,本仓曾遇到过此类隐患)。
# 只把 axis(水平)与 jump("up" 的按下边沿)报给玩家;其余读取接口恒中性。
#
# - 为什么不用 Input.action_press:跳跃读的是 `is_action_just_pressed("up")` 边沿,而 Godot 的
#   just_pressed 判定是 `pressed_physics_frame == get_physics_frames()`。探针协程在 physics_frame
#   信号里按下时记的是**当前**帧号,下一帧处理时帧号已经 +1 → 永远报不到,跳不起来。
#   (回溯探针能用 action_press,是因为它读 is_action_pressed,不吃帧号。)
#
# 冻结(frozen)由基类的公开输入读取接口短路,本桩不碰 —— 与生产实现相同机制契约。

var axis := 0.0
var jump := false


func source_kind() -> int:
	return Kind.AI


func _axis_raw(neg: String, _pos: String) -> float:
	# 只喂水平轴;climb/swim 的 get_axis("up","down") 走另一支 → 0(探针不爬不游)。
	return axis if neg == "left" else 0.0


func _action_pressed_raw(_action: String) -> bool:
	return false


func _action_just_pressed_raw(action: String) -> bool:
	# 按住 = 每帧都报"刚按下":地面帧把跳跃缓冲塞满 → 起跳;空中不消费(无二段跳)。
	# 跳跃期间保持 true 也就不会触发"松手截断"(可变高度),两段测量都是满高度。
	return jump and action == "up"


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
	return false


func _drop_pressed_raw() -> bool:
	return false


# 不读宿主 OS 鼠标(headless 下是垃圾值),给个固定方向。
func get_aim_dir_override() -> Vector2:
	return Vector2.RIGHT
