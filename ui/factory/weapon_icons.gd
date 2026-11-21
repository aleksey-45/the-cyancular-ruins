class_name WeaponIcons
extends RefCounted

static var _atlas: ImageTexture

static func silhouette(type_id: int) -> Texture2D:
	if _atlas == null:
		var image := preload("res://assets/textures/weapons.png").get_image()
		var white := image.duplicate() as Image
		white.fill(Color.WHITE)
		image.blit_rect_mask(white, image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
		image.resize(image.get_width() * 3, image.get_height() * 3, Image.INTERPOLATE_NEAREST)
		_atlas = ImageTexture.create_from_image(image)
	var region := Rect2i(WeaponRegistry.definition(type_id).region)
	var icon := AtlasTexture.new()
	icon.atlas = _atlas
	icon.region = Rect2i(region.position * 3, region.size * 3)
	icon.filter_clip = true
	return icon

static func make_weapon_check(type_id: int, checked: bool) -> CheckButton:
	var button := CheckButton.new()
	button.text = WeaponRegistry.name_of(type_id)
	button.icon = silhouette(type_id)
	button.button_pressed = checked
	button.theme = UiFactory.MENU_THEME
	return button
