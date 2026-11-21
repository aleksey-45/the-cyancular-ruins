class_name MapBrush
extends RefCounted

var width := 1
var material_id := 1
var tint := CyrmMap.NEUTRAL_TINT
var tint_only := false
var outline := false
var color := Color("#42bcca")
var end_color := Color("#182b49")

func sample(session: MapEditSession, cell: Vector2i) -> void:
	var value := CyrmMap.cell_at(session.map, session.layer, cell)
	if session.on_background:
		color = Color.hex(value)
	else:
		material_id = CyrmMap.tile_material(value)
		tint = CyrmMap.tile_tint(value)

func _paint_bounds(session: MapEditSession) -> Rect2i:
	return session.selection if session.selection.has_area() else session.bounds

func _ink(background: bool) -> int:
	return color.to_rgba32() if background else CyrmMap.tile_value(material_id, tint)

func _tinted(tile: int) -> int:
	return CyrmMap.tile_value(CyrmMap.tile_material(tile), tint)

# 按落笔顺序展开每个区域，重叠的笔印也各占一条记录。
func _paint_regions(session: MapEditSession, regions: Array[Rect2i], ink: int, recolor := false,
		gradient_start := Vector2i.ZERO, gradient_axis := Vector2.ZERO) -> bool:
	var count := 0
	for rect in regions: count += rect.get_area()
	var changes := MapEditSession.cell_buffer(count)
	var offset := 0
	var length2 := gradient_axis.length_squared()
	for rect in regions:
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var value := ink
				if length2 > 0.0:
					var t := Vector2(Vector2i(x, y) - gradient_start).dot(gradient_axis) / length2
					value = color.lerp(end_color, clampf(t, 0.0, 1.0)).to_rgba32()
				elif recolor:
					value = _tinted(CyrmMap.cell_at(session.map, session.layer, Vector2i(x, y)))
				changes[offset] = x
				changes[offset + 1] = y
				changes[offset + 2] = value
				offset += 3
	return session.put_cells(changes)

func stroke(path: Array[Vector2i], session: MapEditSession, shape := "brush") -> bool:
	if path.is_empty() or session.locked[session.layer]: return false
	var bounds := _paint_bounds(session)
	var ink := 0 if shape == "erase" else _ink(session.on_background)
	var recolor := tint_only and not session.on_background and shape != "erase"
	var regions: Array[Rect2i] = []
	var add_stamp := func(footprint: Rect2i) -> void:
		var rect := footprint.intersection(bounds)
		if rect.has_area(): regions.append(rect)
	var first := path[0]
	var last := path[-1]
	if shape == "rect":
		if outline:
			var across := Vector2i(last.x, first.y)
			var down := Vector2i(first.x, last.y)
			add_stamp.call(MapEditSession.cell_box(first, across))
			add_stamp.call(MapEditSession.cell_box(across, last))
			add_stamp.call(MapEditSession.cell_box(last, down))
			add_stamp.call(MapEditSession.cell_box(down, first))
		else:
			add_stamp.call(MapEditSession.cell_box(first, last))
	else:
		var size := Vector2i.ONE * width
		var offset := size / 2
		var previous := first
		add_stamp.call(Rect2i(first - offset, size))
		for end: Vector2i in ([last] if shape == "line" else path):
			var delta := (end - previous).abs()
			var steps := maxi(delta.x, delta.y)
			for i in range(1, steps + 1):
				var cell := Vector2i(Vector2(previous).lerp(Vector2(end), float(i) / steps).round())
				add_stamp.call(Rect2i(cell - offset, size))
			previous = end
	return _paint_regions(session, regions, ink, recolor)

func bucket(cell: Vector2i, session: MapEditSession) -> bool:
	var area := _paint_bounds(session)
	if not area.has_point(cell) or session.locked[session.layer]: return false
	var pixels := CyrmMap.read_region(session.map, session.layer, area)
	var stride := area.size.x
	var root := (cell.y - area.position.y) * stride + cell.x - area.position.x
	var old := pixels[root]
	var ink := _tinted(old) if tint_only and not session.on_background else _ink(session.on_background)
	var visited := ~old # 在工作副本中标出已经走过的格子。
	var regions: Array[Rect2i] = []
	var seeds := PackedInt32Array([root])
	var cursor := 0
	# 记录连通的水平段。相邻行的每段旧色只需一个种子。
	while cursor < seeds.size():
		var left := seeds[cursor]
		cursor += 1
		if pixels[left] != old: continue
		var row := left / stride
		var start := row * stride
		while left > start and pixels[left - 1] == old: left -= 1
		var right := left
		while right < start + stride and pixels[right] == old:
			pixels[right] = visited
			var above := right - stride
			var below := right + stride
			if above >= 0 and pixels[above] == old and (right == left or pixels[above - 1] != old): seeds.append(above)
			if below < pixels.size() and pixels[below] == old and (right == left or pixels[below - 1] != old): seeds.append(below)
			right += 1
		regions.append(Rect2i(area.position.x + left - start, area.position.y + row, right - left, 1))
	return _paint_regions(session, regions, ink)

func gradient(path: Array[Vector2i], session: MapEditSession) -> bool:
	var area := session.selection
	if path.is_empty() or not area.has_area() or not session.on_background or session.locked[session.layer]: return false
	var start := path[0]
	return _paint_regions(session, [area], color.to_rgba32(), false, start, Vector2(path[-1] - start))
