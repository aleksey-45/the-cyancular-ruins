extends Node

# 大乱斗机器人试玩 helper(存活场景切换):进 royale_game 后给本地玩家挂
# BotInputSource(随机走/跳/周期开火/旋转瞄准),周期记录状态,超时或终局退出。

var _bot_index := 1
var _elapsed := 0.0
var _logged := 0
var _snap0 := 0
var _src = null
var _player: Node2D = null
var _downed_count := 0
var _was_downed := false
var _pos_changed := false
var _last_pos := Vector2.INF
var _snaps := 0
var _result_written := false


class BotInputSource:
	extends InputSource
	# 机器人的"手柄":随机游走 + 跳跃边沿 + 周期开火脉冲 + 旋转瞄准
	var axis := 0.0
	var aim := Vector2.RIGHT
	var fire := false
	var _jump_edge := false
	var _t := 0.0
	var _next_dir := 0.0
	var _next_fire := 0.6

	func tick(delta: float) -> void:
		_t += delta
		if _t >= _next_dir:
			_next_dir = _t + randf_range(0.8, 2.0)
			axis = [-1.0, 1.0, 0.0][randi() % 3]
			if randf() < 0.4:
				_jump_edge = true
		if _t >= _next_fire:
			_next_fire = _t + randf_range(0.5, 1.1)
			fire = true
		else:
			fire = false
		aim = Vector2.from_angle(0.7 * _t)

	func get_axis(_neg: String, _pos: String) -> float:
		return axis

	func is_action_pressed(_action: String) -> bool:
		return false

	func is_action_just_pressed(action: String) -> bool:
		if action == "up":
			var v := _jump_edge
			_jump_edge = false
			return v
		return false

	func is_action_just_released(_action: String) -> bool:
		return false

	func is_attack_pressed() -> bool:
		return fire

	func is_attack_just_pressed() -> bool:
		return fire

	func is_attack_just_released() -> bool:
		return false

	func get_weapon_slot_pressed() -> int:
		return 0

	func get_aim_dir_override() -> Vector2:
		return aim


func _ready() -> void:
	NetBus.local_snapshot.connect(func(_s: Dictionary) -> void: _snaps += 1)
	_run()


func _run() -> void:
	# 等 royale_game 场景就绪
	for i in range(120):
		await get_tree().create_timer(0.5).timeout
		var cur := get_tree().current_scene
		if cur != null and cur.scene_file_path.ends_with("royale_game.tscn"):
			break
	var cur := get_tree().current_scene
	if cur == null or not cur.scene_file_path.ends_with("royale_game.tscn"):
		print("BOT[%d]: FAIL 未进入 royale_game" % _bot_index)
		_quit_fail()
		return
	print("BOT[%d]: 已进对局场景" % _bot_index)
	await get_tree().create_timer(1.0).timeout
	_player = get_tree().get_first_node_in_group("player")
	if _player == null:
		print("BOT[%d]: FAIL 找不到玩家" % _bot_index)
		_quit_fail()
		return
	_src = BotInputSource.new()
	_player.set_input_source(_src)
	print("BOT[%d]: Bot 输入源已挂载" % _bot_index)
	set_process(true)


func _process(delta: float) -> void:
	if _src != null and is_instance_valid(_src):
		_src.tick(delta)
	_elapsed += delta
	# 每 10s 打点
	if _elapsed >= (_logged + 1) * 10.0:
		_logged += 1
		var pos := Vector2.INF
		var downed := false
		if _player != null and is_instance_valid(_player):
			pos = _player.global_position
			downed = _player.is_downed()
		print("BOT[%d]: t=%d snaps=%d pos=%s downed=%s" % [_bot_index, int(_elapsed), _snaps, pos, downed])
	# 位置变化检测(快照是否真的在驱动本地玩家)
	if _player != null and is_instance_valid(_player):
		var p := _player.global_position
		if _last_pos != Vector2.INF and p.distance_to(_last_pos) > 8.0:
			_pos_changed = true
		_last_pos = p
		var d: bool = _player.is_downed()
		if d and not _was_downed:
			_downed_count += 1
		_was_downed = d
	# 110 秒结束写结果
	if _elapsed >= 110.0 and not _result_written:
		_write_result()


func _write_result() -> void:
	_result_written = true
	var f := FileAccess.open("user://royale_playtest_result_%d.txt" % _bot_index, FileAccess.WRITE)
	f.store_string("in_game=true\nsnaps=%d\npos_changed=%s\ndowned=%d\n" % [_snaps, _pos_changed, _downed_count])
	print("BOT[%d]: RESULT written (snaps=%d pos_changed=%s downed=%d)" % [_bot_index, _snaps, _pos_changed, _downed_count])
	get_tree().quit(0)


func _quit_fail() -> void:
	var f := FileAccess.open("user://royale_playtest_result_%d.txt" % _bot_index, FileAccess.WRITE)
	f.store_string("in_game=false\n")
	get_tree().quit(1)
