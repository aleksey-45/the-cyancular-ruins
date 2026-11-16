class_name FormLight
extends RefCounted
# 形体光:**渲染策略由 TAG 决定**(flat / ellipsoid / cylinder / sdf / parts / guide)。
#
# ★ 为什么需要 tag:不同资产该被当成不同形状 —— 玩家和鸟是团块(椭球),枪是长条(圆柱),
#   贴图和 UI 根本不该有体积(flat)。用一套模型套所有资产必然别扭(枪被当成球、鸟被切面)。
# ★ 半尺寸用**质心椭圆拟合**(SpriteNormalMap.ellipse_fit,按 alpha 质心 + 二阶矩),一个尺寸全帧共用。
# ★ 已经有自定义材质的节点一律不碰(黑鸟的剪影 shader 会覆写 COLOR)。

const SHADER_PATH := "res://core/present/form_light.gdshader"

const MODEL_FLAT := 0
const MODEL_ELLIPSOID := 1
const MODEL_CYLINDER := 2
const MODEL_SDF := 3
const MODEL_PARTS := 4
const MODEL_GUIDE := 5
# 打光辅助图约定:与主图集同目录、同布局的 `<atlas 主名>_shade.png`;缺失时 guide 回退 parts。
const GUIDE_SUFFIX := "_shade.png"

static var _mats: Dictionary = {}   # (atlas, model int, size) -> ShaderMaterial
static var _gain_mul: Dictionary = {}   # material -> 该材质的 gain 倍率(玩家要更柔,枪械要更狠)
static var _override: Dictionary = {}   # material -> 覆盖全局 form 参数的键值(玩家专属调参走这里)
static var _sh: Shader = null
static var _tried: bool = false
static var _unique_seq := 0
# 晚创建的材质(敌人/子弹/武器)也要拿到同一套参数:set_* 只更新这里,建材质时再补推。
static var _steps_cur := 0.0
static var _dither_cur := 1.0
static var _boost_cur := 0.05
static var _bulge_cur := 1.0
static var _edge_lo_cur := 0.20
static var _edge_hi_cur := 0.80


static func model_id(name: String) -> int:
	match name:
		"ellipsoid":
			return MODEL_ELLIPSOID
		"cylinder":
			return MODEL_CYLINDER
		"sdf":
			return MODEL_SDF
		"parts":
			return MODEL_PARTS
		"guide":
			return MODEL_GUIDE
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
static func material_for(atlas: Texture2D, model_id: int, half: Vector2, center: Vector2 = Vector2.ZERO, round_mix: float = 0.0, overrides: Dictionary = {}, part_tex: Texture2D = null, unique: bool = false, shade_tex: Texture2D = null) -> ShaderMaterial:
	var part_id := part_tex.get_instance_id() if part_tex != null else 0
	var shade_id := shade_tex.get_instance_id() if shade_tex != null else 0
	var key := "%s|%d|%s|%s|%.2f|%s|%d|%d" % [atlas.resource_path if atlas != null else "", model_id, str(half), str(center), round_mix, str(overrides), part_id, shade_id]
	if unique:
		_unique_seq += 1
		key = "u%d|%s" % [_unique_seq, key]
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
	mat.set_shader_parameter("shape_round", clampf(round_mix, 0.0, 1.0))
	mat.set_shader_parameter("steps", _steps_cur)
	mat.set_shader_parameter("dither", _dither_cur)
	mat.set_shader_parameter("boost", _boost_cur)
	mat.set_shader_parameter("bulge", _bulge_cur)
	mat.set_shader_parameter("edge_lo", _edge_lo_cur)
	mat.set_shader_parameter("edge_hi", _edge_hi_cur)
	_apply_overrides(mat, overrides)
	if atlas != null and model_id == MODEL_SDF:
		mat.set_shader_parameter("normal_tex", SpriteNormalMap.for_texture(atlas))
	if part_tex != null:
		mat.set_shader_parameter("part_tex", part_tex)
	if shade_tex != null:
		mat.set_shader_parameter("shade_tex", shade_tex)
	_mats[key] = mat
	return mat


static func push(sun_dir: Vector2, gain: float) -> void:
	for k in _mats:
		var mat: ShaderMaterial = _mats[k]
		mat.set_shader_parameter("sun_dir", sun_dir)
		# 逐材质倍率:同一个全局 gain 下,玩家要柔一点、暗色小物件要更狠。
		var mul := float(_gain_mul.get(mat, 1.0))
		mat.set_shader_parameter("gain", clampf(gain * mul, 0.0, 1.0))


static func set_steps(v: float) -> void:
	var s := clampf(v, 0.0, 6.0)
	_steps_cur = s
	for k in _mats:
		var m: ShaderMaterial = _mats[k]
		m.set_shader_parameter("steps", float(_override.get(m, {}).get("steps", s)))


static func set_bulge(v: float) -> void:
	var b := clampf(v, 0.5, 3.0)
	_bulge_cur = b
	for k in _mats:
		var m: ShaderMaterial = _mats[k]
		m.set_shader_parameter("bulge", float(_override.get(m, {}).get("bulge", b)))


static func set_dither(v: float) -> void:
	var d := clampf(v, 0.0, 1.0)
	_dither_cur = d
	for k in _mats:
		var m: ShaderMaterial = _mats[k]
		m.set_shader_parameter("dither", float(_override.get(m, {}).get("dither", d)))


static func set_edge(lo: float, hi: float) -> void:
	var l := clampf(lo, -0.5, 1.0)
	var h := clampf(hi, -0.5, 1.5)
	_edge_lo_cur = l
	_edge_hi_cur = h
	for k in _mats:
		var m: ShaderMaterial = _mats[k]
		var ov: Dictionary = _override.get(m, {})
		m.set_shader_parameter("edge_lo", float(ov.get("edge_lo", l)))
		m.set_shader_parameter("edge_hi", float(ov.get("edge_hi", h)))


static func set_boost(v: float) -> void:
	var b := clampf(v, 0.0, 0.5)
	_boost_cur = b
	for k in _mats:
		var m: ShaderMaterial = _mats[k]
		m.set_shader_parameter("boost", float(_override.get(m, {}).get("boost", b)))


static func _apply_overrides(mat: ShaderMaterial, overrides: Dictionary) -> void:
	if overrides.is_empty():
		return
	_override[mat] = overrides.duplicate()
	for key in overrides:
		mat.set_shader_parameter(str(key), float(overrides[key]))


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


## guide 模型的打光辅助图:图集同目录的 `<主名>_shade.png`,尺寸必须与图集一致;取不到返回 null。
static func guide_texture(atlas: Texture2D) -> Texture2D:
	if atlas == null:
		return null
	var path := atlas.resource_path
	if path.is_empty():
		return null
	var shade_path := path.get_basename() + GUIDE_SUFFIX
	if not ResourceLoader.exists(shade_path):
		return null
	var tex := load(shade_path) as Texture2D
	if tex == null or tex.get_width() != atlas.get_width() or tex.get_height() != atlas.get_height():
		return null
	return tex


## 给画布项挂形体光。`model_name` = flat / ellipsoid / cylinder / sdf / parts / guide(辅助图缺失时回退 parts)。
static func attach(item: CanvasItem, model_name: String = "flat", gain_mul: float = 1.0, round_mix: float = 0.0, overrides: Dictionary = {}, unique: bool = false) -> void:
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
	var part_tex: Texture2D = null
	var shade_tex: Texture2D = null
	if mid == MODEL_GUIDE:
		shade_tex = guide_texture(atlas)
		if shade_tex == null:
			mid = MODEL_PARTS
	if mid == MODEL_PARTS:
		part_tex = SpriteNormalMap.for_parts(regions_of(item), atlas)
	var mat := material_for(atlas, mid, half, center, round_mix, overrides, part_tex, unique, shade_tex)
	if mat == null:
		return
	if not is_equal_approx(gain_mul, 1.0):
		_gain_mul[mat] = gain_mul
	item.material = mat
