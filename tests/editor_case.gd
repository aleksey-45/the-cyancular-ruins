extends "res://tests/case.gd"

var _stone := CyrmMap.tile_value(7)

func run(tree: SceneTree) -> void:
	_format()
	_editing()
	_bucket_history()
	await _workflow(tree)

func _sample() -> Dictionary:
	var map := CyrmMap.create(Vector2i(48, 32))
	for layer in CyrmMap.LAYER_COUNT:
		var tile := PackedInt32Array([_stone, CyrmMap.tile_value(15, Vector4i(6, 4, 4, 7)),
				0, CyrmMap.tile_value(7, Vector4i(3, 4, 4, 7))])
		if layer >= CyrmMap.FIRST_BACKGROUND:
			tile = PackedInt32Array([0xFBDC9981, 0x123456FF, 0, 0xAAF09017])
		CyrmMap.write_cells(map, layer, [layer + 2, 2, tile[0], layer + 3, 2, tile[1],
				layer + 2, 3, tile[2], layer + 3, 3, tile[3]])
	var floor_tiles := PackedInt32Array()
	for x in range(1, 33): CyrmMap.append_cell(floor_tiles, x, 22, _stone)
	CyrmMap.write_cells(map, CyrmMap.SCENE, floor_tiles)
	map.notes = "# 测试地图\n# author note"
	map.points[0] = {"kind": "player", "cell": Vector2i(2, 3)}
	map.points[1] = {"kind": "player2", "cell": Vector2i(6, 3)}
	map.points[2] = {"kind": "enemy", "type": "jump_bird", "cell": Vector2i(9, 3)}
	map.points[3] = {"kind": "respawn", "side": 2, "cell": Vector2i(5, 4)}
	return map

func _format() -> void:
	var map := _sample()
	var large_id := 9007199254740993
	var notes := "# 雪原\n\n  第二行 🎲  "
	map.points[large_id] = {"kind": "enemy", "cell": Vector2i.ONE, "type": "fly_bird"}
	map.notes = notes
	var encoded := CyrmMap.to_bytes(map)
	expect(bytes_to_var(CyrmStorage.unpack(encoded)) == map, "the map file contains the document dictionary")
	var restored := CyrmMap.from_bytes(CyrmStorage.pack(var_to_bytes(map)))
	expect(restored == map and not is_same(restored, map), "all seven layers, 64-bit point IDs and Unicode notes round trip")
	var session := MapEditSession.new()
	session.open(restored, "")
	var respawn := {"kind": "respawn", "cell": Vector2i(2, 4), "side": 2}
	session.commit_point(large_id, respawn)
	expect(restored.points[large_id] == respawn and session.undo() and restored == map,
			"replacing a point's kind and undoing restores the complete document")
	expect(session.redo() and restored.points[large_id] == respawn, "redo replaces the same point ID")
	session.put_notes("first\n\nsecond")
	expect(session.undo() and restored.notes == notes and session.redo() and restored.notes == "first\n\nsecond",
			"undo and redo preserve the full notes text")
	var copy := CyrmMap.read_region(map, CyrmMap.FIRST_BACKGROUND, session.bounds)
	copy.fill(0)
	expect(copy != map.layers[CyrmMap.FIRST_BACKGROUND], "whole-layer reads are independent")
	var shades := PackedInt32Array()
	var painted := PackedInt32Array()
	for i in 300:
		shades.append(CyrmMap.tile_value(7, Vector4i(i % 8, (i / 8) % 8, i / 64, 7)))
		CyrmMap.append_cell(painted, i % 30, i / 30, shades[i])
	CyrmMap.write_cells(map, 0, painted)
	restored = CyrmMap.from_bytes(CyrmMap.to_bytes(map))
	expect(CyrmMap.read_region(restored, 0, Rect2i(0, 0, 30, 10)) == shades, "all authored descriptors round trip")
	var blank := CyrmMap.create(Vector2i.ONE)
	expect(CyrmMap.from_bytes(CyrmMap.to_bytes(blank)) == blank, "unfinished map saves without spawn markers")
	blank.layers[0][0] = CyrmMap.tile_value(999)
	encoded = CyrmMap.to_bytes(blank)
	expect(not encoded.is_empty() and CyrmMap.from_bytes(encoded).is_empty(), "material validation happens on load")
	blank.layers.pop_back()
	expect(CyrmMap.from_bytes(CyrmMap.to_bytes(blank)).is_empty(), "loading requires all seven layers")

func _editing() -> void:
	var s := MapEditSession.new()
	s.open(CyrmMap.create(Vector2i(16, 12)), "")
	var leaf := CyrmMap.tile_value(15)
	var sparse := PackedInt32Array([0, 0, _stone, 15, 11, _stone, 0, 0, leaf, 8, 5, 0])
	var notifications: Array[PackedInt32Array] = []
	s.cells_changed.connect(func(_layer: int, cells: PackedInt32Array) -> void: notifications.append(cells), CONNECT_ONE_SHOT)
	expect(s.put_cells(sparse) and notifications == [sparse] and CyrmMap.cell_at(s.map, s.layer, Vector2i.ZERO) == leaf
			and CyrmMap.cell_at(s.map, s.layer, Vector2i(15, 11)) == _stone, "write and forward the submitted order including repeated coordinates and equal values")
	expect(s.undo() and not s.dirty() and CyrmMap.cell_at(s.map, s.layer, Vector2i.ZERO) == 0
			and CyrmMap.cell_at(s.map, s.layer, Vector2i(15, 11)) == 0, "undo restores both cells to their values before the stroke")
	expect(s.redo() and CyrmMap.cell_at(s.map, s.layer, Vector2i.ZERO) == leaf and CyrmMap.cell_at(s.map, s.layer, Vector2i(15, 11)) == _stone, "redo restores the last value submitted at each coordinate")
	s.undo()
	expect(s.put_cells([0, 0, 0]) and s.dirty() and s.undo() and not s.dirty(), "a same-value submission has its own undo step")
	var brush := MapBrush.new()
	brush.material_id = 7
	brush.width = 5
	expect(brush.stroke([Vector2i.ZERO], s) and s._undo.back().cost == 9 * 12
			and s.map.layers[s.layer].count(_stone) == 9, "a five-cell brush at the corner submits just the 3x3 cells inside the map")
	s.undo()
	brush.width = 1
	brush.outline = true
	var rect: Array[Vector2i] = [Vector2i(2, 2), Vector2i(5, 5)]
	expect(brush.stroke(rect, s, "rect") and CyrmMap.read_region(s.map, 1, Rect2i(2, 2, 4, 4)).count(_stone) == 12, "outlined rectangle leaves interior empty")
	s.undo()
	var area := Rect2i(2, 2, 4, 4)
	expect(brush.stroke(rect, s, "line") and CyrmMap.read_region(s.map, 1, area).count(_stone) == 4, "diagonal line covers endpoints")
	var before := CyrmMap.read_region(s.map, 1, area)
	before[5] = CyrmMap.tile_value(15, Vector4i(1, 2, 3, 4))
	before[10] = 0
	s.put_cells([3, 3, before[5], 4, 4, before[10]])
	brush.tint_only = true
	brush.material_id = 0
	brush.tint = Vector4i(6, 1, 5, 0)
	var expected := before.duplicate()
	expected[0] = CyrmMap.tile_value(7, brush.tint)
	expected[5] = CyrmMap.tile_value(15, brush.tint)
	expected[15] = expected[0]
	expect(brush.stroke(rect, s) and CyrmMap.read_region(s.map, 1, area) == expected, "one tint-only stroke preserves stone, leaves and air even with air selected")
	expect(s.undo() and CyrmMap.read_region(s.map, 1, area) == before, "one undo restores the whole mixed-material stroke")
	expect(s.redo() and CyrmMap.read_region(s.map, 1, area) == expected, "redo restores all four tint channels")
	var reopened: Dictionary = CyrmMap.from_bytes(CyrmMap.to_bytes(s.map))
	expect(CyrmMap.read_region(reopened, 1, area) == expected, "the mixed-material stroke survives a CYRM round trip")
	brush.sample(s, Vector2i(3, 3))
	expect(brush.material_id == 15 and brush.tint == Vector4i(6, 1, 5, 0), "eyedropper preserves fully transparent material and all channels")
	brush.sample(s, Vector2i(4, 4))
	expect(brush.material_id == 0 and brush.tint == CyrmMap.NEUTRAL_TINT, "sampling air resets the material controls to neutral")
	expect(brush.stroke(rect, s, "erase") and CyrmMap.read_region(s.map, 1, Rect2i(2, 2, 4, 4)).count(0) == 16, "eraser clears the diagonal")
	s.open(CyrmMap.create(Vector2i(16, 12)), "")
	brush.material_id = 7
	brush.tint_only = false
	var path: Array[Vector2i] = [Vector2i(1, 1), Vector2i(5, 1), Vector2i(1, 1)]
	expect(brush.stroke(path, s), "freehand stroke commits")
	expect(s.undo() and not s.dirty() and not s.undo(), "self-overlapping stroke is one undo")
	expect(s.redo() and s.dirty(), "redo restores the stroke")
	s.mark_saved(s.path)
	s.selection = Rect2i(1, 1, 5, 1)
	expect(s.copy_selection(), "copy selected subcells")
	expect(s.move_selection(Vector2i(2, 0)), "move overlapping selection")
	expect(CyrmMap.read_region(s.map, 1, Rect2i(3, 1, 5, 1)).count(_stone) == 5, "overlapping move reads original values")
	s.undo()
	expect(not s.dirty(), "undo to save point clears dirty state")
	expect(s.paste(Vector2i(14, 3)), "paste clips at map edge")
	expect(CyrmMap.read_region(s.map, 1, Rect2i(14, 3, 2, 1)).count(_stone) == 2, "clipped clipboard dimensions")
	expect(not s.redo(), "new edit discards redo branch")
	var selection_before := s.selection
	s.locked[s.layer] = true
	expect(not s.paste(Vector2i.ZERO) and s.selection == selection_before, "a locked paste preserves the selection")
	s.locked[s.layer] = false
	s.layer = CyrmMap.LAYER_COUNT - 1
	expect(not s.paste(Vector2i.ZERO), "material clipboard cannot overwrite RGBA")
	brush.color = Color.RED
	brush.end_color = Color.BLUE
	s.selection = Rect2i()
	var segment: Array[Vector2i] = [Vector2i(1, 2), Vector2i(3, 2)]
	expect(not brush.gradient(segment, s), "gradient needs a selection")
	s.selection = Rect2i(1, 2, 3, 1)
	expect(brush.gradient(segment, s), "gradient writes selection")
	var colors := CyrmMap.read_region(s.map, s.layer, s.selection)
	brush.sample(s, segment[0])
	expect(brush.color == Color.RED and Color.hex(colors[2]) == Color.BLUE, "gradient endpoints and eyedropper preserve unsigned RGBA colors")
	s.mirror(true)
	expect(CyrmMap.read_region(s.map, s.layer, s.selection)[0] == colors[2], "horizontal mirror")
	brush.color = Color.WHITE
	s.selection = Rect2i(0, 4, 4, 4)
	expect(brush.bucket(Vector2i(0, 4), s) and CyrmMap.read_region(s.map, s.layer, s.selection).count(-1) == 16, "bucket obeys selection")
	expect(brush.bucket(Vector2i(0, 4), s) and s._undo.back().cost == 16 * 12,
			"a same-color fill visits and submits each connected cell once")
	s.locked[s.layer] = true
	expect(not s.clear_selection(), "locked layer prevents cut or clear")
	s.locked[s.layer] = false
	s.copy_selection()
	s.layer = CyrmMap.FIRST_BACKGROUND
	expect(s.paste(Vector2i.ZERO) and s.undo() and CyrmMap.cell_at(s.map, s.layer, Vector2i.ZERO) == 0
			and CyrmMap.cell_at(s.map, CyrmMap.LAYER_COUNT - 1, Vector2i(0, 4)) == -1, "copy between backgrounds and undo only on the destination")
	var enemy := s.place_point({"kind": "enemy", "cell": Vector2i(3, 2), "type": "jump_bird"})
	s.resize_map(Vector2i(2, 2))
	expect(not s.map.points.has(enemy), "shrink drops cropped point")
	s.undo()
	expect(s.map.size == Vector2i(16, 12) and s.map.points[enemy].cell == Vector2i(3, 2), "undo resize restores the same point and dimensions")

	s.open(CyrmMap.create(Vector2i(2, 1)), "")
	for i in 201:
		s.place_point({"kind": "player", "cell": Vector2i(i % 2, 0)})
	var point_bytes := MapEditSession.POINT_EDIT_BYTES
	expect(s._undo.size() == 200 and s._bytes == 200 * point_bytes, "trimming point history deducts the evicted edit")
	expect(s.undo() and s._bytes == 199 * point_bytes and s.redo() and s._bytes == 200 * point_bytes,
			"point undo and redo deduct and restore the fixed byte estimate")

func _bucket_history() -> void:
	var s := MapEditSession.new()
	var brush := MapBrush.new()
	var single := Vector2i(1234, 876)
	var map := CyrmMap.create(CyrmMap.MAX_SIZE)
	CyrmMap.write_cells(map, CyrmMap.SCENE, [single.x, single.y, _stone])
	s.open(map, "")
	var changed: Array[PackedInt32Array] = []
	s.cells_changed.connect(func(_layer: int, cells: PackedInt32Array) -> void: changed.append(cells))
	for i in 9:
		brush.material_id = 15 if i % 2 == 0 else 7
		brush.bucket(single, s)
	expect(changed.size() == 9 and changed.count(PackedInt32Array([single.x, single.y, _stone])) == 4
			and changed.count(PackedInt32Array([single.x, single.y, CyrmMap.tile_value(15)])) == 5, "nine isolated fills report only their changed cell and its new value")
	for i in 9: s.undo()
	expect(not s.dirty() and CyrmMap.cell_at(s.map, s.layer, single) == _stone, "all nine single-cell fills fit in undo history")

	s.open(CyrmMap.create(Vector2i(24, 16)), "")
	s.selection = Rect2i(8, 4, 9, 7)
	var area := Rect2i(10, 6, 3, 2)
	var before := PackedInt32Array([_stone, _stone, 0, _stone, 0, _stone])
	CyrmMap.write_cells(s.map, s.layer, [10, 6, _stone, 11, 6, _stone, 10, 7, _stone, 12, 7, _stone])
	brush.tint_only = true
	brush.tint = Vector4i(6, 4, 4, 7)
	var tint := CyrmMap.tile_value(7, brush.tint)
	var after := PackedInt32Array([tint, tint, 0, tint, 0, _stone])
	changed.clear()
	brush.bucket(area.position, s)
	expect(changed.size() == 1 and changed[0].size() == 9 and CyrmMap.read_region(s.map, s.layer, area) == after, "offset L-shaped fill reports three changed cells and preserves the hole and the disconnected tile")
	expect(s.undo() and CyrmMap.read_region(s.map, s.layer, area) == before and s.redo() and CyrmMap.read_region(s.map, s.layer, area) == after, "undo and redo replay the cropped fill as one edit")

func _mouse(canvas: MapEditCanvas, cell: Vector2i, down: bool, button := MOUSE_BUTTON_LEFT, modifiers := 0, twice := false) -> void:
	var event := InputEventMouseButton.new()
	event.position = canvas.get_global_transform_with_canvas() * (canvas.origin + (Vector2(cell) + Vector2(0.1, 0.1)) * canvas.zoom)
	event.button_index = button
	event.alt_pressed = bool(modifiers & KEY_MASK_ALT)
	event.shift_pressed = bool(modifiers & KEY_MASK_SHIFT)
	event.double_click = twice
	event.pressed = down
	canvas.get_viewport().push_input(event, true)

func _click_cell(canvas: MapEditCanvas, cell: Vector2i) -> void:
	_mouse(canvas, cell, true)
	_mouse(canvas, cell, false)

func _move_mouse(canvas: MapEditCanvas, cell: Vector2i) -> void:
	var event := InputEventMouseMotion.new()
	event.position = canvas.get_global_transform_with_canvas() * (canvas.origin + (Vector2(cell) + Vector2(0.1, 0.1)) * canvas.zoom)
	canvas.get_viewport().push_input(event, true)

func _click_button(button: Button) -> void:
	var at := button.get_global_transform_with_canvas() * (button.size * 0.5)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		button.get_viewport().push_input(event, true)

func _key(editor: MapEditor, code: Key, command := false, shift := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.ctrl_pressed = command and not OS.has_feature("macos")
	event.meta_pressed = command and OS.has_feature("macos")
	event.shift_pressed = shift
	event.pressed = true
	editor.get_viewport().push_input(event, true)
	event.pressed = false
	editor.get_viewport().push_input(event, true)

func _canvas_display(tree: SceneTree, editor: MapEditor) -> void:
	var s := editor.session
	var c := editor.canvas
	var map := CyrmMap.create(Vector2i(96, 96))
	CyrmMap.write_cells(map, CyrmMap.FRONT, [0, 0, _stone])
	var tinted := CyrmMap.tile_value(22, Vector4i(1, 6, 2, 3))
	CyrmMap.write_cells(map, CyrmMap.BACK, [1, 2, tinted])
	editor._files.open_document(map, "")
	var stroke := PackedInt32Array([0, 0, 1, 65, 66, tinted, 0, 0, _stone, 32, 32, 0])
	for apply: Callable in [s.put_cells.bind(stroke), s.undo, s.redo]:
		expect(apply.call(), "write, undo and redo submit the same stroke to the display")
		var present := CyrmMap.cell_at(map, s.layer, Vector2i.ZERO) == _stone
		var tiles := c._tiles[s.layer]
		var stone_id := c._tiles[CyrmMap.FRONT].get_cell_source_id(Vector2i.ZERO)
		var tinted_id := c._tiles[CyrmMap.BACK].get_cell_source_id(Vector2i(1, 2))
		expect(stone_id >= 0 and tinted_id >= 0 and stone_id != tinted_id
				and tiles.get_cell_source_id(Vector2i.ZERO) == (stone_id if present else -1)
				and tiles.get_cell_source_id(Vector2i(65, 66)) == (tinted_id if present else -1)
				and tiles.get_used_cells().size() == (2 if present else 0), "native tile layers follow edits in order and preserve other layers")
		if present:
			var cell := Vector2i(65, 66)
			expect(tiles.get_cell_atlas_coords(cell) == Vector2i(1, 2)
					and is_equal_approx(tiles.get_cell_tile_data(cell).modulate.a, 3.0 / 7.0), "material phase and tint opacity reach the tile")
	if DisplayServer.get_name() != "headless":
		s.layer = CyrmMap.LAYER_COUNT - 1
		for apply: Callable in [s.put_cells.bind(PackedInt32Array([3, 2, 0xeb286600, 4, 2, 0x12a8c4ad])), s.undo, s.redo]:
			expect(apply.call(), "color edit or history step commits")
			await RenderingServer.frame_post_draw
			var bytes := (c.planes[s.layer] as Sprite2D).texture.get_image().get_data()
			bytes.bswap32()
			expect(bytes.to_int32_array() == map.layers[s.layer], "color texture preserves all RGBA bytes on edit, undo and redo")
			await tree.process_frame
		s.layer = CyrmMap.SCENE
	var draws := [0, 0, 0]
	var terrain_draw := func() -> void: draws[0] += 1
	var markings_draw := func() -> void: draws[1] += 1
	var preview_draw := func() -> void: draws[2] += 1
	var ground := c.terrain.find_children("*", "CanvasItem", true, false)
	ground.append(c.terrain)
	for item: CanvasItem in ground: item.draw.connect(terrain_draw)
	c.markings.draw.connect(markings_draw)
	c.preview.draw.connect(preview_draw)
	for drag_point: bool in [false, true]:
		if drag_point:
			s.place_point({"kind": "respawn", "side": 1, "cell": Vector2i(3, 3)})
			editor._choose_tool("point")
			_mouse(c, Vector2i(3, 3), true)
		await tree.process_frame
		await tree.process_frame
		draws.fill(0)
		_move_mouse(c, Vector2i(5, 5))
		await tree.process_frame
		await tree.process_frame
		expect(draws[0] == 0 and draws[1] == 0 and draws[2] > 0, "brush hover or point drag redraws only the preview")
	_mouse(c, Vector2i(5, 5), false)
	for item: CanvasItem in ground: item.draw.disconnect(terrain_draw)
	c.markings.draw.disconnect(markings_draw)
	c.preview.draw.disconnect(preview_draw)

func _lighting_preview(editor: MapEditor) -> void:
	editor._files.open_document(CyrmMap.create(Vector2i(12, 180)), "")
	var canvas := editor.canvas
	canvas.zoom = 4
	canvas.origin = Vector2(200, 80)
	var edge := Vector2i(canvas.get_global_transform_with_canvas() * (canvas.origin + Vector2(0, 75.5) * canvas.zoom))
	var pixel := edge + Vector2i(8, 0)
	var outside := edge - Vector2i(4, 0)
	var screen := canvas.get_viewport().get_texture()
	await RenderingServer.frame_post_draw
	var raw := screen.get_image()
	canvas.preview_minute = 9 * 60
	await RenderingServer.frame_post_draw
	var morning := screen.get_image()
	expect(morning.get_pixelv(pixel) != raw.get_pixelv(pixel) and morning.get_pixelv(outside) == raw.get_pixelv(outside),
			"on a tall map the sky preview stops at the edge of the document")
	canvas.preview_minute = 0.0
	await RenderingServer.frame_post_draw
	expect(morning.get_pixelv(pixel).b > screen.get_image().get_pixelv(pixel).b + 0.4, "empty editor cells show the selected sky")
	canvas.preview_minute = -1.0
	await RenderingServer.frame_post_draw
	expect(screen.get_image().get_pixelv(pixel) == raw.get_pixelv(pixel), "closing the preview restores the original canvas color")

	var map := CyrmMap.create(Vector2i(24, 20))
	for x in 24: map.layers[CyrmMap.SCENE][10 * 24 + x] = _stone
	map.points[1] = {"kind": "lamp", "cell": Vector2i(0, 9), "tone": "warm"}
	editor._files.open_document(map, "")
	canvas.origin = Vector2(24, 20)
	canvas.zoom = 10
	canvas.torus = true
	canvas.grid = false
	canvas.refresh_view()
	canvas.preview_minute = 0.0
	await RenderingServer.frame_post_draw
	var page := canvas.terrain.get_viewport().get_texture()
	var lit := page.get_image()
	canvas._lamps.night = 0.0
	await RenderingServer.frame_post_draw
	var unlit := page.get_image()
	for cell: Vector2 in [Vector2(1.5, 10.5), Vector2(23.5, 10.5), Vector2(25.5, 30.5)]:
		var sample := Vector2i(canvas.terrain.get_global_transform_with_canvas() * cell)
		expect(lit.get_pixelv(sample).r > unlit.get_pixelv(sample).r + 0.02,
				"editor night preview lights the floor across the seam and on the repeated page at %s" % cell)
	canvas.preview_minute = -1.0
	canvas.torus = false
	canvas.grid = true
	canvas.refresh_view()

func _lamp_workflow(tree: SceneTree, editor: MapEditor) -> void:
	var s := editor.session
	var c := editor.canvas
	editor._files.open_document(_sample(), "")
	editor._set_layer(CyrmMap.SCENE)
	editor._choose_tool("point")
	c.zoom = 12
	c.origin = Vector2(50, 20)
	var types := editor._points._type
	var warm := editor._points._option_for({"kind": "lamp", "tone": "warm"})
	var cool := editor._points._option_for({"kind": "lamp", "tone": "cool"})
	types.select(warm)
	types.item_selected.emit(warm)
	var foot := Vector2i(16, 21)
	_click_cell(c, foot)
	var id := s.selected_point_id
	expect(id >= 0 and s.selected_point() == {"kind": "lamp", "cell": foot, "tone": "warm"}
			and editor._points.is_placing(), "the point palette places a warm street lamp and stays ready for the next one")
	var revision := s.revision
	_click_cell(c, foot)
	expect(s.revision == revision and editor._status.text.contains("重叠"), "overlapping lamps report the reason without making an undo step")
	_click_cell(c, foot + Vector2i.UP)
	expect(s.revision == revision and editor._status.text.contains("实心墙"), "a floating lamp is rejected")
	_click_button(editor._points.place_button)
	_mouse(c, foot + Vector2i.UP * 3, true)
	_mouse(c, foot + Vector2i(4, -3), false)
	foot += Vector2i(4, 0)
	expect(s.selected_point().cell == foot, "dragging the lantern by its upper housing moves its foot by the same offset")
	types.select(cool)
	types.item_selected.emit(cool)
	expect(s.selected_point().tone == "cool" and s.undo() and s.selected_point().tone == "warm"
			and s.redo() and s.selected_point().tone == "cool", "recolor and history retain the same lamp ID")
	var support := CyrmMap.lamp_support(foot, s.map.size)
	s.put_cells([foot.x, foot.y - 4, _stone])
	expect(not c._lamps._supports.has(support) and s.map.points.has(id)
			and CyrmMap.lamp_problem(s.map, foot, id).contains("五格"), "painting the top clearance leaves an invalid draft marker")
	expect(CyrmMap.from_bytes(CyrmMap.to_bytes(s.map)) == s.map and s.undo() and c._lamps._supports.has(support),
			"the invalid draft round trips and undo restores its fixture")
	s.put_cells([foot.x, foot.y + 1, CyrmMap.tile_value(21)])
	expect(not c._lamps._supports.has(support) and s.undo() and c._lamps._supports.has(support), "water cannot support the housing")
	c.preview_minute = 0.0
	c.grab_focus()
	_key(editor, KEY_F5)
	await tree.physics_frame
	var trial := editor._trial.trial
	expect(trial.spec.solo_spawn == SpawnPicker.single_spawn(s.map) and trial.preview_minute == 0.0
			and trial._view._canvas.lamps._supports.has(support), "F5 on a lamp uses the player spawn and the unsaved nighttime fixture")
	editor.finish_trial()
	c.preview_minute = -1.0
	_key(editor, KEY_DELETE)
	expect(not s.map.points.has(id) and s.undo() and s.map.points[id].tone == "cool", "delete and undo restore the lamp under its original ID")

func _canvas_tools(editor: MapEditor) -> void:
	var s := editor.session
	var c := editor.canvas
	editor._files.open_document(CyrmMap.create(Vector2i(16, 12)), "")
	var area := Rect2i(2, 2, 5, 1)
	var corner := Vector2i(6, 2)
	editor._pick_material(7)
	s.cells_changed.connect(func(_layer: int, _changes: PackedInt32Array) -> void:
		expect(not c.cancel(), "the canvas has closed the stroke before the tool commits it"), CONNECT_ONE_SHOT)
	_mouse(c, Vector2i(2, 2), true)
	_move_mouse(c, corner)
	expect(not s.dirty(), "freehand motion only previews a stroke")
	_mouse(c, Vector2i(6, 6), false)
	expect(CyrmMap.read_region(s.map, s.layer, area).count(_stone) == 5 and CyrmMap.read_region(s.map, s.layer, s.bounds).count(_stone) == 9, "release commits the bent path without a selection")
	editor._travel(editor.session.undo)
	editor._choose_tool("bucket")
	_mouse(c, Vector2i(2, 2), true)
	expect(CyrmMap.read_region(s.map, s.layer, s.bounds).count(_stone) == s.bounds.get_area(), "bucket fills the unselected map on press")
	_mouse(c, corner, false)
	editor._travel(editor.session.undo)
	expect(not s.dirty(), "a bucket release creates no second edit")
	editor._choose_tool("select")
	_mouse(c, Vector2i(2, 2), true)
	_mouse(c, corner, false)
	expect(s.selection == area and not s.dirty(), "box selection includes both endpoints without editing pixels")
	editor._choose_tool("bucket")
	_click_cell(c, Vector2i(6, 6))
	expect(not s.dirty(), "a seed outside the selection changes nothing")
	_click_cell(c, corner)
	var revision := s.revision
	_key(editor, KEY_C, true)
	expect(s.revision == revision and s.clip_size == area.size, "Copy is a command even while the bucket is active")
	_key(editor, KEY_X, true)
	expect(editor.active_tool == "bucket" and CyrmMap.read_region(s.map, s.layer, area).count(0) == 5, "Cut clears the box without switching tools")
	editor._travel(editor.session.undo)
	expect(CyrmMap.read_region(s.map, s.layer, s.bounds).count(_stone) == 5, "undo Cut restores only the clipped fill")
	editor._choose_tool("select")
	_mouse(c, Vector2i(2, 2), true)
	_mouse(c, Vector2i(2, 6), false)
	expect(s.selection.position == Vector2i(2, 6) and CyrmMap.read_region(s.map, s.layer, s.selection).count(_stone) == 5, "drag inside a selection moves its contents")
	_mouse(c, Vector2i(2, 6), true, MOUSE_BUTTON_LEFT, KEY_MASK_SHIFT)
	_mouse(c, Vector2i(6, 6), false)
	expect(s.selection == Rect2i(2, 6, 5, 1), "Shift starts a new box over the selected content")
	_mouse(c, corner, true, MOUSE_BUTTON_RIGHT)
	_mouse(c, corner, false, MOUSE_BUTTON_RIGHT)
	editor._choose_tool("gradient")
	revision = s.revision
	_click_cell(c, corner)
	expect(s.revision == revision and editor._status.text.contains("框选"), "the gradient requests its own selection")
	editor._choose_tool("select")
	_mouse(c, Vector2i(2, 2), true)
	_mouse(c, corner, false)
	editor._choose_tool("gradient")
	_mouse(c, Vector2i(2, 2), true)
	expect(s.revision == revision, "gradient press previews without writing")
	_mouse(c, corner, false)
	var colors := CyrmMap.read_region(s.map, CyrmMap.FIRST_BACKGROUND, area)
	expect(Color.hex(colors[0]) == editor.brush.color and Color.hex(colors[-1]) == editor.brush.end_color, "gradient release writes the selected endpoints")
	editor._pick_material(7)
	revision = s.revision
	_mouse(c, Vector2i(2, 2), true)
	_key(editor, KEY_G)
	_mouse(c, corner, false)
	expect(editor.active_tool == "bucket" and s.revision == revision, "changing tools cancels a pending stroke")

func _workspace_controls(editor: MapEditor) -> void:
	var s := editor.session
	var c := editor.canvas
	c.origin = Vector2(16, 16)
	c.zoom = 8
	expect(editor._materials_panel.buttons().size() == TileDefs.materials().size() + 1, "persistent palette covers every material and air")
	editor._set_layer(CyrmMap.BACK)
	editor._choose_tool("gradient")
	expect(editor._inspector.param_rows.color.visible and editor._inspector.param_rows.end_color.visible and not editor._inspector.param_rows.material.visible, "gradient shows its two color endpoints")
	for layer in range(CyrmMap.FIRST_BACKGROUND, CyrmMap.LAYER_COUNT):
		_click_button(editor._layers_panel.buttons()[layer])
		expect(s.layer == layer and editor.active_tool == "gradient", "gradient follows the selected background")
	_click_button(editor._materials_panel.buttons()[7])
	expect(s.layer == CyrmMap.BACK and editor.active_tool == "brush" and editor.brush.material_id == 7, "one palette click returns to painting on the last material layer")
	editor._choose_tool("line")
	_click_button(editor._materials_panel.buttons()[15])
	expect(editor.active_tool == "line" and editor._materials_panel.buttons()[15].button_pressed and not editor._materials_panel.buttons()[7].button_pressed, "choosing material keeps a compatible drawing tool")
	editor._choose_tool("rect")
	expect(editor._inspector.param_rows.outline.visible and not editor._inspector.param_rows.width.visible and not editor._inspector.param_rows.points.visible, "rectangle inspector only offers relevant settings")
	editor._choose_tool("erase")
	expect(editor._inspector.param_rows.width.visible and c.cursor_width == editor.brush.width and not editor._inspector.param_rows.material.visible, "eraser uses the brush width without an ink picker")
	editor._choose_tool("picker")
	expect(editor._inspector.param_rows.material.visible and c.cursor_width == 1 and not editor._inspector.param_rows.width.visible, "eyedropper displays the sampled ink at a single cell")
	_click_button(editor._materials_panel.buttons()[7])
	expect(editor.active_tool == "brush", "choosing a material after the eyedropper returns to painting")
	editor._choose_tool("select")
	expect(editor._inspector.param_rows.selection.visible and not editor._inspector.param_rows.color.visible, "selection has its own controls")
	editor._set_layer(CyrmMap.SCENE)
	_click_button(editor._materials_panel.buttons()[7])
	var enemy := CyrmMap.first_point_id(s.map, "enemy")
	var origin := Vector2i(9, 3)
	var destination := Vector2i(7, 4)
	var initial := s.revision
	c.zoom = 1
	_mouse(c, origin + Vector2i.RIGHT, true)
	_mouse(c, destination + Vector2i.RIGHT, false)
	expect(s.map.points[enemy].cell == destination, "grabbing the edge of a marker preserves the offset from its anchor")
	editor._travel(editor.session.undo)
	editor._choose_tool("brush")
	c.zoom = 8
	_mouse(c, origin, true)
	expect(editor.active_tool == "point" and s.selected_point().cell == origin and editor._points._details.visible, "grab a bird directly from the drawing tool")
	expect(editor._points._type.visible and editor._points._type.is_item_disabled(0), "selected bird offers only compatible type edits")
	_move_mouse(c, destination)
	expect(s.map.points[enemy].cell == origin and s.revision == initial, "drag preview leaves the document intact")
	_mouse(c, destination, false)
	expect(s.map.points[enemy].cell == destination and s.selected_point().cell == destination, "release commits marker destination")
	expect(editor._modified.visible, "unsaved indicator is independent of filename width")
	c.grab_focus()
	_key(editor, KEY_Z, true)
	expect(s.revision == initial and s.map.points[enemy].cell == origin, "the menu undo shortcut reverts the complete drag")
	_key(editor, KEY_Y, true)
	expect(s.map.points[enemy].cell == destination, "the alternate redo shortcut replays one move")
	_key(editor, KEY_Z, true)
	_key(editor, KEY_Z, true, true)
	expect(s.map.points[enemy].cell == destination, "the displayed redo shortcut replays one move")
	editor._travel(editor.session.undo)
	expect(not editor._modified.visible, "undo to saved state hides dirty indicator")
	_mouse(c, origin, true)
	_move_mouse(c, destination)
	_mouse(c, destination, true, MOUSE_BUTTON_RIGHT)
	_mouse(c, destination, false, MOUSE_BUTTON_RIGHT)
	_mouse(c, destination, false)
	expect(s.map.points[enemy].cell == origin and s.revision == initial, "cancelled drag never writes")
	_mouse(c, origin, true)
	_mouse(c, Vector2i(53, 38), false)
	expect(s.revision == initial and s.map.points[enemy].cell == origin, "releasing beyond the map cancels a point drag")
	var fly := -1
	for i in editor._points._type.item_count:
		if editor._points._type.get_item_metadata(i) == {"kind": "enemy", "type": "fly_bird"}: fly = i
	editor._points._type.select(fly)
	editor._points._type.item_selected.emit(fly)
	expect(s.map.points[enemy].type == "fly_bird" and s.selected_point().type == "fly_bird", "type choice updates the selected bird immediately")
	editor._travel(editor.session.undo)
	expect(s.selected_point().type == "jump_bird" and editor._points._type.get_selected_metadata().type == "jump_bird", "undo refreshes the canvas and the point inspector together")
	var list := editor._points._list
	var bird_row := list.get_selected_items()[0]
	s.put_notes("# editor notes")
	expect(s.selected_point_id == enemy, "editing notes keeps the selected point")
	s.place_point({"kind": "respawn", "cell": destination, "side": 2})
	expect(s.selected_point().is_empty() and list.get_item_metadata(bird_row + 1) == enemy, "inserting a row shifts the bird's display row but preserves its ID")
	editor._travel(editor.session.undo)
	expect(s.selected_point().is_empty() and list.get_item_metadata(bird_row) == enemy, "undo returns the same bird to its original row")
	var respawn := CyrmMap.first_point_id(s.map, "respawn")
	s.commit_point(respawn, {"kind": "respawn", "side": 1, "cell": origin})
	_click_cell(c, origin)
	var spawn_row := list.get_selected_items()[0] - 1
	list.grab_focus()
	_key(editor, KEY_UP)
	expect(list.is_selected(spawn_row) and s.selected_point().kind == "respawn", "list keyboard selection chooses the overlapping respawn for the canvas")
	_mouse(c, origin, true)
	_mouse(c, destination, false)
	expect(s.map.points[respawn].cell == destination and s.map.points[enemy].cell == origin, "only the chosen overlapping marker moves")
	expect(list.is_selected(spawn_row) and s.selected_point().cell == destination, "drag keeps the selected respawn row")
	var tint := Vector4i(1, 7, 2, 4)
	for i in 4: editor._inspector.tints[i].value = tint[i]
	_click_button(editor._materials_panel.buttons()[7])
	expect(editor.brush.tint == tint and editor.brush.material_id == 7, "palette and four inspector controls set independent brush fields")
	_mouse(c, origin, true, MOUSE_BUTTON_LEFT, KEY_MASK_ALT)
	_mouse(c, origin, false, MOUSE_BUTTON_LEFT, KEY_MASK_ALT)
	expect(editor.active_tool == "brush" and CyrmMap.read_region(s.map, CyrmMap.SCENE, Rect2i(origin, Vector2i.ONE))[0] == CyrmMap.tile_value(7, tint), "Alt paints the chosen material and tint under a marker")
	_click_button(editor._materials_panel.buttons()[15])
	for i in 4: editor._inspector.tints[i].value = 0
	editor._choose_tool("picker")
	_click_cell(c, origin)
	expect(editor.brush.material_id == 7 and editor._materials_panel.buttons()[7].button_pressed and not editor._materials_panel.buttons()[15].button_pressed, "eyedropper synchronizes palette selection")
	for i in 4: expect(editor._inspector.tints[i].value == tint[i], "eyedropper restores inspector channel %d" % i)
	editor._layers_panel.set_flag(false, CyrmMap.BACK, "visible")
	editor._layers_panel.set_flag(true, CyrmMap.BACK, "locked")
	expect(not c.planes[CyrmMap.BACK].visible and s.locked[CyrmMap.BACK] and s.layer == CyrmMap.SCENE, "per-row visibility and locking do not switch the active layer")
	editor._layers_panel.set_flag(true, CyrmMap.BACK, "visible")
	editor._layers_panel.set_flag(false, CyrmMap.BACK, "locked")
	editor._choose_tool("brush")

func _point_selection(tree: SceneTree, editor: MapEditor) -> void:
	editor._files.open_document(_sample(), "")
	var s := editor.session
	var c := editor.canvas
	var list := editor._points._list
	var inside := Vector2i(3, 4)
	var outside := Vector2i(10, 4)
	var outside_id := CyrmMap.first_point_id(s.map, "respawn")
	s.commit_point(outside_id, {"kind": "respawn", "side": 1, "cell": outside})
	var inside_id := s.place_point({"kind": "respawn", "side": 1, "cell": inside})
	editor._choose_tool("point")
	_click_cell(c, inside)
	expect(s.selected_point_id == inside_id and list.get_item_metadata(list.get_selected_items()[0]) == inside_id, "canvas and list select the same respawn ID")
	s.resize_map(Vector2i(7, 8))
	expect(s.selected_point().is_empty() and s.map.points[inside_id].cell == inside, "crop retains the surviving point in the map and clears selection")
	editor._travel(editor.session.undo)
	expect(s.selected_point().is_empty() and s.map.points[outside_id].cell == outside, "undo crop restores the original point without selecting it")
	_click_cell(c, inside)
	var option := editor._points._type.selected
	list.grab_focus()
	_key(editor, KEY_F5)
	expect(editor._trial.trial.spec.solo_spawn == inside, "F5 starts at the point the user just picked")
	_key(editor, KEY_ESCAPE)
	await tree.process_frame
	expect(editor._trial.trial == null and s.selected_point().cell == inside, "returning from the trial preserves the same list selection")
	_mouse(c, Vector2i(0, 7), true, MOUSE_BUTTON_LEFT, 0, true)
	expect(editor._trial.trial != null and editor._trial.trial.spec.solo_spawn == Vector2i(0, 7), "double-clicking empty space in point mode trials the clicked cell")
	editor.finish_trial()
	_mouse(c, Vector2i(0, 7), false)

	_click_button(editor._points.place_button)
	expect(c.point_hint.is_empty(), "entering continuous placement clears the drag hint immediately")
	editor._points._type.select(option)
	_click_cell(c, inside)
	var twin := s.selected_point_id
	expect(twin != inside_id and s.map.points[twin] == s.map.points[inside_id] and editor._points.place_button.button_pressed, "identical respawns have distinct IDs and continuous placement stays active")
	_mouse(c, inside, true, MOUSE_BUTTON_LEFT, 0, true)
	_mouse(c, inside, false)
	expect(editor._trial.trial == null and s.selected_point_id != twin and s.selected_point() == s.map.points[twin], "the second press of a double-click places another marker in continuous mode")
	editor._travel(editor.session.undo)
	editor._travel(editor.session.undo)
	expect(s.selected_point().is_empty() and not s.map.points.has(twin) and s.map.points[inside_id].cell == inside, "undo removes just the placed twin")
	editor._travel(editor.session.redo)
	expect(s.selected_point().is_empty() and s.map.points[twin].cell == inside, "redo restores the same ID without selecting it")
	var revision := s.revision
	var player: Vector2i = s.map.points[CyrmMap.first_point_id(s.map, "player")].cell
	editor._points._type.select(0)
	_click_cell(c, player)
	expect(s.selected_point().kind == "player" and s.revision == revision, "placing the existing single spawn selects its row without adding history")

	editor._choose_tool("point")
	expect(c.point_hint == MapEditor.POINT_HINT, "leaving continuous placement restores the drag hint")
	_click_cell(c, outside)
	s.resize_map(Vector2i(7, 8))
	expect(s.selected_point().is_empty() and not editor._points._details.visible, "cropping the selected point clears the inspector")
	editor._travel(editor.session.undo)
	_click_cell(c, outside)
	_key(editor, KEY_DELETE)
	expect(not s.map.points.has(outside_id) and s.selected_point().is_empty(), "Delete removes only the selected ID and clears selection")
	editor._travel(editor.session.undo)
	expect(s.map.points[outside_id].cell == outside and s.selected_point().is_empty(), "undo delete restores the original ID without reviving a stale selection")
	_click_cell(c, inside)
	_key(editor, KEY_DELETE)
	_click_cell(c, inside)
	editor._travel(editor.session.undo)
	expect(s.selected_point().is_empty(), "restoring an indistinguishable twin does not silently select another row")
	_click_cell(c, inside)
	_click_cell(c, Vector2i(0, 7))
	expect(s.selected_point().is_empty() and not editor._points._details.visible, "clicking empty space clears the list and point inspector")
	_key(editor, KEY_F5)
	expect(editor._trial.trial.spec.solo_spawn == player, "F5 falls back to the normal spawn when selection is empty")
	editor.finish_trial()
	_click_cell(c, player)
	editor._files.open_document(_sample(), "")
	expect(s.selected_point().is_empty(), "opening a document clears the previous map's point selection")

func _size_dialogs(tree: SceneTree, editor: MapEditor) -> void:
	editor._files.size_dialog(false)
	var dialog: ConfirmationDialog = editor.get_child(-1)
	var fields := dialog.find_children("*", "SpinBox", true, false)
	fields[0].value = 49
	dialog.confirmed.emit()
	dialog.hide()
	await tree.process_frame
	expect(editor.session.map.size == Vector2i(49, 32), "resize is available from the editor dialog")
	editor._travel(editor.session.undo)
	expect(editor.session.map.size == Vector2i(48, 32), "dialog resize remains one undo")
	editor._files.size_dialog(true)
	dialog = editor.get_child(-1)
	fields = dialog.find_children("*", "SpinBox", true, false)
	fields[0].value = 20
	fields[1].value = 10
	dialog.confirmed.emit()
	dialog.hide()
	await tree.process_frame
	expect(editor.session.map.size == Vector2i(20, 10) and not editor.session.dirty(), "new map dialog creates the chosen dimensions")

func _mode_limits(editor: MapEditor) -> void:
	var map := CyrmMap.load_file("res://maps/newfactory.cyrm")
	var sides := SpawnPicker.respawn_cells(map)
	map.points = {0: {"kind": "respawn", "side": 1, "cell": sides[1][0]}}
	editor._files.open_document(map, "")
	editor._validate()
	expect(editor._status.text.contains("大乱斗：点位不足，至少需要 2 人")
			and not WorldSpec.arena(map, WorldSpec.ROYALE, [1, 2], {}, {}, 0).problem().is_empty(), "one valid spawn is insufficient in both the editor and a two-player Royale")
	map.points[1] = {"kind": "respawn", "side": 2, "cell": sides[2][0]}
	editor._validate()
	expect(editor._status.text.contains("1v1：通过") and editor._status.text.contains("团队对抗：点位不足")
			and editor._status.text.contains("大乱斗：最多 2 人") and WorldSpec.arena(map, WorldSpec.ROYALE, [1, 2], {}, {}, 0).problem().is_empty()
			and not WorldSpec.arena(map, WorldSpec.ROYALE, [1, 2, 3], {}, {}, 0).problem().is_empty(), "two valid spawns enable exactly a two-player Royale and a duel")

func _workflow(tree: SceneTree) -> void:
	var filename := "editor-测试-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var game_path := MapCatalog.USER_DIR.path_join(filename + ".cyrm")
	var path := ProjectSettings.globalize_path(game_path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var editor: MapEditor = load("res://scenes/map_editor.tscn").instantiate()
	editor.draft_path = "user://" + filename + ".draft"
	tree.root.add_child(editor)
	await tree.process_frame
	editor._files.open_document(_sample(), "")
	expect(editor._inspector.param_rows.width.visible and not editor._points.visible,
			"the initial brush only shows its own inspector controls")
	var autosave_target := path.get_basename() + "-autosave.cyrm"
	editor._files.save(autosave_target)
	var saved := FileAccess.get_file_as_bytes(autosave_target)
	var edited := editor.session
	var added := edited.place_point({"kind": "enemy", "type": "fly_bird", "cell": Vector2i(1, 1)})
	editor.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	NetSession.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await tree.process_frame
	var quit_prompt: ConfirmationDialog = editor.find_children("*", "ConfirmationDialog", true, false).back()
	expect(editor.theme == UiDesign.MENU_THEME and quit_prompt.get_ok_button().get_theme_stylebox("normal") ==
			UiDesign.MENU_THEME.get_stylebox("normal", "ToolButton"), "editor and confirmation use the shared theme")
	expect(quit_prompt.visible and edited.dirty(), "closing a dirty editor gives the player time to cancel")
	quit_prompt.hide()
	await tree.process_frame
	expect(editor.is_inside_tree() and edited.map.points.has(added), "cancelling close preserves the unsaved map")
	for i in 4:
		await tree.create_timer(2.0).timeout
		edited.put_notes("# edit %d before the tick" % i)
	expect(not FileAccess.file_exists(editor.draft_path), "editing stays in memory before the ten-second autosave")
	await tree.create_timer(2.5).timeout
	var checkpoint := MapEditFiles.read_draft(editor.draft_path)
	expect(not checkpoint.is_empty() and checkpoint.map == edited.map,
			"the first ten-second tick writes all layers, points and the latest notes despite continued editing")
	var on_disk := FileAccess.get_file_as_bytes(editor.draft_path)
	edited.commit_point(added, {"kind": "enemy", "type": "fly_bird", "cell": Vector2i(2, 1)})
	expect(edited.map.points[added].cell == Vector2i(2, 1) and FileAccess.get_file_as_bytes(editor.draft_path) == on_disk,
			"the next edit changes only the live map between checkpoints")
	expect(FileAccess.get_file_as_bytes(autosave_target) == saved, "autosaving the whole draft leaves the chosen CYRM file intact")
	DirAccess.remove_absolute(autosave_target)
	_mode_limits(editor)
	editor._files.open_document(_sample(), "")
	await _size_dialogs(tree, editor)
	await _canvas_display(tree, editor)
	if DisplayServer.get_name() != "headless": await _lighting_preview(editor)
	_canvas_tools(editor)
	editor._files.open_document(_sample(), "")
	_workspace_controls(editor)
	await _point_selection(tree, editor)
	await _lamp_workflow(tree, editor)
	editor._files.open_document(_sample(), "")
	editor._files.file_selected(true, PackedStringArray([path.get_basename()]), 0, true)
	expect(editor.session.path == path and FileAccess.file_exists(path), "native Save As accepts a path without its CYRM extension")
	var old_bytes := FileAccess.get_file_as_bytes(path)
	expect(CyrmMap.save_file(editor.session.map, path.path_join("blocked.cyrm")) != OK and FileAccess.get_file_as_bytes(path) == old_bytes, "failed save leaves original file intact")
	var s := editor.session
	s.layer = CyrmMap.SCENE
	var step := Rect2i(10, 20, 4, 1)
	var pixels := PackedInt32Array([_stone, _stone, _stone, _stone])
	s.put_cells([10, 20, _stone, 11, 20, _stone, 12, 20, _stone, 13, 20, _stone])
	s.selection = step
	editor.canvas.zoom = 13
	editor.canvas.origin = Vector2(91, 33)
	var revision := s.revision
	var document := s.map
	var choice := PackedStringArray([path])
	editor._files.file_selected(false, PackedStringArray(), 0, false)
	editor._files.file_selected(false, choice, 0, true)
	expect(is_same(s.map, document) and s.dirty() and FileAccess.get_file_as_bytes(path) == old_bytes, "cancelling the native picker preserves the dirty document and saved file")
	editor._files.file_selected(true, choice, 0, false)
	var discard: ConfirmationDialog = editor.get_child(-1)
	expect(discard.visible and is_same(s.map, document), "choosing a file waits for confirmation before discarding changes")
	discard.get_cancel_button().pressed.emit()
	await tree.process_frame
	expect(is_same(s.map, document) and s.revision == revision, "cancelling discard retains the edited map")
	editor._files.file_selected(true, PackedStringArray([path.get_basename()]), 0, true)
	var overwrite: ConfirmationDialog = editor.get_child(-1)
	expect(overwrite.visible and FileAccess.get_file_as_bytes(path) == old_bytes, "adding the extension cannot silently overwrite an existing map")
	overwrite.get_cancel_button().pressed.emit()
	await tree.process_frame
	editor._files.write_draft()
	var draft := MapEditFiles.read_draft(editor.draft_path)
	expect(draft.path == path and CyrmMap.read_region(draft.map, 1, step) == pixels, "unsaved draft can recover the step")
	var recovered: MapEditor = load("res://scenes/map_editor.tscn").instantiate()
	recovered.draft_path = editor.draft_path
	tree.root.add_child(recovered)
	expect(recovered.session.dirty() and recovered.session.path == path and CyrmMap.read_region(recovered.session.map, 1, step) == pixels, "entering the editor restores the unsaved document and target")
	recovered.queue_free()
	await tree.process_frame
	var settings_path := Settings.sp_map_path
	var toolbar := editor._workspace.get_child(0).get_child(0)
	var lighting: CheckBox = toolbar.find_children("*", "CheckBox", false, false)[0]
	var time: HSlider = toolbar.find_children("*", "HSlider", false, false)[0]
	_click_button(lighting)
	expect(time.editable and editor.canvas.preview_minute == 720, "lighting preview opens at noon")
	time.value = time.max_value
	expect(time.step == 15 and editor.canvas.preview_minute == 1425 and s.revision == revision,
			"the preview reaches 23:45 in quarter hours without making a map edit")
	editor._choose_tool("point")
	_click_cell(editor.canvas, Vector2i(2, 3))
	editor._points._list.grab_focus()
	_key(editor, KEY_DOWN)
	_key(editor, KEY_F5)
	await tree.physics_frame
	expect(editor._trial.trial != null and editor._trial.trial.spec.solo_spawn == Vector2i(6, 3), "F5 uses the point selected with the list's arrow keys")
	var view := editor._trial.trial._view
	editor._trial.trial._process(0.0)
	expect(editor._trial.trial._presenter.frame.day_minute == 1425 and view._time_of_day.text == "23:45",
			"F5 uses the same fixed light and HUD time as the editor")
	var planes := view.camera.get_viewport().find_children("*", "Parallax2D", false, false)
	expect(planes.size() == 4, "trial renders all four painted backgrounds")
	view.camera.force_update_scroll()
	var starts := planes.map(func(p: Parallax2D) -> Vector2: return p.get_global_transform_with_canvas().origin)
	var lap := Vector2(s.map.size * CyrmMap.CELL_SIZE)
	view.camera.position += lap
	view.camera.force_update_scroll()
	for i in planes.size():
		var plane: Parallax2D = planes[i]
		var sprite: Sprite2D = plane.get_child(0)
		var travel: Vector2 = (starts[i] - plane.get_global_transform_with_canvas().origin) / view.camera.zoom
		expect(travel.is_equal_approx(lap * MatchView.BACKGROUND_SCROLL[i])
				and (travel / sprite.scale).is_equal_approx(Vector2(s.map.size)), "one camera lap scrolls each depth by one texture period")
	expect(editor._trial.trial.terrain.sub_texture(step.position) == 7, "trial collision terrain includes unsaved step")
	var terrain := editor._trial.trial.terrain
	terrain.apply_at(terrain.version, {step.position: 0})
	expect(CyrmMap.read_region(s.map, 1, step) == pixels, "trial destruction cannot modify authored cells")
	editor.finish_trial()
	_click_button(lighting)
	expect(not time.editable and editor.canvas.preview_minute < 0.0, "returning to paint restores unlit colors")
	expect(s.selection == step and s.revision == revision and editor.canvas.zoom == 13 and editor.canvas.origin == Vector2(91, 33), "return preserves view, selection and history")
	expect(Settings.sp_map_path == settings_path and FileAccess.get_file_as_bytes(path) == old_bytes, "trial preserves saved map and normal launch preference")
	expect(s.undo() and not s.dirty(), "step can still be undone after trial")
	s.redo()
	editor._choose_tool("brush")
	var width: SpinBox = editor._inspector.param_rows.width.get_child(1)
	width.get_line_edit().grab_focus()
	_key(editor, KEY_Z, true)
	expect(s.dirty() and s.revision == revision, "undo in a number field leaves the map revision alone")
	_key(editor, KEY_S, true)
	expect(width.get_line_edit().has_focus() and not s.dirty() and FileAccess.get_file_as_bytes(path) != old_bytes, "the save shortcut writes the file with the brush's number field focused")
	var local := CyrmMap.load_file(path)
	var received := CyrmMap.from_bytes(FileAccess.get_file_as_bytes(path))
	expect(local == s.map and received == local,
			"local, network and unsaved preview share the same map schema")
	editor._files.file_selected(true, choice, 0, false)
	expect(not is_same(s.map, document) and s.path == path and CyrmMap.read_region(s.map, 1, step) == pixels, "choosing a CYRM opens it in the editor")
	await tree.process_frame
	expect(editor._filename.text.contains(filename) and editor._filename.size.x > 150.0, "document strip displays the filename")
	expect(MapCatalog.list_maps().any(func(item: Dictionary) -> bool: return item.path == game_path), "normal game map picker sees the file saved in the default folder")
	expect(not FileAccess.file_exists(editor.draft_path), "explicit save clears recovered draft")
	editor.queue_free()
	await tree.process_frame
	MapEditFiles.clear_draft("user://" + filename + ".draft")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
