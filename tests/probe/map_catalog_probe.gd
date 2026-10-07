extends SceneTree

# 地图目录/选图冒烟(-s 数据级):目录扫描 · 双出生点判定 · 开局简略图内容 · 联机定图路径校验 ·
# 单人图的 role2 出生点自动分配。
# 用法:godot --headless --path . -s res://tests/probe/map_catalog_probe.gd
#
# - 本探针刻意只用**数据层**(MapCatalog/MapFormat/MatchBootstrap 的静态函数)—— 选图 UI 的版式
#   与"点了真的进对图"由场景级 `tests/menu_autotest.gd` 的 sp 分支负责(它点真按钮)。

const DEMO := "res://maps/demo.cyrm"          # 单人图:只有 # player
const PVP := "res://maps/newfactory.cyrm"     # 双出生点图:多一句 # player2

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


# 地图的格子级维度(列×行),**整图解析**那条读法(`load_map_file`)。
# - 目录的 `size` 字段是 `MapCatalog` 用 `MapFormat.map_size`(v4 头部)算的 —— 拿它当期望
#   是自证;这条独立读法才是"这个字段到底对不对"的判据。空网格 → ZERO(断言会响亮地红,
#   而不是让 `[0]` 越界把整个函数打断)。
func _grid_size(path: String) -> Vector2i:
	var grid := MapFormat.load_map_file(path)
	if grid.is_empty():
		return Vector2i.ZERO
	return Vector2i((grid[0] as Array).size(), grid.size())


# ── ① 目录:两份现成地图都要在,且"能不能联机"要判对 ──
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
	# - 期望值**从地图自己派生**,不再写死"demo 恰好 125×75 / newfactory 恰好是双出生点图" ——
	#   写死的那两条**换一张图就虚假失败（测试用例误报）**,而它们真要拦的变异(目录项读错文件 / 两个条目互相串了)
	#   与尺寸具体是多少无关。期望值取自哪,逐条写在这里:
	#     - `pvp`  ← `MapFormat.load_spawns(path)`:地图 meta 里那两行 `# player` / `# player2`
	#       是"双出生点"的**唯一**来源,`MapCatalog.list_maps` 也只是把同一份 meta 折成布尔。
	#     - `size` ← `MapFormat.load_map_file(path)` 的**整图解析维度**,而**不是**
	#       `MapFormat.map_size` —— 后者正是 `MapCatalog.list_maps` 构造该字段时调的那一个,
	#       拿它当期望就是"同一表达式比自己"(自证),断言会无效操作。
	# 单人图(无 player2)不能当联机图:resolve_pvp_map 会拒,列表也要标出来
	_chk(demo["pvp"] == MapFormat.load_spawns(DEMO).has("player2"),
			"demo.cyrm 的 pvp 标志应与地图自己的 meta 一致(实为 %s)" % str(demo["pvp"]))
	_chk(pvp["pvp"] == MapFormat.load_spawns(PVP).has("player2"),
			"newfactory.cyrm 的 pvp 标志应与地图自己的 meta 一致(实为 %s)" % str(pvp["pvp"]))
	_chk(demo["size"] == _grid_size(DEMO),
			"demo 尺寸应与**整图解析**的维度一致(实为 %s,期望 %s)" % [str(demo["size"]), str(_grid_size(DEMO))])
	_chk(pvp["size"] == _grid_size(PVP),
			"newfactory 尺寸应与**整图解析**的维度一致(实为 %s,期望 %s)" % [str(pvp["size"]), str(_grid_size(PVP))])
	_chk(demo["external"] == false, "仓内地图 external 应为 false")
	_chk(not (DEMO in MapCatalog._scan("res://ui")), "扫描器不该把非地图目录当地图目录")


# ── ② 显示名:取文件头注释里的名字行(而非文件名)──
func _test_names() -> void:
	var d := MapCatalog.display_name(DEMO)
	_chk(d != "" and d != "demo", "demo 的显示名应取注释行(实为「%s」)" % d)
	var p := MapCatalog.display_name(PVP)
	_chk(p != "" and p != "newfactory", "newfactory 的显示名应取注释行(实为「%s」)" % p)
	print("MAP CATALOG: 显示名 demo=「%s」factory=「%s」" % [d, p])


# ── ③ 简略图:尺寸对得上、不是纯色、出生点画出来了、缓存命中 ──
func _test_images() -> void:
	var img := MapCatalog.build_image(DEMO)
	var sz: Vector2i = _entry(MapCatalog.list_maps(), DEMO)["size"]
	_chk(img.get_width() == sz.x * MapCatalog.CELL_PX and img.get_height() == sz.y * MapCatalog.CELL_PX,
			"简略图尺寸应 %dx%d(实为 %dx%d)" % [sz.x * MapCatalog.CELL_PX, sz.y * MapCatalog.CELL_PX,
			img.get_width(), img.get_height()])
	var seen := {}
	for y in img.get_height():
		for x in img.get_width():
			seen[img.get_pixel(x, y)] = true
			if seen.size() >= 4:
				break
		if seen.size() >= 4:
			break
	_chk(seen.size() >= 3, "简略图应至少有 3 种颜色(背景+墙+其它;实为 %d)" % seen.size())
	_chk(_has_pixel(img, MapCatalog.SPAWN_P1), "简略图里应画出 P1 出生点色块")
	# demo 没有 player2 → 不该有蓝点;factory 两者都要有
	_chk(not _has_pixel(img, MapCatalog.SPAWN_P2), "demo 不该有 P2 出生点色块")
	var pvp := MapCatalog.build_image(PVP)
	_chk(_has_pixel(pvp, MapCatalog.SPAWN_P1) and _has_pixel(pvp, MapCatalog.SPAWN_P2),
			"newfactory 应同时画出 P1/P2 出生点色块")
	_chk(is_same(MapCatalog.build_image(DEMO), img), "同一张图重复取应命中缓存(同一 Image 实例)")
	_chk(MapCatalog.CELL_PX == 2, "每格像素数变了(UI 版式按它算,改了要同步改标注)")


# ── ④ 联机定图校验:客户端上报的路径**只认仓内 res://maps/*.cyrm 且有双出生点** ──
func _test_resolve() -> void:
	_chk(MapCatalog.resolve_pvp_map(PVP) == PVP, "合规联机图应被接受")
	_chk(MapCatalog.resolve_pvp_map(DEMO) == "", "缺 player2 的图应被拒(联机出生点会叠一起)")
	_chk(MapCatalog.resolve_pvp_map("") == "", "空路径应被拒")
	_chk(MapCatalog.resolve_pvp_map("res://maps/../maps/newfactory.cyrm") == "", "含 .. 的路径应被拒")
	_chk(MapCatalog.resolve_pvp_map("res://maps/newfactory.txt") == "", "非 .cyrm 后缀应被拒")
	_chk(MapCatalog.resolve_pvp_map("res://project.godot") == "", "maps 目录外的文件应被拒")
	_chk(MapCatalog.resolve_pvp_map("res://maps/nope.cyrm") == "", "不存在的图应被拒")
	_chk(MapCatalog.resolve_pvp_map("C:/tmp/custom.cyrm") == "", "exe 旁的开发者地图不该用于联机(别的机器没有)")


# ── ⑤ 单人图当联机图时的补救:role2 拿到一个"够远"的地板格 ──
func _test_far_spawn() -> void:
	var grid := MapFormat.load_map_file(DEMO)
	var sp := MapFormat.load_spawns(DEMO)
	_chk(grid.size() > 0 and sp.has("player"), "demo 应有网格与 player 出生点")
	if grid.is_empty() or not sp.has("player"):
		return
	# - 直连 `SpawnPicker` 而**不是** `load("res://server/match/match_bootstrap.gd")`:
	#   后者静态引用 autoload(`GameParameters`/`NetBus`),在 `-s` 下**编译失败**  ->  `load()`
	#   拿到没有成员的 GDScript  ->  下面那几行**从来没跑过**,而 verdict 照打 OK。
	#   (2026-10-02 合并时发现;`far_spawn_from` 本体已一并搬进 `SpawnPicker`。)
	var anchor: Vector2i = sp["player"]
	var cell: Vector2i = SpawnPicker.far_spawn_from(anchor, grid)
	_chk(cell.x >= 0 and cell.y >= 0, "应能挑出 role2 的自动出生格(实为 %s)" % str(cell))
	if cell.x < 0:
		return
	_chk(int(grid[cell.y][cell.x]) == MapFormat.EMPTY, "自动出生格必须是空格")
	_chk(TileDefs.is_blocked(int(grid[(cell.y + 1) % grid.size()][cell.x])), "自动出生格下方必须是实心(地板)")
	var d := MazeGenerator.toroidal_dist(anchor, cell, grid[0].size(), grid.size())
	_chk(d >= 5, "自动出生格应离 role1 有距离(实为 %d 格)" % d)
	print("MAP CATALOG: demo 的 role2 自动出生格 = %s(离 P1 %d 格)" % [str(cell), d])


# - 逐通道容差比较,不能用 is_equal_approx:图是 RGBA8,set_pixel 的浮点值会被量化到 8 位
#   (0.35 → 89/255 = 0.34902),相对 1e-6 的 approx 判定必然不成立。
func _has_pixel(img: Image, col: Color) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if absf(p.r - col.r) < 0.01 and absf(p.g - col.g) < 0.01 and absf(p.b - col.b) < 0.01:
				return true
	return false
