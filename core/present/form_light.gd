class_name FormLight
extends RefCounted

# siri 版形体光:所有普通精灵共用一个 canvas_item 材质,用 alpha 梯度近似法线。
# 这是 main 逐资产模型(椭球/圆柱/SDF)的降级近似;接口与 main 保持同形。
# 材质按 WorldCanvas 实例持有,FormLight 只维护活动材质列表,退出时随节点释放。

const SHADER_PATH := "res://core/present/form_light.gdshader"

static var _materials: Array[ShaderMaterial] = []
static var _steps := 4.0
static var _dither := 0.3
static var _boost := 0.05
static var _bulge := 1.0
static var _edge_lo := 0.20
static var _edge_hi := 0.80
static var _gain := 0.0
static var _sun_dir := Vector2(0.45, -0.89)


static func attach() -> ShaderMaterial:
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_error("FormLight: 加载不到 %s" % SHADER_PATH)
		return null
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_materials.append(mat)
	_apply(mat)
	mat.set_shader_parameter("sun_dir", _sun_dir.normalized())
	mat.set_shader_parameter("gain", _gain)
	return mat


static func detach(mat: ShaderMaterial) -> void:
	if mat != null:
		_materials.erase(mat)


static func _apply(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("steps", _steps)
	mat.set_shader_parameter("dither", _dither)
	mat.set_shader_parameter("boost", _boost)
	mat.set_shader_parameter("bulge", _bulge)
	mat.set_shader_parameter("edge_lo", _edge_lo)
	mat.set_shader_parameter("edge_hi", _edge_hi)
	mat.set_shader_parameter("gain", _gain)
	mat.set_shader_parameter("sun_dir", _sun_dir.normalized())


static func _broadcast() -> void:
	for mat in _materials:
		_apply(mat)


static func set_boost(v: float) -> void:
	_boost = v
	_broadcast()


static func set_steps(v: float) -> void:
	_steps = v
	_broadcast()


static func set_dither(v: float) -> void:
	_dither = v
	_broadcast()


static func set_bulge(v: float) -> void:
	_bulge = v
	_broadcast()


static func set_edge(lo: float, hi: float) -> void:
	_edge_lo = lo
	_edge_hi = hi
	_broadcast()


static func push(sun_dir: Vector2, gain: float) -> void:
	_sun_dir = sun_dir
	_gain = gain
	_broadcast()
