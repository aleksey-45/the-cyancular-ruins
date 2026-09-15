class_name InputSource
extends RefCounted

# 玩家输入抽象:基类默认行为 = 委托真实 Input(即本地玩家现状)。
# AiInputSource / NetworkInputSource / tests/soak_bot_input.gd 覆写 **_*_raw() 钩子**。
#
# ★ frozen 的归属(2026-09-14 修):
#   本类此前把 frozen 短路写在**公开读口**里,而三个子类各自覆写了全部公开读口 →
#   短路被子类整个绕过,`player.set_controls_locked(true)` 对它们是**静默空操作**。
#   现在冻结收在本类的公开读口,子类只覆写不碰 frozen 的 `_*_raw()` 钩子 —— 契约从此无法绕过。
#   历史代价(记下来别再犯):客户端 COUNTDOWN 冻结曾靠"客户端恰好用默认 InputSource"侥幸成立;
#   服务器靠 MatchHost 另调 NetworkInputSource.reset_state()、AI 靠自己查 RoundState 兜住。
#   回归守卫:`tests/ai_input_source_smoke.gd` 的 9 条 `frozen:` 断言(打在**子类实例**上 ——
#   基类自己的实现无法证明子类听话)。
#
# frozen:PvP COUNTDOWN/局间冻结。置 true 后一切输入读口返回中性值(轴 0、无按键/边沿/切枪),
# 玩家像服务器不喂输入那样静止 —— C2 本地预测下倒计时里不自走(服务器权威冻结,客户端预测必须同款冻结,
# 否则预测移动、服务器不消费 → PLAYING 起 ack 跳变 → 大 rollback)。
# ★ 冻结期**不调用**子类的 _*_raw():冻结不该改子类状态(边沿不被消费、切枪槽位不被取走)。
# ★ 瞄准读口 get_aim_dir_override() 刻意**不**参与冻结:武器仍要按注入方向摆枪。
var frozen := false


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


# ── 覆写钩子:子类只改这里。基类默认 = 真实 Input(本地玩家)──

func _axis_raw(neg: String, pos: String) -> float:
	return Input.get_axis(neg, pos)

func _action_pressed_raw(action: String) -> bool:
	return Input.is_action_pressed(action)

func _action_just_pressed_raw(action: String) -> bool:
	return Input.is_action_just_pressed(action)

func _action_just_released_raw(action: String) -> bool:
	return Input.is_action_just_released(action)

func _attack_pressed_raw() -> bool:
	return Input.is_action_pressed("attack")

func _attack_just_pressed_raw() -> bool:
	return Input.is_action_just_pressed("attack")

func _attack_just_released_raw() -> bool:
	return Input.is_action_just_released("attack")

func _weapon_slot_raw() -> int:
	for i in range(1, 7):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0


# 瞄准覆盖:本地返回 ZERO → 武器落回鼠标计算;网络驱动的玩家返回注入的瞄准方向。
# ★ 不参与 frozen(见类头)。
func get_aim_dir_override() -> Vector2:
	return Vector2.ZERO

# 该输入源是否网络注入(NetworkInputSource=true)。网络驱动玩家的武器瞄准**永不读 OS 鼠标**:
# 注入方向为 ZERO 时用玩家朝向兜底(见 weapon_base._aim_world_dir)。
# ★ 不参与 frozen。
func is_network_driven() -> bool:
	return false
