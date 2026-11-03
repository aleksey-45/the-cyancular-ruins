extends Node
# 水体/水面砖映射守卫(2026-11-01 用户报「把水体都变成水面了」)。

const MARKER := "WATER ATLAS PROBE: ALL-OK"
const EXPECTED_CHECKS := 6
const TS := 64          # GameParameters.TILE_SIZE(水体永远按 64px 整格渲染)
const SRC := 32         # 源砖边长 TerrainAtlas.SRC_TILE

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	# ① 常量 = 0-based 下标与纹理 id 的对应(纹理 id = 下标 + 1)
	_chk(TerrainAtlas.WATER_BODY_BRICK == 20 and TerrainAtlas.WATER_SURFACE_BRICK == 21,
			"★ 水砖下标必须是 20/21(0-based ⇒ 纹理 21 水 / 22 水面),实得 %d/%d" % [
				TerrainAtlas.WATER_BODY_BRICK, TerrainAtlas.WATER_SURFACE_BRICK])

	var body := _brick_stats(TerrainAtlas.WATER_BODY_BRICK)
	var surface := _brick_stats(TerrainAtlas.WATER_SURFACE_BRICK)

	# ② 水面砖的顶带必须比其余部分更亮(证明 22 是"带亮线的水面",不是纯色填充)
	_chk(float(surface["top_lum"]) >= float(surface["rest_lum"]) + 12.0,
			"★ 水面砖(纹理 22)顶带必须更亮:顶 %d 行亮度 %.1f,其余 %.1f" % [
				surface["top_rows"], surface["top_lum"], surface["rest_lum"]])

	# ③ 水体砖必须**没有亮带**且 alpha 恒定(深水里不该出现水面的亮线;把它画成水面正是用户报的症状)
	#   ★ 不判"逐像素同色":源砖本身带一点噪声(实测通道差 ≈58),真正的区别是"顶带是否更亮"。
	_chk(int(body["alpha_min"]) == int(body["alpha_max"])
			and float(body["top_lum"]) < float(body["rest_lum"]) + 8.0,
			"★ 水体砖(纹理 21)必须无亮带且 alpha 恒定:顶带-其余亮度差 %.1f、alpha %d..%d" % [
				float(body["top_lum"]) - float(body["rest_lum"]), body["alpha_min"], body["alpha_max"]])

	# ④ 两张放大图必须不同(合并成一个常量 = 同图 ⇒ 整片水一个观感)
	var body_img := TerrainAtlas.water_brick_image(TS, TerrainAtlas.WATER_BODY_BRICK)
	var surf_img := TerrainAtlas.water_brick_image(TS, TerrainAtlas.WATER_SURFACE_BRICK)
	_chk(_images_differ(body_img, surf_img),
			"★ 水体图与水面图必须是两张不同的图(实得同一张 = 两常量合并/缓存串味)")

	# ⑤ 水体图集必须由 BODY 砖构成(取 shape=15 那一列的中心像素与 BODY 砖中心比对)
	var tileset := TerrainAtlas.make_water_tileset(TS)
	var ts_img := _tileset_image(tileset)
	if ts_img == null:
		_chk(false, "water tileset 的 atlas 纹理读不到(期望 TileSetAtlasSource.texture)")
	else:
		var px := ts_img.get_pixel(15 * TS + TS / 2, TS / 2)
		var body_px := body_img.get_pixel(TS / 2, TS / 2)
		_chk(_channels_close(px, body_px, 2.0),
				"★ 水体图集必须用 BODY 砖:A16 图集中心 %s vs BODY 中心 %s" % [str(px), str(body_px)])

	# ⑥ 缓存键必须带 idx:先取 BODY 再取 SURFACE,两者不同;再取一次 BODY 仍等于第一次
	var body_again := TerrainAtlas.water_brick_image(TS, TerrainAtlas.WATER_BODY_BRICK)
	_chk(_images_differ(body_again, surf_img) and not _images_differ(body_again, body_img),
			"★ 水砖缓存必须按 idx 分开(否则水面会把水体那张图顶掉)")

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("%s(%d 条断言):下标映射 · 水面顶带更亮 · 水体均匀 · 两张图不同 · 图集用 BODY · 缓存按 idx 分开"
				% [MARKER, _checks])
		get_tree().quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		# ★ 失败行绝不能含 "ALL-OK"(判据是 grep 那三个字;写成 "ALL-OK: FAIL" 等于让红变绿)。
		print("WATER ATLAS PROBE: FAIL(%d 处)" % _fails.size())
		get_tree().quit(1)


# 统计一块源砖:整体通道最大差(均匀性)、alpha 范围、顶部 TOP_ROWS 行与其余行的平均亮度。
func _brick_stats(idx: int) -> Dictionary:
	const TOP_ROWS := 8
	var src := TerrainAtlas.source_image()
	var r: Rect2i = TerrainAtlas.source_rect(idx)
	var lo := 255.0
	var hi := 0.0
	var a_min := 255
	var a_max := 0
	var top_lum := 0.0
	var rest_lum := 0.0
	var top_n := 0
	var rest_n := 0
	for y in SRC:
		for x in SRC:
			var p := src.get_pixel(r.position.x + x, r.position.y + y)
			var mx := maxf(maxf(p.r, p.g), p.b)
			var mn := minf(minf(p.r, p.g), p.b)
			lo = minf(lo, mn)
			hi = maxf(hi, mx)
			var a := int(round(p.a * 255.0))
			a_min = mini(a_min, a)
			a_max = maxi(a_max, a)
			var lum := (p.r + p.g + p.b) / 3.0 * 255.0
			if y < TOP_ROWS:
				top_lum += lum
				top_n += 1
			else:
				rest_lum += lum
				rest_n += 1
	return {
		"max_channel_delta": (hi - lo) * 255.0,
		"alpha_min": a_min,
		"alpha_max": a_max,
		"top_rows": TOP_ROWS,
		"top_lum": top_lum / maxf(1.0, float(top_n)),
		"rest_lum": rest_lum / maxf(1.0, float(rest_n)),
	}


func _tileset_image(tileset: TileSet) -> Image:
	if tileset == null or tileset.get_source_count() == 0:
		return null
	var src := tileset.get_source(0)
	if src == null:
		return null
	var tex: Texture2D = src.texture
	if tex == null:
		return null
	return tex.get_image()


func _images_differ(a: Image, b: Image) -> bool:
	if a == null or b == null or a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return true
	for y in a.get_height():
		for x in a.get_width():
			if not _channels_close(a.get_pixel(x, y), b.get_pixel(x, y), 1.0):
				return true
	return false


func _channels_close(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) * 255.0 <= tol and absf(a.g - b.g) * 255.0 <= tol \
			and absf(a.b - b.b) * 255.0 <= tol and absf(a.a - b.a) * 255.0 <= tol
