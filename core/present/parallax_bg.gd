class_name ParallaxBg
extends Node2D

# 背景四层景深(层 3-6 = 背景 100%/75%/50%/25%)。**纯视觉**:只在有相机的渲染路径上建,
# 不进快照/回滚/网络包(联机两端都是从同一张地图文件现算,不需要同步)。
#
# 视差口径(**唯一实现**,改动即改行为,判据见 tests/smoke/bg_parallax_smoke.gd):
#   · 层的节点世界坐标 = cam × (1 − f)  ⇒ 相机位移 Δ 时该层屏幕位移 = −f·Δ(f=1 与场景同速,25% 最远)
#   · 采样起点(纹理空间)= cam × f,配 texture_repeat 做环面回绕(地图是环面,背景也要无缝)
# 这两个式子就是全部数学;别在 Level0 里再写第二份(那样"层挪了什么"只能靠肉眼)。

const DEPTH: Array[float] = [1.0, 0.75, 0.5, 0.25]   # 下标 = 层号 − 3
const CELL_PX: int = 4                                # 烘图分辨率:每 64px 格 4px(150×100 格 → 600×400)

static func layer_origin(cam: Vector2, f: float) -> Vector2:
	return cam * (1.0 - f)


static func layer_region(cam: Vector2, f: float, view: Vector2) -> Rect2:
	return Rect2(cam * f, view)


# u32 RGBA/子格(0xRRGGBBAA,透明 = 0) → 每格 4px 的图。颜色层只画渐变/底色 ⇒ 每格取 4×4 子格
# **按 alpha 加权**的均值:直接平均透明格会把黑(0,0,0,0)混进来,边缘发暗。
static func bake_layer_image(rgba: PackedInt32Array, world_cells: Vector2i) -> Image:
	var cols := maxi(world_cells.x, 1)
	var rows := maxi(world_cells.y, 1)
	var img := Image.create(cols * CELL_PX, rows * CELL_PX, false, Image.FORMAT_RGBA8)
	for cy in rows:
		for cx in cols:
			var r := 0.0
			var g := 0.0
			var b := 0.0
			var a := 0.0
			for sy in 4:
				for sx in 4:
					var idx := (cy * 4 + sy) * (cols * 4) + (cx * 4 + sx)
					if idx < 0 or idx >= rgba.size():
						continue
					var v := rgba[idx]
					var av := float(v & 0xFF) / 255.0
					r += float((v >> 24) & 0xFF) / 255.0 * av
					g += float((v >> 16) & 0xFF) / 255.0 * av
					b += float((v >> 8) & 0xFF) / 255.0 * av
					a += av
			var col := Color(0.0, 0.0, 0.0, 0.0)
			if a > 0.0:
				col = Color(r / a, g / a, b / a, a / 16.0)
			img.fill_rect(Rect2i(cx * CELL_PX, cy * CELL_PX, CELL_PX, CELL_PX), col)
	return img


var _sprites: Array = [null, null, null, null]   # 下标 0..3;缺层 = null
var _camera: Camera2D = null


# layers = MapFormat.load_bg_layers 的返回值(恒 4 项,缺层 null);world_cells = 地图格数。
# 返回真正建出来的层数(0 = 这张图没有背景景深层,Level0 可直接跳过)。
func setup(layers: Array, world_cells: Vector2i) -> int:
	var built := 0
	for i in mini(layers.size(), 4):
		var rgba = layers[i]
		if rgba == null:
			continue
		var spr := Sprite2D.new()
		spr.name = "Depth%d" % int(round(DEPTH[i] * 100.0))
		spr.texture = ImageTexture.create_from_image(bake_layer_image(rgba, world_cells))
		spr.centered = false
		spr.region_enabled = true
		spr.region_filter_clip_enabled = false
		spr.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		spr.z_index = -100 + i                    # 远景(25%)最靠后;同层内按层号递增
		add_child(spr)
		_sprites[i] = spr
		built += 1
	return built


func _ready() -> void:
	set_process(true)


func _process(_dt: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_2d()
		if _camera == null:
			return                                 # 无相机(服务器/headless)= 不画,也不报错
	var cam := _camera.get_screen_center_position()
	var scale := get_viewport().get_canvas_transform().get_scale()
	var view := get_viewport_rect().size / Vector2(maxf(scale.x, 0.0001), maxf(scale.y, 0.0001))
	# ★ region 比视口大 2px:亚像素取整时边缘不会露出 1px 的透明缝。
	var region_view := view + Vector2(2.0, 2.0)
	for i in 4:
		var spr: Sprite2D = _sprites[i]
		if spr == null:
			continue
		var f: float = DEPTH[i]
		spr.position = layer_origin(cam, f)
		spr.region_rect = layer_region(cam, f, region_view)
