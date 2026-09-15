class_name LocalInputSource
extends PlayerInput

# 本地输入源:直接读真实 `Input`(阶段 5.9 从旧 `InputSource` 的默认实现拆出)。
#
# 谁在用:
#   · 单机 `player.gd` 的默认输入源(也是它 `_ready` 里构造的那种);
#   · PvP 的**本地玩家** —— C2 下引擎自步进、读真实鼠标键盘(aim/手感=单机);
#   · 远端玩家/权威模拟**不用它**,用 `PacketInputSource`。
#
# ★ 之前的语义错位:这份实现原先长在"接口"里当默认值,于是"本地玩家"和"抽象输入源"
#   是同一个类;要注入别的来源得先继承一个名字像接口的类。拆开后本地这份有了名字,
#   注入方(PacketInputSource / AiInputSource)也不再继承"本地行为"。

func source_kind() -> int:
	return Kind.LOCAL


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
	# ★ 只认 1-4:持有位上限是 4(WeaponInventory.MAX_WEAPONS)。
	#   5/6 的 InputMap 动作**保留不删**(以后想开第 5 个位时不必再动 project.godot),
	#   但这里不读它们 —— 读了就会切到一个不存在的背包位置。
	for i in range(1, 5):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0

func _pickup_pressed_raw() -> bool:
	return Input.is_action_just_pressed("F")

func _drop_pressed_raw() -> bool:
	# ★ 这里报的是"Q 键现在是否按着",**不是**"长按满了" —— 长按计时在 player.gd 的
	#   物理帧里做(那才有确定的 delta),满了才把它当成一次边沿用。
	#   非本地实现(PacketInputSource)拿到的直接是"满了"的边沿。
	return Input.is_action_pressed("Q")
