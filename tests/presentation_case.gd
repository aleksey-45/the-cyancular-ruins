extends "res://tests/simulation_fixture.gd"

func run(tree: SceneTree) -> void:
	_actor_animation(tree)
	_bird_materials(tree)
	_damage_numbers(tree)
	_daylight(tree)
	_street_lamps(tree)
	if DisplayServer.get_name() != "headless":
		await _daylight_render(tree)
		await _lamp_render(tree)
		await _pickup_bindings(tree)
	_camera(tree)
	_result_panel(tree)
	cleanup()
	_detached_match()
	await _solo_scene(tree)
	await _loading_failure(tree)

func _street_lamps(tree: SceneTree) -> void:
	var map := CyrmMap.create(Vector2i(32, 16))
	var wood := CyrmMap.tile_value(19)
	CyrmMap.write_cells(map, CyrmMap.SCENE, [0, 2, wood, 20, 10, wood])
	map.points[5] = {"kind": "lamp", "cell": Vector2i(0, 1), "tone": "warm"}
	map.points[8] = {"kind": "lamp", "cell": Vector2i(20, 9), "tone": "cool"}
	var spec := WorldSpec.solo(map, Vector2i(4, 4), [WeaponType.RIFLE], 0)
	var simulation := MatchWorld.new(spec)
	var presenter := MatchPresenter.new(spec, simulation.terrain, 1, simulation.time_account(1))
	var intro := RunIntro.new(map, presenter.world.textures.items)
	var support := CyrmMap.lamp_support(Vector2i(0, 1), map.size)
	var view: MatchView = load("res://scenes/match_view.tscn").instantiate()
	tree.root.add_child(view)
	view.mount(map, WorldSpec.SOLO, true, false)
	view.textures = intro.textures
	var canvas := view._canvas
	for minute: float in [Daylight.NOON, 0.0]:
		if minute == 0.0:
			simulation.terrain.apply_at(simulation.terrain.version, {simulation.terrain.sub_position(support): 0})
		presenter.preview_minute = minute
		presenter.accept({"current": simulation.sample()})
		intro.append(presenter.advance(0.1, 0.1, 1.0, 0.0))
	simulation.close()
	var lamps := canvas.lamps
	var stand: Node2D = lamps._supports[support]
	var bulbs: Array[Vector2] = []
	for light: PointLight2D in stand.get_children():
		bulbs.append(light.position)
	expect(lamps.radius == 128 and bulbs.has(Vector2(8, -32)) and bulbs.has(Vector2(520, 224)),
			"small toroidal maps cap the radius and carry housing and bulb across both seams")
	var corner := Rect2(0, 0, 32, 48)
	canvas.set_daylight(Daylight.NOON)
	expect(lamps.lit_count(corner) == 0 and not stand.get_child(0).enabled, "noon leaves the housing visible with its light off")
	canvas.set_daylight(0)
	expect(lamps.lit_count(corner) == 1 and lamps.lit_count(Rect2(480, 232, 25, 16)) == 1,
			"each edge receives one light even with the bulb outside the view")
	var light: PointLight2D = stand.get_child(0)
	expect(light.color == StreetLamps.COLORS.warm and light.height == 32 and is_equal_approx(light.energy, 0.9),
			"midnight uses the warm lamp's full energy at the authored height")
	canvas.set_daylight(350)
	expect(lamps.night > 0 and lamps.night < 1, "the filament and light fade continuously at dawn")
	var crowd := WorldDrawing.new(WorldDrawing.Textures.new())
	crowd.data.actors = 15
	crowd.data.minute = 0.0
	canvas.draw_world(crowd.data, [])
	expect(canvas._split_player_batches, "lit street lamps share the per-item light budget with eye lights")
	crowd.data.minute = Daylight.NOON
	canvas.draw_world(crowd.data, [])
	expect(not canvas._split_player_batches, "unlit lamps do not split a 15-player batch")
	view.draw_frame(intro.frames[1])
	expect(not stand.visible and lamps.lit_count(corner) == 0, "the first captured frame can start with a destroyed support")
	view.draw_frame(intro.frames[0])
	expect(stand.visible and not light.enabled, "rewinding restores the fixture under the recorded daylight")
	view.draw_frame(intro.frames[1])
	canvas.set_daylight(0.0)
	expect(not stand.visible and lamps._supports[CyrmMap.lamp_support(Vector2i(20, 9), map.size)].visible,
			"a live terrain patch hides only its own stand, including every periodic copy")
	view.draw_frame(intro.frames[0])
	canvas.set_daylight(0.0)
	expect(stand.visible and light.enabled, "the same support update restores the nighttime lamp on reset")
	view.free()

func _lamp_render(tree: SceneTree) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(220, 160)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(viewport)
	var map := CyrmMap.create(Vector2i(40, 24))
	for x in 20: map.layers[CyrmMap.SCENE][8 * 40 + x] = CyrmMap.tile_value(7)
	map.points[0] = {"kind": "lamp", "cell": Vector2i(4, 7), "tone": "warm"}
	var ground := TerrainView.new()
	viewport.add_child(ground)
	ground.install(map, Vector2.ZERO)
	var canvas := canvas_for(viewport)
	canvas.lamps.install(map)
	canvas.set_daylight(0.0)
	await RenderingServer.frame_post_draw
	var warm := viewport.get_texture().get_image()
	map.points[0].tone = "cool"
	canvas.lamps.install(map)
	await RenderingServer.frame_post_draw
	var cool := viewport.get_texture().get_image()
	canvas.lamps.set_support(8 * 40 + 4, false)
	await RenderingServer.frame_post_draw
	var off := viewport.get_texture().get_image()
	var base := off.get_pixel(88, 132)
	expect(warm.get_pixel(72, 64).r > 0.9 and cool.get_pixel(72, 64).b > cool.get_pixel(72, 64).r,
			"the unshaded filament takes the tone of the light")
	expect(warm.get_pixel(88, 132).r > base.r + 0.03 and cool.get_pixel(88, 132).b > base.b + 0.03
			and warm.get_pixel(88, 132).r > cool.get_pixel(88, 132).r, "both tones illuminate the actual normal-mapped tile layer")
	expect(warm.get_pixel(110, 80) == off.get_pixel(110, 80), "air retains the sky color inside the light radius")
	map.layers[CyrmMap.FIRST_BACKGROUND].fill(Color.SLATE_GRAY.to_rgba32())
	var view := MatchView.new()
	view._mount_backgrounds(viewport, map, Vector2.ZERO)
	view.free()
	await RenderingServer.frame_post_draw
	var background := viewport.get_texture().get_image()
	canvas.eye_light(Transform2D(0.0, Vector2.ONE * WorldCanvas.PLAYER_CONFIG.body_scale, 0.0, Vector2(88, 128)))
	await RenderingServer.frame_post_draw
	var eyes := viewport.get_texture().get_image()
	expect(eyes.get_pixel(88, 132).get_luminance() > background.get_pixel(88, 132).get_luminance() + 0.02,
			"the eye light illuminates nearby terrain")
	expect(background.get_pixel(88, 124) != off.get_pixel(88, 124) and eyes.get_pixel(88, 124) == background.get_pixel(88, 124),
			"the painted parallax background keeps its color inside the eye light")
	viewport.free()

func _bird_materials(tree: SceneTree) -> void:
	var canvas := canvas_for(tree.root)
	var image := EnemyType.get_type("black_bird").frames.get_frame_texture(&"sleep", 0) as AtlasTexture
	var surface := image.atlas as CanvasTexture
	var trails := AfterImageField.new()
	var drawing := WorldDrawing.new(WorldDrawing.Textures.new())
	for style in [WorldDrawing.Pass.NORMAL, WorldDrawing.Pass.MASK, WorldDrawing.Pass.GLOW]:
		drawing.sprite(surface, image.region, Transform2D.IDENTITY, Color.WHITE, style)
	trails.spawn(1, 0.0, image, Transform2D.IDENTITY, Color.WHITE, WorldDrawing.Pass.NORMAL, 1.0)
	trails.present(0.1, Vector2.ZERO, drawing, Vector2(320, 240))
	canvas.draw_world(drawing.data, drawing.textures.items)
	expect(canvas._textures[canvas._batches[0].rows[0][0]] == surface, "the bird body uses its lit surface")
	for i in range(1, 4):
		expect(canvas._textures[canvas._batches[i].rows[0][0]] == surface.diffuse_texture, "silhouette, glow and trail use the original bird art")
	canvas.free()

func _result_panel(tree: SceneTree) -> void:
	var hud := PvpHud.new()
	hud.mode = WorldSpec.ROYALE
	tree.root.add_child(hud)
	var host := arena(hud.mode, [1, 2], {}, RoomOptions.normalized(hud.mode, {}))
	var world := host.world
	var score := RoundProjection.new(world.spec, 1)
	var names := {1: "A", 2: "B"}
	world.rules.phase = MatchRules.Phase.COUNTDOWN
	world.rules.round_timer = 3.0
	var sample := world.capture()
	sample.grace = {}
	expect(score.advance(sample, names, 0.0).title == "3" and score.advance({}, names, 1.1).title == "2",
			"the countdown advances between snapshots")
	sample.tick += 1
	expect(score.advance(sample, names, 0.0).title == "2", "a later snapshot cannot restart an active countdown")
	sample.tick += 1
	sample.rules[MatchRules.State.PHASE] = MatchRules.Phase.MATCH_OVER
	hud.display(score.advance(sample, names, 0.0))
	expect(hud._result.visible and not hud._broadcast.visible and hud._result_subtitle.visible
			and hud._result_subtitle.text == "平局", "only the result panel shows the final outcome")
	var returns: Array = []
	hud.return_requested.connect(func() -> void: returns.append(true))
	hud._return_button.pressed.emit()
	hud._request_return()
	expect(returns.size() == 1 and hud._return_button.disabled, "a confirmed player waits for the room without a second request")
	hud.show_connected(42)
	hud._request_return()
	expect(returns.size() == 2 and hud._ping.text == "42ms", "a reconnected player can confirm the return again")
	hud.free()
	world.close()

func _loading_failure(tree: SceneTree) -> void:
	await SceneTransition.change_with_builder(tree, func() -> Node: return null, "载入中")
	var screen := LoadingScreen.find(tree)
	var back: Button = screen.get_node("%Back")
	back.pressed.emit()
	expect(back.visible and screen.is_queued_for_deletion(), "the loading scene's Back button dismisses a failed transition")
	await tree.process_frame

func _detached_match() -> void:
	var map := CyrmMap.load_file("res://maps/demo.cyrm")
	var sim := CombatSimulator.new(Terrain.new(map), RandomNumberGenerator.new())
	sim.time_field = WorldTime.new(1)
	var actor := sim.add_player(1)
	actor.spawn_at(SpawnPicker.single_spawn(map))
	actor.weapons.set_initial_inventory([WeaponType.RIFLE])
	var enemies: Array = map.points.values().filter(func(p: Dictionary) -> bool: return p.kind == "enemy")
	for entry: Dictionary in enemies:
		sim.add_enemy(entry["type"], actor, CyrmMap.world_position(entry.cell))
	var slots: Array[int] = []
	for enemy in sim.enemies:
		slots.append(enemy.slot)
	sim.step({actor.role: _attack(ActorInput.BIT_ATTACK, ActorInput.BIT_ATTACK)})
	expect(sim.tick == 1 and sim.enemies.size() == enemies.size() and slots == range(slots.size()),
			"demo builds and steps every enemy in map order without a viewport")
	var hulls := sim.terrain.physics.shape_overlaps(CollisionWorld.rectangle(Vector2.ONE), actor.transform, CombatProfiles.Layer.TEAM_A)
	expect(hulls.size() == 1 and hulls[0]["collider"] == actor, "a detached player's RID resolves to its model")
	expect(sim.projectiles.size() == 1, "a detached match resolves player input and spawns a real projectile")
	sim.close()
	expect(not actor.rid.is_valid() and sim.players.is_empty() and sim.enemies.is_empty() and sim.projectiles.is_empty(),
			"closing a detached match releases all combat bodies")

func _solo_scene(tree: SceneTree) -> void:
	var map := CyrmMap.load_file("res://maps/newfactory.cyrm")
	var level := SoloLevel.create(map, SpawnPicker.single_spawn(map), [WeaponType.RIFLE], "")
	tree.root.add_child(level)
	var game := level.session.world
	var sim := game.combat
	var enemy_count: int = map.points.values().filter(func(p: Dictionary) -> bool: return p.kind == "enemy").size()
	expect(sim.enemies.size() == enemy_count and enemy_count > 0, "the solo match owns the map's enemies")
	var viewport := level.get_node("View/WorldViewport")
	var nodes := viewport.get_child_count()
	expect(viewport.get_children() == [level._view.camera, level._view.terrain_view, level._view._canvas],
			"only the camera and world graphics are mounted under the viewport")
	await tree.physics_frame
	Input.action_press(&"attack")
	await tree.physics_frame
	Input.action_release(&"attack")
	expect(sim.projectiles.size() == 1 and viewport.get_child_count() == nodes,
			"firing through the solo input creates a projectile without adding a node")
	if sim.projectiles.size() == 1:
		var bullet: BulletBody = sim.projectiles.values()[0]
		var first_step := bullet.traveled
		expect(first_step > 0.0, "a new projectile moves on the firing tick")
		await tree.physics_frame
		expect(bullet.traveled > first_step, "the following tick continues the same projectile")
	var tick := sim.tick
	var feedback := level._presenter.feedback
	var effect_time := feedback.now
	var daylight_time := game.world_time.elapsed
	level._view.pause.set_open(true)
	await tree.process_frame
	await tree.process_frame
	expect(sim.tick == tick and game.world_time.elapsed == daylight_time and feedback.now > effect_time,
			"pause stops simulation and daylight while the scene tree advances HUD feedback")
	level._view.pause.set_open(false)
	await tree.physics_frame
	await tree.physics_frame
	expect(sim.tick > tick, "closing the pause menu resumes simulation")
	for i in 6:
		await tree.physics_frame
	var before_rewind := sim.tick
	var balance := game.world_time.account.balance
	Input.action_press(&"rewind")
	await tree.physics_frame
	var restored := sim.tick
	expect(game.world_time.is_rewinding() and restored < before_rewind and game.world_time.account.balance < balance,
			"holding rewind in the actual match spends grains and restores an earlier combat tick")
	Input.action_release(&"rewind")
	await tree.physics_frame
	expect(not game.world_time.is_rewinding() and sim.tick == restored + 1,
			"releasing rewind runs the very next combat tick on the new branch")
	var old_drop: WeaponPickup = sim.ground.items.values()[0]
	var old_enemy := sim.enemies[0]
	level.player.force_down()
	level._step(ActorInput.neutral())
	Input.action_press(&"R")
	level._process(ActorStep.DT)
	await tree.physics_frame
	expect(not old_drop.rid.is_valid() and not old_enemy.rid.is_valid() and sim.enemies.size() == enemy_count
			and sim.enemies[0] != old_enemy
			and sim.projectiles.is_empty(), "restart replaces the roster and releases the old bodies on the next fixed step")
	level.free()

func _actor_animation(tree: SceneTree) -> void:
	var parent := world(tree)
	var actor := player(parent)
	var display := _display(parent, actor)
	var id := actor.role
	var pose := func(part: int) -> Transform2D:
		_draw_actor(display, actor)
		var row: Array = display.drawing.sprites[0 if part == 0 else -1]
		return row[2]

	var foot := actor.collision_rect().end.y - actor.position.y
	_place(actor, Vector2(160, 192 - foot - 8))
	actor.velocity.y = 900.0
	_draw_actor(display, actor)
	ActorStep.step(actor, NEUTRAL_INPUT)
	var hull := actor.collision_rect()
	var scale: Vector2 = pose.call(0).get_scale()
	expect(actor._grounded and scale.x > 2.6 and scale.y < 2.4 and actor.collision_rect() == hull,
			"a real landing squashes the drawn body while keeping its collision shape")
	display._frame.now = 0.3
	ActorStep.step(actor, NEUTRAL_INPUT)
	scale = pose.call(0).get_scale()
	expect(scale.distance_to(Vector2(2.5, 2.5)) < 0.003,
			"resting on the floor lets the landing pulse decay")
	var jump := ActorInput.BIT_UP
	display._world.motion(id, &"land", display._frame.now, 900.0)
	display._frame.now += ActorStep.DT
	ActorStep.step(actor, _attack(jump, jump))
	scale = pose.call(0).get_scale()
	expect(scale.x < 2.45 and scale.y > 2.55, "a jump directly after landing still stretches the drawn body")
	display._world.motion(-1, &"jump", 0.0)
	var bird_scale: Vector2 = display._world._squash[-1].sample(0.0, 0.0)
	expect(is_equal_approx(bird_scale.y, 1.0 + ECFG.squash.amount * ECFG.squash.jump),
			"a bird's first jump cue uses the enemy squash settings")

	actor.state = Player.MOVE
	var at_rest: Transform2D = pose.call(1)
	display._frame.now += 0.125
	var walking: Transform2D = pose.call(1)
	expect(absf(walking.origin.y - at_rest.origin.y) > 2.0, "the held gun bobs with the walk cycle")
	actor.state = Player.STAND
	var ready: Transform2D = pose.call(1)
	display._world.fire(id, actor.equipped.type_id, display._frame.now)
	var recoil: Transform2D = pose.call(1)
	expect(recoil.origin.x < ready.origin.x - 1.0, "the fired gun kicks back along its aim axis")
	display._frame.now += 0.1
	expect(pose.call(1).is_equal_approx(ready), "recoil returns to the aiming pose")
	actor.equipped.reload_left = float(actor.equipped.definition["reload"]) * 0.5
	var reload: Transform2D = pose.call(1)
	expect(absf(reload.get_rotation() - ready.get_rotation()) > 0.5 and reload.origin.y > ready.origin.y,
			"the held gun tilts and drops during reload")
	var lowest_drop := actor.position + Vector2.DOWN * CFG.weapon_pickup_radius
	display._frame.pickups.append([actor.equipped.type_id, lowest_drop, true])
	var drawing := display._world.build(display._frame)
	var key: Vector2 = drawing.prompts[0][0]
	var ring: Vector2 = drawing.reload[0]
	expect(key.y + PickupPrompt.BOX.y * 0.5 < ring.y - ReloadRing.RADIUS - ReloadRing.WIDTH * 0.5,
			"even the lowest reachable pickup leaves the whole reload ring visible")
	display.free()
	cleanup()

func _damage_numbers(tree: SceneTree) -> void:
	var parent := world(tree)
	var shooter := player(parent)
	var sim := parent.combat
	var bird := sim.add_enemy("jump_bird", shooter, Vector2.ZERO)
	var view := WorldView.new(parent.terrain.map_size)
	var spec := WorldSpec.solo(parent.document, Vector2i.ZERO, [WeaponType.RIFLE], 0)
	var presenter := MatchPresenter.new(spec, parent.terrain, shooter.role, null)
	var frame := presenter.frame
	frame.begin(0.0, shooter.position)
	presenter._sample_enemies(sim.sample_enemies(), false, false)
	var lethal_damage := bird.hp
	sim.resolve_hit(shooter, bird, CombatProfiles.DIRECT, bird.position, lethal_damage, 0.0)
	frame.begin(0.0, shooter.position)
	presenter._sample_enemies(sim.sample_enemies(), false, false)
	for cue: Array in frame.cues:
		if cue[0] == "number":
			view.hit(cue[1], cue[2], cue[3], cue[4])
	var labels: Array = view.build(frame).labels[1]
	expect(bird.is_dead and labels.size() == 1 and labels[0][0] == str(lethal_damage),
			"the hit that kills an enemy still produces a damage number")
	sim.resolve_hit(shooter, bird, CombatProfiles.DIRECT, bird.position, 1, 0.0)
	frame.now = 1.0
	labels = view.build(frame).labels[1]
	expect(labels.is_empty(), "hitting an enemy that is already dead produces no damage number")
	cleanup()

func _daylight(tree: SceneTree) -> void:
	var sky := Daylight.new()
	for sample in [[0, "2f3643"], [280, "8d779f"], [325, "b38aa3"], [360, "c39da7"],
			[720, "aad9ea"], [1080, "c89475"], [1440, "2f3643"]]:
		var light := sky.set_minute(sample[0])
		expect(light == sky.color and sky.color.to_html(false) == sample[1],
				"the sky color also lights the world at minute %d" % sample[0])
	var dawn := sky.set_minute(360)
	var next := sky.set_minute(365)
	expect(sky.set_minute(362.5).is_equal_approx(dawn.lerp(next, 0.5)), "light changes smoothly between swatches")
	sky.free()
	var parent := world(tree)
	var combat := parent.combat
	var actor := player(parent)
	var field := WorldTime.new(1)
	combat.time_field = field
	expect(Daylight.time_text(Daylight.minute_at(0.0)) == "06:00" and Daylight.minute_at(120.0) == 360.0,
			"a full daylight cycle returns to dawn after 120 seconds")
	field.elapsed = 89.75
	field.advance(combat, {actor.role: NEUTRAL_INPUT}, 1)
	_record_time(combat, actor)
	var before := field.elapsed
	for at in range(2, 17):
		field.advance(combat, {actor.role: _attack(ActorInput.BIT_HASTE, 0)}, at)
	expect(is_equal_approx(field.elapsed, before + 0.5) and Daylight.time_text(Daylight.minute_at(field.elapsed)).begins_with("00:"),
			"haste carries the sky and clock through midnight at player speed")
	field.rewind(combat, actor, 1.0)
	expect(field.elapsed == before and Daylight.time_text(Daylight.minute_at(field.elapsed)).begins_with("23:"),
			"rewinding a hasted interval restores the earlier time of day")
	field.advance(combat, {actor.role: NEUTRAL_INPUT}, 18)
	expect(is_equal_approx(field.elapsed, before + ActorStep.DT), "daylight resumes from the restored time")
	cleanup()

func _daylight_render(tree: SceneTree) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(96, 72)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(viewport)
	var canvas := canvas_for(viewport)
	var drawing := WorldDrawing.new(WorldDrawing.Textures.new())
	drawing.rect(Rect2(4, 4, 16, 16), Color.WHITE, -1, false)
	drawing.rect(Rect2(24, 4, 16, 16), Color.WHITE)
	drawing.rect(Rect2(64, 4, 16, 16), Color(1, 0, 0, 0.5), -1, false)
	drawing.rect(Rect2(4, 46, 88, 12), Color.GRAY, -1, false)
	drawing.rect(Rect2(42, 33, 12, 27), Color.BLACK, -1, false)
	canvas.draw_world(drawing.data, drawing.textures.items)
	canvas.set_daylight(Daylight.NOON)
	await RenderingServer.frame_post_draw
	var noon := viewport.get_texture().get_image()
	canvas.set_daylight(0.0)
	await RenderingServer.frame_post_draw
	var night := viewport.get_texture().get_image()
	var sky := night.get_pixel(60, 36)
	expect(sky.b > 0.12 and noon.get_pixel(60, 36).b > sky.b + 0.4, "empty space shows the night and day sky")
	expect(noon.get_pixel(60, 2).r > noon.get_pixel(60, 68).r + 0.12
			and noon.get_pixel(48, 17) == noon.get_pixel(60, 17)
			and night.get_pixel(48, 17) == night.get_pixel(60, 17),
			"the day and night sky grade vertically and stay even across each row")
	var glass := night.get_pixel(70, 12)
	var air := night.get_pixel(84, 12)
	var white := night.get_pixel(12, 12)
	expect(absf(glass.r - (air.r + white.r) * 0.5) < 0.02 and absf(glass.b - air.b * 0.5) < 0.02,
			"translucent paint blends with the night sky at its authored opacity")
	expect(night.get_pixel(12, 12).r < 0.6 and night.get_pixel(32, 12).r > 0.95,
			"night shades the world while combat cues keep their color")
	canvas._directional.enabled = false
	for minute in [280, 325]:
		canvas.set_daylight(minute)
		await RenderingServer.frame_post_draw
		var dawn := viewport.get_texture().get_image()
		expect(dawn.get_pixel(12, 12) == dawn.get_pixel(60, 0),
				"white terrain follows the brightening sky at %s" % Daylight.time_text(minute))
	canvas._directional.enabled = true
	for hour in [9, 15]:
		canvas.set_daylight(hour * 60.0)
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		expect(image.get_pixel(15, 30) == image.get_pixel(80, 30),
				"the sky is even across the row at %02d:00" % hour)
		var ground := image.get_pixel(10, 52)
		expect(image.get_pixel(41, 52) == ground and image.get_pixel(54, 52) == ground,
				"nearby geometry casts no shadow on either side at %02d:00" % hour)
	await _player_lighting_render(viewport, canvas)
	await _weapon_highlight(viewport, canvas)
	viewport.free()

func _weapon_highlight(viewport: SubViewport, canvas: WorldCanvas) -> void:
	viewport.size = Vector2i(192, 64)
	var metal := WorldView.WEAPONS
	var matte := metal.duplicate() as CanvasTexture
	matte.specular_color = Color.BLACK
	var region: Rect2 = WeaponRegistry.definition(8)["region"]
	var drawing := WorldDrawing.new(WorldDrawing.Textures.new())
	drawing.data.minute = 540.0
	drawing.sprite(matte, region, Transform2D(0.0, Vector2(48, 32)))
	drawing.sprite(metal, region, Transform2D(0.0, Vector2(144, 32)))
	canvas.draw_world(drawing.data, drawing.textures.items)
	canvas._directional.energy = 0.88
	canvas._directional.height = 0.47
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var highlights := 0
	for y in range(18, 46):
		for x in range(10, 86):
			if image.get_pixel(x + 96, y).get_luminance() > image.get_pixel(x, y).get_luminance() + 0.008:
				highlights += 1
	expect(highlights > 5, "the authored weapon reflects light through its native specular map")

func _player_lighting_render(viewport: SubViewport, canvas: WorldCanvas) -> void:
	viewport.size = Vector2i(176, 132)
	var view := WorldView.new(Vector2(viewport.size))
	var frame := MatchFrame.new()
	var actor := MatchFrame.Pose.new()
	actor.anchor = Vector2(60, 60)
	frame.actors.append(actor)
	var render := func(minute: float, eyes := true) -> Image:
		frame.day_minute = minute
		canvas.draw_world(view.build(frame), view.textures.items)
		for light in canvas._eye_lights:
			light.enabled = eyes
		await RenderingServer.frame_post_draw
		return viewport.get_texture().get_image()
	var morning: Image = await render.call(9 * 60, false)
	var afternoon: Image = await render.call(15 * 60, false)
	expect(morning.get_pixel(26, 53).b > morning.get_pixel(86, 53).b
			and afternoon.get_pixel(26, 53).b < afternoon.get_pixel(86, 53).b,
			"Godot lights the player normals from the current sun direction")
	var morning_lit: Image = await render.call(9 * 60)
	expect(morning_lit.get_pixel(68, 51).get_luminance() - morning.get_pixel(68, 51).get_luminance() < 0.02,
			"eye lighting adds little to the face in the morning")
	var night_base: Image = await render.call(0.0, false)
	var night: Image = await render.call(0.0)
	expect(night.get_pixel(61, 36).r > night_base.get_pixel(61, 36).r + 0.4
			and night.get_pixel(78, 36).r > night_base.get_pixel(78, 36).r + 0.4,
			"one point light illuminates both eyes")
	var other := MatchFrame.Pose.new()
	other.id = 2
	other.anchor = actor.anchor
	frame.actors.append(other)
	var overlap: Image = await render.call(0.0, false)
	var light := canvas._eye_lights[0]
	light.enabled = true
	await RenderingServer.frame_post_draw
	var overlap_lit := viewport.get_texture().get_image()
	expect(overlap_lit.get_pixel(61, 36).r > overlap.get_pixel(61, 36).r
			and canvas._batch_count == 1 and canvas._batches[0].rows.size() == 2,
			"adjacent player bodies share a batch and receive each other's eye light")
	frame.actors.pop_back()
	frame.now = 0.5
	actor.facing = -1
	await render.call(0.0)
	expect(light.position.is_equal_approx(Vector2(50, 40)) and not canvas._eye_lights[1].visible,
			"the lamp follows the mirrored frame and the unused lamp is hidden")
	actor.downed = true
	await render.call(0.0)
	expect(light.position.is_equal_approx(Vector2(85, 72)), "the eye light rotates with the downed pose")
	viewport.size = Vector2i(1970, 180)
	frame.now = 1.0
	frame.actors.clear()
	for index in RoomOptions.ROYALE_PLAYERS.y:
		var pose := MatchFrame.Pose.new()
		pose.id = 100 + index
		pose.anchor = Vector2(60 + index * 120, 82)
		frame.actors.append(pose)
	var crowd: Image = await render.call(0.0)
	expect(frame.actors.all(func(pose: MatchFrame.Pose) -> bool:
		return crowd.get_pixel(int(pose.anchor.x) + 1, 58).r > 0.8),
			"separated players keep their eye lights in a full 16-player match")

## 在同一个测试场景中验证摄像机的初始偏移、目标跟随、抖动和跨地图边缘的行为。
func _camera(tree: SceneTree) -> void:
	cleanup()
	var parent := world(tree)
	var cam := MatchCamera.new()
	var target := Node2D.new()
	parent.add_child(target)
	target.position = Vector2(300, 200)
	cam.advance(1.0 / 60.0, target.position, parent.terrain.map_size)
	var bias := Vector2(0.0, CFG.cam_y_bias)
	expect(cam.base_position.is_equal_approx(Vector2(300, 200) + bias),
			"the first bind initializes the base position with the y bias")
	var leading := MatchCamera.new()
	leading.advance(ActorStep.DT, target.position, parent.terrain.map_size, CFG.move_speed * 0.5)
	expect(leading.base_position.is_equal_approx(target.position + bias + Vector2(50, 0)),
			"half running speed leads the player by fifty world pixels")
	leading = MatchCamera.new()
	leading.advance(ActorStep.DT, target.position, parent.terrain.map_size, -CFG.charge_velocity)
	expect(leading.base_position.is_equal_approx(target.position + bias + Vector2(-100, 0)),
			"a leftward dash caps the camera lead at one hundred world pixels")
	var before_stop := leading.base_position.x
	leading.advance(ActorStep.DT, target.position, parent.terrain.map_size, 0.0)
	expect(leading.base_position.x > before_stop and leading.base_position.x < target.position.x,
			"stopping eases the camera back toward the player")
	# 先让目标在摄像机的跟随阈值以内移动，然后越过阈值。
	target.position += Vector2(CFG.cam_deadzone - 1.0, 0.0)
	cam.advance(1.0 / 60.0, target.position, parent.terrain.map_size)
	var settled: Vector2 = cam.base_position
	expect(settled.x < 301.0, "a target inside the deadzone does not move the camera")
	target.position += Vector2(200.0, 0.0)
	cam.advance(1.0 / 60.0, target.position, parent.terrain.map_size)
	var moved: Vector2 = cam.base_position
	expect(moved.x > settled.x + 1.0 and moved.x < target.position.x - 1.0,
			"a target outside the deadzone is followed with exponential smoothing")
	# 在一次强烈抖动中触发一次短而弱的抖动。画面位置等于跟随位置加上当前抖动偏移。
	cam.shake(30.0, 0.5)
	cam.shake(5.0, 0.1)
	expect(is_equal_approx(cam._shake_amt, 30.0) and cam._shake_time >= 0.49,
			"a weak shake cannot replace a stronger amplitude or a longer duration")
	cam.advance(1.0 / 60.0, target.position, parent.terrain.map_size)
	expect(cam.position.is_equal_approx(cam.base_position + cam._shake_offset),
			"the rendered position is base + shake offset")
	# 清除抖动后，将目标放到地图另一端，观察摄像机是否沿跨越边缘的较短方向跟随。
	cam._shake_amt = 0.0
	cam._shake_time = 0.0
	cam._shake_dur = 0.0
	cam._shake_offset = Vector2.ZERO
	target.position = Vector2(parent.terrain.map_size.x - 4.0, 200)
	cam.base_position = Vector2(4.0, 200 + CFG.cam_y_bias)
	cam.advance(1.0 / 60.0, target.position, parent.terrain.map_size)
	expect(cam.base_position.distance_to(target.position + bias) < 32.0,
			"the camera moves into the target's copy across the seam")
	cleanup()

func _pickup_bindings(tree: SceneTree) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(480, 100)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(viewport)
	var prompt := Node2D.new()
	var key := [""]
	prompt.draw.connect(func() -> void: PickupPrompt.paint(prompt, key[0]))
	prompt.position = Vector2(viewport.size) * 0.5
	viewport.add_child(prompt)
	var original := InputMap.action_get_events(&"F")
	var f := InputEventKey.new()
	f.physical_keycode = KEY_F
	var e := InputEventKey.new()
	e.physical_keycode = KEY_E
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	var images: Array[Image] = []
	for binding in [f, e, mouse, f]:
		InputMap.action_erase_events(&"F")
		InputMap.action_add_event(&"F", binding)
		key[0] = Settings.get_binding_names("F")
		prompt.queue_redraw()
		await RenderingServer.frame_post_draw
		images.append(viewport.get_texture().get_image())
	InputMap.action_erase_events(&"F")
	for binding in original: InputMap.action_add_event(&"F", binding)
	expect(images[0].get_data() != images[1].get_data() and images[0].get_data() == images[3].get_data(),
			"pickup keycap redraws the bound keyboard key and restores its original appearance")
	expect(images[2].get_used_rect().size.x > images[0].get_used_rect().size.x,
			"the pickup keycap expands for a mouse binding")
	viewport.free()
