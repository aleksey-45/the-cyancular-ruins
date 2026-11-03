class_name WorldBuilder
extends RefCounted

# 世界构建(地图加载/碰撞),单人 Level0 与 PvP 客户端/服务器共用。
# 行为不变重构:Level0._ready 改为调用此处,单机表现不变。
# build_sim 把碰撞节点挂到 parent 下(客户端=WorldViewport,服务器=服务器世界节点)。

# 加载地图 → current_grid + TileDefs + 地图像素尺寸;返回网格(空=失败)。
# ★ 2026-11-02 进关卡卡顿优化:解析结果按**地图路径**缓存。同一进程里"玩一局→回菜单→再开"
#   每次都要重解析 cyrm(实测 315ms,占进关卡同步耗时的 ~15%)⇒ 缓存后第二次起接近 0。
#   返回的是**深拷贝**:调用方(Level0/TileDefs)会改自己的网格,不能把缓存本体交出去。
static var _grid_cache: Dictionary = {}   # map_path(String) -> {grid, subgrid, subdesc}

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
	# ★ 2026-11-02 解析提速:一次解析拿全套(v4)。旧写法 `load_map_file()` + `load_subgrid_with_descs()`
	#   把同一份 cyrm **解析了两遍**(各含读盘/CRC/240k 迁移)⇒ 这里只解析一次。
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
		# 非 v4(v3 / 旧文本图):回退旧路径(两条各自展开,只在老图上付这份钱)
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

# 建碰撞(永久墙 + 可破坏分块 + 攀爬基座条),挂到 parent;返回持久可破坏子格(摧毁重建用)。
static func build_sim(parent: Node, grid: Array[Array]) -> Array:
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false), parent, "WallCollision")
	var sub := CollisionBuilder.build_sub(grid, true)
	CollisionBuilder.build_destructible_chunks(sub, parent)
	CollisionBuilder.build_climb_ledges(grid, parent)
	return sub
