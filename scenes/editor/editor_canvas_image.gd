extends RefCounted

# 画布视口图的合成:图集(按 descs 重建/缩放)+ 层号倒序把子格重放到 Image。
# 无 class_name(调用方 preload)。图集缓存/颜色图章仍挂在 EditorCanvas 上(c._atlas_*),本文件只操作它们。

const SUB_PER_CELL := 4             # 1 格 = 4×4 子格(与 EditorConstants.SUB_PER_CELL 一致)


## 层号倒序(背景 25% → 前景)把 world 矩形内的子格重放到 dst;shift 是屏幕平移量
## (全量 = 0;脏块 = -块左上角)。子格→屏幕像素公式与相机严格一致。
func paint_layers(c, dst: Image, sub: Vector2i, world: Rect2i, shift: Vector2i) -> void:
	if c._doc == null:
		return
	var layers: Array = c._doc.map.get("layers", [])
	for li in range(EditorConstants.LAYER_COUNT - 1, -1, -1):
		if li >= layers.size():
			continue
		var ld: Variant = layers[li]
		if ld == null:
			continue
		if not c.layer_visible(li):
			continue
		var alpha_mul: float = 1.0 if li == c._active_layer else c.INACTIVE_ALPHA
		if EditorConstants.is_color_layer(li):
			blit_color_layer(c, dst, ld, sub, world, alpha_mul, shift)
		else:
			blit_tex_layer(c, dst, ld, sub, world, alpha_mul, shift)


func blit_tex_layer(c, img: Image, ld: Dictionary, sub: Vector2i, vis: Rect2i, alpha_mul: float,
		shift: Vector2i) -> void:
	if c._atlas_scaled == null:
		return
	var cells: PackedInt32Array = ld.get("desc", PackedInt32Array())
	if cells.is_empty():
		return
	var z: int = c._atlas_scaled_cell
	var atlas_h: int = c._atlas_scaled.get_height()
	var src_img: Image = c._atlas_scaled if alpha_mul >= 0.999 else c._atlas_scaled_dim
	if src_img == null:
		src_img = c._atlas_scaled
	for dy in vis.size.y:
		var wy := vis.position.y + dy
		var sy := posmod(wy, sub.y)
		var qy4 := (sy % SUB_PER_CELL) * SUB_PER_CELL
		var dst_y := roundi((float(wy) - c._origin.y) * c._zoom)
		for dx in vis.size.x:
			var wx := vis.position.x + dx
			var sx := posmod(wx, sub.x)
			var idx := sy * sub.x + sx
			if idx < 0 or idx >= cells.size():
				continue
			var d := int(cells[idx])
			if d == 0:
				continue
			var row := int(c._atlas_row_of.get(d, -1))
			if row < 0:
				row = TerrainAtlas.fallback_row(c._atlas_row_of, d)
			if row < 0 or (row + 1) * z > atlas_h:
				continue
			var src := Rect2i((qy4 + (sx % SUB_PER_CELL)) * z, row * z, z, z)
			img.blend_rect(src_img, src,
					Vector2i(roundi((float(wx) - c._origin.x) * c._zoom) + shift.x, dst_y + shift.y))


func blit_color_layer(c, img: Image, ld: Dictionary, sub: Vector2i, vis: Rect2i, alpha_mul: float,
		shift: Vector2i) -> void:
	var cells: PackedInt32Array = ld.get("rgba", PackedInt32Array())
	if cells.is_empty():
		return
	var z := int(round(c._zoom))
	for dy in vis.size.y:
		var wy := vis.position.y + dy
		var sy := posmod(wy, sub.y)
		var dst_y := roundi((float(wy) - c._origin.y) * c._zoom)
		for dx in vis.size.x:
			var wx := vis.position.x + dx
			var idx := sy * sub.x + posmod(wx, sub.x)
			if idx < 0 or idx >= cells.size():
				continue
			var u := int(cells[idx]) & 0xFFFFFFFF
			if u == 0:
				continue
			var a := float(u & 0xFF) / 255.0 * alpha_mul
			if a <= 0.0:
				continue
			var col := Color8((u >> 24) & 0xFF, (u >> 16) & 0xFF, (u >> 8) & 0xFF,
					clampi(roundi(a * 255.0), 0, 255))
			img.blend_rect(stamp_for(c, col), Rect2i(0, 0, z, z),
					Vector2i(roundi((float(wx) - c._origin.x) * c._zoom) + shift.x, dst_y + shift.y))


func stamp_for(c, col: Color) -> Image:
	var key := "%d,%d,%d,%d" % [clampi(roundi(col.r * 255.0), 0, 255),
			clampi(roundi(col.g * 255.0), 0, 255), clampi(roundi(col.b * 255.0), 0, 255),
			clampi(roundi(col.a * 255.0), 0, 255)]
	if c._color_stamps.has(key):
		return c._color_stamps[key]
	var z := int(round(c._zoom))
	var stamp := Image.create(maxi(z, 1), maxi(z, 1), false, Image.FORMAT_RGBA8)
	stamp.fill(col)
	c._color_stamps[key] = stamp
	return stamp


# ── 图集(descs 变了才重建)─────────────────────────────────────────

func collect_descs(c) -> Array[int]:
	var out: Array[int] = []
	if c._doc == null:
		return out
	var map: Dictionary = c._doc.map
	if map.is_empty():
		return out
	var layers: Array = map.get("layers", [])
	var uniq := {}
	for li in range(0, mini(layers.size(), EditorConstants.LAYER_COUNT)):
		if EditorConstants.is_color_layer(li):
			continue
		var ld: Variant = layers[li]
		if ld == null:
			continue
		var cells: PackedInt32Array = (ld as Dictionary).get("desc", PackedInt32Array())
		for d in cells:
			var dd := int(d)
			if EditorDesc.tex_of(dd) != 0:
				uniq[dd] = true
	out.assign(uniq.keys())
	out.sort()
	return out


func ensure_atlas(c, force: bool = false) -> void:
	var descs := collect_descs(c)
	if not force and c._atlas_img != null and descs == c._atlas_descs:
		return
	c._atlas_descs = descs
	var built := TerrainAtlas.build_atlas_image_for(descs)
	c._atlas_img = built["image"]
	c._atlas_row_of = built["row_of"]
	c._atlas_scaled = null
	c._atlas_scaled_dim = null
	c._atlas_scaled_cell = 0


func ensure_scaled_atlas(c) -> void:
	var z := int(round(c._zoom))
	if c._atlas_img == null or z <= 0:
		return
	if c._atlas_scaled != null and c._atlas_scaled_cell == z:
		return
	var rows := maxi(1, c._atlas_img.get_height() / c.QUAD_TILE)
	var scaled: Image = c._atlas_img.duplicate()
	scaled.resize(c.QUAD_COLS * z, rows * z, Image.INTERPOLATE_NEAREST)
	c._atlas_scaled = scaled
	c._atlas_scaled_cell = z
	c._atlas_scaled_dim = scaled.duplicate()
	multiply_alpha(c._atlas_scaled_dim, c.INACTIVE_ALPHA)


func multiply_alpha(img: Image, mul: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var col := img.get_pixel(x, y)
			if col.a <= 0.0:
				continue
			img.set_pixel(x, y, Color(col.r, col.g, col.b, col.a * mul))


## 只在 changed 子格里判有没有图集里没有的新 desc;有则重建图集并返回 true。
func refresh_atlas_for(c, layer: int, subcells: PackedInt32Array) -> bool:
	if c._doc == null or EditorConstants.is_color_layer(layer):
		return false
	var layers: Array = c._doc.map.get("layers", [])
	if layer < 0 or layer >= layers.size() or layers[layer] == null:
		return false
	var cells: PackedInt32Array = (layers[layer] as Dictionary).get("desc", PackedInt32Array())
	for raw_idx in subcells:
		var idx := int(raw_idx)
		if idx < 0 or idx >= cells.size():
			continue
		var d := int(cells[idx])
		if EditorDesc.tex_of(d) != 0 and not c._atlas_row_of.has(d):
			ensure_atlas(c, true)
			return true
	return false
