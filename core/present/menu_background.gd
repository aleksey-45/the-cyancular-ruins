extends ColorRect

const MAP := "res://maps/newfactory.cyrm"
const CELL_PX := 32
const SEGMENT_SEC := 48.0
const SEG_TURN_DEG := 120.0
const SEG_TURN_EDGE_FRAC := 0.25
const SEG_MOVE_BIAS := 0.8
const SEG_PATH_SEED := 20261003

var _sky := Daylight.new()
var _mat := ShaderMaterial.new()
var _map_cells: Vector2
var _rng := RandomNumberGenerator.new()
var _seg_t := 0.0
var _seg_from := Vector2.ZERO
var _seg_to := Vector2.ZERO
var _seg_index := 0

func _ready() -> void:
	_sky.show_behind_parent = true
	UiFactory.cover(self, _sky)
	var tex := TerrainAtlas.terrain_texture(MAP, CELL_PX)
	_map_cells = Vector2(tex.get_width(), tex.get_height()) / float(CELL_PX)
	_mat.shader = preload("res://core/present/menu_fisheye.gdshader")
	_mat.set_shader_parameter("map_tex", tex)
	_mat.set_shader_parameter("map_size", _map_cells)
	material = _mat
	_rng.seed = SEG_PATH_SEED
	_seg_from = _random_target()
	_seg_to = _random_target()
	_process(0.0)

func _random_target() -> Vector2:
	return Vector2(_rng.randf_range(0.2, 0.8) * _map_cells.x,
			_rng.randf_range(0.2, 0.8) * _map_cells.y)

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
	_mat.set_shader_parameter("view_center", _seg_from.lerp(_seg_to, s))
	_mat.set_shader_parameter("rot_angle", deg_to_rad(SEG_TURN_DEG * turn))

static func _trapezoid(u: float) -> float:
	var a := SEG_TURN_EDGE_FRAC
	var v: float = 1.0 / (1.0 - a)
	if u < a:
		return v * u * u / (2.0 * a)
	if u > 1.0 - a:
		return 1.0 - v * (1.0 - u) * (1.0 - u) / (2.0 * a)
	return v * (a * 0.5 + (u - a))
