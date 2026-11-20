class_name WorldCanvas
extends Node2D

const FONT := PixelFont.FONT
const PLAYER_HUE := preload("res://scenes/player/player_p2_hue.gdshader")
const WHITE_MASK := preload("res://core/present/white_mask.gdshader")
enum Pass { NORMAL, HUE, GLOW, MASK, FOREGROUND }
enum Mark { BOX, CIRCLE, ARC, POLYGON }

var _marks: Array[Array] = []
var _sprites := [[], [], [], [], []]
var _lines: Array[Array] = []
var _overlay_marks: Array[Array] = []
var _labels := [[], []]
var _sprite_passes: Array[CanvasItem] = [self]
var _names := Node2D.new()
var _overlay := Node2D.new()

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var glow := CanvasItemMaterial.new()
	glow.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_add_sprite_pass(_shader_material(PLAYER_HUE))
	_add_sprite_pass(glow)
	_add_sprite_pass(_shader_material(WHITE_MASK))
	_names.z_index = 1
	add_child(_names)
	_names.draw.connect(_draw_names)
	_overlay.z_index = 100
	add_child(_overlay)
	_overlay.draw.connect(_draw_overlay)

static func _shader_material(shader: Shader) -> ShaderMaterial:
	var result := ShaderMaterial.new()
	result.shader = shader
	return result

func _add_sprite_pass(style: Material) -> void:
	var pass_node := Node2D.new()
	pass_node.material = style
	var rows: Array = _sprites[_sprite_passes.size()]
	add_child(pass_node)
	pass_node.draw.connect(_draw_sprites.bind(pass_node, rows))
	_sprite_passes.append(pass_node)


## 发光 sprite pass(加色混合);由 MatchView 挪进 GlowViewport。
func glow_pass() -> CanvasItem:
	return _sprite_passes[Pass.GLOW]

func begin() -> void:
	for rows: Array in _sprites:
		rows.clear()
	for rows: Array in _labels:
		rows.clear()
	_lines.clear()
	_marks.clear()
	_overlay_marks.clear()

func submit() -> void:
	for pass_node in _sprite_passes:
		pass_node.queue_redraw()
	_names.queue_redraw()
	_overlay.queue_redraw()

func sprite(texture: Texture2D, region: Rect2, pose: Transform2D, color := Color.WHITE,
		flip := false, sprite_pass := Pass.NORMAL) -> void:
	var rect := Rect2(-region.size * 0.5, region.size)
	if flip:
		pose.x = -pose.x
	_sprites[sprite_pass].append([texture, region, pose, color, rect])

func line(points: PackedVector2Array, color: Color, width: float) -> void:
	_lines.append([points, color, width])

func rect(box: Rect2, color: Color, stroke := -1.0, overlay := true) -> void:
	var rows := _overlay_marks if overlay else _marks
	rows.append([Mark.BOX, box, color, stroke])

func circle(at: Vector2, radius: float, color: Color) -> void:
	_marks.append([Mark.CIRCLE, at, radius, color])

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
	_draw_sprites(self, _sprites[Pass.NORMAL])
	_draw_marks(self, _marks)

func _draw_overlay() -> void:
	_draw_marks(_overlay, _overlay_marks)
	_draw_labels(_overlay, _labels[1])

func _draw_names() -> void:
	_draw_sprites(_names, _sprites[Pass.FOREGROUND])
	_draw_labels(_names, _labels[0])

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
