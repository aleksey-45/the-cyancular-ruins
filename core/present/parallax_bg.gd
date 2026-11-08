class_name ParallaxBg
extends Node2D

# 背景四层景深(层 3-6 = 背景 100%/75%/50%/25%)。**纯视觉**:只在有相机的渲染路径上建,
# 不进快照/回滚/网络包(联机两端都是从同一张地图文件现算,不需要同步)。
#
# 视差口径(**唯一实现**,改动即改行为;零守卫,改动须人工对拍):
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
var _track: Camera2D = null                      # 被跟踪的世界相机(对局里的那个)
var _view_cam: Camera2D = null                   # 本视口自己的相机:每帧跟随世界相机


# layers = MapFormat.load_bg_layers 的返回值(恒 4 项,缺层 null);world_cells = 地图格数。
# track_camera = 世界相机(相机抖动/缩放都跟着它)。本节点**活在独立 SubViewport 里**:
# 它画的像素不进世界视口的 alpha ⇒ 光照的遮挡/受光完全看不到背景(不透明剪影安全)。
# 返回真正建出来的层数(0 = 这张图没有背景景深层,Level0 可直接跳过)。
func setup(layers: Array, world_cells: Vector2i, track_camera: Camera2D = null) -> int:
	_track = track_camera
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
	if built > 0:
		# 自己的相机(独立视口里必须有一个,否则什么都不画)。位置/缩放每帧跟世界相机。
		_view_cam = Camera2D.new()
		_view_cam.name = "BgCam"
		_view_cam.position_smoothing_enabled = false
		add_child(_view_cam)
	return built


func _ready() -> void:
	set_process(true)


func _process(_dt: float) -> void:
	if _track == null or not is_instance_valid(_track):
		return
	# ① 视口尺寸跟世界视口(窗口缩放时两边必须同尺寸,否则 region 采样错位)
	var host_vp := _track.get_viewport()
	if host_vp != null and get_viewport() != null and get_viewport().size != host_vp.size:
		get_viewport().size = host_vp.size
	# ② 相机跟随:世界相机移多少,本视口相机就移多少 ⇒ 世界坐标的 sprites 出现在同样的屏幕位置
	var cam := _track.get_screen_center_position()
	if _view_cam != null:
		_view_cam.global_position = cam
		_view_cam.zoom = _track.zoom
	var z := _track.zoom
	var view := get_viewport_rect().size / Vector2(maxf(z.x, 0.0001), maxf(z.y, 0.0001))
	# ★ region 比视口大 2px:亚像素取整时边缘不会露出 1px 的透明缝。
	var region_view := view + Vector2(2.0, 2.0)
	for i in 4:
		var spr: Sprite2D = _sprites[i]
		if spr == null:
			continue
		var f: float = DEPTH[i]
		spr.position = layer_origin(cam, f)
		spr.region_rect = layer_region(cam, f, region_view)
