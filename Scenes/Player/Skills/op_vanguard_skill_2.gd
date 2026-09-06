extends SkillBase

# 掩体姿态:正面受到的伤害减半 3 秒,移动速度降至一半;持续期间再按一次提前解除。
# 正面减半在 player.take_hit 里按 shield_left 判定;移速减半由 OperatorComponent.shield_speed_mult。

const SHIELD_TIME := 3.0

var comp: Node = null

func _ready() -> void:
	comp = get_parent()   # OperatorComponent

func _activate() -> bool:
	if comp.shield_left > 0.0:
		comp.shield_left = 0.0   # 提前解除(仍进冷却)
		return true
	comp.shield_left = SHIELD_TIME
	return true
