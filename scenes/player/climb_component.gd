class_name ClimbComponent
extends Node

# 攀爬(梯子/锁链)子系统:中心/脚底在通道格按上主动攀附,不受重力。
# 由根 player.gd 每物理帧显式调用(不在本组件写 _physics_process,保证物理帧顺序)。

var body: CharacterBody2D

var _latched: bool = false   # 攀附状态:中心在通道格(梯/锁链)即攀附,不受重力

const STOP_SNAP := 1.0       # 与根一致:水平速度低于此值归零

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func is_latched() -> bool:
	return _latched

# 中心或脚底是否在梯/链(攀爬通道)格内——即使未攀附也算。用在梯/链上不能空中下冲:
# 按↓只能下移/下落,不能触发 charge_down 快速下坠穿过梯/链(要上下得先按↑抓住)。
func is_over_climb_tile() -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var cols := grid[0].size()
	var rows := grid.size()
	var foot_cell := MazeGenerator.cell_of(body.global_position + Vector2(0.0, _climb_foot_offset()),
			GameParameters.TILE_SIZE, cols, rows)
	var center_cell := MazeGenerator.cell_of(body.global_position, GameParameters.TILE_SIZE, cols, rows)
	var fv: int = grid[foot_cell.y][foot_cell.x]
	var cv: int = grid[center_cell.y][center_cell.x]
	return TileDefs.climb_speed(fv / 16) > 0.0 or TileDefs.climb_speed(cv / 16) > 0.0

# 攀爬判定与攀附状态机:中心(或脚底)在通道格按上主动攀附(不受重力)。
# **到顶 = 脚底进入梯子上方一格才停**(以脚底为参考格);再按上 = 跳离梯子。
# 上爬按瓦片 climb_speed 倍(梯 1.6/锁链 2.0),下降按 climb_descent_speed 倍(梯 2.0),
# 锁链无下降倍率(0)→ 解除攀附交给重力自由落体;松开挂住。返回「正在垂直攀爬」。
# 上爬与梯子下行再整体 × PlayerParams.climb_vertical_mult(1.2;锁链下行=自由落体不受影响)。
func update(mult: Vector2, delta: float, is_squat: bool,
		src: InputSource = null) -> bool:
	# src=null(冒烟等直接调用)回落真实 Input;本地玩家传入自己的 input_source,服务器传入注入源。
	if src == null:
		src = InputSource.new()
	var grid := MazeGenerator.current_grid
	if grid.is_empty() or is_squat:
		_latched = false
		return false
	var cols := grid[0].size()
	var rows := grid.size()
	var foot_pos := body.global_position + Vector2(0.0, _climb_foot_offset())
	var foot_cell := MazeGenerator.cell_of(foot_pos, GameParameters.TILE_SIZE, cols, rows)
	var center_cell := MazeGenerator.cell_of(body.global_position, GameParameters.TILE_SIZE, cols, rows)
	var fv: int = grid[foot_cell.y][foot_cell.x]
	var cv: int = grid[center_cell.y][center_cell.x]
	# 爬速取脚底/中心所在梯子的倍率较大者:基地时脚踩地中心在梯里、到顶时中心出梯脚还在梯里
	var cs: float = maxf(TileDefs.climb_speed(fv / 16), TileDefs.climb_speed(cv / 16))
	var foot_in_channel := fv != 0 and TileDefs.climb_speed(fv / 16) > 0.0
	var center_in_channel := cv != 0 and TileDefs.climb_speed(cv / 16) > 0.0
	var climb_input := src.get_axis("up", "down")
	# 进入攀附:中心或脚底在通道格且「刚按下上」(主动抓;不是按住——跳离梯子后按着上也抓不回)
	# 退出:中心与脚底都不在通道格,且脚底不在梯顶(到顶 = 挂住不算退出)
	if not _latched and (center_in_channel or foot_in_channel) and src.is_action_just_pressed("up"):
		_latched = true
	if _latched and not center_in_channel and not foot_in_channel and not _foot_at_ladder_top(foot_cell):
		_latched = false
	if not _latched:
		return false
	if climb_input < 0.0:
		if foot_in_channel or not _foot_at_ladder_top(foot_cell):
			# 脚底还没跨过梯顶(在梯子里/在梯子下方)→ 上爬:climb_speed × 瓦片倍率 × 上行倍率
			var spd := PlayerParams.climb_speed * cs * PlayerParams.climb_vertical_mult * mult.y
			body.velocity.y = climb_input * spd
			# 攀爬不锁横移:左右交给根的移动逻辑(爬的同时也能横向走)
			return true
		# 脚底进入梯子上方一格 → 到顶:再按上 = 跳离梯子,进入上方空间
		if src.is_action_just_pressed("up"):
			_latched = false
			body.velocity.y = PlayerParams.jump_velocity * mult.y
			body.cancel_jump_state()
			return false
		body.velocity.y = 0.0  # 到顶挂住(松开/再按上可跳)
		return true
	elif climb_input > 0.0:
		var dcs := TileDefs.climb_descent_speed(fv / 16)
		if dcs <= 0.0:
			# 锁链(无下降倍率)= 自由落体:解除攀附交给重力,落下不再抓回
			_latched = false
			return false
		body.velocity.y = climb_input * PlayerParams.climb_speed * dcs * PlayerParams.climb_vertical_mult * mult.y
		return true   # 攀爬不锁横移,左右由根处理
	body.velocity.y = 0.0  # 挂住:不受重力,原地停留
	return false

# 脚底所在格下方是否仍是梯子 → 脚底刚跨过梯顶(进入上方格),这是「到顶」,不解除攀附。
func _foot_at_ladder_top(foot_cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var below: int = grid[posmod(foot_cell.y + 1, rows)][foot_cell.x]
	return below != 0 and TileDefs.climb_speed(below / 16) > 0.0

# 脚底到玩家中心的距离(攀爬姿态 FLY 碰撞箱底部,含 scale 2.5)。
func _climb_foot_offset() -> float:
	return 57.0
