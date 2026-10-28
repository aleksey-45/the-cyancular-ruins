extends ProbeBase

var space: SubViewport

func probe_id() -> String:
	return "ELASTIC COLLISION"

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	TileDefs.load_defs()
	space = SubViewport.new()
	space.world_2d = World2D.new()
	add_child(space)
	_build_arena(15, 15)
	for impact in [
		[Vector2(512, 440), Vector2.DOWN, Vector2.UP],
		[Vector2(512, 210), Vector2.UP, Vector2.DOWN],
		[Vector2(824, 300), Vector2.RIGHT, Vector2.LEFT],
		[Vector2(200, 300), Vector2.LEFT, Vector2.RIGHT],
	]:
		var player := _player(impact[0], impact[1] * 600.0)
		await _impact(player)
		var normal: Vector2 = impact[2]
		_check(is_equal_approx(player.velocity.dot(normal), PlayerParams.elastic_bounce),
				"弹性表面的向外速度 %s：%s" % [normal, player.velocity])
		var peak := 0.0
		for tick in 60:
			await get_tree().physics_frame
			ActorStep.step(player, InputBuffer.neutral())
			peak = maxf(peak, player.velocity.length())
		_check(peak <= PlayerParams.elastic_bounce + 0.1, "离开弹性表面时速度保持有界：%s" % peak)
		player.free()
	_summary(0, "地面、天花板与两侧墙面反弹")

	_build_arena(15, 15, false, 34)
	for speed in [0.0, -150.0]:
		var resting := _player(Vector2(512, 486.9266), Vector2(0, speed))
		resting._grounded = true
		await get_tree().physics_frame
		ActorStep.step(resting, InputBuffer.neutral())
		_check(absf(resting.velocity.y) <= absf(speed) + 0.1, "静止或向外移动不获得额外冲量")
		resting.free()

	_build_arena(15, 1)
	var mixed := _player(Vector2(512, 440), Vector2(0, 600))
	await _impact(mixed)
	_check(is_equal_approx(mixed.velocity.y, -PlayerParams.elastic_bounce), "读取接触子格的弹性材质")
	mixed.free()
	_build_arena(1, 15)
	mixed = _player(Vector2(512, 440), Vector2(0, 600))
	await _impact(mixed)
	_check(mixed.velocity.is_zero_approx(), "同大格的普通子格正常落地")
	mixed.free()

	# 接缝处留下 64px 宽的缺口，从地形上方落下的矩形同时接触两侧。
	_build_arena(15, 15, true)
	var wedged := _player(Vector2(5.567913, 440), Vector2(0, 1000))
	wedged.state = wedged.Pose.FLY
	wedged.gravity = GameParameters.gravity0
	var late_peak := 0.0
	for tick in 360:
		await get_tree().physics_frame
		ActorStep.step(wedged, InputBuffer.neutral())
		if tick >= 60:
			late_peak = maxf(late_peak, wedged.velocity.length())
	_check(late_peak < 600.0, "弹性地形缺口内速度不持续累积：%s" % late_peak)
	print("ELASTIC GAP late_peak=", late_peak)
	wedged.free()
	_build_arena(1, 1, true)
	wedged = _player(Vector2(5.567913, 440), Vector2(0, 1000))
	wedged.state = wedged.Pose.FLY
	wedged.gravity = GameParameters.gravity0
	late_peak = 0.0
	for tick in 180:
		await get_tree().physics_frame
		ActorStep.step(wedged, InputBuffer.neutral())
		if tick >= 60:
			late_peak = maxf(late_peak, wedged.velocity.length())
	_check(late_peak < 100.0, "普通地形夹缝中速度不随重力持续累积：%s" % late_peak)
	wedged.free()
	_build_arena(15, 15, false, 34, true)
	wedged = _player(Vector2(512, 476.6535), Vector2(0, 4000))
	wedged.state = wedged.Pose.MOVE
	wedged.gravity = GameParameters.gravity0
	late_peak = 0.0
	for tick in 180:
		await get_tree().physics_frame
		ActorStep.step(wedged, InputBuffer.neutral())
		if tick >= 30:
			late_peak = maxf(late_peak, wedged.velocity.length())
	_check(late_peak < PlayerParams.elastic_bounce * 2.0, "残留子格处保持弹性反弹，速度不持续累积：%s" % late_peak)
	wedged.free()
	var resting := _player(Vector2(512, 510), Vector2.ZERO)
	var at_rest := resting.position
	await get_tree().physics_frame
	ActorStep.move_by(resting, Vector2.ZERO)
	_check(resting.position == at_rest, "没有击退时不执行额外的碰撞恢复移动")
	resting.free()
	space.free()
	_finish()

func _build_arena(material: int, macro_material: int, gap := false, floor_y := 32, fragment := false) -> void:
	for child in space.get_children():
		child.free()
	GameParameters.MAP_WIDTH = 1024
	GameParameters.MAP_HEIGHT = 768
	var subgrid: Array[Array] = []
	var grid: Array[Array] = []
	for y in 48:
		var row: Array[int] = []
		for x in 64:
			var solid := y == 8 or y == floor_y or x == 8 or x == 55
			if gap:
				solid = y == 32 and x >= 2 and x < 62
			if fragment and x == 33 and y == 32:
				solid = true
			row.append(material if solid else 0)
		subgrid.append(row)
	for y in 12:
		var row: Array[int] = []
		row.resize(16)
		row.fill(0)
		for x in 16:
			for sy in 4:
				for sx in 4:
					if subgrid[y * 4 + sy][x * 4 + sx] != 0:
						row[x] = MazeGenerator.pack(macro_material, 15)
		grid.append(row)
	TileDefs.load_terrain(grid, subgrid)
	TileDefs.terrain.attach(space)

func _player(at: Vector2, velocity: Vector2) -> CharacterBody2D:
	var player: CharacterBody2D = preload("res://scenes/player/player.tscn").instantiate()
	space.add_child(player)
	player.set_physics_process(false)
	player.position = at
	player.velocity = velocity
	player.gravity = 0.0
	player.accel_air = 0.0
	player.brake_air = 0.0
	player.brake_ground = 0.0
	player.state_lock_timer = 100.0
	return player

func _impact(player: CharacterBody2D) -> void:
	for tick in 20:
		await get_tree().physics_frame
		ActorStep.step(player, InputBuffer.neutral())
		if not player.motion_contacts.is_empty():
			return
	_check(false, "角色在预期时间内撞到地形")
