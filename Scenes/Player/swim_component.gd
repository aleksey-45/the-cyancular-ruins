class_name SwimComponent
extends Node

# 主角水中物理:浮力弹簧回水面 + 上浮/下沉 + 水平游泳。根每帧显式调用 update(),
# 返回是否在水中(据此跳过普通垂直/跳跃/下蹲/冲刺逻辑)。不写 _physics_process。

var in_water: bool = false


func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))


func update(parent: CharacterBody2D, delta: float, move_mult: Vector2 = Vector2.ONE) -> bool:
	var grid := MazeGenerator.current_grid
	var feet := Vector2(parent.global_position.x, parent.global_position.y + Water.feet_offset(parent))
	in_water = not grid.is_empty() and Water.is_in_water(feet)
	if not in_water:
		return false
	var surface_y := Water.surface_y_at(parent.global_position)
	var horiz := Input.get_axis("left", "right")
	# 水平游泳(吃武器移动惩罚 move_mult.x)
	var target_vx := horiz * PlayerParams.player_swim_speed * move_mult.x
	parent.velocity.x = _approach(parent.velocity.x, target_vx, PlayerParams.player_swim_accel, delta)
	# 垂直:上/下覆盖,无输入弹簧回水面(中心贴水面线,半没入)
	if Input.is_action_pressed("up"):
		parent.velocity.y = PlayerParams.player_swim_up
	elif Input.is_action_pressed("down"):
		parent.velocity.y = PlayerParams.player_swim_down
	else:
		var target_vy := clampf((surface_y - parent.global_position.y) * PlayerParams.player_buoyancy_k,
				-PlayerParams.player_max_float, PlayerParams.player_max_sink)
		parent.velocity.y = _approach(parent.velocity.y, target_vy, PlayerParams.player_water_damp, delta)
	return true
