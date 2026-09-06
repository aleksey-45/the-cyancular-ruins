class_name AIInputSource
extends InputSource

# AI 玩家的"手柄"(实验性 AI 补位,test-ai 分支):字段由服务端 AINavigator 每帧写,
# player/weapon 经基类接口读取——与 NetworkInputSource/DemoInputSource 同一套注入机制。
# 仅 worker 侧存在;客户端对 AI 玩家的显示走快照副本,无需感知。

var axis := 0.0               # 水平移动 -1/0/1
var aim := Vector2.RIGHT      # 瞄准方向(世界单位向量;get_aim_dir_override 注入)
var fire := false             # 按住开火
var _jump_edge := false       # 一次性跳跃边沿

func press_jump() -> void:
	_jump_edge = true

func get_axis(neg: String, _pos: String) -> float:
	return axis if neg == "left" else 0.0   # 垂直轴走跳跃边沿,不爬梯

func is_action_pressed(_action: String) -> bool:
	return false   # 无持续按住(下蹲/冲刺/攀爬都不用)

func is_action_just_pressed(action: String) -> bool:
	if action == "up":
		var v := _jump_edge
		_jump_edge = false
		return v
	return false

func is_action_just_released(_action: String) -> bool:
	return false

func is_attack_pressed() -> bool:
	return fire

func is_attack_just_pressed() -> bool:
	return fire

func is_attack_just_released() -> bool:
	return false

func get_weapon_slot_pressed() -> int:
	return 0   # 不切枪

func get_aim_dir_override() -> Vector2:
	return aim
