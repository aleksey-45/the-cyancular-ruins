extends RefCounted

# 画布叠加层(_draw 里调用;不进视口图):网格/选区/移动预览/meta 标记/渐变/画刷框/小地图。
# 无 class_name(调用方 preload)。函数体在 EditorCanvas._draw 期间执行,通过 c 的 draw_* 画到同一张画布;
# 状态一律从 c 读(相机/选区/meta/悬停),本文件不持有任何状态。

const SUB_PER_CELL := 4             # 1 格 = 4×4 子格(与 EditorConstants.SUB_PER_CELL 一致)


func draw_grid(c) -> void:
	var sub: Vector2i = c._sub_size()
	var x0 := floori(c._origin.x)
	var x1 := ceili(c._origin.x + c.size.x / c._zoom)
	for wx in range(x0, x1 + 1):
		var px: float = (float(wx) - c._origin.x) * c._zoom
		if px < -1.0 or px > c.size.x + 1.0:
			continue
		if sub.x > 0 and posmod(wx, sub.x) == 0:
			c.draw_line(Vector2(px, 0.0), Vector2(px, c.size.y), c.SEAM_COLOR, 2.0)
		elif posmod(wx, SUB_PER_CELL) == 0:
			c.draw_line(Vector2(px, 0.0), Vector2(px, c.size.y), c.GRID_COLOR, 1.0)
	var y0 := floori(c._origin.y)
	var y1 := ceili(c._origin.y + c.size.y / c._zoom)
	for wy in range(y0, y1 + 1):
		var py: float = (float(wy) - c._origin.y) * c._zoom
		if py < -1.0 or py > c.size.y + 1.0:
			continue
		if sub.y > 0 and posmod(wy, sub.y) == 0:
			c.draw_line(Vector2(0.0, py), Vector2(c.size.x, py), c.SEAM_COLOR, 2.0)
		elif posmod(wy, SUB_PER_CELL) == 0:
			c.draw_line(Vector2(0.0, py), Vector2(c.size.x, py), c.GRID_COLOR, 1.0)


## 选区:半透明填充 + 虚线框(屏幕像素,不随 zoom 变粗)。
func draw_selection(c) -> void:
	var r: Rect2 = c.selection_screen_rect()
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	c.draw_rect(r, c.SELECTION_FILL_COLOR)
	dashed_rect(c, r, c.SELECTION_LINE_COLOR, 1.5)


## 移动工具:拖动中的位移预览(半透明框 + 虚线 + 中心连线),松手才写 doc。
func draw_move_preview(c) -> void:
	if not c._moving_selection or c._doc == null or not c._doc.has_selection():
		return
	var r: Rect2 = c.selection_screen_rect()
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var moved := Rect2(r.position + Vector2(c._move_delta) * c._zoom, r.size)
	c.draw_rect(moved, Color(0.35, 0.90, 1.0, 0.10))
	var col := Color(1.0, 0.85, 0.35, 0.95)
	dashed_rect(c, moved, col, 1.5)
	c.draw_line(r.get_center(), moved.get_center(), Color(col.r, col.g, col.b, 0.35), 1.0)


func dashed_rect(c, r: Rect2, color: Color, width: float) -> void:
	c.draw_dashed_line(r.position, Vector2(r.end.x, r.position.y), color, width, 6.0)
	c.draw_dashed_line(Vector2(r.end.x, r.position.y), r.end, color, width, 6.0)
	c.draw_dashed_line(r.end, Vector2(r.position.x, r.end.y), color, width, 6.0)
	c.draw_dashed_line(Vector2(r.position.x, r.end.y), r.position, color, width, 6.0)


## meta 标记:出生点青方块 P1/P2…、复活点 R1 深绿 / R2 深橙、敌人 idle 贴图(未知类型回退红点)。
## 全部按屏幕像素画,缩放只改变标记位置,不改变标记大小。
func draw_meta(c) -> void:
	var markers: Array = c.meta_markers()
	if markers.is_empty():
		return
	var font: Font = ThemeDB.fallback_font
	for m: Dictionary in markers:
		var pos: Vector2 = m["pos"]
		# 移动工具拖拽中:该标记跟鼠标走(屏幕像素),松手才落回格坐标。
		var dragging := is_dragging_marker(c, m)
		if dragging:
			pos = c._mouse_pos
		var label := String(m["label"])
		match String(m["kind"]):
			"player":
				var col: Color = c.META_PLAYER_COLOR
				var box := Rect2(pos - Vector2(c.META_SQUARE, c.META_SQUARE) * 0.5,
						Vector2(c.META_SQUARE, c.META_SQUARE))
				c.draw_rect(box, col)
				c.draw_rect(box, Color(0.0, 0.0, 0.0, 0.75), false, 1.0)
				marker_text(c, font, pos + Vector2(c.META_SQUARE * 0.7, 4.0), label, col)
			"respawn":
				var col2: Color = c.META_RESPAWN1_COLOR if int(m["side"]) == 1 else c.META_RESPAWN2_COLOR
				var box2 := Rect2(pos - Vector2(c.META_SQUARE, c.META_SQUARE) * 0.5,
						Vector2(c.META_SQUARE, c.META_SQUARE))
				c.draw_rect(box2, col2)
				c.draw_rect(box2, Color(0.0, 0.0, 0.0, 0.75), false, 1.0)
				marker_text(c, font, pos + Vector2(c.META_SQUARE * 0.7, 4.0), label, col2)
			"enemy":
				# 敌人不再画成红点:直接用游戏里的 idle 贴图(默认动画首帧,尺寸 = 游戏内实际像素)。
				var art: Dictionary = c.enemy_art(String(m.get("type", "")))
				if not art.is_empty():
					var k: float = c._zoom / float(EditorConstants.SUB_PX)
					var sz: Vector2 = (art["size"] as Vector2) * k
					var org: Vector2 = (art["offset"] as Vector2) * k
					var art_rect := Rect2(pos - sz * 0.5 + org, sz)
					c.draw_texture_rect(art["tex"] as Texture2D, art_rect, false)
					# 格子中心留一个 2px 点:贴图会盖住格子边界,这个点让「到底放在哪一格」一眼可见。
					c.draw_circle(pos, 2.0, Color(1.0, 0.25, 0.25, 0.85))
					if dragging:
						c.draw_rect(art_rect, Color(1.0, 1.0, 1.0, 0.9), false, 1.5)
				else:
					c.draw_circle(pos, c.META_ENEMY_RADIUS, c.META_ENEMY_COLOR)
					c.draw_circle(pos, c.META_ENEMY_RADIUS, Color(0.0, 0.0, 0.0, 0.6), false, 1.0)
					marker_text(c, font, pos + Vector2(-c.META_ENEMY_RADIUS * 0.45, 4.0), label,
							Color(1.0, 1.0, 1.0, 1.0))
		if dragging:
			c.draw_circle(pos, c.META_HIT_RADIUS, Color(1.0, 1.0, 1.0, 0.9), false, 1.5)


func is_dragging_marker(c, m: Dictionary) -> bool:
	if c._dragging_meta.is_empty():
		return false
	return String(c._dragging_meta.get("kind", "")) == String(m.get("kind", "")) \
			and int(c._dragging_meta.get("index", -1)) == int(m.get("index", -2))


func marker_text(c, font: Font, at: Vector2, text: String, color: Color) -> void:
	if font == null or text == "":
		return
	c.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, c.META_FONT_SIZE, color)


## 渐变预览:从 a 到 b 的屏幕点画虚线 + 两端小圆点(a/b 异色)。只在 active 时画,只进 _draw。
func draw_gradient_preview(c) -> void:
	if not c._gradient_active:
		return
	var a: Vector2 = c.subcell_to_screen(c._gradient_a) + Vector2(c._zoom, c._zoom) * 0.5
	var b: Vector2 = c.subcell_to_screen(c._gradient_b) + Vector2(c._zoom, c._zoom) * 0.5
	c.draw_dashed_line(a, b, c.GRADIENT_LINE_COLOR, 2.0, 8.0)
	c.draw_circle(a, c.GRADIENT_DOT_RADIUS, c.GRADIENT_A_COLOR)
	c.draw_circle(b, c.GRADIENT_DOT_RADIUS, c.GRADIENT_B_COLOR)


func draw_brush(c) -> void:
	# meta 放置模式下不画画刷框(避免「放点模式还显示画笔框」)。
	if not c._has_hover or c._pan_tool or c._move_tool or c._meta_mode_active:
		return
	var sub: Vector2i = c._sub_size()
	if sub.x <= 0 or sub.y <= 0:
		return
	# 指针子格 → 格;画刷以格为中心(与 EditorTools.stamp_cell 的 brush_offsets 同源)。
	var cell := Vector2i(floori(float(c._hover_sub.x) / SUB_PER_CELL),
			floori(float(c._hover_sub.y) / SUB_PER_CELL))
	var off := EditorGeometry.brush_offsets(c._brush_cells)
	var top_left := Vector2i(cell.x - int(off["lo"]), cell.y - int(off["lo"]))
	var rect := Rect2(c.subcell_to_screen(top_left * SUB_PER_CELL),
			Vector2(float(c._brush_cells) * SUB_PER_CELL, float(c._brush_cells) * SUB_PER_CELL) * c._zoom)
	var tint: Color = c.ERASER_COLOR
	if EditorConstants.is_color_layer(c._active_layer):
		# 颜色层:橡皮(_preview_desc=0)保持红框;其余用工具层喂的当前画笔颜色。
		if c._preview_desc != 0:
			tint = c._preview_color
	elif c._preview_desc != 0:
		tint = TerrainAtlas.tint_color(Color.WHITE, c._preview_desc)
	c.draw_rect(rect, Color(tint.r, tint.g, tint.b, 0.20))
	c.draw_rect(rect, Color(tint.r, tint.g, tint.b, 0.95), false, 2.0)


# ── 小地图(右上角;纯叠加层,不进视口图)─────────────────────────────

## 底/边框 → meta 小点 → 当前视口矩形;缩放/平移/画布尺寸变化都按当前相机重算。
func draw_minimap(c) -> void:
	var r: Rect2 = c.minimap_rect()
	var sub: Vector2i = c._sub_size()
	if r.size.x <= 0.0 or r.size.y <= 0.0 or sub.x <= 0 or sub.y <= 0:
		return
	c.draw_rect(r, c.MINIMAP_BG_COLOR)
	c.draw_rect(r, c.MINIMAP_BORDER_COLOR, false, 1.0)
	draw_minimap_meta(c, r, sub)
	draw_minimap_viewport(c, r, sub)


## meta 小点:出生点 / 复活点(side 色)/ 敌人,颜色与画布标记同一套 META_* 常量;
## meta 标记被隐藏时小地图也不画点(与 meta_markers() 口径一致)。
func draw_minimap_meta(c, r: Rect2, sub: Vector2i) -> void:
	if not c._meta_visible or c._doc == null:
		return
	var map: Dictionary = c._doc.map
	if map.is_empty():
		return
	var players: Array = map.get("players", [])
	for i in players.size():
		var p: Variant = players[i]
		if p is Dictionary:
			var pd: Dictionary = p
			c.draw_circle(minimap_cell_point(r, sub,
					Vector2i(int(pd.get("x", 0)), int(pd.get("y", 0)))), c.MINIMAP_META_RADIUS,
					c.META_PLAYER_COLOR)
	var respawns: Array = map.get("respawns", [])
	for i in respawns.size():
		var rp: Variant = respawns[i]
		if rp is Dictionary:
			var rd: Dictionary = rp
			var color: Color = c.META_RESPAWN1_COLOR if int(rd.get("side", 0)) == 1 \
					else c.META_RESPAWN2_COLOR
			c.draw_circle(minimap_cell_point(r, sub,
					Vector2i(int(rd.get("x", 0)), int(rd.get("y", 0)))), c.MINIMAP_META_RADIUS, color)
	var enemies: Array = map.get("enemies", [])
	var enemy_color := Color(c.META_ENEMY_COLOR.r, c.META_ENEMY_COLOR.g, c.META_ENEMY_COLOR.b,
			c.MINIMAP_ENEMY_ALPHA)
	for i in enemies.size():
		var ep: Variant = enemies[i]
		if ep is Dictionary:
			var ed: Dictionary = ep
			c.draw_circle(minimap_cell_point(r, sub,
					Vector2i(int(ed.get("x", 0)), int(ed.get("y", 0)))),
					c.MINIMAP_META_RADIUS * 0.8, enemy_color)


## 格坐标 → 小地图内该格中心的屏幕点(按环面 posmod 归一,越界 meta 也画在图内)。
func minimap_cell_point(r: Rect2, sub: Vector2i, cell: Vector2i) -> Vector2:
	var world := Vector2(float(cell.x) * SUB_PER_CELL + SUB_PER_CELL * 0.5,
			float(cell.y) * SUB_PER_CELL + SUB_PER_CELL * 0.5)
	var frac := Vector2(fposmod(world.x, float(sub.x)) / float(sub.x),
			fposmod(world.y, float(sub.y)) / float(sub.y))
	return r.position + frac * r.size


## 当前视口矩形(origin..origin+size/zoom)映射进小地图;跨环面接缝时拆成多段。
func draw_minimap_viewport(c, r: Rect2, sub: Vector2i) -> void:
	if c._zoom <= 0.0:
		return
	var span: Vector2 = Vector2(c.size) / c._zoom
	var xs := wrap_intervals(fposmod(c._origin.x, float(sub.x)) / float(sub.x),
			span.x / float(sub.x))
	var ys := wrap_intervals(fposmod(c._origin.y, float(sub.y)) / float(sub.y),
			span.y / float(sub.y))
	for xi in xs.size():
		var xr: Vector2 = xs[xi]
		for yi in ys.size():
			var yr: Vector2 = ys[yi]
			var vr := Rect2(r.position + Vector2(xr.x, yr.x) * r.size,
					Vector2(maxf((xr.y - xr.x) * r.size.x, 1.0),
							maxf((yr.y - yr.x) * r.size.y, 1.0)))
			c.draw_rect(vr, c.MINIMAP_VIEW_COLOR, false, 1.0)


## 把 [start, start+length) 在 0..1 的环面上切成 1~2 段(长度 >= 1 = 整圈)。
func wrap_intervals(start: float, length: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if length <= 0.0:
		return out
	if length >= 1.0:
		out.append(Vector2(0.0, 1.0))
		return out
	var s := fposmod(start, 1.0)
	var l := minf(length, 1.0)
	if s + l <= 1.0:
		out.append(Vector2(s, s + l))
	else:
		out.append(Vector2(s, 1.0))
		out.append(Vector2(0.0, s + l - 1.0))
	return out
