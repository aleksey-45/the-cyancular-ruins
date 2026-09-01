class_name SwimComponent
extends Node

# 主角水中物理:水中按上上浮、不按下沉;出水(脚底离开水格)由 in_water 判回 false,
# 根直接切回普通物理(重力)。不做水面检测/悬停。根每帧显式调用 update(),
# 返回是否在水中(据此跳过普通垂直/跳跃/下蹲/冲刺逻辑)。不写 _physics_process。

var in_water: bool = false


func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))


func update(parent: CharacterBody2D, delta: float, move_mult: Vector2 = Vector2.ONE,
		src: InputSource = null) -> bool:
	# src=null(冒烟等直接调用)回落真实 Input;本地玩家传入自己的 input_source,服务器传入注入源。
	if src == null:
		src = InputSource.new()
	var grid := MazeGenerator.current_grid
	var feet := Vector2(parent.global_position.x, parent.global_position.y + Water.feet_offset(parent))
	in_water = not grid.is_empty() and Water.is_in_water(feet)
	if not in_water:
		return false
	var horiz := src.get_axis("left", "right")
	# 水平游泳(吃武器移动惩罚 move_mult.x)
	var target_vx := horiz * PlayerParams.player_swim_speed * move_mult.x
	parent.velocity.x = _approach(parent.velocity.x, target_vx, PlayerParams.player_swim_accel, delta)
	# 垂直:按上上浮,否则下沉。出水靠 in_water 判定自动切回重力,无需水面检测。
	parent.velocity.y = PlayerParams.player_swim_up if src.is_action_pressed("up") else PlayerParams.player_swim_down
	return true
