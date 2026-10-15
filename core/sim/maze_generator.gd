class_name MazeGenerator
extends RefCounted

# 地图会话的入口:只放"选哪份地图 + 当前网格/子格表"这两件会话级状态,其余逐条一行转发 ——
# 格式(`.cyrm` 编解码/解析/序列化/spawn)→ `MapFormat`;环面几何与寻路 → `GridPathfinder`。
# 保留 `MazeGenerator.xxx` 的调用面(生产 ~57 个文件引用)是**刻意**的:新逻辑进那两个类,别在这里写实现。

const MAP_DIR: String = "res://maps"

# 先随机取 exe 旁的 .cyrm(外置自定义地图),否则随机取 `res://maps/*.cyrm`;选中后整个会话固定(缓存在
# `_picked_map`),保证 map_size / load_map_file / parse_spawn_metadata 读的是同一份。`set_map_file` 覆盖它。
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

# 当前关卡的 16px 子格纹理表(cyrm v4):逻辑读格级 `current_grid`,碰撞/破坏/渲染读这张表
# (见 docs/2026-09-20-cyrm-v4-handover.md §3 选项 A);空 = 调用方自行从格级展开。
static var current_subgrid: Array[Array] = []


# ── 转发:格子值编解码与文件读取(MapFormat)──
const EMPTY: int = MapFormat.EMPTY
const SOLID: int = MapFormat.SOLID  # pack(1, 15) = 纹理1 全砖

static func pack(texture: int, shape: int) -> int:
	return MapFormat.pack(texture, shape)

static func texture_of(v: int) -> int:
	return MapFormat.texture_of(v)

static func shape_of(v: int) -> int:
	return MapFormat.shape_of(v)

static func map_size() -> Vector2i:
	return MapFormat.map_size(map_file_path())

static func load_map_file() -> Array[Array]:
	return MapFormat.load_map_file(map_file_path())

static func parse_spawn_metadata(lines: Array) -> Dictionary:
	return MapFormat.parse_spawn_metadata(lines)

static func load_spawns() -> Dictionary:
	return MapFormat.load_spawns(map_file_path())


# ── 转发:环面几何 / 地板格 / 寻路(GridPathfinder)──
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
	return GridPathfinder.has_line_of_sight(current_grid, from_cell, to_cell)
