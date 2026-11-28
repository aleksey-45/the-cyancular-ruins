extends "res://tests/case.gd"

func run(tree: SceneTree) -> void:
	var map := CyrmMap.create(Vector2i(80, 60))
	var cell := Vector2i(31, 24)
	CyrmMap.write_cells(map, CyrmMap.SCENE, [cell.x, cell.y, CyrmMap.tile_value(19)])
	map.points[5] = {"kind": "lamp", "cell": cell + Vector2i.UP, "tone": "warm"}
	var stage := SubViewport.new()
	stage.size = Vector2i(1920, 1440)
	stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(stage)
	var path := "user://test-run-intro-%d-%d.dat" % [OS.get_process_id(), Time.get_ticks_usec()]
	var level := SoloLevel.create(map, cell + Vector2i(-10, -5), [WeaponType.RIFLE], path)
	stage.add_child(level)
	expect(not level.has_node("PreviousRun"), "the first run opens on the live battlefield")
	await _finish_opening(tree, level)
	level.set_process(false)
	level.set_physics_process(false)
	var actor := level.player
	level.world.combat.ground.spawn(WeaponType.RIFLE, 3, actor.position, Vector2.ZERO)
	var first := level._intro.frames.front() as DrawFrame
	var version := level.terrain.version
	level.terrain.apply_at(version, {cell: 0})
	level._presenter.accept({"current": level.world.sample()})
	level.terrain.apply_at(version, {})
	for i in 8:
		level._step(ActorInput.neutral())
	level._process(6.0)
	expect(level._intro.frames[-1].walls == first.walls and level._presenter.frame.cues.all(
			func(cue: Array) -> bool: return cue[0] != "debris"), "wall changes that cancel before a draw leave no debris")
	actor.equipped.reload_left = float(actor.equipped.definition.reload) * 0.5
	actor.apply_hit_health(actor.sim_hp - 3)
	level.terrain.apply_at(level.terrain.version, {cell: 0})
	level._presenter.watch.tremble = WatchHud.TREMBLE_TIME
	level._step(ActorInput.neutral())
	level._process(ActorStep.DT)
	var hit_index := level._intro.frames.size() - 1
	var hit := level._intro.frames[hit_index]
	var original := _values(hit)
	expect(not hit.world.prompts.is_empty() and hit.world.prompts[0][1] == Settings.get_binding_names("F"),
			"the published world prompt contains the current key label")
	expect(hit.world.reload[1] > 0.45 and hit.world.reload[1] < 0.55 and hit.post.hit_red > 0.0
			and hit.camera != level._presenter.camera.base_position and hit.hud.watch.shake != Vector2.ZERO,
			"the published frame includes an active reload, camera shake, hit flash and watch shake")
	var pixels := PackedByteArray()
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		pixels = stage.get_texture().get_image().get_data()
	actor.equipped.reload_left = 0.0
	actor.force_down()
	level._step(ActorInput.neutral())
	level._process(ActorStep.DT)
	var saved := RunIntro.load_pending(path)
	var down := saved.frames[-1]
	level._step(ActorInput.neutral())
	level._process(ActorStep.DT)
	expect(not level.has_node("PreviousRun") and level._view.post.visible and level._view.post._mat.get_shader_parameter("desat") == 1.0
			and level._intro.frames.size() == saved.frames.size(), "death saves its first visible frame and the match stays live")
	expect(down.post.desat == 1.0 and down.time - first.time > 5.0 and saved.frame_at(0.0) == down
			and _values(saved.frame_at(saved.duration())) == _values(first), "the opening rewinds the entire run from death to spawn")
	Input.action_press(&"rewind")
	level._step(level._sample_input(ActorStep.DT))
	level._process(ActorStep.DT)
	Input.action_release(&"rewind")
	expect(not actor.sim_downed and level._intro.frames.size() > saved.frames.size(),
			"rewinding out of death resumes the same run recording")
	expect(_values(hit) == original, "later simulation and drawing preserve every field of the published frame")
	expect(_values(saved.frames[hit_index]) == original, "the disk recording restores the complete frame and wall mask")
	actor.force_down()
	level._step(ActorInput.neutral())
	Input.action_press(&"R")
	level._process(ActorStep.DT)
	var opening := level.get_node("PreviousRun") as MatchView
	var retry_end := RunIntro.load_pending(path).frames[-1]
	expect(not level.is_physics_processing() and retry_end.time > down.time and retry_end.post.desat == 1.0
			and opening.camera.position == retry_end.camera, "R on the death frame starts the next run with that exact frame")
	var skip := InputEventKey.new()
	skip.physical_keycode = KEY_SPACE
	skip.pressed = true
	stage.push_input(skip)
	expect(level._skip_intro, "space skips the opening through the viewport input path")
	await _finish_opening(tree, level)
	expect(not level.player.sim_downed and not FileAccess.file_exists(path) and level._view.post.visible,
			"skipping consumes the previous recording and starts the new run")
	level.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	level.free()
	var next := SoloLevel.create(CyrmMap.create(Vector2i(40, 32)), Vector2i(10, 8), [WeaponType.RIFLE], path)
	stage.add_child(next)
	var support: int = cell.x + cell.y * map.size.x
	opening = next.get_node("PreviousRun") as MatchView
	expect(opening._canvas.lamps._supports.has(support) and next.world.tick == 0,
			"a fresh solo scene plays the previous map before its own simulation starts")
	await _finish_opening(tree, next)
	expect(not FileAccess.file_exists(path) and next.is_physics_processing() and not next.has_node("PreviousRun"),
			"the opening also finishes naturally and consumes the saved recording")
	next.free()
	var replay: MatchView = load("res://scenes/match_view.tscn").instantiate()
	replay.get_node("WorldViewport").world_2d = World2D.new()
	stage.add_child(replay)
	replay.mount(saved.map, WorldSpec.SOLO, true, false)
	replay.textures = saved.textures
	var stand: Node2D = replay._canvas.lamps._supports[cell.x + cell.y * map.size.x]
	var bindings := InputMap.action_get_events(&"F")
	InputMap.action_erase_events(&"F")
	var replacement := InputEventKey.new()
	replacement.physical_keycode = KEY_Z
	InputMap.action_add_event(&"F", replacement)
	var sound_rng := Sfx._rng.state
	replay.draw_frame(saved.frames[hit_index])
	expect(not stand.visible and replay.camera.position == hit.camera and replay.watch._face == hit.hud.watch
			and is_equal_approx(replay.post._mat.get_shader_parameter("hit_red"), hit.post.hit_red),
			"a fresh view directly displays the broken wall, exact camera, watch and hit flash")
	replay.draw_frame(saved.frames[0])
	expect(stand.visible and replay._canvas._drawing.reload.is_empty(), "seeking backwards restores the support and clears the reload ring")
	replay.draw_frame(saved.frames[hit_index])
	replay.draw_frame(saved.frames[hit_index])
	expect(Sfx._rng.state == sound_rng and replay._hud._vitals.state.hp == hit.hud.hp
			and replay._canvas._drawing.prompts == hit.world.prompts, "repeated drawing keeps HUD and keycaps and emits no shot audio")
	if not pixels.is_empty():
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		expect(stage.get_texture().get_image().get_data() == pixels, "live and fresh replay produce identical composited pixels")
	InputMap.action_erase_events(&"F")
	for binding in bindings: InputMap.action_add_event(&"F", binding)
	stage.free()
	var long_run := RunIntro.new(map, [])
	for i in RunIntro.MAX_FRAMES + 30:
		long_run.append(DrawFrame.new(i * ActorStep.DT, Vector2.ZERO, PackedByteArray(), Vector2.ZERO, {}, {}, {}))
	expect(long_run.frames.size() == RunIntro.MAX_FRAMES and long_run.frame_at(0).time == (RunIntro.MAX_FRAMES + 29) * ActorStep.DT
			and long_run.frame_at(3.0).time == 0.0, "thinning keeps both endpoints of a long run")

func _finish_opening(tree: SceneTree, level: SoloLevel) -> void:
	while not level.is_physics_processing():
		await tree.process_frame

func _values(frame: DrawFrame) -> PackedByteArray:
	return var_to_bytes([frame.time, frame.camera, frame.walls, frame.water, frame.world, frame.hud, frame.post])
