extends "res://tests/case.gd"

class MeasuredTerrain extends Terrain:
	var wall_rebuilds := 0

	func _rebuild_walls(key: int, area: Rect2i) -> void:
		wall_rebuilds += 1
		super(key, area)

func run(tree: SceneTree) -> void:
	var node := world(tree)
	var level := _terrain
	_seam(node)
	_beam(level)
	_queries(level)
	_rewind_boundaries(level)
	var sub := Vector2i(8, 12)
	var adjacent := sub + Vector2i.RIGHT
	var original := level.get_hp(sub)
	var adjacent_hp := level.get_hp(adjacent)
	var before := level.apply_at(level.version, {sub: original - 1})
	expect(level.get_hp(sub) == original - 1, "partial terrain damage preserves exact HP")
	level.apply_at(before, {sub: 0, adjacent: 0})
	level.apply_at(before, {})
	expect(level.get_hp(sub) == original - 1, "rewind restores residual HP, not full health")
	expect(level.get_hp(adjacent) == adjacent_hp, "rewind restores both subcells from the first saved macro state")
	var replica := MeasuredTerrain.new(_document)
	var root := replica.version
	var scans := replica.wall_rebuilds
	replica.apply_at(root, {sub: 0, adjacent: 0})
	expect(replica.wall_rebuilds == scans + 1, "multiple occupied cells dirty their shared chunk once")
	replica.take_wall_changes()
	scans = replica.wall_rebuilds
	var cells := {sub: 0, adjacent: 0, adjacent + Vector2i.RIGHT: adjacent_hp - 1}
	var corrected := replica.apply_at(root, cells)
	expect(replica.wall_rebuilds == scans and replica.take_wall_changes().is_empty(),
			"matching occupancy and HP-only corrections skip wall rebuilds")
	expect(replica.changes_since(root) == cells and replica.apply_at(corrected, cells) == corrected,
			"the corrected batch records the base HP once and repeating it is a no-op")
	replica.apply_at(root, {})
	expect(replica.get_modified().is_empty(), "reading the delta leaves the corrected batch reversible")
	_mirror_topology(tree)
	_mirrored_collision(tree)
	_destruction_units(tree)
	_subcell_navigation()
	_beam_hole(tree)
	_proxy_same_frame(tree)
	_lifecycle(tree)
	_toroidal_sight(tree)
	_map_format()
	_respawn_format()
	_water_atlas()
	_water_depth(tree)

func _rewind_boundaries(level: Terrain) -> void:
	var sub := Vector2i(8, 12)
	var cell := Vector2i(2, 3)
	var initial := level.get_hp(sub)
	var root := level.version
	var first := level.apply_at(root, {sub: initial + 2})
	level.apply_at(first, {sub: initial - 1})
	level.apply_at(first, {})
	expect(level.get_hp(sub) == initial + 2, "undo returns to the previous version's exact terrain")
	level.apply_at(first, {sub: initial + 4})
	expect(level.get_hp(sub) == initial + 4, "a new commit follows the retained history")
	level.apply_at(root, {})
	expect(level.get_hp(sub) == initial, "undo crosses the new commit and the retained earlier history")
	level.reset()
	var adjacent := sub + Vector2i.RIGHT
	level.apply_at(level.version, {adjacent: initial - 2})
	level.damage_beam(sub, 1)
	expect(level.get_hp(sub) == initial - 1 and level.get_hp(adjacent) == initial - 3,
			"damage over a full tile subtracts from each subcell's current HP")
	level.reset()
	expect(level.get_hp(sub) == initial and level.get_hp(adjacent) == initial,
			"reset restores each subcell's material HP")

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

func _destruction_units(tree: SceneTree) -> void:
	var trunk := wall_texture()
	var leaf := wall_texture(true)
	world_with_walls(tree, 4, 4, {Vector2i.ZERO: trunk, Vector2i(3, 0): leaf})
	var terrain := _terrain
	var point := Vector2(256, 8)
	var hp := TileDefs.hit_points[trunk]
	var original := block_hp(terrain, Vector2i.ZERO)
	terrain.damage_impact(point, Vector2.LEFT, hp - 1)
	var damaged := {Vector2i.ZERO: 1, Vector2i.RIGHT: 1, Vector2i.DOWN: 1, Vector2i.ONE: 1}
	terrain.commit()
	expect(terrain.get_modified() == damaged,
			"a seam hit records residual HP for exactly the four subcells in the 32 px block")
	expect(terrain.damage_impact(Vector2(24, 0), Vector2.UP, 1) == 4, "destruction reports the subcells actually broken")
	expect(terrain.get_hp(Vector2i.ZERO) == 0 and terrain.get_hp(Vector2i.ONE) == 0
			and terrain.get_hp(Vector2i(2, 0)) == hp and terrain.get_hp(Vector2i(0, 2)) == hp,
			"another hit in the same block opens a hole and leaves the adjacent blocks intact")
	terrain.commit()
	var mask := CollisionWorld.LAYER_TERRAIN
	expect(terrain.physics.ray_hit(Vector2(8, -8), Vector2(8, 24), mask).is_empty()
			and not terrain.physics.ray_hit(Vector2(40, -8), Vector2(40, 24), mask).is_empty(),
			"rays pass through the new projectile hole and still hit its neighboring block")
	expect(terrain.line_of_sight(Vector2(8, -8), Vector2(8, 24))
			and not terrain.line_of_sight(Vector2(40, -8), Vector2(40, 24)),
			"a sight line wrapped at the seam sees the same opening and wall as the physical ray")
	terrain.apply_at(0, {})
	expect(block_hp(terrain, Vector2i.ZERO) == original, "rewind restores all four bullet-damaged subcells")

	var blast_center := Vector2(248, 8)
	var blast_radius := 12.0
	var leaf_hp := TileDefs.hit_points[leaf]
	terrain.damage_blast(blast_center, blast_radius, 8)
	expect(terrain.get_hp(Vector2i(15, 0)) == leaf_hp - 6
			and terrain.get_hp(Vector2i(14, 1)) == leaf_hp - 6
			and terrain.get_hp(Vector2i(13, 0)) == leaf_hp,
			"grenades apply the nearest subcell's damage only to its containing 32 px block")
	terrain.damage_impact(Vector2(248, 0), Vector2.UP, leaf_hp - 6)
	expect(terrain.get_hp(Vector2i(15, 0)) == 0 and terrain.get_hp(Vector2i(14, 1)) == 0
			and terrain.get_hp(Vector2i(13, 0)) == leaf_hp,
			"rounds and grenades accumulate damage on the same four subcells")

	var solid := 7
	var tiles := PackedInt32Array()
	tiles.resize(16)
	tiles.fill(CyrmMap.tile_value(solid))
	tiles[0] = CyrmMap.tile_value(trunk)
	tiles[1] = CyrmMap.tile_value(leaf)
	tiles[4] = 0
	var authored := CyrmMap.create(Vector2i(4, 4))
	authored.layers[CyrmMap.SCENE] = tiles
	var mixed := Terrain.new(authored)
	expect(mixed.damage_impact(Vector2(0, 8), Vector2.LEFT, leaf_hp) == 1
			and mixed.get_hp(Vector2i.ZERO) == hp - leaf_hp and mixed.get_hp(Vector2i.RIGHT) == 0
			and mixed.get_hp(Vector2i.DOWN) == 0 and mixed.get_hp(Vector2i.ONE) == TileDefs.hit_points[solid],
			"the hit subcell selects the block and each neighbor takes damage according to its own material")
	expect(mixed.damage_impact(Vector2(16, 24), Vector2.LEFT, 1) == 0
			and mixed.get_hp(Vector2i.ZERO) == hp - leaf_hp,
			"hitting an indestructible face leaves its vulnerable neighbors alone")

func _subcell_navigation() -> void:
	var map := CyrmMap.create(Vector2i(7, 5))
	var wall := CyrmMap.tile_value(19)
	for y in map.size.y: CyrmMap.write_cells(map, CyrmMap.SCENE, [2, y, wall])
	CyrmMap.write_cells(map, CyrmMap.SCENE, [3, 1, CyrmMap.tile_value(21), 6, 4, wall])
	var terrain := Terrain.new(map)
	var can_pass := func(at: Vector2i) -> bool: return not TileDefs.is_blocked(terrain.material_at(at))
	var start := Vector2i(1, 1)
	var goal := Vector2i(3, 1)
	var gap := Vector2i(2, 1)
	expect(not GridPathfinder.find_path(map.size, start, goal, can_pass).has(gap),
			"navigation avoids a single solid subcell")
	expect(terrain.water(terrain.cell_center(goal)) and not terrain.water(terrain.cell_center(gap)),
			"water and wall inside the same artwork tile have distinct gameplay materials")
	terrain.apply_at(terrain.version, {gap: 0})
	expect(GridPathfinder.find_path(map.size, start, goal, can_pass) == [gap, goal],
			"navigation uses a freshly opened subcell without rebuilding a coarse map")
	var corner := Vector2i(6, 4)
	terrain.damage_impact(terrain.cell_center(corner), Vector2.LEFT, 30)
	expect(terrain.get_hp(corner) == 0 and terrain.get_hp(Vector2i(2, 4)) == 30,
			"an odd-sized map clips the last damage block to its actual subcells")

## 光束的起点位于空子格内，下方紧邻一排有碰撞形状的墙体。
func _beam(terrain: Terrain) -> void:
	var x := terrain.columns / 2
	var wall_cell := Vector2i(x, terrain.rows - 4)
	var start := terrain.cell_center(wall_cell + Vector2i.UP)
	expect(terrain.material_at(wall_cell + Vector2i.UP) == 0 and terrain.material_at(wall_cell) == wall_texture(),
			"fixture has wall directly below an empty subcell")
	var target := terrain.cell_center(wall_cell)
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

## 底部墙体横贯地图。测试检查左右边缘外侧是否也有墙体碰撞形状。
func _seam(node: Node2D) -> void:
	var terrain := _terrain
	var centers := terrain.body_shapes(0)
	expect(centers.has(Vector2(256.0, 224.0)), "bottom row is written into the world")
	expect(centers.has(Vector2(768.0, 224.0)), "seam mirror repeats the bottom row across the left edge")
	expect(centers.has(Vector2(-256.0, 224.0)), "a wall spanning both edges also repeats across the right edge")
	expect(not centers.has(Vector2(256.0, 480.0)),
			"the bottom edge does not repeat itself on the far side")
	expect(terrain.physics.world.space == node.get_viewport().world_2d.space, "the viewport shares the map physics space")

## 在地图中央、边缘及角落各放置墙体，比较重复的碰撞形状与原墙体的相对位置。
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
	expect(centers.has(Vector2(672.0, 672.0)), "interior wall keeps its canonical shape")
	expect(not centers.has(Vector2(672.0 + 1280.0, 672.0)) and not centers.has(Vector2(672.0, 672.0 + 1280.0)),
			"interior wall is not duplicated into visual copies")
	expect(centers.has(Vector2(672.0, -32.0)), "bottom-edge wall repeats above the top edge")
	expect(centers.has(Vector2(1312.0, 352.0)), "left-edge wall repeats across the right edge")
	expect(centers.has(Vector2(32.0, 32.0)) and centers.has(Vector2(1312.0, 32.0))
			and centers.has(Vector2(32.0, 1312.0)) and centers.has(Vector2(1312.0, 1312.0)),
			"corner walls get the three necessary mirror copies")
	expect(total == 9, "four isolated walls produce 9 shapes instead of 36 (%d)" % total)

## 比较地图内外的墙体碰撞。地图内的墙可以挡住弹丸，地图外只会为边缘附近的墙添加对应的碰撞形状。
func _mirrored_collision(tree: SceneTree) -> void:
	cleanup()
	var texture := wall_texture()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(10, 8): texture})
	var actor := player(parent)
	var sim := parent.combat
	var pistol := WeaponType.PISTOL
	var bullet := sim.spawn_projectile(1, pistol, actor, Vector2(740, 544), Vector2.LEFT * 600.0)
	expect(bullet.advance_physics(0.1) == BulletBody.AdvanceResult.TERRAIN_HIT,
			"canonical projectile hits the interior wall")
	var ghost := sim.spawn_projectile(2, pistol, actor, Vector2(740, 544), Vector2.LEFT * 600.0)
	ghost.position.x += 1024.0
	expect(ghost.advance_physics(0.1) == BulletBody.AdvanceResult.MOVED,
			"visual copies of interior walls carry no collision")
	cleanup()

	parent = world_with_walls(tree, 16, 16, {Vector2i(0, 8): texture, Vector2i(8, 0): texture})
	sim = parent.combat
	actor = player(parent)
	var across := sim.spawn_projectile(1, pistol, actor, Vector2(1010, 544), Vector2.RIGHT * 600.0)
	var vertical := sim.spawn_projectile(2, pistol, actor, Vector2(544, 1010), Vector2.DOWN * 600.0)
	expect(across.advance_physics(0.1) == BulletBody.AdvanceResult.TERRAIN_HIT,
			"crossing the horizontal seam still hits the wall on the opposite edge")
	expect(vertical.advance_physics(0.1) == BulletBody.AdvanceResult.TERRAIN_HIT,
			"crossing the vertical seam still hits the wall on the opposite edge")
	cleanup()

	parent = world_with_walls(tree, 16, 16, {Vector2i(2, 4): texture})
	sim = parent.combat
	actor = player(parent)
	var single := sim.spawn_projectile(1, pistol, actor, Vector2(1010, 300), Vector2.RIGHT * 600.0)
	var steps: Array = []
	for i in 3:
		steps.append(single.advance_physics(0.1))
		expect(single.position.x >= 0.0 and single.position.x < 1024.0,
				"single-player projectile stays canonical, tick %d" % (i + 1))
	expect(steps == [BulletBody.AdvanceResult.MOVED, BulletBody.AdvanceResult.MOVED,
			BulletBody.AdvanceResult.TERRAIN_HIT],
			"a single-player projectile crosses the seam and hits an interior wall next tick")
	var ranged := sim.spawn_projectile(2, pistol, actor, Vector2(1010, 300), Vector2.RIGHT * 600.0)
	ranged.max_range = 20.0
	expect(ranged.advance_physics(0.1) == BulletBody.AdvanceResult.RANGE_END
			and ranged.position.x >= 0.0 and ranged.position.x < 1024.0,
			"range end uses the same canonical exit")
	var shell := sim.spawn_projectile(3, WeaponType.GRENADE, actor, Vector2(1010, 300), Vector2.RIGHT * 3000.0)
	sim.step_projectile(shell, 0.1)
	expect(shell.velocity.x < 0.0 and is_equal_approx(shell.fuse_duration, 0.3)
			and shell.position.x >= 0.0 and shell.position.x < 1024.0,
			"a grenade bounces off the mirrored wall, starts its fuse and stays canonical")

func _lifecycle(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent)
	var first := actor.terrain
	var other := world_with_walls(tree, 6, 8, {})
	var second_player := player(other)
	var second := second_player.terrain
	expect(first.physics.world.space != second.physics.world.space, "simultaneous matches own separate physics spaces")
	expect(first.map_size == Vector2(1024, 1024) and second.map_size == Vector2(384, 512), "map dimensions are independent")
	_worlds.pop_back().free()
	expect(not second_player.rid.is_valid() and actor.rid.is_valid(), "closing one match releases only its own actors")
	cleanup()
	expect(not actor.rid.is_valid(), "closing the other match releases its actors too")

## 从地图一端检测另一端的目标，验证视线和爆炸范围会考虑跨过地图边缘的路径。
func _toroidal_sight(tree: SceneTree) -> void:
	cleanup()
	var texture := wall_texture()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(8, 8): texture})
	var terrain := _terrain
	var from := Vector2(900, 544)
	var to := Vector2(100, 544)
	expect(terrain.line_of_sight(from, to),
			"a seam-crossing sight line ignores walls in the middle of the map")
	expect(not terrain.line_of_sight(Vector2(900, 544), Vector2(500, 544)),
			"the same middle wall still blocks a straight line")
	cleanup()
	parent = world_with_walls(tree, 16, 16, {Vector2i(15, 8): texture})
	terrain = _terrain
	expect(not terrain.line_of_sight(from, to), "a wall on the seam blocks the wrapping sight line")
	var victim := player(parent, 3)
	victim.position = Vector2(10, 544)
	victim.sync_collision_geometry()
	collider(victim, CollisionWorld.LAYER_TEAM_A)
	var sim := parent.combat
	sim.resolve_blast(Vector2(1010, 544), {"radius": 128.0, "damage": 25, "impact": 0}, null)
	expect(sim.hits.size() == 1 and sim.hits[0][2] > 0, "an explosion at the seam damages the actor once across it")
	cleanup()
	world_from_solid(tree, 8, 6, func(sx: int, sy: int) -> bool: return sx == 2 and sy == 2)
	expect(not _terrain.line_of_sight(Vector2(496, 360), Vector2(48, 48)),
			"a wall beyond both seams still blocks the line of sight")

func _beam_hole(tree: SceneTree) -> void:
	var texture := wall_texture()
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(10, 8): texture, Vector2i(11, 8): texture})
	var terrain := _terrain
	var world := parent.combat.terrain.physics
	var down := [Vector2(704, 480), Vector2(704, 600)]
	expect(not world.ray_hit(down[0], down[1], CollisionWorld.LAYER_TERRAIN).is_empty(),
			"intact subcells block the ray before the hole exists")
	var cells := {}
	for y in range(32, 36):
		for x in range(41, 47):
			cells[Vector2i(x, y)] = 0
	terrain.apply_at(terrain.version, cells)
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

## 在同一物理帧内移动角色、改碰撞层和切换蹲姿，验证查询可以立即使用更新后的碰撞数据。
func _proxy_same_frame(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent, 1)
	actor.position = Vector2(512, 512)
	actor.sync_collision_geometry()
	var mask := CollisionWorld.LAYER_TEAM_A
	collider(actor, mask)
	var world := actor.terrain.physics
	var circle := CircleShape2D.new()
	circle.radius = 24.0
	var probe := Transform2D(0.0, Vector2(512, 512))
	expect(not world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"the real actor body is queryable in the same frame")
	expect(not world.shape_overlaps(circle, probe, mask).is_empty(),
			"shape queries also see the same-frame body")
	var original := actor.transform
	actor.position.x += 200.0
	expect(world.shape_overlaps(circle, probe, mask).is_empty(), "changing position immediately moves the RID")
	actor.transform = original
	expect(not world.shape_overlaps(circle, probe, mask).is_empty(), "restoring the transform immediately restores contact")
	actor.position = Vector2(200, 512)
	actor.sync_collision_geometry()
	expect(world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"moving the body takes effect without waiting for a physics frame")
	expect(world.shape_overlaps(circle, probe, mask).is_empty(),
			"moving the body also clears same-frame shape queries")
	actor.position = Vector2(512, 512)
	actor.sync_collision_geometry()
	expect(not world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"moving the body back restores the original query result")
	# 当角色在地图边缘蹲下时，位于地图另一端的碰撞形状也要使用蹲姿。
	actor.position = Vector2(10, 512)
	actor.sync_collision_geometry()
	var rid := actor.rid
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
		actor.position = Vector2(500 + i, 512)
		actor.sync_collision_geometry()
		stable = stable and not world.ray_hit(Vector2(500 + i, 380), Vector2(500 + i, 700), mask).is_empty()
	expect(stable, "the body stays queryable across 32 in-frame updates")

func _queries(terrain: Terrain) -> void:
	var ts := float(Terrain.SUB_SIZE)
	var x := terrain.columns / 2
	var solid := Rect2(Vector2(x * ts, (terrain.rows - 1) * ts), Vector2(ts, ts))
	var empty := Rect2(Vector2(x * ts, 0.0), Vector2(ts, ts))
	expect(terrain.rect_overlaps(solid, false), "rect overlap finds a solid cell")
	expect(not terrain.rect_overlaps(empty, false), "rect overlap misses an empty cell")
	var path := GridPathfinder.find_path(Vector2i(terrain.columns, terrain.rows), Vector2i(1, 1), Vector2i(1, 2),
			func(at: Vector2i) -> bool: return not TileDefs.is_blocked(terrain.material_at(at)))
	expect(path == [Vector2i(1, 2)], "adjacent subcells are separate nodes in A*")

func _map_format() -> void:
	var path := "res://maps/newfactory.cyrm"
	var map := CyrmMap.load_file(path)
	expect(not map.is_empty() and map.size == Vector2i(600, 400), "shipped map dimensions are subcells")
	var received := CyrmMap.from_bytes(FileAccess.get_file_as_bytes(path))
	expect(not is_same(received, map) and received == map, "file and network restore independent identical maps")
	var colored := CyrmMap.create(Vector2i(4, 4))
	var desc := 62833
	var values: PackedInt32Array = colored.layers[CyrmMap.SCENE]
	values.fill(desc)
	var authored_tint := Vector4i(1, 6, 5, 2)
	expect(CyrmMap.tile_value(15, authored_tint) == desc and CyrmMap.tile_tint(desc) == authored_tint,
			"semantic tile fields match the stored subcell value")
	expect(TerrainAtlas.tint_color(Color8(82, 196, 144, 147), CyrmMap.tile_tint(desc)) == Color8(116, 235, 85, 42),
			"game tint agrees with the editor's RGBA bytes")
	var colored_terrain := Terrain.new(colored)
	var display := TerrainView.new()
	display.install(colored, Vector2(16.0, 16.0))
	var layer := display._wall
	var sub := Vector2i.ZERO
	var corner := Vector2i(4, 4)
	var atlas := TerrainAtlas.atlas_coords(display._wall_rows[desc], 0)
	expect(layer.get_used_cells().size() == 36 and layer.get_cell_atlas_coords(corner) == atlas,
			"initial paint adds only the one-subcell seam bands around the 4x4 map")
	colored_terrain.apply_at(colored_terrain.version, {sub: 0})
	display.patch(colored_terrain.take_wall_changes())
	expect(layer.get_used_cells().size() == 32 and layer.get_cell_source_id(sub) == -1
			and layer.get_cell_source_id(corner) == -1, "destroying a corner tile erases its four visual cells")
	colored_terrain.apply_at(0, {})
	display.patch(colored_terrain.take_wall_changes())
	expect(layer.get_used_cells().size() == 36 and layer.get_cell_atlas_coords(sub) == atlas
			and layer.get_cell_atlas_coords(corner) == atlas,
			"rewind restores the tinted tile and its seam copy")
	display.free()
	var bytes := CyrmMap.to_bytes(colored)
	for length in [0, 4, 13, bytes.size() - 1]:
		expect(CyrmMap.from_bytes(bytes.slice(0, length)).is_empty(), "truncated map stream is rejected")
	bytes[-1] ^= 1
	expect(CyrmMap.from_bytes(bytes).is_empty(), "corrupt map stream is rejected")

func _water_atlas() -> void:
	expect(TerrainAtlas.WATER_BODY_MATERIAL == 21 and TerrainAtlas.WATER_SURFACE_MATERIAL == 22,
			"water body and surface use their map material IDs")
	TerrainAtlas.clear_cache()
	var body_tile := CyrmMap.tile_value(21)
	var body := TerrainAtlas.tile_image(64, body_tile)
	var surface := TerrainAtlas.tile_image(64, CyrmMap.tile_value(22))
	expect(body != surface, "water body and surface images come from different bricks")
	expect(TerrainAtlas.tile_image(64, body_tile) == body,
			"the neutral water brick is cached")
	var tint := Vector4i(0, 4, 4, 7)
	var colored_body := TerrainAtlas.tile_image(64, CyrmMap.tile_value(21, tint))
	var colored_surface := TerrainAtlas.tile_image(64, CyrmMap.tile_value(22, tint))
	expect(colored_body.get_data() != body.get_data() and colored_surface.get_data() != surface.get_data(),
			"the same tint applies to both water textures")
	expect(TerrainAtlas.tile_image(8, 0).get_pixel(0, 0).a == 0.0, "air has a transparent tile image")
	var water_map := CyrmMap.create(Vector2i(4, 4))
	var cells: PackedInt32Array = water_map.layers[CyrmMap.SCENE]
	var transparent := Vector4i(7, 4, 4, 0)
	cells.fill(CyrmMap.tile_value(21, tint))
	cells[0] = CyrmMap.tile_value(21, transparent)
	cells[3] = 0
	var water := TerrainView.new()
	water.install(water_map, Vector2.ZERO)
	expect(water._water.tile_set.tile_size == Vector2i(16, 16), "water is rendered at subcell resolution")
	expect(water._water.get_cell_atlas_coords(Vector2i.ZERO) != water._water.get_cell_atlas_coords(Vector2i.RIGHT)
			and water._water.get_cell_source_id(Vector2i(3, 0)) == -1, "separate water tints and air remain independent")
	water.free()

## 验证联机出生点的元数据格式和内置地图的点位。
func _respawn_format() -> void:
	var demo := CyrmMap.load_file("res://maps/demo.cyrm")
	var factory := CyrmMap.load_file("res://maps/newfactory.cyrm")
	var demo_respawn := SpawnPicker.respawn_cells(demo)
	var factory_respawn := SpawnPicker.respawn_cells(factory)
	expect(demo_respawn[1].size() == 8 and demo_respawn[2].size() == 8,
			"demo.cyrm defines eight spawn points per side")
	expect(factory_respawn[1].size() == 9 and factory_respawn[2].size() == 9,
			"newfactory.cyrm defines nine spawn points per side")
	expect(SpawnPicker.validate_multiplayer_spawns(demo).is_empty(), "demo.cyrm spawn validation passes")
	expect(SpawnPicker.validate_multiplayer_spawns(factory).is_empty(), "newfactory.cyrm spawn validation passes")
	expect(SpawnPicker.spawn_cell_problem(demo, Vector2i(-1, 0)) != "",
			"an out-of-bounds respawn cell is rejected")
	expect(SpawnPicker.spawn_cell_problem(demo, Vector2i(10, 10)) != "",
			"a cell without foot support is rejected")
	expect(SpawnPicker.spawn_cell_problem(demo, demo_respawn[1][0]) == "",
			"a configured respawn cell passes clearance and support checks")
