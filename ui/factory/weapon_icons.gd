class_name WeaponIcons
extends RefCounted



static var _silhouette_cache: Dictionary = {}

static func silhouette(type_id: int) -> Texture2D:
	if _silhouette_cache.has(type_id):
		return _silhouette_cache[type_id]
	var tex: Texture2D = null
	var scene_path := WeaponRegistry.scene_of(type_id)
	var scene: PackedScene = load(scene_path) if not scene_path.is_empty() else null
	if scene != null:
		var inst := scene.instantiate()
		var sprites := inst.find_children("*", "Sprite2D", true, false)
		if not sprites.is_empty():
			var spr: Sprite2D = sprites[0]
			if spr.region_enabled and spr.texture != null:
				var atlas := spr.texture.get_image()
				if atlas != null:
					if atlas.is_compressed():
						atlas.decompress()
					var r: Rect2 = spr.region_rect
					var img := atlas.get_region(Rect2i(r.position, r.size))
					for y in img.get_height():
						for x in img.get_width():
							if img.get_pixel(x, y).a > 0.05:
								img.set_pixel(x, y, Color.WHITE)
					img.resize(img.get_width() * 3, img.get_height() * 3, Image.INTERPOLATE_NEAREST)
					tex = ImageTexture.create_from_image(img)
		inst.free()
	_silhouette_cache[type_id] = tex
	return tex

static func make_weapon_check(type_id: int, checked: bool, font_size: int, on_toggle: Callable) -> HBoxContainer:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 6)
	var cb := CheckButton.new()
	cb.button_pressed = checked
	UiFactory.style_check(cb, font_size)
	cb.toggled.connect(func(on: bool) -> void: on_toggle.call(on))
	cell.set_meta("cb", cb)
	cell.add_child(cb)
	var icon := TextureRect.new()
	icon.texture = silhouette(type_id)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Vector2(96, 30)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cell.add_child(icon)
	var l := UiFactory.label(WeaponRegistry.name_of(type_id), font_size)
	cell.add_child(l)
	return cell
