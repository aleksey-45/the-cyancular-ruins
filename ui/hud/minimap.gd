class_name Minimap
extends CanvasLayer

# 右下角圆形小地图。HUD 例外:用 anchors + UiFactory.MARGIN / SP_* 表达位置,禁止从逻辑分辨率
# 反推坐标(原先从 1920×1440 减留白反推,已删;契约 .tmp/ui-system-contract.md §5)。

const RADIUS_PX := 140.0
const RANGE_CELLS := 50.0
const PX_PER_CELL := RADIUS_PX / RANGE_CELLS
# 留白 token:EDGE = 屏幕边距 MARGIN(24);EDGE_BOTTOM 再让出底部 48(SP_8)= 72 ——
# 右下角是延迟条(font_size 32),小地图 layer 131 画在 PvpHud(130)之上,不可盖住它。
const EDGE := float(UiFactory.MARGIN)
const EDGE_BOTTOM := EDGE + UiFactory.SP_8
const RING_PX := 4.0
const RING_SELF_PX := 4.0

const SHADER_PATH := "res://ui/hud/minimap_circle.gdshader"
const SELF_COLOR := Color(0.6, 0.95, 1.0)
const ENEMY_COLOR := Color(1.0, 0.4, 0.35)

var _local_provider: Callable = Callable()
var _enemy_provider: Callable = Callable()
var _others_provider: Callable = Callable()
var _color_provider: Callable = Callable()
var _self_color_provider: Callable = Callable()
var _ring_self: ColorRect
var _mat: ShaderMaterial = null
var _view: ColorRect = null       # 圆形视野(右下角锚点 + offset;圆心由它派生)
var _dot_self: ColorRect
var _dot_enemy: ColorRect
var _other_dots: Array[ColorRect] = []


func setup(local_provider: Callable, enemy_provider: Callable) -> void:
	_local_provider = local_provider
	_enemy_provider = enemy_provider


func setup_multi(local_provider: Callable, others_provider: Callable,
		color_provider: Callable, self_color_provider: Callable) -> void:
	_local_provider = local_provider
	_others_provider = others_provider
	_color_provider = color_provider
	_self_color_provider = self_color_provider


func _ready() -> void:
	layer = 131
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		set_process(false)
		return
	var cols: int = grid[0].size()
	var rows: int = grid.size()

	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in rows:
		for x in cols:
			var v: int = grid[y][x]
			if v == MazeGenerator.EMPTY:
				img.set_pixel(x, y, Color(0.05, 0.09, 0.13, 0.55))
			elif Water.is_liquid(MazeGenerator.texture_of(v)):
				img.set_pixel(x, y, Color(0.15, 0.38, 0.85, 0.85))
			else:
				img.set_pixel(x, y, Color(0.62, 0.68, 0.75, 0.95))

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	_mat.set_shader_parameter("map_tex", ImageTexture.create_from_image(img))
	_mat.set_shader_parameter("map_size", Vector2(float(cols), float(rows)))
	_mat.set_shader_parameter("px_per_cell", PX_PER_CELL)
	_mat.set_shader_parameter("radius", RADIUS_PX)
	_mat.set_shader_parameter("ring", RING_PX)

	var view := ColorRect.new()
	view.name = "Circle"
	view.material = _mat
	# 右下角:锚 bottom-right + offset(-EDGE-R 直径 / -EDGE_BOTTOM);位置只由 MARGIN/SP_* token
	# 与固定像素半径决定,与逻辑分辨率无关(原先的 1920×1440 反推已删)。
	view.anchor_left = 1.0
	view.anchor_right = 1.0
	view.anchor_top = 1.0
	view.anchor_bottom = 1.0
	view.offset_left = -EDGE - RADIUS_PX * 2.0
	view.offset_right = -EDGE
	view.offset_top = -EDGE_BOTTOM - RADIUS_PX * 2.0
	view.offset_bottom = -EDGE_BOTTOM
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(view)
	_view = view

	# ★ 描边先建、点后建:Godot 的绘制顺序 = 子节点顺序,后建的在上层 ⇒ 点压在框上。
	_ring_self = _make_dot(Color(1.0, 1.0, 1.0, 1.0))
	_ring_self.size = Vector2(8, 8) + Vector2(RING_SELF_PX, RING_SELF_PX) * 2.0
	_dot_self = _make_dot(SELF_COLOR)
	_dot_enemy = _make_dot(ENEMY_COLOR)


func _make_dot(color: Color) -> ColorRect:
	var d := ColorRect.new()
	d.color = color
	d.size = Vector2(8, 8)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.visible = false
	add_child(d)
	return d


func _process(_delta: float) -> void:
	if _dot_self == null:
		return
	var p := Vector2.INF
	if _local_provider.is_valid():
		p = _local_provider.call()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	if not p.is_finite() or w <= 0.0 or h <= 0.0:
		_dot_self.visible = false
		_ring_self.visible = false
		_dot_enemy.visible = false
		for d in _other_dots:
			d.visible = false
		return
	var canonical := MazeGenerator.wrap_to_range(p, w, h)
	_mat.set_shader_parameter("center_cell", canonical / float(GameParameters.TILE_SIZE))

	_dot_self.visible = true
	_dot_self.position = _circle_center() - _dot_self.size * 0.5
	# ★ 3v3(有自色提供器):自己的点 = 队色(与身体 / 头顶 ID 同源)+ 一圈白描边;1v1 / 大乱斗不传它 ⇒ use_team_self 为假 ⇒ 走 SELF_COLOR,行为逐字不变。
	var use_team_self := _self_color_provider.is_valid()
	if use_team_self:
		_dot_self.color = _self_color_provider.call()
		_ring_self.visible = true
		_ring_self.position = _circle_center() - _ring_self.size * 0.5
	else:
		_ring_self.visible = false

	if _others_provider.is_valid():
		var others: Array = _others_provider.call()
		# ★ 队色每帧回填(不是建点时定色):match_sync 到得比小地图晚,建点时还拿不到队色。
		var cols: Array = _color_provider.call() if _color_provider.is_valid() else []
		while _other_dots.size() < others.size():
			_other_dots.append(_make_dot(ENEMY_COLOR))
		for i in range(_other_dots.size()):
			if i < cols.size():
				(_other_dots[i] as ColorRect).color = cols[i]
			_place_enemy_dot(_other_dots[i], others[i] if i < others.size() else Vector2.INF, p, w, h)
		return
	if _dot_enemy != null and _enemy_provider.is_valid():
		_place_enemy_dot(_dot_enemy, _enemy_provider.call(), p, w, h)


func _circle_center() -> Vector2:
	# 圆心 = 视野 Control 的实际矩形中心(锚点解析后的屏幕坐标);删掉 _rect_pos 后由布局本身给出。
	if _view == null or not is_instance_valid(_view):
		return Vector2.ZERO
	return _view.get_global_rect().get_center()


func _place_enemy_dot(dot: ColorRect, enemy: Vector2, player: Vector2, w: float, h: float) -> void:
	if not Settings.pvp_minimap_show_enemy or not enemy.is_finite():
		dot.visible = false
		return
	var d := GridPathfinder.toroidal_delta_px(player, enemy, w, h)
	var s := d / float(GameParameters.TILE_SIZE) * PX_PER_CELL
	if s.length() > RADIUS_PX:
		dot.visible = false
		return
	dot.visible = true
	dot.position = _circle_center() + s - dot.size * 0.5
