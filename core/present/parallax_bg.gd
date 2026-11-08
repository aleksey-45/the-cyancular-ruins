class_name ParallaxBg
extends Node2D

# 背景四层景深(层 3-6 = 背景 100%/75%/50%/25%)。**纯视觉**:只在有相机的渲染路径上建,
# 不进快照/回滚/网络包(联机两端都是从同一张地图文件现算,不需要同步)。
#
# 口径(**唯一实现**,改动即改行为;零守卫,改动须人工对拍):
#   · 位置:层的节点世界坐标 = cam × (1 − f) ⇒ 相机位移 Δ 时该层屏幕位移 = −f·Δ
#   · 尺寸:**每层图按自己的景深缩小** —— 该层图的世界尺寸 = 世界 × f(f=1 铺满世界,0.25 只占 1/4),
#     1 texel = 16·f 世界像素;每层是**四张不同的图**(各从自己那层的色层数据烘出,互不共用纹理)
#   · 平铺:把该层自己的图按它的世界尺寸摆副本覆盖视口(常规是 3×3;图比视口小时按需多摆,不留缝)
#
# 本节点活在**独立 SubViewport**里(见 Level0):它画的像素不进世界视口的 alpha ⇒ 光照的遮挡/受光
# 看不到背景(不透明剪影安全),只吃 PostProcess 的 ambient_color。

const DEPTH: Array[float] = [1.0, 0.75, 0.5, 0.25]   # 下标 = 层号 − 3
const CELL_PX: int = 4                                # 烘图:每 64px 格 4px ⇒ 1 texel = 1 子格
const CELL: int = 64                                  # 世界像素/格
const SUB_PX: int = 16                                # 世界像素/子格(= 1 texel 在 f=1 时的世界尺寸)

static func layer_origin(cam: Vector2, f: float) -> Vector2:
	return cam * (1.0 - f)


# u32 RGBA/子格(0xRRGGBBAA,透明 = 0) → 该层的小图(每格 4 texel)。颜色层只画渐变/底色 ⇒
# 每格取 4×4 子格**按 alpha 加权**的均值:直接平均透明格会把黑混进来,背景边缘发暗。
static func bake_layer_image(rgba: PackedInt32Array, world_cells: Vector2i, f: float = 1.0) -> Image:
	"""把一层的 u32 RGBA/子格直接烘成**目标分辨率**的小图(每像素 = 一块子格的 alpha 加权平均)。
	目标宽高 = 子格数 × f(600x400 → 450x300 → 300x200 → 150x100):图本身就小,不是先大后缩。
	显示时最近邻放大到世界尺寸 ⇒ 大像素块,不做任何插值。"""
	var cols := maxi(world_cells.x, 1)
	var rows := maxi(world_cells.y, 1)
	var sw := cols * 4
	var sh := rows * 4
	var iw := maxi(1, int(round(sw * f)))
	var ih := maxi(1, int(round(sh * f)))
	var n := iw * ih
	var ar := PackedFloat32Array(); ar.resize(n)
	var ag := PackedFloat32Array(); ag.resize(n)
	var ab := PackedFloat32Array(); ab.resize(n)
	var aa := PackedFloat32Array(); aa.resize(n)
	var ac := PackedInt32Array(); ac.resize(n)
	for sy in sh:
		var oy := (sy * ih) / sh
		for sx in sw:
			var idx := sy * sw + sx
			if idx < 0 or idx >= rgba.size():
				continue
			var v := rgba[idx]
			var av := float(v & 0xFF) / 255.0
			var o := oy * iw + (sx * iw) / sw
			if av > 0.0:
				ar[o] += float((v >> 24) & 0xFF) / 255.0 * av
				ag[o] += float((v >> 16) & 0xFF) / 255.0 * av
				ab[o] += float((v >> 8) & 0xFF) / 255.0 * av
				aa[o] += av
			ac[o] += 1
	var img := Image.create(iw, ih, false, Image.FORMAT_RGBA8)
	for o in n:
		var col := Color(0, 0, 0, 0)
		if aa[o] > 0.0:
			# alpha = 该块内所有子格 alpha 的平均(透明格也算分母:整块越透明,输出越透明)
			col = Color(ar[o] / aa[o], ag[o] / aa[o], ab[o] / aa[o], aa[o] / float(maxi(1, ac[o])))
		img.set_pixel(o % iw, o / iw, col)
	return img


var _layers: Array = []       # 每层:{f, sprites(9 个 = 世界 3×3 环面副本)}
var _world := Vector2.ZERO    # 世界像素尺寸
var _track: Camera2D = null   # 被跟踪的世界相机
var _view_cam: Camera2D = null


# layers = MapFormat.load_bg_layers 的返回值(恒 4 项,缺层 null);world_cells = 地图格数。
# track_camera = 世界相机。返回建出来的层数。
# ★★ 口径(2026-11-08 用户口径,已逐条对齐):
#   ① 四个背景 = **四张不同的图**(各从自己那层的色层数据烘出,互不共用纹理);
#   ② 四张图**像素尺寸随景深变小**(600x400 / 450x300 / 300x200 / 150x100),**显示一律铺满世界**(最近邻放大);
#   ③ **平铺只为环面**:每张图随世界的 3×3 副本一起摆,与视口大小无关,没有 repeat / 没有内部再平铺。
func setup(layers: Array, world_cells: Vector2i, track_camera: Camera2D = null) -> int:
	_track = track_camera
	_world = Vector2(world_cells) * float(CELL)
	var built := 0
	for i in mini(layers.size(), 4):
		var rgba = layers[i]
		if rgba == null:
			continue
		var f: float = DEPTH[i]
		# ★ 图本身按 f 的低分辨率生成(600x400 → 450x300 → 300x200 → 150x100),没有"先大后缩"
		var img := bake_layer_image(rgba, world_cells, f)
		var tex := ImageTexture.create_from_image(img)
		var sprites: Array = []
		for oy in 3:
			for ox in 3:
				var spr := Sprite2D.new()
				spr.texture = tex
				spr.centered = false
				spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				# ★ 显示始终铺满世界(图小就放大):scale = 世界像素 / 图像素
				spr.scale = Vector2(_world.x / float(img.get_width()), _world.y / float(img.get_height()))
				spr.z_index = -100 + i
				add_child(spr)
				sprites.append({"node": spr, "ring": Vector2(ox - 1, oy - 1) * _world})
		_layers.append({"f": f, "sprites": sprites})
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
	if _track == null or not is_instance_valid(_track) or _layers.is_empty():
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
		var base := layer_origin(cam, float(L["f"]))
		for e in L["sprites"]:
			var d: Dictionary = e
			(d["node"] as Sprite2D).position = base + (d["ring"] as Vector2)
