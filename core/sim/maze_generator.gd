class_name MazeGenerator
extends RefCounted

# 地图与网格管理：负责选定地图路径与维护当前网格全局状态，具体格式与几何寻路分别委托给：
#   - MapFormat (core/sim/map_format.gd)：.cyrm 格式解析、序列化与出生点元数据；
#   - GridPathfinder (core/sim/grid_pathfinder.gd)：环面距离计算、地面检测与寻路。
# 本类保留既有兼容接口供外部调用，具体实现委托至对应专门类。

const MAP_DIR: String = "res://maps"

# ── 地图文件(.cyrm)──
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

# 当前关卡网格(level_0._ready 赋值;空网格时寻路一律视为无路)。
static var current_grid: Array[Array] = []

# 当前关卡的 16px 子格纹理表（cyrm v4 格式：逻辑层读取 64px current_grid，物理与渲染层读取此子格表）。
# 由 WorldBuilder.load_grid 与 current_grid 一起装填;空 = 调用方自行从格级展开。
static var current_subgrid: Array[Array] = []


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
