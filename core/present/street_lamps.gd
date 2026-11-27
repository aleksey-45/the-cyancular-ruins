class_name StreetLamps
extends Node2D

const FIXTURE := preload("res://core/present/street_lamp.tscn")
const COLORS := {"warm": Color("#ffd69c"), "cool": Color("#86d9e8")}
const RECEIVER_MASK := 2
const CELL := CyrmMap.CELL_SIZE
const BULB_HEIGHT := (CyrmMap.LAMP_HEIGHT - 1) * CELL

var _supports: Dictionary[int, Node2D] = {}
var _layout: Array = []
var radius := 160.0
var night := 0.0:
	set(value):
		if value == night: return
		night = value
		for stand in _supports.values():
			for light: PointLight2D in stand.get_children():
				_light(light)

func install(map: Dictionary, margin := Vector2.ZERO, repeats := Vector2i.ZERO) -> void:
	var fixtures: Dictionary[Vector2i, String] = {}
	for id: int in map.points:
		var point: Dictionary = map.points[id]
		if point.kind == "lamp" and CyrmMap.lamp_problem(map, point.cell, id).is_empty():
			fixtures[point.cell] = point.tone
	# 编辑器提交一笔地形修改后，仅在有效灯位、色温或地图范围改变时重建灯具。
	var layout := [map.size, margin, repeats, fixtures]
	if layout == _layout: return
	_layout = layout
	for stand in _supports.values(): stand.free()
	_supports.clear()
	var period := Vector2(map.size * CELL)
	radius = minf(160.0, minf(period.x, period.y) * 0.5)
	var size := Vector2(CELL, CyrmMap.LAMP_HEIGHT * CELL)
	for cell in fixtures:
		var foot := (Vector2(cell) + Vector2(0.5, 1)) * CELL
		var bulb := foot - Vector2(0, BULB_HEIGHT)
		var glow := Rect2(bulb, Vector2.ZERO).grow(radius)
		var housing := Rect2(foot - size * Vector2(0.5, 1), size)
		var copies := ToroidalGrid.seam_copy_range(glow.merge(housing), period, margin)
		var stand := Node2D.new()
		add_child(stand)
		_supports[CyrmMap.lamp_support(cell, map.size)] = stand
		for y in range(copies.position.y, copies.end.y + repeats.y):
			for x in range(copies.position.x, copies.end.x + repeats.x):
				var light: PointLight2D = FIXTURE.instantiate()
				light.position = bulb + Vector2(x, y) * period
				light.color = COLORS[fixtures[cell]]
				light.texture_scale = 2.0 * radius / light.texture.get_width()
				stand.add_child(light)
				_light(light)

func _light(light: PointLight2D) -> void:
	light.enabled = night > 0.0
	light.energy = 0.9 * night
	light.get_node("Filament").self_modulate = Color(light.color, night)

func set_support(index: int, alive: bool) -> void:
	if _supports.has(index): _supports[index].visible = alive

func lit_count(view: Rect2) -> int:
	if night == 0.0: return 0
	var count := 0
	for stand in _supports.values():
		if not stand.visible: continue
		for light: PointLight2D in stand.get_children():
			var nearest := light.position.clamp(view.position, view.end)
			if light.position.distance_squared_to(nearest) < radius * radius: count += 1
	return count
