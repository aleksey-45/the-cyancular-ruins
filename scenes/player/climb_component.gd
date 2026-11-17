class_name ClimbComponent
extends Node

# 攀爬(梯子/锁链)子系统:中心/脚底在通道格按上主动攀附,不受重力;由根 player.gd 每物理帧显式调用(本组件不写 _physics_process,保证物理帧顺序)。

var body: CharacterBody2D

var haste_mult: float = 1.0

var _latched: bool = false


func _ready() -> void:
	body = get_parent() as CharacterBody2D

func is_latched() -> bool:
	return _latched

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

func update(mult: Vector2, delta: float, is_squat: bool,
		src: PlayerInput = null) -> bool:
	# ★ src 一律由调用方注入:本地玩家 = 自己的 input_source,服务器 = 注入的网络源;缺了就点名报错 + 按「这一帧没在攀爬」安全返回,绝不静默改读全局输入总线(headless 服务器会读到宿主机桌面按键),也不写 velocity。
	# ★ 缺 src 时 _latched 一并归 false:根读 is_latched() 决定是否跳过重力,留着上一帧的攀附态会把玩家挂在半空;正常路径不走这一支。
	if src == null:
		push_error("ClimbComponent.update: 缺 src(注入输入源)—— 本组件只读注入进来的输入,禁止读全局输入;本帧按「没在攀爬」安全返回(调用方应传 player.input_source)")
		_latched = false
		return false
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
	var foot_tex := MazeGenerator.texture_of(fv)
	var center_tex := MazeGenerator.texture_of(cv)
	var on_ladder := (fv != 0 and TileDefs.climb_descent_speed(foot_tex) > 0.0) \
			or (cv != 0 and TileDefs.climb_descent_speed(center_tex) > 0.0)
	var foot_in_channel := fv != 0 and TileDefs.climb_speed(foot_tex) > 0.0
	var center_in_channel := cv != 0 and TileDefs.climb_speed(center_tex) > 0.0
	var climb_input := src.get_axis("up", "down")
	if not _latched and (center_in_channel or foot_in_channel) and src.is_action_just_pressed("up"):
		_latched = true
	if _latched and not center_in_channel and not foot_in_channel and not _foot_at_ladder_top(foot_cell):
		_latched = false
	if not _latched:
		return false
	if climb_input < 0.0:
		if foot_in_channel or not _foot_at_ladder_top(foot_cell):
			# 脚底还没跨过梯顶 ⇒ 上爬:梯/链各自绝对速度 × 时间场倍率(加速时爬梯/爬链与陆上/水中同源)。
			var up_speed: float = PlayerParams.climb_ladder_up_speed if on_ladder \
					else PlayerParams.climb_chain_up_speed
			body.velocity.y = climb_input * up_speed * mult.y * _time_mult()
			return true
		if src.is_action_just_pressed("up"):
			_latched = false
			body.velocity.y = PlayerParams.jump_velocity * mult.y
			body.cancel_jump_state()
			return false
		body.velocity.y = 0.0
		return true
	elif climb_input > 0.0:
		var dcs := TileDefs.climb_descent_speed(MazeGenerator.texture_of(fv))
		if dcs <= 0.0:
			_latched = false
			return false
		body.velocity.y = climb_input * PlayerParams.climb_ladder_down_speed * mult.y * _time_mult()
		return true
	body.velocity.y = 0.0
	return false

func _foot_at_ladder_top(foot_cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var below: int = grid[posmod(foot_cell.y + 1, rows)][foot_cell.x]
	return below != 0 and TileDefs.climb_speed(MazeGenerator.texture_of(below)) > 0.0

func _climb_foot_offset() -> float:
	return Water.feet_offset(body)


# 时间场倍率(加速 ×2,正常 1;回溯整帧由根早退接管,故 0 一律当 1)。判据与根 player.gd 同源:有世界时间场就走它,否则读根每帧推入的 haste_mult(PvP 的 worker 与本端预测各写同一字段)。
func _time_mult() -> float:
	var m := haste_mult
	if TimeField.current != null:
		m = TimeField.player_speed_mult()
	return m if m > 0.0 else 1.0


# 整态里的攀爬段(键名 = NetCodec 的 C2_SCHEMA 标志位 `clatch`)。状态归本组件所有,根的编解码只做装配。
func capture_state() -> Dictionary:
	return {"clatch": _latched}


func restore_state(st: Dictionary) -> void:
	_latched = bool(st.get("clatch", _latched))
