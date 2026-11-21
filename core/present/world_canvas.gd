class_name WorldCanvas
extends Node2D

const FONT := PixelFont.FONT
const WHITE_MASK := preload("res://core/present/white_mask.gdshader")
enum Pass { NORMAL, PLAYER, GLOW, MASK, FOREGROUND }
enum Mark { BOX, CIRCLE, ARC, POLYGON, LINE }

class SpriteBatch extends Node2D:
	var rows: Array[Array] = []

var _sky := Daylight.new()
var _ambient := CanvasModulate.new()
var _player_material := _shader_material(preload("res://scenes/player/player_color.gdshader"))
var _marks: Array[Array] = []
var _materials: Array[Material]
var _batches: Array[SpriteBatch] = []
var _batch_count := 0
var _lines: Array[Array] = []
var _overlay_marks: Array[Array] = []
var _labels := [[], []]
var _foreground := SpriteBatch.new()
var _overlay := Node2D.new()

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var glow := CanvasItemMaterial.new()
	glow.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_player_material.set_shader_parameter("shade_atlas", preload("res://assets/textures/player_shade.png"))
	_player_material.set_shader_parameter("eye_irradiance", preload("res://assets/textures/player_eye_light.png"))
	_materials = [null, _player_material, glow, _shader_material(WHITE_MASK)]
	_foreground.z_index = 1
	add_child(_foreground)
	_foreground.draw.connect(_draw_foreground)
	var sky_layer := CanvasLayer.new()
	sky_layer.layer = -1
	add_child(sky_layer)
	# 镜头预留的上下边距延用天顶和地平线颜色。
	_sky.overscan_y = maxf(1.0, get_viewport_rect().size.y / get_window().get_visible_rect().size.y)
	UiFactory.cover(sky_layer, _sky)
	add_child(_ambient)
	set_daylight(Daylight.NOON)
	var cues := CanvasLayer.new()
	cues.follow_viewport_enabled = true
	add_child(cues)
	cues.add_child(_overlay)
	_overlay.draw.connect(_draw_overlay)

func set_daylight(minute: float) -> void:
	_ambient.color = _sky.set_minute(minute)
	_player_material.set_shader_parameter("ambient_light", _ambient.color)
	_player_material.set_shader_parameter("directional_light", _sky.directional_light)

static func _shader_material(shader: Shader) -> ShaderMaterial:
	var result := ShaderMaterial.new()
	result.shader = shader
	return result

## 只合批相邻的同材质贴图，保留角色、武器与特效的遮挡顺序。
func _batch(style: Material) -> SpriteBatch:
	if _batch_count > 0 and _batches[_batch_count - 1].material == style:
		return _batches[_batch_count - 1]
	if _batch_count == _batches.size():
		var node := SpriteBatch.new()
		add_child(node)
		node.draw.connect(_draw_sprites.bind(node, node.rows))
		_batches.append(node)
	var batch := _batches[_batch_count]
	batch.material = style
	_batch_count += 1
	return batch

func begin() -> void:
	for batch in _batches:
		batch.rows.clear()
	_batch_count = 0
	_foreground.rows.clear()
	for rows: Array in _labels:
		rows.clear()
	_lines.clear()
	_marks.clear()
	_overlay_marks.clear()

func submit() -> void:
	queue_redraw()
	for batch in _batches:
		batch.queue_redraw()
	_foreground.queue_redraw()
	_overlay.queue_redraw()

func sprite(texture: Texture2D, region: Rect2, pose: Transform2D, color := Color.WHITE,
		flip := false, sprite_pass := Pass.NORMAL) -> void:
	var rect := Rect2(-region.size * 0.5, region.size)
	if flip:
		pose.x = -pose.x
	var batch := _foreground if sprite_pass == Pass.FOREGROUND else _batch(_materials[sprite_pass])
	batch.rows.append([texture, region, pose, color, rect])

func line(points: PackedVector2Array, color: Color, width: float, overlay := false) -> void:
	if overlay:
		_overlay_marks.append([Mark.LINE, points, color, width])
	else:
		_lines.append([points, color, width])

func rect(box: Rect2, color: Color, stroke := -1.0, overlay := true) -> void:
	var rows := _overlay_marks if overlay else _marks
	rows.append([Mark.BOX, box, color, stroke])

func circle(at: Vector2, radius: float, color: Color, overlay := false) -> void:
	var rows := _overlay_marks if overlay else _marks
	rows.append([Mark.CIRCLE, at, radius, color])

func arc(at: Vector2, radius: float, start: float, end: float, color: Color, width: float) -> void:
	_overlay_marks.append([Mark.ARC, at, radius, start, end, color, width])

func polygon(points: PackedVector2Array, color: Color) -> void:
	_marks.append([Mark.POLYGON, points, color])

func text_at(value: String, at: Vector2, color: Color, plate := false, outline := 0) -> void:
	_labels[int(not plate)].append([value, at, color, plate, outline])

static func centered_baseline() -> float:
	return (FONT.get_ascent(32) - FONT.get_descent(32)) * 0.5

func _draw() -> void:
	for row in _lines:
		draw_polyline(row[0], row[1], row[2], true)

func _draw_overlay() -> void:
	_draw_marks(_overlay, _overlay_marks)
	_draw_labels(_overlay, _labels[1])

func _draw_foreground() -> void:
	_draw_marks(_foreground, _marks)
	_draw_sprites(_foreground, _foreground.rows)
	_draw_labels(_foreground, _labels[0])

func _draw_sprites(target: CanvasItem, rows: Array) -> void:
	for row: Array in rows:
		target.draw_set_transform_matrix(row[2])
		target.draw_texture_rect_region(row[0], row[4], row[1], row[3], false, false)
	target.draw_set_transform_matrix(Transform2D.IDENTITY)

func _draw_marks(target: CanvasItem, rows: Array) -> void:
	for row: Array in rows:
		match row[0]:
			Mark.BOX: target.draw_rect(row[1], row[2], row[3] < 0.0, row[3])
			Mark.CIRCLE: target.draw_circle(row[1], row[2], row[3], true, -1.0, true)
			Mark.ARC: target.draw_arc(row[1], row[2], row[3], row[4], 48, row[5], row[6], true)
			Mark.POLYGON: target.draw_colored_polygon(row[1], row[2])
			Mark.LINE: target.draw_polyline(row[1], row[2], row[3], true)

func _draw_labels(target: CanvasItem, rows: Array) -> void:
	for row: Array in rows:
		var at: Vector2 = row[1]
		var size := 32
		var width := FONT.get_string_size(row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var start := at - Vector2(width * 0.5, 0.0)
		var color: Color = row[2]
		if row[3]:
			target.draw_rect(Rect2(start - Vector2(6, FONT.get_ascent(size) + 2),
					Vector2(width + 12, FONT.get_height(size) + 4)), UiFactory.C_PLATE)
		if row[4] > 0:
			target.draw_string_outline(FONT, start, row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size,
					row[4], Color(UiFactory.C_BG, color.a))
		target.draw_string(FONT, start, row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
