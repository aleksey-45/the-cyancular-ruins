extends RefCounted

# 画布视图变换:缩放/平移/坐标换算与可见子格区。相机真源(origin/zoom)、视口尺寸、文档
# 都从 bind() 注入的宿主(EditorCanvas)读,不反向 get_node 找画布。无 class_name(调用方 preload)。

var _host = null


## 注入宿主:origin/zoom、size、doc、refresh() 与 zoom_changed 都由它提供。
func bind(host) -> void:
	_host = host


func screen_to_subcell(pos: Vector2) -> Vector2i:
	if _host._zoom <= 0.0:
		return Vector2i.ZERO
	return Vector2i(floori(_host._origin.x + pos.x / _host._zoom), floori(_host._origin.y + pos.y / _host._zoom))


func subcell_to_screen(sub: Vector2i) -> Vector2:
	return Vector2((float(sub.x) - _host._origin.x) * _host._zoom, (float(sub.y) - _host._origin.y) * _host._zoom)


func _cell_center_screen(cell: Vector2i) -> Vector2:
	var spc: float = float(_host.SUB_PER_CELL)
	return Vector2(
			(float(cell.x) * spc + spc * 0.5 - _host._origin.x) * _host._zoom,
			(float(cell.y) * spc + spc * 0.5 - _host._origin.y) * _host._zoom)


func zoom_at_screen(at: Vector2, direction: int) -> void:
	if direction == 0:
		return
	var idx := _zoom_index(_host._zoom)
	var ni := clampi(idx + direction, 0, _host.ZOOM_STEPS.size() - 1)
	if ni == idx:
		return
	_apply_zoom(float(_host.ZOOM_STEPS[ni]), at)


func zoom_in() -> void:
	zoom_at_screen(_host.size * 0.5, 1)


func zoom_out() -> void:
	zoom_at_screen(_host.size * 0.5, -1)


func set_zoom(value: float) -> void:
	var target := _nearest_step(value)
	if is_equal_approx(target, _host._zoom):
		return
	_apply_zoom(target, _host.size * 0.5)


func set_camera(new_origin: Vector2, new_zoom: float) -> void:
	var changed: bool = not _host._origin.is_equal_approx(new_origin) \
			or not is_equal_approx(_host._zoom, _nearest_step(new_zoom))
	_host._origin = new_origin
	_host._zoom = _nearest_step(new_zoom)
	_host.refresh()
	if changed:
		_host.zoom_changed.emit(_host._zoom)


func pan_pixels(delta: Vector2) -> void:
	if _host._zoom <= 0.0:
		return
	_host._origin += delta / _host._zoom
	_host.refresh()


func center_on_subcell(sub: Vector2i) -> void:
	if _host._zoom <= 0.0:
		return
	_host._origin = Vector2(sub) - _host.size / (2.0 * _host._zoom)
	_host.refresh()


func fit_to_map() -> void:
	var sub := _sub_size()
	if sub.x <= 0 or sub.y <= 0 or _host.size.x <= 0.0 or _host.size.y <= 0.0:
		_host._origin = Vector2.ZERO
		_host._zoom = _host.ZOOM_DEFAULT
		_host.refresh()
		_host.zoom_changed.emit(_host._zoom)
		return
	var best: float = float(_host.ZOOM_STEPS[0])
	for s: float in _host.ZOOM_STEPS:
		if float(sub.x) * s <= _host.size.x and float(sub.y) * s <= _host.size.y:
			best = s
	_host._zoom = best
	_host._origin = (Vector2(sub) - _host.size / best) * 0.5
	_host.refresh()
	_host.zoom_changed.emit(_host._zoom)


func _sub_size() -> Vector2i:
	if _host._doc == null:
		return Vector2i.ZERO
	var map: Dictionary = _host._doc.map
	if map.is_empty():
		return Vector2i.ZERO
	return Vector2i(int(map.get("sub_cols", 0)), int(map.get("sub_rows", 0)))


func _visible_sub_rect() -> Rect2i:
	var cols := ceili(float(_host.size.x) / _host._zoom) + 1
	var rows := ceili(float(_host.size.y) / _host._zoom) + 1
	return Rect2i(floori(_host._origin.x), floori(_host._origin.y), maxi(cols, 1), maxi(rows, 1))


func _apply_zoom(new_zoom: float, at: Vector2) -> void:
	var anchor: Vector2 = _host._origin + at / _host._zoom     # 锚点处的世界子格(带小数)
	_host._zoom = new_zoom
	_host._origin = anchor - at / _host._zoom
	_host.refresh()
	_host.zoom_changed.emit(_host._zoom)


func _zoom_index(z: float) -> int:
	var best := 0
	var best_d := absf(float(_host.ZOOM_STEPS[0]) - z)
	for i in _host.ZOOM_STEPS.size():
		var d := absf(float(_host.ZOOM_STEPS[i]) - z)
		if d < best_d:
			best_d = d
			best = i
	return best


func _nearest_step(z: float) -> float:
	return float(_host.ZOOM_STEPS[_zoom_index(z)])
