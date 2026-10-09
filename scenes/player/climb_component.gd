class_name ClimbComponent
extends Node

# 攀爬(梯子/锁链)子系统:中心/脚底在通道格按上主动攀附,不受重力。
# 由根 player.gd 每物理帧显式调用(不在本组件写 _physics_process,保证物理帧顺序)。

var body: CharacterBody2D

# 加速倍率(PvP):由**根每物理帧推入**(`player.gd` 的 `_push_haste_mult`)。
# ★ 为什么是"注入成员"而不是 `update()` 的调用参数或构造参数:宿主引用只在 `_ready` 里拿一次
#   (`body = get_parent()`),而倍率**每帧都在变**(按住加速键才 >1)⇒ 只能每帧推。
# ★ 覆盖上限(照实):默认 1.0 ⇒ 调用方忘推 = 静默不加速(不报错)。钉它的是
#   rewind_weapon_probe.gd(已删·2026-10-09) 的 S10(形状 + 行为两条:梯上 vy 随倍率变)。
var haste_mult: float = 1.0

var _latched: bool = false   # 攀附状态:中心在通道格(梯/锁链)即攀附,不受重力

# (此处原有 const STOP_SNAP := 1.0 —— **死副本**:全仓零使用,注释描述的是一个从未接线的意图。
#  2026-09-14 删除;水平速度归零的阈值现由 PlayerParams.stop_snap 单一持有。本文件此前也有过
#  一份零调用的 _approach 死副本(批次 1 已删),抄常量前先 grep 一下还有没有别的使用者。)

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
	return TileDefs.climb_speed(MazeGenerator.texture_of(fv)) > 0.0 or TileDefs.climb_speed(MazeGenerator.texture_of(cv)) > 0.0

# 攀爬判定与攀附状态机:中心(或脚底)在通道格按上主动攀附(不受重力)。
# **到顶 = 脚底进入梯子上方一格才停**(以脚底为参考格);再按上 = 跳离梯子。
# 上爬按瓦片 climb_speed 倍(梯 1.6/锁链 2.0),下降按 climb_descent_speed 倍(梯 2.0),
# 锁链无下降倍率(0)→ 解除攀附交给重力自由落体;松开挂住。返回「正在垂直攀爬」。
# 上爬与梯子下行再整体 × PlayerParams.climb_vertical_mult(1.2;锁链下行=自由落体不受影响)。
func update(mult: Vector2, delta: float, is_squat: bool,
		src: PlayerInput = null) -> bool:
	# ★★ 2026-10-04(审计 §2.6 的**第 5 处**,与武器那三处 / 游泳那处**逐字同款**):这里原先
	#   缺 src 就**自己造一个「读真实输入总线」的本地源**兜底。那让本组件能从全局输入总线偷读,
	#   而且**完全不报错**;在权威服务器 / 回放 / 预测下那是错的来源(headless 服务器读到的是
	#   **宿主机桌面**的按键状态)。现在:src **一律由调用方注入**(本地玩家 = 自己的 input_source,
	#   服务器 = 注入的网络源),缺了就**点名报错** + 按「这一帧没在攀爬」安全返回,绝不静默改读
	#   全局输入,也**不碰** body 物理(不写 velocity)。
	#   ★ `_latched` 一并归 false:缺 src 时这一帧并没有被真正驱动,不能把上一帧的攀附态留在原地
	#     —— 根读的是 `is_latched()`(`player.gd:261`),留着它就等于让根继续跳过重力、把玩家挂在半空。
	#     (有 src 的正常路径压根不走这一支;且正常路径本来就允许「`_latched` 真 + 返回 false」= 到顶挂住。)
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
			# 时间场:加速时爬梯/爬链也按主角时间加快(与陆上/水中同源)
			var spd := PlayerParams.climb_speed * cs * PlayerParams.climb_vertical_mult * mult.y * _time_mult()
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

# 脚底到玩家中心的距离(攀爬姿态 FLY 碰撞箱底部,含 scale 2.5)。
func _climb_foot_offset() -> float:
	return 57.0


# 时间场倍率(加速 ×2;正常 1)。回溯整帧由根早退接管,故 0 一律当 1 处理。
#
# ★★ 2026-10-03 修:**PvP 下这条原先恒返回 1** —— `TimeField.current` 只由单机 Level0 创建,
#   PvP/菜单恒 null ⇒ `player_speed_mult()` 恒 1.0,与本文件"加速时爬梯/爬链也按主角时间加快"
#   的注释自相矛盾(一下水/一上梯,加速就没了)。
#   改成与根 `player.gd:191` **同一条判据**:有世界时间场就走它,否则读自己那个
#   `pvp_haste_mult`(worker 与本端预测各自每帧写的同一字段)。
# ★★ 2026-10-05(closeout 批 Task 3 / T10):那一半原先走 `body.get("pvp_haste_mult")` ——
#   **字符串反射**,而 `body` 的静态类型是 `CharacterBody2D`(玩家根没有 `class_name`)。
#   现在读**根每帧推入**的注入成员 `haste_mult`(见该成员上方)。单机那一支**原样保留**。
func _time_mult() -> float:
	var m := haste_mult
	if TimeField.current != null:
		m = TimeField.player_speed_mult()
	return m if m > 0.0 else 1.0
