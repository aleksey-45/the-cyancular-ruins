class_name WeaponIcons
extends RefCounted

# 武器图标与选择控件：生成纯白像素剪影切片以及选择单元格控件。
# 数据来源统一由 WeaponRegistry 读取，与武器配置保持一致。

# 纯白像素剪影纹理缓存（按武器类型 ID 索引）。
# 从武器场景中切取精灵图集切片并保留透明通道，使用 3 倍最近邻放大以契合像素风格。
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

# 构造通用武器选择单元格：包含勾选开关、固定尺寸剪影图标与武器名称。
# 剪影通过指定尺寸的 TextureRect 容器约束排版，开关引用保存在元数据 cb 中供调用方获取。
static func make_weapon_check(type_id: int, checked: bool, font_size: int, on_toggle: Callable) -> HBoxContainer:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 6)
	var cb := CheckButton.new()
	cb.button_pressed = checked
	# 通过界面工厂统一开关按钮样式与尺寸
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
	# 使用统一工厂生成像素字体标签
	var l := UiFactory.label(WeaponRegistry.name_of(type_id), font_size)
	cell.add_child(l)
	return cell

