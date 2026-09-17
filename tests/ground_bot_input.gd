extends PlayerInput

# 局内「捡枪/丢枪」探针的脚本手柄:**一根哑手柄** —— 它自己不做任何决策,只把
# `axis` / `aim` / `jump` / `hold_q` 这几个字段和"按一次 F"的边沿报给输入读口;
# 每一步走哪儿、什么时候按 F 由**观察者**(ground_net_watcher.gd)每物理帧写进来。
#
# ★ 为什么决策不放这儿:决策要读**真 royale_game 的运行时状态**(地面武器表在哪、自己
#   背包里有没有枪),而观察者本来就挂在 root 上、跨换场存活、能直接读那些生产对象。
#   手柄自持状态的话,那份"该不该按 F"的知识就要在两个文件之间对不上。
#
# ★ 为什么是"哑手柄"而不是 `soak_bot_input.gd` 那种自带相位脚本的:这份探针要的是
#   **确定性** —— 时序由观察者按客户端真实状态推进,而不是按固定 tick 数盲走。
#
# 无 class_name(新建全局类要刷 --import 全局类缓存,本仓踩过这个坑),由观察者 preload 引用。

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


# ── 覆写钩子(公开读口由基类持有并对 frozen 短路)──
func _axis_raw(neg: String, _pos: String) -> float:
	# 垂直轴(climb/swim 用 get_axis("up","down"))不走这里 —— 跳跃走 "up" 动作的边沿。
	return axis if neg == "left" else 0.0

func _action_pressed_raw(action: String) -> bool:
	# ★ Q 必须是 **is_action_pressed**(不是边沿):player.gd 的长按计时读的就是它,
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

func _weapon_slot_raw() -> int:
	return 0

func _pickup_pressed_raw() -> bool:
	var v := _f_edge
	_f_edge = false
	return v

# Q 的"长按满阈值"那次边沿由 **player.gd** 判(它有确定的物理 delta),判满了它调
# `mark_drop_edge()` 打标 —— 本手柄必须像 `LocalInputSource` 那样把标记读走并清掉。
# ★ 恒返回 false 是个**静默**失效:客户端看起来一切正常(长按进度条会走),但丢弃
#   永远上不了行,探针就退化成"只捡不丢"的空转、还一条报错都不给。
func _drop_pressed_raw() -> bool:
	var v := _drop_edge
	_drop_edge = false
	return v


# 不读宿主 OS 鼠标(headless 下是垃圾值),用观察者写的方向。
func get_aim_dir_override() -> Vector2:
	return aim
