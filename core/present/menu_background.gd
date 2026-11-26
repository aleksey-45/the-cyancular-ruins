extends ColorRect

const MAP := "res://maps/newfactory.cyrm"
const SEGMENT_SEC := 48.0
const SEG_TURN_DEG := 120.0
const SEG_TURN_EDGE_FRAC := 0.25
const SEG_MOVE_BIAS := 0.8
const SEG_PATH_SEED := 20261003

static var _map_material := ShaderMaterial.new()
var _sky := Daylight.new()
var _rng := RandomNumberGenerator.new()
var _seg_t := 0.0
var _seg_from := Vector2.ZERO
var _seg_to := Vector2.ZERO
var _seg_index := 0

func _ready() -> void:
	_sky.show_behind_parent = true
	UiDesign.cover(self, _sky)
	if _map_material.shader == null:
		_map_material.shader = preload("res://core/present/menu_fisheye.gdshader")
		_set_map(CyrmMap.load_file(MAP))
	material = _map_material
	_rng.seed = SEG_PATH_SEED
	_seg_from = _random_target()
	_seg_to = _random_target()
	_process(0.0)

static func _set_map(map: Dictionary) -> void:
	var tile_layers := {}
	var tiles: Array[Image] = []
	var indices := PackedFloat32Array()
	for tile: int in map.layers[CyrmMap.SCENE]:
		if not tile_layers.has(tile):
			tile_layers[tile] = tiles.size()
			tiles.append(TerrainAtlas.tile_image(TerrainAtlas.SRC_TILE, tile))
		indices.append(tile_layers[tile])
	var tile_textures := Texture2DArray.new()
	tile_textures.create_from_images(tiles)
	var layout := Image.create_from_data(map.size.x, map.size.y, false, Image.FORMAT_RF, indices.to_byte_array())
	_map_material.set_shader_parameter("map_size", Vector2(map.size) / TerrainAtlas.SUBS_PER_TEXTURE)
	_map_material.set_shader_parameter("tile_index", ImageTexture.create_from_image(layout))
	_map_material.set_shader_parameter("tiles", tile_textures)

func _random_target() -> Vector2:
	return Vector2(_rng.randf_range(0.2, 0.8), _rng.randf_range(0.2, 0.8))

func _process(delta: float) -> void:
	_seg_t += delta
	while _seg_t >= SEGMENT_SEC:
		_seg_t -= SEGMENT_SEC
		_seg_index += 1
		_seg_from = _seg_to
		_seg_to = _random_target()
	self_modulate = _sky.set_minute(Daylight.minute_at(_seg_index * SEGMENT_SEC + _seg_t))
	var u := clampf(_seg_t / SEGMENT_SEC, 0.0, 1.0)
	var s: float = pow(smoothstep(0.0, 1.0, u), SEG_MOVE_BIAS)
	var e := _trapezoid(u)
	var turn: float = e if (_seg_index % 2) == 0 else 1.0 - e
	set_instance_shader_parameter("view_center", _seg_from.lerp(_seg_to, s))
	set_instance_shader_parameter("rot_angle", deg_to_rad(SEG_TURN_DEG * turn))

static func _trapezoid(u: float) -> float:
	var a := SEG_TURN_EDGE_FRAC
	var v: float = 1.0 / (1.0 - a)
	if u < a:
		return v * u * u / (2.0 * a)
	if u > 1.0 - a:
		return 1.0 - v * (1.0 - u) * (1.0 - u) / (2.0 * a)
	return v * (a * 0.5 + (u - a))
