class_name WorldBuilder
extends RefCounted

# 单人、客户端与服务器共用的地图装载入口。
static func load_grid() -> Array:
	MazeGenerator.current_spawns = {}
	var info := MapFormat.load_map_info(MazeGenerator.map_file_path(), true)
	var grid: Array[Array] = info["grid"]
	if grid.is_empty():
		push_error("WorldBuilder: 地图加载失败")
		return []
	MazeGenerator.current_spawns = info["spawns"]
	TileDefs.load_terrain(grid, info["subgrid"])
	GameParameters.MAP_WIDTH = grid[0].size() * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = grid.size() * GameParameters.TILE_SIZE
	return grid
