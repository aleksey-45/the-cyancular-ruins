extends SceneTree

# 地图目录与选图冒烟测试: 目录扫描、双出生点判定、缩略图生成与缓存、联机地图路径校验、出生点自动分配

const DEMO := "res://maps/demo.cyrm"          # 单人地图(包含 player 出生点)
const PVP := "res://maps/newfactory.cyrm"     # 双出生点地图(包含 player 与 player2 出生点)

var _fails: Array[String] = []


func _init() -> void:
	MapCatalog.clear_cache()
	_test_list()
	_test_names()
	_test_images()
	_test_resolve()
	_test_far_spawn()
	if _fails.is_empty():
		print("MAP CATALOG OK(目录/双出生点判定/显示名/简略图内容+缓存/联机定图校验/单人图自动分配出生点)")
		quit(0)
	else:
		print("MAP CATALOG FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		quit(1)


func _chk(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)


func _entry(maps: Array, path: String) -> Dictionary:
	for m in maps:
		if str(m["path"]) == path:
			return m
	return {}


# 通过完整解析地图文件获取瓦片网格维度(列数 × 行数)
func _grid_size(path: String) -> Vector2i:
	var grid := MapFormat.load_map_file(path)
	if grid.is_empty():
		return Vector2i.ZERO
	return Vector2i((grid[0] as Array).size(), grid.size())


# 阶段 1：目录扫描，验证基础地图存在且多人联机支持标记正确
func _test_list() -> void:
	_chk(MapCatalog.is_valid_map(DEMO), "demo.cyrm 应判为可用地图")
	var maps := MapCatalog.list_maps()
	_chk(maps.size() >= 2, "目录至少 2 张图(实为 %d)" % maps.size())
	var demo := _entry(maps, DEMO)
	var pvp := _entry(maps, PVP)
	_chk(not demo.is_empty(), "目录缺 demo.cyrm")
	_chk(not pvp.is_empty(), "目录缺 newfactory.cyrm")
	if demo.is_empty() or pvp.is_empty():
		return
	_chk(demo["pvp"] == MapFormat.load_spawns(DEMO).has("player2"),
			"demo.cyrm 的 pvp 标志应与地图元数据一致(实为 %s)" % str(demo["pvp"]))
	_chk(pvp["pvp"] == MapFormat.load_spawns(PVP).has("player2"),
			"newfactory.cyrm 的 pvp 标志应与地图元数据一致(实为 %s)" % str(pvp["pvp"]))
	_chk(demo["size"] == _grid_size(DEMO),
			"demo 尺寸应与整图解析维度一致(实为 %s,期望 %s)" % [str(demo["size"]), str(_grid_size(DEMO))])
	_chk(pvp["size"] == _grid_size(PVP),
			"newfactory 尺寸应与整图解析维度一致(实为 %s,期望 %s)" % [str(pvp["size"]), str(_grid_size(PVP))])
	_chk(demo["external"] == false, "内部地图 external 应为 false")
	_chk(not (DEMO in MapCatalog._scan("res://ui")), "扫描器不应将非地图目录识别为地图")


# 阶段 2：显示名称，读取头部注释中的名称定义
func _test_names() -> void:
	var d := MapCatalog.display_name(DEMO)
	_chk(d != "" and d != "demo", "demo 显示名应取头部注释定义(实为「%s」)" % d)
	var p := MapCatalog.display_name(PVP)
	_chk(p != "" and p != "newfactory", "newfactory 显示名应取头部注释定义(实为「%s」)" % p)
	print("MAP CATALOG: 显示名 demo=「%s」factory=「%s」" % [d, p])


# 阶段 3：缩略图生成，验证尺寸匹配、颜色丰富度、出生点标记与缓存有效性
func _test_images() -> void:
	var img := MapCatalog.build_image(DEMO)
	var sz: Vector2i = _entry(MapCatalog.list_maps(), DEMO)["size"]
	_chk(img.get_width() == sz.x * MapCatalog.CELL_PX and img.get_height() == sz.y * MapCatalog.CELL_PX,
			"简略图尺寸应为 %dx%d(实为 %dx%d)" % [sz.x * MapCatalog.CELL_PX, sz.y * MapCatalog.CELL_PX,
			img.get_width(), img.get_height()])
	var seen := {}
	for y in img.get_height():
		for x in img.get_width():
			seen[img.get_pixel(x, y)] = true
			if seen.size() >= 4:
				break
		if seen.size() >= 4:
			break
	_chk(seen.size() >= 3, "简略图应至少包含 3 种颜色(实为 %d)" % seen.size())
	_chk(_has_pixel(img, MapCatalog.SPAWN_P1), "简略图应绘制 P1 出生点色块")
	_chk(not _has_pixel(img, MapCatalog.SPAWN_P2), "单人地图不应包含 P2 出生点色块")
	var pvp := MapCatalog.build_image(PVP)
	_chk(_has_pixel(pvp, MapCatalog.SPAWN_P1) and _has_pixel(pvp, MapCatalog.SPAWN_P2),
			"newfactory 应同时包含 P1 与 P2 出生点色块")
	_chk(is_same(MapCatalog.build_image(DEMO), img), "相同地图多次生成应命中缓存返回同一 Image 实例")
	_chk(MapCatalog.CELL_PX == 2, "瓦片缩略图基础单位像素应为 2")


# 阶段 4：联机地图路径安全校验，仅接受 res://maps/*.cyrm 且具备双出生点的地图
func _test_resolve() -> void:
	_chk(MapCatalog.resolve_pvp_map(PVP) == PVP, "合规联机图应被接受")
	_chk(MapCatalog.resolve_pvp_map(DEMO) == "", "缺少 player2 的地图应被拒绝")
	_chk(MapCatalog.resolve_pvp_map("") == "", "空路径应被拒绝")
	_chk(MapCatalog.resolve_pvp_map("res://maps/../maps/newfactory.cyrm") == "", "包含路径穿越的路径应被拒绝")
	_chk(MapCatalog.resolve_pvp_map("res://maps/newfactory.txt") == "", "非 .cyrm 扩展名应被拒绝")
	_chk(MapCatalog.resolve_pvp_map("res://project.godot") == "", "maps 目录外的文件应被拒绝")
	_chk(MapCatalog.resolve_pvp_map("res://maps/nope.cyrm") == "", "不存在的文件应被拒绝")
	_chk(MapCatalog.resolve_pvp_map("C:/tmp/custom.cyrm") == "", "外部绝对路径应被拒绝")


# 阶段 5：单人地图在多人联机模式下的回退出生点算法
func _test_far_spawn() -> void:
	var grid := MapFormat.load_map_file(DEMO)
	var sp := MapFormat.load_spawns(DEMO)
	_chk(grid.size() > 0 and sp.has("player"), "demo 应包含网格与 player 出生点")
	if grid.is_empty() or not sp.has("player"):
		return
	var anchor: Vector2i = sp["player"]
	var cell: Vector2i = SpawnPicker.far_spawn_from(anchor, grid)
	_chk(cell.x >= 0 and cell.y >= 0, "应能分配有效的 role2 备选出生点(实为 %s)" % str(cell))
	if cell.x < 0:
		return
	_chk(int(grid[cell.y][cell.x]) == MapFormat.EMPTY, "自动出生格必须为空格")
	_chk(TileDefs.is_blocked(int(grid[(cell.y + 1) % grid.size()][cell.x])), "自动出生格下方必须为实体地面")
	var d := MazeGenerator.toroidal_dist(anchor, cell, grid[0].size(), grid.size())
	_chk(d >= 5, "自动出生格与 role1 之间应保持足够距离(实为 %d 格)" % d)
	print("MAP CATALOG: demo 的 role2 自动出生格 = %s(离 P1 %d 格)" % [str(cell), d])


# 逐通道容差比对颜色像素
func _has_pixel(img: Image, col: Color) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if absf(p.r - col.r) < 0.01 and absf(p.g - col.g) < 0.01 and absf(p.b - col.b) < 0.01:
				return true
	return false
