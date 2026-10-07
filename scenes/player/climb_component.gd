class_name ClimbComponent
extends Node

# 攀爬（梯子/锁链）子系统：角色中心或脚底处于通道格时，按上方向键主动攀附，攀附状态下不受重力影响。
# 由根节点 player.gd 每物理帧显式调用驱动。

var body: CharacterBody2D

var _latched: bool = false   # 攀附状态：处于通道格内并激活攀附时为 true


func _ready() -> void:
	body = get_parent() as CharacterBody2D


func is_latched() -> bool:
	return _latched


# 中心或脚底是否处于攀爬通道格内（梯子或锁链）。处于通道格时禁止空中下冲。
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
	return TileDefs.climb_speed(MazeGenerator.texture_of(fv)) > 0.0 or TileDefs.climb_speed(MazeGenerator.texture_of(cv)) > 0.0


# 攀爬状态判定与移动更新：
# 中心或脚底在通道格内按上方向键主动攀附（不受重力）。
# 到达梯顶时脚底越过梯子顶格停止上升，再次按跳跃键可跳离梯子。
# 攀爬速度根据瓦片配置缩放，锁链无下行减速（向下移动直接脱离攀附）。
func update(mult: Vector2, delta: float, is_squat: bool,
		src: PlayerInput = null) -> bool:
	if src == null:
		src = LocalInputSource.new()
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
	var cs: float = maxf(TileDefs.climb_speed(MazeGenerator.texture_of(fv)), TileDefs.climb_speed(MazeGenerator.texture_of(cv)))
	var foot_in_channel := fv != 0 and TileDefs.climb_speed(MazeGenerator.texture_of(fv)) > 0.0
	var center_in_channel := cv != 0 and TileDefs.climb_speed(MazeGenerator.texture_of(cv)) > 0.0
	var climb_input := src.get_axis("up", "down")
	if not _latched and (center_in_channel or foot_in_channel) and src.is_action_just_pressed("up"):
		_latched = true
	if _latched and not center_in_channel and not foot_in_channel and not _foot_at_ladder_top(foot_cell):
		_latched = false
	if not _latched:
		return false
	if climb_input < 0.0:
		if foot_in_channel or not _foot_at_ladder_top(foot_cell):
			# 向上攀爬：按基础爬速、瓦片倍率与时间场倍率计算垂直速度
			var spd := PlayerParams.climb_speed * cs * PlayerParams.climb_vertical_mult * mult.y * _time_mult()
			body.velocity.y = climb_input * spd
			return true
		# 到达梯顶：再次按向上方向键跳离梯子
		if src.is_action_just_pressed("up"):
			_latched = false
			body.velocity.y = PlayerParams.jump_velocity * mult.y
			body.cancel_jump_state()
			return false
		body.velocity.y = 0.0  # 梯顶悬停挂住
		return true
	elif climb_input > 0.0:
		var dcs := TileDefs.climb_descent_speed(MazeGenerator.texture_of(fv))
		if dcs <= 0.0:
			# 锁链无下行减速倍率，脱离攀附转为自由落体
			_latched = false
			return false
		body.velocity.y = climb_input * PlayerParams.climb_speed * dcs * PlayerParams.climb_vertical_mult * mult.y * _time_mult()
		return true
	body.velocity.y = 0.0  # 原地停留悬停挂住
	return false


# 检测脚底所在格下方是否仍为梯子（判定是否处于梯顶悬挂状态）
func _foot_at_ladder_top(foot_cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var below: int = grid[posmod(foot_cell.y + 1, rows)][foot_cell.x]
	return below != 0 and TileDefs.climb_speed(MazeGenerator.texture_of(below)) > 0.0


# 脚底到玩家中心的世界坐标垂直偏移量
func _climb_foot_offset() -> float:
	return 57.0


# 获取当前时间场速度倍率（支持单人模式与多人模式时间加速）
func _time_mult() -> float:
	var m := 1.0
	if TimeField.current != null:
		m = TimeField.player_speed_mult()
	elif body != null:
		m = float(body.get("pvp_haste_mult"))
	return m if m > 0.0 else 1.0
