class_name SpriteBounds
extends RefCounted


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

	var half := Vector2(region.size) * 0.5
	var out := Rect2(Vector2(min_x, min_y) - half, Vector2(max_x - min_x + 1, max_y - min_y + 1))
	_cache[key] = out
	return out
