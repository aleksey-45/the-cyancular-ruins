extends Control

# 主菜单背景:复用**游戏渲染管线**(场景层 TileMapLayer + ParallaxBg + PostProcess)的实时光影场景,
# 不是烘焙贴图。昼夜由 PostProcess 自己推进(常量见 core/present/day_cycle.gd:120 秒 = 24 小时,
# 开局 06:00),所以菜单里能看到晨昏/日间/夜晚的光影变化。
#   · 三个 SubViewport:World(透明,场景瓦片 + Camera2D)/ Bg(ParallaxBg)/ Preview(PostProcess 合成),
#     合成图贴到全屏 TextureRect;最上面压一层 UiFactory.C_MENU_DIM 保证菜单可读。
#   · 相机只做缓慢漂移(不再有鱼眼/旋转),让光影场景像"透过一扇窗"。
#   · 不加 class_name(生成器按路径挂脚本);只依赖 core/sim + core/present,不碰 editor/**。

const MAP := "res://maps/newfactory.cyrm"
const SUB_PX := 16                              # 世界像素/子格
const CAM_ZOOM := 0.5                           # 屏幕像素/世界像素:1920 宽 ≈ 60 格
const DRIFT_FRAC := 0.18                        # 漂移幅度(占地图世界尺寸)
const DRIFT_PERIOD_A := 19.0                     # 秒(两个轴周期不同,避免明显闭环)
const DRIFT_PERIOD_B := 27.0

var _display: TextureRect = null
var _dim: ColorRect = null
var _world_vp: SubViewport = null
var _bg_vp: SubViewport = null
var _preview_vp: SubViewport = null
var _camera: Camera2D = null
var _bg: ParallaxBg = null
var _post: PostProcess = null
var _map_world := Vector2.ZERO
var _t := 0.0
var _vp_size := Vector2i.ZERO
var _built := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_display = TextureRect.new()
	_display.name = "Display"
	_display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_display.stretch_mode = TextureRect.STRETCH_SCALE
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_display)

	_world_vp = SubViewport.new()
	_world_vp.name = "WorldViewport"
	_world_vp.transparent_bg = true
	_world_vp.disable_3d = true
	_world_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_world_vp)

	_camera = Camera2D.new()
	_camera.name = "Camera2D"
	_camera.position_smoothing_enabled = false
	_world_vp.add_child(_camera)

	_bg_vp = SubViewport.new()
	_bg_vp.name = "BgViewport"
	_bg_vp.transparent_bg = true
	_bg_vp.disable_3d = true
	_bg_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_bg_vp)

	_preview_vp = SubViewport.new()
	_preview_vp.name = "PreviewViewport"
	_preview_vp.disable_3d = true
	_preview_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_preview_vp)
	_post = PostProcess.new()
	_post.name = "PostProcess"
	_post.world_viewport = _world_vp
	_post.bg_viewport = _bg_vp
	_preview_vp.add_child(_post)

	_load_map()
	if _post != null:
		_post.set_hour(20.3)                     # 从上午 8 点开始:先给一眼有太阳的光影,再按 120s/24h 走
	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = UiFactory.C_MENU_DIM
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	resized.connect(_sync_sizes)
	_sync_sizes()
	_built = true
	set_process(true)


func _process(delta: float) -> void:
	if not _built:
		return
	if Vector2i(roundi(size.x), roundi(size.y)) != _vp_size:
		_sync_sizes()
	_t += delta
	var amp := _map_world * DRIFT_FRAC
	_camera.position = _map_world * 0.5 + Vector2(
			sin(_t * TAU / DRIFT_PERIOD_A), cos(_t * TAU / DRIFT_PERIOD_B)) * amp


func _sync_sizes() -> void:
	var s := Vector2i(roundi(size.x), roundi(size.y))
	if s.x <= 0 or s.y <= 0:
		return
	_vp_size = s
	for vp in [_world_vp, _bg_vp, _preview_vp]:
		if vp is SubViewport:
			(vp as SubViewport).size = s
	if _display != null:
		_display.texture = _preview_vp.get_texture()
	_camera.zoom = Vector2(CAM_ZOOM, CAM_ZOOM)
	_camera.position = _map_world * 0.5


# 光影要用到的地形掩码(1px = 1 格;R=实心、G=材质类):从子格纹理/描述符烘,与游戏内
# PostProcess._bind_terrain_mask 的格式一致,否则太阳遮挡/受光会整体失效、画面变成一张灰片。
func _feed_terrain_mask(textures: Array, descs: Array, cols: int, rows: int) -> void:
	if _post == null or textures.is_empty() or descs.is_empty():
		return
	var cell_cols := cols / 4
	var cell_rows := rows / 4
	if cell_cols <= 0 or cell_rows <= 0:
		return
	var img := Image.create(cell_cols, cell_rows, false, Image.FORMAT_RGBA8)
	for cy in cell_rows:
		for cx in cell_cols:
			var solid := false
			var tex_id := 0
			for sy in 4:
				for sx in 4:
					var v := int((descs[cy * 4 + sy] as Array)[cx * 4 + sx])
					if v == 0:
						continue
					solid = true
					tex_id = int((textures[cy * 4 + sy] as Array)[cx * 4 + sx])
					break
				if solid:
					break
			if solid:
				img.set_pixel(cx, cy, Color(1.0, TileDefs.material_id(tex_id) / 255.0, 0.0, 1.0))
			else:
				img.set_pixel(cx, cy, Color(0.0, 0.0, 0.0, 1.0))
	_post.set_terrain_mask_image(img, cell_cols, cell_rows)


func _load_map() -> void:
	var sub := MapFormat.load_subgrid_with_descs(MAP)
	var descs: Array = sub.get("descs", [])
	var textures: Array = sub.get("textures", [])
	if descs.is_empty():
		push_warning("MenuBackdrop: 读不到地图背景 %s" % MAP)
		return
	var rows := descs.size()
	var cols := (descs[0] as Array).size()
	if cols <= 0:
		return
	_map_world = Vector2(cols, rows) * float(SUB_PX)

	var uniq := {}
	for row in descs:
		for v: Variant in (row as Array):
			if int(v) != 0:
				uniq[int(v)] = true
	var desc_list: Array = uniq.keys()
	desc_list.sort()
	if desc_list.is_empty():
		return
	var built := TerrainAtlas.make_wall_tileset_for(desc_list)
	var tl := TileMapLayer.new()
	tl.name = "SceneLayer"
	tl.tile_set = built["tileset"]
	tl.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_world_vp.add_child(tl)
	var row_of: Dictionary = built["row_of"]
	var painted := 0
	for sy in rows:
		var row: Array = descs[sy]
		for sx in row.size():
			var v := int(row[sx])
			if v == 0:
				continue
			var tile := Vector2i((sy % 4) * 4 + (sx % 4), int(row_of.get(v, 0)))
			tl.set_cell(Vector2i(sx, sy), 0, tile)
			painted += 1
	if painted == 0:
		tl.queue_free()
		return

	_feed_terrain_mask(textures, descs, cols, rows)
	var bg_layers := MapFormat.load_bg_layers(MAP)
	var cells := Vector2i(ceili(float(cols) / 4.0), ceili(float(rows) / 4.0))
	var bg := ParallaxBg.new()
	bg.name = "ParallaxBg"
	var made := bg.setup(bg_layers, cells, _camera)
	if made > 0:
		_bg_vp.add_child(bg)
		_bg = bg
	else:
		bg.free()
