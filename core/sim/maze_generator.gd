class_name MazeGenerator
extends RefCounted


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

static func set_map_file(path: String) -> void:
	_picked_map = path


# 当前世界的格子数(像素尺寸 = 它 × GameParameters.TILE_SIZE)。
# 网格已加载 ⇒ 网格尺寸;未加载(菜单态)⇒ 地图文件头。
# ★ 单一来源:此前 GameParameters 存两个可写字段,`_ready()` 按文件写一次、`world_builder`
#   加载网格后再写一次,两者之间没有一致性断言。现在没有任何地方写尺寸,读的地方只有这一个。
# ★ 缓存:网格分支是 O(1)(两次 size()),不缓存;文件分支要读盘,按路径缓存 —
#   `set_map_file` 换路径即失效。相机每帧、子弹每发都读这里,别让他们走 IO。
static var _file_cells := Vector2i.ZERO
static var _file_cells_path := ""
static var _file_cells_ready := false

static func world_cells() -> Vector2i:
	var grid := current_grid
	if not grid.is_empty() and not (grid[0] as Array).is_empty():
		return Vector2i((grid[0] as Array).size(), grid.size())
	var path := map_file_path()
	if not _file_cells_ready or path != _file_cells_path:
		_file_cells_path = path
		_file_cells = map_size()
		_file_cells_ready = true
	return _file_cells

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

static var current_grid: Array[Array] = []

# 当前关卡的 16px 子格纹理表(cyrm v4):逻辑读格级 `current_grid`,碰撞/破坏/渲染读这张表
# (见 docs/systems/gameplay/world.md 的 v4 / 子格一节);空 = 调用方自行从格级展开。
static var current_subgrid: Array[Array] = []

static var current_subdesc: Array[Array] = []


const EMPTY: int = MapFormat.EMPTY
const SOLID: int = MapFormat.SOLID

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


