class_name PlayerInput
extends RefCounted

# 玩家输入的**纯接口**(阶段 5.9 从旧名 `InputSource` 改名并拆出)。
#
# ★ 为什么改名 + 拆:此前本类叫 `InputSource`,却**同时**是"接口"和"本地实现" ——
#   它的 `_*_raw()` 默认实现直接读真实 `Input`。于是"给玩家注入一个输入源"这句话,
#   在这个类上到底是"用本地输入"还是"某种输入"是含混的;而真要用本地输入时,
#   又只能 `LocalInputSource.new()` 拿这个"接口"的实例。
#   现在:`PlayerInput` 只声明契约(三个实现见下),本地那份独立成 `LocalInputSource`。
#
# 三个实现:
#   · `LocalInputSource`  —— 读真实 `Input`(单机与 PvP 本地玩家;C2 下由引擎自步进读)
#   · `PacketInputSource` —— 消费网络输入包(权威服务器唯一消费方)
#   · `AiInputSource`     —— AI 补位(AINavigator 每帧写字段)
#   · 另有 `tests/soak_bot_input.gd`(压力探针的脚本手柄,不在生产路径)
#
# ★ frozen 的归属(2026-09-14 修,本类保留):
#   此前 frozen 短路写在公开读口里、而三个子类各自覆写了全部公开读口 →
#   短路被子类整个绕过,`player.set_controls_locked(true)` 对它们是**静默空操作**。
#   现在冻结收在本类的公开读口,子类只覆写不碰 frozen 的 `_*_raw()` 钩子 —— 契约无法绕过。
#   历史代价(记下来别再犯):客户端 COUNTDOWN 冻结曾靠"客户端恰好用默认 InputSource"侥幸成立;
#   服务器靠 MatchHost 另调 PacketInputSource.reset_state()、AI 靠自己查 RoundState 兜住。
#   回归守卫:`tests/ai_input_source_smoke.gd` 的 9 条 `frozen:` 断言
#   (打在**子类实例**上 —— 基类自己的实现无法证明子类听话)。
#
# frozen:PvP COUNTDOWN/局间冻结。置 true 后一切输入读口返回中性值(轴 0、无按键/边沿/切枪),
# 玩家像服务器不喂输入那样静止 —— C2 本地预测下倒计时里不自走(服务器权威冻结,客户端预测
# 必须同款冻结,否则预测移动、服务器不消费 → PLAYING 起 ack 跳变 → 大 rollback)。
# ★ 冻结期**不调用**子类的 _*_raw():冻结不该改子类状态(边沿不被消费、切枪槽位不被取走)。
# ★ 瞄准读口 get_aim_dir_override() 刻意**不**参与冻结:武器仍要按注入方向摆枪。
var frozen := false

# 输入源种类。★ 用枚举而不是 `is_network_driven() == true/false` 那种二值判断:
# 二值判断每加一种来源就要重新想"它算不算网络",而这里加一个枚举值即可。
enum Kind { LOCAL, PACKET, AI }


# 本实现的种类。子类**必须覆写**(基类给会报错的兜底,同仓内其它"必须覆写"桩)。
func source_kind() -> int:
	push_error("PlayerInput: 子类必须覆写 source_kind()")
	return -1


# ── 公开读口:frozen 一律在此短路,子类**不得覆写这些**(覆写了就等于绕开冻结)──

func get_axis(neg: String, pos: String) -> float:
	if frozen:
		return 0.0
	return _axis_raw(neg, pos)

func is_action_pressed(action: String) -> bool:
	return not frozen and _action_pressed_raw(action)

func is_action_just_pressed(action: String) -> bool:
	return not frozen and _action_just_pressed_raw(action)

func is_action_just_released(action: String) -> bool:
	return not frozen and _action_just_released_raw(action)

func is_attack_pressed() -> bool:
	return not frozen and _attack_pressed_raw()

func is_attack_just_pressed() -> bool:
	return not frozen and _attack_just_pressed_raw()

func is_attack_just_released() -> bool:
	return not frozen and _attack_just_released_raw()

func get_weapon_slot_pressed() -> int:
	if frozen:
		return 0
	return _weapon_slot_raw()

# 拾取(F 按下边沿) / 丢弃(Q 长按满阈值后的那一次边沿)。
# ★ 与其它读口同款:冻结一律在此短路,子类**不得覆写这两个**(覆写即绕开冻结)。
func is_pickup_pressed() -> bool:
	return not frozen and _pickup_pressed_raw()

func is_drop_pressed() -> bool:
	return not frozen and _drop_pressed_raw()


# ── 覆写钩子:子类只改这里;本基类给会报错的兜底(纯接口,不再自带"本地"实现)──

func _axis_raw(_neg: String, _pos: String) -> float:
	push_error("PlayerInput: 子类必须覆写 _axis_raw();本地输入请用 LocalInputSource")
	return 0.0

func _action_pressed_raw(_action: String) -> bool:
	push_error("PlayerInput: 子类必须覆写 _action_pressed_raw()")
	return false

func _action_just_pressed_raw(_action: String) -> bool:
	push_error("PlayerInput: 子类必须覆写 _action_just_pressed_raw()")
	return false

func _action_just_released_raw(_action: String) -> bool:
	push_error("PlayerInput: 子类必须覆写 _action_just_released_raw()")
	return false

func _attack_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _attack_pressed_raw()")
	return false

func _attack_just_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _attack_just_pressed_raw()")
	return false

func _attack_just_released_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _attack_just_released_raw()")
	return false

func _weapon_slot_raw() -> int:
	push_error("PlayerInput: 子类必须覆写 _weapon_slot_raw()")
	return 0

func _pickup_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _pickup_pressed_raw()")
	return false

func _drop_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _drop_pressed_raw()")
	return false


# 瞄准覆盖:本地返回 ZERO → 武器落回鼠标计算;网络驱动的玩家返回注入的瞄准方向。
# ★ 不参与 frozen(见类头)。
func get_aim_dir_override() -> Vector2:
	return Vector2.ZERO

# 该输入源是否网络注入。网络驱动玩家的武器瞄准**永不读 OS 鼠标**:
# 注入方向为 ZERO 时用玩家朝向兜底(见 weapon_base._aim_world_dir)。
# ★ 不参与 frozen。
# ★ 保留本方法(而不是让调用方都改去比 source_kind):它是**语义**问句("要按网络玩家对待吗"),
#   调用点有三处且都是这个语义;种类问句留给需要区分 LOCAL/PACKET/AI 的新调用方。
func is_network_driven() -> bool:
	return source_kind() == Kind.PACKET
