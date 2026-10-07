class_name WorldBuilder
extends RefCounted

# 场景世界构建器：负责地图网格数据加载与物理碰撞体生成，供单人模式 Level0、PvP 客户端与服务端统一复用。
# build_sim 方法负责将生成的物理碰撞体节点挂载至指定的 parent 节点下（客户端挂载至 WorldViewport，服务端挂载至权威世界节点）。

# 加载地图网格数据 -> 初始化 current_grid、TileDefs 以及地图像素尺寸；返回网格数组（空表示失败）。
static func load_grid() -> Array:
	var grid := MazeGenerator.load_map_file()
	if grid.is_empty():
		push_error("WorldBuilder: 地图加载失败")
		return []
	MazeGenerator.current_grid = grid
	# cyrm v4：子格纹理表与大格网格一同装填；旧版 v3 地图由 MapFormat 内部展开兼容
	MazeGenerator.current_subgrid = MapFormat.load_subgrid(MazeGenerator.map_file_path())
	TileDefs.load_defs()
	GameParameters.MAP_WIDTH = grid[0].size() * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = grid.size() * GameParameters.TILE_SIZE
	return grid

# 构建物理碰撞体（永久墙体 + 可破坏瓦片分块 + 攀爬基座），并挂载至 parent 节点；返回持久化可破坏子格数据以备后续局部重建。
static func build_sim(parent: Node, grid: Array[Array]) -> Array:
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false), parent, "WallCollision")
	var sub := CollisionBuilder.build_sub(grid, true)
	CollisionBuilder.build_destructible_chunks(sub, parent)
	CollisionBuilder.build_climb_ledges(grid, parent)
	return sub
