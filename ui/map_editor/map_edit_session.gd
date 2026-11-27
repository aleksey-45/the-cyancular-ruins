class_name MapEditSession
extends RefCounted

signal changed
signal selection_changed
signal cells_changed(layer: int, changes: PackedInt32Array)
## 传点位 ID 时只更新该项。传 -1 时重建点位列表。
signal points_changed(updated_id: int)
signal point_rejected(reason: String)

const POINT_EDIT_BYTES := 128

var map: Dictionary
var bounds: Rect2i:
	get: return Rect2i(Vector2i.ZERO, map.size)
var path := ""
var layer := CyrmMap.SCENE
var on_background: bool:
	get: return layer >= CyrmMap.FIRST_BACKGROUND
var selection := Rect2i():
	set(value):
		if value != selection:
			selection = value
			selection_changed.emit()
var selected_point_id := -1
var locked: Array[bool] = []
var clipboard := PackedInt32Array()
var clip_size := Vector2i.ZERO
var clip_color := false
var revision := 0
var _saved_revision := 0
var _serial := 0
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _bytes := 0
var _next_point_id := 0

func _init() -> void:
	locked.resize(CyrmMap.LAYER_COUNT)

static func cell_box(a: Vector2i, b: Vector2i) -> Rect2i:
	return Rect2i(a.min(b), (a - b).abs() + Vector2i.ONE)

static func cell_buffer(cell_count: int) -> PackedInt32Array:
	var changes := PackedInt32Array()
	changes.resize(cell_count * 3)
	return changes

func open(document: Dictionary, filename: String, dirty := false) -> void:
	_next_point_id = 0 if document.points.is_empty() else int(document.points.keys().max()) + 1
	path = filename
	_undo.clear()
	_redo.clear()
	_bytes = 0
	_serial += 1
	revision = _serial
	_saved_revision = -1 if dirty else revision
	_set_map(document, true)

func _set_map(document: Dictionary, reset_points: bool) -> void:
	map = document
	if reset_points: selected_point_id = -1
	selection = Rect2i()
	cells_changed.emit(-1, PackedInt32Array())
	if reset_points: points_changed.emit(-1)
	changed.emit()

func dirty() -> bool:
	return revision != _saved_revision

func mark_saved(filename: String) -> void:
	path = filename
	_saved_revision = revision
	changed.emit()

# 撤销和重做记录分别保存下一次操作要恢复的内容和修订号。
func _record(inverse: Callable, cost: int, direction: int) -> void:
	var edit := {"apply": inverse, "cost": cost, "revision": revision}
	var undoing := direction < 0
	if direction == 0:
		_redo.clear()
		_serial += 1
		revision = _serial
	else:
		var source := _undo if undoing else _redo
		revision = source.pop_back().revision
	var destination := _redo if undoing else _undo
	destination.append(edit)
	_bytes += -cost if undoing else cost
	while _undo.size() > 1 and (_undo.size() > 200 or _bytes > 64 * 1024 * 1024):
		_bytes -= int(_undo.pop_front().cost)

func undo() -> bool:
	return _replay(_undo, -1)

func redo() -> bool:
	return _replay(_redo, 1)

func _replay(history: Array[Dictionary], direction: int) -> bool:
	if history.is_empty(): return false
	var apply: Callable = history.back().apply
	apply.call(direction)
	return true

func put_cells(changes: PackedInt32Array, target_layer := layer) -> bool:
	if changes.is_empty() or locked[target_layer]: return false
	_put_cells(0, changes, target_layer)
	return true

func _put_cells(direction: int, changes: PackedInt32Array, target_layer: int) -> void:
	# 写入前读取所有旧值，确保重复修改的子格也能恢复到本次操作前的状态。
	var previous := changes.duplicate()
	var cells: PackedInt32Array = map.layers[target_layer]
	var width: int = map.size.x
	for i in range(0, changes.size(), 3):
		previous[i + 2] = cells[changes[i + 1] * width + changes[i]]
	CyrmMap.write_cells(map, target_layer, changes)
	_record(_put_cells.bind(previous, target_layer), changes.size() * 4, direction)
	cells_changed.emit(target_layer, changes)
	changed.emit()

func selected_point() -> Dictionary:
	return map.points.get(selected_point_id, {})

## 列表、绘制和鼠标命中共用从底到顶的点位顺序。
func point_ids() -> Array[int]:
	var ids: Array = map.points.keys()
	ids.sort()
	var ordered: Array[int] = []
	for kind in ["lamp", "player", "player2", "respawn", "enemy"]:
		for id: int in ids:
			if map.points[id].kind == kind: ordered.append(id)
	return ordered

func dragged_point_cell(cell: Vector2i, from_subcell: Vector2i, to_subcell: Vector2i) -> Vector2i:
	var at := cell + to_subcell - from_subcell
	if selected_point().get("kind") == "lamp":
		return Vector2i(posmod(at.x, map.size.x), posmod(at.y, map.size.y))
	return at.clamp(Vector2i.ZERO, map.size - Vector2i.ONE)

func commit_point(id: int, target: Variant) -> int:
	if id < 0: return -1
	var before: Dictionary = map.points.get(id, {})
	var row: Dictionary = before.merged({"cell": target}, true) if target is Vector2i else target
	if row.get("kind") == "lamp" and (before.get("kind") != "lamp" or before.cell != row.cell):
		var problem := CyrmMap.lamp_problem(map, row.cell, id)
		if not problem.is_empty():
			point_rejected.emit(problem)
			return -1
	_put_point(0, id, row)
	return id

func _put_point(direction: int, id: int, row: Dictionary) -> void:
	var previous: Dictionary = map.points.get(id, {})
	if previous == row: return
	if row.is_empty(): map.points.erase(id)
	else: map.points[id] = row
	_record(_put_point.bind(id, previous), POINT_EDIT_BYTES, direction)
	_next_point_id = maxi(_next_point_id, id + 1)
	if previous.is_empty() or row.is_empty(): selected_point_id = -1
	points_changed.emit(id if previous.get("kind") == row.get("kind") else -1)
	changed.emit()

func place_point(row: Dictionary) -> int:
	if row.kind in ["player", "player2"]:
		var id := CyrmMap.first_point_id(map, row.kind)
		if id >= 0: return commit_point(id, row)
	return commit_point(_next_point_id, row)

func put_notes(text: String) -> void:
	_put_notes(0, text)

func _put_notes(direction: int, text: String) -> void:
	if text == map.notes: return
	var previous: String = map.notes
	map.notes = text
	_record(_put_notes.bind(previous), maxi(text.length(), previous.length()) * 4, direction)
	changed.emit()

func resize_map(dimensions: Vector2i) -> bool:
	if dimensions == map.size: return false
	var document := CyrmMap.resized(map, dimensions)
	if document.is_empty(): return false
	_replace_map(0, document)
	return true

func _replace_map(direction: int, document: Dictionary) -> void:
	var cost := maxi(map.layers[0].size(), document.layers[0].size()) * CyrmMap.LAYER_COUNT * 4
	_record(_replace_map.bind(map), cost, direction)
	_set_map(document, map.points.size() != document.points.size())

func _region_cells(area: Rect2i, pixels: PackedInt32Array = map.layers[layer], source: Rect2i = bounds) -> PackedInt32Array:
	var changes := cell_buffer(area.get_area())
	var offset := 0
	var clear := pixels.is_empty()
	for y in range(area.position.y, area.end.y):
		var row := (y - source.position.y) * source.size.x - source.position.x
		for x in range(area.position.x, area.end.x):
			changes[offset] = x
			changes[offset + 1] = y
			changes[offset + 2] = 0 if clear else pixels[row + x]
			offset += 3
	return changes

func copy_selection() -> bool:
	if not selection.has_area():
		return false
	clipboard = CyrmMap.read_region(map, layer, selection)
	clip_size = selection.size
	clip_color = on_background
	return true

func clear_selection() -> bool:
	return not locked[layer] and put_cells(_region_cells(selection, PackedInt32Array()))

func paste(at: Vector2i) -> bool:
	if clipboard.is_empty() or on_background != clip_color or locked[layer]:
		return false
	var source := Rect2i(at, clip_size)
	var dest := source.intersection(bounds)
	if not dest.has_area(): return false
	selection = dest
	return put_cells(_region_cells(dest, clipboard, source))

func mirror(horizontal: bool) -> bool:
	if not selection.has_area() or locked[layer]:
		return false
	var changes := _region_cells(selection)
	var axis := 0 if horizontal else 1
	var sum := selection.position[axis] + selection.end[axis] - 1
	for i in range(axis, changes.size(), 3): changes[i] = sum - changes[i]
	return put_cells(changes)

func move_selection(offset: Vector2i) -> bool:
	var source := selection
	var dest := Rect2i(source.position + offset, source.size)
	if not source.has_area() or offset == Vector2i.ZERO or locked[layer] or not bounds.encloses(dest):
		return false
	var changes := _region_cells(selection)
	for i in range(0, changes.size(), 3):
		var cell := Vector2i(changes[i], changes[i + 1])
		changes[i] += offset.x
		changes[i + 1] += offset.y
		if not dest.has_point(cell): CyrmMap.append_cell(changes, cell.x, cell.y, 0)
	put_cells(changes)
	selection = dest
	return true
