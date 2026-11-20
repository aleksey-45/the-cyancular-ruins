class_name FormLight
extends RefCounted

# siri 版形体光:所有普通精灵共用一个 canvas_item 材质,用 alpha 梯度近似法线。
# 这是 main 逐资产模型(椭球/圆柱/SDF)的降级近似;接口与 main 保持同形。

const SHADER_PATH := "res://core/present/form_light.gdshader"

static var _mat: ShaderMaterial
static var _shader: Shader
static var _tried := false
static var _steps := 4.0
static var _dither := 0.3
static var _boost := 0.05
static var _bulge := 1.0
static var _edge_lo := 0.20
static var _edge_hi := 0.80
static var _gain := 0.0


static func material() -> ShaderMaterial:
	if _mat != null:
		return _mat
	if not _tried:
		_tried = true
		_shader = load(SHADER_PATH) as Shader
	if _shader == null:
		push_error("FormLight: 加载不到 %s" % SHADER_PATH)
		return null
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_apply()
	return _mat


static func _apply() -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("steps", _steps)
	_mat.set_shader_parameter("dither", _dither)
	_mat.set_shader_parameter("boost", _boost)
	_mat.set_shader_parameter("bulge", _bulge)
	_mat.set_shader_parameter("edge_lo", _edge_lo)
	_mat.set_shader_parameter("edge_hi", _edge_hi)
	_mat.set_shader_parameter("gain", _gain)


static func set_boost(v: float) -> void:
	_boost = v
	_apply()


static func set_steps(v: float) -> void:
	_steps = v
	_apply()


static func set_dither(v: float) -> void:
	_dither = v
	_apply()


static func set_bulge(v: float) -> void:
	_bulge = v
	_apply()


static func set_edge(lo: float, hi: float) -> void:
	_edge_lo = lo
	_edge_hi = hi
	_apply()


static func push(sun_dir: Vector2, gain: float) -> void:
	_gain = gain
	if _mat == null:
		material()
	if _mat == null:
		return
	_mat.set_shader_parameter("sun_dir", sun_dir.normalized())
	_mat.set_shader_parameter("gain", gain)
