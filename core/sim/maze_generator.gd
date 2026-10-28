class_name MazeGenerator
extends RefCounted

# 地图选择与查询入口；运行时数据由 NativeTerrain 持有。

const MAP_DIR: String = "res://maps"

# 优先读取可执行文件同级目录的 .cyrm 自定义地图，若无则从 res://maps/ 随机选取。
# 选中的地图在会话内保持，保证各处查询一致。
static var _picked_map: String = ""
static func map_file_path() -> String:
	if _picked_map != "":
		return _picked_map
	var ext := _random_cyrm(OS.get_executable_path().get_base_dir())
	_picked_map = ext if ext != "" else _random_cyrm(MAP_DIR)
	return _picked_map

# 显式指定地图文件路径（PvP 联机由服务端指定地图，客户端同步加载同名文件）。
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

# 快照只读。装载新地图使用 TileDefs.load_terrain()。
static var current_grid: Array[Array]:
	get: return TileDefs.terrain.get_grid_snapshot()
static var current_subgrid: Array[Array]:
	get: return TileDefs.terrain.get_subgrid_snapshot()

# 转发至 MapFormat：瓦片网格编解码
const EMPTY: int = MapFormat.EMPTY
const SOLID: int = MapFormat.SOLID  # pack(1, 15) = 纹理1 全砖

static func pack(texture: int, shape: int) -> int:
	return MapFormat.pack(texture, shape)

static func texture_of(v: int) -> int:
	return MapFormat.texture_of(v)

static func shape_of(v: int) -> int:
	return MapFormat.shape_of(v)


# 转发至 MapFormat：地图文件读取与出生点解析
static func map_size() -> Vector2i:
	return MapFormat.map_size(map_file_path())

static func load_map_file() -> Array[Array]:
	return MapFormat.load_map_file(map_file_path())

static func parse_spawn_metadata(lines: Array) -> Dictionary:
	return MapFormat.parse_spawn_metadata(lines)

static func load_spawns() -> Dictionary:
	return MapFormat.load_spawns(map_file_path())


# 转发至 GridPathfinder：环面几何距离计算
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


static func is_floor_cell(grid: Array, cell: Vector2i) -> bool:
	return GridPathfinder.is_floor_cell(grid, cell)

static func is_floor_cell_with_headroom(grid: Array, cell: Vector2i) -> bool:
	return GridPathfinder.is_floor_cell_with_headroom(grid, cell)

static func astar_path_nearest(from_cell: Vector2i, to_cell: Vector2i, max_visit: int = 4000,
		passable_pred: Callable = Callable(), max_search_dist: int = -1) -> Array[Vector2i]:
	return GridPathfinder.astar_path_nearest(current_grid, from_cell, to_cell, max_visit, passable_pred, max_search_dist)

static func has_line_of_sight(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	return TileDefs.terrain.line_of_sight_cells(from_cell, to_cell)
