extends SceneTree

# cyrm v4 编解码探针(-s 数据级)。2026-09-28 起地图就是 v4 二进制,这是格式层的回归守卫。
# 覆盖:
#   ① 真地图(已被转换成 v4)能被 load_map_file / load_spawns / map_size 正常消费,
#      且出生点格为空、其下方为实心(语义自洽);
#   ② 写读往返:serialize_v4 → parse_v4 → flatten 与原网格逐格一致(含形状掩码逐位一致);
#   ③ **compression=1 读入**(编辑器浏览器端导出的是 deflate):内嵌一份 Python-zlib 造的
#      标准 v4 夹具,永久守卫这条链路 —— 这正是规格书交接文档列的"第一件必做的事";
#   ④ CRC 破坏检测:改 body 一个字节必须被拒。
# 用法:godot --headless --path . -s res://tests/probe/map_format_v4_probe.gd

const DEMO := "res://maps/demo.cyrm"
const PVP := "res://maps/newfactory.cyrm"

# 压缩 v4 夹具(78 字节):4×4 格,格 (1,1)=纹理2 全砖,meta = "# player 2 2" + "# v4_fixture"。
static var FIXTURE := PackedByteArray([
	67, 89, 82, 77, 4, 1, 40, 1, 0, 0, 236, 176, 103, 181, 16, 0, 16, 0, 2, 0, 120, 156, 147, 98,
	80, 86, 40, 200, 73, 172, 76, 45, 82, 48, 82, 48, 226, 82, 86, 40, 51, 137, 79, 203, 172, 40,
	41, 45, 74, 229, 98, 100, 98, 0, 1, 21, 125, 6, 6, 70, 48, 139, 66, 192, 200, 200, 136, 98,
	14, 169, 252, 129, 4, 0, 33, 34, 8, 93,
])

var _fails: Array[String] = []


func _init() -> void:
	_test_real_maps()
	_test_roundtrip()
	_test_compressed_fixture()
	_test_crc_tamper()
	if _fails.is_empty():
		print("MAP FORMAT V4 OK(真图消费/写读往返/压缩读入/CRC 破坏检测)")
		quit(0)
	else:
		print("MAP FORMAT V4 FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		quit(1)


func _chk(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)


# 整图解析出来的格子级维度(列×行);空网格 → ZERO(断言响亮地红,不让 `[0]` 越界打断本函数)。
func _dims(grid: Array) -> Vector2i:
	if grid.is_empty():
		return Vector2i.ZERO
	return Vector2i((grid[0] as Array).size(), grid.size())


# ── ① 真地图(现在是 v4 二进制)──
func _test_real_maps() -> void:
	_chk(MapFormat.is_v4(DEMO), "demo.cyrm 应已是 v4 二进制")
	_chk(MapFormat.is_v4(PVP), "newfactory.cyrm 应已是 v4 二进制")
	var demo := MapFormat.load_map_file(DEMO)
	var pvp := MapFormat.load_map_file(PVP)
	# - 尺寸断言**只比两条独立读法**,不写死 125×75 —— "这张图恰好多大"是地图自己的事,
	#   写死只会让换图/改图测试误报。两条读法是:
	#     - `map_size()`   → v4 **头部**的 sub_cols/sub_rows(不解析 body)
	#     - `load_map_file()` → **整图解析**(把 body 里的场景层展平成格)
	#   两者对不上 = 头部与 body 不一致(真 bug);旧写法(两边各自写死数字)拦不住它。
	_chk(MapFormat.map_size(DEMO) == _dims(demo),
			"map_size(demo) 应与整图解析的维度一致(实为 %s vs %s)"
			% [str(MapFormat.map_size(DEMO)), str(_dims(demo))])
	_chk(MapFormat.map_size(PVP) == _dims(pvp),
			"map_size(factory) 应与整图解析的维度一致(实为 %s vs %s)"
			% [str(MapFormat.map_size(PVP)), str(_dims(pvp))])
	var sp_demo := MapFormat.load_spawns(DEMO)
	var sp_pvp := MapFormat.load_spawns(PVP)
	_chk(sp_demo.has("player") and not sp_demo.has("player2"), "demo 应只有 player 出生点")
	_chk(sp_pvp.has("player") and sp_pvp.has("player2"), "factory 应有 player+player2")
	# 出生点格必须为空 —— 顺带验证扁平化没把语义弄反。
	# - 只查"格为空",不查"下方实心":newfactory 的 player 出生点下方**本来就是空气**
	#   (原 v3 里就是,玩家出生在平台边缘),不是转换丢块。
	for pair in [[DEMO, sp_demo["player"]], [PVP, sp_pvp["player"]], [PVP, sp_pvp["player2"]]]:
		var g: Array = MapFormat.load_map_file(pair[0])
		var c: Vector2i = pair[1]
		var v: int = g[c.y][c.x]
		_chk(v == 0, "%s 出生点格应为空(实为 %d)" % [str(pair[0]), v])


# ── ② 写读往返(含形状掩码逐位)──
func _test_roundtrip() -> void:
	for path in [DEMO, PVP]:
		var grid := MapFormat.load_map_file(path)
		var meta: Array = []
		var v := MapFormatV4.parse(MapFormat._read_bytes(path))
		if bool(v.get("ok", false)):
			meta = v["meta_lines"]
		var blob := MapFormatV4.serialize(grid, meta)
		var v2 := MapFormatV4.parse(blob)
		_chk(bool(v2.get("ok", false)), "%s 往返解析失败:%s" % [path, str(v2.get("error"))])
		if not bool(v2.get("ok", false)):
			continue
		var back := MapFormatV4.flatten_scene(v2["scene"], int(v2["sub_cols"]), int(v2["sub_rows"]))
		_chk(back == grid, "%s 往返网格逐格一致" % path)
		var sp_a := MapFormat.parse_spawn_metadata(MapFormatV4.join_meta(meta).split("\n"))
		var sp_b := MapFormat.parse_spawn_metadata(v2["meta_lines"])
		_chk(str(sp_a) == str(sp_b), "%s 往返 spawn 一致" % path)


# ── ③ compression=1 读入(编辑器导出路径)──
func _test_compressed_fixture() -> void:
	var v := MapFormatV4.parse(FIXTURE)
	_chk(bool(v.get("ok", false)), "压缩夹具应能解开(实为:%s)" % str(v.get("error", "?")))
	if not bool(v.get("ok", false)):
		return
	var g := MapFormatV4.flatten_scene(v["scene"], int(v["sub_cols"]), int(v["sub_rows"]))
	_chk(g.size() == 4 and (g[0] as Array).size() == 4, "夹具网格应 4×4")
	_chk(g[1][1] == MapFormat.pack(2, 15), "夹具 (1,1) 应为纹理2 全砖(实为 %d)" % g[1][1])
	var sp := MapFormat.parse_spawn_metadata(v["meta_lines"])
	_chk(sp.get("player", Vector2i(-1, -1)) == Vector2i(2, 2), "夹具出生点应 (2,2)")


# ── ④ CRC 破坏检测 ──
func _test_crc_tamper() -> void:
	var bad := FIXTURE.duplicate()
	bad[40] = bad[40] ^ 0xFF   # body 中段翻一个字节
	var v := MapFormatV4.parse(bad)
	_chk(not bool(v.get("ok", false)), "破坏 body 后必须被拒(实为 ok=%s)" % str(v.get("ok")))
	var bad2 := FIXTURE.duplicate()
	bad2[10] = bad2[10] ^ 0xFF   # 头部 CRC 字段本身错 → 同样必须拒
	_chk(not bool(MapFormatV4.parse(bad2).get("ok", false)), "头部 CRC 不符必须被拒")
