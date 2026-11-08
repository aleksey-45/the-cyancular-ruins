class_name ParallaxBg
extends Node2D

# 背景四层景深(层 3-6 = 背景 100%/75%/50%/25%)。**纯视觉**:只在有相机的渲染路径上建,
# 不进快照/回滚/网络包(联机两端都是从同一张地图文件现算,不需要同步)。
#
# 视差口径(**唯一实现**,改动即改行为;零守卫,改动须人工对拍):
#   · 层的节点世界坐标 = cam × (1 − f)  ⇒ 相机位移 Δ 时该层屏幕位移 = −f·Δ(f=1 与场景同速,25% 最远)
#   · **背景图与地图同大**(色层 1 texel/子格 × 16 = 世界像素),环面靠 **3×3 副本**(与墙体一致)
# 这两个式子就是全部数学;别在 Level0 里再写第二份(那样"层挪了什么"只能靠肉眼)。

const DEPTH: Array[float] = [1.0, 0.75, 0.5, 0.25]   # 下标 = 层号 − 3
const CELL_PX: int = 4                                # 烘图:每 64px 格 4px ⇒ 1 texel = 1 子格
const CELL: int = 64                                  # 世界像素/格
const SUB_PX: int = 16                                # 世界像素/texel(= 子格边长)

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


var _layers: Array = []       # 每层:{f, sprites(9 个), offs(9 个副本偏移)}
var _world := Vector2.ZERO    # 世界像素尺寸(= 背景图放大后的尺寸)
var _track: Camera2D = null   # 被跟踪的世界相机(对局里的那个)
var _view_cam: Camera2D = null


# layers = MapFormat.load_bg_layers 的返回值(恒 4 项,缺层 null);world_cells = 地图格数。
# ★★ 尺寸与平铺:**背景图与地图同大**(色层每子格 1 texel,放大 16 倍铺满世界),
#    环面靠 **3×3 副本**(与墙体一致)——不是纹理 repeat:眼睛看到的那一份永远是"世界本身"那一张。
# track_camera = 世界相机(抖动/缩放都跟着它)。本节点活在独立 SubViewport 里 ⇒ 不进世界视口 alpha。
func setup(layers: Array, world_cells: Vector2i, track_camera: Camera2D = null) -> int:
	_track = track_camera
	_world = Vector2(world_cells) * float(CELL)
	var built := 0
	for i in mini(layers.size(), 4):
		var rgba = layers[i]
		if rgba == null:
			continue
		var img := bake_layer_image(rgba, world_cells)          # (世界像素 / 16) 见方
		var tex := ImageTexture.create_from_image(img)
		var sprites: Array = []
		var offs: Array = []
		for oy in 3:
			for ox in 3:
				var spr := Sprite2D.new()
				spr.texture = tex
				spr.centered = false
				spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				spr.scale = Vector2(float(SUB_PX), float(SUB_PX))   # 1 texel = 16 世界像素
				spr.z_index = -100 + i                              # 远景(25%)最靠后
				add_child(spr)
				sprites.append(spr)
				offs.append(Vector2(ox - 1, oy - 1) * _world)
		_layers.append({"f": DEPTH[i], "sprites": sprites, "offs": offs})
		built += 1
	if built > 0:
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
	var host_vp := _track.get_viewport()
	if host_vp != null and get_viewport() != null and get_viewport().size != host_vp.size:
		get_viewport().size = host_vp.size
	var cam := _track.get_screen_center_position()
	if _view_cam != null:
		_view_cam.global_position = cam
		_view_cam.zoom = _track.zoom
	for li in _layers.size():
		var L: Dictionary = _layers[li]
		var f: float = float(L["f"])
		var base := layer_origin(cam, f)
		var sprites: Array = L["sprites"]
		var offs: Array = L["offs"]
		for k in sprites.size():
			(sprites[k] as Sprite2D).position = base + (offs[k] as Vector2)
