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

# ── 攻击与切枪(本地委托真实 Input;NetworkInputSource 覆写)──
func is_attack_pressed() -> bool:
	return Input.is_action_pressed("attack")

func is_attack_just_pressed() -> bool:
	return Input.is_action_just_pressed("attack")

func is_attack_just_released() -> bool:
	return Input.is_action_just_released("attack")

# 本轮按下的武器槽位(0=无,1-6)。本地用 Input 事件,网络由注入包提供。
func get_weapon_slot_pressed() -> int:
	for i in range(1, 7):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0
