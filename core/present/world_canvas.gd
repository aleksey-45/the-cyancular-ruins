class_name WorldCanvas
extends Node2D

const FONT := PixelFont.FONT
const WHITE_MASK := preload("res://core/present/white_mask.gdshader")
const PLAYER_CONFIG: PlayerConfig = preload("res://core/config/player_config.tres")
const EYE_LIGHT := preload("res://assets/textures/player_light_cookie.png")
const MAX_POINT_LIGHTS_PER_ITEM := 15  # Mobile 渲染器中一个 CanvasItem 可接收的点光源数量上限。
const Pass := WorldDrawing.Pass
const Mark := WorldDrawing.Mark

class SpriteBatch extends Node2D:
	var style: int
	var rows: Array[Array] = []

var _sky := Daylight.new()
var lamps := StreetLamps.new()
var _ambient := CanvasModulate.new()
var _directional := DirectionalLight2D.new()
var _eye_lights: Array[PointLight2D] = []
var _eye_light_count := 0
var _player_body_material := _shader_material(preload("res://core/present/player_body_lighting.gdshader"))
var _drawing: Dictionary = WorldDrawing.new(WorldDrawing.Textures.new()).data
var _textures: Array[Texture2D]
var _materials: Array[Material]
var _batches: Array[SpriteBatch] = []
var _batch_count := 0
var _split_player_batches := false
var _foreground := SpriteBatch.new()
var overlay_layer := Node2D.new()

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(lamps)
	var glow := CanvasItemMaterial.new()
	glow.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_materials = [null, _player_body_material, glow, _shader_material(WHITE_MASK)]
	_foreground.z_index = 1
	add_child(_foreground)
	_foreground.draw.connect(_draw_foreground)
	var sky_layer := CanvasLayer.new()
	sky_layer.layer = -1
	add_child(sky_layer)
	# 视口为畸变预留的上下区域沿用天空渐变两端的颜色。
	_sky.overscan_y = maxf(1.0, get_viewport_rect().size.y / get_window().get_visible_rect().size.y)
	UiDesign.cover(sky_layer, _sky)
	add_child(_ambient)
	_directional.height = 0.25
	add_child(_directional)
	set_daylight(Daylight.NOON)
	var cues := CanvasLayer.new()
	cues.follow_viewport_enabled = true
	add_child(cues)
	cues.add_child(overlay_layer)
	overlay_layer.draw.connect(_draw_overlay)

func set_daylight(minute: float) -> void:
	_ambient.color = _sky.set_minute(minute)
	lamps.night = _sky.night
	var source := _sky.directional_light
	var color := _sky.directional_color
	_directional.rotation = Vector2.DOWN.angle_to(-Vector2(source.x, source.y))
	_directional.color = Color(color, 1.0)
	_directional.energy = (0.22 if source.z > 0.0 else 0.11) * color.a
	_player_body_material.set_shader_parameter(&"body_daylight", Color(_ambient.color, source.z))

static func _shader_material(shader: Shader) -> ShaderMaterial:
	var result := ShaderMaterial.new()
	result.shader = shader
	return result

## 相邻且使用同一材质的精灵可共用画布节点，保持原有遮挡顺序。
func _batch(style: int, separate: bool) -> SpriteBatch:
	if not separate and _batch_count > 0 and _batches[_batch_count - 1].style == style:
		return _batches[_batch_count - 1]
	if _batch_count == _batches.size():
		var node := SpriteBatch.new()
		add_child(node)
		node.draw.connect(_draw_sprites.bind(node, node.rows))
		_batches.append(node)
	var batch := _batches[_batch_count]
	batch.style = style
	batch.material = _materials[style]
	batch.light_mask = 1 | StreetLamps.RECEIVER_MASK if style in [Pass.NORMAL, Pass.PLAYER_BODY] else 1
	_batch_count += 1
	return batch

func draw_world(drawing: Dictionary, textures: Array[Texture2D]) -> void:
	_drawing = drawing
	_textures = textures
	set_daylight(drawing.minute)
	for batch in _batches:
		batch.rows.clear()
	_batch_count = 0
	_foreground.rows.clear()
	var view := get_canvas_transform().affine_inverse() * get_viewport_rect()
	_split_player_batches = drawing.actors > 1 and drawing.actors + lamps.lit_count(view) > MAX_POINT_LIGHTS_PER_ITEM
	_eye_light_count = 0
	for pose: Transform2D in drawing.eyes:
		eye_light(pose)
	for index in range(_eye_light_count, _eye_lights.size()):
		_eye_lights[index].hide()
	for row: Array in drawing.sprites:
		var style: int = row[4]
		var batch := _foreground if style == Pass.FOREGROUND else _batch(style, _split_player_batches and style == Pass.PLAYER_BODY)
		batch.rows.append(row)
	queue_redraw()
	for batch in _batches:
		batch.queue_redraw()
	_foreground.queue_redraw()
	overlay_layer.queue_redraw()

func eye_light(pose: Transform2D) -> void:
	if _eye_light_count == _eye_lights.size():
		var node := PointLight2D.new()
		node.texture = EYE_LIGHT
		node.texture_scale = 1.0 / PLAYER_CONFIG.body_scale
		node.range_item_cull_mask = StreetLamps.RECEIVER_MASK
		node.height = 32.0
		add_child(node)
		_eye_lights.append(node)
	var light := _eye_lights[_eye_light_count]
	_eye_light_count += 1
	light.energy = lerpf(0.04, 0.75, _sky.night)
	light.transform = pose
	light.show()

func _draw() -> void:
	for row: Array in _drawing.lines:
		draw_polyline(row[0], row[1], row[2], true)

func _draw_overlay() -> void:
	_draw_marks(overlay_layer, _drawing.overlay)
	_draw_labels(overlay_layer, _drawing.labels[1])
	for row: Array in _drawing.bars:
		overlay_layer.draw_set_transform(row[0])
		EnemyHpBar.paint(overlay_layer, row[1])
	for row: Array in _drawing.prompts:
		overlay_layer.draw_set_transform(row[0])
		PickupPrompt.paint(overlay_layer, row[1])
	var reload: Array = _drawing.reload
	if not reload.is_empty():
		overlay_layer.draw_set_transform(reload[0])
		ReloadRing.paint(overlay_layer, reload[1], reload[2])
	overlay_layer.draw_set_transform(Vector2.ZERO)

func _draw_foreground() -> void:
	_draw_marks(_foreground, _drawing.marks)
	_draw_sprites(_foreground, _foreground.rows)
	_draw_labels(_foreground, _drawing.labels[0])

func _draw_sprites(target: CanvasItem, rows: Array) -> void:
	for row: Array in rows:
		var region: Rect2 = row[1]
		target.draw_set_transform_matrix(row[2])
		target.draw_texture_rect_region(_textures[row[0]], Rect2(-region.size * 0.5, region.size), region, row[3], false, false)
	target.draw_set_transform_matrix(Transform2D.IDENTITY)

func _draw_marks(target: CanvasItem, rows: Array) -> void:
	for row: Array in rows:
		match row[0]:
			Mark.BOX: target.draw_rect(row[1], row[2], row[3] < 0.0, row[3])
			Mark.CIRCLE: target.draw_circle(row[1], row[2], row[3], true, -1.0, true)
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
					Vector2(width + 12, FONT.get_height(size) + 4)), UiDesign.C_PLATE)
		if row[4] > 0:
			target.draw_string_outline(FONT, start, row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size,
					row[4], Color(UiDesign.C_BG, color.a))
		target.draw_string(FONT, start, row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
