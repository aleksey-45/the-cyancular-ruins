class_name ClimbComponent
extends Node

# 攀爬(梯子/锁链)子系统:中心/脚底在通道格按上主动攀附,不受重力;由根 player.gd 每物理帧显式调用(本组件不写 _physics_process,保证物理帧顺序)。

var body: CharacterBody2D

# ★ 加速倍率(PvP)由根每物理帧推入(_push_haste_mult):宿主引用只在 _ready 里拿一次,而倍率每帧都在变,只能每帧推。
# ★ 覆盖上限:默认 1.0 ⇒ 调用方忘推 = 静默不加速(不报错)。零守卫(rewind_weapon_probe 已删·2026-10-09 的 S10)。
var haste_mult: float = 1.0

var _latched: bool = false   # 攀附状态:中心在通道格(梯/锁链)即攀附,不受重力


func _ready() -> void:
	body = get_parent() as CharacterBody2D

func is_latched() -> bool:
	return _latched

# 中心或脚底是否在梯/链(攀爬通道)格内,未攀附也算:在梯/链上按↓只能下移/下落,不能触发 charge_down 穿过通道格(要上下得先按↑抓住)。
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

# 攀爬判定与攀附状态机:中心(或脚底)在通道格按上主动攀附(不受重力);到顶 = 脚底进入梯子上方一格才停,再按上 = 跳离梯子。
# 上爬按瓦片 climb_speed 倍(梯 1.6/锁链 2.0),下降按 climb_descent_speed(梯 2.0;锁链 0 ⇒ 解除攀附交重力),整体再 × PlayerParams.climb_vertical_mult(1.2);松开挂住。
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
	# 爬速取脚底/中心所在梯子的倍率较大者:基地时脚踩地中心在梯里、到顶时中心出梯脚还在梯里
	var cs: float = maxf(TileDefs.climb_speed(MazeGenerator.texture_of(fv)), TileDefs.climb_speed(MazeGenerator.texture_of(cv)))
	var foot_in_channel := fv != 0 and TileDefs.climb_speed(MazeGenerator.texture_of(fv)) > 0.0
	var center_in_channel := cv != 0 and TileDefs.climb_speed(MazeGenerator.texture_of(cv)) > 0.0
	var climb_input := src.get_axis("up", "down")
	# 进入攀附:中心或脚底在通道格且刚按下上(主动抓,不是按住 —— 跳离梯子后按着上也抓不回);退出:中心与脚底都不在通道格,且脚底不在梯顶。
	if not _latched and (center_in_channel or foot_in_channel) and src.is_action_just_pressed("up"):
		_latched = true
	if _latched and not center_in_channel and not foot_in_channel and not _foot_at_ladder_top(foot_cell):
		_latched = false
	if not _latched:
		return false
	if climb_input < 0.0:
		if foot_in_channel or not _foot_at_ladder_top(foot_cell):
			# 脚底还没跨过梯顶 ⇒ 上爬:climb_speed × 瓦片倍率 × 上行倍率 × 时间场倍率(加速时爬梯/爬链与陆上/水中同源)。
			var spd := PlayerParams.climb_speed * cs * PlayerParams.climb_vertical_mult * mult.y * _time_mult()
			body.velocity.y = climb_input * spd
			return true
		if src.is_action_just_pressed("up"):
			_latched = false
			body.velocity.y = PlayerParams.jump_velocity * mult.y
			body.cancel_jump_state()
			return false
		body.velocity.y = 0.0  # 到顶挂住(松开/再按上可跳)
		return true
	elif climb_input > 0.0:
		var dcs := TileDefs.climb_descent_speed(MazeGenerator.texture_of(fv))
		if dcs <= 0.0:
			# 锁链(无下降倍率)= 自由落体:解除攀附交给重力,落下不再抓回
			_latched = false
			return false
		body.velocity.y = climb_input * PlayerParams.climb_speed * dcs * PlayerParams.climb_vertical_mult * mult.y * _time_mult()
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
	return below != 0 and TileDefs.climb_speed(MazeGenerator.texture_of(below)) > 0.0

func _climb_foot_offset() -> float:
	return 57.0


# 时间场倍率(加速 ×2,正常 1;回溯整帧由根早退接管,故 0 一律当 1)。判据与根 player.gd 同源:有世界时间场就走它,否则读根每帧推入的 haste_mult(PvP 的 worker 与本端预测各写同一字段)。
func _time_mult() -> float:
	var m := haste_mult
	if TimeField.current != null:
		m = TimeField.player_speed_mult()
	return m if m > 0.0 else 1.0
