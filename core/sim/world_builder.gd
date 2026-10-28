class_name WorldBuilder
extends RefCounted

# 单人、客户端与服务器共用的地图装载入口。
static func load_grid() -> Array:
	var grid := MazeGenerator.load_map_file()
	if grid.is_empty():
		push_error("WorldBuilder: 地图加载失败")
		return []
	var subgrid := MapFormat.load_subgrid(MazeGenerator.map_file_path())
	TileDefs.load_terrain(grid, subgrid)
	GameParameters.MAP_WIDTH = grid[0].size() * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = grid.size() * GameParameters.TILE_SIZE
	return grid
