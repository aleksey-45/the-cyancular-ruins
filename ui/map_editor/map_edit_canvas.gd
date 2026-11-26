class_name MapEditCanvas
extends ColorRect

signal tool_pressed(cell: Vector2i, event: InputEventMouseButton, point_id: int)
signal zoom_changed(value: float)
signal cursor_moved(cell: Vector2i)

const COPIES := [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]
var session: MapEditSession
var brush: MapBrush
var cursor_width := 1
var point_hint := ""
var zoom := 6.0:
	set(value):
		zoom = clampf(value, 0.15, 64.0)
		zoom_changed.emit(zoom)
		refresh_view()
var origin := Vector2(20, 20):
	set(value):
		origin = value
		terrain.position = value
		markings.queue_redraw()
		preview.queue_redraw()
var grid := true
var subgrid := false
var torus := false
var guides := false
var dim_others := false
var mouse_cell := Vector2i(-1, -1)
var destination_point_id := -1
var _enemy_icons := {}
var _gesture := ""
var _on_release: Callable
var _points: Array[Vector2i] = []
var _tip: Vector2i:
	get: return mouse_cell.clamp(Vector2i.ZERO, session.map.size - Vector2i.ONE)
var terrain := UiFactory.shade(Color("#26363b"))
var _sky := Daylight.new()
var _map_layers := Node2D.new()
var _major_grid := UiFactory.shade(Color(0.75, 0.88, 0.85))
var _minor_grid := UiFactory.shade(Color(1, 1, 1, 0.12))
var preview_minute := -1.0:
	set(value):
		preview_minute = value
		_sky.visible = value >= 0.0
		_map_layers.modulate = _sky.set_minute(value) if _sky.visible else Color.WHITE
		markings.queue_redraw()
		preview.queue_redraw()
var markings := Node2D.new()
var preview := Node2D.new()
var planes: Array[Node2D] = []
var _tiles: Array[TileMapLayer] = [TileMapLayer.new(), TileMapLayer.new(), TileMapLayer.new()]
var _palette := TileSet.new()
var _source_ids: Dictionary[int, int] = {}

func _ready() -> void:
	for type: String in EnemyType.paths:
		var enemy: EnemyType = load(EnemyType.paths[type])
		var clip := &"sleeping" if enemy.frames.has_animation(&"sleeping") else &"sleep"
		var sprite := enemy.frames.get_frame_texture(clip, 0)
		_enemy_icons[type] = {"sprite": sprite, "image": sprite.get_image(), "scale": enemy.body_scale}
	clip_contents = true
	color = Color("#0e1519")
	focus_mode = Control.FOCUS_ALL
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	terrain.clip_contents = true
	add_child(terrain)
	_sky.visible = preview_minute >= 0.0
	UiFactory.cover(terrain, _sky)
	terrain.add_child(_map_layers)
	for tiles in _tiles:
		tiles.collision_enabled = false
		tiles.navigation_enabled = false
		tiles.occlusion_enabled = false
		planes.append(tiles)
	for layer in range(CyrmMap.FIRST_BACKGROUND, CyrmMap.LAYER_COUNT):
		var sprite := Sprite2D.new()
		sprite.centered = false
		planes.append(sprite)
	for i in range(planes.size() - 1, -1, -1):
		_map_layers.add_child(planes[i])
	var grid_material := ShaderMaterial.new()
	grid_material.shader = preload("res://ui/map_editor/grid.gdshader")
	for overlay in [_minor_grid, _major_grid]:
		overlay.material = grid_material
		UiFactory.cover(terrain, overlay)
	add_child(markings)
	markings.draw.connect(_draw_markings)
	add_child(preview)
	preview.draw.connect(_overlay)
	resized.connect(markings.queue_redraw)

func fit() -> void:
	if session == null or session.map.is_empty():
		return
	if size.x <= 64 or size.y <= 64:
		if not resized.is_connected(fit): resized.connect(fit)
		return
	if resized.is_connected(fit): resized.disconnect(fit)
	var extent := Vector2(session.map.size)
	zoom = minf((size.x - 64.0) / extent.x, (size.y - 64.0) / extent.y)
	origin = (size - extent * zoom) / 2.0

func zoom_at(factor: float, anchor := size / 2.0) -> void:
	var at := (anchor - origin) / zoom
	zoom *= factor
	origin = anchor - at * zoom

func center_on(cell: Vector2i) -> void:
	origin = size / 2.0 - _marker_center(cell, Vector2.ZERO)

func paint_cells(layer: int, changes: PackedInt32Array) -> void:
	if layer < 0:
		cancel()
		_palette = TileSet.new()
		_source_ids.clear()
		for tiles in _tiles:
			tiles.clear()
			tiles.tile_set = _palette
		fit()
		var width: int = session.map.size.x
		for index in _tiles.size():
			var cells: PackedInt32Array = session.map.layers[index]
			for i in cells.size():
				if cells[i]: _paint_tile(_tiles[index], Vector2i(i % width, i / width), cells[i])
		for index in range(CyrmMap.FIRST_BACKGROUND, CyrmMap.LAYER_COUNT):
			var sprite := planes[index] as Sprite2D
			sprite.texture = ImageTexture.create_from_image(TerrainAtlas.background_image(session.map, index))
	elif layer >= CyrmMap.FIRST_BACKGROUND:
		var sprite := planes[layer] as Sprite2D
		(sprite.texture as ImageTexture).update(TerrainAtlas.background_image(session.map, layer))
	else:
		for i in range(0, changes.size(), 3):
			_paint_tile(_tiles[layer], Vector2i(changes[i], changes[i + 1]), changes[i + 2])

func _paint_tile(tiles: TileMapLayer, cell: Vector2i, value: int) -> void:
	if CyrmMap.tile_material(value) == 0:
		tiles.erase_cell(cell)
		return
	# 材质和色调相同的子格共用图块图集。八档不透明度由 TileData.modulate.a 区分。
	var opaque := value | (7 << 9)
	var source: int = _source_ids.get(opaque, -1)
	if source < 0:
		var atlas := TileSetAtlasSource.new()
		_set_tile_image(atlas, opaque)
		for y in TerrainAtlas.SUBS_PER_TEXTURE:
			for x in TerrainAtlas.SUBS_PER_TEXTURE:
				var at := Vector2i(x, y)
				atlas.create_tile(at)
				for fade in range(1, 8):
					atlas.create_alternative_tile(at, fade)
					atlas.get_tile_data(at, fade).modulate.a = (7 - fade) / 7.0
		source = _palette.add_source(atlas)
		_source_ids[opaque] = source
	tiles.set_cell(cell, source, cell % TerrainAtlas.SUBS_PER_TEXTURE, 7 - CyrmMap.tile_tint(value).w)

func _set_tile_image(atlas: TileSetAtlasSource, opaque: int) -> void:
	atlas.texture_region_size = _palette.tile_size
	atlas.texture = ImageTexture.create_from_image(TerrainAtlas.tile_image(_palette.tile_size.x * TerrainAtlas.SUBS_PER_TEXTURE, opaque))

func refresh_view() -> void:
	if session == null or session.map.is_empty():
		return
	terrain.position = origin
	terrain.scale = Vector2.ONE * zoom
	terrain.size = Vector2(session.map.size)
	RenderingServer.canvas_set_item_repeat(terrain.get_canvas_item(), terrain.size if torus else Vector2.ZERO, 1)
	var spacing := 4
	while spacing * zoom < 14.0:
		spacing *= 2
	_major_grid.visible = grid
	_major_grid.color.a = 0.13 if spacing > 4 else 0.22
	_major_grid.set_instance_shader_parameter("spacing", float(spacing))
	_minor_grid.visible = subgrid and zoom >= 8.0
	var detail := 1 if zoom < 2.5 else (3 if zoom < 6 else 8)
	if _palette.tile_size.x != detail:
		_palette.tile_size = Vector2i.ONE * detail
		for opaque in _source_ids: _set_tile_image(_palette.get_source(_source_ids[opaque]), opaque)
		for tiles in _tiles: tiles.scale = Vector2.ONE / detail
	for layer in planes.size():
		planes[layer].modulate = Color(0.43, 0.46, 0.5) if dim_others and layer != session.layer else Color.WHITE
	markings.queue_redraw()
	preview.queue_redraw()

func _draw_markings() -> void:
	if session == null or session.map.is_empty(): return
	var dims: Vector2i = session.map.size
	var ids := session.point_ids()
	for i in (COPIES.size() if torus else 1):
		var corner := _copy_origin(i)
		var shape := Rect2(corner, Vector2(dims) * zoom)
		if not shape.intersects(Rect2(Vector2.ZERO, size)):
			continue
		if guides:
			for fraction: float in [1.0 / 3.0, 0.5, 2.0 / 3.0]:
				var p := corner + shape.size * fraction
				markings.draw_line(Vector2(p.x, corner.y), Vector2(p.x, shape.end.y), Color("#e0bd6e"))
				markings.draw_line(Vector2(corner.x, p.y), Vector2(shape.end.x, p.y), Color("#e0bd6e"))
		for id in ids:
			var selected := id == session.selected_point_id
			if selected and _gesture == "point_drag": continue
			var row: Dictionary = session.map.points[id]
			_draw_point(markings, row, _marker_center(row.cell, corner), selected)
		if i != 0:
			markings.draw_rect(shape, Color(0, 0, 0, 0.22))
		markings.draw_rect(shape, Color("#739b9c"), false, 1.0)

func _marker_center(cell: Vector2i, corner: Vector2) -> Vector2:
	return corner + Vector2(cell) * zoom

func _copy_origin(i: int) -> Vector2:
	return origin + Vector2(COPIES[i] * session.map.size) * zoom

func _point_at(event: InputEventMouse) -> int:
	if destination_point_id >= 0 or point_hint.is_empty() or event.alt_pressed or not session.bounds.has_point(mouse_cell):
		return -1
	# 选取离光标最近的命中点位。同距时优先保留已选点位，其余按绘制顺序取最上层。
	var best := -1
	var closest := INF
	var radius := clampf(zoom * 1.8, 5.0, 18.0)
	var ids := session.point_ids()
	ids.reverse()
	for id in ids:
		var item: Dictionary = session.map.points[id]
		var delta := event.position - _marker_center(item.cell, origin)
		var distance := delta.length_squared()
		if distance > radius * radius:
			if item.kind != "enemy" or zoom < 3.5:
				continue
			var icon: Dictionary = _enemy_icons[item.type]
			var sprite: Texture2D = icon.sprite
			var pixel := Vector2i((delta * 16.0 / (icon.scale * zoom) + sprite.get_size() / 2.0).floor())
			if not Rect2i(Vector2i.ZERO, sprite.get_size()).has_point(pixel) or icon.image == null or icon.image.get_pixelv(pixel).a <= 0.0:
				continue
		if distance < closest or (distance == closest and id == session.selected_point_id):
			best = id
			closest = distance
	return best

func _draw_point(target: Node2D, row: Dictionary, pos: Vector2, selected: bool, tint := Color.WHITE) -> void:
	if not Rect2(Vector2.ZERO, size).grow(10 * zoom + 8).has_point(pos): return
	var radius := clampf(zoom * 1.8, 4.0, 17.0)
	if row.kind == "enemy" and zoom >= 3.5:
		var icon: Dictionary = _enemy_icons[row.type]
		var sprite: Texture2D = icon.sprite
		var extent: Vector2 = sprite.get_size() * icon.scale * zoom / 16.0
		target.draw_texture_rect(sprite, Rect2(pos - extent / 2.0, extent), false, tint * _map_layers.modulate)
	else:
		var fill := Color("#f2d391")
		var letter := "P" if row.kind == "player" else "2"
		if row.kind == "enemy":
			fill = Color("#e8756c")
			letter = str(row.type).left(1).to_upper()
		elif row.kind == "respawn":
			fill = Color("#78d0a0") if row.side == 1 else Color("#849ff4")
			letter = str(row.side)
		target.draw_circle(pos, radius, fill * tint)
		if zoom >= 3:
			target.draw_string(PixelFont.FONT, pos + Vector2(-radius, radius * 0.55), letter,
				HORIZONTAL_ALIGNMENT_CENTER, radius * 2, maxi(10, int(radius * 1.5)), Color("#162430") * tint)
	if selected:
		target.draw_arc(pos, radius + 3, 0, TAU, 24, tint, 2)

func _screen_box(area: Rect2i) -> Rect2:
	return Rect2(origin + Vector2(area.position) * zoom, Vector2(area.size) * zoom)

func _cell_center(cell: Vector2i) -> Vector2:
	return origin + (Vector2(cell) + Vector2(0.5, 0.5)) * zoom

func _overlay() -> void:
	if session == null or session.map.is_empty(): return
	if _gesture == "point_drag":
		var row := session.selected_point()
		var cell := session.dragged_point_cell(row.cell, _points[0], _tip)
		for i in (COPIES.size() if torus else 1):
			var tint := Color.WHITE if i == 0 else Color(0.78, 0.78, 0.78)
			_draw_point(preview, row, _marker_center(cell, _copy_origin(i)), true, tint)
	var region := session.selection
	if _gesture == "select":
		region = MapEditSession.cell_box(_points[0], _tip)
	elif _gesture == "move":
		region.position += _tip - _points[0]
	if region.has_area():
		var rect := _screen_box(region)
		preview.draw_rect(rect, Color(0.16, 0.8, 0.83, 0.12))
		preview.draw_rect(rect, Color("#72e4dc"), false, 2.0)
	var ink := Color(0.98, 0.84, 0.44, 0.8)
	match _gesture:
		"brush", "erase", "line", "rect":
			for area in brush.stroke_regions(_drag_path(), session, _gesture):
				preview.draw_rect(_screen_box(area), ink)
		"gradient":
			preview.draw_line(_cell_center(_points[0]), _cell_center(_tip), ink, 2.0)
	if _gesture != "point_drag" and session.bounds.has_point(mouse_cell):
		var area := Rect2i(mouse_cell - Vector2i.ONE * (cursor_width / 2), Vector2i.ONE * cursor_width)
		preview.draw_rect(_screen_box(area), Color.WHITE, false, 1)

## 从当前鼠标子格开始预览拖动。松开时把拖动经过的子格传给回调，取消时丢弃预览。
func begin_drag(gesture: String, on_release: Callable) -> void:
	_gesture = gesture
	_on_release = on_release
	_points = [mouse_cell]
	if gesture == "point_drag":
		mouse_default_cursor_shape = Control.CURSOR_DRAG
		markings.queue_redraw()

func pick_point_destination(id := session.selected_point_id) -> void:
	cancel()
	destination_point_id = id
	mouse_default_cursor_shape = Control.CURSOR_CAN_DROP

func cancel() -> bool:
	var was_active := not _gesture.is_empty() or destination_point_id >= 0
	destination_point_id = -1
	_end_drag()
	return was_active

func _end_drag() -> void:
	if _gesture == "point_drag": markings.queue_redraw()
	_gesture = ""
	_on_release = Callable()
	_points = []
	mouse_default_cursor_shape = Control.CURSOR_CAN_DROP if destination_point_id >= 0 else Control.CURSOR_CROSS
	tooltip_text = ""
	preview.queue_redraw()

func _drag_path() -> Array[Vector2i]:
	if _points[-1] == _tip: return _points
	var path := _points.duplicate()
	path.append(_tip)
	return path

func _finish_drag() -> void:
	if not _on_release.is_valid() or (_gesture == "point_drag" and not session.bounds.has_point(mouse_cell)):
		_end_drag()
		return
	var finish := _on_release
	var path := _drag_path()
	_end_drag()
	finish.call(path)

func _gui_input(event: InputEvent) -> void:
	if session == null or session.map.is_empty():
		return
	if not event is InputEventMouseMotion and not event is InputEventMouseButton:
		return
	mouse_cell = Vector2i(((event.position - origin) / zoom).floor())
	if event is InputEventMouseMotion:
		if _gesture == "pan":
			origin += event.relative
		elif _gesture in ["brush", "erase"] and _points[-1] != _tip:
			_points.append(_tip)
		elif _gesture.is_empty() and destination_point_id < 0:
			var hover := _point_at(event) >= 0
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hover else Control.CURSOR_CROSS
			tooltip_text = point_hint if hover else ""
		cursor_moved.emit(mouse_cell)
		preview.queue_redraw()
		return
	if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		zoom_at(1.25 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8, event.position)
	elif event.button_index == MOUSE_BUTTON_MIDDLE or (event.pressed and event.button_index == MOUSE_BUTTON_LEFT and Input.is_physical_key_pressed(KEY_SPACE)):
		_end_drag()
		if event.pressed: _gesture = "pan"
	elif event.button_index == MOUSE_BUTTON_LEFT:
		grab_focus()
		if event.pressed:
			if not session.bounds.has_point(mouse_cell): return
			tool_pressed.emit(mouse_cell, event, _point_at(event))
		else:
			_finish_drag()
	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if not cancel(): session.selection = Rect2i()
	preview.queue_redraw()
	accept_event()
