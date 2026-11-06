class_name WorldBuilder
extends RefCounted


static var _grid_cache: Dictionary = {}

static func load_grid() -> Array:
	var map_path := MazeGenerator.map_file_path()
	var cached: Dictionary = _grid_cache.get(map_path, {})
	if not cached.is_empty():
		var grid0: Array[Array] = MazeGenerator.copy_grid(cached["grid"])
		MazeGenerator.current_grid = grid0
		MazeGenerator.current_subgrid = MazeGenerator.copy_grid(cached["subgrid"])
		MazeGenerator.current_subdesc = MazeGenerator.copy_grid(cached["subdesc"])
		GameParameters.MAP_WIDTH = grid0[0].size() * GameParameters.TILE_SIZE
		GameParameters.MAP_HEIGHT = grid0.size() * GameParameters.TILE_SIZE
		return grid0
	var bundle := MapFormat.load_map_bundle(map_path)
	var grid: Array[Array]
	if not bundle.is_empty():
		grid = bundle["grid"]
		if grid.is_empty():
			push_error("WorldBuilder: 地图解析失败")
			return []
		MazeGenerator.current_grid = grid
		MazeGenerator.current_subgrid = bundle["textures"]
		MazeGenerator.current_subdesc = bundle["descs"]
	else:
		grid = MazeGenerator.load_map_file()
		if grid.is_empty():
			push_error("WorldBuilder: 地图加载失败")
			return []
		MazeGenerator.current_grid = grid
		var sd := MapFormat.load_subgrid_with_descs(map_path)
		MazeGenerator.current_subgrid = sd["textures"]
		MazeGenerator.current_subdesc = sd["descs"]
	TileDefs.load_defs()
	GameParameters.MAP_WIDTH = grid[0].size() * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = grid.size() * GameParameters.TILE_SIZE
	_grid_cache[map_path] = {
		"grid": MazeGenerator.copy_grid(grid),
		"subgrid": MazeGenerator.copy_grid(MazeGenerator.current_subgrid),
		"subdesc": MazeGenerator.copy_grid(MazeGenerator.current_subdesc),
	}
	return grid

static func build_sim(parent: Node, grid: Array[Array]) -> Array:
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false), parent, "WallCollision")
	var sub := CollisionBuilder.build_sub(grid, true)
	CollisionBuilder.build_destructible_chunks(sub, parent)
	CollisionBuilder.build_climb_ledges(grid, parent)
	return sub
