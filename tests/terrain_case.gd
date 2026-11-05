extends "res://tests/case.gd"

func run(tree: SceneTree) -> void:
	var node := world(tree)
	var level := TileDefs.terrain
	_seam(node)
	_beam(level)
	_queries(level)
	var sub := Vector2i(8, 12)
	var original := level.get_hp(sub)
	level.apply_hp(sub, original - 1, 1)
	expect(level.get_hp(sub) == original - 1, "partial terrain damage preserves exact HP")
	expect(level.flush_collisions() == 0, "HP-only damage does not rebuild geometry")
	level.set_rewind_enabled(true)
	level.seal_rewind(0.0)
	level.apply_hp(sub, 0, 1)
	level.seal_rewind(1.0)
	expect(level.flush_collisions() > 0, "destroyed terrain commits collision changes")
	level.rewind_between(0.0, 1.0)
	expect(level.get_hp(sub) == original - 1, "rewind restores residual HP, not full health")
	level.reset()
	level.reset_prediction(100)
	var generation := level.generation
	level.predict_blast(1, WeaponRegistry.all_ids()[0], Vector2(136, 200), 101, 8.0, original)
	var damaged := level.get_hp(sub)
	expect(damaged < original, "predicted blast changes terrain")
	expect(level.can_restore(100, generation), "prediction checkpoint is restorable")
	level.restore_checkpoint(100)
	expect(level.get_hp(sub) == original, "prediction restore recovers exact terrain")
	level.predict_blast(1, WeaponRegistry.all_ids()[0], Vector2(136, 200), 101, 8.0, original)
	expect(level.get_hp(sub) == damaged, "repeated blast after restore gives the same damage")
	level.apply_authority({"tick": 101, "revision": 1, "cells": {sub: damaged}})
	expect(level.difference(101, generation, 1).is_empty(), "matching authority confirms predicted terrain")
	_mirror_topology(tree)
	_mirrored_collision(tree)
	_beam_hole(tree)
	_proxy_same_frame(tree)
	_remote_layer(tree)
	_lifecycle(tree)
	_toroidal_sight(tree)
	_visual_projection(tree)
	_map_format()
	_respawn_format()
	_water_atlas()

# 测试地图只有最下面一行宏格是实心的；从上方向下打，命中那一行。
func _beam(terrain: Terrain) -> void:
	var x := terrain.columns / 2
	var wall_cell := Vector2i(x, terrain.rows - 1)
	var start := Vector2((x + 0.5) * terrain.tile_size, (terrain.rows - 1.5) * terrain.tile_size)
	var packed := terrain.value(wall_cell)
	expect(terrain.value(Vector2i(x, terrain.rows - 2)) == 0 and (packed & 15) == 15,
			"test map has a solid row under an empty one")
	var target := Vector2(start.x, start.y + terrain.tile_size)
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
	var terrain := TileDefs.terrain
	var centers := terrain.body_shapes(0)
	expect(centers.has(Vector2(256.0, 224.0)), "bottom row is written into the world")
	expect(centers.has(Vector2(768.0, 224.0)), "seam mirror repeats the bottom row across the left edge")
	expect(not centers.has(Vector2(256.0, 480.0)),
			"the bottom edge does not repeat itself on the far side")
	var plain := Node.new()
	node.add_child(plain)
	expect(Terrain._space_of(plain).is_valid(), "plain nodes resolve the world of their viewport")
	plain.free()

# 内部墙只有一份物理形状；贴边与角落只补必要副本。
func _mirror_topology(tree: SceneTree) -> void:
	var texture := wall_texture()
	world_with_walls(tree, 20, 20, {Vector2i(10, 10): texture, Vector2i(10, 19): texture,
			Vector2i(0, 5): texture, Vector2i(0, 0): texture})
	var terrain := TileDefs.terrain
	var centers := {}
	var total := 0
	for key in terrain._chunks.keys():
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
	var texture := wall_texture()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(10, 8): texture})
	var bullet: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	bullet.prediction_only = true
	bullet.setup(Vector2.LEFT, 600.0, 1000.0, 1.0, Color.WHITE, null)
	bullet.position = Vector2(740, 544)
	parent.add_child(bullet)
	bullet.set_physics_process(false)
	expect(bullet.advance_physics(0.1) == BulletBody.AdvanceResult.TERRAIN_HIT,
			"canonical projectile hits the interior wall")
	bullet.free()
	var ghost: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	ghost.prediction_only = true
	ghost.setup(Vector2.LEFT, 600.0, 1000.0, 1.0, Color.WHITE, null)
	ghost.position = Vector2(740 + 1024, 544)
	parent.add_child(ghost)
	ghost.set_physics_process(false)
	expect(ghost.advance_physics(0.1) == BulletBody.AdvanceResult.MOVED,
			"visual copies of interior walls carry no collision")
	ghost.free()
	# 规范世界运动跨接缝：右侧出门，撞到左侧贴边墙的镜像
	cleanup()
	var edge := wall_texture()
	var seam_parent := world_with_walls(tree, 16, 16, {Vector2i(0, 8): edge, Vector2i(8, 0): edge})
	var across := preload("res://scenes/weapons/bullet.tscn").instantiate() as BulletBase
	across.prediction_only = true
	across.setup(Vector2.RIGHT, 600.0, 2000.0, 1.0, Color.WHITE, null)
	across.position = Vector2(1010, 544)
	seam_parent.add_child(across)
	across.set_physics_process(false)
	expect(across.advance_physics(0.1) == BulletBody.AdvanceResult.TERRAIN_HIT,
			"crossing the horizontal seam still hits the wall on the opposite edge")
	across.free()
	var vertical := preload("res://scenes/weapons/bullet.tscn").instantiate() as BulletBase
	vertical.prediction_only = true
	vertical.setup(Vector2.DOWN, 600.0, 2000.0, 1.0, Color.WHITE, null)
	vertical.position = Vector2(544, 1010)
	seam_parent.add_child(vertical)
	vertical.set_physics_process(false)
	expect(vertical.advance_physics(0.1) == BulletBody.AdvanceResult.TERRAIN_HIT,
			"crossing the vertical seam still hits the wall on the opposite edge")
	vertical.free()
	# 单人弹丸同样只持有规范坐标：跨接缝后下一 tick 命中的是不在接缝附近的中部墙。
	cleanup()
	var interior := world_with_walls(tree, 16, 16, {Vector2i(2, 4): edge})
	var single: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	single.setup(Vector2.RIGHT, 600.0, 4000.0, 1.0, Color.WHITE, null)
	single.position = Vector2(1010, 300)
	interior.add_child(single)
	single.set_physics_process(false)
	var steps: Array = []
	for i in 3:
		steps.append(single.advance_physics(0.1))
		expect(single.global_position.x >= 0.0 and single.global_position.x < 1024.0,
				"single-player projectile stays canonical, tick %d" % (i + 1))
	expect(steps == [BulletBody.AdvanceResult.MOVED, BulletBody.AdvanceResult.MOVED,
			BulletBody.AdvanceResult.TERRAIN_HIT],
			"a single-player projectile crosses the seam and hits an interior wall next tick")
	single.free()
	var ranged: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	ranged.setup(Vector2.RIGHT, 600.0, 20.0, 1.0, Color.WHITE, null)
	ranged.position = Vector2(1010, 300)
	interior.add_child(ranged)
	ranged.set_physics_process(false)
	expect(ranged.advance_physics(0.1) == BulletBody.AdvanceResult.RANGE_END,
			"range-ended projectiles leave through the same canonical exit")
	expect(ranged.global_position.x >= 0.0 and ranged.global_position.x < 1024.0,
			"range end still returns to canonical coordinates")
	ranged.free()
	var shell: BulletBase = preload("res://scenes/weapons/grenade_bullet.tscn").instantiate()
	shell.setup(Vector2.RIGHT, 3000.0, 4000.0, 1.0, Color.WHITE, null)
	shell.position = Vector2(1010, 300)
	interior.add_child(shell)
	shell.set_physics_process(false)
	expect(shell.advance_physics(0.1) == BulletBody.AdvanceResult.BOUNCED,
			"a grenade bounces off the mirrored interior wall")
	expect(shell.global_position.x >= 0.0 and shell.global_position.x < 1024.0,
			"bounced projectiles are also canonical")
	shell.free()

# 预测世界拥有真实远端体；检查点恢复与边界换层立即提交 RID。
func _remote_layer(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var local := player(parent, 1)
	var prediction := PredictionWorld.new()
	prediction.bind(local)
	prediction.terrain = TileDefs.terrain
	prediction.ensure_actor(7, 2)
	var remote := prediction.actor(7)
	var record: Array = preload("res://tests/prediction_case.gd").wire_state(local.capture_state())
	record[PlayerStateSchema.slot("pos")] = Vector2(512, 512)
	record[PlayerStateSchema.slot("respawn_tick")] = 20
	var frame := {"tick": 10, "own": {"state": local.capture_state(), "rewind": false},
			"world": {"players": {1: preload("res://tests/prediction_case.gd").wire_state(local.capture_state()), 7: record},
			"projectiles": {}}, "time": {}}
	prediction.restore_authority(frame)
	var checkpoint := prediction.capture([])
	var physics := CollisionWorld.acquire(remote)
	var circle := CircleShape2D.new()
	circle.radius = 24.0
	var probe := Transform2D(0.0, Vector2(512, 512))
	expect(not physics.shape_overlaps(circle, probe, CollisionWorld.LAYER_TEAM_B).is_empty(),
			"authority restore immediately exposes the remote RID on its team layer")
	for at in range(11, 21): prediction.step_tick(InputBuffer.neutral(), true)
	expect(remote.collision_layer == 0, "the rules phase at the known respawn tick removes the old body")
	expect(physics.shape_overlaps(circle, probe, CollisionWorld.LAYER_TEAM_B).is_empty(),
			"the expired remote layer is immediately absent from physics")
	prediction.restore(checkpoint)
	expect(remote.collision_layer == CollisionWorld.LAYER_TEAM_B,
			"world checkpoint restores the remote collision layer")
	remote.global_position = Vector2(10, 512)
	remote.apply_collision_pose()
	expect(not physics.shape_overlaps(circle, Transform2D(0.0, Vector2(10 + GameParameters.MAP_WIDTH, 512)),
			CollisionWorld.LAYER_TEAM_B).is_empty(), "a seam actor mirrors its hull to the other side")
	remote.global_position = Vector2(512, 512)
	remote.apply_collision_pose()
	expect(physics.shape_overlaps(circle, Transform2D(0.0, Vector2(512 + GameParameters.MAP_WIDTH, 512)),
			CollisionWorld.LAYER_TEAM_B).is_empty(), "a mid-map actor has no mirror across the seam")

# 空间适配层闭环：用例清理后不留残留空间。
func _lifecycle(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var space: RID = parent.get_world_2d().space
	var actor := player(parent)
	collider(actor, CollisionWorld.LAYER_TEAM_A)
	var world := CollisionWorld.acquire(actor)
	expect(world.space == space, "the adapter binds the fixture space")
	cleanup()
	expect(not CollisionWorld._by_space.has(space.get_id()),
			"case cleanup returns the space adapter to the baseline")

# 遮挡与爆炸候选都按环面最短位移处理，跨接缝的连线不会改判成穿过整张地图的直线。
func _toroidal_sight(tree: SceneTree) -> void:
	cleanup()
	var texture := wall_texture()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(8, 8): texture})
	var terrain := TileDefs.terrain
	terrain.flush_collisions()
	var from := Vector2(900, 544)
	var to := Vector2(100, 544)
	expect(terrain.line_of_sight(from, to),
			"a seam-crossing sight line ignores walls in the middle of the map")
	expect(not terrain.line_of_sight(Vector2(900, 544), Vector2(500, 544)),
			"the same middle wall still blocks a straight line")
	cleanup()
	parent = world_with_walls(tree, 16, 16, {Vector2i(15, 8): texture})
	terrain = TileDefs.terrain
	terrain.flush_collisions()
	expect(not terrain.line_of_sight(from, to), "a wall on the seam blocks the wrapping sight line")
	var victim := player(parent, 3)
	victim.global_position = Vector2(10, 544)
	victim.apply_collision_pose()
	collider(victim, CollisionWorld.LAYER_TEAM_A)
	var world := CollisionWorld.acquire(victim)
	var roles := {}
	for entry: Dictionary in Explosion._candidates(Vector2(1010, 544), 128.0):
		var node: Node2D = entry["collider"]
		if node is ActorBody: roles[node.role] = true
	expect(roles.has(victim.role), "an explosion at the seam still finds actors across it")

func _beam_hole(tree: SceneTree) -> void:
	var texture := wall_texture()
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {Vector2i(10, 8): texture, Vector2i(11, 8): texture})
	var terrain := TileDefs.terrain
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
	actor.apply_collision_pose()
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
	actor.global_position = Vector2(200, 512)
	actor.apply_collision_pose()
	expect(world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"moving the body takes effect without waiting for a physics frame")
	expect(world.shape_overlaps(circle, probe, mask).is_empty(),
			"moving the body also clears same-frame shape queries")
	actor.global_position = Vector2(512, 512)
	actor.apply_collision_pose()
	expect(not world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"moving the body back restores the original query result")
	# 姿态切换：镜像槽的形状立即换成对应姿态壳。
	actor.global_position = Vector2(10, 512)
	actor.apply_collision_pose()
	var stand_shape := PhysicsServer2D.body_get_shape(actor.get_rid(), actor.hulls.size())
	actor.is_squat = true
	actor.apply_collision_pose()
	expect(PhysicsServer2D.body_get_shape(actor.get_rid(), actor.hulls.size()) != stand_shape,
			"stance changes swap the mirror shape in the same frame")
	actor.is_squat = false
	actor.apply_collision_pose()
	actor.collision_layer = 0
	expect(world.ray_hit(Vector2(512, 380), Vector2(512, 700), mask).is_empty(),
			"layer changes take effect immediately")
	expect(world.shape_overlaps(circle, probe, mask).is_empty(),
			"a cleared layer also leaves shape queries")
	actor.collision_layer = mask
	var stable := true
	for i in 32:
		actor.global_position = Vector2(500 + i, 512)
		actor.apply_collision_pose()
		stable = stable and not world.ray_hit(Vector2(500 + i, 380), Vector2(500 + i, 700), mask).is_empty()
	expect(stable, "the body stays queryable across 32 in-frame updates")

# 弹丸的视觉投影不写回物理位置；逻辑坐标与渲染副本互相独立。
func _visual_projection(tree: SceneTree) -> void:
	cleanup()
	var parent := world_with_walls(tree, 16, 16, {})
	var actor := player(parent, 1)
	actor.global_position = Vector2(64, 512)
	var bullet: BulletBase = preload("res://scenes/weapons/bullet.tscn").instantiate()
	bullet.setup(Vector2.RIGHT, 600.0, 1000.0, 1.0, Color.WHITE, null)
	bullet.position = Vector2(960, 512)
	parent.add_child(bullet)
	bullet.set_physics_process(false)
	bullet.shooter = actor
	var canonical := bullet.global_position
	bullet.present_projection()
	expect(bullet.global_position == canonical, "visual projection never rewrites the physics position")
	expect(bullet.visual_offset == Vector2(-1024, 0), "visual projection picks the copy nearest the local player")
	bullet.present_projection()
	expect(bullet.global_position == canonical and bullet.visual_offset == Vector2(-1024, 0),
			"repeated projection is stable")

func _queries(terrain: Terrain) -> void:
	var ts := float(terrain.tile_size)
	var x := terrain.columns / 2
	var solid := Rect2(Vector2(x * ts, (terrain.rows - 1) * ts), Vector2(ts, ts))
	var empty := Rect2(Vector2(x * ts, 0.0), Vector2(ts, ts))
	expect(terrain.rect_overlaps(solid, ts, false), "rect overlap finds a solid cell")
	expect(not terrain.rect_overlaps(empty, ts, false), "rect overlap misses an empty cell")
	# 快照按 Array[Array] 返回：寻路接口可以直接接收，不需要隐藏拷贝，也不会在运行时被拒绝。
	var path := GridPathfinder.astar_path_nearest(terrain.get_grid_snapshot(), Vector2i(1, 1), Vector2i(1, 2))
	expect(not path.is_empty(), "grid snapshot feeds the typed pathfinder directly")

func _map_format() -> void:
	var info := MapFormat.load_map_info("res://maps/newfactory.cyrm", true)
	expect(not info["grid"].is_empty() and not info["subgrid"].is_empty(), "shipped v4 map loads macro and subgrid together")
	var body := PackedByteArray([0, 0, 1, 1, 0, 0, 16, 0, 0, 1])
	body.resize(26)
	var bytes := _map_bytes(body)
	expect(MapFormatV4.parse(bytes)["ok"], "minimal valid v4 scene")
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
			"the water brick cache is keyed by (ts, brick)")
	var tiles := TerrainAtlas.make_water_tileset(64, TerrainAtlas.WATER_BODY_BRICK)
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
	var demo := MapFormat.load_map_info("res://maps/demo.cyrm", true)
	var factory := MapFormat.load_map_info("res://maps/newfactory.cyrm", true)
	var demo_respawn: Dictionary = demo["spawns"].get("respawn", {})
	var factory_respawn: Dictionary = factory["spawns"].get("respawn", {})
	expect(demo_respawn.get(1, []).size() >= 5 and demo_respawn.get(2, []).size() >= 5,
			"demo.cyrm defines at least five respawn points per side")
	expect(factory_respawn.get(1, []).size() >= 5 and factory_respawn.get(2, []).size() >= 5,
			"newfactory.cyrm defines at least five respawn points per side")
	var teams_5v5 := {}
	for i in 5:
		teams_5v5[i + 1] = 1
		teams_5v5[i + 6] = 2
	expect(MatchRules.validate_team_spawns("res://maps/demo.cyrm", teams_5v5) == "",
			"demo.cyrm 5v5 spawn validation passes")
	expect(MatchRules.validate_team_spawns("res://maps/newfactory.cyrm", teams_5v5) == "",
			"newfactory.cyrm 5v5 spawn validation passes")
	var meta := ["# respawn 1 2 3", "# respawn 3 1 2", "# respawn 1 a 2",
			"# respawn 1 1", "# respawn 1 200 200"]
	var parsed := MapFormat.parse_spawn_metadata(meta, Vector2i(10, 10))
	expect(parsed["respawn"][1] == [Vector2i(2, 3)], "a valid respawn line is stored per team")
	expect(parsed["respawn_errors"].size() == 4, "malformed respawn lines are reported")
	expect(str(parsed["respawn_errors"][0]).contains("第 2 行"),
			"the respawn error names its source line")
	expect(str(parsed["respawn_errors"][0]).contains("3"), "the respawn error includes the source content")
	var dims := Vector2i(125, 75)
	var subgrid: Array = demo["subgrid"]
	expect(MatchRules.spawn_cell_problem(subgrid, dims, Vector2i(-1, 0)) != "",
			"an out-of-bounds respawn cell is rejected")
	expect(MatchRules.spawn_cell_problem(subgrid, dims, Vector2i(10, 10)) != "",
			"a cell without foot support is rejected")
	expect(MatchRules.spawn_cell_problem(subgrid, dims, demo_respawn[1][0]) == "",
			"a configured respawn cell passes clearance and support checks")
