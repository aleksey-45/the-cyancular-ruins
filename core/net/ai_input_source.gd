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

# ★ AI **不捡也不丢枪**:大乱斗补位 AI 只用开局随机发的那把,死后也只留随机一把
#   (复活规则见 MatchHost/_respawn_player)。要让它会捡枪就得先有"想捡哪把"的决策,
#   那是另一件事,别在这里偷偷返回 true(会变成 AI 沿路把所有枪都吸走)。
func _pickup_pressed_raw() -> bool:
	return false

func _drop_pressed_raw() -> bool:
	return false

func get_aim_dir_override() -> Vector2:
	return aim

# 本类**必须**为 true,理由是**瞄准**而不是换弹:
# weapon_base._aim_world_dir() 对 input_is_network()==true 的玩家**永不读宿主 OS 鼠标**,
# 注入方向为 ZERO 时改用朝向兜底。AI 没有鼠标(服务器 headless),不覆写就会让它去读
# 宿主机的真实鼠标位置 —— 瞄准变成随服务器桌面而变的随机值。
# (AI 的 aim 恒非零,两个分支其实都安全,但语义上必须是"网络驱动的玩家"。)
#
# ★ 2026-09-15 起**不再是**为了绕开换弹:原先 WeaponBase.reload_active() 的第二判据正是
#   input_is_network(),本类靠返回 true 让 AI 不换弹(免得打空后静默停火 reload_time 秒)。
#   换弹对全模式开放后那道闸门已整个删除,AI 现在**照常换弹** —— 与真人同规则
#   (打空 → 装填 → 继续打),这是有意为之,不是 AI 手感退化。
#   AiInputSource 不产 R 边沿(_action_just_pressed_raw 只认 "up"),故 AI 只会走
#   "打空自动装填"这一条,不会手动换弹。
func is_network_driven() -> bool:
	return true
