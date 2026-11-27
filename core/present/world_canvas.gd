class_name WorldCanvas
extends Node2D

const FONT := PixelFont.FONT
const WHITE_MASK := preload("res://core/present/white_mask.gdshader")
const PLAYER_CONFIG: PlayerConfig = preload("res://core/config/player_config.tres")
const EYE_LIGHT := preload("res://assets/textures/player_light_cookie.png")
const MAX_POINT_LIGHTS_PER_ITEM := 15  # Mobile 渲染器中一个 CanvasItem 可接收的点光源数量上限。
enum Pass { NORMAL, PLAYER_BODY, GLOW, MASK, FOREGROUND }
enum Mark { BOX, CIRCLE, POLYGON, LINE }
enum Display { DAYLIGHT, EYES, BATCHES, FOREGROUND, LINES, MARKS, OVERLAY, LABELS }

class SpriteBatch extends Node2D:
	var style: int
	var rows: Array[Array] = []

var _sky := Daylight.new()
var lamps := StreetLamps.new()
var _day_minute: float
var _ambient := CanvasModulate.new()
var _directional := DirectionalLight2D.new()
var _eye_lights: Array[PointLight2D] = []
var _eye_light_count := 0
var _player_body_material := _shader_material(preload("res://core/present/player_body_lighting.gdshader"))
var _marks: Array[Array] = []
var _materials: Array[Material]
var _batches: Array[SpriteBatch] = []
var _batch_count := 0
var _split_player_batches := false
var _lines: Array[Array] = []
var _overlay_marks: Array[Array] = []
var _labels := [[], []]
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
	_day_minute = minute
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

func begin(actor_count: int) -> void:
	for batch in _batches:
		batch.rows.clear()
	_batch_count = 0
	var view := get_canvas_transform().affine_inverse() * get_viewport_rect()
	_split_player_batches = actor_count > 1 and actor_count + lamps.lit_count(view) > MAX_POINT_LIGHTS_PER_ITEM
	_eye_light_count = 0
	_foreground.rows.clear()
	for rows: Array in _labels:
		rows.clear()
	_lines.clear()
	_marks.clear()
	_overlay_marks.clear()

func submit() -> void:
	for index in range(_eye_light_count, _eye_lights.size()):
		_eye_lights[index].hide()
	queue_redraw()
	for batch in _batches:
		batch.queue_redraw()
	_foreground.queue_redraw()
	overlay_layer.queue_redraw()

static func diffuse(texture: Texture2D) -> Texture2D:
	return texture.diffuse_texture if texture is CanvasTexture else texture

func sprite(texture: Texture2D, region: Rect2, pose: Transform2D, color := Color.WHITE,
		sprite_pass := Pass.NORMAL) -> void:
	if sprite_pass == Pass.GLOW or sprite_pass == Pass.MASK:
		texture = diffuse(texture)
	var separate := _split_player_batches and sprite_pass == Pass.PLAYER_BODY
	var batch := _foreground if sprite_pass == Pass.FOREGROUND else _batch(sprite_pass, separate)
	batch.rows.append([texture, region, pose, color])

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

func polygon(points: PackedVector2Array, color: Color) -> void:
	_marks.append([Mark.POLYGON, points, color])

func text_at(value: String, at: Vector2, color: Color, plate := false, outline := 0) -> void:
	_labels[int(not plate)].append([value, at, color, plate, outline])

func display_state(texture_index: Callable) -> Array:
	var eyes: Array[Transform2D] = []
	for i in _eye_light_count:
		eyes.append(_eye_lights[i].transform)
	var batches: Array[Array] = []
	for i in _batch_count:
		var batch := _batches[i]
		batches.append([batch.style, _index_sprites(batch.rows, texture_index)])
	return [_day_minute, eyes, batches, _index_sprites(_foreground.rows, texture_index),
		_copy_geometry(_lines, 0), _copy_geometry(_marks, 1), _copy_geometry(_overlay_marks, 1),
		_labels.duplicate(true)]

func show_display(state: Array, textures: Array[Texture2D]) -> void:
	set_daylight(state[Display.DAYLIGHT])
	begin(0)
	for pose: Transform2D in state[Display.EYES]:
		eye_light(pose)
	for batch: Array in state[Display.BATCHES]:
		_restore_sprites(_batch(batch[0], true).rows, batch[1], textures)
	_restore_sprites(_foreground.rows, state[Display.FOREGROUND], textures)
	_lines.assign(state[Display.LINES])
	_marks.assign(state[Display.MARKS])
	_overlay_marks.assign(state[Display.OVERLAY])
	for i in _labels.size():
		_labels[i].assign(state[Display.LABELS][i])
	submit()

static func _index_sprites(rows: Array[Array], texture_index: Callable) -> Array[Array]:
	var captured: Array[Array] = []
	for row in rows:
		captured.append([texture_index.call(row[0]), row[1], row[2], row[3]])
	return captured

static func _restore_sprites(rows: Array[Array], saved: Array, textures: Array[Texture2D]) -> void:
	for row: Array in saved:
		rows.append([textures[row[0]], row[1], row[2], row[3]])

static func _copy_geometry(rows: Array[Array], point_column: int) -> Array[Array]:
	var captured := rows.duplicate(true)
	for row in captured:
		if row[point_column] is PackedVector2Array:
			row[point_column] = row[point_column].duplicate()
	return captured

func _draw() -> void:
	for row in _lines:
		draw_polyline(row[0], row[1], row[2], true)

func _draw_overlay() -> void:
	_draw_marks(overlay_layer, _overlay_marks)
	_draw_labels(overlay_layer, _labels[1])

func _draw_foreground() -> void:
	_draw_marks(_foreground, _marks)
	_draw_sprites(_foreground, _foreground.rows)
	_draw_labels(_foreground, _labels[0])

func _draw_sprites(target: CanvasItem, rows: Array) -> void:
	for row: Array in rows:
		var region: Rect2 = row[1]
		target.draw_set_transform_matrix(row[2])
		target.draw_texture_rect_region(row[0], Rect2(-region.size * 0.5, region.size), region, row[3], false, false)
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
