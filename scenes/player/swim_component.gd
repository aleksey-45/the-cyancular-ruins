class_name SwimComponent
extends Node


const WaterSample := preload("res://core/sim/water_sample.gd")

var in_water: bool = false
# 本帧水判定(唯一来源):根读它做呼吸/形变,别在根里再查一次水面(旧实现因此把呼吸线换成"中心+10px")。
var sample: WaterSample = null


func update(parent: CharacterBody2D, delta: float, move_mult: Vector2 = Vector2.ONE,
		src: PlayerInput = null, haste_mult: float = 1.0) -> bool:
	if src == null:
		push_error("SwimComponent.update: 缺 src(注入输入源)—— 本组件只读注入进来的输入,禁止读全局输入;本帧按「不在水中」安全返回(调用方应传 player.input_source)")
		in_water = false
		sample = null
		return false
	sample = Water.sample_body(parent, in_water)
	in_water = sample.in_water
	if not in_water:
		return false
	var horiz := src.get_axis("left", "right")
	var tm := haste_mult
	if TimeField.current != null:
		tm = TimeField.player_speed_mult()
	if tm <= 0.0:
		tm = 1.0
	var target_vx := horiz * PlayerParams.player_swim_speed * move_mult.x * tm
	parent.velocity.x = MathUtil.approach(parent.velocity.x, target_vx, PlayerParams.player_swim_accel, delta)
	parent.velocity.y = (PlayerParams.player_swim_up if src.is_action_pressed("up") else PlayerParams.player_swim_down) * tm
	return true
