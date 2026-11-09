extends Control

# T3 真渲染预览:在地图编辑器里用**游戏同一套管线**出一张「真实观感」的预览图,不做第二套渲染。
# 不加 class_name(调用方用 load/preload);契约见 .tmp/p2-extras-contract.md §3。
#
# ── 节点结构(全部运行时建,挂在本 Control 下)────────────────────────────────
#   Display(TextureRect)          ← 贴 PreviewViewport.get_texture(),只铺满本 Control(不铺满编辑器)
#   PreviewViewport(SubViewport)  ← 只放 PostProcess(CanvasLayer + 全屏 shader);它的输出才是最终图像
#   WorldViewport(SubViewport)    ← transparent_bg;3 个 TileMapLayer(层 0/1/2)+ Camera2D(世界相机)
#   BgViewport(SubViewport)       ← transparent_bg;ParallaxBg(背景四层,自己建 BgCam 跟随世界相机)
# 接线:WorldViewport → PostProcess.world_viewport;BgViewport → PostProcess.bg_viewport;
#       PreviewViewport 里 PostProcess 合成的图 → Display。PostProcess 只活在这个专用 SubViewport 里,
#       不接触编辑器其余 UI(不会铺满编辑器)。
#
# ── 相机口径(与 EditorCanvas 完全一致;公式为实际验证口径)────────────────────
#   origin = 预览左上角对应的世界**子格**坐标(float);zoom = 每子格屏幕像素(画布口径)。
#   1 子格 = 16 世界像素;Camera2D.zoom(屏幕px/世界px)= zoom/16。
#   可见世界尺寸 = 视口尺寸 / Camera2D.zoom ⇒ 视口中心的世界坐标
#     = origin*16 + 视口size*0.5 / (zoom/16) = origin*16 + 视口size*0.5*16/zoom
#   ⇒ camera.position = origin*16 + size*0.5*16/zoom;camera.zoom = Vector2(zoom/16, zoom/16)。
#   (契约里 "size/2/zoom" 的 zoom 即 Camera2D.zoom;按数值验证写成本式。)
#
# ── 瓦片 ─────────────────────────────────────────────────────────────────────
#   3 层共用同一个 TileSet:TerrainAtlas.make_wall_tileset_for(合成 descs),
#   descs = 层 0/1/2 的非空 desc 去重排序;瓦片坐标 = Vector2i((sy%4)*4+(sx%4), row_of[desc]),
#   用的是**子格**坐标(1 tile = 16px),与 EditorCanvas 的取角映射同源。
#   本预览只铺地图本体一份,**不摆 3×3 环面副本**(画布才做环面);相机走出地图边界会看到空区 ——
#   root 接预览时按需把相机限制在地图内,或接受边界外为空。
#
# ── 刷新策略 ─────────────────────────────────────────────────────────────────
#   refresh() = 全量重铺(图集按 descs 签名缓存,背景按 rgba 哈希缓存;大图整铺较慢)。
#   doc.changed:纹理层走**增量**(只改变过的子格);颜色层(背景)与 structure_changed 走下一帧全量。
#   set_active(false) 后停止更新(视口 UPDATE_DISABLED + 关 ParallaxBg/PostProcess 的 _process),
#   期间的变更只记脏,重新显示时补一次。
#
# ★ 像素不作为判据:headless(dummy 渲染)下本模块只保证 **零 SCRIPT ERROR / 零空引用**;
#   画面正确性需非 headless 人工看(或像素探针另做)。探针只断言结构(stats)与相机数值。
# ★ 禁止 RegEx(客户端导出裁剪了 regex 模块)。

const SUB_PX: int = 16                          # 世界像素/子格
const FALLBACK_SIZE := Vector2i(640, 480)       # 本 Control 还没拿到尺寸时的兜底视口

var _doc: EditorDoc = null
var _built := false
var _active := true
var _origin := Vector2.ZERO                     # 画布口径:预览左上角的世界子格
var _zoom := 16.0                               # 画布口径:每子格屏幕像素

var _display: TextureRect = null
var _preview_vp: SubViewport = null
var _world_vp: SubViewport = null
var _bg_vp: SubViewport = null
var _world_camera: Camera2D = null
var _tile_layers: Array[TileMapLayer] = []
var _tileset: TileSet = null
var _row_of: Dictionary = {}
var _tileset_sig := ""
var _bg: ParallaxBg = null
var _bg_sig := ""
var _bg_layers := 0
var _post: PostProcess = null
var _tile_count := 0
var _pending_full := false


# 装入文档:建(或复用)视口/图层/背景/后处理,并立即全量重铺。可反复调用(换图/换文档)。
func setup(doc: EditorDoc) -> void:
	_disconnect_doc()
	_doc = doc
	if _doc != null:
		_doc.changed.connect(_on_doc_changed)
		_doc.structure_changed.connect(_on_structure_changed)
	if not _built:
		_build()
	_sync_viewport_sizes()
	refresh()


# 全量重铺:图集(按 descs 签名)+ 三层瓦片 + 背景四层(按 rgba 哈希)。
func refresh() -> void:
	_pending_full = false
	if not _built or _doc == null:
		return
	var map: Dictionary = _doc.map
	if map.is_empty():
		_tile_count = 0
		return
	_refresh_tiles(map)
	_refresh_bg(map)


# 相机口径同 EditorCanvas:origin = 左上角世界子格,zoom = 每子格屏幕像素。
func set_camera(origin: Vector2, zoom: float) -> void:
	_origin = origin
	_zoom = maxf(zoom, 0.01)
	_apply_camera()


# 显示/隐藏;隐藏时停掉三个视口的渲染与背景/后处理的逐帧处理(统计值保留)。
func set_active(on: bool) -> void:
	_active = on
	visible = on
	if _display != null:
		_display.visible = on
	var mode := SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	for vp in [_preview_vp, _world_vp, _bg_vp]:
		if vp is SubViewport:
			(vp as SubViewport).render_target_update_mode = mode
	if _bg != null and is_instance_valid(_bg):
		_bg.set_process(on)
	if _post != null and is_instance_valid(_post):
		_post.set_process(on)
	set_process(on)
	if on and _pending_full:
		refresh()


# 供探针/root 观察的结构统计:{tiles: 三层已铺瓦片数, bg_layers: 背景建成层数,
# post: PostProcess 节点是否存在, ready: 文档/视口已建}.
func stats() -> Dictionary:
	var is_ready := _built and _doc != null and not _doc.map.is_empty()
	return {"tiles": _tile_count, "bg_layers": _bg_layers, "post": _post != null, "ready": is_ready}


# ── 文档信号 ────────────────────────────────────────────────────────────────

func _on_doc_changed(layer: int, subcells: PackedInt32Array) -> void:
	if not _built or _doc == null:
		return
	if not _active:
		_pending_full = true                      # 隐藏时只记脏,重新显示时补一次
		return
	if layer >= 0 and layer <= 2:
		_apply_tex_changed(layer, subcells)
	elif layer >= 0:
		_pending_full = true                      # 颜色层(3-6)= 背景需要重烘
	else:
		_pending_full = true


func _on_structure_changed() -> void:
	# 换图/尺寸变/层增删:图集与全部图层都要重建,代价大 ⇒ 只记脏,由 _process 在下一帧合并成一次全量。
	_pending_full = true


func _process(_dt: float) -> void:
	if _active and _pending_full:
		refresh()


# ── 建树 ────────────────────────────────────────────────────────────────────

func _build() -> void:
	_built = true
	var mode := SubViewport.UPDATE_ALWAYS if _active else SubViewport.UPDATE_DISABLED

	_display = TextureRect.new()
	_display.name = "Display"
	_display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_display.stretch_mode = TextureRect.STRETCH_SCALE
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_display)

	# 世界视口:透明背景(PostProcess 用 alpha 判遮挡),每帧更新。
	_world_vp = SubViewport.new()
	_world_vp.name = "WorldViewport"
	_world_vp.transparent_bg = true
	_world_vp.disable_3d = true
	_world_vp.render_target_update_mode = mode
	add_child(_world_vp)

	_world_camera = Camera2D.new()
	_world_camera.name = "Camera2D"
	_world_vp.add_child(_world_camera)

	# 层 0 前景 / 1 场景 / 2 后景;z_index 让前景压住场景、场景压住后景(与游戏画序一致)。
	for i in 3:
		var tl := TileMapLayer.new()
		tl.name = ["FrontLayer", "SceneLayer", "BackLayer"][i]
		tl.z_index = 2 - i
		_world_vp.add_child(tl)
		_tile_layers.append(tl)

	# 背景独立视口(不进世界视口 ⇒ 不参与遮挡/受光);ParallaxBg 在里面自建 BgCam 跟随世界相机。
	_bg_vp = SubViewport.new()
	_bg_vp.name = "BgViewport"
	_bg_vp.transparent_bg = true
	_bg_vp.disable_3d = true
	_bg_vp.render_target_update_mode = mode
	add_child(_bg_vp)

	# 后处理专用视口:只装 PostProcess,输出贴到 Display。
	_preview_vp = SubViewport.new()
	_preview_vp.name = "PreviewViewport"
	_preview_vp.disable_3d = true
	_preview_vp.render_target_update_mode = mode
	add_child(_preview_vp)
	_post = PostProcess.new()
	_post.name = "PostProcess"
	_post.world_viewport = _world_vp
	_post.bg_viewport = _bg_vp
	_preview_vp.add_child(_post)

	resized.connect(_on_resized)


func _on_resized() -> void:
	_sync_viewport_sizes()


func _sync_viewport_sizes() -> void:
	if not _built:
		return
	var s := Vector2i(roundi(size.x), roundi(size.y))
	if s.x <= 0 or s.y <= 0:
		s = FALLBACK_SIZE
	_world_vp.size = s
	_bg_vp.size = s
	_preview_vp.size = s
	if _display != null:
		_display.texture = _preview_vp.get_texture()
	_apply_camera()


func _apply_camera() -> void:
	if _world_camera == null or _world_vp == null:
		return
	var z := maxf(_zoom, 0.01) / float(SUB_PX)          # Camera2D.zoom = 屏幕px/世界px
	var vp := Vector2(_world_vp.size)
	_world_camera.zoom = Vector2(z, z)
	_world_camera.position = _origin * float(SUB_PX) + vp * 0.5 / z


# ── 图层重铺 ────────────────────────────────────────────────────────────────

func _refresh_tiles(map: Dictionary) -> void:
	var layers: Array = map.get("layers", [])
	var sub_cols := int(map.get("sub_cols", 0))
	var sub_rows := int(map.get("sub_rows", 0))
	var uniq := {}
	for layer_idx in 3:
		var d := _tex_layer(layers, layer_idx)
		if d.is_empty():
			continue
		for v in (d["desc"] as PackedInt32Array):
			if int(v) != 0:
				uniq[int(v)] = true
	var descs: Array = uniq.keys()
	descs.sort()
	var sig := "%d:%d" % [descs.size(), hash(descs)]
	if _tileset == null or sig != _tileset_sig:
		var built := TerrainAtlas.make_wall_tileset_for(descs)
		_tileset = built["tileset"]
		_row_of = built["row_of"]
		_tileset_sig = sig
		for tl: TileMapLayer in _tile_layers:
			tl.tile_set = _tileset
	var painted := 0
	for layer_idx in 3:
		var tl: TileMapLayer = _tile_layers[layer_idx]
		tl.clear()
		var d := _tex_layer(layers, layer_idx)
		if d.is_empty() or sub_cols <= 0:
			continue
		var desc: PackedInt32Array = d["desc"]
		var n := mini(desc.size(), sub_cols * sub_rows)
		for i in n:
			var v := int(desc[i])
			if v == 0:
				continue
			var sx := i % sub_cols
			var sy := i / sub_cols
			tl.set_cell(Vector2i(sx, sy), 0,
					Vector2i((sy % 4) * 4 + (sx % 4), TerrainAtlas.fallback_row(_row_of, v)))
			painted += 1
	_tile_count = painted


# doc.changed 的纹理层增量:只改变过的子格(逐格 set/erase,瓦片计数同步)。
# 出现图集行表里没有的新 desc ⇒ 退回下一帧全量 refresh(重建图集)。
func _apply_tex_changed(layer: int, idxs: PackedInt32Array) -> void:
	var map: Dictionary = _doc.map
	var sub_cols := int(map.get("sub_cols", 0))
	var layers: Array = map.get("layers", [])
	if sub_cols <= 0 or layer >= layers.size():
		return
	var d := _tex_layer(layers, layer)
	if d.is_empty():
		return
	var desc: PackedInt32Array = d["desc"]
	for idx in idxs:
		if idx >= 0 and idx < desc.size():
			var v := int(desc[idx])
			if v != 0 and not _row_of.has(v):
				_pending_full = true
				return
	var tl: TileMapLayer = _tile_layers[layer]
	for idx in idxs:
		if idx < 0 or idx >= desc.size():
			continue
		var v := int(desc[idx])
		var pos := Vector2i(idx % sub_cols, idx / sub_cols)
		var had := tl.get_cell_atlas_coords(pos) != Vector2i(-1, -1)
		if v == 0:
			if had:
				tl.erase_cell(pos)
				_tile_count -= 1
			continue
		tl.set_cell(pos, 0,
				Vector2i((pos.y % 4) * 4 + (pos.x % 4), int(_row_of[v])))
		if not had:
			_tile_count += 1


func _refresh_bg(map: Dictionary) -> void:
	var layers: Array = map.get("layers", [])
	var sub_cols := int(map.get("sub_cols", 0))
	var sub_rows := int(map.get("sub_rows", 0))
	if sub_cols <= 0 or sub_rows <= 0:
		return
	var bg_layers: Array = []
	var sig_parts := PackedInt32Array()
	for L in range(EditorConstants.LAYER_BG_FIRST, EditorConstants.LAYER_BG_LAST + 1):
		var rgba: Variant = null
		if L < layers.size() and layers[L] != null and layers[L] is Dictionary:
			var ld: Dictionary = layers[L]
			if String(ld.get("kind", "")) == "color" and ld.has("rgba"):
				rgba = ld["rgba"]
		bg_layers.append(rgba)
		sig_parts.append(-1 if rgba == null else int(hash(rgba)))
	var sig := "%d:%d:%d:%d" % [sig_parts[0], sig_parts[1], sig_parts[2], sig_parts[3]]
	if sig == _bg_sig:
		return
	if _bg != null and is_instance_valid(_bg):
		_bg.free()
	_bg = null
	_bg_layers = 0
	_bg_sig = sig
	var world_cells := Vector2i(sub_cols / EditorConstants.SUB_PER_CELL, sub_rows / EditorConstants.SUB_PER_CELL)
	var bg := ParallaxBg.new()
	bg.name = "ParallaxBg"
	var built := bg.setup(bg_layers, world_cells, _world_camera)
	if built > 0:
		_bg_vp.add_child(bg)
		bg.set_process(_active)
		_bg = bg
		_bg_layers = built
	else:
		bg.free()


# layers[i] 若是纹理层返回 {"kind":"tex","desc":...},否则返回 {}。
func _tex_layer(layers: Array, layer_idx: int) -> Dictionary:
	if layer_idx < 0 or layer_idx >= layers.size() or layers[layer_idx] == null:
		return {}
	if not (layers[layer_idx] is Dictionary):
		return {}
	var d: Dictionary = layers[layer_idx]
	if String(d.get("kind", "")) != "tex" or not d.has("desc"):
		return {}
	return d


func _disconnect_doc() -> void:
	if _doc == null:
		return
	if _doc.changed.is_connected(_on_doc_changed):
		_doc.changed.disconnect(_on_doc_changed)
	if _doc.structure_changed.is_connected(_on_structure_changed):
		_doc.structure_changed.disconnect(_on_structure_changed)


func _exit_tree() -> void:
	_disconnect_doc()
