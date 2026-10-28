extends Node

class TestLevel extends Level0:
	func _ready() -> void:
		set_process(false)
		set_physics_process(false)

var _failures: Array[String] = []
var _level: TestLevel

func _ready() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures.append(message)

func _record(t: float) -> void:
	_level._rewind._t = t
	_level._flush_terrain_history()

func _rewind(target: float, cursor: float) -> void:
	_level.terrain.rewind_between(target, cursor)
	_level.flush_terrain_visuals()

func _run() -> void:
	TileDefs.load_defs()
	var trunk := 19
	var leaf := 15
	var grid: Array[Array] = [[MazeGenerator.pack(trunk, 15), MazeGenerator.pack(leaf, 15)]]
	var subgrid := MapFormat.expand_cells_to_subgrid(grid)
	# 混纹理格：树干、树叶、永久墙和水。
	subgrid[0][0] = leaf
	subgrid[0][1] = 1
	subgrid[0][2] = 21
	TileDefs.load_terrain(grid, subgrid)
	_level = TestLevel.new()
	var world := Node2D.new()
	world.name = "WorldViewport"
	_level.add_child(world)
	var wall := TileMapLayer.new()
	wall.tile_set = TerrainAtlas.make_wall_tileset()
	world.add_child(wall)
	Level0.wall_layer = wall
	Level0.pvp_mode = false
	_level.terrain = TileDefs.terrain
	_level.terrain.attach(world)
	_level.terrain.set_rewind_enabled(true)
	Level0.time_field = TimeField.new(GrainAccount.new())
	_level._rewind = WorldRewind.new(world)
	add_child(_level)
	var cell := Vector2i.ZERO
	var sub := Vector2i.ZERO
	var full := TileDefs.capture_terrain_cell(cell)
	TileDefs.damage_tile(cell, 4, "explosion")
	TileDefs.damage_sub(sub, 2, "bullet")
	_check(_level.terrain.pending_rewind_count() == 1, "一帧内同格的格级和子格伤害只保存第一次改动前的状态")
	_record(1.0)
	var damaged := TileDefs.capture_terrain_cell(cell)
	var revision := TileDefs.collision_revision
	_level.flush_terrain_collision()
	TileDefs.damage_tile(cell, 3, "explosion")
	TileDefs.damage_sub(sub, 1, "bullet")
	_record(2.0)
	_rewind(1.5, 2.0)
	_check(TileDefs.capture_terrain_cell(cell) == damaged, "受损未碎的两套 HP 应还原实际残血，不能补成满血")
	_check(TileDefs.collision_revision == revision and _level.terrain.dirty_count() == 0,
		"只恢复正值 HP 不应使碰撞缓存失效或重建物理块")
	_level.terrain.truncate_rewind(1.5)
	# 改写未来：同一时间戳有两次入账，必须恢复后写值，再恢复更早值。
	TileDefs.damage_sub(sub, 1, "bullet")
	_record(2.0)
	TileDefs.damage_sub(sub, 1, "bullet")
	_record(2.0)
	_rewind(1.5, 2.0)
	_check(TileDefs.capture_terrain_cell(cell) == damaged, "同一时间戳的记录必须严格按写入逆序恢复")
	_level.terrain.truncate_rewind(1.5)
	TileDefs.damage_tile(cell, 9999, "explosion")
	_record(3.0)
	_rewind(1.5, 3.0)
	_check(TileDefs.capture_terrain_cell(cell) == damaged, "整格破坏后应恢复混纹理子格 HP 和原有格级残血")
	_check(TileDefs.sub_alive(Vector2i(1, 0)) and TileDefs.sub_alive(Vector2i(2, 0)), "永久墙和水不能被连带清零")
	_check(_level.terrain.get_collision_snapshot(true)[0][0] == MazeGenerator.SOLID and _level.terrain.get_collision_snapshot(true)[0][2] == MazeGenerator.EMPTY,
		"恢复碰撞不能把水变成实体墙")
	_check(wall.get_cell_source_id(Vector2i.ZERO) >= 0 and world.get_node("DestructibleChunk_0_0").get_child_count() > 0,
		"子格复活必须重铺贴图并提交实际碰撞")
	_rewind(0.5, 1.5)
	_check(TileDefs.capture_terrain_cell(cell) == full, "继续回溯跨过首次扣血时才恢复原先满血状态")
	_level.terrain.truncate_rewind(0.5)
	_check(_level.terrain.rewind_count() == 0 and _level.terrain.pending_rewind_count() == 0, "恢复操作不得再次记账，已改写的未来应裁掉")
	# 没有格级剩余子格的彻底破坏，也必须恢复原格索引与 HP。
	var other := Vector2i(1, 0)
	var other_full := TileDefs.capture_terrain_cell(other)
	TileDefs.damage_tile(other, 9999, "explosion")
	_record(4.0)
	_check(MazeGenerator.current_grid[0][1] == 0, "纯可破坏格被清空")
	_rewind(3.5, 4.0)
	_check(TileDefs.capture_terrain_cell(other) == other_full, "全灭后应精确恢复格级索引和两套 HP")
	_level.free()
	_check(not TileDefs.terrain.history_stats()["rewind_enabled"], "单人场景退出应停止录制其地形历史")
	TimeField.current = null
	Level0.time_field = null
	if _failures.is_empty():
		print("TERRAIN HISTORY PROBE: OK partial HP, mixed cells, destruction, branch and stable LIFO")
	else:
		print("TERRAIN HISTORY PROBE: FAIL ", _failures)
	get_tree().quit(0 if _failures.is_empty() else 1)
