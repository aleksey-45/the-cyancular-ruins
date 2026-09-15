class_name AiInputSource
extends PlayerInput

# AI 玩家的"手柄"(实验性 AI 补位,test-ai 分支):字段由服务端 AiNavigator 每帧写,
# player/weapon 经基类接口读取——与 PacketInputSource/DemoInputSource 同一套注入机制。
# 仅 worker 侧存在;客户端对 AI 玩家的显示走快照副本,无需感知。

var axis := 0.0               # 水平移动 -1/0/1
var aim := Vector2.RIGHT      # 瞄准方向(世界单位向量;get_aim_dir_override 注入)
var fire := false             # 按住开火
var _jump_edge := false       # 一次性跳跃边沿

# 输入源种类(基类 PlayerInput.Kind;阶段 5.9 起接口要求实现)。
func source_kind() -> int:
	return Kind.AI


func press_jump() -> void:
	_jump_edge = true

# ── 覆写钩子(公开读口由基类持有并对 frozen 短路;本类不再各自处理冻结)──

func _axis_raw(neg: String, _pos: String) -> float:
	return axis if neg == "left" else 0.0   # 垂直轴走跳跃边沿,不爬梯

func _action_pressed_raw(_action: String) -> bool:
	return false   # 无持续按住(下蹲/冲刺/攀爬都不用)

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

func _weapon_slot_raw() -> int:
	return 0   # 不切枪

func get_aim_dir_override() -> Vector2:
	return aim

# ★ L5 必加(规格 §3 L5 明文) —— 不加以致静默手感退化:
# main 的 WeaponBase.reload_active()(scenes/weapons/weapon_base.gd)第二判据是
#   player.input_is_network() → input_source.is_network_driven()
# 基类 PlayerInput.is_network_driven() 返回 false,而本类不覆写 →
#   服务器侧 AI 会被判成"本地单机" → 打空弹夹后进换弹、静默停火 reload_time 秒
#   (霰弹 2.2s / 榴弹 2.8s)。AI 没有预测端,不会造成客户端分歧 ——
#   只是 AI 手感莫名变差且无任何报错。
# 附带正向影响:weapon_base._aim_world_dir() 在 override == ZERO 时对
#   input_is_network()==true 的玩家永不读宿主 OS 鼠标、改用朝向兜底;
#   AI 的 aim 恒非零(AiNavigator 每帧写 src.aim),两分支都安全但语义更正确。
func is_network_driven() -> bool:
	return true
