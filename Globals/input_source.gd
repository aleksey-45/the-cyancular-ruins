class_name InputSource
extends RefCounted

# 玩家输入抽象(行为不变重构):基类默认行为 = 委托真实 Input,即本地玩家现状。
# Plan B 的 NetworkInputSource 覆写这些方法,消费网络输入包驱动服务器上的远端玩家。
# 目标:player.gd 不再直接读全局 Input,输入来源可注入。
#
# frozen:PvP COUNTDOWN/局间冻结。置 true 后一切输入读口返回中性值(轴 0、无按键/边沿/切枪),
# 玩家像服务器不喂输入那样静止 —— C2 本地预测下倒计时里不自走(服务器权威冻结,客户端预测必须同款冻结,
# 否则预测移动、服务器不消费 → PLAYING 起 ack 跳变 → 大 rollback)。瞄准读口仍走 get_current_aim_dir,冻结不影响。
var frozen := false

func get_axis(neg: String, pos: String) -> float:
	if frozen:
		return 0.0
	return Input.get_axis(neg, pos)

func is_action_pressed(action: String) -> bool:
	if frozen:
		return false
	return Input.is_action_pressed(action)

func is_action_just_pressed(action: String) -> bool:
	if frozen:
		return false
	return Input.is_action_just_pressed(action)

func is_action_just_released(action: String) -> bool:
	if frozen:
		return false
	return Input.is_action_just_released(action)

# 瞄准覆盖:本地返回 ZERO → 武器落回鼠标计算;网络驱动的玩家返回注入的瞄准方向。
func get_aim_dir_override() -> Vector2:
	return Vector2.ZERO

# 该输入源是否网络注入(NetworkInputSource=true)。网络驱动玩家的武器瞄准**永不读 OS 鼠标**:
# 注入方向为 ZERO 时用玩家朝向兜底(见 weapon_base._aim_world_dir)。
func is_network_driven() -> bool:
	return false

# ── 攻击与切枪(本地委托真实 Input;NetworkInputSource 覆写)──
func is_attack_pressed() -> bool:
	if frozen:
		return false
	return Input.is_action_pressed("attack")

func is_attack_just_pressed() -> bool:
	if frozen:
		return false
	return Input.is_action_just_pressed("attack")

func is_attack_just_released() -> bool:
	if frozen:
		return false
	return Input.is_action_just_released("attack")

# 本轮按下的武器槽位(0=无,1-7)。本地用 Input 事件,网络由注入包提供。
func get_weapon_slot_pressed() -> int:
	if frozen:
		return 0
	for i in range(1, 8):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0
