class_name SpriteBounds
extends RefCounted

# 从 Sprite2D 的像素求"哪一块真的画了东西"的包围盒。
#
# 用途:地面武器(WeaponPickup)的碰撞箱 —— 武器 .tscn 里**没有**碰撞体,手画 6 个矩形
# 既烦又会在换贴图后失真,所以按 alpha 自动求一次。
#
# ★ 参考系(最容易写错的点):返回的 Rect2 以 **sprite 的局部原点**为参考,
#   而 Sprite2D 默认 `centered = true` → 原点在**贴图/region 的中心**,不是左上角。
#   `region_enabled` 时原点在 region 中心(region 之外的像素根本不参与扫描)。
#
# ★ 与**手持态**的差异:weapon_base 的 sprite 有 _base_sprite_pos 偏移、换弹/后坐抖动
#   (weapon_base.gd 的 _update_reload_pose)与 facing 的 scale.x 翻转。地面态一律取
#   **facing=1、无抖动**的基准,所以本工具只吃 sprite 本身,不吃那些运行时偏移。

static var _cache: Dictionary = {}


static func from_sprite(spr: Sprite2D, alpha_threshold: float = 0.05) -> Rect2:
	if spr == null or spr.texture == null:
		return Rect2()
	var tex := spr.texture
	var region := Rect2i(spr.region_rect) if spr.region_enabled \
		else Rect2i(0, 0, tex.get_width(), tex.get_height())
	if region.size.x <= 0 or region.size.y <= 0:
		return Rect2()

	var key := "%d:%s" % [tex.get_instance_id(), str(region)]
	if _cache.has(key):
		return _cache[key]

	var img := tex.get_image()
	if img == null:
		return Rect2()
	if img.is_compressed():
		img.decompress()

	# 逐像素扫 alpha 求包围盒。武器贴图是 32px 级的小图,一次扫描开销可忽略,
	# 且结果进 _cache(同一贴图只扫一次)。
	var min_x := region.size.x
	var min_y := region.size.y
	var max_x := -1
	var max_y := -1
	for y in region.size.y:
		for x in region.size.x:
			if img.get_pixel(region.position.x + x, region.position.y + y).a > alpha_threshold:
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	if max_x < 0:
		_cache[key] = Rect2()
		return Rect2()

	# region 坐标 → sprite 局部坐标:减去 region 中心(centered 语义)
	var half := Vector2(region.size) * 0.5
	var out := Rect2(Vector2(min_x, min_y) - half, Vector2(max_x - min_x + 1, max_y - min_y + 1))
	_cache[key] = out
	return out
