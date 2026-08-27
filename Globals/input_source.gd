class_name InputSource
extends RefCounted

# 玩家输入抽象(行为不变重构):基类默认行为 = 委托真实 Input,即本地玩家现状。
# Plan B 的 NetworkInputSource 覆写这些方法,消费网络输入包驱动服务器上的远端玩家。
# 目标:player.gd 不再直接读全局 Input,输入来源可注入。

func get_axis(neg: String, pos: String) -> float:
	return Input.get_axis(neg, pos)

func is_action_pressed(action: String) -> bool:
	return Input.is_action_pressed(action)

func is_action_just_pressed(action: String) -> bool:
	return Input.is_action_just_pressed(action)

func is_action_just_released(action: String) -> bool:
	return Input.is_action_just_released(action)

# 瞄准覆盖:本地返回 ZERO → 武器落回鼠标计算;网络驱动的玩家返回注入的瞄准方向。
func get_aim_dir_override() -> Vector2:
	return Vector2.ZERO
