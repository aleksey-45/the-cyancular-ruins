class_name SpriteFramesIO
extends RefCounted
# 精灵帧的唯一入口:从 `<name>.frames.json` 构建 SpriteFrames。
#
# ★ 为什么不再用手写 .tres:那里面每个 AtlasTexture 的 Rect2 都是人手填的,没有任何地方
#   能推导或校验它。实测 player_frames.tres 出现过 1px 漂移(同一行的帧分别落在 y=0 和 y=1),
#   而 .tres 里看不出这是错的。改成"网格 + 每帧用 [列, 行] 指格子"之后,坐标是算出来的。
# ★ 同一路径只构建一次并缓存:本体与 PvP 副本必须共用同一份实例(副本侧的注释要求"只有一处帧数据")。

static var _cache: Dictionary = {}


## 读 JSON 并构建。失败返回 null(调用方保持原样即可,不要静默产出半成品)。
## `image_field` 用于同一份 cells 生成**另一张图**的帧:发光遮罩就用 "light_image"
## (同一套网格 ⇒ 帧索引天然同步,不会错位,也不用第二份 JSON)。
static func load_json(json_path: String, image_field: String = "image") -> SpriteFrames:
	var cache_key := "%s|%s" % [json_path, image_field]
	if _cache.has(cache_key):
		return _cache[cache_key]
	var text := FileAccess.get_file_as_string(json_path)
	if text.is_empty():
		push_error("SpriteFramesIO: 读不到 %s" % json_path)
		return null
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SpriteFramesIO: %s 不是合法 JSON 对象" % json_path)
		return null
	var dict: Dictionary = parsed
	var image_name := str(dict.get(image_field, ""))
	if image_name.is_empty():
		push_error("SpriteFramesIO: %s 没有 %s 字段" % [json_path, image_field])
		return null
	var tex: Texture2D = load(json_path.get_base_dir().path_join(image_name))
	if tex == null:
		push_error("SpriteFramesIO: %s 的 image 加载失败" % json_path)
		return null
	# 发光遮罩可以自动补一圈**很弱的边缘光**:遮罩只标"哪几个像素发光",不含光晕;
	# 光晕由这里按半径衰减生成,美术不用重画。半径/强度写在 JSON 的 light_halo_px / light_halo_strength。
	if image_field == "light_image" and float(dict.get("light_halo_px", 0)) > 0.0:
		tex = _with_halo(tex, int(dict.get("light_halo_px", 0)), float(dict.get("light_halo_strength", 0.3)))
		if tex == null:
			return null
	var frame_size := _as_vec2i(dict.get("frame_size"), Vector2i(48, 48))
	var origin := _as_vec2i(dict.get("grid_origin"), Vector2i.ZERO)
	var pitch := _as_vec2i(dict.get("grid_pitch"), frame_size)
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	var anims: Dictionary = dict.get("animations", {})
	for anim_name in anims:
		var spec: Dictionary = anims[anim_name]
		var anim := StringName(str(anim_name))
		frames.add_animation(anim)
		frames.set_animation_speed(anim, float(spec.get("fps", 8.0)))
		frames.set_animation_loop(anim, bool(spec.get("loop", true)))
		var cells: Array = spec.get("cells", [])
		var durations: Array = spec.get("durations", [])
		for i in cells.size():
			var cell: Array = cells[i]
			if cell.size() < 2:
				push_error("SpriteFramesIO: %s/%s 第 %d 帧的 cells 项不是 [列, 行]" % [json_path, anim_name, i])
				continue
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(
					float(origin.x + int(cell[0]) * pitch.x),
					float(origin.y + int(cell[1]) * pitch.y),
					float(frame_size.x), float(frame_size.y))
			var dur := float(durations[i]) if i < durations.size() else 1.0
			frames.add_frame(anim, at, dur)
	_cache[cache_key] = frames
	return frames


static func _as_vec2i(v: Variant, fallback: Vector2i) -> Vector2i:
	if typeof(v) != TYPE_ARRAY:
		return fallback
	var arr: Array = v
	if arr.size() < 2:
		return fallback
	return Vector2i(int(arr[0]), int(arr[1]))


## 在遮罩外面补一圈**径向衰减**的边缘光:每个像素取邻域内 (源 alpha × 距离衰减) 的最大值。
## ★ 只增不减:原遮罩像素的 alpha 原样保留(取 max),所以标记本身不会被削弱。
## ★ 光晕像素必须同时把 RGB 设成白色 —— 遮罩外部本来是透明黑,只写 alpha 会得到黑色预乘。
## ★ 衰减用 smoothstep 而不是线性:线性在半径边缘会留一道明显的"边",加大半径也还是硬;
##   smoothstep 两端导数趋零,读起来是晕开的,不会看到一圈轮廓。
static func _with_halo(src: Texture2D, radius_px: int, strength: float) -> Texture2D:
	var img := src.get_image()
	if img == null or img.is_empty():
		push_error("SpriteFramesIO: 遮罩取不到像素数据,跳过光晕")
		return src
	img = img.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var r := maxi(radius_px, 1)
	var reach := float(r) + 1.0
	for y in h:
		for x in w:
			var best := 0.0
			for dy in range(-r, r + 1):
				var yy := y + dy
				if yy < 0 or yy >= h:
					continue
				for dx in range(-r, r + 1):
					var xx := x + dx
					if xx < 0 or xx >= w:
						continue
					var a := img.get_pixel(xx, yy).a
					if a <= 0.0:
						continue
					var contrib := a
					if dx != 0 or dy != 0:
						var d := sqrt(float(dx * dx + dy * dy))
						var t := clampf(1.0 - d / reach, 0.0, 1.0)
						contrib = a * strength * (t * t * (3.0 - 2.0 * t))   # smoothstep 衰减
					if contrib > best:
						best = contrib
			if best <= 0.0:
				continue
			out.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(best, 0.0, 1.0)))
	return ImageTexture.create_from_image(out)
