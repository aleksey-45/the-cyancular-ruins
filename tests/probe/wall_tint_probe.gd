extends Node
# 墙体图集「按描述符行烘」守卫:make_wall_tileset_for / build_atlas_image_for 的行 = 描述符序列,

const MARKER := "WALL TINT PROBE: ALL-OK"
const EXPECTED_CHECKS := 4
const QUAD := 16        # TerrainAtlas.QUAD_TILE(图集每格 16px)
const QSRC := 8         # TerrainAtlas.QUAD_SRC(源象限 8px)

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var d_neutral := MapFormatV4.neutral_descriptor(1)
	var d_hue3 := _desc(1, 3, 4, 4, 7)            # 迁移后 tex2 的落点(base1 + hue 档 3)
	var descs: Array = [d_neutral, d_hue3]
	descs.sort()
	var built := TerrainAtlas.make_wall_tileset_for(descs)
	var row_of: Dictionary = built["row_of"]
	var tileset: TileSet = built["tileset"]
	var img := _tileset_image(tileset)

	# ① row_of = 传入序列的行号;图集尺寸 = 16 列 × descs.size() 行;瓦片都建出来了
	var ok: bool = img != null and row_of.size() == 2 \
			and int(row_of.get(descs[0], -1)) == 0 and int(row_of.get(descs[1], -1)) == 1
	if img != null:
		ok = ok and img.get_width() == TerrainAtlas.QUAD_COLS * QUAD \
				and img.get_height() == descs.size() * QUAD
		var src0 := tileset.get_source(0) as TileSetAtlasSource
		ok = ok and src0 != null and src0.has_tile(Vector2i(0, 0)) \
				and src0.has_tile(Vector2i(TerrainAtlas.QUAD_COLS - 1, descs.size() - 1))
	_chk(ok, "row_of 映射 / 图集尺寸 / 瓦片存在(实得 row_of=%s img=%s)" % [str(row_of),
			"null" if img == null else "%dx%d" % [img.get_width(), img.get_height()]])
	if img == null:
		_finish_rest(false)
		return

	# ② 两行像素必须不同(hue 档 3 对纹理 1 有效;烘培漏 tint = 两行同图)
	var differ := false
	for y in QUAD:
		for x in img.get_width():
			if not _close(img.get_pixel(x, y), img.get_pixel(x, y + QUAD), 1.0):
				differ = true
				break
		if differ:
			break
	_chk(differ, "中性行与 hue3 行像素必须不同(相同 = 烘培没消费描述符)")

	# ③ 逐像素 = tint_color(源象限像素, 该行描述符):列 = qy*4+qx、2× 最近邻(px/2)
	var src_img := TerrainAtlas.source_image()
	var bad: Array[String] = []
	for r in descs.size():
		var desc := int(descs[r])
		var rect := TerrainAtlas.source_rect(((desc >> 12) & 0xFFF) - 1)
		for q in TerrainAtlas.QUAD_COLS:
			var qy := q / 4
			var qx := q % 4
			for py in QUAD:
				for px in QUAD:
					var sp := src_img.get_pixel(rect.position.x + qx * QSRC + px / 2,
							rect.position.y + qy * QSRC + py / 2)
					var want := TerrainAtlas.tint_color(sp, desc)
					var got := img.get_pixel(q * QUAD + px, r * QUAD + py)
					if not _close(got, want, 1.0):
						if bad.size() < 3:
							bad.append("row%d col%d (%d,%d): %s != %s" % [r, q, px, py, str(got), str(want)])
	_chk(bad.is_empty(), "图集逐像素 = 源砖象限 tint_color(象限列映射 + 2× 最近邻)%s"
			% ["" if bad.is_empty() else ":" + "; ".join(bad)])

	# ④ 行号回落:命中直接给行;缺失回落**同纹理中性行**;中性也没有 → 0
	var d_missing := _desc(1, 5, 4, 4, 7)
	var d_missing_other := _desc(7, 5, 4, 4, 7)
	var ok4 := TerrainAtlas.fallback_row(row_of, d_hue3) == int(row_of[d_hue3]) \
			and TerrainAtlas.fallback_row(row_of, d_missing) == int(row_of[d_neutral]) \
			and TerrainAtlas.fallback_row(row_of, d_missing_other) == 0 \
			and TerrainAtlas.fallback_row({}, d_neutral) == 0
	_chk(ok4, "fallback_row:命中 / 缺失回落中性行 / 中性也缺 → 0")

	_finish_rest(true)


func _finish_rest(ran: bool) -> void:
	if not ran:
		_checks += 2   # ②③ 没跑:补计数让条数闸红,而不是静默 ALL-OK
		_fails.append("图集纹理读不到,②③ 未跑")
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("%s(%d 条断言):row_of 映射 · 两行不同 · 逐像素 tint · 行号回落" % [MARKER, _checks])
		get_tree().quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		# ★ 失败行绝不能含 "ALL-OK"(判据是 grep 那三个字)。
		print("WALL TINT PROBE: FAIL(%d 处)" % _fails.size())
		get_tree().quit(1)


func _desc(tex: int, hue: int, bri: int, sat: int, alpha: int) -> int:
	return (tex << 12) | ((alpha & 7) << 9) | ((sat & 7) << 6) | ((bri & 7) << 3) | (hue & 7)


func _tileset_image(tileset: TileSet) -> Image:
	if tileset == null or tileset.get_source_count() == 0:
		return null
	var src := tileset.get_source(0)
	if src == null or src.texture == null:
		return null
	return src.texture.get_image()


func _close(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) * 255.0 <= tol and absf(a.g - b.g) * 255.0 <= tol \
			and absf(a.b - b.b) * 255.0 <= tol and absf(a.a - b.a) * 255.0 <= tol
