extends "res://tests/case.gd"

func run(tree: SceneTree) -> void:
	var node := world(tree)
	var level := _terrain
	_seam(node)
	_beam(level)
	_queries(level)
	var sub := Vector2i(8, 12)
	var adjacent := sub + Vector2i.RIGHT
	var original := level.get_hp(sub)
	var adjacent_hp := level.get_hp(adjacent)
	level.apply_hp(sub, original - 1, 1)
	expect(level.get_hp(sub) == original - 1, "partial terrain damage preserves exact HP")
	expect(level.flush_collisions() == 0, "HP-only damage does not rebuild geometry")
	level.rewind_enabled = true
	level.seal_rewind(0.0)
	level.apply_hp(sub, 0, 1)
	level.apply_hp(adjacent, 0, 1)
	level.seal_rewind(1.0)
	expect(level.flush_collisions() == 1, "two destroyed subcells queue their shared chunk once")
	level.rewind_between(0.0, 1.0)
	expect(level.get_hp(sub) == original - 1, "rewind restores residual HP, not full health")
	expect(level.get_hp(adjacent) == adjacent_hp, "rewind restores both subcells from the first saved macro state")
	level.reset()
	level.apply_values({sub: original - 2})
	expect(level.get_hp(sub) == original - 2,
			"an authority patch sets exact HP")
	level.apply_values({sub: original - 2})
	expect(level.flush_collisions() == 0 and level.get_hp(sub) == original - 2,
			"the absolute HP patch is idempotent and keeps the same geometry")
	_mirror_topology(tree)
	_mirrored_collision(tree)
	_beam_hole(tree)
	_proxy_same_frame(tree)
	_lifecycle(tree)
	_toroidal_sight(tree)
	_map_format()
	_respawn_format()
	_water_atlas()
	_water_depth(tree)

func _water_depth(tree: SceneTree) -> void:
	var cells := {}
	for y in [6, 7, 0, 1, 2]:
		cells[Vector2i(0, y)] = 21
	for y in 8:
		cells[Vector2i(1, y)] = 22
	world_with_walls(tree, 4, 8, cells)
	var terrain := _terrain
	expect(terrain.water_depth(Vector2(32, 2)) == 130.0
			and terrain.water_depth(Vector2(32, 514)) == 130.0,
			"water depth follows the same surface on both sides of the vertical seam")
	expect(terrain.water_depth(Vector2(32, 178)) == 306.0,
			"a deep column measures up through the water even beyond half the map height")
	expect(terrain.water_depth(Vector2(96, 2)) == INF and terrain.water_depth(Vector2(160, 2)) == -INF,
			"continuous water columns have no surface and dry columns have no depth")

# 测试地图只有最下面一行宏格是实心的；从上方向下打，命中那一行。
func _beam(terrain: Terrain) -> void:
	var x := terrain.columns / 2
	var wall_cell := Vector2i(x, terrain.rows - 1)
	var start := Vector2((x + 0.5) * Terrain.TILE_SIZE, (terrain.rows - 1.5) * Terrain.TILE_SIZE)
	var packed := terrain.value(wall_cell)
	expect(terrain.value(Vector2i(x, terrain.rows - 2)) == 0 and (packed & 15) == 15,
			"test map has a solid row under an empty one")
	var target := Vector2(start.x, start.y + Terrain.TILE_SIZE)
	var direction := (target - start).normalized()
	var beam := terrain.trace_beam(start, direction, 64.0, 0)
	expect((beam["points"] as PackedVector2Array).size() == 2 and (beam["points"] as PackedVector2Array)[0] == start,
			"beam trace starts at the muzzle and stops at the wall")
	expect(not (beam["contacts"] as Array).is_empty() and (beam["contacts"] as Array)[0] == wall_cell,
			"beam trace reports the solid cell it hits")
	var again := terrain.trace_beam(start, direction, 64.0, 0)
	expect(again["points"] == beam["points"] and again["contacts"] == beam["contacts"],
			"beam trace is deterministic")
	var empty_world := Terrain.new()
	var straight := empty_world.trace_beam(Vector2.ZERO, Vector2.RIGHT, 100.0, 0)
	expect((straight["points"] as PackedVector2Array).size() == 2 and (straight["contacts"] as Array).is_empty(),
			"beam trace on empty terrain is a straight segment")

# 接缝镜像：底部一行在顶边之外必须还有一份，但不再复制整张地图。
func _seam(node: Node2D) -> void:
	var terrain := _terrain
	var centers := terrain.body_shapes(0)
	expect(centers.has(Vector2(256.0, 224.0)), "bottom row is written into the world")
	expect(centers.has(Vector2(768.0, 224.0)), "seam mirror repeats the bottom row across the left edge")
	expect(centers.has(Vector2(-256.0, 224.0)), "a wall spanning both edges also repeats across the right edge")
	expect(not centers.has(Vector2(256.0, 480.0)),
			"the bottom edge does not repeat itself on the far side")
	var plain := Node.new()
	node.add_child(plain)
	expect(CollisionWorld.world_of(plain).space.is_valid(), "plain nodes resolve the world of their viewport")
	plain.free()

# 内部墙只有一份物理形状；贴边与角落只补必要副本。
func _mirror_topology(tree: SceneTree) -> void:
	var texture := wall_texture()
	world_with_walls(tree, 20, 20, {Vector2i(10, 10): texture, Vector2i(10, 19): texture,
			Vector2i(0, 5): texture, Vector2i(0, 0): texture})
	var terrain := _terrain
	var centers := {}
	var total := 0
	for key in terrain._chunks.size():
		var shapes := terrain.body_shapes(key)
		total += shapes.size()
		for center in shapes:
			centers[center] = true
	# 中部孤立墙：一份
	expect(centers.has(Vector2(672.0, 672.0)), "interior wall keeps its canonical shape")
	expect(not centers.has(Vector2(672.0 + 1280.0, 672.0)) and not centers.has(Vector2(672.0, 672.0 + 1280.0)),
			"interior wall is not duplicated into visual copies")
	# 贴底边：补一份到顶边之外
	expect(centers.has(Vector2(672.0, -32.0)), "bottom-edge wall repeats above the top edge")
	# 贴左边：补一份到右边之外
	expect(centers.has(Vector2(1312.0, 352.0)), "left-edge wall repeats across the right edge")
	# 角落：规范 + X + Y + 角落
	expect(centers.has(Vector2(32.0, 32.0)) and centers.has(Vector2(1312.0, 32.0))
			and centers.has(Vector2(32.0, 1312.0)) and centers.has(Vector2(1312.0, 1312.0)),
			"corner walls get the three necessary mirror copies")
	expect(total == 9, "four isolated walls produce 9 shapes instead of 36 (%d)" % total)

# 规范坐标的弹丸命中内部墙；同一位置在可视副本里没有碰撞。
func _mirrored_collision(tree: SceneTree) -> void:
	cleanup()
	var texture := wall_texture()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(10, 8): texture})
	var actor := player(parent)
	var sim := CombatSimulator.new(_terrain, parent, true)
	var pistol := WeaponRegistry.Type.PISTOL
	var source := actor.get_instance_id()
	var bullet := sim.spawn_projectile(1, pistol, source, Vector2(740, 544), Vector2.LEFT * 600.0)
	expect(bullet.advance_physics(0.1) == BulletBody.AdvanceResult.TERRAIN_HIT,
			"canonical projectile hits the interior wall")
	var ghost := sim.spawn_projectile(2, pistol, source, Vector2(740, 544), Vector2.LEFT * 600.0)
	ghost.global_position.x += 1024.0
	expect(ghost.advance_physics(0.1) == BulletBody.AdvanceResult.MOVED,
			"visual copies of interior walls carry no collision")
	cleanup()

	parent = world_with_walls(tree, 16, 16, {Vector2i(0, 8): texture, Vector2i(8, 0): texture})
	sim = CombatSimulator.new(_terrain, parent, true)
	actor = player(parent)
	source = actor.get_instance_id()
	var across := sim.spawn_projectile(1, pistol, source, Vector2(1010, 544), Vector2.RIGHT * 600.0)
	var vertical := sim.spawn_projectile(2, pistol, source, Vector2(544, 1010), Vector2.DOWN * 600.0)
	expect(across.advance_physics(0.1) == BulletBody.AdvanceResult.TERRAIN_HIT,
			"crossing the horizontal seam still hits the wall on the opposite edge")
	expect(vertical.advance_physics(0.1) == BulletBody.AdvanceResult.TERRAIN_HIT,
			"crossing the vertical seam still hits the wall on the opposite edge")
	cleanup()

	parent = world_with_walls(tree, 16, 16, {Vector2i(2, 4): texture})
	sim = CombatSimulator.new(_terrain, parent)
	actor = player(parent)
	source = actor.get_instance_id()
	var single := sim.spawn_projectile(1, pistol, source, Vector2(1010, 300), Vector2.RIGHT * 600.0)
	var steps: Array = []
	for i in 3:
		steps.append(single.advance_physics(0.1))
		expect(single.global_position.x >= 0.0 and single.global_position.x < 1024.0,
				"single-player projectile stays canonical, tick %d" % (i + 1))
	expect(steps == [BulletBody.AdvanceResult.MOVED, BulletBody.AdvanceResult.MOVED,
			BulletBody.AdvanceResult.TERRAIN_HIT],
			"a single-player projectile crosses the seam and hits an interior wall next tick")
	var ranged := sim.spawn_projectile(2, pistol, source, Vector2(1010, 300), Vector2.RIGHT * 600.0)
	ranged.max_range = 20.0
	expect(ranged.advance_physics(0.1) == BulletBody.AdvanceResult.RANGE_END
			and ranged.global_position.x >= 0.0 and ranged.global_position.x < 1024.0,
			"range end uses the same canonical exit")
	var shell := sim.spawn_projectile(3, WeaponRegistry.Type.GRENADE, source, Vector2(1010, 300), Vector2.RIGHT * 3000.0)
	sim.step_projectile(shell, 0.1)
	expect(shell.velocity_vec.x < 0.0 and is_equal_approx(shell.fuse_duration, 0.3)
			and shell.global_position.x >= 0.0 and shell.global_position.x < 1024.0,
			"a grenade bounces off the mirrored wall, starts its fuse and stays canonical")

func _lifecycle(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent)
	var space := parent.get_world_2d().space
	var world := CollisionWorld.acquire(actor)
	var first := _terrain
	var other := world_with_walls(tree, 6, 8, {})
	var second := _terrain
	expect(world.space == space and actor.terrain == first and CollisionWorld.acquire(other).terrain == second,
			"simultaneous maps bind their own physics spaces")
	expect(first.map_size == Vector2(1024, 1024) and second.map_size == Vector2(384, 512),
			"map dimensions are independent")
	_worlds.pop_back().free()
	expect(actor.terrain == first and not second.space_rid().is_valid(),
			"closing one map leaves the other adapter and actors bound")
	cleanup()
	expect(not CollisionWorld._by_space.has(space.get_id()),
			"case cleanup releases the remaining space adapter")

# 遮挡与爆炸候选都按环面最短位移处理，跨接缝的连线不会改判成穿过整张地图的直线。
func _toroidal_sight(tree: SceneTree) -> void:
	cleanup()
	var texture := wall_texture()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(8, 8): texture})
	var terrain := _terrain
	terrain.flush_collisions()
	var from := Vector2(900, 544)
	var to := Vector2(100, 544)
	expect(terrain.line_of_sight(from, to),
			"a seam-crossing sight line ignores walls in the middle of the map")
	expect(not terrain.line_of_sight(Vector2(900, 544), Vector2(500, 544)),
			"the same middle wall still blocks a straight line")
	cleanup()
	parent = world_with_walls(tree, 16, 16, {Vector2i(15, 8): texture})
	terrain = _terrain
	terrain.flush_collisions()
	expect(not terrain.line_of_sight(from, to), "a wall on the seam blocks the wrapping sight line")
	var victim := player(parent, 3)
	victim.global_position = Vector2(10, 544)
	victim.sync_collision_geometry()
	collider(victim, CollisionWorld.LAYER_TEAM_A)
	var sim := CombatSimulator.new(terrain, parent)
	expect(sim._blast_targets(Vector2(1010, 544), 128.0) == [victim],
			"an explosion at the seam finds the actor once across it")
	cleanup()
	world_from_solid(tree, 8, 6, func(sx: int, sy: int) -> bool: return sx == 2 and sy == 2)
	expect(not _terrain.line_of_sight(Vector2(496, 360), Vector2(48, 48)),
			"a wall beyond both seams still blocks the line of sight")

func _beam_hole(tree: SceneTree) -> void:
	var texture := wall_texture()
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(10, 8): texture, Vector2i(11, 8): texture})
	var terrain := _terrain
	terrain.flush_collisions()
	var world := CollisionWorld.acquire(parent)
	var down := [Vector2(704, 480), Vector2(704, 600)]
	expect(not world.ray_hit(down[0], down[1], CollisionWorld.LAYER_TERRAIN).is_empty(),
			"intact subcells block the ray before the hole exists")
	for y in range(32, 36):
		for x in range(41, 47): terrain.apply_hp(Vector2i(x, y), 0, 0)
	terrain.flush_collisions()
	expect(world.ray_hit(down[0], down[1], CollisionWorld.LAYER_TERRAIN).is_empty(),
			"a same-frame ray already sees the freshly destroyed subcells")
	var start := Vector2(704, 480)
	var beam := terrain.trace_beam(start, Vector2.DOWN, 160.0, 0)
	expect(beam["contacts"].is_empty() and beam["points"][-1] == Vector2(704, 640),
			"laser passes through a 96px hole while adjacent subcells remain alive")
	var wall := terrain.trace_beam(Vector2(648, 480), Vector2.DOWN, 160.0, 0)
	expect(not wall["contacts"].is_empty() and wall["points"][-1] == Vector2(648, 512),
			"laser still stops at surviving subcells beside the hole")
	for direction: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var clear := terrain.trace_beam(Vector2(256, 256), direction, 160.0, 0)
		expect(clear["points"].size() == 2 and clear["points"][-1] == Vector2(256, 256) + direction * 160.0,
				"unobstructed laser keeps its range at subcell boundaries, direction %s" % direction)
	var reflected := terrain.trace_beam(Vector2(648, 480), Vector2.DOWN, 96.0, 1)
	expect(reflected["points"] == PackedVector2Array([Vector2(648, 480), Vector2(648, 512), Vector2(648, 448)]),
			"laser reflection uses surviving subcells and preserves its total range")

# 同帧角色：位置 A→B→A、姿态与层变化后，引擎查询立即读到新状态。
func _proxy_same_frame(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent, 1)
	actor.global_position = Vector2(512, 512)
	actor.sync_collision_geometry()
	var mask := CollisionWorld.LAYER_TEAM_A
	collider(actor, mask)
	var world := CollisionWorld.acquire(actor)
	var circle := CircleShape2D.new()
	circle.radius = 24.0
	var probe := Transform2D(0.0, Vector2(512, 512))
	expect(not world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"the real actor body is queryable in the same frame")
	expect(not world.shape_overlaps(circle, probe, mask).is_empty(),
			"shape queries also see the same-frame body")
	var displaced := actor.global_transform
	displaced.origin.x += 200.0
	CollisionWorld.sync_body_pose(actor.get_rid(), displaced)
	expect(world.shape_overlaps(circle, probe, mask).is_empty(),
			"changing the RID pose moves the live collision body")
	actor.sync_collision_geometry()
	expect(not world.shape_overlaps(circle, probe, mask).is_empty(),
			"an unchanged scene pose still restores the live collision body")
	actor.global_position = Vector2(200, 512)
	actor.sync_collision_geometry()
	expect(world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"moving the body takes effect without waiting for a physics frame")
	expect(world.shape_overlaps(circle, probe, mask).is_empty(),
			"moving the body also clears same-frame shape queries")
	actor.global_position = Vector2(512, 512)
	actor.sync_collision_geometry()
	expect(not world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"moving the body back restores the original query result")
	# 姿态切换：镜像槽的形状立即换成对应姿态壳。
	actor.global_position = Vector2(10, 512)
	actor.sync_collision_geometry()
	var rid := actor.get_rid()
	var stand_shape := PhysicsServer2D.body_get_shape(rid, 0)
	expect(PhysicsServer2D.body_get_shape_count(rid) == 4
			and PhysicsServer2D.body_get_shape(rid, 1) == stand_shape,
			"one active hull and up to three mirrors share four slots")
	actor.is_squat = true
	actor.sync_collision_geometry()
	var squat_shape := PhysicsServer2D.body_get_shape(rid, 0)
	expect(squat_shape != stand_shape and PhysicsServer2D.body_get_shape(rid, 1) == squat_shape,
			"stance changes swap the base and mirror shapes in the same frame")
	actor.is_squat = false
	actor.sync_collision_geometry()
	actor.collision_layer = 0
	expect(world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"layer changes take effect immediately")
	expect(world.shape_overlaps(circle, probe, mask).is_empty(),
			"a cleared layer also leaves shape queries")
	actor.collision_layer = mask
	var stable := true
	for i in 32:
		actor.global_position = Vector2(500 + i, 512)
		actor.sync_collision_geometry()
		stable = stable and not world.ray_hit(Vector2(500 + i, 380), Vector2(500 + i, 700), mask).is_empty()
	expect(stable, "the body stays queryable across 32 in-frame updates")

func _queries(terrain: Terrain) -> void:
	var ts := float(Terrain.TILE_SIZE)
	var x := terrain.columns / 2
	var solid := Rect2(Vector2(x * ts, (terrain.rows - 1) * ts), Vector2(ts, ts))
	var empty := Rect2(Vector2(x * ts, 0.0), Vector2(ts, ts))
	expect(terrain.rect_overlaps(solid, ts, false), "rect overlap finds a solid cell")
	expect(not terrain.rect_overlaps(empty, ts, false), "rect overlap misses an empty cell")
	# 快照按 Array[Array] 返回：寻路接口可以直接接收，不需要隐藏拷贝，也不会在运行时被拒绝。
	var path := GridPathfinder.astar_path_nearest(terrain.get_grid_snapshot(), Vector2i(1, 1), Vector2i(1, 2))
	expect(not path.is_empty(), "grid snapshot feeds the typed pathfinder directly")

func _map_format() -> void:
	var path := "res://maps/newfactory.cyrm"
	var info := MapFormat.load_map(path)
	expect(not info["grid"].is_empty() and not info["descriptors"].is_empty(), "shipped v4 map loads macro cells and subcell descriptors")
	var received := MapFormat.parse_map(FileAccess.get_file_as_bytes(path), "network fixture")
	expect(is_same(received, info), "received bytes reuse the same parsed map as the file")
	var body := PackedByteArray([0, 0, 1, 1, 0, 0, 16, 0, 0, 1])
	body.resize(26)
	var bytes := _map_bytes(body)
	expect(MapFormatV4.parse(bytes)["ok"], "minimal valid v4 scene")
	var legacy := body.duplicate()
	legacy.encode_u32(5, (16 << 12) | (2 << 9) | (5 << 6) | (6 << 3) | 3)
	var colored := MapFormat.parse_map(_map_bytes(legacy), "legacy fixture")
	var desc: int = colored["descriptors"][0]
	expect(desc == 62833 and MapFormatV4.descriptor_texture(desc) == 15,
			"loading a legacy leaf composes its hue and preserves brightness, saturation and alpha")
	expect(TerrainAtlas.tint_color(Color8(82, 196, 144, 147), desc) == Color8(116, 235, 85, 42),
			"game tint agrees with the editor's RGBA bytes")
	var colored_terrain := Terrain.new(colored["grid"], colored["descriptors"])
	var level := Level0.new()
	level.terrain = colored_terrain
	level._view_margin = Vector2(16.0, 16.0)
	level._wall_rows = TerrainAtlas.descriptor_rows(colored_terrain.descriptors())
	var layer := TileMapLayer.new()
	level.wall_layer = layer
	layer.tile_set = TerrainAtlas.make_wall_tileset(level._wall_rows)
	var sub := Vector2i.ZERO
	var corner := Vector2i(4, 4)
	var atlas := TerrainAtlas.atlas_coords(level._wall_rows[desc], 0)
	level._paint_maze()
	expect(layer.get_used_cells().size() == 36 and layer.get_cell_atlas_coords(corner) == atlas,
			"initial paint adds only the one-subcell seam bands around the 4x4 map")
	colored_terrain.rewind_enabled = true
	colored_terrain.apply_hp(sub, 0, 1)
	colored_terrain.seal_rewind(1.0)
	level.flush_terrain_visuals()
	expect(layer.get_used_cells().size() == 32 and layer.get_cell_source_id(sub) == -1
			and layer.get_cell_source_id(corner) == -1, "destroying a corner tile erases its four visual cells")
	colored_terrain.rewind_between(0.0, 1.0)
	level.flush_terrain_visuals()
	expect(layer.get_used_cells().size() == 36 and layer.get_cell_atlas_coords(sub) == atlas
			and layer.get_cell_atlas_coords(corner) == atlas,
			"rewind restores the tinted tile and its seam copy")
	layer.free()
	level.free()
	for size in [3, 4, 8, 9, 10, 25]:
		expect(not MapFormatV4.parse(_map_bytes(body.slice(0, size)))["ok"], "truncated v4 block is rejected, length %d" % size)
	var invalid := body.duplicate()
	invalid[9] = 3
	expect(not MapFormatV4.parse(_map_bytes(invalid))["ok"], "invalid palette index width is rejected")
	invalid = body.duplicate()
	invalid[10] = 1
	expect(not MapFormatV4.parse(_map_bytes(invalid))["ok"], "out-of-range palette index is rejected")
	bytes[10] ^= 1
	expect(not MapFormatV4.parse(bytes)["ok"], "v4 CRC mismatch is rejected")

func _water_atlas() -> void:
	expect(TerrainAtlas.WATER_BODY_BRICK == 20 and TerrainAtlas.WATER_SURFACE_BRICK == 21,
			"water body and surface use distinct 0-based brick indices")
	TerrainAtlas.clear_cache()
	var body := TerrainAtlas.water_brick_image(64, TerrainAtlas.WATER_BODY_BRICK)
	var surface := TerrainAtlas.water_brick_image(64, TerrainAtlas.WATER_SURFACE_BRICK)
	expect(body != surface, "water body and surface images come from different bricks")
	expect(TerrainAtlas.water_brick_image(64, TerrainAtlas.WATER_BODY_BRICK) == body,
			"the neutral water brick is cached")
	var tint := MapFormatV4.NEUTRAL_TINT - 4
	var colored_body := TerrainAtlas.water_brick_image(64, TerrainAtlas.WATER_BODY_BRICK, tint)
	var colored_surface := TerrainAtlas.water_brick_image(64, TerrainAtlas.WATER_SURFACE_BRICK, tint)
	expect(colored_body.get_data() != body.get_data() and colored_surface.get_data() != surface.get_data(),
			"the same tint applies to both water textures")
	var tiles := TerrainAtlas.make_water_tileset(64, TerrainAtlas.WATER_BODY_BRICK, {tint: 0})
	expect(tiles != null and tiles.tile_size == Vector2i(64, 64), "the water tileset keeps its 64px cell size")


func _map_bytes(body: PackedByteArray) -> PackedByteArray:
	var bytes := PackedByteArray([67, 89, 82, 77, 4, 0])
	bytes.resize(20)
	bytes.encode_u32(6, body.size())
	bytes.encode_u32(10, MapFormatV4.crc32(body))
	bytes.encode_u16(14, 4)
	bytes.encode_u16(16, 4)
	bytes[18] = 2
	bytes.append_array(body)
	return bytes
# 出生点元数据：严格格式校验与两张内部地图的团队可开局性。
func _respawn_format() -> void:
	var demo := MapFormat.load_map("res://maps/demo.cyrm")
	var factory := MapFormat.load_map("res://maps/newfactory.cyrm")
	var demo_respawn: Dictionary = demo["spawns"].get("respawn", {})
	var factory_respawn: Dictionary = factory["spawns"].get("respawn", {})
	expect(demo_respawn.get(1, []).size() >= 5 and demo_respawn.get(2, []).size() >= 5,
			"demo.cyrm defines at least five respawn points per side")
	expect(factory_respawn.get(1, []).size() >= 5 and factory_respawn.get(2, []).size() >= 5,
			"newfactory.cyrm defines at least five respawn points per side")
	expect(MatchRules.validate_team_spawns("res://maps/demo.cyrm", demo) == "",
			"demo.cyrm 5v5 spawn validation passes")
	expect(MatchRules.validate_team_spawns("res://maps/newfactory.cyrm", factory) == "",
			"newfactory.cyrm 5v5 spawn validation passes")
	var meta := ["# respawn 1 2 3", "# respawn 3 1 2", "# respawn 1 a 2",
			"# respawn 1 1", "# respawn 1 200 200"]
	var parsed := MapFormat.parse_spawn_metadata(meta, Vector2i(10, 10))
	expect(parsed["respawn"][1] == [Vector2i(2, 3)], "a valid respawn line is stored per team")
	expect(parsed["respawn_errors"].size() == 4, "malformed respawn lines are reported")
	expect(str(parsed["respawn_errors"][0]).contains("第 2 行"),
			"the respawn error names its source line")
	expect(str(parsed["respawn_errors"][0]).contains("3"), "the respawn error includes the source content")
	parsed = MapFormat.parse_spawn_metadata(["# player 1 2", "# player2 4294967296 2",
			"# enemy jump_bird 10 2", "# enemy jump_bird x 2"], Vector2i(10, 10))
	expect(parsed["player"] == Vector2i(1, 2) and parsed["errors"].size() == 3,
			"bad coordinates and integer overflow are rejected before storing spawn cells")
	var dims := Vector2i(125, 75)
	var descriptors: PackedInt32Array = demo["descriptors"]
	expect(MatchRules.spawn_cell_problem(descriptors, dims, Vector2i(-1, 0)) != "",
			"an out-of-bounds respawn cell is rejected")
	expect(MatchRules.spawn_cell_problem(descriptors, dims, Vector2i(10, 10)) != "",
			"a cell without foot support is rejected")
	expect(MatchRules.spawn_cell_problem(descriptors, dims, demo_respawn[1][0]) == "",
			"a configured respawn cell passes clearance and support checks")
