class_name WeaponIcons
extends RefCounted

# 武器图标与选择控件：生成纯白像素剪影切片以及选择单元格控件。
# 数据来源统一由 WeaponRegistry 读取，与武器配置保持一致。

static var _silhouette_cache: Dictionary = {}

static func silhouette(type_id: int) -> Texture2D:
	if _silhouette_cache.has(type_id):
		return _silhouette_cache[type_id]
	var region: Rect2 = WeaponRegistry.definition(type_id)["region"]
	var atlas := preload("res://assets/textures/weapons.png").get_image()
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

static func make_weapon_check(type_id: int, checked: bool) -> CheckButton:
	var button := CheckButton.new()
	button.text = WeaponRegistry.name_of(type_id)
	button.icon = silhouette(type_id)
	button.button_pressed = checked
	button.theme = UiFactory.MENU_THEME
	return button
