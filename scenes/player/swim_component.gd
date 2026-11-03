class_name SwimComponent
extends Node

# 主角水中物理:水中按上上浮、不按下沉;出水由 Water.sample_body 的滞回判回 false,
# 根直接切回普通物理(重力)。不做水面检测/悬停。根每帧显式调用 update(),
# 返回是否在水中(据此跳过普通垂直/跳跃/下蹲/冲刺逻辑)。不写 _physics_process。

const WaterSample := preload("res://core/sim/water_sample.gd")

var in_water: bool = false
# 本帧水判定(唯一来源):根读它做呼吸/形变,别在根里再查一次水面(旧实现因此把呼吸线换成"中心+10px")。
var sample: WaterSample = null


func update(parent: CharacterBody2D, delta: float, move_mult: Vector2 = Vector2.ONE,
		src: PlayerInput = null, haste_mult: float = 1.0) -> bool:
	# ★★ 2026-10-04(审计 §2.6 的**第 4 处**,与武器那三处同款):这里原先缺 src 就**自己造一个
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
	# 时间场:加速是"主角的时间加快",水里/上下浮同样要快(否则一下水加速就没了)。
	var tm := haste_mult
	if TimeField.current != null:
		tm = TimeField.player_speed_mult()
	if tm <= 0.0:
		tm = 1.0
	# 水平游泳(吃武器移动惩罚 move_mult.x)
	var target_vx := horiz * PlayerParams.player_swim_speed * move_mult.x * tm
	parent.velocity.x = MathUtil.approach(parent.velocity.x, target_vx, PlayerParams.player_swim_accel, delta)
	# 垂直:按上上浮,否则下沉。出水靠 in_water 判定自动切回重力,无需水面检测。
	parent.velocity.y = (PlayerParams.player_swim_up if src.is_action_pressed("up") else PlayerParams.player_swim_down) * tm
	return true
