class_name SwimComponent
extends Node

# 主角水中物理:水中按上上浮、不按下沉;出水(脚底离开水格)由 in_water 判回 false,
# 根直接切回普通物理(重力)。不做水面检测/悬停。根每帧显式调用 update(),
# 返回是否在水中(据此跳过普通垂直/跳跃/下蹲/冲刺逻辑)。不写 _physics_process。

var in_water: bool = false


func update(parent: CharacterBody2D, delta: float, move_mult: Vector2 = Vector2.ONE,
		src: PlayerInput = null) -> bool:
	# ★★ 2026-10-04(审计 §2.6 的**第 4 处**,与武器那三处同款):这里原先缺 src 就**自己造一个
	#   读真实输入总线的本地源**兜底。那让本组件能从全局输入总线偷读,而且**完全不报错**;
	#   在权威服务器 / 回放 / 预测下那是错的来源(headless 服务器读到的是**宿主机桌面**的按键
	#   状态)。现在:src **一律由调用方注入**(本地玩家 = 自己的 input_source,服务器 = 注入的
	#   网络源),缺了就**点名报错** + 按「不在水中」安全返回,绝不静默改读全局输入。
	#   ★ in_water 一并归 false,是为保住正常路径同款的不变式「返回 true ⇔ 在 水中」——
	#     否则读 `swim.in_water` 的副本/渲染会看到与根逻辑矛盾的残值。
	if src == null:
		push_error("SwimComponent.update: 缺 src(注入输入源)—— 本组件只读注入进来的输入,禁止读全局输入;本帧按「不在水中」安全返回(调用方应传 player.input_source)")
		in_water = false
		return false
	var grid := MazeGenerator.current_grid
	var feet := Vector2(parent.global_position.x, parent.global_position.y + Water.feet_offset(parent))
	in_water = not grid.is_empty() and Water.is_in_water(feet)
	if not in_water:
		return false
	var horiz := src.get_axis("left", "right")
	# 时间场:加速是"主角的时间加快",水里/上下浮同样要快(否则一下水加速就没了)。
	# 回溯整帧早在根里早退,到不了这里;正常态该倍率恒 1。
	# ★★ 2026-10-03 修:**PvP 下这条原先恒 1** —— `TimeField.current` 只由单机 Level0 创建
	#   ⇒ PvP 里 `player_speed_mult()` 恒 1.0,与本行上面那句注释直接矛盾。
	#   改成与根 `player.gd:191` 同一条判据:有世界时间场走它,否则读 `pvp_haste_mult`。
	var tm := 1.0
	if TimeField.current != null:
		tm = TimeField.player_speed_mult()
	else:
		tm = float(parent.get("pvp_haste_mult"))
	if tm <= 0.0:
		tm = 1.0
	# 水平游泳(吃武器移动惩罚 move_mult.x)
	var target_vx := horiz * PlayerParams.player_swim_speed * move_mult.x * tm
	parent.velocity.x = MathUtil.approach(parent.velocity.x, target_vx, PlayerParams.player_swim_accel, delta)
	# 垂直:按上上浮,否则下沉。出水靠 in_water 判定自动切回重力,无需水面检测。
	parent.velocity.y = (PlayerParams.player_swim_up if src.is_action_pressed("up") else PlayerParams.player_swim_down) * tm
	return true
