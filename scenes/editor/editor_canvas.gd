class_name EditorCanvas
extends Control

# P2 编辑器画布:把 EditorDoc 的地图渲染成一张与 canvas 等大的离屏图像(视口离屏层),并把鼠标事件
# 翻译成子格坐标。**不实现工具语义** —— 工具在 editor_root.gd,本文件只发 pointer_* 事件。
# 契约见 .tmp/editor-p2-contract.md §4。
# ★ 本脚本进客户端导出包 ⇒ 禁止 RegEx(裁剪模板 module_regex_enabled=false);本文件不需要正则。
#
# 渲染:层号倒序(背景 25% → 前景)合成到 RGBA8 Image;纹理层用 TerrainAtlas 的 16px 象限制图集
#   (象限列 = (sy%4)*4 + (sx%4),行 = row_of[desc];按 zoom 先整张 INTERPOLATE_NEAREST 缩放一次,
#   再逐子格 blend),颜色层按子格填 rgba(u32),空气露出 SKY_COLOR。非 active 层 alpha 调低。
# 相机:origin = 画布左上角对应的世界子格坐标(可负/小数;渲染按 posmod 取环面样本),
#   zoom = 每子格屏幕像素(默认 16,档位 ZOOM_STEPS)。滚轮以鼠标为锚缩放,中键/空格拖动平移。
#
# 去掉什么它才会红(tests/probe/editor_canvas_probe.gd 逐条守):
#   ① 不建离屏纹理 / 尺寸错 ⇒ view_texture 断言红;
#   ② screen_to_subcell 不用 floor 或漏 origin ⇒ 手算 3 点红;
#   ③ 缩放不以鼠标为锚 ⇒ 锚点子格变了红;
#   ④ 不判 layer_visible / active 不恒可见 ⇒ 层可见性与隐藏后像素红;
#   ⑤ 不重标 alpha(非 active 层)⇒ 颜色像素不是 0.45 混合红;
#   ⑥ 纹理层不 blit 图集 ⇒ 纹理格全是底色红;
#   ⑦ 左键没翻译成子格事件 ⇒ pointer_down 断言红;
#   ⑧ 新 desc 不重建图集 / blit 回落中性行 ⇒ descs() 缺项或变体像素同色红;
#   ⑨ 无 doc / 空图 refresh() 崩或产不出纹理 ⇒ 条数闸 + 纹理断言红。
# class_name 行已由 Lead 预注册:别改(全局类缓存按名字解析)。

const ZOOM_STEPS := [4.0, 8.0, 12.0, 16.0, 24.0, 32.0, 48.0, 64.0]
const ZOOM_DEFAULT := 16.0
const INACTIVE_ALPHA := 0.45        # 非 active 层被压暗到多少(契约 §4)
const QUAD_COLS := 16               # TerrainAtlas 图集列数 = 4×4 象限
const QUAD_TILE := 16               # TerrainAtlas 图集每象限像素(16px = 1 子格)
const SUB_PER_CELL := 4             # 1 格 = 4×4 子格(与 EditorConstants.SUB_PER_CELL 一致)
const BG_COLOR := Color("2f4256")   # = TerrainAtlas.SKY_COLOR,空气露出的底色
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.07)
const SEAM_COLOR := Color(0.35, 0.95, 1.0, 0.35)   # 环面接缝(地图 0 边)高亮
const ERASER_COLOR := Color(1.0, 0.35, 0.35, 1.0)
const BRUSH_MAX_CELLS := 32

signal pointer_down(sub: Vector2i, button: int, shift: bool, ctrl: bool)
signal pointer_drag(sub: Vector2i)
signal pointer_up(sub: Vector2i)
signal cursor_moved(sub: Vector2i)
signal zoom_changed(zoom: float)

# 相机只读口(origin/zoom 由本文件维护;外部用 zoom_in/zoom_out/set_zoom/set_camera/fit_to_map/pan_pixels)。
var zoom: float:
	get:
		return _zoom
var origin: Vector2:
	get:
		return _origin

var _doc: EditorDoc = null
var _zoom := ZOOM_DEFAULT
var _origin := Vector2.ZERO
var _active_layer := 1
var _layer_visible: Array[bool] = [true, true, true, true, true, true, true]
var _brush_cells := 1
var _preview_desc := 0
var _hover_sub := Vector2i.ZERO
var _has_hover := false

var _left_down := false
var _panning := false
var _space_held := false

var _view_tex: ImageTexture = null

var _atlas_img: Image = null
var _atlas_row_of := {}
var _atlas_descs: Array[int] = []
var _atlas_scaled: Image = null
var _atlas_scaled_dim: Image = null
var _atlas_scaled_cell := 0        # _atlas_scaled 里一个子格占几像素(== int(zoom))
var _color_stamps := {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	if not resized.is_connected(_on_resized):
		resized.connect(_on_resized)
	refresh()


# ── 公开 API(editor_root 与场景探针消费)────────────────────────────

func set_doc(doc: EditorDoc) -> void:
	if _doc != null:
		if _doc.changed.is_connected(_on_doc_changed):
			_doc.changed.disconnect(_on_doc_changed)
		if _doc.structure_changed.is_connected(_on_doc_structure_changed):
			_doc.structure_changed.disconnect(_on_doc_structure_changed)
	_doc = doc
	_atlas_img = null
	_atlas_row_of = {}
	_atlas_descs.clear()
	_atlas_scaled = null
	_atlas_scaled_dim = null
	_atlas_scaled_cell = 0
	if _doc != null:
		_doc.changed.connect(_on_doc_changed)
		_doc.structure_changed.connect(_on_doc_structure_changed)
		_active_layer = clampi(int(_doc.active_layer), 0, EditorConstants.LAYER_COUNT - 1)
		_ensure_atlas(true)
	refresh()


func view_texture() -> Texture2D:
	return _view_tex


## 当前图集里的描述符(去重排序;新 desc 出现后应包含它)。
func descs() -> Array[int]:
	return _atlas_descs.duplicate()


func set_active_layer(layer: int) -> void:
	var v := clampi(layer, 0, EditorConstants.LAYER_COUNT - 1)
	if v == _active_layer:
		return
	_active_layer = v
	refresh()


func get_active_layer() -> int:
	return _active_layer


func set_layer_visible(layer: int, vis: bool) -> void:
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return
	if _layer_visible[layer] == vis:
		return
	_layer_visible[layer] = vis
	if layer != _active_layer:
		refresh()


## active 层恒可见(面板上打了叉也只是图例,不挡正在编辑的那层)。
func layer_visible(layer: int) -> bool:
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return false
	if layer == _active_layer:
		return true
	return _layer_visible[layer]


func set_brush_preview(size_cells: int) -> void:
	_brush_cells = clampi(size_cells, 1, BRUSH_MAX_CELLS)
	queue_redraw()


func set_preview_desc(desc: int) -> void:
	_preview_desc = desc
	queue_redraw()


# ── 相机 ──────────────────────────────────────────────────────────────

## 屏幕(画布内)坐标 → 世界子格。可能为负/超出地图;环面归一化由调用方(EditorDoc)做。
func screen_to_subcell(pos: Vector2) -> Vector2i:
	if _zoom <= 0.0:
		return Vector2i.ZERO
	return Vector2i(floori(_origin.x + pos.x / _zoom), floori(_origin.y + pos.y / _zoom))


func subcell_to_screen(sub: Vector2i) -> Vector2:
	return Vector2((float(sub.x) - _origin.x) * _zoom, (float(sub.y) - _origin.y) * _zoom)


## 以屏幕点为锚缩放到下一个/上一个档位(direction = +1 放大 / -1 缩小)。
## 锚点下的子格保持不变(screen_to_subcell(at) 前后相等)。
func zoom_at_screen(at: Vector2, direction: int) -> void:
	if direction == 0:
		return
	var idx := _zoom_index(_zoom)
	var ni := clampi(idx + direction, 0, ZOOM_STEPS.size() - 1)
	if ni == idx:
		return
	_apply_zoom(float(ZOOM_STEPS[ni]), at)


func zoom_in() -> void:
	zoom_at_screen(size * 0.5, 1)


func zoom_out() -> void:
	zoom_at_screen(size * 0.5, -1)


## 直接设档位(贴到最近档);锚点 = 画布中心。
func set_zoom(value: float) -> void:
	var target := _nearest_step(value)
	if is_equal_approx(target, _zoom):
		return
	_apply_zoom(target, size * 0.5)


## 重置相机(origin = 世界子格,zoom 贴到最近档);主要给场景探针/root 复位用。
func set_camera(new_origin: Vector2, new_zoom: float) -> void:
	var changed := not _origin.is_equal_approx(new_origin) or not is_equal_approx(_zoom, _nearest_step(new_zoom))
	_origin = new_origin
	_zoom = _nearest_step(new_zoom)
	refresh()
	if changed:
		zoom_changed.emit(_zoom)


func pan_pixels(delta: Vector2) -> void:
	if _zoom <= 0.0:
		return
	_origin += delta / _zoom
	refresh()


## 让整张地图尽量大地放进画布并居中;空图复位到默认档 + 原点。
func fit_to_map() -> void:
	var sub := _sub_size()
	if sub.x <= 0 or sub.y <= 0 or size.x <= 0.0 or size.y <= 0.0:
		_origin = Vector2.ZERO
		_zoom = ZOOM_DEFAULT
		refresh()
		zoom_changed.emit(_zoom)
		return
	var best: float = float(ZOOM_STEPS[0])
	for s: float in ZOOM_STEPS:
		if float(sub.x) * s <= size.x and float(sub.y) * s <= size.y:
			best = s
	_zoom = best
	_origin = (Vector2(sub) - size / best) * 0.5
	refresh()
	zoom_changed.emit(_zoom)


# ── 刷新:重建离屏视口层 ─────────────────────────────────────────────

func refresh() -> void:
	_rebuild_view()
	queue_redraw()


func _rebuild_view() -> void:
	var w := maxi(1, int(round(size.x)))
	var h := maxi(1, int(round(size.y)))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(BG_COLOR)
	if _doc != null:
		var sub := _sub_size()
		if sub.x > 0 and sub.y > 0:
			if _atlas_img == null:
				_ensure_atlas(true)
			_ensure_scaled_atlas()
			var vis := _visible_sub_rect()
			var layers: Array = _doc.map.get("layers", [])
			_color_stamps.clear()
			# 层号倒序:背景 25%(6) → … → 前景(0)。
			for li in range(EditorConstants.LAYER_COUNT - 1, -1, -1):
				if li >= layers.size():
					continue
				var ld: Variant = layers[li]
				if ld == null:
					continue
				if not layer_visible(li):
					continue
				var alpha_mul := 1.0 if li == _active_layer else INACTIVE_ALPHA
				if EditorConstants.is_color_layer(li):
					_blit_color_layer(img, ld, sub, vis, alpha_mul)
				else:
					_blit_tex_layer(img, ld, sub, vis, alpha_mul)
	# ★ 每次重建 ImageTexture(不用 update()):update() 不刷新 CPU 侧 image_storage,
	#   外部 get_image() 会读到旧像素(场景探针要按像素断言渲染结果,会假绿/假红)。
	_view_tex = ImageTexture.create_from_image(img)


func _sub_size() -> Vector2i:
	if _doc == null:
		return Vector2i.ZERO
	var map: Dictionary = _doc.map
	if map.is_empty():
		return Vector2i.ZERO
	return Vector2i(int(map.get("sub_cols", 0)), int(map.get("sub_rows", 0)))


func _visible_sub_rect() -> Rect2i:
	var cols := ceili(float(size.x) / _zoom) + 1
	var rows := ceili(float(size.y) / _zoom) + 1
	return Rect2i(floori(_origin.x), floori(_origin.y), maxi(cols, 1), maxi(rows, 1))


func _blit_tex_layer(img: Image, ld: Dictionary, sub: Vector2i, vis: Rect2i, alpha_mul: float) -> void:
	if _atlas_scaled == null:
		return
	var cells: PackedInt32Array = ld.get("desc", PackedInt32Array())
	if cells.is_empty():
		return
	var z := _atlas_scaled_cell
	var atlas_h := _atlas_scaled.get_height()
	var src_img := _atlas_scaled if alpha_mul >= 0.999 else _atlas_scaled_dim
	if src_img == null:
		src_img = _atlas_scaled
	for dy in vis.size.y:
		var wy := vis.position.y + dy
		var sy := posmod(wy, sub.y)
		var qy4 := (sy % SUB_PER_CELL) * SUB_PER_CELL
		var dst_y := roundi((float(wy) - _origin.y) * _zoom)
		for dx in vis.size.x:
			var wx := vis.position.x + dx
			var sx := posmod(wx, sub.x)
			var idx := sy * sub.x + sx
			if idx < 0 or idx >= cells.size():
				continue
			var d := int(cells[idx])
			if d == 0:
				continue
			var row := int(_atlas_row_of.get(d, -1))
			if row < 0:
				row = TerrainAtlas.fallback_row(_atlas_row_of, d)
			if row < 0 or (row + 1) * z > atlas_h:
				continue
			var src := Rect2i((qy4 + (sx % SUB_PER_CELL)) * z, row * z, z, z)
			img.blend_rect(src_img, src, Vector2i(roundi((float(wx) - _origin.x) * _zoom), dst_y))


func _blit_color_layer(img: Image, ld: Dictionary, sub: Vector2i, vis: Rect2i, alpha_mul: float) -> void:
	var cells: PackedInt32Array = ld.get("rgba", PackedInt32Array())
	if cells.is_empty():
		return
	var z := int(round(_zoom))
	for dy in vis.size.y:
		var wy := vis.position.y + dy
		var sy := posmod(wy, sub.y)
		var dst_y := roundi((float(wy) - _origin.y) * _zoom)
		for dx in vis.size.x:
			var wx := vis.position.x + dx
			var idx := sy * sub.x + posmod(wx, sub.x)
			if idx < 0 or idx >= cells.size():
				continue
			var u := int(cells[idx]) & 0xFFFFFFFF
			if u == 0:
				continue
			var a := float(u & 0xFF) / 255.0 * alpha_mul
			if a <= 0.0:
				continue
			var c := Color8((u >> 24) & 0xFF, (u >> 16) & 0xFF, (u >> 8) & 0xFF, clampi(roundi(a * 255.0), 0, 255))
			img.blend_rect(_stamp_for(c), Rect2i(0, 0, z, z),
					Vector2i(roundi((float(wx) - _origin.x) * _zoom), dst_y))


func _stamp_for(c: Color) -> Image:
	var key := "%d,%d,%d,%d" % [clampi(roundi(c.r * 255.0), 0, 255),
			clampi(roundi(c.g * 255.0), 0, 255), clampi(roundi(c.b * 255.0), 0, 255),
			clampi(roundi(c.a * 255.0), 0, 255)]
	if _color_stamps.has(key):
		return _color_stamps[key]
	var z := int(round(_zoom))
	var stamp := Image.create(maxi(z, 1), maxi(z, 1), false, Image.FORMAT_RGBA8)
	stamp.fill(c)
	_color_stamps[key] = stamp
	return stamp


# ── 图集(descs 变了才重建)─────────────────────────────────────────

func _collect_descs() -> Array[int]:
	var out: Array[int] = []
	if _doc == null:
		return out
	var map: Dictionary = _doc.map
	if map.is_empty():
		return out
	var layers: Array = map.get("layers", [])
	var uniq := {}
	for li in range(0, mini(layers.size(), EditorConstants.LAYER_COUNT)):
		if EditorConstants.is_color_layer(li):
			continue
		var ld: Variant = layers[li]
		if ld == null:
			continue
		var cells: PackedInt32Array = (ld as Dictionary).get("desc", PackedInt32Array())
		for d in cells:
			var dd := int(d)
			if EditorDesc.tex_of(dd) != 0:
				uniq[dd] = true
	out.assign(uniq.keys())
	out.sort()
	return out


func _ensure_atlas(force: bool = false) -> void:
	var descs := _collect_descs()
	if not force and _atlas_img != null and descs == _atlas_descs:
		return
	_atlas_descs = descs
	var built := TerrainAtlas.build_atlas_image_for(descs)
	_atlas_img = built["image"]
	_atlas_row_of = built["row_of"]
	_atlas_scaled = null
	_atlas_scaled_dim = null
	_atlas_scaled_cell = 0


func _ensure_scaled_atlas() -> void:
	var z := int(round(_zoom))
	if _atlas_img == null or z <= 0:
		return
	if _atlas_scaled != null and _atlas_scaled_cell == z:
		return
	var rows := maxi(1, _atlas_img.get_height() / QUAD_TILE)
	var scaled := _atlas_img.duplicate()
	scaled.resize(QUAD_COLS * z, rows * z, Image.INTERPOLATE_NEAREST)
	_atlas_scaled = scaled
	_atlas_scaled_cell = z
	_atlas_scaled_dim = scaled.duplicate()
	_multiply_alpha(_atlas_scaled_dim, INACTIVE_ALPHA)


func _multiply_alpha(img: Image, mul: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.0:
				continue
			img.set_pixel(x, y, Color(c.r, c.g, c.b, c.a * mul))


# ── doc 信号 ─────────────────────────────────────────────────────────

func _on_doc_changed(layer: int, subcells: PackedInt32Array) -> void:
	# 只按变更子格判新 desc(整图扫描在大图上会拖慢每一笔)。
	if _doc != null and not EditorConstants.is_color_layer(layer):
		var layers: Array = _doc.map.get("layers", [])
		if layer >= 0 and layer < layers.size() and layers[layer] != null:
			var cells: PackedInt32Array = (layers[layer] as Dictionary).get("desc", PackedInt32Array())
			for raw_idx in subcells:
				var idx := int(raw_idx)
				if idx < 0 or idx >= cells.size():
					continue
				var d := int(cells[idx])
				if EditorDesc.tex_of(d) != 0 and not _atlas_row_of.has(d):
					_ensure_atlas(true)
					break
	refresh()


func _on_doc_structure_changed() -> void:
	_ensure_atlas(true)
	refresh()


func _on_resized() -> void:
	refresh()


# ── 绘制:视口纹理 + 网格 + 画刷框 ────────────────────────────────────

func _draw() -> void:
	if _view_tex != null and size.x > 0.0 and size.y > 0.0:
		draw_texture_rect(_view_tex, Rect2(Vector2.ZERO, size), false)
	_draw_grid()
	_draw_brush()


func _draw_grid() -> void:
	var sub := _sub_size()
	var x0 := floori(_origin.x)
	var x1 := ceili(_origin.x + size.x / _zoom)
	for wx in range(x0, x1 + 1):
		var px := (float(wx) - _origin.x) * _zoom
		if px < -1.0 or px > size.x + 1.0:
			continue
		if sub.x > 0 and posmod(wx, sub.x) == 0:
			draw_line(Vector2(px, 0.0), Vector2(px, size.y), SEAM_COLOR, 2.0)
		elif posmod(wx, SUB_PER_CELL) == 0:
			draw_line(Vector2(px, 0.0), Vector2(px, size.y), GRID_COLOR, 1.0)
	var y0 := floori(_origin.y)
	var y1 := ceili(_origin.y + size.y / _zoom)
	for wy in range(y0, y1 + 1):
		var py := (float(wy) - _origin.y) * _zoom
		if py < -1.0 or py > size.y + 1.0:
			continue
		if sub.y > 0 and posmod(wy, sub.y) == 0:
			draw_line(Vector2(0.0, py), Vector2(size.x, py), SEAM_COLOR, 2.0)
		elif posmod(wy, SUB_PER_CELL) == 0:
			draw_line(Vector2(0.0, py), Vector2(size.x, py), GRID_COLOR, 1.0)


func _draw_brush() -> void:
	if not _has_hover:
		return
	var sub := _sub_size()
	if sub.x <= 0 or sub.y <= 0:
		return
	# 指针子格 → 格;画刷以格为中心(与 editor_root._stamp_cell 的 brush_offsets 同源)。
	var cell := Vector2i(floori(float(_hover_sub.x) / SUB_PER_CELL), floori(float(_hover_sub.y) / SUB_PER_CELL))
	var off := EditorGeometry.brush_offsets(_brush_cells)
	var top_left := Vector2i(cell.x - int(off["lo"]), cell.y - int(off["lo"]))
	var rect := Rect2(subcell_to_screen(top_left * SUB_PER_CELL),
			Vector2(float(_brush_cells) * SUB_PER_CELL, float(_brush_cells) * SUB_PER_CELL) * _zoom)
	var tint := ERASER_COLOR
	if _preview_desc != 0:
		tint = TerrainAtlas.tint_color(Color.WHITE, _preview_desc)
	draw_rect(rect, Color(tint.r, tint.g, tint.b, 0.20))
	draw_rect(rect, Color(tint.r, tint.g, tint.b, 0.95), false, 2.0)


# ── 输入:鼠标 → 子格事件 + 相机操作 ─────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_gui_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_gui_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.keycode == KEY_SPACE:
			_space_held = k.pressed
			if not _space_held:
				_panning = false


func _gui_mouse_button(mb: InputEventMouseButton) -> void:
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if mb.pressed:
				zoom_at_screen(mb.position, 1)
		MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				zoom_at_screen(mb.position, -1)
		MOUSE_BUTTON_LEFT:
			_update_hover(mb.position)
			if mb.pressed:
				grab_focus()
				if _space_held:
					_panning = true
				else:
					_left_down = true
					pointer_down.emit(screen_to_subcell(mb.position), mb.button_index,
							mb.shift_pressed, mb.ctrl_pressed)
			else:
				if _left_down:
					_left_down = false
					pointer_up.emit(screen_to_subcell(mb.position))
				_panning = false
		MOUSE_BUTTON_MIDDLE:
			_update_hover(mb.position)
			if mb.pressed:
				grab_focus()
				_panning = true
			else:
				_panning = false
	if not _panning:
		queue_redraw()


func _gui_mouse_motion(mm: InputEventMouseMotion) -> void:
	_update_hover(mm.position)
	if _panning:
		_origin -= mm.relative / _zoom
		refresh()
		return
	var sub := screen_to_subcell(mm.position)
	if _left_down:
		pointer_drag.emit(sub)
	cursor_moved.emit(sub)
	queue_redraw()


func _update_hover(pos: Vector2) -> void:
	_hover_sub = screen_to_subcell(pos)
	_has_hover = true


# ── 档位小工具 ───────────────────────────────────────────────────────

func _apply_zoom(new_zoom: float, at: Vector2) -> void:
	var anchor := _origin + at / _zoom     # 锚点处的世界子格(带小数)
	_zoom = new_zoom
	_origin = anchor - at / _zoom
	refresh()
	zoom_changed.emit(_zoom)


func _zoom_index(z: float) -> int:
	var best := 0
	var best_d := absf(float(ZOOM_STEPS[0]) - z)
	for i in ZOOM_STEPS.size():
		var d := absf(float(ZOOM_STEPS[i]) - z)
		if d < best_d:
			best_d = d
			best = i
	return best


func _nearest_step(z: float) -> float:
	return float(ZOOM_STEPS[_zoom_index(z)])
