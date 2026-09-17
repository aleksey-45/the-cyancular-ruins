extends Control

# 圆形小地图探针(**必须带真实渲染,不能加 --headless**)。
# 跑法: "$GODOT" --path . --quit-after 3600 res://tests/minimap_circle_probe.tscn
# 判据: 圆外的像素仍是背景色(discard 生效)+ 圆内有地形 + 敌人点只在范围内显示。
# PNG 落 res://.superpowers/sdd/(该目录自带 .gitignore = *,不入库)。
#
# ★ 判据为什么是这三个:圆形裁剪与"范围过滤"都是**数值断言抓不住**的东西 ——
#   旧实现(整图缩略贴右下角)在这三条里会挂一、二、四,而它看起来"功能正常"。
# ★ 背景故意铺品红:与地图三色(空气深/水蓝/墙灰)都不会撞,圆外只要不是品红就说明没裁干净。

const OUT_DIR := "res://.superpowers/sdd"
const PVP_HUD_SCENE := "res://ui/pvp_hud.tscn"
const BG := Color(1.0, 0.0, 1.0)          # 品红背景
const WALL := Color(0.62, 0.68, 0.75)     # ui/minimap.gd 里墙的颜色(半透明 alpha 0.95)

var _failures: Array[String] = []
var _local := Vector2(1600.0, 1600.0)     # 玩家 canonical 位置(格 25,25)
var _enemy := Vector2.INF


func _ready() -> void:
	Settings.pvp_minimap_show_enemy = true

	# 合成地图:250×150 全实心(整张都是墙色)。★ 尺寸必须与 GameParameters 的
	# MAP_WIDTH/HEIGHT 一致 —— 小地图把"格数"当贴图尺寸、把"世界像素"当坐标,
	# 两者不一致时圆里画的是错位的图(而断言可能照样绿)。
	# ★ 故意比真图(125×75 / 150×100)大一倍:下面要构造"环面最短距离在范围外"的样本,
	#   而那个距离受"地图半宽"封顶(超半宽就绕回来了)。图太小的话,RANGE_CELLS 调大一点
	#   就构造不出范围外样本 —— 断言会从"该红"变成"真绿"或反过来。
	const COLS := 250
	const ROWS := 150
	# ★ 底图**故意做成有结构的图案**(空底 + 每 8 列/6 行一道墙),不是"整张全实心":
	#   全实心取出来是一块均匀灰盘,人眼验收读不出"地形在 2.8px/格 下清不清楚" ——
	#   而那正是调过 RANGE_CELLS 之后**唯一需要人眼回答**的问题。
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		row.resize(COLS)          # resize 填 0 == MazeGenerator.EMPTY
		for x in range(COLS):
			if x % 8 == 0 or y % 6 == 0:
				row[x] = MazeGenerator.SOLID
		grid.append(row)
	# ★ MAP_WIDTH/HEIGHT 是 **int**(core/config/game_parameters.gd:22),别用浮点赋值
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = grid

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var mm := Minimap.new()
	mm.setup(func() -> Vector2: return _local, func() -> Vector2: return _enemy)
	add_child(mm)

	# ★ 两个样本距离都从 Minimap.RANGE_CELLS **推导**,不写死格数 ——
	#   写死的话调一次范围常量,这两条断言就可能悄悄翻面(本该红的变绿,或反之)。
	var ts := float(GameParameters.TILE_SIZE)
	var in_cells: float = minf(3.0, float(Minimap.RANGE_CELLS) * 0.5)
	var out_cells: float = float(Minimap.RANGE_CELLS) + 10.0
	_check(out_cells * ts < float(GameParameters.MAP_WIDTH) * 0.5,
			"合成地图够大,能构造出范围外样本(需要 < 半宽,实际 %.0f 格)" % out_cells)

	# ── ① 范围内的敌人点必须显示 ──
	_enemy = _local + Vector2(ts * in_cells, 0.0)
	await _frames(3)
	_check(mm._dot_enemy.visible, "范围内(%.0f 格)的敌人点应显示" % in_cells)

	# ── ② 范围外的敌人点必须不显示 ──
	_enemy = _local + Vector2(ts * out_cells, 0.0)
	await _frames(3)
	_check(not mm._dot_enemy.visible, "范围外(%.0f 格)的敌人点不得显示" % out_cells)

	# ── ③ 跨接缝:地图另一头、但环面距离在范围内的敌人**必须**显示 ──
	# 放到玩家左边整整一张图宽再回退 2 格 —— 直线距离 123 格,环面距离只有 2 格。
	_enemy = Vector2(_local.x - float(GameParameters.MAP_WIDTH) + ts * 2.0, _local.y)
	await _frames(3)
	_check(mm._dot_enemy.visible, "跨接缝 2 格的敌人点应显示(走环面最短向量)")

	# ── ⑤ 小地图的圆不得压到右下角的延迟条 ──
	# ★ 为什么单开这一条:小地图 layer 131 画在 PvpHud(130) **之上**,而两者都在右下角 ——
	#   2026-09-17 就是从"整图缩略 200px 高"换成"圆 280×280"时**盖住了延迟数字**
	#   (用户报「不要挡住下方的延迟」)。这条只有把两块 HUD 真摆在一起才测得出来。
	#   也在取图之前挂,好让 PNG 里能一眼看出圆和延迟条的间距。
	var pvp: CanvasLayer = (load(PVP_HUD_SCENE) as PackedScene).instantiate()
	add_child(pvp)
	# ★ 必须收掉它的全屏压暗罩:Mask 是一整块黑 0.3,会把下面④要验的"圆外=纯背景色"
	#   压成 (0.702,0,0.702) 而假红(实测踩到)。实机里小地图 layer 131 画在 Mask(130) 之上、
	#   不受它影响,所以收掉它并不改变本探针要验的东西。
	pvp._mask.visible = false
	pvp._on_ping(24)
	await _frames(3)
	var ping_label := pvp.get_node("PingWrap/PingLabel") as Label
	_check(ping_label.text == "24ms", "延迟条文案应为「24ms」而不是「延迟 24 ms」(实际「%s」)" % ping_label.text)
	var ping_rect: Rect2 = (pvp.get_node("PingWrap") as Control).get_global_rect()
	var c := _circle_center_on_screen()
	var r := Minimap.RADIUS_PX
	# 矩形上离圆心最近的点:若它落在圆内 → 圆压住了延迟条
	var q := Vector2(clampf(c.x, ping_rect.position.x, ping_rect.end.x),
			clampf(c.y, ping_rect.position.y, ping_rect.end.y))
	_check(c.distance_to(q) > r,
			"小地图的圆不得压到延迟条(圆心 %s / 半径 %.0f / 最近点 %s / 距离 %.1f)"
					% [str(c), r, str(q), c.distance_to(q)])

	# ── ④ 取图:圆外必须还是背景色,圆内必须出现地形 ──
	_enemy = Vector2.INF
	await _frames(2)
	var img := await _shot("minimap_circle.png")
	if img.get_width() > 0:
		var g := _circle_geom(img)
		# 圆的**外接方框**左上角往内 4px —— 在方框内、但在圆外(距圆心 ≈192px > 140)
		var outside := Vector2i(int(g["left"]) + 4, int(g["top"]) + 4)
		_check(_near(img.get_pixelv(outside), BG, 0.08),
				"圆外像素应仍是背景色(实际 %s)" % str(img.get_pixelv(outside)))
		# 圆内:地形真的画出来了。★ 判"墙色像素够多"而不是"某一点是墙色" ——
		#   底图现在有结构,某一点恰好落在空气上是正常的(而且玩家自己的点也画在圆心,
		#   采圆心会取到 SELF_COLOR,实测踩过)。
		#   墙色 alpha 0.95 压在品红上 → 实际像素是两者的合成,故给 0.12 容差。
		var wall_px := _count_near(img, g, WALL, 0.12)
		_check(wall_px > 500, "圆内应画出地形(墙色像素 %d,期望 > 500)" % wall_px)

	_finish()


# 圆心在**屏幕**坐标(未按取图缩放)。与 ui/minimap.gd 的常量保持一致:
# 右留白 EDGE、下留白 EDGE_BOTTOM(★ 两者不同 —— 下边要给延迟条让位)。
func _circle_center_on_screen() -> Vector2:
	var r: float = Minimap.RADIUS_PX
	return Vector2(1920.0 - Minimap.EDGE - r, 1440.0 - Minimap.EDGE_BOTTOM - r)


# 圆在取到的图上的几何
func _circle_geom(img: Image) -> Dictionary:
	var s := Vector2(img.get_width(), img.get_height()) / get_viewport().get_visible_rect().size
	var r: float = Minimap.RADIUS_PX
	var c := _circle_center_on_screen()
	var cx := c.x * s.x
	var cy := c.y * s.y
	return {"cx": cx, "cy": cy, "top": cy - r * s.y, "left": cx - r * s.x}


func _near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) < tol and absf(a.g - b.g) < tol and absf(a.b - b.b) < tol


# 圆**内部**(按 _circle_geom 给的圆心/半径)里接近给定颜色的像素数。
func _count_near(img: Image, g: Dictionary, want: Color, tol: float) -> int:
	var r: float = Minimap.RADIUS_PX
	var cx: float = g["cx"]
	var cy: float = g["cy"]
	var n := 0
	for y in range(int(cy - r), int(cy + r)):
		for x in range(int(cx - r), int(cx + r)):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if Vector2(float(x), float(y)).distance_to(Vector2(cx, cy)) > r:
				continue
			if _near(img.get_pixel(x, y), want, tol):
				n += 1
	return n


func _shot(png_name: String) -> Image:
	await _frames(2)
	var img := get_viewport().get_texture().get_image()
	if img == null or img.get_width() == 0:
		_failures.append("截图 %s 失败(是不是误加了 --headless?)" % png_name)
		return Image.new()
	var path := OUT_DIR.path_join(png_name)
	if img.save_png(path) != OK:
		_failures.append("截图 %s 写入失败(%s)" % [png_name, path])
	else:
		print("[MINIMAP] 已存 %s  %dx%d" % [
				ProjectSettings.globalize_path(path), img.get_width(), img.get_height()])
	return img


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[MINIMAP] ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[MINIMAP] ✗ %s" % msg)


func _finish() -> void:
	if _failures.is_empty():
		print("MINIMAP CIRCLE PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("MINIMAP CIRCLE PROBE: FAIL")
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)
