extends SkillBase

# 冲锋:朝当前移动方向快速突进约 3 格(DASH_TIME×DASH_SPEED≈192px),
# 突进途中免疫击退;空中可用。位移由 player.gd 根循环读 OperatorComponent.dash_* 接管。
const DASH_TIME := 0.16
const DASH_SPEED := 1200.0

var comp: Node = null

func _ready() -> void:
	comp = get_parent()   # OperatorComponent

func _activate() -> bool:
	var axis := input_source.get_axis("left", "right") if input_source != null else 0.0
	var dir := axis
	if absf(dir) <= 0.1:
		dir = float(player.get("facing_direction")) if "facing_direction" in player else 1.0
	comp.dash_left = DASH_TIME
	comp.dash_dir = signf(dir)
	return true
