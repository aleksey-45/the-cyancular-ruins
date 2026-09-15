class_name WorldBuilder
extends RefCounted

# 世界构建(地图加载/碰撞),单人 Level0 与 PvP 客户端/服务器共用。
# 行为不变重构:Level0._ready 改为调用此处,单机表现不变。
# build_sim 把碰撞节点挂到 parent 下(客户端=WorldViewport,服务器=服务器世界节点)。

# 加载地图 → current_grid + TileDefs + 地图像素尺寸;返回网格(空=失败)。
static func load_grid() -> Array:
	var grid := MazeGenerator.load_map_file()
	if grid.is_empty():
		push_error("WorldBuilder: 地图加载失败")
		return []
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()
	GameParameters.MAP_WIDTH = grid[0].size() * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = grid.size() * GameParameters.TILE_SIZE
	return grid

# 建碰撞(永久墙 + 可破坏分块 + 攀爬基座条),挂到 parent;返回持久可破坏子格(摧毁重建用)。
static func build_sim(parent: Node, grid: Array[Array]) -> Array:
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false), parent, "WallCollision")
	var sub := CollisionBuilder.build_sub(grid, true)
	CollisionBuilder.build_destructible_chunks(sub, parent)
	CollisionBuilder.build_climb_ledges(grid, parent)
	return sub
