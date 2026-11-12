class_name WeaponIcons
extends RefCounted

# 武器图标与选择控件：生成纯白像素剪影切片以及选择单元格控件。
# 数据来源统一由 WeaponRegistry 读取，与武器配置保持一致。

static var _silhouette_cache: Dictionary = {}

static func silhouette(type_id: int) -> Texture2D:
	if _silhouette_cache.has(type_id):
		return _silhouette_cache[type_id]
	var region: Rect2 = WeaponRegistry.definition(type_id)["region"]
	var atlas := WeaponBase.SHEET.get_image()
	if atlas.is_compressed():
		atlas.decompress()
	var img := atlas.get_region(Rect2i(region))
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.05:
				img.set_pixel(x, y, Color.WHITE)
	img.resize(img.get_width() * 3, img.get_height() * 3, Image.INTERPOLATE_NEAREST)
	var texture := ImageTexture.create_from_image(img)
	_silhouette_cache[type_id] = texture
	return texture

# 构造通用武器选择单元格：包含勾选开关、固定尺寸剪影图标与武器名称。
# 剪影通过指定尺寸的 TextureRect 容器约束排版。
static func make_weapon_check(type_id: int, checked: bool, font_size: int, on_toggle: Callable) -> HBoxContainer:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 6)
	var cb := CheckButton.new()
	cb.button_pressed = checked
	# 通过界面工厂统一开关按钮样式与尺寸
	UiFactory.style_check(cb, font_size)
	cb.toggled.connect(on_toggle)
	cell.add_child(cb)
	var icon := TextureRect.new()
	icon.texture = silhouette(type_id)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Vector2(96, 30)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cell.add_child(icon)
	# 使用统一工厂生成像素字体标签
	var l := UiFactory.label(WeaponRegistry.name_of(type_id), font_size)
	cell.add_child(l)
	return cell

