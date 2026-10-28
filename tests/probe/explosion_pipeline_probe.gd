extends Node

const Fx := preload("res://scenes/effects/tile_hit_fx.gd")

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	TileDefs.load_defs()
	GameParameters.MAP_WIDTH = 1024
	GameParameters.MAP_HEIGHT = 768
	var subgrid: Array[Array] = []
	var grid: Array[Array] = []
	for y in 48:
		var row: Array[int] = []
		row.resize(64)
		row.fill(19)
		subgrid.append(row)
	for y in 12:
		var row: Array[int] = []
		row.resize(16)
		row.fill(MazeGenerator.pack(19, 15))
		grid.append(row)
	TileDefs.load_terrain(grid, subgrid)
	var center := Vector2(512, 384)
	var cells := Explosion.destructible_subs(center, 350)
	assert(cells.size() > 100)
	TileDefs.apply_sub_hp(cells[0]["sub"], 0)
	var alive := Explosion.destructible_subs(center, 350)
	assert(alive.size() == cells.size() - 1)
	var space := SubViewport.new()
	space.world_2d = World2D.new()
	space.size = Vector2i(1024, 768)
	space.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(space)
	Fx.spawn_explosion(space, center, 350)
	assert(space.get_child_count() == 1)
	var particles: CPUParticles2D = space.get_child(0)
	assert(particles.amount == alive.size() * 10)
	assert(particles.emission_points.size() == alive.size())
	assert(particles.emission_colors.size() == alive.size())
	if OS.get_cmdline_user_args().has("--capture"):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := ProjectSettings.globalize_path("res://.test_logs/explosion_particles.png")
		assert(space.get_texture().get_image().save_png(path) == OK)
	var started := Time.get_ticks_usec()
	var authority := AuthorityWorld.new()
	space.add_child(authority)
	authority.set_physics_process(false)
	Settings.pvp_show_trajectories = true
	var grenade: BulletBase = preload("res://scenes/weapons/grenade_bullet.tscn").instantiate()
	grenade.authority_world = authority
	grenade.position = center
	space.add_child(grenade)
	grenade.set_physics_process(false)
	var children := space.get_child_count()
	var hp := TileDefs.sub_hp.duplicate()
	grenade._explode()
	assert(space.get_child_count() == children and grenade.get_child_count() == 2)
	assert(TileDefs.sub_hp != hp)
	print("EXPLOSION AUTHORITY cells=", alive.size(), " duration_ms=", (Time.get_ticks_usec() - started) / 1000.0)
	for cell: Dictionary in cells:
		TileDefs.apply_sub_hp(cell["sub"], 0)
	var count := space.get_child_count()
	Fx.spawn_explosion(space, center, 350)
	assert(space.get_child_count() == count)
	await get_tree().create_timer(1.0).timeout
	assert(not is_instance_valid(particles))
	space.free()
	print("EXPLOSION PIPELINE PROBE OK live cells, one emitter, unchanged particle density, authority damage without effects, particles finish")
	get_tree().quit()
