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
	# ★ 报的是"长按满了一次"的**边沿**,不是"Q 现在按着" ——
	#   后者会让联机端**一碰 Q 就丢枪**(长按 2s 的规则形同虚设),而且按住不放会每 tick
	#   都发一次,把背包一把把丢光。计时在 player.gd 里(那里有确定的物理 delta),
	#   满了由 player 调 mark_drop_edge() 打标;这里读一次即清。
	var v := _drop_edge
	_drop_edge = false
	return v
