class_name MenuDemoAi
extends Node

# 主菜单背景的实机演示 AI:驱动一个真实 Player(注入 DemoInputSource)在地图里
# 追打最近的鸟,死光自动在远处补一批——相当于循环的实机宣传片。
# 输入完全走 player 现成的注入接口(InputSource 覆写),与 PvP 服务器的注入同一条路。

const DEMO_ENEMY_COUNT := 6        # 同屏演示鸟数量
const RESPAWN_CHECK := 2.0         # 补怪检查间隔(秒)
const ENGAGE_RADIUS := 1000.0      # 追击半径(环面 px)
const FIRE_RADIUS := 700.0         # 开火半径
const WANDER_FLIP := 1.6           # 无目标时的游走换向间隔(秒)

var player: CharacterBody2D = null
var src: MenuDemoAi.DemoInputSource = null

var _respawn_timer := 0.0
var _wander_timer := 0.0
var _wander_dir := 1.0
var _world: Node = null
var _home := Vector2.ZERO        # 出生点世界坐标(AI 活动范围与复活参考)
var _down_t := 0.0               # 倒地累计(演示里倒地太久就自动复活重置)


class DemoInputSource:
	extends InputSource
	# AI 的"手柄":字段由 MenuDemoAi 每帧写,player/weapon 经基类接口读取。
	var demo_axis := 0.0          # 水平移动 -1/0/1
	var demo_aim := Vector2.RIGHT # 瞄准方向(世界坐标;get_aim_dir_override 注入)
	var demo_fire := false        # 按住开火
	var _jump_edge := false       # 一次性跳跃边沿

	func press_jump() -> void:
		_jump_edge = true

	func get_axis(neg: String, pos: String) -> float:
		return demo_axis if neg == "left" else 0.0   # 垂直轴不参与(AI 不爬梯)

	func is_action_pressed(action: String) -> bool:
		return false   # 无持续按住的移动键(垂直/下蹲/冲刺都不用)

	func is_action_just_pressed(action: String) -> bool:
		if action == "up":
			var v := _jump_edge
			_jump_edge = false
			return v
		return false

	func is_action_just_released(_action: String) -> bool:
		return false

	func is_attack_pressed() -> bool:
		return demo_fire

	func is_attack_just_pressed() -> bool:
		return demo_fire

	func is_attack_just_released() -> bool:
		return false

	func get_weapon_slot_pressed() -> int:
		return 0   # 不切枪,手枪打全场

	func get_aim_dir_override() -> Vector2:
		return demo_aim


func setup(p: CharacterBody2D, s: MenuDemoAi.DemoInputSource) -> void:
	player = p
	src = s
	_world = p.get_parent()
	_home = p.global_position


func _ready() -> void:
	_spawn_wave()


func _physics_process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	# 演示里被打倒:2 秒后原地满血复活(背景演出不能一直躺着)
	if player.is_downed():
		_down_t += delta
		if _down_t > 2.0:
			_down_t = 0.0
			player.combat.revive()
			player.global_position = _home
			player.velocity = Vector2.ZERO
		return
	_down_t = 0.0
	# 活动范围钳制:离出生点太远就往回走(碰撞只建了出生点周边)
	var to_home := MazeGenerator.toroidal_delta_px(player.global_position, _home,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var far_from_home := to_home.length() > 1150.0
	_respawn_timer -= delta
	if _respawn_timer <= 0.0:
		_respawn_timer = RESPAWN_CHECK
		if _alive_enemy_count() == 0:
			_spawn_wave()

	var target := _nearest_enemy()
	if target != null:
		# 追打最近的鸟:贴脸距离内开火,太近后撤保持射击距离
		var to := MazeGenerator.toroidal_delta_px(player.global_position,
				(target as Node2D).global_position, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		src.demo_aim = to.normalized()
		var d := to.length()
		if d > FIRE_RADIUS * 0.75:
			src.demo_axis = 1.0 if to.x > 0.0 else -1.0
		elif d < 180.0:
			src.demo_axis = -1.0 if to.x > 0.0 else 1.0   # 拉开距离
		else:
			src.demo_axis = 0.0
		src.demo_fire = d <= FIRE_RADIUS
		# 被墙挡/贴墙 → 跳
		if player.is_on_wall() or (absf(src.demo_axis) > 0.0 and player.velocity.x == 0.0
				and player.is_on_floor()):
			src.press_jump()
	else:
		# 没目标:左右游走等补怪;跑出活动区就先回家
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = WANDER_FLIP
			_wander_dir = -_wander_dir
		if far_from_home and absf(to_home.x) > 40.0:
			_wander_dir = 1.0 if to_home.x > 0.0 else -1.0
		src.demo_axis = _wander_dir
		src.demo_aim = Vector2(_wander_dir, 0.0)
		src.demo_fire = false
		if player.is_on_wall():
			src.press_jump()


func _nearest_enemy() -> Node2D:
	var best: Node2D = null
	var best_d := ENGAGE_RADIUS
	for e in get_tree().get_nodes_in_group("enemies"):
		var e2 := e as Node2D
		if e2 == null or not is_instance_valid(e2):
			continue
		if "is_dead" in e2 and e2.is_dead:
			continue   # 尸体不追
		var d := MazeGenerator.toroidal_delta_px(player.global_position, e2.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d < best_d:
			best_d = d
			best = e2
	return best


func _alive_enemy_count() -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e) and not ("is_dead" in e and e.is_dead):
			n += 1
	return n


# 在玩家 6~14 格外刷一波演示鸟(类型循环取自注册表;复用 spawner 的地板格采样)
func _spawn_wave() -> void:
	if player == null:
		return
	EnemySpawner.load_types()
	if EnemySpawner.TYPES.is_empty():
		return
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return
	var cols := grid[0].size()
	var rows := grid.size()
	var player_cell := MazeGenerator.cell_of(player.global_position, GameParameters.TILE_SIZE, cols, rows)
	var cells := EnemySpawner.sample_spawn_cells(grid, player_cell, DEMO_ENEMY_COUNT, 6)
	var ids := EnemySpawner.TYPES.keys()
	var ts := GameParameters.TILE_SIZE
	for c in cells:
		var scene: PackedScene = load(EnemySpawner.TYPES[ids[randi() % ids.size()]])
		if scene == null:
			continue
		var e := scene.instantiate()
		_world.add_child(e)
		e.global_position = Vector2(c.x * ts + ts * 0.5, c.y * ts + ts * 0.5)
