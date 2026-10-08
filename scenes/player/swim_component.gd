class_name SwimComponent
extends Node

# 角色水体物理子系统：在水中按向上方向键上浮，无按键时自然下沉；离开水体后恢复常规重力物理。
# 由根节点 player.gd 在物理帧中显式调用驱动。

var in_water: bool = false


func update(parent: CharacterBody2D, delta: float, move_mult: Vector2 = Vector2.ONE,
		src: PlayerInput = null) -> bool:
	if src == null:
		src = LocalInputSource.new()
	var grid := MazeGenerator.current_grid
	var feet := Vector2(parent.global_position.x, parent.global_position.y + Water.feet_offset(parent))
	in_water = not grid.is_empty() and Water.is_in_water(feet)
	if not in_water:
		return false
	var horiz := src.get_axis("left", "right")
	# 时间场加速倍率（同时支持单人关卡与多人模式时间加速）
	var tm := 1.0
	if TimeField.current != null:
		tm = TimeField.player_speed_mult()
	else:
		tm = float(parent.get("pvp_haste_mult"))
	if tm <= 0.0:
		tm = 1.0
	# 水平游泳移动，受到武器负重与时间加速倍率影响
	var target_vx := horiz * PlayerParams.player_swim_speed * move_mult.x * tm
	parent.velocity.x = MathUtil.approach(parent.velocity.x, target_vx, PlayerParams.player_swim_accel, delta)
	# 垂直方向：按上键上浮，松开下沉
	parent.velocity.y = (PlayerParams.player_swim_up if src.is_action_pressed("up") else PlayerParams.player_swim_down) * tm
	return true
