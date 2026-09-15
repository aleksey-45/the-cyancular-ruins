class_name WeaponIcons
extends RefCounted

# 武器图标与选择格(纯 UI):纯白剪影切片 + 「勾选框 + 剪影 + 名称」格子。
#
# 原先长在 `scenes/player/weapon_component.gd` 里 —— 那是**武器子系统**(注册表/换枪/移动惩罚/
# 后坐/残弹记忆),与渲染毫无关系;而这两个函数的消费者**全是 UI**:lobby_page 的禁用武器网格、
# main_menu 的选枪栏、ui/hud 的左下角武器显示。2026-09-15 阶段 4.1 拆出来。
#
# ★ 数据仍来自 `WeaponComponent`:WEAPONS(槽位→场景路径)与 DISPLAY_NAMES(中文名)是注册表的
#   单一来源,本文件**不复制一份**(复制了就会出现「加了新武器只有一边知道」)。


# 纯白像素剪影缓存(slot → Texture2D):从武器场景的 Sprite2D 图集切片,
# 全像素刷白保留 alpha,3× 最近邻放大(与瓦片/8bit 音效同风格,零美术素材)。
static var _silhouette_cache: Dictionary = {}

static func silhouette(slot: int) -> Texture2D:
	if _silhouette_cache.has(slot):
		return _silhouette_cache[slot]
	var tex: Texture2D = null
	var scene: PackedScene = load(WeaponComponent.WEAPONS.get(str(slot), "")) if WeaponComponent.WEAPONS.has(str(slot)) else null
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
	_silhouette_cache[slot] = tex
	return tex

# 武器选择格(共用):勾选框 + 固定尺寸白剪影 + 名称。
# 剪影原始宽度可达 252px,直接挂 CheckButton.icon 会把横排面板撑出屏幕(实测),
# 这里用固定尺寸 TextureRect 约束。CheckButton 引用存 meta("cb") 供调用方读取状态。
static func make_weapon_check(slot: int, checked: bool, font_size: int, on_toggle: Callable) -> HBoxContainer:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 6)
	var cb := CheckButton.new()
	cb.button_pressed = checked
	# 走 UiFactory.style_check:默认主题的 CheckButton 在「关」态没有可见轨道,只剩一个
	# 小灰点 —— 本函数同时给主菜单单人面板与匹配页对战选项用,两处一起修。
	UiFactory.style_check(cb, font_size)
	cb.toggled.connect(func(on: bool) -> void: on_toggle.call(on))
	cell.set_meta("cb", cb)   # 挂 cell 上(调用方统一 cell.get_meta("cb") 取勾选框)
	cell.add_child(cb)
	var icon := TextureRect.new()
	icon.texture = silhouette(slot)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Vector2(96, 30)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cell.add_child(icon)
	# 走 UiFactory:它同时写 font 与 font_size 两个 override。原先只写字号 → 本行文字
	# 落回默认主题字体,与同页面其它 Label(像素字体)不一致。
	var l := UiFactory.label("%d %s" % [slot, WeaponComponent.DISPLAY_NAMES[slot]], font_size)
	cell.add_child(l)
	return cell
