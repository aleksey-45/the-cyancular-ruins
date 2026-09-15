class_name MazeGenerator
extends RefCounted

# 地图会话的入口:**选哪份地图 + 当前网格**这两件会话级状态住在这里,其余一律委托出去。
#   · `.cyrm` 格式(格子值编解码 / 解析 / 序列化 / spawn 元数据)→ **MapFormat**(core/sim/map_format.gd)
#   · 环面网格几何与寻路(环面距离 / 副本锚定 / 地板格 / A* / LOS)→ **GridPathfinder**(core/sim/grid_pathfinder.gd)
# ★ 本文件保留全仓既有的 `MazeGenerator.xxx` 调用面(生产代码 ~57 个文件、上百处引用),
#   所以下面是**逐条一行**的转发。别在这里再写实现 —— 新逻辑进上面两个类;
#   新代码若明确只碰格式或只碰寻路,直接引 MapFormat / GridPathfinder,不必绕这里。

const MAP_DIR: String = "res://maps"

# ── 地图文件(.cyrm)──
# 先随机取 exe 旁的 .cyrm(玩家/开发者外置自定义地图),否则随机取 res://maps/*.cyrm;
# 同目录多份 .cyrm 随机读一份。选中的地图整个会话固定(缓存在 _picked_map),
# 保证 map_size / load_map_file / parse_spawn_metadata 读的是同一份。
static var _picked_map: String = ""
static func map_file_path() -> String:
	if _picked_map != "":
		return _picked_map
	var ext := _random_cyrm(OS.get_executable_path().get_base_dir())
	_picked_map = ext if ext != "" else _random_cyrm(MAP_DIR)
	return _picked_map

# 钉住地图文件(PvP:服务器定图,客户端加载同名文件;覆盖会话随机读的缓存)。
static func set_map_file(path: String) -> void:
	_picked_map = path

# 在 dir 目录下随机挑一个 .cyrm 地图;没有则返回 ""。
static func _random_cyrm(dir: String) -> String:
	var da := DirAccess.open(dir)
	if da == null:
		return ""
	var maps: Array[String] = []
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if not da.current_is_dir() and f.to_lower().ends_with(".cyrm"):
			maps.append(dir.path_join(f))
		f = da.get_next()
	da.list_dir_end()
	if maps.is_empty():
		return ""
	return maps[randi() % maps.size()]

# 当前关卡网格(level_0._ready 赋值;空网格时寻路一律视为无路)。
static var current_grid: Array[Array] = []


# ── 转发:格子值编解码(MapFormat)──
const EMPTY: int = MapFormat.EMPTY
const SOLID: int = MapFormat.SOLID  # pack(1, 15) = 纹理1 全砖

static func pack(texture: int, shape: int) -> int:
	return MapFormat.pack(texture, shape)

static func texture_of(v: int) -> int:
	return MapFormat.texture_of(v)

static func shape_of(v: int) -> int:
	return MapFormat.shape_of(v)


# ── 转发:文件读取(MapFormat)──
static func map_size() -> Vector2i:
	return MapFormat.map_size(map_file_path())

static func load_map_file() -> Array[Array]:
	return MapFormat.load_map_file(map_file_path())

static func parse_spawn_metadata(lines: Array) -> Dictionary:
	return MapFormat.parse_spawn_metadata(lines)

static func load_spawns() -> Dictionary:
	return MapFormat.load_spawns(map_file_path())


# ── 转发:环面几何(GridPathfinder)──
static func toroidal_dist(a: Vector2i, b: Vector2i, cols: int, rows: int) -> int:
	return GridPathfinder.toroidal_dist(a, b, cols, rows)

static func toroidal_delta_px(a: Vector2, b: Vector2, w: float, h: float) -> Vector2:
	return GridPathfinder.toroidal_delta_px(a, b, w, h)

static func toroidal_lerp(a: Vector2, b: Vector2, alpha: float, w: float, h: float) -> Vector2:
	return GridPathfinder.toroidal_lerp(a, b, alpha, w, h)

static func anchor_to_nearest(pos: Vector2, anchor: Vector2, w: float, h: float) -> Vector2:
	return GridPathfinder.anchor_to_nearest(pos, anchor, w, h)

static func wrap_to_range(pos: Vector2, w: float, h: float) -> Vector2:
	return GridPathfinder.wrap_to_range(pos, w, h)

static func copy_grid(grid: Array) -> Array[Array]:
	return GridPathfinder.copy_grid(grid)

static func cell_of(pos: Vector2, ts: int, cols: int, rows: int) -> Vector2i:
	return GridPathfinder.cell_of(pos, ts, cols, rows)


# ── 转发:地板格与寻路(GridPathfinder,网格取会话的 current_grid)──
static func is_floor_cell(grid: Array, cell: Vector2i) -> bool:
	return GridPathfinder.is_floor_cell(grid, cell)

static func is_floor_cell_with_headroom(grid: Array, cell: Vector2i) -> bool:
	return GridPathfinder.is_floor_cell_with_headroom(grid, cell)

static func astar_path_nearest(from_cell: Vector2i, to_cell: Vector2i, max_visit: int = 4000,
		passable_pred: Callable = Callable(), max_search_dist: int = -1) -> Array[Vector2i]:
	return GridPathfinder.astar_path_nearest(current_grid, from_cell, to_cell, max_visit, passable_pred, max_search_dist)

static func has_line_of_sight(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	return GridPathfinder.has_line_of_sight(current_grid, from_cell, to_cell)
