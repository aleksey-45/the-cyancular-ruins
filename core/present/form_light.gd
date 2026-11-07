class_name FormLight
extends RefCounted
# 形体光:**渲染策略由 TAG 决定**(flat / ellipsoid / cylinder / sdf)。
#
# ★ 为什么需要 tag:不同资产该被当成不同形状 —— 玩家和鸟是团块(椭球),枪是长条(圆柱),
#   贴图和 UI 根本不该有体积(flat)。用一套模型套所有资产必然别扭(枪被当成球、鸟被切面)。
# ★ 半尺寸用**剪影包围盒**(所有帧取最大),保证动画里法线不抖。
# ★ 已经有自定义材质的节点一律不碰(黑鸟的剪影 shader 会覆写 COLOR)。

const SHADER_PATH := "res://core/present/form_light.gdshader"

const MODEL_FLAT := 0
const MODEL_ELLIPSOID := 1
const MODEL_CYLINDER := 2
const MODEL_SDF := 3

static var _mats: Dictionary = {}   # (atlas, model int, size) -> ShaderMaterial
static var _sh: Shader = null
static var _tried: bool = false


static func model_id(name: String) -> int:
	match name:
		"ellipsoid":
			return MODEL_ELLIPSOID
		"cylinder":
			return MODEL_CYLINDER
		"sdf":
			return MODEL_SDF
		_:
			return MODEL_FLAT


static func _shader() -> Shader:
	if _sh != null or _tried:
		return _sh
	_tried = true
	_sh = load(SHADER_PATH) as Shader
	if _sh == null:
		push_error("FormLight: 加载不到 %s" % SHADER_PATH)
	return _sh


## 取(或建)材质:key = 图集 + 模型 + 半尺寸。
static func material_for(atlas: Texture2D, model_id: int, half: Vector2, center: Vector2 = Vector2.ZERO) -> ShaderMaterial:
	var key := "%s|%d|%s|%s" % [atlas.resource_path if atlas != null else "", model_id, str(half), str(center)]
	if _mats.has(key):
		return _mats[key]
	var sh := _shader()
	if sh == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("light_model", model_id)
	mat.set_shader_parameter("light_size", half)
	mat.set_shader_parameter("light_center", center)
	if atlas != null and model_id == MODEL_SDF:
		mat.set_shader_parameter("normal_tex", SpriteNormalMap.for_texture(atlas))
	_mats[key] = mat
	return mat


static func push(sun_dir: Vector2, gain: float) -> void:
	for k in _mats:
		var mat: ShaderMaterial = _mats[k]
		mat.set_shader_parameter("sun_dir", sun_dir)
		mat.set_shader_parameter("gain", clampf(gain, 0.0, 1.0))


static func set_steps(v: float) -> void:
	var s := clampf(v, 0.0, 6.0)
	for k in _mats:
		(_mats[k] as ShaderMaterial).set_shader_parameter("steps", s)


static func set_bulge(v: float) -> void:
	var b := clampf(v, 0.5, 3.0)
	for k in _mats:
		(_mats[k] as ShaderMaterial).set_shader_parameter("bulge", b)


static func set_dither(v: float) -> void:
	var d := clampf(v, 0.0, 1.0)
	for k in _mats:
		(_mats[k] as ShaderMaterial).set_shader_parameter("dither", d)


static func set_boost(v: float) -> void:
	var b := clampf(v, 0.0, 0.5)
	for k in _mats:
		(_mats[k] as ShaderMaterial).set_shader_parameter("boost", b)


## 取图集(用于算剪影包围盒)。
static func atlas_of(item: CanvasItem) -> Texture2D:
	if item is Sprite2D:
		var s := item as Sprite2D
		if s.texture is AtlasTexture:
			return (s.texture as AtlasTexture).atlas
		return s.texture
	if item is AnimatedSprite2D:
		var a := item as AnimatedSprite2D
		if a.sprite_frames == null:
			return null
		var names := a.sprite_frames.get_animation_names()
		if names.is_empty():
			return null
		var t := a.sprite_frames.get_frame_texture(names[0], 0)
		if t is AtlasTexture:
			return (t as AtlasTexture).atlas
		return t
	return null


## 取所有帧的区域(用于算包围盒)。
static func regions_of(item: CanvasItem) -> Array:
	var out := []
	if item is Sprite2D:
		var s := item as Sprite2D
		if s.texture is AtlasTexture:
			out.append((s.texture as AtlasTexture).region)
		elif s.texture != null:
			out.append(Rect2(Vector2.ZERO, s.texture.get_size()))
	elif item is AnimatedSprite2D:
		var a := item as AnimatedSprite2D
		if a.sprite_frames != null:
			for anim in a.sprite_frames.get_animation_names():
				for i in a.sprite_frames.get_frame_count(anim):
					var t := a.sprite_frames.get_frame_texture(anim, i)
					if t is AtlasTexture:
						out.append((t as AtlasTexture).region)
					elif t != null:
						out.append(Rect2(Vector2.ZERO, t.get_size()))
	return out


## 给画布项挂形体光。`model_name` = flat / ellipsoid / cylinder / sdf。
static func attach(item: CanvasItem, model_name: String = "flat") -> void:
	if item == null or item.material != null:
		return
	var mid := model_id(model_name)
	if mid == MODEL_FLAT:
		return   # 不做形体光,省一次材质切换
	var atlas := atlas_of(item)
	var half := Vector2(24.0, 24.0)
	var center := Vector2.ZERO
	if atlas != null:
		var img := atlas.get_image()
		if img != null and not img.is_empty():
			var fit := SpriteNormalMap.ellipse_fit(img, regions_of(item))
			center = fit["center"]
			half = fit["size"]
	var mat := material_for(atlas, mid, half, center)
	if mat == null:
		return
	item.material = mat
